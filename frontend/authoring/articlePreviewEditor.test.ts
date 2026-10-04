import assert from "node:assert/strict";
import test from "node:test";
import { Editor } from "@tiptap/core";
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
  const source =
    "![左手 <device> & 写真](/assets/photo.jpg)\n\n![](/assets/empty.jpg)";
  const editor = new Editor({
    extensions: ARTICLE_PREVIEW_EXTENSIONS,
    content: source,
    contentType: "markdown",
  });
  try {
    const article = document.createElement("div");
    article.innerHTML = editor.getHTML();
    assert.equal(article.querySelectorAll(".article-image__caption").length, 1);
    assert.equal(
      article.querySelector(".article-image__caption")?.textContent,
      "左手 <device> & 写真",
    );
    assert.equal(article.querySelector("img")?.alt, "左手 <device> & 写真");
    assert.equal(editor.getMarkdown(), source);
  } finally {
    editor.destroy();
    dom.window.close();
  }
});
