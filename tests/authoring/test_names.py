from datetime import date, datetime, timezone

import pytest

from log_migration.authoring.names import (
    encoded_page_name,
    page_path,
    validate_page_name,
)


@pytest.mark.parametrize("name", ["", "2026-01-01", "a/b", "a?b", "a#b", "a\nb", "a\x00b"])
def test_invalid_page_names_are_rejected(name):
    with pytest.raises(ValueError):
        validate_page_name(name)


def test_page_names_are_trimmed_but_case_sensitive():
    assert validate_page_name(" page-a ") == "page-a"
    assert validate_page_name("Page-A") == "Page-A"


def test_named_page_path_is_url_encoded_and_date_path_is_fixed(tmp_path):
    assert encoded_page_name("page-a") == "page-a"
    assert encoded_page_name("日本語 page") == "%E6%97%A5%E6%9C%AC%E8%AA%9E%20page"
    assert page_path(tmp_path, "named", "page-a", None) == tmp_path / "page-a.md"
    assert page_path(tmp_path, "date", None, date(2026, 1, 1)) == tmp_path / "2026-01-01.md"


def test_page_name_rejects_syntax_delimiters():
    for name in ["[[page-a]]", "---", "status: draft"]:
        with pytest.raises(ValueError):
            validate_page_name(name)


def test_date_page_path_rejects_datetime(tmp_path):
    with pytest.raises(ValueError):
        page_path(tmp_path, "date", None, datetime(2026, 1, 1, tzinfo=timezone.utc))
