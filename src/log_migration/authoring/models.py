from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Literal


PageType = Literal["date", "named"]
Status = Literal["draft", "published"]


@dataclass(frozen=True)
class WikiLink:
    name: str
    start: int = 0
    end: int = 0


@dataclass(frozen=True)
class PageDocument:
    id: str
    page_type: PageType
    name: str | None
    page_date: date | None
    title: str | None
    status: Status
    created_at: datetime
    updated_at: datetime
    published_at: datetime | None
    path: Path
    body: str
    links: tuple[WikiLink, ...] = ()

    @property
    def display_title(self) -> str:
        if self.page_type == "named":
            return self.name or ""
        return self.title or (self.page_date.isoformat() if self.page_date else "")

    @property
    def route(self) -> str:
        return self.name if self.page_type == "named" else self.page_date.isoformat()

    @property
    def is_empty(self) -> bool:
        return not self.body.strip()


@dataclass(frozen=True)
class PageProblem:
    path: Path
    detail: str


@dataclass(frozen=True)
class Redirect:
    old_route: str
    new_route: str


@dataclass(frozen=True)
class SaveRequest:
    page_type: PageType
    body: str
    page_id: str | None = None
    name: str | None = None
    page_date: date | None = None
    title: str | None = None
    expected_updated_at: datetime | None = None


@dataclass(frozen=True)
class PublishRequest:
    page_id: str
    expected_updated_at: datetime | None = None


class ConflictError(Exception):
    """Raised when a requested authoring change conflicts with current state."""


class PublishError(Exception):
    """Raised when a publication cannot be started or completed."""
