import pytest

from log_migration.authoring import cli
from log_migration.authoring.cli import build_parser


def test_parser_requires_content_index_and_site(capsys):
    parser = build_parser()

    with pytest.raises(SystemExit):
        parser.parse_args([])

    error = capsys.readouterr().err
    assert "--content" in error
    assert "--index" in error
    assert "--site" in error


def test_parser_defaults_to_localhost_on_port_8000(tmp_path):
    args = build_parser().parse_args(
        [
            "--content",
            str(tmp_path / "content"),
            "--index",
            str(tmp_path / "data" / "index" / "authoring.sqlite3"),
            "--site",
            str(tmp_path / "site"),
        ]
    )

    assert args.host == "127.0.0.1"
    assert args.port == 8000


def test_main_prepares_repository_before_starting_local_server(tmp_path, monkeypatch):
    calls = []
    original_refresh = cli.ContentRepository.refresh
    original_rebuild = cli.AuthoringDatabase.rebuild

    def refresh(repository):
        calls.append("refresh")
        return original_refresh(repository)

    def rebuild(database, snapshot):
        calls.append("rebuild")
        return original_rebuild(database, snapshot)

    class Server:
        def serve_forever(self):
            raise KeyboardInterrupt

    def make_server(host, port, app):
        calls.append(("server", host, port, app))
        return Server()

    monkeypatch.setattr(cli.ContentRepository, "refresh", refresh)
    monkeypatch.setattr(cli.AuthoringDatabase, "rebuild", rebuild)
    monkeypatch.setattr(cli, "make_server", make_server)
    content = tmp_path / "content"
    index = tmp_path / "data" / "index" / "authoring.sqlite3"

    result = cli.main(
        ["--content", str(content), "--index", str(index), "--site", str(tmp_path / "site")]
    )

    assert result == 0
    assert content.is_dir()
    assert index.parent.is_dir()
    assert index.is_file()
    assert calls[:3] == ["refresh", "rebuild", "rebuild"]
    assert calls[3][0:3] == ("server", "127.0.0.1", 8000)
