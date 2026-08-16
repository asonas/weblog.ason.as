from pathlib import Path

from log_migration.scrapbox import load_export


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


def test_load_export_preserves_page_titles_and_lines():
    project = load_export(FIXTURE)

    assert project.name == "asonas-memo"
    assert [page.title for page in project.pages] == ["A", "B"]
    assert list(project.pages[0].lines) == ["本文", "[B]"]


def test_load_export_keeps_source_link_and_image_lines():
    project = load_export(FIXTURE)

    assert project.pages[0].links == ("B",)
    assert project.pages[0].asset_references == ("photo.jpg",)
