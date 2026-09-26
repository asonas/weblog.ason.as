import assert from "node:assert/strict";
import test from "node:test";
import {
  markdownBlockIndexAt,
  markdownKeyEdit,
  suggestionVerticalPosition,
  textareaWikiLinkQuery,
  wrapTextareaSelectionInWikiLink,
} from "./draftMarkdown";

test("indents and unindents Markdown lines with Tab", () => {
  assert.deepEqual(markdownKeyEdit("- one\n- two", 2, 2, "Tab"), {
    value: "    - one\n- two",
    selectionStart: 6,
    selectionEnd: 6,
  });
  assert.deepEqual(markdownKeyEdit("    - one\n  - two", 4, 18, "Tab", true), {
    value: "- one\n- two",
    selectionStart: 0,
    selectionEnd: 11,
  });
  assert.deepEqual(markdownKeyEdit("- one\n- two", 0, 6, "Tab"), {
    value: "    - one\n- two",
    selectionStart: 0,
    selectionEnd: 9,
  });
});

test("continues and ends Markdown lists with Enter", () => {
  assert.deepEqual(markdownKeyEdit("2. item", 7, 7, "Enter"), {
    value: "2. item\n3. ",
    selectionStart: 11,
    selectionEnd: 11,
  });
  assert.deepEqual(markdownKeyEdit("- [x] done", 10, 10, "Enter"), {
    value: "- [x] done\n- [ ] ",
    selectionStart: 17,
    selectionEnd: 17,
  });
  assert.deepEqual(markdownKeyEdit("- ", 2, 2, "Enter"), {
    value: "",
    selectionStart: 0,
    selectionEnd: 0,
  });
});

test("moves between table cells and extends a table with Enter", () => {
  assert.deepEqual(markdownKeyEdit("| one | two |", 2, 2, "Tab"), {
    value: "| one | two |",
    selectionStart: 8,
    selectionEnd: 8,
  });
  assert.deepEqual(markdownKeyEdit("| one | two |", 8, 8, "Tab", true), {
    value: "| one | two |",
    selectionStart: 2,
    selectionEnd: 2,
  });
  assert.deepEqual(markdownKeyEdit("| a | b |", 9, 9, "Enter"), {
    value: "| a | b |\n| --- | --- |\n|  |  |",
    selectionStart: 27,
    selectionEnd: 27,
  });
});

test("finds an unfinished Wiki link at the textarea cursor", () => {
  const unfinished = "before\n[[webl";
  assert.deepEqual(textareaWikiLinkQuery(unfinished, unfinished.length), {
    from: 9,
    to: unfinished.length,
    value: "webl",
  });
  assert.deepEqual(textareaWikiLinkQuery("[[old value]]", 5), {
    from: 2,
    to: 13,
    value: "old",
  });
  assert.equal(textareaWikiLinkQuery("[[closed]] after", 16), null);
});

test("wraps the selected textarea text in a Wiki link", () => {
  assert.deepEqual(
    wrapTextareaSelectionInWikiLink("before page after", 7, 11),
    {
      value: "before [[page]] after",
      selectionStart: 9,
      selectionEnd: 13,
    },
  );
  assert.equal(wrapTextareaSelectionInWikiLink("page", 2, 2), null);
});

test("does not suggest while a textarea range is selected", () => {
  assert.equal(textareaWikiLinkQuery("[[page", 2, 6), null);
});

test("maps the cursor to its blank-line separated Markdown block", () => {
  const markdown = "first\nline\n\nsecond\n\nthird";
  assert.equal(markdownBlockIndexAt(markdown, 3), 0);
  assert.equal(
    markdownBlockIndexAt(markdown, markdown.indexOf("second") + 2),
    1,
  );
  assert.equal(markdownBlockIndexAt(markdown, markdown.length), 2);
});

test("places Wiki link suggestions above the textarea cursor", () => {
  assert.deepEqual(suggestionVerticalPosition(480, 500, 24, 42), {
    bottom: 28,
  });
  assert.deepEqual(suggestionVerticalPosition(120, 500, 24, 42), {
    bottom: 388,
  });
});

test("places Wiki link suggestions below the line when they do not fit above", () => {
  assert.deepEqual(suggestionVerticalPosition(16, 500, 24, 42), { top: 48 });
  assert.deepEqual(suggestionVerticalPosition(60, 500, 24, 56), { top: 92 });
  assert.deepEqual(suggestionVerticalPosition(64, 500, 24, 56), {
    bottom: 444,
  });
});
