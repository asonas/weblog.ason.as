from datetime import date, datetime
from zoneinfo import ZoneInfo

import pytest

from log_migration.authoring.database import AuthoringDatabase
from log_migration.authoring.models import PublishError, PublishRequest, SaveRequest
from log_migration.authoring.publisher import StaticPublisher
from log_migration.authoring.repository import ContentRepository


def test_preview_renders_unsaved_input_without_creating_source_or_index(tmp_path):
    service = service_for(tmp_path)

    rendered = service.preview(new_date_request(body="[[bad/name]]"))

    assert rendered.problems == ("page name contains a forbidden character",)
    assert not (tmp_path / "content").exists()
    assert not (tmp_path / "data").exists()


def test_publish_failure_keeps_draft_source_and_existing_public_output(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(new_date_request(body="公開前の本文"))
    site = tmp_path / "site"
    site.mkdir()
    (site / "marker").write_text("以前の公開版", encoding="utf-8")
    service.publisher = FailingPublisher(site)

    with pytest.raises(PublishError, match="simulated build failure"):
        service.publish(PublishRequest(page.id))

    assert service.repository.get_page(page.id).status == "draft"
    assert page.path.exists()
    assert (site / "marker").read_text(encoding="utf-8") == "以前の公開版"


def test_swap_failure_restores_draft_source_and_existing_public_output(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(new_date_request(body="公開前の本文"))
    site = tmp_path / "site"
    site.mkdir()
    (site / "marker").write_text("以前の公開版", encoding="utf-8")
    service.publisher = FailingSwapPublisher(site)

    with pytest.raises(PublishError, match="simulated swap failure"):
        service.publish(PublishRequest(page.id))

    restored = service.repository.get_page(page.id)
    assert restored is not None
    assert restored.status == "draft"
    assert restored.body == "公開前の本文"
    assert (site / "marker").read_text(encoding="utf-8") == "以前の公開版"


def test_saving_published_page_updates_local_source_but_not_public_output(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(new_date_request(body="公開版"))
    service.publish(PublishRequest(page.id))

    saved = service.save_draft(SaveRequest(page_type="date", page_id=page.id, body="編集版"))

    assert saved.status == "published"
    assert "編集版" in saved.path.read_text(encoding="utf-8")
    public = (tmp_path / "site" / "2026-01-01" / "index.html").read_text(encoding="utf-8")
    assert "公開版" in public
    assert "編集版" not in public


def test_republish_preserves_first_published_at(tmp_path):
    times = iter(
        (
            datetime(2026, 1, 1, 12, 0, tzinfo=JST),
            datetime(2026, 1, 1, 12, 1, tzinfo=JST),
            datetime(2026, 1, 1, 12, 2, tzinfo=JST),
            datetime(2026, 1, 1, 12, 3, tzinfo=JST),
        )
    )
    service = service_for(tmp_path, clock=lambda: next(times))
    page = service.save_draft(new_date_request(body="公開版"))
    first = service.publish(PublishRequest(page.id)).page
    service.save_draft(SaveRequest(page_type="date", page_id=page.id, body="更新版"))

    republished = service.publish(PublishRequest(page.id)).page

    assert republished.published_at == first.published_at
    assert republished.updated_at > first.updated_at


def test_later_publish_uses_last_release_for_an_edited_published_page(tmp_path):
    service = service_for(tmp_path)
    page_a = service.save_draft(new_date_request(body="Aの公開版"))
    service.publish(PublishRequest(page_a.id))

    service.save_draft(SaveRequest(page_type="date", page_id=page_a.id, body="Aの編集中"))
    page_b = service.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 2), body="Bの公開版")
    )
    service.publish(PublishRequest(page_b.id))

    public_a = (tmp_path / "site" / "2026-01-01" / "index.html").read_text(
        encoding="utf-8"
    )
    assert "Aの公開版" in public_a
    assert "Aの編集中" not in public_a


def test_corrupt_released_source_rejects_unrelated_publish_without_site_swap(tmp_path):
    service = service_for(tmp_path)
    page_a = service.save_draft(new_date_request(body="Aの公開版"))
    service.publish(PublishRequest(page_a.id))
    page_b = service.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 2), body="Bの公開版")
    )
    site_before = {
        path: path.read_bytes() for path in (tmp_path / "site").rglob("*") if path.is_file()
    }
    page_a.path.write_text("---\nstatus: broken\n---\n壊れた本文\n", encoding="utf-8")

    with pytest.raises(PublishError, match="released page"):
        service.publish(PublishRequest(page_b.id))

    site_after = {
        path: path.read_bytes() for path in (tmp_path / "site").rglob("*") if path.is_file()
    }
    assert site_after == site_before
    assert not (tmp_path / "site" / "2026-01-02").exists()


def test_unpublish_rebuilds_referenced_page_as_public_placeholder(tmp_path):
    service = service_for(tmp_path)
    source = service.save_draft(new_date_request(body="[[page-a]]"))
    target = service.repository.find_route("page-a")
    assert target is not None
    service.save_draft(SaveRequest(page_type="named", page_id=target.id, body="非公開本文"))
    service.publish(PublishRequest(source.id))
    service.publish(PublishRequest(target.id))

    unpublished = service.unpublish(target.id)

    assert unpublished.status == "draft"
    placeholder = (tmp_path / "site" / "page-a" / "index.html").read_text(encoding="utf-8")
    assert "まだ内容がありません" in placeholder
    assert "非公開本文" not in placeholder


def test_rename_published_page_adds_redirect_but_draft_rename_does_not(tmp_path):
    service = service_for(tmp_path)
    published = service.save_draft(SaveRequest(page_type="named", name="old-public", body="本文"))
    draft = service.save_draft(SaveRequest(page_type="named", name="old-draft", body="本文"))
    service.publish(PublishRequest(published.id))

    service.rename(published.id, "new-public")
    service.rename(draft.id, "new-draft")

    redirect = (tmp_path / "site" / "old-public" / "index.html").read_text(encoding="utf-8")
    assert 'url=/new-public' in redirect
    assert not (tmp_path / "site" / "old-draft").exists()
    assert service.repository.find_route("new-public").id == published.id


def test_published_rename_redirect_survives_a_fresh_service_publish(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(SaveRequest(page_type="named", name="old-public", body="本文"))
    service.publish(PublishRequest(page.id))
    service.rename(page.id, "new-public")

    restarted = service_for(tmp_path)
    later = restarted.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 2), body="後続公開")
    )
    restarted.publish(PublishRequest(later.id))

    redirect = (tmp_path / "site" / "old-public" / "index.html").read_text(encoding="utf-8")
    assert 'url=/new-public' in redirect


def test_persisted_rename_redirect_chain_flattens_after_restart(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(SaveRequest(page_type="named", name="page-a", body="本文"))
    service.publish(PublishRequest(page.id))
    service.rename(page.id, "page-b")
    service.rename(page.id, "page-c")

    restarted = service_for(tmp_path)
    later = restarted.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 2), body="後続公開")
    )
    restarted.publish(PublishRequest(later.id))

    redirect_a = (tmp_path / "site" / "page-a" / "index.html").read_text(encoding="utf-8")
    redirect_b = (tmp_path / "site" / "page-b" / "index.html").read_text(encoding="utf-8")
    assert 'url=/page-c' in redirect_a
    assert 'url=/page-c' in redirect_b
    assert 'url=/page-b' not in redirect_a


def test_failed_published_rename_restores_source_without_redirect_metadata(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(SaveRequest(page_type="named", name="old-public", body="本文"))
    service.publish(PublishRequest(page.id))
    service.publisher = FailingPublisher(tmp_path / "site")
    metadata_before = (tmp_path / "content" / ".authoring-redirects.json").read_bytes()

    with pytest.raises(PublishError, match="simulated build failure"):
        service.rename(page.id, "new-public")

    assert (tmp_path / "content" / "old-public.md").exists()
    assert not (tmp_path / "content" / "new-public.md").exists()
    assert (tmp_path / "content" / ".authoring-redirects.json").read_bytes() == metadata_before


def test_failed_rename_swap_restores_existing_redirect_metadata(tmp_path):
    service = service_for(tmp_path)
    page = service.save_draft(SaveRequest(page_type="named", name="old-public", body="本文"))
    service.publish(PublishRequest(page.id))
    service.rename(page.id, "current-public")
    service.publisher = FailingSwapPublisher(tmp_path / "site")

    with pytest.raises(PublishError, match="simulated swap failure"):
        service.rename(page.id, "next-public")

    restarted = service_for(tmp_path)
    later = restarted.save_draft(
        SaveRequest(page_type="date", page_date=date(2026, 1, 2), body="後続公開")
    )
    restarted.publish(PublishRequest(later.id))

    redirect = (tmp_path / "site" / "old-public" / "index.html").read_text(encoding="utf-8")
    assert 'url=/current-public' in redirect
    assert (tmp_path / "content" / "current-public.md").exists()
    assert not (tmp_path / "content" / "next-public.md").exists()


JST = ZoneInfo("Asia/Tokyo")


class FailingPublisher(StaticPublisher):
    def build(self, snapshot, destination):
        raise PublishError("simulated build failure")


class FailingSwapPublisher(StaticPublisher):
    def swap(self, destination):
        raise PublishError("simulated swap failure")


def new_date_request(body: str = "") -> SaveRequest:
    return SaveRequest(page_type="date", page_date=date(2026, 1, 1), body=body)


def service_for(tmp_path, clock=None):
    current_clock = clock or (lambda: datetime(2026, 1, 1, 12, 0, tzinfo=JST))
    repository = ContentRepository(
        tmp_path / "content",
        tmp_path / "data" / "index" / "authoring.sqlite3",
        current_clock,
    )
    from log_migration.authoring.service import AuthoringService

    return AuthoringService(
        repository,
        AuthoringDatabase(tmp_path / "data" / "index" / "authoring.sqlite3"),
        StaticPublisher(tmp_path / "site"),
        current_clock,
    )
