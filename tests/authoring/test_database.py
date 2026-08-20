from datetime import date

from log_migration.authoring.database import AuthoringDatabase
from log_migration.authoring.models import SaveRequest

from .support import new_date_request, repository_for


def test_rebuild_restores_index_after_database_file_is_deleted(tmp_path):
    repository = repository_for(tmp_path)
    source = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    database = AuthoringDatabase(tmp_path / "data" / "index" / "authoring.sqlite3")
    database.rebuild(repository.refresh())
    database.path.unlink()

    database.rebuild(repository.refresh())

    target = repository.find_route("/page-a")
    assert target is not None
    assert database.backlinks(target.id, public_only=False) == (source,)


def test_backlinks_can_exclude_draft_sources_and_search_filters_status(tmp_path):
    repository = repository_for(tmp_path)
    draft = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    published = repository.save_draft(SaveRequest(page_type="named", name="published", body="[[page-a]]"))
    published = repository.save_draft(
        SaveRequest(page_type="named", page_id=published.id, name="published", body="[[page-a]]")
    )
    published_path = published.path
    source = published_path.read_text(encoding="utf-8").replace("status: draft", "status: published")
    published_path.write_text(source, encoding="utf-8")
    snapshot = repository.refresh()
    database = AuthoringDatabase(tmp_path / "data" / "index" / "authoring.sqlite3")
    database.rebuild(snapshot)

    target = repository.find_route("/page-a")
    refreshed_draft = repository.get_page(draft.id)
    refreshed_published = repository.get_page(published.id)
    assert target is not None
    assert database.backlinks(target.id, public_only=False) == (refreshed_draft, refreshed_published)
    assert database.backlinks(target.id, public_only=True) == (refreshed_published,)
    assert database.search("publish", "published") == (refreshed_published,)
    assert database.search("2026-01-01", "draft") == (refreshed_draft,)


def test_rebuild_stores_problems_but_not_document_bodies(tmp_path):
    repository = repository_for(tmp_path)
    content = tmp_path / "content"
    content.mkdir()
    (content / "broken.md").write_text("---\nstatus: broken\n---\nsecret body", encoding="utf-8")
    page = repository.save_draft(new_date_request(date(2026, 1, 1), "visible body"))
    database = AuthoringDatabase(tmp_path / "data" / "index" / "authoring.sqlite3")

    database.rebuild(repository.refresh())

    assert database.search("2026-01-01", None) == (page,)
    with database.connect() as connection:
        dumped = " ".join(str(value) for row in connection.execute("SELECT * FROM pages") for value in row)
        problems = connection.execute("SELECT path, detail FROM problems").fetchall()
    assert "visible body" not in dumped
    assert problems == [(str(content / "broken.md"), "missing required key: id")]
