from pathlib import Path

from log_migration.index import build_index, stable_asset_id
from log_migration.normalize import normalize_project, stable_post_id
from log_migration.render import render_cards
from log_migration.scrapbox import load_export


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


def _card_snapshot(tmp_path: Path):
    project = load_export(FIXTURE)
    normalized = normalize_project(project, tmp_path / "normalized")
    index = build_index(normalized, tmp_path / "index" / "log.sqlite3")
    return normalized, index


def test_card_view_includes_root_linked_post_and_asset(tmp_path: Path):
    normalized, index = _card_snapshot(tmp_path)
    root_id = stable_post_id("asonas-memo", "A")

    html = render_cards(normalized, index, root_id=root_id, range_name="all", depth=1)

    assert f'data-root-id="{root_id}"' in html
    assert f'data-post-id="{root_id}"' in html
    assert f'data-post-id="{stable_post_id("asonas-memo", "B")}"' in html
    assert f'data-asset-id="{stable_asset_id("photo.jpg")}"' in html
    assert 'data-range="all"' in html
    assert 'data-depth="1"' in html


def test_card_view_does_not_duplicate_a_node_reached_by_two_edges(tmp_path: Path):
    normalized, index = _card_snapshot(tmp_path)
    root_id = stable_post_id("asonas-memo", "A")

    html = render_cards(normalized, index, root_id=root_id, range_name="all", depth=2)

    assert html.count(f'data-post-id="{stable_post_id("asonas-memo", "B")}"') == 1
    assert html.count(f'data-asset-id="{stable_asset_id("photo.jpg")}"') == 1


def test_card_view_supports_explicit_time_range(tmp_path: Path):
    normalized, index = _card_snapshot(tmp_path)
    root_id = stable_post_id("asonas-memo", "A")

    html = render_cards(normalized, index, root_id=root_id, range_name="7d", depth=1)

    assert 'data-range="7d"' in html


def test_card_view_exposes_shared_data_source_and_independent_depth_controls(
    tmp_path: Path,
):
    normalized, index = _card_snapshot(tmp_path)
    root_id = stable_post_id("asonas-memo", "A")

    html = render_cards(normalized, index, root_id=root_id, range_name="all", depth=1)

    assert 'data-card-data-url="/static/cards-data.json"' in html
    assert 'data-range-option="7d"' in html
    assert 'data-depth-option="0"' in html
    assert 'data-depth-option="3"' in html
