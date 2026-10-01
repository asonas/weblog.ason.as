import assert from "node:assert/strict";
import { test } from "node:test";
import { pieceSeparator } from "./pieceSeparator";

test("splits when Enter follows a newly typed separator before existing text", () => {
  assert.deepEqual(pieceSeparator("A\n---\n\nB", 6, "A\n---\nB", 5), {
    before: "A",
    after: "\nB",
    caret: 0,
  });
});

test("preserves historical rules while allowing a new separator", () => {
  const previous = "A\n---\nB";
  assert.equal(pieceSeparator(`AA\n---\nB`, 1, previous, 0), null);
  assert.equal(pieceSeparator(`${previous}C`, 8, previous), null);
  assert.equal(pieceSeparator(`AA\n---\nB`, 8, previous), null);
  assert.deepEqual(pieceSeparator(`${previous}\n---\nC`, 13, previous), {
    before: previous,
    after: "C",
    caret: 1,
  });
  assert.deepEqual(pieceSeparator("A\n---\nB", 7, "A\n---\n"), {
    before: "A",
    after: "B",
    caret: 1,
  });
});

test("starts a piece only after text is entered below the separator", () => {
  assert.equal(pieceSeparator("A\n---", 5), null);
  assert.equal(pieceSeparator("A\n---\n", 6), null);
  assert.deepEqual(pieceSeparator("A\n---\nB", 7), {
    before: "A",
    after: "B",
    caret: 1,
  });
});

test("splits within a piece without dropping the remaining paragraphs", () => {
  assert.deepEqual(pieceSeparator("前半\n---\n新しい文章\n\n後半", 12), {
    before: "前半",
    after: "新しい文章\n\n後半",
    caret: 5,
  });
});

test("keeps separators inside fenced code and splits after the code", () => {
  const code = "```text\n---\nコード\n```";
  assert.equal(pieceSeparator(code, code.length), null);
  const value = `${code}\n---\nB`;
  assert.deepEqual(pieceSeparator(value, value.length), {
    before: code,
    after: "B",
    caret: 1,
  });
  const tildeCode = "~~~~\n---\n~~~\n---\n~~~~";
  assert.equal(pieceSeparator(tildeCode, tildeCode.length), null);
});
