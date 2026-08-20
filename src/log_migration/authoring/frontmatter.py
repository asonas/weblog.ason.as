from datetime import date, datetime
from pathlib import Path
from typing import Any

import yaml

from .models import PageDocument, PageProblem


_REQUIRED = {"id", "page_type", "status", "created_at", "updated_at"}


def _problem(path: Path, detail: str) -> PageProblem:
    return PageProblem(path=path, detail=detail)


def parse_document(path: Path, text: str) -> PageDocument | PageProblem:
    if not text.startswith("---\n"):
        return _problem(path, "frontmatter is missing")
    marker = text.find("\n---\n", 4)
    if marker < 0:
        return _problem(path, "frontmatter is not closed")
    try:
        values = yaml.safe_load(text[4:marker])
    except yaml.YAMLError as error:
        return _problem(path, f"frontmatter is invalid: {error}")
    if not isinstance(values, dict):
        return _problem(path, "frontmatter must be a mapping")
    if "id" not in values:
        return _problem(path, "missing required key: id")
    if "page_type" in values and values["page_type"] not in ("date", "named"):
        return _problem(path, "page_type must be date or named")
    if "status" in values and values["status"] not in ("draft", "published"):
        return _problem(path, "status must be draft or published")
    missing = _REQUIRED - values.keys()
    if missing:
        return _problem(path, f"missing required key: {sorted(missing)[0]}")
    if not isinstance(values["id"], str) or not values["id"]:
        return _problem(path, "id must be a non-empty string")
    if not all(isinstance(values[key], datetime) for key in ("created_at", "updated_at")):
        return _problem(path, "created_at and updated_at must be datetimes")
    page_date = values.get("page_date")
    if isinstance(page_date, datetime) or (
        page_date is not None and not isinstance(page_date, date)
    ):
        return _problem(path, "page_date must be a date")
    published_at = values.get("published_at")
    if published_at is not None and not isinstance(published_at, datetime):
        return _problem(path, "published_at must be a datetime")
    name = values.get("name")
    title = values.get("title")
    if name is not None and not isinstance(name, str):
        return _problem(path, "name must be a string")
    if title is not None and not isinstance(title, str):
        return _problem(path, "title must be a string")
    if values["page_type"] == "date" and page_date is None:
        return _problem(path, "date pages require page_date")
    if values["page_type"] == "named" and not name:
        return _problem(path, "named pages require name")
    return PageDocument(
        id=values["id"],
        page_type=values["page_type"],
        name=name,
        page_date=page_date,
        title=title,
        status=values["status"],
        created_at=values["created_at"],
        updated_at=values["updated_at"],
        published_at=published_at,
        path=path,
        body=text[marker + len("\n---\n") :],
    )


def serialize_document(document: PageDocument) -> str:
    values: dict[str, Any] = {
        "id": document.id,
        "page_type": document.page_type,
        "name": document.name,
        "page_date": document.page_date,
        "title": document.title,
        "status": document.status,
        "created_at": document.created_at,
        "updated_at": document.updated_at,
        "published_at": document.published_at,
    }
    frontmatter = yaml.safe_dump(values, sort_keys=False, allow_unicode=True)
    return f"---\n{frontmatter}---\n{document.body}"
