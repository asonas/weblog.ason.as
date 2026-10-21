import assert from "node:assert/strict";
import test from "node:test";
import { Editor } from "@tiptap/core";
import { JSDOM } from "jsdom";

test("parses spoiler text and media while keeping code literal and hidden images out of covers", async () => {
  const dom = new JSDOM("<!doctype html><div id='editor'></div>");
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
  });
  const { ARTICLE_PREVIEW_EXTENSIONS, autoCoverImageUrl } = await import(
    "./articlePreviewEditor"
  );
  const { markdownForEditor } = await import("./markdown");
  const { installSpoilers } = await import("./installSpoilers");
  const source =
    "前 ||秘密 **強調**|| 後\n\n||![隠す](/assets/hidden.webp)||\n\n||\n[動画](/assets/uploads/2026/10/abc-123.mp4)\n||\n\n`||code||`\n\n```\n||fenced||\n```\n\n\\|\\|escaped||\n\n||unclosed";
  const element = document.getElementById("editor");
  assert.ok(element);
  const editor = new Editor({
    element,
    editable: false,
    extensions: ARTICLE_PREVIEW_EXTENSIONS,
    content: markdownForEditor(source),
    contentType: "markdown",
  });
  const cleanup = installSpoilers(element);
  try {
    assert.equal(element.querySelectorAll(".article-spoiler").length, 3);
    assert.ok(element.querySelector(".article-spoiler strong"));
    assert.ok(element.querySelector(".article-spoiler img"));
    assert.ok(element.querySelector(".article-spoiler video"));
    assert.equal(autoCoverImageUrl(source), null);
    assert.equal(
      autoCoverImageUrl(`${source}\n\n![表紙](/assets/visible.webp)`),
      "/assets/visible.webp",
    );
    const spoiler = element.querySelector<HTMLElement>(".article-spoiler");
    const button = spoiler?.querySelector("button");
    const content = spoiler?.querySelector<HTMLElement>(
      ".article-spoiler__content",
    );
    assert.ok(button && content);
    assert.equal(content.getAttribute("aria-hidden"), "true");
    button.click();
    assert.equal(button.getAttribute("aria-expanded"), "true");
    assert.equal(content.inert, false);
    content.click();
    assert.equal(button.getAttribute("aria-expanded"), "false");
    assert.equal(content.inert, true);
  } finally {
    cleanup();
    editor.destroy();
    dom.window.close();
  }
});
