import assert from "node:assert/strict";
import test from "node:test";
import { articleDocumentTitle } from "./documentTitle";

test("formats draft document titles", () => {
  assert.equal(articleDocumentTitle(""), "weblog.ason.as");
  assert.equal(
    articleDocumentTitle("テストの記事です。"),
    "テストの記事です。 | weblog.ason.as",
  );
  assert.equal(
    articleDocumentTitle("2026-09-22", "development"),
    "[dev] 2026-09-22 | weblog.ason.as",
  );
});
