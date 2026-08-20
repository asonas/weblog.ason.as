import re

from .models import WikiLink


_LINK = re.compile(r"\[\[([^\[\]]+)\]\]")
_FENCE = re.compile(r"^\s*(`{3,}|~{3,})")


def _segments(body: str):
    offset = 0
    fence: tuple[str, int] | None = None
    for line in body.splitlines(keepends=True):
        match = _FENCE.match(line)
        was_fenced = fence is not None
        if match is not None:
            marker = match.group(1)
            marker_type = marker[0]
            marker_length = len(marker)
            if fence is None:
                fence = (marker_type, marker_length)
            elif marker_type == fence[0] and marker_length >= fence[1]:
                fence = None
        yield line, offset, was_fenced or match is not None
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
