import argparse
from pathlib import Path
from typing import Sequence

from .index import build_index
from .normalize import normalize_project
from .render import render_site
from .report import write_reports
from .scrapbox import load_export


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Migrate a Scrapbox export")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if not args.input.is_file():
        parser.error(f"input file does not exist: {args.input}")

    args.output.mkdir(parents=True, exist_ok=True)
    args.report.mkdir(parents=True, exist_ok=True)

    try:
        project = load_export(args.input)
        normalized = normalize_project(project, args.output)
        index_path = args.output / "index" / "log.sqlite3"
        index = build_index(normalized, index_path)
        site_path = args.output / "site"
        render_site(normalized, index, site_path)
        write_reports(
            args.report,
            args.input,
            project,
            normalized,
            index_path=index_path,
            site_path=site_path,
        )
    except ValueError as error:
        parser.error(str(error))

    return 0
