import os
import uuid
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path
from typing import Callable
from zoneinfo import ZoneInfo

from .database import AuthoringDatabase
from .frontmatter import parse_document, serialize_document
from .links import extract_wiki_links, replace_wiki_links
from .models import ConflictError, PageDocument, PageProblem, Redirect, SaveRequest, Status
from .names import page_path, validate_page_name


TOKYO = ZoneInfo("Asia/Tokyo")


@dataclass(frozen=True)
class RepositorySnapshot:
    pages: tuple[PageDocument, ...] = ()
    problems: tuple[PageProblem, ...] = ()
    redirects: tuple[Redirect, ...] = ()

    def with_redirect(self, old_route: str, new_route: str) -> "RepositorySnapshot":
        redirect = Redirect(old_route=old_route, new_route=new_route)
        if redirect in self.redirects:
            return self
        return replace(self, redirects=(*self.redirects, redirect))


class FileTransaction:
    def __init__(self) -> None:
        self._writes: dict[Path, bytes] = {}
        self._deletes: set[Path] = set()

    def write(self, path: Path, content: bytes) -> None:
        self._writes[path] = content
        self._deletes.discard(path)

    def delete(self, path: Path) -> None:
        if path not in self._writes:
            self._deletes.add(path)

    def commit(self) -> None:
        affected = set(self._writes) | self._deletes
        original = {path: path.read_bytes() for path in affected if path.exists()}
        created = {path for path in affected if path not in original}
        try:
            for path, content in self._writes.items():
                self._replace(path, content)
            for path in self._deletes:
                path.unlink()
        except Exception:
            for path, content in original.items():
                self._replace(path, content)
            for path in created:
                if path.exists():
                    path.unlink()
            raise

    @staticmethod
    def _replace(path: Path, content: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            with temporary.open("xb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()


class ContentRepository:
    def __init__(
        self,
        content_dir: Path,
        database_path: Path,
        clock: Callable[[], datetime],
    ):
        self.content_dir = content_dir
        self.database_path = database_path
        self.clock = clock
        self.database = AuthoringDatabase(database_path)

    def refresh(self) -> RepositorySnapshot:
        pages: list[PageDocument] = []
        problems: list[PageProblem] = []
        ids: set[str] = set()
        routes: set[str] = set()
        if self.content_dir.exists():
            for path in sorted(self.content_dir.glob("*.md")):
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError as error:
                    problems.append(PageProblem(path, f"document is not UTF-8: {error}"))
                    continue
                parsed = parse_document(path, text)
                if isinstance(parsed, PageProblem):
                    problems.append(parsed)
                    continue
                document = self._with_links_and_tokyo_time(parsed)
                if document.id in ids:
                    problems.append(PageProblem(path, f"duplicate page id: {document.id}"))
                    continue
                if document.route in routes:
                    problems.append(PageProblem(path, f"duplicate route: {document.route}"))
                    continue
                ids.add(document.id)
                routes.add(document.route)
                pages.append(document)
        snapshot = RepositorySnapshot(tuple(pages), tuple(problems))
        self.database.rebuild(snapshot)
        return snapshot

    def get_page(self, page_id: str) -> PageDocument | None:
        return next((page for page in self.refresh().pages if page.id == page_id), None)

    def find_route(self, route: str) -> PageDocument | None:
        normalized = route.strip("/")
        return next((page for page in self.refresh().pages if page.route == normalized), None)

    def list_pages(
        self,
        query: str = "",
        status: Status | None = None,
        empty_only: bool = False,
    ) -> tuple[PageDocument, ...]:
        pages = self.refresh().pages
        query = query.casefold()
        return tuple(
            page
            for page in pages
            if (status is None or page.status == status)
            and (not empty_only or page.is_empty)
            and (
                not query
                or query in page.display_title.casefold()
                or query in page.route.casefold()
            )
        )

    def save_draft(self, request: SaveRequest) -> PageDocument:
        snapshot = self.refresh()
        current = self._current_page(snapshot, request.page_id)
        if current is None:
            document = self._new_document(snapshot, request)
        else:
            self._validate_expected_update(current, request)
            document = replace(
                current,
                body=request.body,
                title=request.title if current.page_type == "date" else None,
                updated_at=self._now(),
            )
        document = self._with_links_and_tokyo_time(document)
        transaction = FileTransaction()
        transaction.write(document.path, serialize_document(document).encode())
        current_names = {page.name for page in snapshot.pages if page.name is not None}
        for link in document.links:
            name = validate_page_name(link.name)
            if name not in current_names:
                empty = self._new_empty_named_page(snapshot, name)
                transaction.write(empty.path, serialize_document(empty).encode())
                current_names.add(name)
        transaction.commit()
        self.refresh()
        return self.get_page(document.id) or document

    def rename_named_page(self, page_id: str, new_name: str) -> PageDocument:
        snapshot = self.refresh()
        page = self._current_page(snapshot, page_id)
        if page is None:
            raise ConflictError(f"page does not exist: {page_id}")
        if page.page_type != "named":
            raise ConflictError("only named pages can be renamed")
        new_name = validate_page_name(new_name)
        if new_name == page.name:
            return page
        destination = page_path(self.content_dir, "named", new_name, None)
        if any(other.name == new_name for other in snapshot.pages) or destination.exists():
            raise ConflictError(f"page name already exists: {new_name}")
        renamed = replace(page, name=new_name, path=destination, updated_at=self._now())
        transaction = FileTransaction()
        for source in snapshot.pages:
            if source.id == page.id:
                transaction.write(destination, serialize_document(renamed).encode())
            else:
                body = replace_wiki_links(source.body, page.name or "", new_name)
                if body != source.body:
                    transaction.write(
                        source.path,
                        serialize_document(replace(source, body=body, updated_at=self._now())).encode(),
                    )
        transaction.delete(page.path)
        transaction.commit()
        self.refresh()
        return self.get_page(page.id) or renamed

    def _new_document(self, snapshot: RepositorySnapshot, request: SaveRequest) -> PageDocument:
        now = self._now()
        if request.page_type == "date":
            if request.page_date is None:
                raise ValueError("date pages require page_date")
            if any(page.page_date == request.page_date for page in snapshot.pages):
                raise ConflictError(f"date page already exists: {request.page_date.isoformat()}")
            path = page_path(self.content_dir, "date", None, request.page_date)
            if path.exists():
                raise ConflictError(f"source path already exists: {path.name}")
            return PageDocument(
                id=uuid.uuid4().hex,
                page_type="date",
                name=None,
                page_date=request.page_date,
                title=request.title,
                status="draft",
                created_at=now,
                updated_at=now,
                published_at=None,
                path=path,
                body=request.body,
            )
        if request.page_type == "named":
            if request.name is None:
                raise ValueError("named pages require a name")
            name = validate_page_name(request.name)
            if any(page.name == name for page in snapshot.pages):
                raise ConflictError(f"page name already exists: {name}")
            path = page_path(self.content_dir, "named", name, None)
            if path.exists():
                raise ConflictError(f"source path already exists: {path.name}")
            return PageDocument(
                id=uuid.uuid4().hex,
                page_type="named",
                name=name,
                page_date=None,
                title=None,
                status="draft",
                created_at=now,
                updated_at=now,
                published_at=None,
                path=path,
                body=request.body,
            )
        raise ValueError(f"unknown page type: {request.page_type}")

    def _new_empty_named_page(self, snapshot: RepositorySnapshot, name: str) -> PageDocument:
        return self._new_document(snapshot, SaveRequest(page_type="named", name=name, body=""))

    @staticmethod
    def _current_page(snapshot: RepositorySnapshot, page_id: str | None) -> PageDocument | None:
        if page_id is None:
            return None
        return next((page for page in snapshot.pages if page.id == page_id), None)

    @staticmethod
    def _validate_expected_update(page: PageDocument, request: SaveRequest) -> None:
        if request.expected_updated_at is not None and request.expected_updated_at != page.updated_at:
            raise ConflictError("page was updated by another edit")

    def _now(self) -> datetime:
        value = self.clock()
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("clock must return an aware datetime")
        return value.astimezone(TOKYO)

    @staticmethod
    def _with_links_and_tokyo_time(document: PageDocument) -> PageDocument:
        times = (document.created_at, document.updated_at, document.published_at)
        if any(value is not None and (value.tzinfo is None or value.utcoffset() is None) for value in times):
            raise ValueError("document timestamps must be aware")
        return replace(
            document,
            created_at=document.created_at.astimezone(TOKYO),
            updated_at=document.updated_at.astimezone(TOKYO),
            published_at=document.published_at.astimezone(TOKYO) if document.published_at else None,
            links=extract_wiki_links(document.body),
        )
