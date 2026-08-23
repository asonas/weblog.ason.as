/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { Editor } from "@tiptap/core";
import { JSDOM } from "jsdom";

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
const { buildInternalUniverseGroups, EDITOR_EXTENSIONS } = await import("./editor");

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
