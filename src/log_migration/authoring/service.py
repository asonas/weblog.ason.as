import json
import shutil
import uuid
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path
from typing import Callable, Literal
from zoneinfo import ZoneInfo

from .database import AuthoringDatabase
from .markdown import RenderedBody, render_markdown
from .models import ConflictError, PageDocument, PublishError, PublishRequest, Redirect, SaveRequest
from .publisher import StaticPublisher
from .repository import ContentRepository, FileTransaction, RepositorySnapshot


TOKYO = ZoneInfo("Asia/Tokyo")
_REDIRECTS_FILENAME = ".authoring-redirects.json"


@dataclass(frozen=True)
class PublishResult:
    page: PageDocument


class AuthoringService:
    def __init__(
        self,
        repository: ContentRepository,
        database: AuthoringDatabase | StaticPublisher,
        publisher: StaticPublisher | Callable[[], datetime],
        clock: Callable[[], datetime] | None = None,
    ):
        if clock is None:
            clock = publisher
            publisher = database
            database = repository.database
        self.repository = repository
        self.database = database
        self.publisher = publisher
        self.clock = clock
        self._redirects: tuple[Redirect, ...] = ()

    def save_draft(self, request: SaveRequest) -> PageDocument:
        page = self.repository.save_draft(request)
        self._refresh()
        return self.repository.get_page(page.id) or page

    def preview(
        self, request: SaveRequest, mode: Literal["local", "public"] = "local"
    ) -> RenderedBody:
        return render_markdown(request.body, mode=mode)

    def publish(self, request: PublishRequest) -> PublishResult:
        snapshot = self._refresh()
        page = self._page(snapshot, request.page_id)
        self._validate_expected_update(page, request)
        now = self._now()
        published = replace(
            page,
            status="published",
            updated_at=now,
            published_at=page.published_at or now,
        )
        candidate = self._replace_page(snapshot, published)
        self._publish_candidate(candidate, page, published)
        return PublishResult(self.repository.get_page(page.id) or published)

    def unpublish(self, page_id: str) -> PageDocument:
        snapshot = self._refresh()
        page = self._page(snapshot, page_id)
        if page.status != "published":
            raise ConflictError("only published pages can be unpublished")
        unpublished = replace(page, status="draft", updated_at=self._now())
        candidate = self._replace_page(snapshot, unpublished)
        self._publish_candidate(candidate, page, unpublished)
        return self.repository.get_page(page.id) or unpublished

    def rename(self, page_id: str, new_name: str) -> PageDocument:
        snapshot = self._refresh()
        if snapshot.problems:
            raise ConflictError("cannot rename while source documents have problems")
        page = self._page(snapshot, page_id)
        source_before = self._source_files() if page.status == "published" else None
        renamed = self.repository.rename_named_page(page_id, new_name)
        if page.status != "published" or renamed.route == page.route:
            self._refresh()
            return renamed

        redirect = Redirect(old_route=page.route, new_route=renamed.route)
        try:
            candidate = self._snapshot_with_redirect(self._refresh(), redirect)
            self._publish_snapshot(candidate, candidate.redirects)
        except Exception:
            assert source_before is not None
            self._restore_source_files(source_before)
            self._refresh()
            raise
        self._refresh()
        return self.repository.get_page(page_id) or renamed

    def _publish_candidate(
        self,
        candidate: RepositorySnapshot,
        original: PageDocument,
        replacement: PageDocument,
    ) -> None:
        staging = self._staging_path()
        try:
            self.publisher.build(candidate, staging)
            transaction = FileTransaction()
            transaction.write(replacement.path, self._serialized(replacement))
            transaction.commit()
            try:
                self.publisher.swap(staging)
            except Exception:
                rollback = FileTransaction()
                rollback.write(original.path, self._serialized(original))
                rollback.commit()
                raise
        except PublishError:
            self._remove_staging(staging)
            self._refresh()
            raise
        except OSError as error:
            self._remove_staging(staging)
            self._refresh()
            raise PublishError(f"could not publish page: {error}") from error
        self._refresh()

    def _publish_snapshot(
        self, snapshot: RepositorySnapshot, redirects: tuple[Redirect, ...]
    ) -> None:
        staging = self._staging_path()
        try:
            self.publisher.build(snapshot, staging)
            transaction = FileTransaction()
            transaction.write(self._redirects_path, self._serialize_redirects(redirects))
            transaction.commit()
            self.publisher.swap(staging)
        except PublishError:
            self._remove_staging(staging)
            raise
        except OSError as error:
            self._remove_staging(staging)
            raise PublishError(f"could not publish page: {error}") from error

    def _refresh(self) -> RepositorySnapshot:
        snapshot = self.repository.refresh()
        self._redirects = self._load_redirects()
        self.database.rebuild(snapshot)
        return replace(snapshot, redirects=self._redirects)

    def _replace_page(
        self, snapshot: RepositorySnapshot, replacement: PageDocument
    ) -> RepositorySnapshot:
        return replace(
            snapshot,
            pages=tuple(
                replacement if page.id == replacement.id else page for page in snapshot.pages
            ),
            redirects=self._redirects,
        )

    def _snapshot_with_redirect(
        self, snapshot: RepositorySnapshot, redirect: Redirect
    ) -> RepositorySnapshot:
        redirects = self._redirects
        if redirect not in redirects:
            redirects = (*redirects, redirect)
        return replace(snapshot, redirects=redirects)

    @staticmethod
    def _page(snapshot: RepositorySnapshot, page_id: str) -> PageDocument:
        page = next((page for page in snapshot.pages if page.id == page_id), None)
        if page is None:
            raise ConflictError(f"page does not exist: {page_id}")
        return page

    @staticmethod
    def _validate_expected_update(page: PageDocument, request: PublishRequest) -> None:
        if request.expected_updated_at is not None and request.expected_updated_at != page.updated_at:
            raise ConflictError("page was updated by another edit")

    def _now(self) -> datetime:
        value = self.clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("clock must return an aware datetime")
        return value.astimezone(TOKYO)

    @staticmethod
    def _serialized(page: PageDocument) -> bytes:
        from .frontmatter import serialize_document

        return serialize_document(page).encode()

    def _staging_path(self) -> Path:
        return self.publisher.output_dir.with_name(
            f"{self.publisher.output_dir.name}.staging-{uuid.uuid4().hex}"
        )

    @staticmethod
    def _remove_staging(path: Path) -> None:
        if path.exists():
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()

    def _source_files(self) -> dict[Path, bytes]:
        files = {
            path: path.read_bytes()
            for path in self.repository.content_dir.glob("*.md")
        }
        if self._redirects_path.exists():
            files[self._redirects_path] = self._redirects_path.read_bytes()
        return files

    def _restore_source_files(self, source_before: dict[Path, bytes]) -> None:
        transaction = FileTransaction()
        current_paths = list(self.repository.content_dir.glob("*.md"))
        if self._redirects_path.exists():
            current_paths.append(self._redirects_path)
        for path in current_paths:
            if path not in source_before:
                transaction.delete(path)
        for path, content in source_before.items():
            transaction.write(path, content)
        transaction.commit()

    @property
    def _redirects_path(self) -> Path:
        return self.repository.content_dir / _REDIRECTS_FILENAME

    def _load_redirects(self) -> tuple[Redirect, ...]:
        if not self._redirects_path.exists():
            return ()
        try:
            value = json.loads(self._redirects_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ConflictError(f"redirect metadata is invalid: {error}") from error
        if not isinstance(value, dict) or set(value) != {"redirects"}:
            raise ConflictError("redirect metadata must contain only redirects")
        redirects = value["redirects"]
        if not isinstance(redirects, list):
            raise ConflictError("redirect metadata redirects must be a list")
        loaded: list[Redirect] = []
        for item in redirects:
            if (
                not isinstance(item, dict)
                or set(item) != {"old_route", "new_route"}
                or not isinstance(item["old_route"], str)
                or not isinstance(item["new_route"], str)
            ):
                raise ConflictError("redirect metadata contains an invalid redirect")
            redirect = Redirect(**item)
            if redirect not in loaded:
                loaded.append(redirect)
        return tuple(loaded)

    @staticmethod
    def _serialize_redirects(redirects: tuple[Redirect, ...]) -> bytes:
        value = {
            "redirects": [
                {"old_route": redirect.old_route, "new_route": redirect.new_route}
                for redirect in redirects
            ]
        }
        return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
