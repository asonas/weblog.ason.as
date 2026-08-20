from datetime import date

import pytest

from log_migration.authoring.models import ConflictError, SaveRequest

from .support import new_date_request, repository_for, repository_with_date_page


def test_first_date_save_creates_only_the_date_source_file(tmp_path):
    repository = repository_for(tmp_path)

    page = repository.save_draft(new_date_request(date(2026, 1, 1), "本文"))

    assert page.path == tmp_path / "content" / "2026-01-01.md"
    assert tuple(path.name for path in (tmp_path / "content").iterdir()) == (
        "2026-01-01.md",
    )
    assert repository.find_route("/2026-01-01") == page


def test_second_date_page_for_same_day_is_rejected(tmp_path):
    repository = repository_with_date_page(tmp_path, date(2026, 1, 1))

    with pytest.raises(ConflictError, match="2026-01-01"):
        repository.save_draft(new_date_request(date(2026, 1, 1)))


def test_saving_wiki_link_creates_an_empty_named_draft(tmp_path):
    repository = repository_for(tmp_path)

    repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))

    linked_page = repository.find_route("/page-a")
    assert linked_page is not None
    assert linked_page.status == "draft"
    assert linked_page.is_empty
    assert linked_page.path.read_text(encoding="utf-8").endswith("---\n")


def test_invalid_external_document_is_reported_without_overwrite(tmp_path):
    path = tmp_path / "content" / "2026-01-01.md"
    path.parent.mkdir()
    original = "---\nstatus: broken\n---\n本文\n"
    path.write_text(original, encoding="utf-8")

    snapshot = repository_for(tmp_path).refresh()

    assert snapshot.problems[0].path == path
    assert path.read_bytes() == original.encode()


def test_rename_collision_leaves_all_source_files_unchanged(tmp_path):
    repository = repository_for(tmp_path)
    first = repository.save_draft(SaveRequest(page_type="named", name="page-a", body="本文"))
    repository.save_draft(SaveRequest(page_type="named", name="page-b", body="本文"))
    before = {path: path.read_bytes() for path in (tmp_path / "content").glob("*.md")}

    with pytest.raises(ConflictError, match="page-b"):
        repository.rename_named_page(first.id, "page-b")

    assert {path: path.read_bytes() for path in (tmp_path / "content").glob("*.md")} == before
    assert repository.find_route("/page-a").id == first.id


def test_rename_updates_source_links_and_preserves_the_page_id(tmp_path):
    repository = repository_for(tmp_path)
    source = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    target = repository.find_route("/page-a")
    assert target is not None

    renamed = repository.rename_named_page(target.id, "page-b")

    assert renamed.id == target.id
    assert renamed.path == tmp_path / "content" / "page-b.md"
    assert not (tmp_path / "content" / "page-a.md").exists()
    assert "[[page-b]]" in source.path.read_text(encoding="utf-8")


def test_rename_restores_source_files_when_file_transaction_fails(tmp_path, monkeypatch):
    repository = repository_for(tmp_path)
    source = repository.save_draft(new_date_request(date(2026, 1, 1), "[[page-a]]"))
    target = repository.find_route("/page-a")
    assert target is not None
    before = {path: path.read_bytes() for path in (tmp_path / "content").glob("*.md")}

    import log_migration.authoring.repository as repository_module

    original_replace = repository_module.os.replace
    calls = 0

    def fail_second_replace(source_path, destination_path):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("simulated write failure")
        original_replace(source_path, destination_path)

    monkeypatch.setattr(repository_module.os, "replace", fail_second_replace)

    with pytest.raises(OSError, match="simulated write failure"):
        repository.rename_named_page(target.id, "page-b")

    assert {path: path.read_bytes() for path in (tmp_path / "content").glob("*.md")} == before
    assert "[[page-a]]" in source.path.read_text(encoding="utf-8")
