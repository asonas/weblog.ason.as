import json
from pathlib import Path

from log_migration.scrapbox import load_export


def test_load_export_separates_page_links_and_external_urls(tmp_path: Path):
    export = {
        "projectName": "memo",
        "pages": [
            {
                "title": "A",
                "lines": [
                    {"text": "[B]"},
                    {"text": "[https://gyazo.com/abc image] https://gyazo.com/abc"},
                    {"text": "[missing]"},
                ],
            },
            {"title": "B", "lines": []},
        ],
    }
    path = tmp_path / "export.json"
    path.write_text(json.dumps(export), encoding="utf-8")

    project = load_export(path)

    assert project.pages[0].links == ("B", "missing")
    assert project.pages[0].external_urls == ("https://gyazo.com/abc",)
