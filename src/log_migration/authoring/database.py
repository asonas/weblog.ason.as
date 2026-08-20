import hashlib
import sqlite3
from datetime import datetime
from pathlib import Path

from .models import PageDocument, Status


class AuthoringDatabase:
    def __init__(self, path: Path):
        self.path = path
        self._pages: dict[str, PageDocument] = {}

    def connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        return sqlite3.connect(self.path)

    def rebuild(self, snapshot: "RepositorySnapshot") -> None:
        self._pages = {page.id: page for page in snapshot.pages}
        by_name = {page.name: page.id for page in snapshot.pages if page.name is not None}
        with self.connect() as connection:
            connection.executescript(
                """
                DROP TABLE IF EXISTS links;
                DROP TABLE IF EXISTS pages;
                DROP TABLE IF EXISTS problems;
                CREATE TABLE pages (
                    id TEXT PRIMARY KEY,
                    page_type TEXT NOT NULL,
                    name TEXT,
                    page_date TEXT,
                    title TEXT,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    published_at TEXT,
                    path TEXT NOT NULL,
                    body_hash TEXT NOT NULL,
                    is_empty INTEGER NOT NULL
                );
                CREATE TABLE links (
                    source_id TEXT NOT NULL,
                    target_id TEXT,
                    target_name TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (source_id, position)
                );
                CREATE TABLE problems (
                    path TEXT PRIMARY KEY,
                    detail TEXT NOT NULL
                );
                """
            )
            connection.executemany(
                """
                INSERT INTO pages VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        page.id,
                        page.page_type,
                        page.name,
                        page.page_date.isoformat() if page.page_date else None,
                        page.title,
                        page.status,
                        page.created_at.isoformat(),
                        page.updated_at.isoformat(),
                        page.published_at.isoformat() if page.published_at else None,
                        str(page.path),
                        hashlib.sha256(page.body.encode()).hexdigest(),
                        int(page.is_empty),
                    )
                    for page in snapshot.pages
                ],
            )
            connection.executemany(
                "INSERT INTO links VALUES (?, ?, ?, ?)",
                [
                    (page.id, by_name.get(link.name), link.name, position)
                    for page in snapshot.pages
                    for position, link in enumerate(page.links)
                ],
            )
            connection.executemany(
                "INSERT INTO problems VALUES (?, ?)",
                [(str(problem.path), problem.detail) for problem in snapshot.problems],
            )

    def backlinks(self, target_id: str, public_only: bool) -> tuple[PageDocument, ...]:
        query = """
            SELECT DISTINCT pages.id
            FROM links JOIN pages ON pages.id = links.source_id
            WHERE links.target_id = ?
        """
        parameters: list[str] = [target_id]
        if public_only:
            query += " AND pages.status = ?"
            parameters.append("published")
        query += " ORDER BY pages.path"
        with self.connect() as connection:
            ids = [row[0] for row in connection.execute(query, parameters)]
        return tuple(self._document_for(page_id) for page_id in ids)

    def search(self, query: str, status: Status | None) -> tuple[PageDocument, ...]:
        clauses = []
        parameters: list[str] = []
        if query:
            clauses.append("(name LIKE ? OR title LIKE ? OR page_date LIKE ?)")
            pattern = f"%{query}%"
            parameters.extend((pattern, pattern, pattern))
        if status is not None:
            clauses.append("status = ?")
            parameters.append(status)
        statement = "SELECT id FROM pages"
        if clauses:
            statement += " WHERE " + " AND ".join(clauses)
        statement += " ORDER BY path"
        with self.connect() as connection:
            ids = [row[0] for row in connection.execute(statement, parameters)]
        return tuple(self._document_for(page_id) for page_id in ids)

    def _document_for(self, page_id: str) -> PageDocument:
        document = self._pages.get(page_id)
        if document is not None:
            return document
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT id, page_type, name, page_date, title, status, created_at,
                       updated_at, published_at, path
                FROM pages WHERE id = ?
                """,
                (page_id,),
            ).fetchone()
        if row is None:
            raise KeyError(page_id)
        from datetime import date

        return PageDocument(
            id=row[0],
            page_type=row[1],
            name=row[2],
            page_date=date.fromisoformat(row[3]) if row[3] else None,
            title=row[4],
            status=row[5],
            created_at=datetime.fromisoformat(row[6]),
            updated_at=datetime.fromisoformat(row[7]),
            published_at=datetime.fromisoformat(row[8]) if row[8] else None,
            path=Path(row[9]),
            body="",
        )
