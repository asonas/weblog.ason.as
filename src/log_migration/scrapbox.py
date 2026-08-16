import json
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from .models import ScrapboxPage, ScrapboxProject


_SCRAPBOX_LINK = re.compile(r"\[([^\[\]]+)\]")


def load_export(path: Path) -> ScrapboxProject:
    path = Path(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read Scrapbox export: {path}") from error

    if not isinstance(payload, dict):
        raise ValueError(f"Scrapbox export must be an object: {path}")

    project_name = payload.get("projectName") or payload.get("name")
    raw_pages = payload.get("pages")
    if not isinstance(project_name, str) or not isinstance(raw_pages, list):
        raise ValueError(f"Scrapbox export is missing projectName or pages: {path}")

    pages = tuple(_parse_page(project_name, raw_page, path) for raw_page in raw_pages)
    return ScrapboxProject(name=project_name, pages=pages)


def _parse_page(project_name: str, raw_page: object, path: Path) -> ScrapboxPage:
    if not isinstance(raw_page, dict):
        raise ValueError(f"Scrapbox page must be an object: {path}")

    title = raw_page.get("title")
    raw_lines = raw_page.get("lines", [])
    if not isinstance(title, str) or not isinstance(raw_lines, list):
        raise ValueError(f"Scrapbox page is missing title or lines: {path}")

    lines = tuple(_line_text(line, path) for line in raw_lines)
    links = _extract_links(lines)
    assets = _extract_assets(raw_page.get("assets"), path)
    source_url = f"https://scrapbox.io/{quote(project_name)}/{quote(title, safe='')}"

    return ScrapboxPage(
        project=project_name,
        title=title,
        lines=lines,
        created_at=_timestamp(raw_page.get("created")),
        updated_at=_timestamp(raw_page.get("updated")),
        links=links,
        asset_references=assets,
        source_url=source_url,
    )


def _line_text(line: object, path: Path) -> str:
    if isinstance(line, str):
        return line
    if isinstance(line, dict) and isinstance(line.get("text"), str):
        return line["text"]
    raise ValueError(f"Scrapbox page line must contain text: {path}")


def _extract_links(lines: tuple[str, ...]) -> tuple[str, ...]:
    links: list[str] = []
    for line in lines:
        for match in _SCRAPBOX_LINK.finditer(line):
            link = match.group(1).strip()
            if link and not link.startswith(("http://", "https://")) and link not in links:
                links.append(link.lstrip("/"))
    return tuple(links)


def _extract_assets(raw_assets: object, path: Path) -> tuple[str, ...]:
    if raw_assets is None:
        return ()
    if not isinstance(raw_assets, list) or not all(isinstance(asset, str) for asset in raw_assets):
        raise ValueError(f"Scrapbox page assets must be a list of strings: {path}")
    return tuple(dict.fromkeys(raw_assets))


def _timestamp(value: object) -> datetime | None:
    if value is None:
        return None
    if not isinstance(value, (int, float)):
        raise ValueError(f"Scrapbox timestamp must be numeric: {value!r}")
    return datetime.fromtimestamp(value, tz=timezone.utc)
