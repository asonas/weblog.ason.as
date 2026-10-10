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

test("reading preview lays out portrait images without changing Markdown or captions", async () => {
  const dom = new JSDOM("<!doctype html><div id='editor'></div>");
  Object.assign(globalThis, {
    document: dom.window.document,
    window: dom.window,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle,
  });
  const { ARTICLE_PREVIEW_EXTENSIONS } = await import("./articlePreviewEditor");
  const element = document.getElementById("editor");
  assert.ok(element);
  const source = "![ゲームの画面](/portrait.webp)\n\n本文";
  const editor = new Editor({
    element,
    editable: false,
    extensions: ARTICLE_PREVIEW_EXTENSIONS,
    content: source,
    contentType: "markdown",
  });
  try {
    const image = element.querySelector("img");
    assert.ok(image);
    Object.defineProperties(image, {
      naturalWidth: { value: 400 },
      naturalHeight: { value: 800 },
    });
    image.dispatchEvent(new dom.window.Event("load"));
    assert.ok(image.closest(".article-image--portrait"));
    assert.equal(
      element.querySelector(".article-image__caption")?.textContent,
      "ゲームの画面",
    );
    assert.equal(editor.getMarkdown(), source);
    editor.commands.setContent("![横長の写真](/landscape.webp)", {
      contentType: "markdown",
    });
    const replacement = element.querySelector("img");
    assert.ok(replacement);
    Object.defineProperties(replacement, {
      naturalWidth: { value: 800 },
      naturalHeight: { value: 400 },
    });
    replacement.dispatchEvent(new dom.window.Event("load"));
    assert.equal(element.querySelector(".article-image--portrait"), null);
  } finally {
    editor.destroy();
    dom.window.close();
  }
});

test("renders saved standalone uploaded video links as players", async () => {
  const dom = new JSDOM("<!doctype html>");
  Object.assign(globalThis, {
    document: dom.window.document,
    window: dom.window,
  });
  const { ARTICLE_PREVIEW_EXTENSIONS } = await import("./articlePreviewEditor");
  const { markdownForEditor } = await import("./markdown");
  const path = "/assets/uploads/2026/10/abc-123.mp4";
  const link = `[clip.MOV](${path})`;
  const editor = new Editor({
    extensions: ARTICLE_PREVIEW_EXTENSIONS,
    content: markdownForEditor(link),
    contentType: "markdown",
  });
  try {
    assert.match(editor.getHTML(), /<video/);
    assert.ok(editor.getHTML().includes(`data-avc="${path}"`));
    assert.equal(markdownForEditor(`Download ${link}`), `Download ${link}`);
    assert.equal(
      markdownForEditor(`\`\`\`\n${link}\n\`\`\``),
      `\`\`\`\n${link}\n\`\`\``,
    );
    assert.equal(
      markdownForEditor("[clip](https://example.com/clip.mp4)"),
      "[clip](https://example.com/clip.mp4)",
    );
  } finally {
    editor.destroy();
    dom.window.close();
  }
});
