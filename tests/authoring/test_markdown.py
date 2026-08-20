from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from log_migration.authoring.markdown import render_markdown, render_page
from log_migration.authoring.models import PageDocument


TOKYO = ZoneInfo("Asia/Tokyo")


def document(*, name: str, body: str, title: str | None = None) -> PageDocument:
    return PageDocument(
        id=name,
        page_type="named",
        name=name,
        page_date=None,
        title=title,
        status="draft",
        created_at=datetime(2026, 1, 1, tzinfo=TOKYO),
        updated_at=datetime(2026, 1, 1, tzinfo=TOKYO),
        published_at=None,
        path=Path(f"content/{name}.md"),
        body=body,
    )


def test_local_markdown_has_extensions_and_safe_wiki_link():
    html = render_markdown(
        "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- [ ] todo\n\n~~old~~\n\n[[page-a]]",
        mode="local",
    ).html

    assert "<table>" in html
    assert 'type="checkbox"' in html
    assert "<del>old</del>" in html
    assert 'href="/page-a"' in html
    assert 'target="_blank"' in html
    assert 'rel="noreferrer"' in html
    assert "<script>" not in render_markdown("<script>alert(1)</script>", mode="local").html


def test_markdown_highlights_known_code_and_escapes_unknown_code():
    rendered = render_markdown(
        "```python\nprint('hello')\n```\n\n```not-a-language\n<unsafe>\n```",
        mode="local",
    )

    assert "highlight" in rendered.html
    assert "print" in rendered.html
    assert "&lt;unsafe&gt;" in rendered.html
    assert "<unsafe>" not in rendered.html


def test_public_markdown_links_use_the_same_tab_and_code_fences_keep_wiki_text():
    rendered = render_markdown("[[page-a]]\n\n```md\n[[ignored]]\n```", mode="public")

    assert 'href="/page-a"' in rendered.html
    assert 'target="_blank"' not in rendered.html
    assert 'rel="noreferrer"' not in rendered.html
    assert tuple(link.name for link in rendered.links) == ("page-a",)
    assert "[[ignored]]" in rendered.html


def test_invalid_wiki_links_are_reported_without_becoming_links():
    rendered = render_markdown("[[bad/name]]", mode="local")

    assert rendered.problems == ("page name contains a forbidden character",)
    assert "href=" not in rendered.html


def test_render_page_includes_escaped_title_body_and_backlinks():
    page = document(name="page-a", title=None, body="本文 <title> [[page-b]]")
    backlink = document(name="page-b", title=None, body="")

    html = render_page(page, (backlink,), mode="local")

    assert "&lt;title&gt;" in html
    assert "本文" in html
    assert "リンク元" in html
    assert 'href="/page-b"' in html
    assert 'target="_blank"' in html
