from dataclasses import replace
from datetime import date

import pytest

from log_migration.authoring.models import PageProblem, PublishError, Redirect, SaveRequest
from log_migration.authoring.repository import RepositorySnapshot

from .support import new_date_request, repository_for


def test_build_excludes_draft_body_and_includes_referenced_empty_page(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "公開本文\n\n[[page-a]]"))
    target = repository.find_route("page-a")
    assert target is not None
    repository.save_draft(SaveRequest(page_type="named", page_id=target.id, body="下書き本文"))
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(published_snapshot(repository.refresh(), published.id), destination)

    assert "公開本文" in (destination / "2026-01-01" / "index.html").read_text()
    placeholder = (destination / "page-a" / "index.html").read_text()
    assert "page-a" in placeholder
    assert "まだ内容がありません" in placeholder
    assert "下書き本文" not in "".join(path.read_text() for path in destination.rglob("*.html"))


def test_build_includes_only_published_backlinks(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    draft = repository.save_draft(SaveRequest(page_type="named", name="draft-source", body="[[page-a]]"))
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(published_snapshot(repository.refresh(), published.id), destination)

    page = (destination / "page-a" / "index.html").read_text()
    assert "2026-01-01" in page
    assert draft.display_title not in page
    assert not (destination / "draft-source").exists()


def test_build_writes_redirect_only_for_published_named_page(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(SaveRequest(page_type="named", name="new-name", body="公開本文"))
    repository.save_draft(SaveRequest(page_type="named", name="draft-name", body="下書き本文"))
    snapshot = replace(
        published_snapshot(repository.refresh(), published.id),
        redirects=(
            Redirect(old_route="old-name", new_route="new-name"),
            Redirect(old_route="old-draft", new_route="draft-name"),
        ),
    )
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(snapshot, destination)

    redirect = (destination / "old-name" / "index.html").read_text()
    assert 'url=/new-name' in redirect
    assert not (destination / "old-draft").exists()


def test_build_flattens_redirect_chain_to_final_published_route(tmp_path):
    repository = repository_for(tmp_path)
    page = repository.save_draft(SaveRequest(page_type="named", name="page-c", body="本文"))
    snapshot = replace(
        published_snapshot(repository.refresh(), page.id),
        redirects=(
            Redirect(old_route="page-a", new_route="page-b"),
            Redirect(old_route="page-b", new_route="page-c"),
        ),
    )
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(snapshot, destination)

    page_a = (destination / "page-a" / "index.html").read_text(encoding="utf-8")
    page_b = (destination / "page-b" / "index.html").read_text(encoding="utf-8")
    assert 'url=/page-c' in page_a
    assert 'url=/page-c' in page_b
    assert 'url=/page-b' not in page_a


def test_build_rejects_problem_required_by_public_candidate(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    snapshot = replace(
        published_snapshot(repository.refresh(), published.id),
        problems=(PageProblem(tmp_path / "content" / "page-a.md", "broken frontmatter"),),
    )

    with pytest.raises(PublishError, match="page-a"):
        publisher(tmp_path).build(snapshot, tmp_path / "next-site")


def test_build_ignores_problem_unrelated_to_public_candidate(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "公開本文"))
    snapshot = replace(
        published_snapshot(repository.refresh(), published.id),
        problems=(PageProblem(tmp_path / "content" / "draft-only.md", "broken frontmatter"),),
    )
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(snapshot, destination)

    assert "公開本文" in (destination / "2026-01-01" / "index.html").read_text()


def test_build_url_encodes_named_page_route(tmp_path):
    repository = repository_for(tmp_path)
    page = repository.save_draft(SaveRequest(page_type="named", name="page a", body="公開本文"))
    destination = tmp_path / "next-site"

    publisher(tmp_path).build(published_snapshot(repository.refresh(), page.id), destination)

    assert (destination / "page%20a" / "index.html").exists()
    assert not (destination / "page a").exists()


def test_publish_rejects_route_that_escapes_staging_destination(tmp_path):
    repository = repository_for(tmp_path)
    page = repository.save_draft(SaveRequest(page_type="named", name="..", body="公開本文"))
    current_site = tmp_path / "site"
    current_site.mkdir()
    (current_site / "marker").write_text("before", encoding="utf-8")

    with pytest.raises(PublishError, match="escapes destination"):
        publisher(tmp_path).publish(published_snapshot(repository.refresh(), page.id))

    assert (current_site / "marker").read_text(encoding="utf-8") == "before"
    assert not (tmp_path / "index.html").exists()
    assert not tuple(tmp_path.glob("site.staging-*"))


def test_build_rejects_redirect_that_overwrites_current_public_route(tmp_path):
    repository = repository_for(tmp_path)
    page = repository.save_draft(SaveRequest(page_type="named", name="current", body="公開本文"))
    snapshot = replace(
        published_snapshot(repository.refresh(), page.id),
        redirects=(Redirect(old_route="current", new_route="current"),),
    )

    with pytest.raises(PublishError, match="redirect.*current"):
        publisher(tmp_path).build(snapshot, tmp_path / "next-site")


def test_publish_keeps_existing_site_when_swap_fails(tmp_path, monkeypatch):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "公開本文"))
    current_site = tmp_path / "site"
    current_site.mkdir()
    (current_site / "marker").write_text("before", encoding="utf-8")
    static_publisher = publisher(tmp_path)

    import log_migration.authoring.publisher as publisher_module

    original_replace = publisher_module.os.replace

    def fail_staging_swap(source, destination):
        if source.name.startswith("site.staging-") and destination == current_site:
            raise OSError("simulated swap failure")
        original_replace(source, destination)

    monkeypatch.setattr(publisher_module.os, "replace", fail_staging_swap)

    with pytest.raises(PublishError, match="simulated swap failure"):
        static_publisher.publish(published_snapshot(repository.refresh(), published.id))

    assert (current_site / "marker").read_text(encoding="utf-8") == "before"
    assert not tuple(tmp_path.glob("site.staging-*"))
    assert not tuple(tmp_path.glob("site.previous-*"))


def test_publish_does_not_create_site_when_build_fails(tmp_path):
    repository = repository_for(tmp_path)
    published = repository.save_draft(new_date_request(date(2026, 1, 1), "valid"))
    snapshot = published_snapshot(repository.refresh(), published.id)
    broken = replace(snapshot.pages[0], body="[[bad/name]]")
    snapshot = replace(snapshot, pages=(broken,))

    with pytest.raises(PublishError, match="forbidden"):
        publisher(tmp_path).publish(snapshot)

    assert not (tmp_path / "site").exists()
    assert not tuple(tmp_path.glob("site.staging-*"))


def publisher(tmp_path):
    from log_migration.authoring.publisher import StaticPublisher

    return StaticPublisher(tmp_path / "site")


def published_snapshot(snapshot: RepositorySnapshot, page_id: str) -> RepositorySnapshot:
    return replace(
        snapshot,
        pages=tuple(
            replace(page, status="published", published_at=page.updated_at)
            if page.id == page_id
            else page
            for page in snapshot.pages
        ),
    )
