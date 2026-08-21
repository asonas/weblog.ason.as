const WIKI_START = "[[";
const WIKI_END = "]]";
const FENCE_PATTERN = /^\s*(`{3,}|~{3,})/;

type Fence = {
  marker: string;
  length: number;
};

function encodePageName(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function escapeLinkLabel(label: string): string {
  return label.replace(/[\\[\]()/]/g, "\\$&");
}

function replaceWikiLinks(line: string): string {
  let result = "";
  let cursor = 0;
  let codeMarker: string | null = null;

  while (cursor < line.length) {
    if (line[cursor] === "`") {
      let end = cursor;
      while (line[end] === "`") end += 1;
      const marker = line.slice(cursor, end);
      result += marker;
      codeMarker = codeMarker === marker ? null : codeMarker || marker;
      cursor = end;
      continue;
    }

    if (codeMarker === null && line.startsWith(WIKI_START, cursor)) {
      const end = line.indexOf(WIKI_END, cursor + WIKI_START.length);
      if (end !== -1) {
        const name = line.slice(cursor + WIKI_START.length, end).trim();
        if (name.length > 0) {
          result += `[${escapeLinkLabel(name)}](/${encodePageName(name)})`;
          cursor = end + WIKI_END.length;
          continue;
        }
      }
    }

    result += line[cursor];
    cursor += 1;
  }

  return result;
}

export function markdownForEditor(source: string): string {
  let fence: Fence | null = null;
  const lines = source.match(/[^\n]*\n|[^\n]+$/g) || [];

  return lines.map((line) => {
    const fenceMatch = FENCE_PATTERN.exec(line);
    const insideFence = fence !== null || fenceMatch !== null;
    const converted = insideFence ? line : replaceWikiLinks(line);

    if (fenceMatch !== null) {
      const marker = fenceMatch[1];
      if (fence === null) {
        fence = { marker: marker[0], length: marker.length };
      } else if (marker[0] === fence.marker && marker.length >= fence.length) {
        fence = null;
      }
    }

    return converted;
  }).join("");
}

function replaceLocalLinks(line: string): string {
  let result = "";
  let cursor = 0;
  let codeMarker: string | null = null;

  while (cursor < line.length) {
    if (line[cursor] === "`") {
      let end = cursor;
      while (line[end] === "`") end += 1;
      const marker = line.slice(cursor, end);
      result += marker;
      codeMarker = codeMarker === marker ? null : codeMarker || marker;
      cursor = end;
      continue;
    }

    if (codeMarker === null && line.startsWith("\\[\\[", cursor)) {
      const escapedEnd = line.indexOf("\\]\\]", cursor + 4);
      if (escapedEnd !== -1) {
        const name = line.slice(cursor + 4, escapedEnd);
        if (name.trim().length > 0) {
          result += `[[${name}]]`;
          cursor = escapedEnd + 4;
          continue;
        }
      }
    }

    if (codeMarker === null && line[cursor] === "[") {
      const labelEnd = line.indexOf("](", cursor + 1);
      if (labelEnd !== -1) {
        const hrefEnd = line.indexOf(")", labelEnd + 2);
        const label = line.slice(cursor + 1, labelEnd);
        if (hrefEnd !== -1) {
          const href = line.slice(labelEnd + 2, hrefEnd);
          if (!href.startsWith("/") || /[\s<>]/.test(href)) {
            result += line[cursor];
            cursor += 1;
            continue;
          }

          try {
            const name = decodeURIComponent(href.slice(1));
            if (name === label) {
              result += `[[${name}]]`;
              cursor = hrefEnd + 1;
              continue;
            }
          } catch (_error) {
            // Leave malformed URL text untouched so the server can report it.
          }
        }
      }
    }

    result += line[cursor];
    cursor += 1;
  }

  return result;
}

export function markdownForSource(markdown: string): string {
  let fence: Fence | null = null;
  const lines = markdown.match(/[^\n]*\n|[^\n]+$/g) || [];

  return lines.map((line) => {
    const fenceMatch = FENCE_PATTERN.exec(line);
    const insideFence = fence !== null || fenceMatch !== null;
    const converted = insideFence ? line : replaceLocalLinks(line);

    if (fenceMatch !== null) {
      const marker = fenceMatch[1];
      if (fence === null) {
        fence = { marker: marker[0], length: marker.length };
      } else if (marker[0] === fence.marker && marker.length >= fence.length) {
        fence = null;
      }
    }

    return converted;
  }).join("");
}
