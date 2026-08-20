import json
import shutil
import uuid
from dataclasses import dataclass, replace
from datetime import date, datetime
from pathlib import Path
from typing import Callable, Literal
from zoneinfo import ZoneInfo

from .database import AuthoringDatabase
from .links import extract_wiki_links, replace_wiki_links
from .markdown import RenderedBody, render_markdown
from .models import (
    ConflictError,
    PageDocument,
    PublishError,
    PublishRequest,
    Redirect,
    SaveRequest,
)
from .publisher import StaticPublisher, flatten_redirects
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
        self._release_pages: tuple[PageDocument, ...] = ()

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
        candidate = self._candidate(snapshot, explicit_page_ids={page.id})
        candidate = self._replace_page(candidate, published)
        self._publish_candidate(candidate, published, self._public_pages(candidate))
        return PublishResult(self.repository.get_page(page.id) or published)

    def unpublish(self, page_id: str) -> PageDocument:
        snapshot = self._refresh()
        page = self._page(snapshot, page_id)
        if page.status != "published":
            raise ConflictError("only published pages can be unpublished")
        unpublished = replace(page, status="draft", updated_at=self._now())
        candidate = self._candidate(snapshot, explicit_page_ids={page.id})
        candidate = self._replace_page(candidate, unpublished)
        self._publish_candidate(candidate, unpublished, self._public_pages(candidate))
        return self.repository.get_page(page.id) or unpublished

    def rename(self, page_id: str, new_name: str) -> PageDocument:
        snapshot = self._refresh()
        if snapshot.problems:
            raise ConflictError("cannot rename while source documents have problems")
        page = self._page(snapshot, page_id)
        release_pages_before = self._release_pages or tuple(
            current for current in snapshot.pages if current.status == "published"
        )
        if page.status == "published":
            self._validate_release_sources(snapshot, release_pages_before)
        source_before = self._source_files() if page.status == "published" else None
        renamed = self.repository.rename_named_page(page_id, new_name)
        if page.status != "published" or renamed.route == page.route:
            self._refresh()
            return renamed

        redirect = Redirect(old_route=page.route, new_route=renamed.route)
        try:
            after_rename = self._refresh()
            renamed_release_pages = self._rename_release_pages(
                release_pages_before, page, renamed
            )
            candidate = self._candidate(after_rename, release_pages=renamed_release_pages)
            candidate = self._snapshot_with_redirect(candidate, redirect)
            self._publish_snapshot(candidate, self._public_pages(candidate), source_before)
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
        replacement: PageDocument,
        release_pages: tuple[PageDocument, ...],
    ) -> None:
        staging = self._staging_path()
        source_before = self._source_files()
        try:
            self.publisher.build(candidate, staging)
            transaction = FileTransaction()
            transaction.write(replacement.path, self._serialized(replacement))
            transaction.write(
                self._redirects_path,
                self._serialize_release(candidate.redirects, release_pages),
            )
            transaction.commit()
            try:
                self.publisher.swap(staging)
            except Exception:
                self._restore_source_files(source_before)
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
        self,
        snapshot: RepositorySnapshot,
        release_pages: tuple[PageDocument, ...],
        source_before: dict[Path, bytes],
    ) -> None:
        staging = self._staging_path()
        try:
            self.publisher.build(snapshot, staging)
            transaction = FileTransaction()
            transaction.write(
                self._redirects_path,
                self._serialize_release(snapshot.redirects, release_pages),
            )
            transaction.commit()
            try:
                self.publisher.swap(staging)
            except Exception:
                self._restore_source_files(source_before)
                raise
        except PublishError:
            self._remove_staging(staging)
            raise
        except OSError as error:
            self._remove_staging(staging)
            raise PublishError(f"could not publish page: {error}") from error

    def _refresh(self) -> RepositorySnapshot:
        snapshot = self.repository.refresh()
        manifest = self._load_manifest()
        self._redirects = self._load_redirects(manifest)
        self._release_pages = self._load_release_pages(manifest)
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
            redirects=snapshot.redirects,
        )

    def _snapshot_with_redirect(
        self, snapshot: RepositorySnapshot, redirect: Redirect
    ) -> RepositorySnapshot:
        redirects = flatten_redirects((*snapshot.redirects, redirect))
        return replace(snapshot, redirects=redirects)

    def _candidate(
        self,
        snapshot: RepositorySnapshot,
        *,
        explicit_page_ids: set[str] | frozenset[str] = frozenset(),
        release_pages: tuple[PageDocument, ...] | None = None,
    ) -> RepositorySnapshot:
        release_pages = self._release_pages if release_pages is None else release_pages
        self._validate_release_sources(snapshot, release_pages)
        released_by_id = {page.id: page for page in release_pages}
        return replace(
            snapshot,
            pages=tuple(
                page
                if page.id in explicit_page_ids
                else released_by_id.get(page.id, page)
                for page in snapshot.pages
            ),
            redirects=snapshot.redirects,
        )

    @staticmethod
    def _public_pages(snapshot: RepositorySnapshot) -> tuple[PageDocument, ...]:
        return tuple(page for page in snapshot.pages if page.status == "published")

    @staticmethod
    def _validate_release_sources(
        snapshot: RepositorySnapshot, release_pages: tuple[PageDocument, ...]
    ) -> None:
        current_by_id = {page.id: page for page in snapshot.pages}
        problems_by_path = {problem.path: problem for problem in snapshot.problems}
        for release_page in release_pages:
            problem = problems_by_path.get(release_page.path)
            if problem is not None:
                raise PublishError(
                    f"released page is invalid: {release_page.route}: {problem.detail}"
                )
            current = current_by_id.get(release_page.id)
            if current is None:
                raise PublishError(f"released page is missing: {release_page.route}")
            if current.path != release_page.path:
                raise PublishError(f"released page path changed: {release_page.route}")

    def _rename_release_pages(
        self,
        release_pages: tuple[PageDocument, ...],
        original: PageDocument,
        renamed: PageDocument,
    ) -> tuple[PageDocument, ...]:
        old_name = original.name or ""
        new_name = renamed.name or ""
        result: list[PageDocument] = []
        for release_page in release_pages:
            body = replace_wiki_links(release_page.body, old_name, new_name)
            updated = replace(release_page, body=body, links=extract_wiki_links(body))
            if release_page.id == original.id:
                updated = replace(updated, name=renamed.name, path=renamed.path)
            result.append(updated)
        return tuple(result)

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

    def _load_manifest(self) -> dict[str, object]:
        if not self._redirects_path.exists():
            return {"redirects": [], "pages": []}
        try:
            value = json.loads(self._redirects_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ConflictError(f"release metadata is invalid: {error}") from error
        if not isinstance(value, dict) or not set(value) <= {"redirects", "pages"}:
            raise ConflictError("release metadata contains unknown fields")
        return value

    def _load_redirects(self, manifest: dict[str, object]) -> tuple[Redirect, ...]:
        redirects = manifest.get("redirects", [])
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
        try:
            return flatten_redirects(tuple(loaded))
        except PublishError as error:
            raise ConflictError(str(error)) from error

    def _load_release_pages(self, manifest: dict[str, object]) -> tuple[PageDocument, ...]:
        records = manifest.get("pages", [])
        if not isinstance(records, list):
            raise ConflictError("release metadata pages must be a list")
        return tuple(self._page_from_record(record) for record in records)

    def _page_from_record(self, record: object) -> PageDocument:
        required = {
            "id",
            "page_type",
            "name",
            "page_date",
            "title",
            "status",
            "created_at",
            "updated_at",
            "published_at",
            "path",
            "body",
        }
        if not isinstance(record, dict) or set(record) != required:
            raise ConflictError("release metadata contains an invalid page")
        if (
            not isinstance(record["id"], str)
            or record["page_type"] not in {"date", "named"}
            or record["status"] != "published"
            or not isinstance(record["body"], str)
            or not isinstance(record["path"], str)
            or Path(record["path"]).name != record["path"]
        ):
            raise ConflictError("release metadata contains an invalid page")
        try:
            page_date = (
                date.fromisoformat(record["page_date"])
                if record["page_date"] is not None
                else None
            )
            created_at = datetime.fromisoformat(record["created_at"])
            updated_at = datetime.fromisoformat(record["updated_at"])
            published_at = (
                datetime.fromisoformat(record["published_at"])
                if record["published_at"] is not None
                else None
            )
        except (TypeError, ValueError) as error:
            raise ConflictError("release metadata contains invalid timestamps") from error
        timestamps = (created_at, updated_at, published_at)
        if any(value is not None and (value.tzinfo is None or value.utcoffset() is None) for value in timestamps):
            raise ConflictError("release metadata timestamps must be aware")
        return PageDocument(
            id=record["id"],
            page_type=record["page_type"],
            name=record["name"],
            page_date=page_date,
            title=record["title"],
            status=record["status"],
            created_at=created_at,
            updated_at=updated_at,
            published_at=published_at,
            path=self.repository.content_dir / record["path"],
            body=record["body"],
            links=extract_wiki_links(record["body"]),
        )

    @staticmethod
    def _serialize_release(
        redirects: tuple[Redirect, ...], pages: tuple[PageDocument, ...]
    ) -> bytes:
        value = {
            "redirects": [
                {"old_route": redirect.old_route, "new_route": redirect.new_route}
                for redirect in redirects
            ],
            "pages": [
                {
                    "id": page.id,
                    "page_type": page.page_type,
                    "name": page.name,
                    "page_date": page.page_date.isoformat() if page.page_date else None,
                    "title": page.title,
                    "status": page.status,
                    "created_at": page.created_at.isoformat(),
                    "updated_at": page.updated_at.isoformat(),
                    "published_at": page.published_at.isoformat()
                    if page.published_at
                    else None,
                    "path": page.path.name,
                    "body": page.body,
                }
                for page in pages
            ],
        }
        return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
