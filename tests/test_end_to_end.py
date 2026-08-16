import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "scrapbox" / "minimal.json"


def test_cli_generates_normalized_index_site_and_report(tmp_path: Path):
    before_hash = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
    output_dir = tmp_path / "normalized"
    report_dir = tmp_path / "report"
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "log_migration",
            "--input",
            str(FIXTURE),
            "--output",
            str(output_dir),
            "--report",
            str(report_dir),
        ],
        cwd=ROOT,
        env={**os.environ, "PYTHONPATH": str(ROOT / "src")},
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert hashlib.sha256(FIXTURE.read_bytes()).hexdigest() == before_hash
    assert list((output_dir / "posts").glob("*.md"))
    assert (output_dir / "index" / "log.sqlite3").is_file()
    assert (output_dir / "asset-manifest.json").is_file()
    assert (output_dir / "site" / "2024-08-01" / "index.html").is_file()
    assert list((output_dir / "site" / "posts").glob("*/cards/index.html"))

    report = json.loads(
        (report_dir / "migration-report.json").read_text(encoding="utf-8")
    )
    assert report["pages"] == 2
    assert report["posts"] == 2
    assert report["assets"] == 1
    assert (report_dir / "migration-report.md").is_file()
