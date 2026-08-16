from pathlib import Path
import sqlite3

import pytest

from log_migration.index import build_index, stable_asset_id
from log_migration.normalize import normalize_project, stable_post_id
from log_migration.scrapbox import load_export


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


@pytest.fixture
def index(tmp_path: Path):
    project = load_export(FIXTURE)
    normalized = normalize_project(project, tmp_path / "normalized")
    return build_index(normalized, tmp_path / "log.sqlite3")


def test_backlinks_return_all_posts_referencing_an_asset(index):
    asset_id = stable_asset_id("photo.jpg")

    assert index.find_backlinks(asset_id) == [
        stable_post_id("asonas-memo", "A"),
        stable_post_id("asonas-memo", "B"),
    ]


def test_neighbors_are_deduplicated_and_depth_limited(index):
    post_a = stable_post_id("asonas-memo", "A")
    post_b = stable_post_id("asonas-memo", "B")
    asset_id = stable_asset_id("photo.jpg")

    neighbors = index.neighbors(post_a, direction="both", depth=1)

    assert post_b in neighbors
    assert asset_id in neighbors
    assert index.neighbors(post_a, direction="both", depth=0) == []


def test_rebuilding_index_produces_identical_ordered_rows(tmp_path: Path):
    project = load_export(FIXTURE)
    normalized = normalize_project(project, tmp_path / "normalized")
    first_path = tmp_path / "first.sqlite3"
    second_path = tmp_path / "second.sqlite3"
    build_index(normalized, first_path)
    build_index(normalized, second_path)

    def rows(path: Path) -> dict[str, list[tuple]]:
        with sqlite3.connect(path) as connection:
            return {
                table: connection.execute(
                    f"SELECT * FROM {table} ORDER BY {order_by}"
                ).fetchall()
                for table, order_by in {
                    "posts": "id",
                    "assets": "id",
                    "edges": "source_id, target_id, edge_kind, position",
                    "issues": "kind, source, detail",
                }.items()
            }

    assert rows(first_path) == rows(second_path)
