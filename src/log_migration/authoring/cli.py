import argparse
from datetime import datetime
from pathlib import Path
from typing import Sequence
from wsgiref.simple_server import make_server
from zoneinfo import ZoneInfo

from .database import AuthoringDatabase
from .publisher import StaticPublisher
from .repository import ContentRepository
from .service import AuthoringService
from .web import create_app


TOKYO = ZoneInfo("Asia/Tokyo")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the local authoring server")
    parser.add_argument("--content", required=True, type=Path)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--site", required=True, type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8000, type=int)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.content.mkdir(parents=True, exist_ok=True)
    args.index.parent.mkdir(parents=True, exist_ok=True)

    database = AuthoringDatabase(args.index)
    repository = ContentRepository(args.content, args.index, _now)
    service = AuthoringService(repository, database, StaticPublisher(args.site), _now)
    snapshot = repository.refresh()
    database.rebuild(snapshot)

    server = make_server(args.host, args.port, create_app(service))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def _now() -> datetime:
    return datetime.now(TOKYO)
