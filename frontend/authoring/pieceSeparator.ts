export function pieceSeparator(
  value: string,
  caret: number,
  previous = "",
  previousCaret = Number.POSITIVE_INFINITY,
) {
  let prefix = 0;
  while (prefix < previous.length && previous[prefix] === value[prefix])
    prefix++;
  let suffix = 0;
  while (
    suffix < previous.length - prefix &&
    suffix < value.length - prefix &&
    previous[previous.length - suffix - 1] === value[value.length - suffix - 1]
  )
    suffix++;
  let offset = 0;
  let fence: { character: string; length: number } | undefined;
  for (const line of value.split("\n")) {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (marker) {
      const token = marker[1];
      if (!fence) fence = { character: token[0], length: token.length };
      else if (
        token[0] === fence.character &&
        token.length >= fence.length &&
        !marker[2].trim()
      )
        fence = undefined;
    } else if (
      !fence &&
      line === "---" &&
      caret > offset + line.length &&
      value.slice(offset + line.length + 1).trim()
    ) {
      const oldOffset =
        offset + line.length <= prefix
          ? offset
          : offset >= value.length - suffix
            ? offset + previous.length - value.length
            : -1;
      // Historical horizontal rules remain text; only a new separator splits.
      if (
        oldOffset >= 0 &&
        previousCaret !== oldOffset + line.length &&
        (oldOffset === 0 || previous[oldOffset - 1] === "\n") &&
        previous.slice(oldOffset, oldOffset + 4) === "---\n" &&
        previous.slice(oldOffset + 4).trim()
      ) {
        offset += line.length + 1;
        continue;
      }
      return {
        before: value.slice(0, offset).replace(/\n$/, ""),
        after: value.slice(offset + line.length + 1),
        caret: caret - offset - line.length - 1,
      };
    }
    offset += line.length + 1;
  }
  return null;
}
