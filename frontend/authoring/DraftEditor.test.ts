import assert from "node:assert/strict";
import test from "node:test";
import {
  markdownBlockIndexAt,
  suggestionVerticalPosition,
  textareaWikiLinkQuery,
  wrapTextareaSelectionInWikiLink,
} from "./draftMarkdown";

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

test("places Wiki link suggestions above a cursor near the textarea bottom", () => {
  assert.deepEqual(suggestionVerticalPosition(480, 500), { bottom: 28 });
  assert.deepEqual(suggestionVerticalPosition(120, 500), { top: 128 });
});
