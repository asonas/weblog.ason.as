import hashlib
import re
import sqlite3
from datetime import date
from pathlib import Path
from typing import Literal


_POST_LINK = re.compile(r"\]\(/posts/([^/]+)/\)")


def stable_asset_id(source_path: str) -> str:
    return f"asset_{hashlib.sha256(source_path.encode('utf-8')).hexdigest()[:16]}"


class LinkIndex:
    def __init__(self, connection: sqlite3.Connection):
        self._connection = connection

    def find_backlinks(self, target_id: str) -> list[str]:
        rows = self._connection.execute(
            "SELECT source_id FROM edges WHERE target_id = ? ORDER BY source_id",
            (target_id,),
        ).fetchall()
        return [row[0] for row in rows]

    def directions_between(self, first_id: str, second_id: str) -> tuple[str, ...]:
        directions: list[str] = []
        outgoing = self._connection.execute(
            "SELECT 1 FROM edges WHERE source_id = ? AND target_id = ? LIMIT 1",
            (first_id, second_id),
        ).fetchone()
        incoming = self._connection.execute(
            "SELECT 1 FROM edges WHERE source_id = ? AND target_id = ? LIMIT 1",
            (second_id, first_id),
        ).fetchone()
        if incoming is not None:
            directions.append("incoming")
        if outgoing is not None:
            directions.append("outgoing")
        return tuple(directions)

    def neighbors(
        self,
        root_id: str,
        *,
        direction: Literal["incoming", "outgoing", "both"] = "both",
        depth: int = 1,
        start_date: str | date | None = None,
        end_date: str | date | None = None,
    ) -> list[str]:
        if depth <= 0:
            return []

        visited = {root_id}
        frontier = [root_id]
        found: list[str] = []

        for _ in range(depth):
            next_frontier: list[str] = []
            for node_id in frontier:
                for neighbor_id in self._adjacent(node_id, direction):
                    if neighbor_id in visited:
                        continue
                    visited.add(neighbor_id)
                    next_frontier.append(neighbor_id)
                    if self._matches_date_range(neighbor_id, start_date, end_date):
                        found.append(neighbor_id)
            frontier = next_frontier
            if not frontier:
                break

        return found

    def _adjacent(
        self,
        node_id: str,
        direction: Literal["incoming", "outgoing", "both"],
    ) -> list[str]:
        neighbors: set[str] = set()
        if direction in ("outgoing", "both"):
            rows = self._connection.execute(
                "SELECT target_id FROM edges WHERE source_id = ?",
                (node_id,),
            ).fetchall()
            neighbors.update(row[0] for row in rows)
        if direction in ("incoming", "both"):
            rows = self._connection.execute(
                "SELECT source_id FROM edges WHERE target_id = ?",
                (node_id,),
            ).fetchall()
            neighbors.update(row[0] for row in rows)
        return sorted(neighbors)

    def _matches_date_range(
        self,
        node_id: str,
        start_date: str | date | None,
        end_date: str | date | None,
    ) -> bool:
        if start_date is None and end_date is None:
            return True

        row = self._connection.execute(
            "SELECT created_at FROM posts WHERE id = ?",
            (node_id,),
        ).fetchone()
        if row is None:
            return True
        if row[0] is None:
            return False

        value = row[0][:10]
        start = _date_text(start_date)
        end = _date_text(end_date)
        return (start is None or value >= start) and (end is None or value <= end)


def build_index(normalized, database_path: Path) -> LinkIndex:
    database_path = Path(database_path)
    database_path.parent.mkdir(parents=True, exist_ok=True)
    if database_path.exists():
        database_path.unlink()

    connection = sqlite3.connect(database_path)
    connection.executescript(
        """
        CREATE TABLE posts (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            created_at TEXT,
            updated_at TEXT,
            published_at TEXT,
            visibility TEXT NOT NULL,
            path TEXT NOT NULL
        );
        CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            source_path TEXT NOT NULL,
            mime_type TEXT,
            path TEXT
        );
        CREATE TABLE edges (
            source_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            edge_kind TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (source_id, target_id, edge_kind, position)
        );
        CREATE TABLE issues (
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE INDEX edges_source_idx ON edges (source_id);
        CREATE INDEX edges_target_idx ON edges (target_id);
        CREATE INDEX posts_created_idx ON posts (created_at);
        """
    )

    for post in normalized.posts:
        frontmatter = post.frontmatter
        connection.execute(
            """
            INSERT INTO posts
                (id, title, created_at, updated_at, published_at, visibility, path)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                post.id,
                frontmatter["title"],
                frontmatter["created_at"],
                frontmatter["updated_at"],
                frontmatter["published_at"],
                frontmatter["visibility"],
                f"posts/{post.id}.md",
            ),
        )

        source_project = str(frontmatter["source_project"])
        for position, target_title in enumerate(post.links):
            target_id = normalized.mapping.get(f"{source_project}\x00{target_title}")
            if target_id is not None:
                connection.execute(
                    "INSERT INTO edges VALUES (?, ?, ?, ?)",
                    (post.id, target_id, "post_reference", position),
                )

        for position, source_path in enumerate(post.asset_references):
            asset_id = stable_asset_id(source_path)
            connection.execute(
                "INSERT OR IGNORE INTO assets (id, source_path) VALUES (?, ?)",
                (asset_id, source_path),
            )
            connection.execute(
                "INSERT INTO edges VALUES (?, ?, ?, ?)",
                (post.id, asset_id, "asset_reference", position),
            )

        for issue in post.issues:
            connection.execute(
                "INSERT INTO issues VALUES (?, ?, ?)",
                (issue.kind, issue.source, issue.detail),
            )

    connection.commit()
    return LinkIndex(connection)


def _date_text(value: str | date | None) -> str | None:
    if value is None:
        return None
    return value.isoformat() if isinstance(value, date) else value
