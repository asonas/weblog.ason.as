from dataclasses import dataclass
from datetime import datetime


@dataclass(frozen=True)
class ScrapboxPage:
    project: str
    title: str
    lines: tuple[str, ...]
    created_at: datetime | None
    updated_at: datetime | None
    links: tuple[str, ...]
    asset_references: tuple[str, ...]
    source_url: str


@dataclass(frozen=True)
class ScrapboxProject:
    name: str
    pages: tuple[ScrapboxPage, ...]
