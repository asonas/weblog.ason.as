import io
import json
from dataclasses import dataclass
from datetime import date
from wsgiref.util import setup_testing_defaults

from log_migration.authoring.models import PublishRequest, SaveRequest
from log_migration.authoring.web import create_app
from log_migration.authoring.publisher import StaticPublisher
from log_migration.authoring.repository import ContentRepository
from log_migration.authoring.service import AuthoringService


def service_for(tmp_path):
    return AuthoringService(
        ContentRepository(tmp_path / "content", tmp_path / "data" / "authoring.sqlite3", fixed_clock),
        StaticPublisher(tmp_path / "site"),
        fixed_clock,
    )


def fixed_clock():
    from datetime import datetime
    from zoneinfo import ZoneInfo

    return datetime(2026, 1, 1, 12, 0, tzinfo=ZoneInfo("Asia/Tokyo"))


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


def test_save_creates_empty_wiki_target(tmp_path):
    app = create_app(service_for(tmp_path))

    response = request_json(
        app,
        "POST",
        "/api/save",
        {
            "page_type": "date",
            "date": "2026-01-01",
            "title": "",
            "body": "[[page-a]]",
        },
    )

    assert response.status == 200
    assert response.json["status"] == "draft"
    assert request_json(app, "GET", "/page-a").status == 200


def test_preview_does_not_persist_unsaved_link_target(tmp_path):
    service = service_for(tmp_path)

    response = request_json(
        create_app(service),
        "POST",
        "/api/preview",
        {"title": "", "body": "[[page-a]]"},
    )

    assert 'href="/page-a"' in response.json["html"]
    assert service.repository.find_route("/page-a") is None


def test_local_view_shows_draft_body_and_opens_wiki_links_in_new_tab(tmp_path):
    service = service_for(tmp_path)
    service.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 1), body="下書き [[page-a]]")
    )

    response = request_json(create_app(service), "GET", "/2026-01-01")

    assert response.status == 200
    assert "下書き" in response.body
    assert 'target="_blank"' in response.body


def test_public_draft_route_is_not_exposed_by_local_view(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 1), body="公開本文")
    )
    service.publish(PublishRequest(page.id))
    service.save_draft(
        SaveRequest(page_type="date", page_id=page.id, body="下書き更新")
    )

    response = request_json(create_app(service), "GET", "/2026-01-01")

    assert response.status == 200
    assert "下書き更新" in response.body


def test_api_returns_japanese_errors_for_invalid_and_conflicting_requests(tmp_path):
    app = create_app(service_for(tmp_path))

    invalid = request_json(app, "POST", "/api/save", {"page_type": "date", "body": ""})
    missing = request_json(app, "POST", "/api/publish", {"page_id": "missing"})

    assert invalid.status == 422
    assert invalid.json["error"]
    assert missing.status == 409
    assert missing.json["error"]


def test_editor_contains_split_view_accessible_controls_and_scripts(tmp_path):
    app = create_app(service_for(tmp_path))
    response = request_json(app, "GET", "/editor/today")
    javascript = request_json(app, "GET", "/static/authoring/editor.js").body
    stylesheet = request_json(app, "GET", "/static/authoring/authoring.css").body

    assert response.status == 200
    assert '<label for="title">タイトル</label>' in response.body
    assert 'aria-describedby="title-errors"' in response.body
    assert 'aria-describedby="body-errors"' in response.body
    assert '<textarea id="body"' in response.body
    assert 'aria-live="polite"' in response.body
    assert 'src="/static/authoring/editor.js"' in response.body
    assert "先に保存してください" in javascript
    assert "previewSequence" in javascript
    assert 'pre { max-width: 100%; overflow-x: auto; }' in stylesheet
    assert 'img { max-width: 100%; height: auto; }' in stylesheet
    assert "box-sizing: border-box" in stylesheet
