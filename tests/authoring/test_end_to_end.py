import io
import json
from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

from log_migration.authoring.models import PublishRequest, SaveRequest
from log_migration.authoring.publisher import StaticPublisher
from log_migration.authoring.repository import ContentRepository
from log_migration.authoring.service import AuthoringService
from log_migration.authoring.web import create_app
from wsgiref.util import setup_testing_defaults


def fixed_clock():
    return datetime(2026, 1, 1, 12, 0, tzinfo=ZoneInfo("Asia/Tokyo"))


def service_for(tmp_path):
    return AuthoringService(
        ContentRepository(
            tmp_path / "content",
            tmp_path / "data" / "index" / "authoring.sqlite3",
            fixed_clock,
        ),
        StaticPublisher(tmp_path / "site"),
        fixed_clock,
    )


def public_exists(tmp_path, route):
    return (tmp_path / "site" / route / "index.html").exists()


def read_source(tmp_path, filename):
    return (tmp_path / "content" / filename).read_text(encoding="utf-8")


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict[str, str]
    body: str

    @property
    def json(self):
        return json.loads(self.body)


def request_json(app, method, path, payload=None):
    body = b"" if payload is None else json.dumps(payload).encode()
    environ = {}
    setup_testing_defaults(environ)
    environ.update(
        REQUEST_METHOD=method,
        PATH_INFO=path,
        CONTENT_TYPE="application/json",
        CONTENT_LENGTH=str(len(body)),
        **{"wsgi.input": io.BytesIO(body)},
    )
    captured = {}

    def start_response(status, headers):
        captured["status"] = int(status.split()[0])
        captured["headers"] = dict(headers)

    response_body = b"".join(app(environ, start_response)).decode()
    return Response(captured["status"], captured["headers"], response_body)


def test_authoring_flow_save_publish_rename_and_rebuild(tmp_path):
    service = service_for(tmp_path)
    app = create_app(service)

    today = request_json(app, "GET", "/")

    assert today.status == 302
    assert today.headers["Location"] == "/editor/today"
    assert not (tmp_path / "content").exists()
    assert service.repository.list_pages() == ()

    saved = request_json(
        app,
        "POST",
        "/api/save",
        {
            "page_type": "date",
            "date": "2026-01-01",
            "title": "",
            "body": "公開元 [[page-a]]",
        },
    )
    duplicate = request_json(
        app,
        "POST",
        "/api/save",
        {
            "page_type": "date",
            "date": "2026-01-01",
            "title": "",
            "body": "同日投稿",
        },
    )

    assert saved.status == 200
    assert saved.json["status"] == "draft"
    assert duplicate.status == 409
    assert request_json(app, "GET", "/2026-01-01").body.count('target="_blank"') == 1
    local_empty_target = request_json(app, "GET", "/page-a")
    assert local_empty_target.status == 200
    assert "まだ内容がありません" in local_empty_target.body
    assert not (tmp_path / "site").exists()

    target = service.repository.find_route("page-a")
    assert target is not None
    service.save_draft(SaveRequest(page_type="named", page_id=target.id, body="下書き本文"))
    published = request_json(app, "POST", "/api/publish", {"page_id": saved.json["id"]})

    assert published.status == 200
    assert public_exists(tmp_path, "2026-01-01")
    public_source = (tmp_path / "site" / "2026-01-01" / "index.html").read_text(encoding="utf-8")
    public_target = (tmp_path / "site" / "page-a" / "index.html").read_text(encoding="utf-8")
    assert 'href="/page-a"' in public_source
    assert 'target="_blank"' not in public_source
    assert "まだ内容がありません" in public_target
    assert "下書き本文" not in public_target
    assert not tuple(tmp_path.glob("site.staging-*"))

    target = service.save_draft(SaveRequest(page_type="named", page_id=target.id, body=""))
    service.publish(PublishRequest(target.id))
    service.rename(target.id, "page-b")

    assert "[[page-b]]" in read_source(tmp_path, "2026-01-01.md")
    assert public_exists(tmp_path, "page-b")
    assert 'url=/page-b' in (tmp_path / "site" / "page-a" / "index.html").read_text(encoding="utf-8")

    service.database.path.unlink()
    service.database.rebuild(service.repository.refresh())

    assert service.database.search("page-b", None)


def test_malformed_frontmatter_rejects_publication_of_referenced_page(tmp_path):
    service = service_for(tmp_path)
    app = create_app(service)
    saved = request_json(
        app,
        "POST",
        "/api/save",
        {"page_type": "date", "date": "2026-01-01", "title": "", "body": "[[page-a]]"},
    )
    malformed = tmp_path / "content" / "page-a.md"
    malformed.write_text("---\nstatus: broken\n---\n本文\n", encoding="utf-8")

    published = request_json(app, "POST", "/api/publish", {"page_id": saved.json["id"]})

    assert published.status == 409
    assert published.json["error"]
    assert not (tmp_path / "site").exists()
