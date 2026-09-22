import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";

test("keeps preview extensions and resolves internal cover images", async () => {
  const dom = new JSDOM("<!doctype html>");
  Object.assign(globalThis, {
    document: dom.window.document,
    window: dom.window,
  });
  const { ARTICLE_PREVIEW_EXTENSIONS, autoCoverImageUrl } = await import(
    "./articlePreviewEditor"
  );
  assert.ok(ARTICLE_PREVIEW_EXTENSIONS.length > 0);
  assert.equal(
    autoCoverImageUrl("本文\n\n![cover](/assets/photo.webp)"),
    "/assets/photo.webp",
  );
  assert.equal(
    autoCoverImageUrl("![external](https://example.com/photo.webp)"),
    null,
  );
});
