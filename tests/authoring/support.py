from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from log_migration.authoring.models import PublishRequest, SaveRequest


def fixed_clock() -> datetime:
    return datetime(2026, 1, 1, 12, 0, tzinfo=ZoneInfo("Asia/Tokyo"))


def repository_for(tmp_path: Path):
    from log_migration.authoring.repository import ContentRepository

    return ContentRepository(
        content_dir=tmp_path / "content",
        database_path=tmp_path / "data" / "index" / "authoring.sqlite3",
        clock=fixed_clock,
    )


def service_for(tmp_path: Path, fail_static_build: bool = False):
    from log_migration.authoring.publisher import StaticPublisher
    from log_migration.authoring.service import AuthoringService

    return AuthoringService(
        repository_for(tmp_path),
        StaticPublisher(tmp_path / "site", fail_build=fail_static_build),
        clock=fixed_clock,
    )


def new_date_request(page_date: date, body: str = "") -> SaveRequest:
    return SaveRequest(page_type="date", page_date=page_date, body=body)


def repository_with_date_page(tmp_path: Path, page_date: date):
    repository = repository_for(tmp_path)
    repository.save_draft(new_date_request(page_date))
    return repository


def snapshot_with_published_link_to_empty_page(tmp_path: Path):
    repository = repository_for(tmp_path)
    page = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    repository.save_draft(SaveRequest(page_type="named", name="page-a", body=""))
    repository.publish(page.id)
    return repository.refresh()


def service_with_published_page(tmp_path: Path, body: str = ""):
    service = service_for(tmp_path)
    page = service.save_draft(new_date_request(date(2026, 1, 1), body))
    service.publish(publish_request(page.id))
    return service


def edit_request(page_id: str, body: str, title: str | None = None) -> SaveRequest:
    return SaveRequest(page_type="date", page_id=page_id, body=body, title=title)


def publish_request(page_id: str) -> PublishRequest:
    return PublishRequest(page_id=page_id)


def page_id_for(tmp_path: Path, page_type: str = "date") -> str:
    page = repository_for(tmp_path).list_pages()[0]
    return page.id


def read_source(tmp_path: Path, filename: str) -> str:
    return (tmp_path / "content" / filename).read_text(encoding="utf-8")


def public_exists(tmp_path: Path, route: str) -> bool:
    return (tmp_path / "site" / route.strip("/") / "index.html").exists()
