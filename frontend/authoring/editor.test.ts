/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { Editor } from "@tiptap/core";
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
  ensureBodySelection,
  internalNodeVisual,
  replaceEditorContentPreservingSelection
} = await import("./editor");
const { imageDimensions, resizedDimensions } = await import("./imageMetadata");
const { markdownForSource } = await import("./markdown");

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
  assert.deepEqual(internalNodeVisual(1), { opacity: 0.72, size: 14 });
  assert.deepEqual(internalNodeVisual(10), { opacity: 0.96, size: 23 });
  assert.deepEqual(internalNodeVisual(100), { opacity: 1, size: 26 });
});

test("omits the current page from internal universe topics", () => {
  const backlink: EditorBootstrap["linked_pages"][number] = {
    id: "daily-page",
    title: "2026-08-23",
    route: "2026-08-23",
    excerpt: "Calicoについて",
    image_url: null,
    related_by: ["Calico"]
  };

  const groups = buildInternalUniverseGroups("[[Calico]]\n\nhttps://calicocat.app/", "Calico", [{
    kind: "wiki",
    name: "Calico",
    pages: [backlink],
    isTopicOnly: false
  }]);

  assert.deepEqual(groups, []);
});

test("opens an unfocused wiki link in the same tab", async () => {
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

  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  Object.defineProperty(click, "target", { value: link });
  let handled = false;
  editor.view.someProp("handleClick", (handler) => {
    handled ||= handler(editor.view, 2, click) === true;
  });

  assert.equal(handled, false);
  assert.equal(click.defaultPrevented, false);
  assert.ok(editor.view.dom.querySelector('a[href="/example"]'));
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
