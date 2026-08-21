import json
from dataclasses import replace
from pathlib import Path

from log_migration.asset_manifest import stable_url_asset_id
from log_migration.index import build_index, stable_asset_id
from log_migration.normalize import (
    NormalizedPost,
    NormalizationResult,
    normalize_project,
    stable_post_id,
)
from log_migration.render import render_cards, render_site
from log_migration.scrapbox import load_export
from support import normalized_result_with_external_urls


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


def _rendered_site(tmp_path: Path) -> Path:
    project = load_export(FIXTURE)
    normalized = normalize_project(project, tmp_path / "normalized")
    private_post = _private_copy(normalized.posts[0])
    undated_post = _undated_copy(normalized.posts[0])
    snapshot = NormalizationResult(
        posts=normalized.posts + (private_post, undated_post),
        mapping=normalized.mapping,
        issues=normalized.issues,
    )
    index = build_index(snapshot, tmp_path / "index" / "log.sqlite3")
    site = tmp_path / "site"
    render_site(snapshot, index, site)
    return site


def _private_copy(post: NormalizedPost) -> NormalizedPost:
    frontmatter = {**post.frontmatter, "id": "private-post", "visibility": "private"}
    return replace(post, id="private-post", frontmatter=frontmatter)


def _undated_copy(post: NormalizedPost) -> NormalizedPost:
    frontmatter = {**post.frontmatter, "id": "undated-post", "created_at": None}
    return replace(post, id="undated-post", frontmatter=frontmatter)


def test_render_day_page_orders_public_posts_and_hides_private_posts(tmp_path: Path):
    site = _rendered_site(tmp_path)
    html = (site / "2024-08-01" / "index.html").read_text(encoding="utf-8")

    assert html.index(f'data-post-id="{stable_post_id("asonas-memo", "A")}"') < html.index(
        f'data-post-id="{stable_post_id("asonas-memo", "B")}"'
    )
    assert "private-post" not in html
    assert "card--expanded" in html


def test_render_undated_page_contains_posts_without_created_at(tmp_path: Path):
    site = _rendered_site(tmp_path)
    html = (site / "undated" / "index.html").read_text(encoding="utf-8")

    assert 'data-post-id="undated-post"' in html


def test_rendered_post_contains_asset_card(tmp_path: Path):
    site = _rendered_site(tmp_path)
    html = (site / "2024-08-01" / "index.html").read_text(encoding="utf-8")

    assert "asset_" in html
    assert "photo.jpg" in html


def test_render_site_writes_shared_card_data_without_private_posts(tmp_path: Path):
    site = _rendered_site(tmp_path)

    data = json.loads(
        (site / "static" / "cards-data.json").read_text(encoding="utf-8")
    )
    post_a = stable_post_id("asonas-memo", "A")
    post_b = stable_post_id("asonas-memo", "B")
    asset_id = stable_asset_id("photo.jpg")
    posts = {post["id"]: post for post in data["posts"]}
    assets = {asset["id"]: asset for asset in data["assets"]}

    assert data["version"] == 1
    assert set(posts) == {post_a, post_b, "undated-post"}
    assert "private-post" not in posts
    assert posts[post_a]["body_html"].startswith("<p>本文")
    assert assets[asset_id]["references"] == sorted([post_a, post_b, "undated-post"])
    assert {edge["target"] for edge in data["edges"] if edge["source"] == post_a} == {
        post_b,
        asset_id,
    }


def test_render_cards_include_external_url_asset(tmp_path: Path):
    normalized = normalized_result_with_external_urls(
        ("https://example.test/image.png",),
    )
    index = build_index(normalized, tmp_path / "log.sqlite3")

    html = render_cards(normalized, index, root_id="post-a")

    asset_id = stable_url_asset_id("https://example.test/image.png")
    assert f'data-asset-id="{asset_id}"' in html
    assert "example.test" in html


def test_render_site_uses_fetched_url_metadata_and_shared_preview_image(
    tmp_path: Path,
):
    url = "https://example.test/article"
    normalized = normalized_result_with_external_urls((url,), (url,))
    index = build_index(normalized, tmp_path / "log.sqlite3")
    asset_id = stable_url_asset_id(url)
    image_name = f"{asset_id}.jpg"
    asset_dir = tmp_path / "assets"
    asset_dir.mkdir()
    (asset_dir / image_name).write_bytes(b"preview")
    metadata_path = tmp_path / "url-metadata.json"
    metadata_path.write_text(
        json.dumps(
            {
                "assets": [
                    {
                        "description": "A description",
                        "domain": "example.test",
                        "id": asset_id,
                        "image": {
                            "local_path": image_name,
                            "mime_type": "image/jpeg",
                        },
                        "kind": "url",
                        "source_post_ids": ["post-a", "post-b"],
                        "status": "ready",
                        "title": "An article",
                        "url": url,
                    }
                ],
                "version": 1,
            }
        ),
        encoding="utf-8",
    )

    site = tmp_path / "site"
    render_site(
        normalized,
        index,
        site,
        url_metadata_path=metadata_path,
        asset_dir=asset_dir,
    )

    data = json.loads(
        (site / "static" / "cards-data.json").read_text(encoding="utf-8")
    )
    asset = next(item for item in data["assets"] if item["id"] == asset_id)
    assert asset["title"] == "An article"
    assert asset["description"] == "A description"
    assert asset["image_path"] == f"/assets/{asset_id}/{image_name}"
    assert asset["references"] == ["post-a", "post-b"]

    page = (site / "undated" / "index.html").read_text(encoding="utf-8")
    assert "asset-card--with-image" in page
    assert "An article" in page
    assert "A description" in page
    assert f"/assets/{asset_id}/{image_name}" in page
    assert (site / "assets" / asset_id / image_name).read_bytes() == b"preview"
