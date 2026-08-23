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
const { AuthoringEditor, buildInternalUniverseGroups, EDITOR_EXTENSIONS } = await import("./editor");

test("includes pages that link to the current route in the internal universe", () => {
  const backlink: EditorBootstrap["linked_pages"][number] = {
    id: "daily-page",
    title: "2026-08-23",
    route: "2026-08-23",
    excerpt: "Calicoについて",
    image_url: null,
    related_by: ["Calico"]
  };

  const groups = buildInternalUniverseGroups("https://calicocat.app/", "Calico", [{
    kind: "wiki",
    name: "Calico",
    pages: [backlink],
    isTopicOnly: false
  }]);

  assert.deepEqual(groups, [{
    kind: "wiki",
    name: "Calico",
    pages: [backlink],
    isTopicOnly: false
  }]);
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
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});
