import re
from datetime import date
from pathlib import Path
from urllib.parse import quote

from .models import PageType


_DATE_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def validate_page_name(name: str) -> str:
    if not isinstance(name, str):
        raise ValueError("page name must be a string")
    normalized = name.strip()
    if not normalized:
        raise ValueError("page name must not be empty")
    if any(character in normalized for character in "/?#\r\n"):
        raise ValueError("page name contains a forbidden character")
    if any(ord(character) < 32 or ord(character) == 127 for character in normalized):
        raise ValueError("page name contains a control character")
    if _DATE_NAME.fullmatch(normalized):
        raise ValueError("date-shaped names are reserved")
    if "[[" in normalized or "]]" in normalized or normalized.startswith("---") or ":" in normalized:
        raise ValueError("page name collides with document syntax")
    return normalized


def encoded_page_name(name: str) -> str:
    return quote(validate_page_name(name), safe="-._~")


def page_path(
    content_dir: Path,
    page_type: PageType,
    name: str | None,
    page_date: date | None,
) -> Path:
    if page_type == "named":
        if name is None:
            raise ValueError("named pages require a name")
        return content_dir / f"{encoded_page_name(name)}.md"
    if page_type == "date":
        if page_date is None:
            raise ValueError("date pages require a date")
        return content_dir / f"{page_date.isoformat()}.md"
    raise ValueError(f"unknown page type: {page_type}")
