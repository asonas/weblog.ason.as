/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { Editor } from "@tiptap/core";
import { TextSelection } from "@tiptap/pm/state";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";

import type { EditorBootstrap } from "./editor";

function installDom() {
  const dom = new JSDOM("<!doctype html><html data-can-edit=\"true\"><body></body></html>", {
    url: "http://127.0.0.1:5173/current"
  });
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    HTMLAnchorElement: dom.window.HTMLAnchorElement,
    KeyboardEvent: dom.window.KeyboardEvent,
    MouseEvent: dom.window.MouseEvent,
    MutationObserver: dom.window.MutationObserver,
    DOMParser: dom.window.DOMParser,
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle)
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: dom.window.navigator
  });
  dom.window.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(0), 0) as unknown as number;
  dom.window.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
}

installDom();
Object.defineProperty(document, "hidden", { configurable: true, value: false });
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const {
  AuthoringEditor,
  buildInternalUniverseGroups,
  EDITOR_EXTENSIONS,
  embedImageUrl,
  ensureBodySelection,
  extractEmbeddableUrls,
  internalNodeVisual,
  isImageDrag,
  matchingWikiLinkNames,
  nextWikiLinkSuggestionIndex,
  replaceEditorContentPreservingSelection,
  wrapSelectionInWikiLink,
  wikiLinkQuery,
  topicSourceElement,
  youtubeVideoId
} = await import("./editor");
const { imageDimensions, resizedDimensions } = await import("./imageMetadata");
const { markdownForSource } = await import("./markdown");

test("ignores URLs in inline and fenced code when building embeds", () => {
  const body = [
    "https://example.com/article",
    "`https://inline.example.com/full/path`",
    "```js",
    'const endpoint = "https://fenced.example.com/full/path";',
    "```"
  ].join("\n");

  assert.deepEqual(extractEmbeddableUrls(body), ["https://example.com/article"]);
});

test("recognizes image files and inbox photos as image drags", () => {
  assert.equal(isImageDrag({ items: [{ kind: "file", type: "image/png" }] }), true);
  assert.equal(isImageDrag({ items: [{ kind: "file", type: "text/plain" }] }), false);
  assert.equal(isImageDrag({ types: ["application/x-weblog-inbox-key"] }), true);
});

test("extracts video IDs from YouTube URLs", () => {
  assert.equal(youtubeVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), "dQw4w9WgXcQ");
  assert.equal(youtubeVideoId("https://youtu.be/dQw4w9WgXcQ?t=42"), "dQw4w9WgXcQ");
  assert.equal(youtubeVideoId("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ");
  assert.equal(youtubeVideoId("https://example.com/watch?v=dQw4w9WgXcQ"), null);
});

test("uses the YouTube thumbnail when OGP has no image", () => {
  const url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
  assert.equal(
    embedImageUrl(url, {
      url,
      canonical_url: url,
      title: "YouTube",
      description: "",
      site_name: "YouTube",
      image_url: "",
      status: "ready"
    }),
    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
  );
});

test("renders a standalone YouTube URL in the editor and preserves its Markdown", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ",
    contentType: "markdown"
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(editor.state.doc.child(1).type.name, "youtubePlayer");
  assert.match(editor.getHTML(), /youtube\.com\/embed\/dQw4w9WgXcQ/);
  assert.match(editor.getMarkdown(), /https:\/\/www\.youtube\.com\/watch\?v=dQw4w9WgXcQ/);
  editor.destroy();
});

test("edits a selected YouTube player as its original URL", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ\n\nbody",
    contentType: "markdown"
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const playerPosition = editor.state.doc.firstChild!.nodeSize;

  editor.commands.setNodeSelection(playerPosition);

  assert.equal(editor.state.doc.child(1).type.name, "paragraph");
  assert.equal(editor.state.doc.child(1).textContent, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert.ok(editor.state.selection instanceof TextSelection);

  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.equal(editor.state.doc.child(1).type.name, "youtubePlayer");
  editor.destroy();
});

test("uses an inline YouTube player as the universe line source", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ",
    contentType: "markdown"
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  const source = topicSourceElement(
    editor.view.dom,
    "url",
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  );

  assert.equal(source?.dataset.youtubePlayer, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  editor.destroy();
});

test("finds and filters the unfinished Wiki link at the cursor", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n[[2026-",
    contentType: "markdown"
  });
  editor.commands.focus("end");

  assert.equal(wikiLinkQuery(editor)?.value, "2026-");
  assert.deepEqual(
    matchingWikiLinkNames(["2026-08-23", "topic", "2026-08-22"], "2026-"),
    ["2026-08-23", "2026-08-22"]
  );
  editor.destroy();
});

test("moves Wiki link suggestions forward and backward", () => {
  assert.equal(nextWikiLinkSuggestionIndex(0, 5, false), 1);
  assert.equal(nextWikiLinkSuggestionIndex(4, 5, false), 0);
  assert.equal(nextWikiLinkSuggestionIndex(0, 5, true), 4);
});

test("reads PNG dimensions before decoding the image", () => {
  const bytes = new Uint8Array(24);
  new DataView(bytes.buffer).setUint32(0, 0x89504e47);
  new DataView(bytes.buffer).setUint32(16, 4000);
  new DataView(bytes.buffer).setUint32(20, 3000);

  assert.deepEqual(imageDimensions(bytes.buffer, "image/png"), { width: 4000, height: 3000 });
  assert.deepEqual(resizedDimensions({ width: 4000, height: 3000 }), { width: 2560, height: 1920 });
});

test("applies JPEG EXIF orientation before resizing", () => {
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    0xff, 0xe1, 0x00, 0x22,
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
    0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x01, 0x00,
    0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0xff, 0xe1, 0x00, 0x08, 0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f,
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x0f, 0xb0, 0x17, 0x80, 0x01, 0x01, 0x11, 0x00,
    0xff, 0xd9
  ]);

  const dimensions = imageDimensions(bytes.buffer, "image/jpeg");
  assert.deepEqual(dimensions, { width: 4016, height: 6016 });
  assert.deepEqual(resizedDimensions(dimensions!), { width: 1709, height: 2560 });
});

test("round trips an uploaded image as Markdown", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nbody",
    contentType: "markdown"
  });

  editor.commands.focus("end");
  editor.commands.setImage({ src: "/assets/uploads/2026/08/image.webp", alt: "" });

  assert.match(editor.getMarkdown(), /!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/);
  editor.destroy();
});

test("keeps an uploaded image out of the title line", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title",
    contentType: "markdown"
  });

  ensureBodySelection(editor);
  editor.commands.setImage({ src: "/assets/uploads/2026/08/image.webp", alt: "" });

  assert.equal(editor.state.doc.childCount, 3);
  assert.equal(editor.state.doc.firstChild?.type.name, "paragraph");
  assert.equal(editor.state.doc.firstChild?.textContent, "title");
  assert.match(editor.getMarkdown(), /^title\n\n!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/);
  editor.destroy();
});

test("emphasizes internal nodes with more connections", () => {
  assert.equal(internalNodeVisual(1, 2, 1, 2).size, 14);
  assert.equal(internalNodeVisual(10, 2, 1, 2).size, 23);
  assert.equal(internalNodeVisual(100, 2, 1, 2).size, 26);
});

test("makes newer internal nodes darker than older nodes", () => {
  assert.equal(internalNodeVisual(1, 1, 1, 3).opacity, 0.35);
  assert.equal(internalNodeVisual(1, 2, 1, 3).opacity, 0.675);
  assert.equal(internalNodeVisual(1, 3, 1, 3).opacity, 1);
});

test("keeps the current page hub while omitting its self node", () => {
  const backlink: EditorBootstrap["linked_pages"][number] = {
    id: "daily-page",
    title: "2026-08-23",
    route: "2026-08-23",
    created_at: "2026-08-23T00:00:00+09:00",
    excerpt: "Calicoについて",
    image_url: null,
    related_by: ["Calico"]
  };
  const currentPage = { ...backlink, id: "calico", title: "Calico", route: "Calico" };

  const groups = buildInternalUniverseGroups("[[Calico]]\n\nhttps://calicocat.app/", "Calico", [{
    kind: "wiki",
    name: "Calico",
    pages: [currentPage, backlink],
    isTopicOnly: false
  }]);

  assert.equal(groups.length, 1);
  assert.equal(groups[0].name, "Calico");
  assert.deepEqual(groups[0].pages, [backlink]);
});

test("opens an unfocused wiki link instead of expanding it for editing", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example) foo bar",
    contentType: "markdown"
  });
  const link = editor.view.dom.querySelector<HTMLAnchorElement>('a[href="/example"]');

  assert.ok(link);
  assert.equal(link.textContent, "example");
  assert.notEqual(link.target, "_blank");

  const mouseDown = new window.MouseEvent("mousedown", { bubbles: true, cancelable: true });
  Object.defineProperty(mouseDown, "target", { value: link });
  let mouseDownHandled = false;
  editor.view.someProp("handleDOMEvents", (handlers) => {
    mouseDownHandled ||= handlers.mousedown?.(editor.view, mouseDown) === true;
  });

  assert.equal(mouseDownHandled, true);
  assert.equal(mouseDown.defaultPrevented, true);
  assert.ok(editor.view.dom.querySelector('a[href="/example"]'));

  let opened: { url?: string | URL; target?: string } | undefined;
  const originalOpen = window.open;
  window.open = (url, target) => {
    opened = { url, target };
    return null;
  };
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  Object.defineProperty(click, "target", { value: link });
  let handled = false;
  editor.view.someProp("handleClick", (handler) => {
    handled ||= handler(editor.view, 2, click) === true;
  });
  window.open = originalOpen;

  assert.equal(handled, true);
  assert.equal(opened?.url, "http://127.0.0.1:5173/example");
  assert.equal(opened?.target, "_self");
  assert.ok(editor.view.dom.querySelector('a[href="/example"]'));
  assert.equal(editor.getText(), "example foo bar");
  editor.destroy();
});

test("deletes a closing wiki bracket from the cursor immediately after the link", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)test",
    contentType: "markdown"
  });

  editor.commands.setTextSelection(8);
  assert.equal(editor.getText(), "[[example]]test");
  assert.equal(editor.state.selection.from, 12);

  editor.commands.deleteRange({ from: 11, to: 12 });

  assert.equal(editor.getText(), "[[example]test");
  editor.destroy();
});

test("keeps a wiki link raw while composing text after it", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown"
  });

  editor.commands.setTextSelection(8);
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
  editor.commands.insertContent("あ");

  assert.equal(editor.view.composing, true);
  assert.equal(editor.getText(), "[[example]]あ");
  editor.destroy();
});

test("wraps selected text in a wiki link with the platform shortcut", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "example",
    contentType: "markdown"
  });

  editor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(wrapSelectionInWikiLink(editor), true);
  assert.equal(editor.getText(), "[[example]]");
  editor.destroy();
});

test("preserves wiki link cursor boundaries and text selections", () => {
  const wikiEditor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown"
  });

  wikiEditor.commands.setTextSelection(1);
  assert.equal(wikiEditor.getText(), "[[example]]");
  assert.equal(wikiEditor.state.doc.textBetween(
    wikiEditor.state.selection.from,
    wikiEditor.state.selection.from + 2
  ), "[[");
  wikiEditor.destroy();

  const selectionEditor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown"
  });

  selectionEditor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(selectionEditor.getText(), "[[example]]");
  assert.deepEqual(
    { from: selectionEditor.state.selection.from, to: selectionEditor.state.selection.to },
    { from: 1, to: 12 }
  );
  assert.equal(selectionEditor.state.doc.rangeHasMark(1, 12, selectionEditor.schema.marks.link), false);
  selectionEditor.destroy();
});

test("preserves the cursor when refreshed content replaces the document", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nbody\n\n[日記](/%E6%97%A5%E8%A8%98)",
    contentType: "markdown"
  });
  const bodyPosition = editor.state.doc.child(0).nodeSize + 2;
  editor.commands.setTextSelection(bodyPosition);

  replaceEditorContentPreservingSelection(
    editor,
    "title\n\nbody\n\n[日記](/%E6%97%A5%E8%A8%98)"
  );

  assert.equal(editor.state.selection.from, bodyPosition);
  editor.destroy();
});

test("edits a selected image as Markdown and renders it again after leaving", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n![](/assets/uploads/2026/08/image.webp)\n\nbody",
    contentType: "markdown"
  });
  const imagePosition = editor.state.doc.firstChild!.nodeSize;

  editor.commands.setTextSelection(imagePosition - 1);
  editor.commands.setNodeSelection(imagePosition);
  assert.match(editor.getText(), /!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/);
  assert.match(markdownForSource(editor.getMarkdown()), /!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/);
  assert.equal(editor.state.selection.empty, true);
  assert.equal(editor.state.doc.textBetween(editor.state.selection.from, editor.state.selection.from + 1), "!");

  editor.commands.setTextSelection({
    from: imagePosition + 1,
    to: imagePosition + editor.state.doc.child(1).nodeSize - 1
  });
  assert.equal(editor.state.doc.child(1).type.name, "paragraph");

  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.ok(editor.state.doc.child(1).type.name === "image");
  assert.equal(editor.state.doc.child(1).attrs.src, "/assets/uploads/2026/08/image.webp");
  editor.destroy();
});

test("edits an image as Markdown when the cursor lands to its right", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n![](/assets/uploads/2026/08/image.webp)\n\nbody",
    contentType: "markdown"
  });
  const bodyStart = editor.state.doc.firstChild!.nodeSize + editor.state.doc.child(1).nodeSize + 1;

  editor.commands.setTextSelection(bodyStart);

  assert.match(editor.getText(), /!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/);
  assert.equal(editor.state.selection.from, editor.state.doc.child(0).nodeSize + editor.state.doc.child(1).nodeSize - 1);
  editor.destroy();
});

test("refreshes an unedited page from its public API", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({
    mode: "editor",
    id: "page-id",
    page_type: "named",
    date: null,
    name: "current",
    title: null,
    updated_at: "2026-08-24T00:00:00.000000000+09:00",
    route: "current",
    body: "新しい本文",
    linked_pages: [],
    linked_pages_has_more: false
  }), { headers: { "content-type": "application/json", etag: "\"new\"" } });
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "古い本文",
    expected_updated_at: "2026-08-23T00:00:00.000000000+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });

    assert.match(container.textContent || "", /新しい本文/);
    assert.doesNotMatch(container.textContent || "", /古い本文/);
    assert.equal(window.location.pathname, "/current");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});
