/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { Editor } from "@tiptap/core";
import { TextSelection } from "@tiptap/pm/state";
import { JSDOM } from "jsdom";
import { act, createElement, Profiler } from "react";
import { createRoot } from "react-dom/client";

import type { EditorBootstrap } from "./editor";

function installDom() {
  const dom = new JSDOM(
    '<!doctype html><html data-can-edit="true"><body></body></html>',
    {
      url: "http://127.0.0.1:5173/current",
    },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Node: dom.window.Node,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    HTMLAnchorElement: dom.window.HTMLAnchorElement,
    KeyboardEvent: dom.window.KeyboardEvent,
    MouseEvent: dom.window.MouseEvent,
    ClipboardEvent: dom.window.Event,
    MutationObserver: dom.window.MutationObserver,
    DOMParser: dom.window.DOMParser,
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(0), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  });
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: dom.window.navigator,
  });
  dom.window.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(0), 0) as unknown as number;
  dom.window.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  Object.assign(dom.window.document, {
    elementFromPoint: () => dom.window.document.querySelector(".ProseMirror"),
  });
  Object.assign(dom.window.Range.prototype, {
    getClientRects: () => [],
    getBoundingClientRect: () =>
      dom.window.document.body.getBoundingClientRect(),
  });
}

installDom();
Object.defineProperty(document, "hidden", { configurable: true, value: false });
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const {
  AuthoringEditor,
  autoCoverImageUrl,
  buildInternalUniverseGroups,
  EDITOR_EXTENSIONS,
  embedImageUrl,
  editorDocumentTitle,
  ensureBodySelection,
  extractEmbeddableUrls,
  insertPastedJapaneseUrl,
  isImageDrag,
  isVisibleLine,
  lineUpdateLabel,
  lineUpdateStrength,
  pendingLineUpdates,
  matchingWikiLinkNames,
  nextWikiLinkSuggestionIndex,
  replaceEditorContentPreservingSelection,
  wrapSelectionInWikiLink,
  wikiLinkQuery,
  universeReferences,
  showYouTubeFallback,
  applyYouTubeThumbnailFallback,
  youtubeVideoId,
} = await import("./editor");
const { imageDimensions, resizedDimensions } = await import("./imageMetadata");
const { markdownForSource } = await import("./markdown");
const { SearchPage, SiteSearch } = await import("./search");
const { createVideoUploadCard } = await import("./VideoUploadCard");

test("highlights image Markdown during range selection and copies without changing the document", () => {
  for (const editable of [true, false]) {
    for (const backwards of [false, true]) {
      const element = document.createElement("div");
      document.body.append(element);
      let updates = 0;
      const editor = new Editor({
        element,
        extensions: EDITOR_EXTENSIONS,
        editable,
        content: "前半の文章\n\n![写真](/assets/photo.jpg)\n\n後半の文章",
        contentType: "markdown",
        onUpdate: () => updates++,
      });
      try {
        const original = editor.getJSON();
        const from = 3;
        const to = editor.state.doc.content.size - 3;
        editor.view.dom.dispatchEvent(
          new MouseEvent("mousedown", { bubbles: true }),
        );
        editor.view.dispatch(
          editor.state.tr.setSelection(
            TextSelection.create(
              editor.state.doc,
              backwards ? to : from,
              backwards ? from : to,
            ),
          ),
        );
        const selection = editor.state.selection.toJSON();
        const selectedImage = editor.view.dom.querySelector(
          ".selectable-image--selected",
        );
        assert.ok(selectedImage);
        assert.equal(selectedImage.querySelectorAll("img").length, 1);
        const markdown = selectedImage.querySelector(
          ".selected-image-markdown",
        );
        assert.equal(markdown?.textContent, "![写真](/assets/photo.jpg)");
        assert.equal(markdown?.hasAttribute("hidden"), false);
        document.dispatchEvent(new MouseEvent("mouseup"));
        const data = new Map<string, string>([["text/html", "<img>"]]);
        const event = new ClipboardEvent("copy", {
          bubbles: true,
          cancelable: true,
        });
        Object.defineProperty(event, "clipboardData", {
          value: {
            clearData: () => data.clear(),
            setData: (type: string, value: string) => data.set(type, value),
          },
        });
        editor.view.dom.dispatchEvent(event);
        assert.equal(event.defaultPrevented, true);
        assert.deepEqual(
          [...data],
          [["text/plain", "の文章\n\n![写真](/assets/photo.jpg)\n\n後半の"]],
        );
        assert.deepEqual(editor.getJSON(), original);
        assert.deepEqual(editor.state.selection.toJSON(), selection);
        assert.equal(updates, 0);
        const nativeSelection = window.getSelection();
        nativeSelection?.selectAllChildren(editor.view.dom);
        editor.view.dom.dispatchEvent(new window.FocusEvent("blur"));
        assert.equal(
          editor.view.dom.querySelector(".selectable-image--selected"),
          null,
        );
        assert.equal(markdown?.hasAttribute("hidden"), true);
        assert.equal(editor.state.selection.empty, true);
        assert.equal(editor.state.selection.head, backwards ? from : to);
        assert.equal(nativeSelection?.rangeCount, 0);
        assert.deepEqual(editor.getJSON(), original);
        assert.equal(updates, 0);
        editor.view.dom.dispatchEvent(new window.FocusEvent("focus"));
        assert.equal(markdown?.hasAttribute("hidden"), true);
        assert.equal(editor.state.selection.empty, true);
        editor.commands.setTextSelection(1);
        assert.equal(editor.view.dom.querySelectorAll("img").length, 1);
        assert.equal(
          editor.view.dom.querySelector(".selectable-image--selected"),
          null,
        );
        assert.equal(markdown?.hasAttribute("hidden"), true);
        assert.deepEqual(editor.getJSON(), original);
        assert.equal(updates, 0);
      } finally {
        editor.destroy();
        element.remove();
      }
    }
  }
});

test("includes an image when dragging onto it from the following paragraph", () => {
  const element = document.createElement("div");
  document.body.append(element);
  const editor = new Editor({
    element,
    extensions: EDITOR_EXTENSIONS,
    content: "前半の文章\n\n![写真](/assets/photo.jpg)\n\n後半の文章",
    contentType: "markdown",
  });
  try {
    const original = editor.getJSON();
    editor.commands.setTextSelection(14);
    const paragraph = editor.view.dom.lastElementChild;
    const image = editor.view.dom.querySelector("img");
    assert.ok(paragraph);
    assert.ok(image);
    paragraph.dispatchEvent(
      new MouseEvent("mousedown", { bubbles: true, buttons: 1 }),
    );
    assert.equal(editor.state.selection.anchor, 14);
    image.dispatchEvent(
      new MouseEvent("mousemove", { bubbles: true, buttons: 1 }),
    );
    assert.ok(editor.view.dom.querySelector(".selectable-image--selected"));
    assert.equal(editor.state.selection.anchor, 14);
    assert.equal(
      editor.state.selection.content().content.firstChild?.textContent,
      "",
    );
    assert.match(editor.state.selection.content().content.toString(), /image/);
    assert.deepEqual(editor.getJSON(), original);
  } finally {
    editor.destroy();
    element.remove();
  }
});

test("keeps upload progress out of Markdown and inserts at the tracked position without moving the cursor", () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "タイトル\n\n前半後半",
    contentType: "markdown",
  });
  editor.commands.setTextSelection(9);
  const controller = new AbortController();
  const card = createVideoUploadCard(
    editor,
    new File(["video"], "clip.mov"),
    controller.signal,
  );
  const original = editor.getMarkdown();
  card.update("動画を変換中… AV1 82%");
  assert.equal(editor.getMarkdown(), original);
  editor.commands.insertContentAt(8, "追加");
  editor.commands.setTextSelection(1);
  card.complete({
    avc: "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4",
    width: 1920,
    height: 1080,
  });
  assert.match(
    editor.getMarkdown(),
    /前追加半\n\n:::video .*1920x1080 :::\n\n後半/,
  );
  assert.equal(editor.state.selection.from, 1);
  assert.equal(editor.view.dom.querySelector(".video-upload-card"), null);
  card.dispose();
  editor.destroy();
});

test("retries an inline upload and cancels it without inserting a late result", async () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "タイトル\n\n本文",
    contentType: "markdown",
  });
  editor.commands.setTextSelection(8);
  const card = createVideoUploadCard(
    editor,
    new File(["video"], "clip.mov"),
    new AbortController().signal,
  );
  const retry = card.retry(new Error("送信できませんでした"));
  const buttons = () => Array.from(editor.view.dom.querySelectorAll("button"));
  buttons()
    .find((b) => b.textContent === "再試行")
    ?.click();
  assert.equal(await retry, true);
  card.update("動画を変換中… 20%");
  buttons()
    .find((b) => b.textContent === "キャンセル")
    ?.click();
  assert.equal(card.signal.aborted, true);
  card.complete({
    avc: "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4",
    width: 1920,
    height: 1080,
  });
  assert.equal(editor.getMarkdown(), "タイトル\n\n本文");
  card.dispose();
  editor.destroy();
});

test("aborts an upload when its insertion position is deleted", () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "タイトル\n\n本文です",
    contentType: "markdown",
  });
  editor.commands.setTextSelection(8);
  const card = createVideoUploadCard(
    editor,
    new File(["video"], "clip.mov"),
    new AbortController().signal,
  );
  editor.commands.deleteRange({ from: 7, to: 10 });
  assert.equal(card.signal.aborted, true);
  card.dispose();
  editor.destroy();
});

test("keeps multiple dropped videos in order at their shared insertion position", () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "タイトル\n\n前後",
    contentType: "markdown",
  });
  editor.commands.setTextSelection(8);
  const signal = new AbortController().signal;
  const first = createVideoUploadCard(
    editor,
    new File(["video"], "first.mov"),
    signal,
  );
  const second = createVideoUploadCard(
    editor,
    new File(["video"], "second.mov"),
    signal,
  );
  const avc =
    "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4";
  first.complete({ avc, width: 1920, height: 1080 });
  assert.equal(second.signal.aborted, false);
  second.complete({ avc, width: 1080, height: 1920 });
  assert.match(
    editor.getMarkdown(),
    /前\n\n:::video .*1920x1080 :::\n\n:::video .*1080x1920 :::\n\n後/,
  );
  first.dispose();
  second.dispose();
  editor.destroy();
});

test("preserves uploaded video sources through Markdown save and re-edit", () => {
  const avc =
    "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4";
  const av1 =
    "/assets/uploads/2026/09/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4";
  const source = `:::video ${avc} ${av1} :::`;
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: source,
    contentType: "markdown",
  });
  assert.equal(editor.getJSON().content?.[0].type, "video");
  assert.equal(editor.getMarkdown().trim(), source);
  assert.match(editor.getHTML(), /preload="metadata"/);
  assert.match(editor.getHTML(), /av01/);
  editor.commands.setContent(editor.getMarkdown(), { contentType: "markdown" });
  assert.equal(editor.getJSON().content?.[0].attrs?.avc, avc);
  assert.equal(editor.getJSON().content?.[0].attrs?.av1, av1);
  editor.destroy();
});

test("edits video Markdown and removes the node with undo, only when editable", () => {
  const avc =
    "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4";
  const host = document.createElement("div");
  document.body.append(host);
  const editor = new Editor({
    element: host,
    extensions: EDITOR_EXTENSIONS,
    content: `:::video ${avc} :::`,
    contentType: "markdown",
  });
  const click = (label: string) => {
    const button = Array.from(host.querySelectorAll("button")).find(
      (button) => button.textContent === label,
    );
    assert.ok(button, label);
    button.click();
  };
  click("記法を編集");
  const field = host.querySelector("textarea");
  assert.ok(field);
  field.value = `:::video ${avc} 1080x1920 :::`;
  click("変更を反映");
  assert.equal(editor.getMarkdown().trim(), field.value);
  editor.commands.setContent(editor.getMarkdown(), { contentType: "markdown" });
  assert.equal(host.querySelector("video")?.getAttribute("width"), "1080");
  assert.equal(host.querySelector("video")?.getAttribute("height"), "1920");
  click("本文から削除");
  assert.equal(host.querySelector("video"), null);
  editor.commands.undo();
  assert.ok(host.querySelector("video"));
  editor.setEditable(false);
  assert.equal(
    host.querySelector<HTMLElement>(".video-node__actions")?.hidden,
    true,
  );
  click("本文から削除");
  assert.ok(host.querySelector("video"));
  editor.destroy();
  host.remove();
});

test("prefixes editor document titles only in development", () => {
  assert.equal(editorDocumentTitle("", "development"), "[dev] weblog.ason.as");
  assert.equal(
    editorDocumentTitle("2026-08-26", "development"),
    "[dev] 2026-08-26 : weblog.ason.as",
  );
  assert.equal(
    editorDocumentTitle("2026-08-26"),
    "2026-08-26 : weblog.ason.as",
  );
});

test("inserts a percent-encoded Japanese URL with a decoded label", () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "本文",
    contentType: "markdown",
  });
  const url =
    "https://jnbk.app/topics/%E4%BB%BB%E6%84%8F%E3%81%AE%E3%82%B3%E3%83%9E%E3%83%B3%E3%83%89";

  editor.commands.setTextSelection(editor.state.doc.content.size);
  assert.equal(insertPastedJapaneseUrl(editor, url), true);
  assert.equal(
    editor.getMarkdown(),
    `本文[https://jnbk.app/topics/任意のコマンド](${url})`,
  );
  editor.destroy();
});

test("leaves ordinary pasted text and ASCII URLs to the default handler", () => {
  const editor = new Editor({
    extensions: EDITOR_EXTENSIONS,
    content: "本文",
    contentType: "markdown",
  });

  assert.equal(insertPastedJapaneseUrl(editor, "URLを参照"), false);
  assert.equal(
    insertPastedJapaneseUrl(editor, "https://example.com/path"),
    false,
  );
  assert.equal(editor.getMarkdown(), "本文");
  editor.destroy();
});

test("resolves an automatic cover from the first internal article image", () => {
  assert.equal(
    autoCoverImageUrl(
      "before\n\n![first](/assets/first.webp)\n\n![second](/assets/second.webp)",
    ),
    "/assets/first.webp",
  );
  assert.equal(
    autoCoverImageUrl("![external](https://example.com/image.webp)"),
    null,
  );
});

test("formats recent and older line update times", () => {
  const now = new Date("2026-08-28T12:00:00+09:00");

  assert.equal(
    lineUpdateLabel("2026-08-23T12:00:00+09:00", now),
    "5日前に更新",
  );
  assert.equal(
    lineUpdateLabel("2021-11-14T13:24:36+09:00", now),
    "2021/11/14 13:24:36に更新",
  );
});

test("fades line update colors as updates age", () => {
  const now = new Date("2026-08-29T12:00:00+09:00");

  assert.equal(lineUpdateStrength("2026-08-29T11:30:00+09:00", now), 1);
  assert.equal(lineUpdateStrength("2026-08-29T06:00:00+09:00", now), 0.85);
  assert.equal(lineUpdateStrength("2026-08-27T12:00:00+09:00", now), 0.65);
  assert.equal(lineUpdateStrength("2026-08-15T12:00:00+09:00", now), 0.45);
  assert.equal(lineUpdateStrength("2026-07-01T12:00:00+09:00", now), 0.25);
  assert.equal(lineUpdateStrength("2026-05-31T11:59:59+09:00", now), 0);
});

test("keeps unchanged line updates and leaves edited lines pending", () => {
  assert.deepEqual(
    pendingLineUpdates(
      "最初の行\n残る行\n末尾",
      "追加行\n最初の行\n変更後\n末尾",
      ["first", "remaining", "last"],
    ),
    [null, "first", null, "last"],
  );
  assert.deepEqual(pendingLineUpdates("", "新しい記事", []), [null]);
  assert.deepEqual(
    pendingLineUpdates("最初の行\n\n末尾", "最初の行\n\n末尾", [
      "first",
      "blank",
      "last",
    ]),
    ["first", null, "last"],
  );
});

test("treats blank and non-breaking-space lines as invisible", () => {
  assert.equal(isVisibleLine(""), false);
  assert.equal(isVisibleLine("   "), false);
  assert.equal(isVisibleLine("&nbsp;"), false);
  assert.equal(isVisibleLine("本文"), true);
});

test("searches from the shared search field and renders article links", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return new Response(
      JSON.stringify({
        results: [
          {
            route: "検索の仕組み",
            title: "検索の仕組み",
            excerpt: "BM25で記事を検索する",
            updated_at: "2026-08-27T00:00:00Z",
          },
        ],
      }),
      { headers: { "Content-Type": "application/json" } },
    );
  };

  try {
    window.history.pushState({}, "", "/search?q=%E6%A4%9C%E7%B4%A2");
    await act(async () => root.render(createElement(SearchPage)));
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 220));
    });

    assert.deepEqual(requests, ["/api/search?q=%E6%A4%9C%E7%B4%A2&limit=10"]);
    const result = container.querySelector<HTMLAnchorElement>(
      ".site-search__results a",
    );
    assert.equal(result?.textContent, "検索の仕組みBM25で記事を検索する");
    assert.equal(
      result?.getAttribute("href"),
      "/%E6%A4%9C%E7%B4%A2%E3%81%AE%E4%BB%95%E7%B5%84%E3%81%BF",
    );
  } finally {
    await act(async () => root.unmount());
    window.history.pushState({}, "", "/current");
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("keeps the desktop search prompt hidden until the user engages the field", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const prototype = window.HTMLElement
    .prototype as typeof window.HTMLElement.prototype & {
    attachEvent?: () => void;
    detachEvent?: () => void;
  };
  prototype.attachEvent = () => {};
  prototype.detachEvent = () => {};
  try {
    await act(async () => root.render(createElement(SiteSearch)));
    assert.equal(container.querySelector(".site-search__message"), null);
    const input = container.querySelector<HTMLInputElement>(
      ".site-search__desktop input",
    );
    assert.ok(input);
    await act(async () =>
      input.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true })),
    );
    assert.equal(container.querySelector(".site-search__message"), null);
    await act(async () =>
      input.dispatchEvent(new window.Event("pointerdown", { bubbles: true })),
    );
    assert.equal(
      container.querySelector(".site-search__message")?.textContent,
      "キーワードを入力してください",
    );
    await act(async () =>
      input.dispatchEvent(
        new window.FocusEvent("focusout", {
          bubbles: true,
          relatedTarget: document.body,
        }),
      ),
    );
    assert.equal(container.querySelector(".site-search__message"), null);
  } finally {
    await act(async () => root.unmount());
    delete prototype.attachEvent;
    delete prototype.detachEvent;
    container.remove();
  }
});

test("opens and closes the mobile search dialog without leaving background controls active", async () => {
  const container = document.createElement("div");
  const main = document.createElement("main");
  main.id = "main";
  const navigation = document.createElement("nav");
  navigation.className = "header-nav";
  document.body.append(main, navigation, container);
  const root = createRoot(container);
  const prototype = window.HTMLElement
    .prototype as typeof window.HTMLElement.prototype & {
    attachEvent?: () => void;
    detachEvent?: () => void;
  };
  prototype.attachEvent = () => {};
  prototype.detachEvent = () => {};

  try {
    await act(async () => root.render(createElement(SiteSearch)));
    const trigger = container.querySelector<HTMLButtonElement>(
      ".site-search__mobile-button",
    );
    assert.ok(trigger);
    await act(async () => trigger.click());
    assert.ok(container.querySelector('[role="dialog"][aria-modal="true"]'));
    assert.equal(main.hasAttribute("inert"), true);
    assert.equal(navigation.hasAttribute("inert"), true);

    await act(async () =>
      document.dispatchEvent(
        new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      ),
    );
    assert.equal(container.querySelector('[role="dialog"]'), null);
    assert.equal(main.hasAttribute("inert"), false);
    assert.equal(navigation.hasAttribute("inert"), false);
  } finally {
    await act(async () => root.unmount());
    delete prototype.attachEvent;
    delete prototype.detachEvent;
    main.remove();
    navigation.remove();
    container.remove();
  }
});

test("ignores URLs in inline and fenced code when building embeds", () => {
  const body = [
    "https://example.com/article",
    "`https://inline.example.com/full/path`",
    "```js",
    'const endpoint = "https://fenced.example.com/full/path";',
    "```",
  ].join("\n");

  assert.deepEqual(extractEmbeddableUrls(body), [
    "https://example.com/article",
  ]);
});

test("keeps universe references stable while editing prose", () => {
  const before = universeReferences(
    "日記の本文 [[Calico]] https://example.com/article",
  );
  const after = universeReferences(
    "日記の本文を追記した [[Calico]] https://example.com/article",
  );

  assert.equal(after.wikiLinkKey, before.wikiLinkKey);
  assert.equal(after.externalUrlKey, before.externalUrlKey);
  assert.notEqual(
    universeReferences("[[Calico]] [[TipTap]]").wikiLinkKey,
    before.wikiLinkKey,
  );
  assert.notEqual(
    universeReferences("[[Calico]] https://example.com/other").externalUrlKey,
    before.externalUrlKey,
  );
});

test("does not fetch previews until a graph node is selected, even after editor input", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const originalResizeObserver = globalThis.ResizeObserver;
  const originalCss = globalThis.CSS;
  const originalNodeFilter = globalThis.NodeFilter;
  const originalMatchMedia = window.matchMedia;
  const rangePrototype = window.Range.prototype as Range & {
    getBoundingClientRect?: () => DOMRect;
  };
  const originalRangeRect = rangePrototype.getBoundingClientRect;
  const originalUniverse = document.documentElement.dataset.universe;
  let embedFetchCount = 0;
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  globalThis.CSS = { escape: (value: string) => value } as typeof CSS;
  globalThis.NodeFilter = window.NodeFilter;
  window.matchMedia = () =>
    ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }) as unknown as MediaQueryList;
  rangePrototype.getBoundingClientRect = () =>
    ({
      bottom: 0,
      height: 0,
      left: 0,
      right: 0,
      top: 0,
      width: 0,
      x: 0,
      y: 0,
      toJSON: () => ({}),
    }) as DOMRect;
  document.documentElement.dataset.universe = "on";
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.startsWith("/api/embed?")) {
      embedFetchCount += 1;
      return new Response(
        JSON.stringify({
          url: "https://example.com/article",
          title: "Example",
          site_name: "example.com",
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    return minimalEditorFetch(input);
  };
  const bootstrap = {
    ...minimalEditorBootstrap(),
    body: "本文 https://example.com/article",
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    assert.equal(embedFetchCount, 0);
    const element = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(element);
    const mountedEditor = (element as HTMLElement & { editor: Editor }).editor;

    await act(async () => {
      mountedEditor.commands.insertContent("追記");
      await new Promise((resolve) => setTimeout(resolve, 1050));
    });

    assert.equal(embedFetchCount, 0);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    globalThis.ResizeObserver = originalResizeObserver;
    globalThis.CSS = originalCss;
    globalThis.NodeFilter = originalNodeFilter;
    window.matchMedia = originalMatchMedia;
    rangePrototype.getBoundingClientRect = originalRangeRect;
    if (originalUniverse === undefined)
      delete document.documentElement.dataset.universe;
    else document.documentElement.dataset.universe = originalUniverse;
    container.remove();
  }
});

test("does not fetch embeds while the universe is disabled", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const originalUniverse = document.documentElement.dataset.universe;
  let embedFetchCount = 0;
  document.documentElement.dataset.universe = "off";
  globalThis.fetch = async (input) => {
    if (String(input).startsWith("/api/embed?")) embedFetchCount += 1;
    return minimalEditorFetch(input);
  };

  try {
    await act(async () => {
      root.render(
        createElement(AuthoringEditor, {
          bootstrap: {
            ...minimalEditorBootstrap(),
            body: "本文 https://example.com/article",
          },
        }),
      );
      await new Promise((resolve) => setTimeout(resolve, 20));
    });

    assert.equal(embedFetchCount, 0);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    if (originalUniverse === undefined)
      delete document.documentElement.dataset.universe;
    else document.documentElement.dataset.universe = originalUniverse;
    container.remove();
  }
});

test("recognizes image files and inbox photos as image drags", () => {
  assert.equal(
    isImageDrag({ items: [{ kind: "file", type: "image/png" }] }),
    true,
  );
  assert.equal(
    isImageDrag({ items: [{ kind: "file", type: "text/plain" }] }),
    false,
  );
  assert.equal(
    isImageDrag({ types: ["application/x-weblog-inbox-item-id"] }),
    true,
  );
});

function minimalEditorBootstrap(): EditorBootstrap {
  return {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-29T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };
}

function minimalEditorFetch(input: RequestInfo | URL): Promise<Response> {
  const url = String(input);
  if (url === "/api/inbox") {
    return Promise.resolve(
      new Response(JSON.stringify({ items: [] }), {
        headers: { "content-type": "application/json" },
      }),
    );
  }
  if (url.startsWith("/api/page-names")) {
    return Promise.resolve(
      new Response(JSON.stringify({ names: [] }), {
        headers: { "content-type": "application/json" },
      }),
    );
  }
  if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
    return Promise.resolve(
      new Response(
        JSON.stringify({
          mode: "editor",
          id: "page-id",
          page_type: "named",
          date: null,
          name: "current",
          title: null,
          updated_at: "2026-08-29T12:00:00+09:00",
          route: "current",
          body: "本文",
          linked_pages: [],
          linked_pages_has_more: false,
        }),
        { headers: { "content-type": "application/json", etag: '"same"' } },
      ),
    );
  }
  return Promise.reject(new Error(`unexpected request: ${url}`));
}

test("keeps the authoring React tree out of each editor input", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const rangePrototype = window.Range.prototype as Range & {
    getBoundingClientRect?: () => DOMRect;
  };
  const originalRangeRect = rangePrototype.getBoundingClientRect;
  globalThis.fetch = minimalEditorFetch;
  let lineMeasurementCount = 0;
  let renderCount = 0;
  rangePrototype.getBoundingClientRect = () => {
    lineMeasurementCount += 1;
    return document.body.getBoundingClientRect();
  };

  try {
    await act(async () => {
      root.render(
        createElement(
          Profiler,
          {
            id: "authoring-editor",
            onRender: () => {
              renderCount += 1;
            },
          },
          createElement(AuthoringEditor, {
            bootstrap: minimalEditorBootstrap(),
          }),
        ),
      );
      await new Promise((resolve) => setTimeout(resolve, 100));
    });
    const element = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(element);
    const mountedEditor = (element as HTMLElement & { editor: Editor }).editor;
    act(() =>
      mountedEditor.commands.setTextSelection(
        mountedEditor.state.doc.content.size - 1,
      ),
    );
    lineMeasurementCount = 0;
    renderCount = 0;

    await act(async () => {
      mountedEditor.commands.insertContent("追記");
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

    assert.equal(lineMeasurementCount, 0);
    assert.equal(renderCount, 0);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    rangePrototype.getBoundingClientRect = originalRangeRect;
    container.remove();
  }
});

test("pastes one Japanese URL link through the editor event path", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = minimalEditorFetch;
  const url =
    "https://jnbk.app/topics/%E4%BB%BB%E6%84%8F%E3%81%AE%E3%82%B3%E3%83%9E%E3%83%B3%E3%83%89";
  try {
    await act(async () => {
      root.render(
        createElement(AuthoringEditor, { bootstrap: minimalEditorBootstrap() }),
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const element = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(element);
    const mountedEditor = (element as HTMLElement & { editor: Editor }).editor;
    mountedEditor.commands.setTextSelection(
      mountedEditor.state.doc.content.size,
    );
    const event = new window.Event("paste", {
      bubbles: true,
      cancelable: true,
    });
    Object.defineProperty(event, "clipboardData", {
      value: {
        files: [],
        getData: (type: string) => (type === "text/plain" ? url : ""),
      },
    });

    await act(async () => {
      element.dispatchEvent(event);
    });

    assert.equal(
      mountedEditor.getMarkdown(),
      `current\n\n本文[https://jnbk.app/topics/任意のコマンド](${url})`,
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("navigates material tabs with arrows, Home, and End", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = minimalEditorFetch;
  try {
    await act(async () => {
      root.render(
        createElement(AuthoringEditor, { bootstrap: minimalEditorBootstrap() }),
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const selectedLabel = () =>
      container
        .querySelector('[role="tab"][aria-selected="true"]')
        ?.getAttribute("aria-label");
    const press = async (label: string, key: string) => {
      await act(async () => {
        const tab = container.querySelector<HTMLButtonElement>(
          `[role="tab"][aria-label="${label}"]`,
        );
        assert.ok(tab);
        tab.dispatchEvent(
          new window.KeyboardEvent("keydown", { key, bubbles: true }),
        );
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
    };
    await press("写真", "End");
    assert.equal(selectedLabel(), "Raindrop");
    await press("Raindrop", "ArrowUp");
    assert.equal(selectedLabel(), "Bluesky");
    await press("Bluesky", "ArrowRight");
    assert.equal(selectedLabel(), "Raindrop");
    await press("Raindrop", "Home");
    assert.equal(selectedLabel(), "写真");
    assert.equal(document.activeElement?.getAttribute("aria-label"), "写真");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("adopts an inbox photo and marks it as used by the current page", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const savedPayloads: Array<Record<string, unknown>> = [];
  let resolveSave: (() => void) | null = null;
  const waitForSave = () =>
    new Promise<void>((resolve) => {
      resolveSave = resolve;
    });
  const pageResponse = {
    mode: "editor",
    id: "page-id",
    page_type: "named",
    date: null,
    name: "current",
    title: null,
    updated_at: "2026-08-26T12:00:00+09:00",
    route: "current",
    body: "本文",
    linked_pages: [],
    linked_pages_has_more: false,
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url === "/api/inbox") {
      return new Response(
        JSON.stringify({
          items: [
            {
              id: "item-1",
              source: "photo",
              kind: "photo",
              source_id: "photo-1",
              occurred_at: "2026-08-26T11:00:00+09:00",
              ingested_at: "2026-08-26T11:00:00+09:00",
              expires_at: "2026-09-02T11:00:00+09:00",
              payload: {
                inbox_key: "/assets/inbox/photo-1.jpg",
                preview_url: "/assets/inbox/thumbnails/photo-1.webp",
              },
              used_in_pages: [],
            },
          ],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    if (url === "/api/inbox/adopt") {
      const itemId = JSON.parse(String(init?.body)).item_id;
      return new Response(
        JSON.stringify({
          public_url: `/assets/uploads/2026/08/${itemId}.webp`,
        }),
        {
          headers: { "content-type": "application/json" },
        },
      );
    }
    if (url === "/api/authoring/pages/page-id") {
      savedPayloads.push(JSON.parse(String(init?.body)));
      resolveSave?.();
      resolveSave = null;
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json", etag: '"same"' },
      });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-26T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    assert.equal(
      container
        .querySelector('[role="tab"][aria-selected="true"]')
        ?.getAttribute("aria-label"),
      "写真",
    );

    const transferData = new Map<string, string>();
    const dataTransfer = {
      files: [],
      items: [],
      types: [] as Array<string>,
      effectAllowed: "none",
      dropEffect: "none",
      setData(type: string, value: string) {
        transferData.set(type, value);
        if (!this.types.includes(type)) this.types.push(type);
      },
      getData(type: string) {
        return transferData.get(type) || "";
      },
    };
    const remainingItem = container.querySelector<HTMLButtonElement>(
      ".content-inbox__item",
    );
    assert.ok(remainingItem);
    assert.equal(
      remainingItem.querySelector<HTMLImageElement>("img")?.getAttribute("src"),
      "/assets/inbox/thumbnails/photo-1.webp",
    );
    const dragStart = new window.Event("dragstart", {
      bubbles: true,
      cancelable: true,
    });
    Object.defineProperty(dragStart, "dataTransfer", { value: dataTransfer });
    remainingItem.dispatchEvent(dragStart);
    assert.equal(dataTransfer.effectAllowed, "copy");

    let nativeDropObserved = false;
    const editorElement = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(editorElement);
    editorElement.addEventListener("drop", () => {
      nativeDropObserved = true;
    });
    const dropSave = waitForSave();
    await act(async () => {
      const drop = new window.Event("drop", {
        bubbles: true,
        cancelable: true,
      });
      Object.defineProperties(drop, {
        dataTransfer: { value: dataTransfer },
        clientX: { value: 0 },
        clientY: { value: 0 },
      });
      editorElement.dispatchEvent(drop);
      await dropSave;
    });

    assert.equal(nativeDropObserved, false);
    assert.equal(savedPayloads.length, 1);
    assert.equal(savedPayloads[0].cover_mode, "auto");
    assert.equal(savedPayloads[0].cover_image_url, null);
    assert.deepEqual(savedPayloads[0].consumed_inbox_item_ids, ["item-1"]);
    assert.match(
      String(savedPayloads[0].body),
      /\/assets\/uploads\/2026\/08\/item-1\.webp/,
    );
    assert.notEqual(container.querySelector(".content-inbox__item"), null);
    assert.equal(
      container.querySelector(".content-inbox__usage")?.textContent,
      "currentで使用済み",
    );
    const coverSave = waitForSave();
    await act(async () => {
      const coverButton = container.querySelector<HTMLButtonElement>(
        '[aria-label$="をカバーに設定"]',
      );
      assert.ok(coverButton);
      coverButton.click();
      await coverSave;
    });
    assert.equal(savedPayloads.at(-1)?.cover_mode, "explicit");
    assert.equal(
      savedPayloads.at(-1)?.cover_image_url,
      "/assets/uploads/2026/08/item-1.webp",
    );
    assert.equal(
      container
        .querySelector(".article-editing-cover__actions input:checked")
        ?.getAttribute("value"),
      "explicit",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("reuses a video material after removing it from the body without uploading or consuming it", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  const saved: Array<Record<string, unknown>> = [];
  const avc =
    "/assets/uploads/2026/09/11111111-2222-3333-4444-555555555555.mp4";
  const av1 =
    "/assets/uploads/2026/09/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.mp4";
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-26T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };
  const pageResponse = {
    ...bootstrap,
    mode: "editor",
    id: "page-id",
    updated_at: bootstrap.expected_updated_at,
  };
  let saveComplete: (() => void) | undefined;
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    requests.push(url);
    let result: unknown;
    if (url === "/api/inbox")
      result = {
        items: [
          {
            id: "video-1",
            source: "video",
            kind: "video",
            source_id: "video-1",
            occurred_at: bootstrap.expected_updated_at,
            ingested_at: bootstrap.expected_updated_at,
            expires_at: null,
            used_in_pages: [],
            payload: {
              avc,
              av1,
              width: 1920,
              height: 1080,
              duration: 33.44,
              name: "IMG_0010.MOV",
            },
          },
        ],
      };
    else if (url === "/api/authoring/pages/page-id") {
      const payload = JSON.parse(String(init?.body));
      saved.push(payload);
      result = { ...pageResponse, body: payload.body };
      saveComplete?.();
    } else if (url.startsWith("/api/page-names")) result = { names: [] };
    else if (url.startsWith("/api/routes/") || url.startsWith("/api/related"))
      result = pageResponse;
    else throw new Error(`unexpected request: ${url}`);
    return new Response(JSON.stringify(result), {
      headers: { "content-type": "application/json" },
    });
  };
  const clickAndSave = async (selector: string) => {
    const completed = new Promise<void>((resolve) => {
      saveComplete = resolve;
    });
    await act(async () => {
      const button = container.querySelector<HTMLButtonElement>(selector);
      assert.ok(button);
      button.click();
      await Promise.race([
        completed,
        new Promise((_, reject) =>
          setTimeout(
            () =>
              reject(
                new Error(
                  `Save did not complete: ${selector}; ${container.querySelector(".ProseMirror")?.innerHTML}`,
                ),
              ),
            2000,
          ),
        ),
      ]);
    });
  };
  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    assert.deepEqual(
      Array.from(container.querySelectorAll('[role="tab"]'), (tab) =>
        tab.getAttribute("aria-label"),
      ),
      ["写真", "動画", "Bluesky", "Raindrop"],
    );
    await act(async () => {
      container
        .querySelector<HTMLButtonElement>('[role="tab"][aria-label="写真"]')
        ?.dispatchEvent(
          new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
        );
      await new Promise((resolve) => setTimeout(resolve, 5));
    });
    assert.equal(document.activeElement?.getAttribute("aria-label"), "動画");
    assert.equal(
      container.querySelector(".content-inbox__excerpt")?.textContent,
      "33秒 / 1920×1080",
    );
    await clickAndSave(".content-inbox__item");
    assert.match(String(saved.at(-1)?.body), /:::video/);
    assert.ok(String(saved.at(-1)?.body).includes(avc));
    assert.ok(String(saved.at(-1)?.body).includes(av1));
    await clickAndSave(
      ".ProseMirror .video-node__actions > button:nth-child(2)",
    );
    assert.doesNotMatch(String(saved.at(-1)?.body), /:::video/);
    assert.ok(container.querySelector(".content-inbox__item"));
    await clickAndSave(".content-inbox__item");
    assert.match(String(saved.at(-1)?.body), /:::video/);
    assert.deepEqual(saved.at(-1)?.consumed_inbox_item_ids, []);
    await act(async () => {
      container
        .querySelector<HTMLButtonElement>(".content-inbox__sync")
        ?.click();
    });
    assert.equal(requests.filter((url) => url === "/api/inbox").length, 2);
    assert.ok(
      requests.every(
        (url) =>
          !url.startsWith("/api/uploads") && !url.startsWith("/api/inbox/sync"),
      ),
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("inserts a Raindrop URL and marks it as used by the current page", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const savedPayloads: Array<Record<string, unknown>> = [];
  let resolveSave: (() => void) | null = null;
  const pageResponse = {
    mode: "editor",
    id: "page-id",
    page_type: "named",
    date: null,
    name: "current",
    title: null,
    updated_at: "2026-08-29T12:00:00+09:00",
    route: "current",
    body: "本文",
    linked_pages: [],
    linked_pages_has_more: false,
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url === "/api/inbox") {
      return new Response(
        JSON.stringify({
          items: [
            {
              id: "bookmark-1",
              source: "raindrop",
              kind: "bookmark",
              source_id: "42",
              occurred_at: "2026-08-29T11:00:00+09:00",
              ingested_at: "2026-08-29T12:00:00+09:00",
              expires_at: "2026-09-05T12:00:00+09:00",
              payload: {
                raindrop_id: 42,
                url: "https://example.com/article",
                title: "Article",
                excerpt: "An article summary from Raindrop.",
                cover: "https://cdn.example/article.jpg",
              },
              used_in_pages: [],
            },
          ],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    if (url === "/api/authoring/pages/page-id") {
      savedPayloads.push(JSON.parse(String(init?.body)));
      resolveSave?.();
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json", etag: '"same"' },
      });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-29T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => {
      const tab = container.querySelector<HTMLButtonElement>(
        '[role="tab"][aria-label="Raindrop"]',
      );
      assert.ok(tab);
      tab.click();
      await Promise.resolve();
    });

    const item = container.querySelector<HTMLButtonElement>(
      ".content-inbox__item",
    );
    assert.ok(item);
    assert.equal(item.getAttribute("aria-label"), "Articleを本文へ追加");
    assert.equal(
      item.querySelector(".content-inbox__title")?.textContent,
      "Article",
    );
    assert.equal(
      item.querySelector(".content-inbox__excerpt")?.textContent,
      "An article summary from Raindrop.",
    );
    assert.equal(
      item.querySelector<HTMLImageElement>(".content-inbox__thumbnail")?.src,
      "https://cdn.example/article.jpg",
    );

    const saved = new Promise<void>((resolve) => {
      resolveSave = resolve;
    });
    await act(async () => {
      item.click();
      await Promise.race([
        saved,
        new Promise((resolve) => setTimeout(resolve, 1_000)),
      ]);
    });

    assert.deepEqual(savedPayloads[0].consumed_inbox_item_ids, ["bookmark-1"]);
    assert.match(
      String(savedPayloads[0].body),
      /https:\/\/example\.com\/article/,
    );
    assert.equal(
      container.querySelector(".content-inbox__usage")?.textContent,
      "currentで使用済み",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("inserts Bluesky post and like URLs and marks them as used", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const savedPayloads: Array<Record<string, unknown>> = [];
  let resolveSave: (() => void) | null = null;
  const pageResponse = {
    mode: "editor",
    id: "page-id",
    page_type: "named",
    date: null,
    name: "current",
    title: null,
    updated_at: "2026-08-29T12:00:00+09:00",
    route: "current",
    body: "本文",
    linked_pages: [],
    linked_pages_has_more: false,
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url === "/api/inbox") {
      return new Response(
        JSON.stringify({
          items: [
            {
              id: "like-1",
              source: "bluesky",
              kind: "like",
              source_id:
                "at://did:plc:nzhcpsryikfegc27zbimbwhq/app.bsky.feed.like/3mlike",
              occurred_at: "2026-08-29T11:30:00+09:00",
              ingested_at: "2026-08-29T12:00:00+09:00",
              expires_at: "2026-09-05T12:00:00+09:00",
              payload: {
                canonical_url:
                  "https://bsky.app/profile/did:plc:author/post/3mliked",
                text: "Liked post text",
                author_handle: "author.example",
                author_display_name: "Author",
                thumbnail_url: "https://cdn.example/liked.jpg",
              },
              used_in_pages: [],
            },
            {
              id: "post-1",
              source: "bluesky",
              kind: "post",
              source_id:
                "at://did:plc:nzhcpsryikfegc27zbimbwhq/app.bsky.feed.post/3mexample",
              occurred_at: "2026-08-29T11:00:00+09:00",
              ingested_at: "2026-08-29T12:00:00+09:00",
              expires_at: "2026-09-05T12:00:00+09:00",
              payload: {
                canonical_url:
                  "https://bsky.app/profile/did:plc:nzhcpsryikfegc27zbimbwhq/post/3mexample",
                text: "My post text",
              },
              used_in_pages: [],
            },
          ],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    if (url === "/api/authoring/pages/page-id") {
      savedPayloads.push(JSON.parse(String(init?.body)));
      resolveSave?.();
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json", etag: '"same"' },
      });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-29T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => {
      const tab = container.querySelector<HTMLButtonElement>(
        '[role="tab"][aria-label="Bluesky"]',
      );
      assert.ok(tab);
      tab.click();
      await Promise.resolve();
    });

    const items = container.querySelectorAll<HTMLButtonElement>(
      ".content-inbox__item",
    );
    assert.equal(items.length, 2);
    assert.equal(
      items[0].getAttribute("aria-label"),
      "Bluesky いいねを本文へ追加",
    );
    assert.equal(
      items[1].getAttribute("aria-label"),
      "Bluesky 投稿を本文へ追加",
    );
    assert.equal(
      items[0].querySelector(".content-inbox__title")?.textContent,
      "Author",
    );
    assert.equal(
      items[0].querySelector(".content-inbox__excerpt")?.textContent,
      "Liked post text",
    );
    assert.equal(
      items[1].querySelector(".content-inbox__excerpt")?.textContent,
      "My post text",
    );

    const saved = new Promise<void>((resolve) => {
      resolveSave = resolve;
    });
    await act(async () => {
      items[0].click();
      await Promise.race([
        saved,
        new Promise((resolve) => setTimeout(resolve, 1_000)),
      ]);
    });

    assert.deepEqual(savedPayloads[0].consumed_inbox_item_ids, ["like-1"]);
    assert.match(
      String(savedPayloads[0].body),
      /https:\/\/bsky\.app\/profile\/did:plc:author\/post\/3mliked/,
    );
    assert.equal(
      items[0].querySelector(".content-inbox__usage")?.textContent,
      "currentで使用済み",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("manually synchronizes the inbox and refreshes it after completion", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  const syncPayloads: Array<unknown> = [];
  let inboxReads = 0;
  const pageResponse = {
    mode: "editor",
    id: "page-id",
    page_type: "named",
    date: null,
    name: "current",
    title: null,
    updated_at: "2026-08-26T12:00:00+09:00",
    route: "current",
    body: "本文",
    linked_pages: [],
    linked_pages_has_more: false,
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    requests.push(url);
    if (url === "/api/inbox") {
      inboxReads += 1;
      return new Response(
        JSON.stringify({
          items:
            inboxReads === 1
              ? []
              : [
                  {
                    id: "bookmark-1",
                    source: "raindrop",
                    kind: "bookmark",
                    source_id: "1",
                    occurred_at: "2026-08-28T11:00:00+09:00",
                    ingested_at: "2026-08-28T12:00:00+09:00",
                    expires_at: "2026-09-04T12:00:00+09:00",
                    payload: { url: "https://example.com" },
                    used_in_pages: [],
                  },
                ],
        }),
        { headers: { "content-type": "application/json" } },
      );
    }
    if (url === "/api/inbox/sync") {
      syncPayloads.push(JSON.parse(String(init?.body)));
      return new Response(
        JSON.stringify({ run_id: "run-1", status: "queued" }),
        {
          status: 202,
          headers: { "content-type": "application/json" },
        },
      );
    }
    if (url === "/api/inbox/sync/run-1") {
      return new Response(
        JSON.stringify({ id: "run-1", status: "succeeded", sources: [] }),
        {
          headers: { "content-type": "application/json" },
        },
      );
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), {
        headers: { "content-type": "application/json" },
      });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), {
        headers: { "content-type": "application/json", etag: '"same"' },
      });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "本文",
    expected_updated_at: "2026-08-26T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => {
      const tab = container.querySelector<HTMLButtonElement>(
        '[role="tab"][aria-label="Bluesky"]',
      );
      assert.ok(tab);
      tab.click();
    });
    await act(async () => {
      const syncButton = container.querySelector<HTMLButtonElement>(
        ".content-inbox__sync",
      );
      assert.ok(syncButton);
      syncButton.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

    assert.deepEqual(
      requests.filter((url) => url.startsWith("/api/inbox")),
      ["/api/inbox", "/api/inbox/sync", "/api/inbox/sync/run-1", "/api/inbox"],
    );
    assert.deepEqual(syncPayloads, [{ sources: ["bluesky"] }]);
    assert.equal(container.querySelector('[aria-label="更新対象"]'), null);
    await act(async () => {
      const tab = container.querySelector<HTMLButtonElement>(
        '[role="tab"][aria-label="Raindrop"]',
      );
      assert.ok(tab);
      tab.click();
    });
    assert.equal(
      container.querySelector(".content-inbox__kind")?.textContent,
      "Raindrop",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("extracts video IDs from YouTube URLs", () => {
  assert.equal(
    youtubeVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
    "dQw4w9WgXcQ",
  );
  assert.equal(
    youtubeVideoId("https://youtu.be/dQw4w9WgXcQ?t=42"),
    "dQw4w9WgXcQ",
  );
  assert.equal(
    youtubeVideoId("https://www.youtube.com/shorts/dQw4w9WgXcQ"),
    "dQw4w9WgXcQ",
  );
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
      status: "ready",
    }),
    "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
  );
});

test("falls back when a maximum resolution YouTube thumbnail is unavailable", () => {
  const image = document.createElement("img");
  image.src = "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg";
  image.dataset.youtubeThumbnailFallback =
    "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg";

  applyYouTubeThumbnailFallback(image);

  assert.equal(image.src, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg");
  assert.equal(image.dataset.youtubeThumbnailFallback, undefined);
});

test("shows the YouTube thumbnail and URL after a player error", () => {
  const wrapper = document.createElement("div");
  wrapper.className = "youtube-player";
  wrapper.innerHTML =
    '<iframe data-youtube-player-frame></iframe><a class="youtube-player__fallback" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">URL</a>';
  const iframe = wrapper.querySelector("iframe");
  assert.ok(iframe);

  showYouTubeFallback(iframe);

  assert.equal(wrapper.classList.contains("youtube-player--fallback"), true);
  assert.equal(
    wrapper.querySelector<HTMLAnchorElement>(".youtube-player__fallback")?.href,
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  );
});

test("renders a standalone YouTube URL in the editor and preserves its Markdown", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ",
    contentType: "markdown",
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(editor.state.doc.child(1).type.name, "youtubePlayer");
  assert.match(editor.getHTML(), /youtube\.com\/embed\/dQw4w9WgXcQ/);
  assert.match(editor.getHTML(), /YouTubeで見る/);
  assert.match(editor.getHTML(), /aria-label="YouTubeで動画を見る"/);
  assert.match(
    editor.getMarkdown(),
    /https:\/\/www\.youtube\.com\/watch\?v=dQw4w9WgXcQ/,
  );
  editor.destroy();
});

test("pastes a Speaker Deck URL as a player while preserving Markdown and URL editing", async (t) => {
  const url = "https://speakerdeck.com/asonas/module-synths-end";
  const playerUrl =
    "https://speakerdeck.com/player/01c1db30c790447fafdf79a27979b67e";
  t.mock.method(globalThis, "fetch", async (input: string) => {
    assert.equal(input, `/api/embed?${new URLSearchParams({ url })}`);
    return new Response(
      JSON.stringify({
        title: "module Synths; end",
        speakerdeck: { src: playerUrl, width: 710, height: 399 },
      }),
    );
  });
  const element = document.createElement("div");
  document.body.append(element);
  const editor = new Editor({
    element,
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n",
    contentType: "markdown",
  });
  try {
    editor.commands.insertContentAt(editor.state.doc.content.size, {
      type: "paragraph",
    });
    editor.commands.setTextSelection(editor.state.doc.content.size - 1);
    editor.view.pasteText(url);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(editor.state.doc.child(2).type.name, "speakerdeckPlayer");
    assert.equal(element.querySelector("iframe")?.src, playerUrl);
    assert.equal(
      element.querySelector("iframe")?.style.aspectRatio,
      "710 / 399",
    );
    assert.match(
      editor.getMarkdown(),
      /https:\/\/speakerdeck.com\/asonas\/module-synths-end/,
    );
    const position =
      editor.state.doc.child(0).nodeSize + editor.state.doc.child(1).nodeSize;
    editor.setEditable(false);
    editor.commands.setNodeSelection(position);
    assert.equal(editor.state.doc.child(2).type.name, "speakerdeckPlayer");
    editor.setEditable(true);
    editor.commands.setNodeSelection(position);
    assert.equal(editor.state.doc.child(2).type.name, "paragraph");
    assert.equal(editor.state.doc.child(2).textContent, url);
  } finally {
    editor.destroy();
    element.remove();
  }
});

test("keeps Speaker Deck links usable when metadata fails or contains an unsafe player", async (t) => {
  const { loadSpeakerDeck } = await import("./speakerDeck");
  const url = "https://speakerdeck.com/asonas/module-synths-end";
  for (const response of [
    new Response("", { status: 502 }),
    new Response(
      JSON.stringify({
        speakerdeck: {
          src: "https://example.com/player",
          width: 710,
          height: 399,
        },
      }),
    ),
  ]) {
    t.mock.method(globalThis, "fetch", async () => response);
    const element = document.createElement("div");
    element.dataset.speakerdeckPlayer = url;
    element.innerHTML = `<a href="${url}">${url}</a>`;
    const cleanup = loadSpeakerDeck(element);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(element.querySelector("iframe"), null);
    assert.equal(element.querySelector("a")?.href, url);
    cleanup();
  }
});

test("renders a standalone Bluesky post URL in the editor and preserves its Markdown", async () => {
  const url =
    "https://bsky.app/profile/did:plc:nzhcpsryikfegc27zbimbwhq/post/3muc4ata4ys2r";
  const element = document.createElement("div");
  document.body.append(element);
  const editor = new Editor({
    element,
    extensions: EDITOR_EXTENSIONS,
    content: `title\n\n${url}`,
    contentType: "markdown",
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(editor.state.doc.child(1).type.name, "blueskyPlayer");
  assert.match(
    editor.getHTML(),
    /embed\.bsky\.app\/embed\/did:plc:nzhcpsryikfegc27zbimbwhq\/app\.bsky\.feed\.post\/3muc4ata4ys2r/,
  );
  const iframe = element.querySelector<HTMLIFrameElement>(
    ".bluesky-player iframe",
  );
  assert.ok(iframe);
  assert.ok(iframe.dataset.blueskyId);

  window.dispatchEvent(
    new window.MessageEvent("message", {
      origin: "https://embed.bsky.app",
      data: { id: iframe.dataset.blueskyId, height: 608 },
    }),
  );

  assert.equal(iframe.style.height, "608px");
  assert.match(editor.getMarkdown(), new RegExp(url.replaceAll(".", "\\.")));
  editor.destroy();
  element.remove();
});

test("keeps embedded players rendered when selected in read-only mode", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content:
      "title\n\nhttps://bsky.app/profile/did:plc:example/post/3mexample\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ",
    contentType: "markdown",
    editable: false,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  const title = editor.state.doc.firstChild;
  assert.ok(title);
  editor.commands.setNodeSelection(title.nodeSize);
  assert.equal(editor.state.doc.child(1).type.name, "blueskyPlayer");

  const blueskyPlayer = editor.state.doc.child(1);
  editor.commands.setNodeSelection(title.nodeSize + blueskyPlayer.nodeSize);
  assert.equal(editor.state.doc.child(2).type.name, "youtubePlayer");
  editor.destroy();
});

test("edits a selected YouTube player as its original URL", async () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ\n\nbody",
    contentType: "markdown",
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const firstChild = editor.state.doc.firstChild;
  assert.ok(firstChild);
  const playerPosition = firstChild.nodeSize;

  editor.commands.setNodeSelection(playerPosition);

  assert.equal(editor.state.doc.child(1).type.name, "paragraph");
  assert.equal(
    editor.state.doc.child(1).textContent,
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
  );
  assert.ok(editor.state.selection instanceof TextSelection);

  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.equal(editor.state.doc.child(1).type.name, "youtubePlayer");
  editor.destroy();
});

test("finds and filters the unfinished Wiki link at the cursor", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n[[2026-",
    contentType: "markdown",
  });
  editor.commands.focus("end");

  assert.equal(wikiLinkQuery(editor)?.value, "2026-");
  assert.deepEqual(
    matchingWikiLinkNames(["2026-08-23", "topic", "2026-08-22"], "2026-"),
    ["2026-08-23", "2026-08-22"],
  );
  editor.destroy();
});

test("limits Wiki link suggestions to seven matches", () => {
  assert.deepEqual(
    matchingWikiLinkNames(
      Array.from({ length: 8 }, (_, index) => `topic-${index + 1}`),
      "topic-",
    ),
    [
      "topic-1",
      "topic-2",
      "topic-3",
      "topic-4",
      "topic-5",
      "topic-6",
      "topic-7",
    ],
  );
});

test("replaces the complete Wiki link through the suggestion event path", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    if (String(input).startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: ["test2"] }), {
        headers: { "content-type": "application/json" },
      });
    }
    return minimalEditorFetch(input);
  };

  try {
    await act(async () => {
      root.render(
        createElement(AuthoringEditor, {
          bootstrap: { ...minimalEditorBootstrap(), body: "[[test]]" },
        }),
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const element = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(element);
    const mountedEditor = (element as HTMLElement & { editor: Editor }).editor;
    let cursor: number | null = null;
    mountedEditor.state.doc.descendants((node, position) => {
      const link = node.marks.find(
        (mark) => mark.type.name === "link" && mark.attrs.href === "/test",
      );
      if (node.isText && node.text === "test" && link) cursor = position + 2;
    });
    assert.notEqual(cursor, null);

    await act(async () => {
      mountedEditor.commands.setTextSelection(cursor as number);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const option = container.querySelector<HTMLButtonElement>(
      ".wiki-link-suggestions__option",
    );
    assert.ok(option);

    await act(async () => option.click());

    assert.equal(
      markdownForSource(mountedEditor.getMarkdown()),
      "current\n\n[[test2]]",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
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

  assert.deepEqual(imageDimensions(bytes.buffer, "image/png"), {
    width: 4000,
    height: 3000,
  });
  assert.deepEqual(resizedDimensions({ width: 4000, height: 3000 }), {
    width: 2560,
    height: 1920,
  });
});

test("applies JPEG EXIF orientation before resizing", () => {
  const bytes = Uint8Array.from([
    0xff, 0xd8, 0xff, 0xe1, 0x00, 0x22, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
    0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x12, 0x01,
    0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xff, 0xe1, 0x00, 0x08, 0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f,
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x0f, 0xb0, 0x17, 0x80, 0x01, 0x01, 0x11,
    0x00, 0xff, 0xd9,
  ]);

  const dimensions = imageDimensions(bytes.buffer, "image/jpeg");
  assert.deepEqual(dimensions, { width: 4016, height: 6016 });
  assert.ok(dimensions);
  assert.deepEqual(resizedDimensions(dimensions), {
    width: 1709,
    height: 2560,
  });
});

test("round trips an uploaded image as Markdown", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nbody",
    contentType: "markdown",
  });

  editor.commands.focus("end");
  editor.commands.setImage({
    src: "/assets/uploads/2026/08/image.webp",
    alt: "",
  });

  assert.match(
    editor.getMarkdown(),
    /!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/,
  );
  editor.destroy();
});

test("keeps an uploaded image out of the title line", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title",
    contentType: "markdown",
  });

  ensureBodySelection(editor);
  editor.commands.setImage({
    src: "/assets/uploads/2026/08/image.webp",
    alt: "",
  });

  assert.equal(editor.state.doc.childCount, 3);
  assert.equal(editor.state.doc.firstChild?.type.name, "paragraph");
  assert.equal(editor.state.doc.firstChild?.textContent, "title");
  assert.match(
    editor.getMarkdown(),
    /^title\n\n!\[\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/,
  );
  editor.destroy();
});

test("keeps the current page hub while omitting its self node", () => {
  const backlink: EditorBootstrap["linked_pages"][number] = {
    id: "daily-page",
    title: "2026-08-23",
    route: "2026-08-23",
    created_at: "2026-08-23T00:00:00+09:00",
    excerpt: "Calicoについて",
    image_url: null,
    related_by: ["Calico"],
  };
  const currentPage = {
    ...backlink,
    id: "calico",
    title: "Calico",
    route: "Calico",
  };

  const groups = buildInternalUniverseGroups(
    "[[Calico]]\n\nhttps://calicocat.app/",
    "Calico",
    [
      {
        kind: "wiki",
        name: "Calico",
        pages: [currentPage, backlink],
        isTopicOnly: false,
      },
    ],
  );

  assert.equal(groups.length, 1);
  assert.equal(groups[0].name, "Calico");
  assert.deepEqual(groups[0].pages, [backlink]);
});

test("navigates an unfocused wiki link through the editor mouse event path", () => {
  const editorElement = document.createElement("div");
  document.body.append(editorElement);
  const editor = new Editor({
    element: editorElement,
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example) foo bar",
    contentType: "markdown",
  });
  const link =
    editor.view.dom.querySelector<HTMLAnchorElement>('a[href="/example"]');

  assert.ok(link);
  assert.equal(link.textContent, "example");
  assert.notEqual(link.target, "_blank");

  let opened: { url?: string | URL; target?: string } | undefined;
  const originalOpen = window.open;
  const originalPosAtCoords = editor.view.posAtCoords;
  window.open = (url, target) => {
    opened = { url, target };
    return null;
  };
  editor.view.posAtCoords = () => ({ pos: 2, inside: -1 });

  try {
    const mouseDown = new window.MouseEvent("mousedown", {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 2,
      clientY: 2,
    });
    link.dispatchEvent(mouseDown);

    const mouseUp = new window.MouseEvent("mouseup", {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 2,
      clientY: 2,
    });
    link.dispatchEvent(mouseUp);

    assert.equal(mouseDown.defaultPrevented, false);
    assert.equal(opened?.url, "http://127.0.0.1:5173/example");
    assert.equal(opened?.target, "_self");
    assert.ok(editor.view.dom.querySelector('a[href="/example"]'));
    assert.equal(editor.getText(), "example foo bar");
  } finally {
    editor.view.posAtCoords = originalPosAtCoords;
    window.open = originalOpen;
    editor.destroy();
    editorElement.remove();
  }
});

test("does not mark a read-only page dirty when navigating a wiki link", async () => {
  const header = document.createElement("header");
  header.className = "site-header";
  header.innerHTML = '<div class="header-actions"></div>';
  document.body.append(header);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const originalOpen = window.open;
  const bootstrap: EditorBootstrap = {
    page_id: "page-id",
    page_type: "named",
    date: "",
    name: "current",
    title: "current",
    body: "[[example]]",
    expected_updated_at: "2026-08-29T11:00:00+09:00",
    save_message: "",
    linked_pages: [],
    linked_pages_has_more: false,
    cover_mode: "explicit",
    cover_image_url: "/assets/cover.jpg",
    resolved_cover_image_url: "/assets/cover.jpg",
  };
  globalThis.fetch = async (input) => {
    const url = String(input);
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(null, { status: 304, headers: { etag: '"same"' } });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  window.open = () => null;

  try {
    await act(async () => {
      root.render(
        createElement(AuthoringEditor, {
          bootstrap,
          canEdit: false,
          canSwitchToEdit: true,
          editingHref: "/editor/page-id",
          readingHref: "/current",
        }),
      );
      await Promise.resolve();
    });
    const editorElement = container.querySelector<HTMLElement>(".ProseMirror");
    assert.ok(editorElement);
    const link =
      editorElement.querySelector<HTMLAnchorElement>('a[href="/example"]');
    assert.ok(link);
    assert.equal(editorElement.getAttribute("contenteditable"), "false");
    assert.equal(
      container.querySelector(".article-reading-header h1")?.textContent,
      "current",
    );
    assert.equal(
      container
        .querySelector<HTMLImageElement>(".article-reading-header img")
        ?.src.endsWith("/assets/cover.jpg"),
      true,
    );
    assert.equal(container.querySelector(".content-inbox-drawer"), null);
    assert.equal(document.documentElement.dataset.view, "reading");
    assert.equal(
      header.querySelector<HTMLAnchorElement>(".header-action--view-mode")
        ?.href,
      "http://127.0.0.1:5173/editor/page-id",
    );
    assert.equal(header.textContent, "編集");

    link.dispatchEvent(
      new window.MouseEvent("mousedown", {
        bubbles: true,
        cancelable: true,
        button: 0,
      }),
    );
    link.dispatchEvent(
      new window.MouseEvent("mouseup", {
        bubbles: true,
        cancelable: true,
        button: 0,
      }),
    );

    const beforeUnload = new window.Event("beforeunload", { cancelable: true });
    window.dispatchEvent(beforeUnload);
    assert.equal(beforeUnload.defaultPrevented, false);
    assert.equal(
      container.textContent?.includes("ページが別の編集で更新されています"),
      false,
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    window.open = originalOpen;
    container.remove();
    header.remove();
  }
});

test("keeps a wiki link collapsed when the cursor is immediately after it", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)test",
    contentType: "markdown",
  });

  editor.commands.setTextSelection(8);
  assert.equal(editor.getText(), "exampletest");
  assert.ok(editor.view.dom.querySelector('a[href="/example"]'));
  editor.destroy();
});

test("keeps composing text after a collapsed wiki link", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown",
  });

  editor.commands.setTextSelection(8);
  editor.view.dom.dispatchEvent(
    new window.CompositionEvent("compositionstart", { bubbles: true }),
  );
  editor.commands.insertContent("あ");

  assert.equal(editor.view.composing, true);
  assert.equal(editor.getText(), "exampleあ");
  assert.equal(
    editor.view.dom.querySelector('a[href="/example"]')?.textContent,
    "example",
  );
  editor.destroy();
});

test("wraps selected text in a wiki link with the platform shortcut", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "example",
    contentType: "markdown",
  });

  editor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(wrapSelectionInWikiLink(editor), true);
  assert.equal(editor.getText(), "[[example]]");
  editor.destroy();
});

test("expands a wiki link only after the cursor enters its text", () => {
  const wikiEditor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown",
  });

  wikiEditor.commands.setTextSelection(1);
  assert.equal(wikiEditor.getText(), "example");
  assert.ok(wikiEditor.view.dom.querySelector('a[href="/example"]'));

  wikiEditor.commands.setTextSelection(2);
  assert.equal(wikiEditor.getText(), "[[example]]");
  assert.equal(wikiEditor.state.selection.from, 4);
  wikiEditor.destroy();

  const selectionEditor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown",
  });

  selectionEditor.commands.setTextSelection({ from: 1, to: 8 });
  assert.equal(selectionEditor.getText(), "[[example]]");
  assert.deepEqual(
    {
      from: selectionEditor.state.selection.from,
      to: selectionEditor.state.selection.to,
    },
    { from: 1, to: 12 },
  );
  assert.equal(
    selectionEditor.state.doc.rangeHasMark(
      1,
      12,
      selectionEditor.schema.marks.link,
    ),
    false,
  );
  selectionEditor.destroy();
});

test("preserves the cursor when refreshed content replaces the document", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\nbody\n\n[日記](/%E6%97%A5%E8%A8%98)",
    contentType: "markdown",
  });
  const bodyPosition = editor.state.doc.child(0).nodeSize + 2;
  editor.commands.setTextSelection(bodyPosition);

  replaceEditorContentPreservingSelection(
    editor,
    "title\n\nbody\n\n[日記](/%E6%97%A5%E8%A8%98)",
  );

  assert.equal(editor.state.selection.from, bodyPosition);
  editor.destroy();
});

test("edits a selected image as Markdown and renders it again after leaving", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n![犬](/assets/uploads/2026/08/image.webp)\n\nbody",
    contentType: "markdown",
  });
  const firstChild = editor.state.doc.firstChild;
  assert.ok(firstChild);
  const imagePosition = firstChild.nodeSize;

  editor.commands.setTextSelection(imagePosition - 1);
  editor.commands.setNodeSelection(imagePosition);
  assert.match(
    editor.getText(),
    /!\[犬\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/,
  );
  assert.match(
    markdownForSource(editor.getMarkdown()),
    /!\[犬\]\(\/assets\/uploads\/2026\/08\/image\.webp\)/,
  );
  assert.equal(editor.state.selection.empty, true);
  assert.equal(
    editor.state.doc.textBetween(
      editor.state.selection.from,
      editor.state.selection.from + 1,
    ),
    "!",
  );

  editor.commands.setTextSelection({
    from: imagePosition + 1,
    to: imagePosition + editor.state.doc.child(1).nodeSize - 1,
  });
  assert.equal(editor.state.doc.child(1).type.name, "paragraph");

  editor.commands.setTextSelection(editor.state.doc.content.size - 1);
  assert.ok(editor.state.doc.child(1).type.name === "image");
  assert.equal(
    editor.state.doc.child(1).attrs.src,
    "/assets/uploads/2026/08/image.webp",
  );
  assert.equal(editor.state.doc.child(1).attrs.alt, "犬");
  editor.destroy();
});

test("keeps a selected image rendered in read-only mode", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n![犬](/assets/uploads/2026/08/image.webp)\n\nbody",
    contentType: "markdown",
    editable: false,
  });
  const imagePosition = editor.state.doc.firstChild?.nodeSize;
  assert.ok(imagePosition);

  editor.commands.setNodeSelection(imagePosition);

  assert.equal(editor.state.doc.child(1).type.name, "image");
  editor.destroy();
});

test("keeps an image rendered when the cursor moves to the start of the following line", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "title\n\n![](/assets/uploads/2026/08/image.webp)\n\nbody",
    contentType: "markdown",
  });
  const firstChild = editor.state.doc.firstChild;
  assert.ok(firstChild);
  const bodyStart =
    firstChild.nodeSize + editor.state.doc.child(1).nodeSize + 1;

  editor.commands.setTextSelection(bodyStart);

  assert.equal(editor.state.doc.child(1).type.name, "image");
  assert.equal(editor.state.selection.from, bodyStart);
  editor.destroy();
});

test("refreshes an unedited page once when the tab becomes visible", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  globalThis.fetch = async (input) => {
    if (String(input) === "/api/pages/page-id") fetchCount += 1;
    return new Response(
      JSON.stringify({
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
        linked_pages_has_more: false,
      }),
      { headers: { "content-type": "application/json", etag: '"new"' } },
    );
  };
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
    linked_pages_has_more: false,
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });

    assert.equal(fetchCount, 0);
    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: true,
    });
    document.dispatchEvent(new window.Event("visibilitychange"));
    assert.equal(fetchCount, 0);

    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: false,
    });
    await act(async () => {
      document.dispatchEvent(new window.Event("visibilitychange"));
      document.dispatchEvent(new window.Event("visibilitychange"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });

    assert.equal(fetchCount, 1);
    await act(async () => {
      document.dispatchEvent(new window.Event("visibilitychange"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    assert.equal(fetchCount, 1);
    assert.match(container.textContent || "", /新しい本文/);
    assert.doesNotMatch(container.textContent || "", /古い本文/);
    assert.equal(window.location.pathname, "/current");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    Object.defineProperty(document, "hidden", {
      configurable: true,
      value: false,
    });
    container.remove();
  }
});
