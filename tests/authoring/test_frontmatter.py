from datetime import date, datetime, timezone

import pytest

from log_migration.authoring.frontmatter import parse_document, serialize_document
from log_migration.authoring.models import PageDocument, PageProblem


def test_date_document_round_trips_frontmatter_and_body(tmp_path):
    path = tmp_path / "2026-01-01.md"
    document = PageDocument(
        id="page-id",
        page_type="date",
        name=None,
        page_date=date(2026, 1, 1),
        title="A day",
        status="draft",
        created_at=datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc),
        updated_at=datetime(2026, 1, 2, 0, 0, tzinfo=timezone.utc),
        published_at=None,
        path=path,
        body="本文\n",
    )

    parsed = parse_document(path, serialize_document(document))

    assert parsed == document


def test_named_document_uses_name_as_display_title(tmp_path):
    document = PageDocument(
        id="page-id",
        page_type="named",
        name="page-a",
        page_date=None,
        title=None,
        status="published",
        created_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        updated_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        published_at=datetime(2026, 1, 1, tzinfo=timezone.utc),
        path=tmp_path / "page-a.md",
        body="",
    )
    assert document.display_title == "page-a"


def test_invalid_status_returns_page_problem(tmp_path):
    result = parse_document(
        tmp_path / "page-a.md",
        "---\nid: page-id\npage_type: named\nname: page-a\nstatus: broken\n---\nbody\n",
    )
    assert isinstance(result, PageProblem)
    assert "status" in result.detail


def test_missing_id_returns_page_problem(tmp_path):
    result = parse_document(
        tmp_path / "page-a.md",
        "---\npage_type: named\nname: page-a\nstatus: draft\n---\nbody\n",
    )
    assert isinstance(result, PageProblem)
    assert "id" in result.detail


def test_date_document_rejects_datetime_page_date(tmp_path):
    result = parse_document(
        tmp_path / "2026-01-01.md",
        "---\n"
        "id: page-id\n"
        "page_type: date\n"
        "page_date: 2026-01-01T00:00:00+00:00\n"
        "status: draft\n"
        "created_at: 2026-01-01T00:00:00+00:00\n"
        "updated_at: 2026-01-01T00:00:00+00:00\n"
        "---\nbody\n",
    )
    assert isinstance(result, PageProblem)
    assert "page_date" in result.detail


@pytest.mark.parametrize(
    "frontmatter, expected",
    [
        ("page_type: date\npage_date: null\n", "page_date"),
        ("page_type: named\nname: null\n", "name"),
    ],
)
def test_document_requires_identity_for_its_page_type(tmp_path, frontmatter, expected):
    result = parse_document(
        tmp_path / "page.md",
        "---\n"
        "id: page-id\n"
        f"{frontmatter}"
        "status: draft\n"
        "created_at: 2026-01-01T00:00:00+00:00\n"
        "updated_at: 2026-01-01T00:00:00+00:00\n"
        "---\nbody\n",
    )
    assert isinstance(result, PageProblem)
    assert expected in result.detail
