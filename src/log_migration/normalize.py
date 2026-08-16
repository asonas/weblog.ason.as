import hashlib
import json
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Mapping

from .models import ScrapboxPage


@dataclass(frozen=True)
class NormalizationIssue:
    kind: str
    source: str
    detail: str


@dataclass(frozen=True)
class NormalizedPost:
    id: str
    frontmatter: dict[str, object]
    body: str
    links: tuple[str, ...]
    asset_references: tuple[str, ...]
    external_urls: tuple[str, ...]
    issues: tuple[NormalizationIssue, ...]


@dataclass(frozen=True)
class NormalizationResult:
    posts: tuple[NormalizedPost, ...]
    mapping: dict[str, str]
    issues: tuple[NormalizationIssue, ...]


_LINK = re.compile(r"\[([^\[\]]+)\]")
_EXTERNAL_URL = re.compile(r"https?://[^\s<>\[\]\\\"']+")


def stable_post_id(project: str, title: str) -> str:
    source_key = f"{project}\x00{title}".encode("utf-8")
    return f"post_{hashlib.sha256(source_key).hexdigest()[:16]}"


def normalize_page(
    page: ScrapboxPage,
    link_map: Mapping[str, str] | None = None,
) -> NormalizedPost:
    post_id = stable_post_id(page.project, page.title)
    issues: list[NormalizationIssue] = []
    body_lines: list[str] = []

    for line in page.lines:
        body_lines.append(_rewrite_links(line, page.title, link_map, issues))

    frontmatter = {
        "id": post_id,
        "title": page.title,
        "created_at": _format_datetime(page.created_at),
        "updated_at": _format_datetime(page.updated_at),
        "published_at": None,
        "visibility": "public",
        "source_kind": "scrapbox",
        "source_project": page.project,
        "source_title": page.title,
        "source_url": page.source_url,
    }

    return NormalizedPost(
        id=post_id,
        frontmatter=frontmatter,
        body="\n".join(body_lines),
        links=page.links,
        asset_references=page.asset_references,
        external_urls=page.external_urls,
        issues=tuple(issues),
    )


def normalize_project(project, output_dir: Path) -> NormalizationResult:
    output_dir = Path(output_dir)
    posts_dir = output_dir / "posts"
    posts_dir.mkdir(parents=True, exist_ok=True)

    link_map = {
        page.title: stable_post_id(project.name, page.title)
        for page in project.pages
    }
    mapping = {
        f"{project.name}\x00{page.title}": stable_post_id(project.name, page.title)
        for page in project.pages
    }

    posts = tuple(normalize_page(page, link_map) for page in project.pages)
    for post in posts:
        (posts_dir / f"{post.id}.md").write_text(
            serialize_post(post),
            encoding="utf-8",
        )

    (output_dir / "migration-map.json").write_text(
        json.dumps(mapping, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    issues = tuple(issue for post in posts for issue in post.issues)
    return NormalizationResult(posts=posts, mapping=mapping, issues=issues)


def serialize_post(post: NormalizedPost) -> str:
    frontmatter = "\n".join(
        f"{key}: {_yaml_value(value)}" for key, value in post.frontmatter.items()
    )
    return f"---\n{frontmatter}\n---\n\n{post.body}\n"


def _rewrite_links(
    line: str,
    source_title: str,
    link_map: Mapping[str, str] | None,
    issues: list[NormalizationIssue],
) -> str:
    if link_map is None:
        return line

    def replace(match: re.Match[str]) -> str:
        target_title = match.group(1).strip()
        if _EXTERNAL_URL.search(target_title):
            return match.group(0)
        target_id = link_map.get(target_title)
        if target_id is None:
            issues.append(
                NormalizationIssue(
                    kind="unresolved_link",
                    source=source_title,
                    detail=target_title,
                )
            )
            return match.group(0)
        return f"[{target_title}](/posts/{target_id}/)"

    return _LINK.sub(replace, line)


def _format_datetime(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def _yaml_value(value: object) -> str:
    if value is None:
        return "null"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    return str(value)
