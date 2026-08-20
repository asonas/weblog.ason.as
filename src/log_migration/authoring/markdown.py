import html
from dataclasses import dataclass
from typing import Literal
from uuid import uuid4

from markdown_it import MarkdownIt
from mdit_py_plugins.tasklists import tasklists_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

from .links import extract_wiki_links
from .models import PageDocument, WikiLink
from .names import encoded_page_name, validate_page_name


Mode = Literal["local", "public"]
_SENTINEL_PREFIX = "https://weblog.invalid/wiki/"


@dataclass(frozen=True)
class RenderedBody:
    html: str
    links: tuple[WikiLink, ...]
    problems: tuple[str, ...]


def render_markdown(body: str, *, mode: Mode) -> RenderedBody:
    links = extract_wiki_links(body)
    rendered_body, replacements, problems = _replace_valid_wiki_links(
        body, links, f"{_SENTINEL_PREFIX}{uuid4().hex}/"
    )
    output = _markdown().render(rendered_body)
    for sentinel, route in replacements:
        output = output.replace(sentinel, route)
    if mode == "local":
        output = output.replace("<a ", '<a target="_blank" rel="noreferrer" ')
    return RenderedBody(html=output, links=links, problems=tuple(problems))


def render_page(page: PageDocument, backlinks: tuple[PageDocument, ...], *, mode: Mode) -> str:
    body = render_markdown(page.body, mode=mode).html
    title = html.escape(page.display_title)
    backlinks_html = ""
    if backlinks:
        backlink_items = "".join(
            f'<li><a href="{_page_url(backlink)}">{html.escape(backlink.display_title)}</a></li>'
            for backlink in backlinks
        )
        backlinks_html = f'<aside class="backlinks"><h2>リンク元</h2><ul>{backlink_items}</ul></aside>'
        if mode == "local":
            backlinks_html = backlinks_html.replace(
                "<a ", '<a target="_blank" rel="noreferrer" '
            )
    return f"<article><h1>{title}</h1>{body}</article>{backlinks_html}"


def _markdown() -> MarkdownIt:
    markdown = MarkdownIt("default", {"breaks": True, "html": False})
    markdown.use(tasklists_plugin)
    markdown.renderer.rules["s_open"] = _open_strikethrough
    markdown.renderer.rules["s_close"] = _close_strikethrough
    markdown.options["highlight"] = _highlight_code
    return markdown


def _highlight_code(code: str, language: str, _attrs: str = "") -> str:
    if not language:
        return f"<pre><code>{html.escape(code)}</code></pre>"
    try:
        lexer = get_lexer_by_name(language, stripall=True)
    except ClassNotFound:
        return f"<pre><code>{html.escape(code)}</code></pre>"
    return highlight(code, lexer, HtmlFormatter())


def _open_strikethrough(_tokens, _index, _options, _environment) -> str:
    return "<del>"


def _close_strikethrough(_tokens, _index, _options, _environment) -> str:
    return "</del>"


def _replace_valid_wiki_links(
    body: str, links: tuple[WikiLink, ...], sentinel_prefix: str
) -> tuple[str, tuple[tuple[str, str], ...], list[str]]:
    replacements: list[tuple[str, str]] = []
    problems: list[str] = []
    for link in reversed(links):
        try:
            name = validate_page_name(link.name)
        except ValueError as error:
            problems.append(str(error))
            continue
        sentinel = f"{sentinel_prefix}{encoded_page_name(name)}"
        body = f"{body[:link.start]}[{name}]({sentinel}){body[link.end:]}"
        replacements.append((sentinel, f"/{encoded_page_name(name)}"))
    replacements.reverse()
    problems.reverse()
    return body, tuple(replacements), problems


def _page_url(page: PageDocument) -> str:
    if page.page_type == "named":
        return f"/{encoded_page_name(page.name or '')}"
    return f"/{page.route}"
