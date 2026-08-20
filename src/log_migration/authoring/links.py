import re

from .models import WikiLink


_LINK = re.compile(r"\[\[([^\[\]]+)\]\]")
_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def _segments(body: str):
    offset = 0
    fenced = False
    for line in body.splitlines(keepends=True):
        is_fence = _FENCE.match(line) is not None
        if is_fence:
            fenced = not fenced
        yield line, offset, fenced or is_fence
        offset += len(line)


def extract_wiki_links(body: str) -> tuple[WikiLink, ...]:
    links: list[WikiLink] = []
    for line, offset, fenced in _segments(body):
        if fenced:
            continue
        for match in _LINK.finditer(line):
            name = match.group(1).strip()
            if name:
                links.append(WikiLink(name=name, start=offset + match.start(), end=offset + match.end()))
    return tuple(links)


def replace_wiki_links(body: str, old_name: str, new_name: str) -> str:
    replacements: list[tuple[int, int]] = []
    for link in extract_wiki_links(body):
        if link.name == old_name:
            replacements.append((link.start, link.end))
    for start, end in reversed(replacements):
        body = f"{body[:start]}[[{new_name}]]{body[end:]}"
    return body
