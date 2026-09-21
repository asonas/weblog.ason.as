export type WikiLinkQuery = {
  from: number;
  to: number;
  value: string;
};

export type TextareaEdit = {
  value: string;
  selectionStart: number;
  selectionEnd: number;
};

export function textareaWikiLinkQuery(
  value: string,
  selectionStart: number,
  selectionEnd = selectionStart,
): WikiLinkQuery | null {
  if (selectionStart !== selectionEnd) return null;
  const lineStart = value.lastIndexOf("\n", selectionStart - 1) + 1;
  const beforeCursor = value.slice(lineStart, selectionStart);
  const match = /\[\[([^[\]\n]*)$/.exec(beforeCursor);
  if (!match) return null;
  const remainder =
    /^[^[\]\n]*\]\]/.exec(value.slice(selectionStart))?.[0] || "";
  return {
    from: selectionStart - match[1].length,
    to: selectionStart + remainder.length,
    value: match[1],
  };
}

export function markdownBlockIndexAt(value: string, cursor: number): number {
  const beforeCursor = value.slice(0, cursor);
  const blocks = beforeCursor.split(/\n\s*\n/);
  return Math.max(0, blocks.length - 1);
}

export function wrapTextareaSelectionInWikiLink(
  value: string,
  selectionStart: number,
  selectionEnd: number,
): TextareaEdit | null {
  if (selectionStart === selectionEnd) return null;
  const selected = value.slice(selectionStart, selectionEnd);
  return {
    value: `${value.slice(0, selectionStart)}[[${selected}]]${value.slice(selectionEnd)}`,
    selectionStart: selectionStart + 2,
    selectionEnd: selectionEnd + 2,
  };
}
