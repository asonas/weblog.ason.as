import html
import os
import shutil
import uuid
from pathlib import Path
from urllib.parse import quote, unquote

from .markdown import render_markdown, render_page
from .models import PageDocument, PublishError, Redirect
from .repository import RepositorySnapshot


_TEMPLATE = Path(__file__).parent.parent / "templates" / "authoring" / "public.html"
_EMPTY_STATE = "まだ内容がありません"


def flatten_redirects(redirects: tuple[Redirect, ...]) -> tuple[Redirect, ...]:
    targets = {redirect.old_route: redirect.new_route for redirect in redirects}
    flattened: list[Redirect] = []
    seen_old_routes: set[str] = set()
    for redirect in redirects:
        old_route = redirect.old_route
        if old_route in seen_old_routes:
            continue
        seen_old_routes.add(old_route)
        route = old_route
        visited: set[str] = set()
        while route in targets:
            if route in visited:
                raise PublishError(f"redirect cycle detected: {old_route}")
            visited.add(route)
            route = targets[route]
        if route != old_route:
            flattened.append(Redirect(old_route=old_route, new_route=route))
    return tuple(flattened)


class StaticPublisher:
    def __init__(self, output_dir: Path):
        self.output_dir = output_dir

    def build(self, snapshot: RepositorySnapshot, destination: Path) -> None:
        candidates = self._public_candidates(snapshot)
        redirects = self._published_redirects(snapshot)
        self._validate(snapshot, candidates, redirects)
        try:
            if destination.exists():
                _remove(destination)
            destination.mkdir(parents=True)
            for route, page in candidates.items():
                backlinks = self._public_backlinks(page, candidates, snapshot.pages)
                if page is None or page.status != "published" or page.is_empty:
                    title = page.display_title if page is not None else route
                    content = self._placeholder(title, backlinks)
                else:
                    title = page.display_title
                    content = render_page(page, backlinks, mode="public")
                self._write(destination, route, self._document(title, content))
            for old_route, new_route in redirects:
                self._write(destination, old_route, self._redirect(new_route))
        except PublishError:
            raise
        except OSError as error:
            raise PublishError(f"could not build public site: {error}") from error

    def swap(self, destination: Path) -> None:
        previous = self.output_dir.with_name(f"{self.output_dir.name}.previous-{uuid.uuid4().hex}")
        moved_current = False
        try:
            if self.output_dir.exists():
                os.replace(self.output_dir, previous)
                moved_current = True
            os.replace(destination, self.output_dir)
        except OSError as error:
            restore_error = None
            if moved_current and previous.exists():
                try:
                    os.replace(previous, self.output_dir)
                except OSError as restoration_error:
                    restore_error = restoration_error
            _remove_if_exists(destination)
            if restore_error is None:
                _remove_if_exists(previous)
            detail = f"could not swap public site: {error}"
            if restore_error is not None:
                detail += f"; could not restore previous site: {restore_error}"
            raise PublishError(detail) from error
        _remove_if_exists(previous)

    def publish(self, snapshot: RepositorySnapshot) -> None:
        staging = self.output_dir.with_name(f"{self.output_dir.name}.staging-{uuid.uuid4().hex}")
        try:
            self.build(snapshot, staging)
            self.swap(staging)
        except PublishError:
            _remove_if_exists(staging)
            raise
        except OSError as error:
            _remove_if_exists(staging)
            raise PublishError(f"could not publish public site: {error}") from error

    def _public_candidates(
        self, snapshot: RepositorySnapshot
    ) -> dict[str, PageDocument | None]:
        by_name = {page.name: page for page in snapshot.pages if page.name is not None}
        candidates: dict[str, PageDocument | None] = {
            page.route: page for page in snapshot.pages if page.status == "published"
        }
        for page in snapshot.pages:
            if page.status != "published":
                continue
            for link in page.links:
                candidates.setdefault(link.name, by_name.get(link.name))
        return candidates

    def _validate(
        self,
        snapshot: RepositorySnapshot,
        candidates: dict[str, PageDocument | None],
        redirects: tuple[tuple[str, str], ...],
    ) -> None:
        candidate_routes = set(candidates)
        for old_route, _new_route in redirects:
            if old_route in candidate_routes:
                raise PublishError(f"redirect collides with public route: {old_route}")
        for problem in snapshot.problems:
            route = unquote(problem.path.stem)
            if route in candidate_routes:
                raise PublishError(f"public page is invalid: {route}: {problem.detail}")
        for page in candidates.values():
            if page is None or page.status != "published" or page.is_empty:
                continue
            rendered = render_markdown(page.body, mode="public")
            if rendered.problems:
                raise PublishError(
                    f"public page is invalid: {page.route}: {'; '.join(rendered.problems)}"
                )

    @staticmethod
    def _public_backlinks(
        page: PageDocument | None,
        candidates: dict[str, PageDocument | None],
        pages: tuple[PageDocument, ...],
    ) -> tuple[PageDocument, ...]:
        if page is None or page.name is None or page.route not in candidates:
            return ()
        return tuple(
            source
            for source in pages
            if source.status == "published"
            and any(link.name == page.name for link in source.links)
        )

    def _published_redirects(self, snapshot: RepositorySnapshot) -> tuple[tuple[str, str], ...]:
        published_named_routes = {
            page.route
            for page in snapshot.pages
            if page.page_type == "named" and page.status == "published"
        }
        return tuple(
            (redirect.old_route, redirect.new_route)
            for redirect in flatten_redirects(snapshot.redirects)
            if redirect.new_route in published_named_routes
        )

    @staticmethod
    def _placeholder(title: str, backlinks: tuple[PageDocument, ...]) -> str:
        backlinks_html = ""
        if backlinks:
            items = "".join(
                f'<li><a href="/{_encoded_route(backlink.route)}">'
                f"{html.escape(backlink.display_title)}</a></li>"
                for backlink in backlinks
            )
            backlinks_html = f"<aside><h2>リンク元</h2><ul>{items}</ul></aside>"
        return (
            f"<article><h1>{html.escape(title)}</h1>"
            f'<p class="empty-state">{_EMPTY_STATE}</p></article>{backlinks_html}'
        )

    @staticmethod
    def _document(title: str, content: str) -> str:
        template = _TEMPLATE.read_text(encoding="utf-8")
        return template.replace("{{title}}", html.escape(title)).replace("{{content}}", content)

    @staticmethod
    def _redirect(new_route: str) -> str:
        url = f"/{_encoded_route(new_route)}"
        escaped_url = html.escape(url, quote=True)
        return (
            "<!doctype html><html lang=\"ja\"><head>"
            f'<meta http-equiv="refresh" content="0; url={escaped_url}">'
            f"<link rel=\"canonical\" href=\"{escaped_url}\"></head>"
            f'<body><a href="{escaped_url}">{escaped_url}</a></body></html>'
        )

    @staticmethod
    def _write(destination: Path, route: str, content: str) -> None:
        path = destination / _encoded_route(route) / "index.html"
        try:
            path.resolve().relative_to(destination.resolve())
        except ValueError as error:
            raise PublishError(f"output route escapes destination: {route}") from error
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


def _encoded_route(route: str) -> str:
    return quote(route, safe="-._~")


def _remove_if_exists(path: Path) -> None:
    if path.exists():
        _remove(path)


def _remove(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
