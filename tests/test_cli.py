import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "scrapbox" / "minimal.json"


def run_cli(args: list[str]) -> subprocess.CompletedProcess[str]:
    environment = {**os.environ, "PYTHONPATH": str(ROOT / "src")}
    return subprocess.run(
        [sys.executable, "-m", "log_migration", *args],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )


def test_cli_requires_input_and_output():
    result = run_cli([])

    assert result.returncode != 0
    assert "--input" in result.stderr


def test_cli_rejects_missing_input(tmp_path: Path):
    result = run_cli(
        [
            "--input",
            str(tmp_path / "missing.json"),
            "--output",
            str(tmp_path / "out"),
            "--report",
            str(tmp_path / "report"),
        ]
    )

    assert result.returncode != 0
    assert "missing.json" in result.stderr


def test_cli_normalizes_scrapbox_input(tmp_path: Path):
    output_dir = tmp_path / "normalized"
    report_dir = tmp_path / "report"
    result = run_cli(
        [
            "--input",
            str(FIXTURE),
            "--output",
            str(output_dir),
            "--report",
            str(report_dir),
        ]
    )

    assert result.returncode == 0, result.stderr
    assert list((output_dir / "posts").glob("*.md"))
    assert (output_dir / "migration-map.json").is_file()
    assert (output_dir / "index" / "log.sqlite3").is_file()
