from pathlib import Path

from log_migration.scrapbox import load_export
from log_migration.normalize import normalize_page, normalize_project, stable_post_id


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


def test_post_id_is_stable_for_same_source_key():
    first = stable_post_id("asonas-memo", "A")
    second = stable_post_id("asonas-memo", "A")

    assert first == second
    assert first.startswith("post_")


def test_normalized_page_defaults_to_public_and_keeps_source_metadata():
    project = load_export(FIXTURE)
    post = normalize_page(project.pages[0])

    assert post.frontmatter["visibility"] == "public"
    assert post.frontmatter["source_title"] == "A"
    assert post.frontmatter["published_at"] is None


def test_normalized_page_rewrites_resolved_internal_links():
    project = load_export(FIXTURE)
    target_id = stable_post_id("asonas-memo", "B")
    post = normalize_page(project.pages[0], {"B": target_id})

    assert f"[B](/posts/{target_id}/)" in post.body


def test_normalize_project_writes_markdown_and_mapping(tmp_path: Path):
    project = load_export(FIXTURE)
    result = normalize_project(project, tmp_path)

    assert (tmp_path / "posts" / f"{stable_post_id('asonas-memo', 'A')}.md").is_file()
    assert result.mapping["asonas-memo\u0000A"].startswith("post_")
