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

export function markdownKeyEdit(
  value: string,
  start: number,
  end: number,
  key: "Tab" | "Enter",
  shiftKey = false,
): TextareaEdit | null {
  const lineStart = value.lastIndexOf("\n", start - 1) + 1;
  const nextBreak = value.indexOf("\n", start);
  const lineEnd = nextBreak < 0 ? value.length : nextBreak;
  const line = value.slice(lineStart, lineEnd);

  if (key === "Tab") {
    if (start === end && line.startsWith("|")) {
      const pipes = [...line.matchAll(/\|/g)].map(
        (match) => lineStart + match.index,
      );
      const currentPipe = [...pipes].reverse().find((pipe) => pipe < start);
      const target = shiftKey
        ? [...pipes].reverse().find((pipe) => pipe < (currentPipe ?? lineStart))
        : pipes.find((pipe) => pipe > start);
      const caret = shiftKey
        ? Math.min(lineEnd, (target ?? pipes[0]) + 2)
        : target === undefined || target === pipes[pipes.length - 1]
          ? lineEnd
          : Math.min(lineEnd, target + 2);
      return { value, selectionStart: caret, selectionEnd: caret };
    }
    const lastSelectedCharacter =
      end > start && value[end - 1] === "\n" ? end - 2 : end - 1;
    const lastLineStart =
      value.lastIndexOf("\n", Math.max(lineStart - 1, lastSelectedCharacter)) +
      1;
    const blockEnd = value.indexOf("\n", lastLineStart);
    const to = blockEnd < 0 ? value.length : blockEnd;
    const before = value.slice(lineStart, to);
    const replacement = shiftKey
      ? before.replace(/^ {1,4}/gm, "")
      : before.replace(/^/gm, "    ");
    if (replacement === before)
      return { value, selectionStart: start, selectionEnd: end };
    const nextValue = value.slice(0, lineStart) + replacement + value.slice(to);
    if (start === end) {
      const removed = shiftKey ? before.length - replacement.length : -4;
      const caret = Math.max(lineStart, start - removed);
      return { value: nextValue, selectionStart: caret, selectionEnd: caret };
    }
    return {
      value: nextValue,
      selectionStart: lineStart,
      selectionEnd: lineStart + replacement.length,
    };
  }

  if (shiftKey || start !== end || start === lineStart) return null;
  const marker = /^(\s*(?:[-+*]|\d+\.) (?:\[(?:x| )\] )?)/.exec(line)?.[1];
  if (marker) {
    if (!line.slice(marker.length).trim()) {
      return {
        value:
          value.slice(0, lineStart) + value.slice(lineStart + marker.length),
        selectionStart: lineStart,
        selectionEnd: lineStart,
      };
    }
    if (start >= lineStart + marker.length) {
      const nextMarker = marker
        .replace(/\[x\]/, "[ ]")
        .replace(
          /^(\s*)(\d+)\./,
          (_, indent: string, number: string) =>
            `${indent}${number === "1" ? number : Number(number) + 1}.`,
        );
      const inserted = `\n${nextMarker}`;
      return {
        value: value.slice(0, start) + inserted + value.slice(start),
        selectionStart: start + inserted.length,
        selectionEnd: start + inserted.length,
      };
    }
  }

  if (
    !line.startsWith("|") ||
    !/\|\s*$/.test(line) ||
    value.slice(start, lineEnd).trim()
  )
    return null;
  if (/^[|\s]+$/.test(line)) return null;
  const pipes = (line.match(/\|/g) ?? []).length;
  const row = Array(pipes).fill("|").join("  ");
  const previous =
    value
      .slice(0, Math.max(0, lineStart - 1))
      .split("\n")
      .at(-1) ?? "";
  const firstRow = !line.includes("---") && !previous.includes("|");
  const inserted = firstRow
    ? `\n${Array(pipes).fill("|").join(" --- ")}\n${row}`
    : `\n${row}`;
  const caret = firstRow ? start + inserted.length - row.length + 3 : start + 3;
  return {
    value: value.slice(0, start) + inserted + value.slice(start),
    selectionStart: caret,
    selectionEnd: caret,
  };
}

export function insertMarkdownBlock(
  body: string,
  start: number,
  end: number,
  markdown: string,
): { body: string; caret: number } {
  const before = body.slice(0, start);
  const after = body.slice(end);
  const leading =
    before && !before.endsWith("\n\n")
      ? before.endsWith("\n")
        ? "\n"
        : "\n\n"
      : "";
  const trailing =
    after && !after.startsWith("\n\n")
      ? after.startsWith("\n")
        ? "\n"
        : "\n\n"
      : "";
  const inserted = `${leading}${markdown}${trailing}`;
  return {
    body: `${before}${inserted}${after}`,
    caret: before.length + leading.length + markdown.length,
  };
}

export function suggestionVerticalPosition(
  caretTop: number,
  fieldHeight: number,
): { bottom: number } {
  const gap = 8;
  return { bottom: fieldHeight - caretTop + gap };
}

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
