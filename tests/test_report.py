import json
from pathlib import Path

from log_migration.index import build_index
from log_migration.normalize import normalize_project
from log_migration.report import build_report, write_reports
from log_migration.scrapbox import load_export
from support import normalized_result_with_external_urls


FIXTURE = Path(__file__).parent / "fixtures" / "scrapbox" / "minimal.json"


def _report_snapshot(tmp_path: Path):
    payload = json.loads(FIXTURE.read_text(encoding="utf-8"))
    payload["pages"][0]["lines"].append({"text": "[missing-page]"})
    input_path = tmp_path / "export.json"
    input_path.write_text(json.dumps(payload), encoding="utf-8")
    project = load_export(input_path)
    normalized = normalize_project(project, tmp_path / "normalized")
    index_path = tmp_path / "index" / "log.sqlite3"
    build_index(normalized, index_path)
    return input_path, project, normalized, index_path


def test_report_counts_unresolved_links_and_missing_assets(tmp_path: Path):
    input_path, project, normalized, index_path = _report_snapshot(tmp_path)

    report = build_report(
        input_path,
        project,
        normalized,
        index_path=index_path,
        site_path=tmp_path / "normalized" / "site",
    )

    assert report["unresolved_links"] == 1
    assert report["missing_assets"] == 1
    assert report["missing_asset_paths"] == ["photo.jpg"]


def test_report_contains_input_hash_and_writes_json_and_markdown(tmp_path: Path):
    input_path, project, normalized, index_path = _report_snapshot(tmp_path)

    report = write_reports(
        tmp_path / "report",
        input_path,
        project,
        normalized,
        index_path=index_path,
        site_path=tmp_path / "normalized" / "site",
    )

    assert len(report["input_sha256"]) == 64
    assert (tmp_path / "report" / "migration-report.json").is_file()
    assert (tmp_path / "report" / "migration-report.md").is_file()


def test_report_counts_external_url_candidates(tmp_path: Path):
    project = load_export(FIXTURE)
    normalized = normalize_project(project, tmp_path / "normalized")
    index_path = tmp_path / "index" / "log.sqlite3"
    build_index(normalized, index_path)

    report = build_report(
        FIXTURE,
        project,
        normalized,
        index_path=index_path,
        site_path=tmp_path / "normalized" / "site",
    )

    assert report["external_url_candidates"] == 0
    assert report["asset_manifest_path"].endswith("asset-manifest.json")


def test_report_assets_include_external_url_candidates(tmp_path: Path):
    project = load_export(FIXTURE)
    normalized = normalized_result_with_external_urls(
        ("https://example.test/image.png",),
    )
    index_path = tmp_path / "index" / "log.sqlite3"
    build_index(normalized, index_path)

    report = build_report(
        FIXTURE,
        project,
        normalized,
        index_path=index_path,
        site_path=tmp_path / "normalized" / "site",
    )

    assert report["external_url_candidates"] == 1
    assert report["assets"] == 1
