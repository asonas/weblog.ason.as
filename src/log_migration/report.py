import hashlib
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import ScrapboxProject
from .normalize import NormalizationResult


def build_report(
    input_path: Path,
    project: ScrapboxProject,
    normalized: NormalizationResult,
    *,
    index_path: Path,
    site_path: Path,
    asset_root: Path | None = None,
    run_at: datetime | None = None,
) -> dict[str, Any]:
    """Build a review-oriented summary without changing migration inputs."""

    input_path = Path(input_path)
    asset_root = Path(asset_root) if asset_root is not None else input_path.parent
    asset_paths = sorted(
        {
            source_path
            for post in normalized.posts
            for source_path in post.asset_references
        }
    )
    missing_asset_paths = [
        source_path
        for source_path in asset_paths
        if not (asset_root / source_path).is_file()
    ]
    unresolved = [
        {
            "source": issue.source,
            "target": issue.detail,
        }
        for issue in normalized.issues
        if issue.kind == "unresolved_link"
    ]
    resolved_links = _resolved_link_count(normalized)
    duplicate_titles = sorted(
        title for title, count in Counter(page.title for page in project.pages).items() if count > 1
    )
    undated_posts = sorted(
        page.title for page in project.pages if page.created_at is None
    )
    timestamp = run_at or datetime.now(timezone.utc)

    return {
        "input_path": str(input_path),
        "input_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "run_at": timestamp.isoformat(),
        "pages": len(project.pages),
        "posts": len(normalized.posts),
        "assets": len(asset_paths),
        "resolved_internal_links": resolved_links,
        "unresolved_links": len(unresolved),
        "unresolved_link_details": unresolved,
        "missing_assets": len(missing_asset_paths),
        "missing_asset_paths": missing_asset_paths,
        "duplicate_titles": duplicate_titles,
        "undated_posts": undated_posts,
        "invalid_dates": [],
        "output_paths": {
            "index": str(index_path),
            "site": str(site_path),
        },
    }


def write_reports(
    report_dir: Path,
    input_path: Path,
    project: ScrapboxProject,
    normalized: NormalizationResult,
    *,
    index_path: Path,
    site_path: Path,
    asset_root: Path | None = None,
    run_at: datetime | None = None,
) -> dict[str, Any]:
    report_dir = Path(report_dir)
    report_dir.mkdir(parents=True, exist_ok=True)
    report = build_report(
        input_path,
        project,
        normalized,
        index_path=index_path,
        site_path=site_path,
        asset_root=asset_root,
        run_at=run_at,
    )
    (report_dir / "migration-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (report_dir / "migration-report.md").write_text(
        _markdown_report(report),
        encoding="utf-8",
    )
    return report


def _resolved_link_count(normalized: NormalizationResult) -> int:
    count = 0
    for post in normalized.posts:
        source_project = str(post.frontmatter["source_project"])
        count += sum(
            normalized.mapping.get(f"{source_project}\x00{target_title}") is not None
            for target_title in post.links
        )
    return count


def _markdown_report(report: dict[str, Any]) -> str:
    lines = [
        "# Migration report",
        "",
        f"- Input: `{report['input_path']}`",
        f"- Input SHA-256: `{report['input_sha256']}`",
        f"- Run at: `{report['run_at']}`",
        f"- Pages: {report['pages']}",
        f"- Posts: {report['posts']}",
        f"- Assets: {report['assets']}",
        f"- Resolved internal links: {report['resolved_internal_links']}",
        f"- Unresolved links: {report['unresolved_links']}",
        f"- Missing assets: {report['missing_assets']}",
        "",
        "## Unresolved links",
        "",
    ]
    lines.extend(
        f"- `{item['source']}` -> `{item['target']}`"
        for item in report["unresolved_link_details"]
    )
    if not report["unresolved_link_details"]:
        lines.append("- なし")

    lines.extend(["", "## Missing assets", ""])
    lines.extend(f"- `{path}`" for path in report["missing_asset_paths"])
    if not report["missing_asset_paths"]:
        lines.append("- なし")

    lines.extend(["", "## Other checks", ""])
    lines.append(
        "- Duplicate titles: "
        + (", ".join(f"`{title}`" for title in report["duplicate_titles"]) or "なし")
    )
    lines.append(
        "- Undated posts: "
        + (", ".join(f"`{title}`" for title in report["undated_posts"]) or "なし")
    )
    lines.append(
        "- Invalid dates: "
        + (", ".join(f"`{value}`" for value in report["invalid_dates"]) or "なし")
    )
    lines.extend(["", "## Outputs", ""])
    lines.extend(
        f"- {name}: `{path}`" for name, path in sorted(report["output_paths"].items())
    )
    return "\n".join(lines) + "\n"
