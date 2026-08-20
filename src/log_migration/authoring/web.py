import html
import json
from datetime import date, datetime
from http import HTTPStatus
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, quote
from zoneinfo import ZoneInfo

from .markdown import render_page
from .models import ConflictError, PageDocument, PublishError, PublishRequest, SaveRequest
from .service import AuthoringService


_ROOT = Path(__file__).parent.parent
_TEMPLATES = _ROOT / "templates" / "authoring"
_STATIC = _ROOT / "static" / "authoring"
_TOKYO = ZoneInfo("Asia/Tokyo")


def create_app(service: AuthoringService) -> Callable:
    def application(environ, start_response):
        try:
            return _dispatch(service, environ, start_response)
        except (ValueError, TypeError) as error:
            return _error(start_response, HTTPStatus.UNPROCESSABLE_ENTITY, str(error))
        except (ConflictError, PublishError) as error:
            return _error(start_response, HTTPStatus.CONFLICT, str(error))

    return application


def _dispatch(service, environ, start_response):
    method = environ["REQUEST_METHOD"]
    path = environ.get("PATH_INFO", "/") or "/"
    if path.startswith("/static/authoring/"):
        return _static(path, start_response)
    if method == "POST" and path.startswith("/api/"):
        return _api(service, path, _json_body(environ), start_response)
    if method != "GET":
        return _text(start_response, HTTPStatus.METHOD_NOT_ALLOWED, "許可されていないメソッドです")
    if path == "/":
        return _home(service, start_response)
    if path == "/manage":
        return _management(service, environ.get("QUERY_STRING", ""), start_response)
    if path == "/editor/today":
        return _editor(service, None, start_response)
    if path.startswith("/editor/"):
        return _editor(service, path.removeprefix("/editor/"), start_response)
    return _local_page(service, path, start_response)


def _home(service, start_response):
    today = _today(service)
    page = next((page for page in service.repository.list_pages() if page.page_date == today), None)
    location = f"/editor/{quote(page.id)}" if page else "/editor/today"
    start_response("302 Found", [("Location", location), ("Content-Length", "0")])
    return [b""]


def _management(service, query_string, start_response):
    query = parse_qs(query_string)
    search = query.get("q", [""])[0]
    status = query.get("status", [""])[0] or None
    if status not in (None, "draft", "published"):
        raise ValueError("status は draft または published を指定してください")
    empty_only = query.get("empty", [""])[0] == "1"
    pages = service.repository.list_pages(search, status, empty_only)
    problems = service.repository.refresh().problems
    rows = "".join(_management_row(page) for page in pages)
    if not rows:
        rows = '<tr><td colspan="5">該当するページはありません</td></tr>'
    problem_html = "".join(
        f"<li>{html.escape(problem.path.name)}: {html.escape(problem.detail)}</li>" for problem in problems
    )
    return _html(
        start_response,
        _template(
            "management.html",
            title="管理",
            search=html.escape(search, quote=True),
            draft_selected=" selected" if status == "draft" else "",
            published_selected=" selected" if status == "published" else "",
            empty_checked=" checked" if empty_only else "",
            rows=rows,
            problems=(f"<ul>{problem_html}</ul>" if problem_html else "<p>問題はありません。</p>"),
        ),
    )


def _management_row(page):
    identity = page.name if page.page_type == "named" else page.page_date.isoformat()
    return (
        "<tr>"
        f"<td>{html.escape(page.page_type)}</td>"
        f'<td><a href="/editor/{quote(page.id)}">{html.escape(identity or "")}</a></td>'
        f"<td>{html.escape(page.status)}</td>"
        f"<td>{'空' if page.is_empty else '内容あり'}</td>"
        f'<td><a href="/{quote(page.route)}" target="_blank" rel="noreferrer">閲覧</a></td>'
        "</tr>"
    )


def _editor(service, page_id, start_response):
    page = service.repository.get_page(page_id) if page_id else None
    if page_id and page is None:
        return _text(start_response, HTTPStatus.NOT_FOUND, "ページが見つかりません")
    today = _today(service).isoformat()
    values = _page_values(page, today)
    return _html(start_response, _template("editor.html", **values))


def _page_values(page, today):
    return {
        "title": "編集",
        "page_id": html.escape(page.id if page else "", quote=True),
        "page_type": html.escape(page.page_type if page else "date", quote=True),
        "page_date": html.escape(page.page_date.isoformat() if page and page.page_date else today, quote=True),
        "name": html.escape(page.name if page and page.name else "", quote=True),
        "document_title": html.escape(page.title if page and page.title else "", quote=True),
        "body": html.escape(page.body if page else ""),
        "status": html.escape(page.status if page else "未保存"),
        "saved_at": html.escape(_time(page.updated_at) if page else "未保存"),
        "expected_updated_at": html.escape(page.updated_at.isoformat() if page else "", quote=True),
    }


def _local_page(service, path, start_response):
    page = service.repository.find_route(path)
    if page is None:
        return _text(start_response, HTTPStatus.NOT_FOUND, "ページが見つかりません")
    backlinks = service.database.backlinks(page.id, public_only=False)
    content = _empty_page(page, backlinks) if page.is_empty else render_page(page, backlinks, mode="local")
    return _html(start_response, _template("local.html", title=html.escape(page.display_title), content=content))


def _api(service, path, payload, start_response):
    if path == "/api/preview":
        request = _save_request(service, payload, allow_unsaved=True)
        rendered = service.preview(request, mode="local")
        return _json(start_response, HTTPStatus.OK, {"html": rendered.html, "errors": list(rendered.problems)})
    if path == "/api/save":
        page = service.save_draft(_save_request(service, payload))
        return _json(start_response, HTTPStatus.OK, _page_json(page))
    page_id = _required(payload, "page_id")
    if path == "/api/publish":
        page = service.publish(PublishRequest(page_id, _expected_updated_at(payload))).page
    elif path == "/api/unpublish":
        page = service.unpublish(page_id)
    elif path == "/api/rename":
        page = service.rename(page_id, _required(payload, "name"))
    else:
        return _text(start_response, HTTPStatus.NOT_FOUND, "API が見つかりません")
    return _json(start_response, HTTPStatus.OK, _page_json(page))


def _save_request(service, payload, allow_unsaved=False):
    page_id = _optional_string(payload, "page_id")
    current = service.repository.get_page(page_id) if page_id else None
    if page_id and current is None:
        raise ConflictError("ページが見つかりません")
    page_type = payload.get("page_type") or (current.page_type if current else "date")
    if page_type not in ("date", "named"):
        raise ValueError("page_type が不正です")
    body = _optional_string(payload, "body") or ""
    if not allow_unsaved and "body" not in payload:
        raise ValueError("body は必須です")
    page_date = (
        _date_value(payload.get("date"))
        if page_type == "date" and (payload.get("date") or not allow_unsaved)
        else None
    )
    if page_date is None and current and current.page_type == "date":
        page_date = current.page_date
    name = _optional_string(payload, "name") if page_type == "named" else None
    if name is None and current and current.page_type == "named":
        name = current.name
    return SaveRequest(
        page_type=page_type,
        page_id=page_id,
        page_date=page_date,
        name=name,
        title=_optional_string(payload, "title"),
        body=body,
        expected_updated_at=_expected_updated_at(payload),
    )


def _json_body(environ):
    try:
        length = int(environ.get("CONTENT_LENGTH") or 0)
        value = json.loads(environ["wsgi.input"].read(length).decode() or "{}")
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("JSON 本文が不正です") from error
    if not isinstance(value, dict):
        raise ValueError("JSON 本文はオブジェクトにしてください")
    return value


def _required(payload, key):
    value = _optional_string(payload, key)
    if not value:
        raise ValueError(f"{key} は必須です")
    return value


def _optional_string(payload, key):
    value = payload.get(key)
    if value is not None and not isinstance(value, str):
        raise ValueError(f"{key} は文字列にしてください")
    return value


def _date_value(value):
    if not isinstance(value, str) or not value:
        raise ValueError("date は必須です")
    return date.fromisoformat(value)


def _expected_updated_at(payload):
    value = _optional_string(payload, "expected_updated_at")
    return datetime.fromisoformat(value) if value else None


def _page_json(page):
    return {
        "id": page.id,
        "page_type": page.page_type,
        "date": page.page_date.isoformat() if page.page_date else None,
        "name": page.name,
        "title": page.title,
        "status": page.status,
        "updated_at": page.updated_at.isoformat(),
        "route": page.route,
    }


def _empty_page(page, backlinks):
    backlink_items = "".join(
        f'<li><a href="/{quote(source.route)}" target="_blank" rel="noreferrer">'
        f"{html.escape(source.display_title)}</a></li>"
        for source in backlinks
    )
    backlinks_html = f"<aside><h2>リンク元</h2><ul>{backlink_items}</ul></aside>" if backlink_items else ""
    return (
        f"<article><h1>{html.escape(page.display_title)}</h1>"
        '<p class="empty-state">まだ内容がありません</p></article>'
        f"{backlinks_html}"
    )


def _template(filename, **values):
    output = (_TEMPLATES / filename).read_text(encoding="utf-8")
    for key, value in values.items():
        output = output.replace(f"{{{{{key}}}}}", str(value))
    return output


def _static(path, start_response):
    filename = path.removeprefix("/static/authoring/")
    if filename not in {"editor.js", "authoring.css"}:
        return _text(start_response, HTTPStatus.NOT_FOUND, "ファイルが見つかりません")
    content_type = "text/javascript" if filename.endswith(".js") else "text/css"
    return _response(start_response, HTTPStatus.OK, (_STATIC / filename).read_bytes(), content_type)


def _json(start_response, status, value):
    return _response(start_response, status, json.dumps(value, ensure_ascii=False).encode(), "application/json")


def _html(start_response, value):
    return _response(start_response, HTTPStatus.OK, value.encode(), "text/html")


def _text(start_response, status, value):
    return _response(start_response, status, value.encode(), "text/plain")


def _error(start_response, status, detail):
    message = "入力内容を確認してください" if status == HTTPStatus.UNPROCESSABLE_ENTITY else "他の編集と競合したか、公開処理に失敗しました"
    return _json(start_response, status, {"error": message})


def _response(start_response, status, body, content_type):
    start_response(f"{status.value} {status.phrase}", [("Content-Type", f"{content_type}; charset=utf-8"), ("Content-Length", str(len(body)))])
    return [body]


def _time(value):
    return value.astimezone(_TOKYO).strftime("%Y-%m-%d %H:%M")


def _today(service):
    return service.repository.clock().astimezone(_TOKYO).date()
