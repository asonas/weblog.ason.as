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
  Object.assign(dom.window.document, {
    elementFromPoint: () => dom.window.document.querySelector(".ProseMirror")
  });
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
  universeReferences,
  showYouTubeFallback,
  useYouTubeThumbnailFallback,
  youtubeVideoId
} = await import("./editor");
const { imageDimensions, resizedDimensions } = await import("./imageMetadata");
const { markdownForSource } = await import("./markdown");
const { SearchPage, SiteSearch } = await import("./search");

test("searches from the shared search field and renders article links", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return new Response(JSON.stringify({
      results: [{
        route: "検索の仕組み",
        title: "検索の仕組み",
        excerpt: "BM25で記事を検索する",
        updated_at: "2026-08-27T00:00:00Z"
      }]
    }), { headers: { "Content-Type": "application/json" } });
  };

  try {
    window.history.pushState({}, "", "/search?q=%E6%A4%9C%E7%B4%A2");
    await act(async () => root.render(createElement(SearchPage)));
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 220));
    });

    assert.deepEqual(requests, ["/api/search?q=%E6%A4%9C%E7%B4%A2&limit=10"]);
    const result = container.querySelector<HTMLAnchorElement>(".site-search__results a");
    assert.equal(result?.textContent, "検索の仕組みBM25で記事を検索する");
    assert.equal(result?.getAttribute("href"), "/%E6%A4%9C%E7%B4%A2%E3%81%AE%E4%BB%95%E7%B5%84%E3%81%BF");
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
  const prototype = window.HTMLElement.prototype as typeof window.HTMLElement.prototype & {
    attachEvent?: () => void;
    detachEvent?: () => void;
  };
  prototype.attachEvent = () => {};
  prototype.detachEvent = () => {};
  try {
    await act(async () => root.render(createElement(SiteSearch)));
    assert.equal(container.querySelector(".site-search__message"), null);
    const input = container.querySelector<HTMLInputElement>(".site-search__desktop input");
    assert.ok(input);
    await act(async () => input.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true })));
    assert.equal(container.querySelector(".site-search__message"), null);
    await act(async () => input.dispatchEvent(new window.Event("pointerdown", { bubbles: true })));
    assert.equal(container.querySelector(".site-search__message")?.textContent, "キーワードを入力してください");
    await act(async () => input.dispatchEvent(new window.FocusEvent("focusout", { bubbles: true, relatedTarget: document.body })));
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
  const prototype = window.HTMLElement.prototype as typeof window.HTMLElement.prototype & {
    attachEvent?: () => void;
    detachEvent?: () => void;
  };
  prototype.attachEvent = () => {};
  prototype.detachEvent = () => {};

  try {
    await act(async () => root.render(createElement(SiteSearch)));
    const trigger = container.querySelector<HTMLButtonElement>(".site-search__mobile-button");
    assert.ok(trigger);
    await act(async () => trigger.click());
    assert.ok(container.querySelector('[role="dialog"][aria-modal="true"]'));
    assert.equal(main.hasAttribute("inert"), true);
    assert.equal(navigation.hasAttribute("inert"), true);

    await act(async () => document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
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
    "```"
  ].join("\n");

  assert.deepEqual(extractEmbeddableUrls(body), ["https://example.com/article"]);
});

test("keeps universe references stable while editing prose", () => {
  const before = universeReferences("日記の本文 [[Calico]] https://example.com/article");
  const after = universeReferences("日記の本文を追記した [[Calico]] https://example.com/article");

  assert.equal(after.wikiLinkKey, before.wikiLinkKey);
  assert.equal(after.externalUrlKey, before.externalUrlKey);
  assert.notEqual(universeReferences("[[Calico]] [[TipTap]]").wikiLinkKey, before.wikiLinkKey);
  assert.notEqual(universeReferences("[[Calico]] https://example.com/other").externalUrlKey, before.externalUrlKey);
});

test("recognizes image files and inbox photos as image drags", () => {
  assert.equal(isImageDrag({ items: [{ kind: "file", type: "image/png" }] }), true);
  assert.equal(isImageDrag({ items: [{ kind: "file", type: "text/plain" }] }), false);
  assert.equal(isImageDrag({ types: ["application/x-weblog-inbox-item-id"] }), true);
});

test("adopts an inbox photo and marks it as used by the current page", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const savedPayloads: Array<Record<string, unknown>> = [];
  let resolveSave: (() => void) | null = null;
  const waitForSave = () => new Promise<void>((resolve) => { resolveSave = resolve; });
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
    linked_pages_has_more: false
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url === "/api/inbox") {
      return new Response(JSON.stringify({
        items: [{
          id: "item-1",
          source: "photo",
          kind: "photo",
          source_id: "photo-1",
          occurred_at: "2026-08-26T11:00:00+09:00",
          ingested_at: "2026-08-26T11:00:00+09:00",
          expires_at: "2026-09-02T11:00:00+09:00",
          payload: { preview_url: "/assets/inbox/photo-1.webp" },
          used_in_pages: []
        }]
      }), { headers: { "content-type": "application/json" } });
    }
    if (url === "/api/inbox/adopt") {
      const itemId = JSON.parse(String(init?.body)).item_id;
      return new Response(JSON.stringify({ public_url: `/assets/uploads/2026/08/${itemId}.webp` }), {
        headers: { "content-type": "application/json" }
      });
    }
    if (url === "/api/authoring/pages/page-id") {
      savedPayloads.push(JSON.parse(String(init?.body)));
      resolveSave?.();
      resolveSave = null;
      return new Response(JSON.stringify(pageResponse), { headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), { headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), { headers: { "content-type": "application/json", etag: "\"same\"" } });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id", page_type: "named", date: "", name: "current", title: "current", body: "本文",
    expected_updated_at: "2026-08-26T11:00:00+09:00", save_message: "", linked_pages: [], linked_pages_has_more: false
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await Promise.resolve();
    });
    await act(async () => {
      container.querySelector<HTMLButtonElement>(".content-inbox__tab")!.click();
      await Promise.resolve();
    });
    assert.equal(container.querySelector(".content-inbox__kind")?.textContent, "写真");

    const transferData = new Map<string, string>();
    const dataTransfer = {
      files: [], items: [], types: [] as Array<string>, effectAllowed: "none", dropEffect: "none",
      setData(type: string, value: string) {
        transferData.set(type, value);
        if (!this.types.includes(type)) this.types.push(type);
      },
      getData(type: string) { return transferData.get(type) || ""; }
    };
    const remainingItem = container.querySelector<HTMLButtonElement>(".content-inbox__item")!;
    const dragStart = new window.Event("dragstart", { bubbles: true, cancelable: true });
    Object.defineProperty(dragStart, "dataTransfer", { value: dataTransfer });
    remainingItem.dispatchEvent(dragStart);
    assert.equal(dataTransfer.effectAllowed, "copy");

    let nativeDropObserved = false;
    const editorElement = container.querySelector<HTMLElement>(".ProseMirror")!;
    editorElement.addEventListener("drop", () => { nativeDropObserved = true; });
    const dropSave = waitForSave();
    await act(async () => {
      const drop = new window.Event("drop", { bubbles: true, cancelable: true });
      Object.defineProperties(drop, {
        dataTransfer: { value: dataTransfer },
        clientX: { value: 0 },
        clientY: { value: 0 }
      });
      editorElement.dispatchEvent(drop);
      await dropSave;
    });

    assert.equal(nativeDropObserved, false);
    assert.equal(savedPayloads.length, 1);
    assert.deepEqual(savedPayloads[0].consumed_inbox_item_ids, ["item-1"]);
    assert.match(String(savedPayloads[0].body), /\/assets\/uploads\/2026\/08\/item-1\.webp/);
    assert.notEqual(container.querySelector(".content-inbox__item"), null);
    assert.equal(container.querySelector(".content-inbox__usage")?.textContent, "currentで使用済み");
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
    mode: "editor", id: "page-id", page_type: "named", date: null, name: "current", title: null,
    updated_at: "2026-08-29T12:00:00+09:00", route: "current", body: "本文",
    linked_pages: [], linked_pages_has_more: false
  };
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    if (url === "/api/inbox") {
      return new Response(JSON.stringify({ items: [{
        id: "bookmark-1", source: "raindrop", kind: "bookmark", source_id: "42",
        occurred_at: "2026-08-29T11:00:00+09:00", ingested_at: "2026-08-29T12:00:00+09:00",
        expires_at: "2026-09-05T12:00:00+09:00",
        payload: { raindrop_id: 42, url: "https://example.com/article", title: "Article" }, used_in_pages: []
      }] }), { headers: { "content-type": "application/json" } });
    }
    if (url === "/api/authoring/pages/page-id") {
      savedPayloads.push(JSON.parse(String(init?.body)));
      resolveSave?.();
      return new Response(JSON.stringify(pageResponse), { headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), { headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), { headers: { "content-type": "application/json", etag: "\"same\"" } });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id", page_type: "named", date: "", name: "current", title: "current", body: "本文",
    expected_updated_at: "2026-08-29T11:00:00+09:00", save_message: "", linked_pages: [], linked_pages_has_more: false
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await Promise.resolve();
    });
    await act(async () => {
      container.querySelector<HTMLButtonElement>(".content-inbox__tab")!.click();
      await Promise.resolve();
    });

    const transferData = new Map<string, string>();
    const dataTransfer = {
      files: [], items: [], types: [] as Array<string>, effectAllowed: "none", dropEffect: "none",
      setData(type: string, value: string) {
        transferData.set(type, value);
        if (!this.types.includes(type)) this.types.push(type);
      },
      getData(type: string) { return transferData.get(type) || ""; }
    };
    const item = container.querySelector<HTMLButtonElement>(".content-inbox__item")!;
    const dragStart = new window.Event("dragstart", { bubbles: true, cancelable: true });
    Object.defineProperty(dragStart, "dataTransfer", { value: dataTransfer });
    item.dispatchEvent(dragStart);

    const saved = new Promise<void>((resolve) => { resolveSave = resolve; });
    await act(async () => {
      const drop = new window.Event("drop", { bubbles: true, cancelable: true });
      Object.defineProperties(drop, {
        dataTransfer: { value: dataTransfer }, clientX: { value: 0 }, clientY: { value: 0 }
      });
      container.querySelector<HTMLElement>(".ProseMirror")!.dispatchEvent(drop);
      await Promise.race([saved, new Promise((resolve) => setTimeout(resolve, 1_000))]);
    });

    assert.deepEqual(savedPayloads[0].consumed_inbox_item_ids, ["bookmark-1"]);
    assert.match(String(savedPayloads[0].body), /https:\/\/example\.com\/article/);
    assert.equal(container.querySelector(".content-inbox__usage")?.textContent, "currentで使用済み");
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
  let inboxReads = 0;
  const pageResponse = {
    mode: "editor", id: "page-id", page_type: "named", date: null, name: "current", title: null,
    updated_at: "2026-08-26T12:00:00+09:00", route: "current", body: "本文",
    linked_pages: [], linked_pages_has_more: false
  };
  globalThis.fetch = async (input) => {
    const url = String(input);
    requests.push(url);
    if (url === "/api/inbox") {
      inboxReads += 1;
      return new Response(JSON.stringify({
        items: inboxReads === 1 ? [] : [{
          id: "bookmark-1", source: "raindrop", kind: "bookmark", source_id: "1",
          occurred_at: "2026-08-28T11:00:00+09:00", ingested_at: "2026-08-28T12:00:00+09:00",
          expires_at: "2026-09-04T12:00:00+09:00",
          payload: { url: "https://example.com" }, used_in_pages: []
        }]
      }), { headers: { "content-type": "application/json" } });
    }
    if (url === "/api/inbox/sync") {
      return new Response(JSON.stringify({ run_id: "run-1", status: "queued" }), {
        status: 202, headers: { "content-type": "application/json" }
      });
    }
    if (url === "/api/inbox/sync/run-1") {
      return new Response(JSON.stringify({ id: "run-1", status: "succeeded", sources: [] }), {
        headers: { "content-type": "application/json" }
      });
    }
    if (url.startsWith("/api/page-names")) {
      return new Response(JSON.stringify({ names: [] }), { headers: { "content-type": "application/json" } });
    }
    if (url.startsWith("/api/routes/") || url.startsWith("/api/related")) {
      return new Response(JSON.stringify(pageResponse), { headers: { "content-type": "application/json", etag: "\"same\"" } });
    }
    throw new Error(`unexpected request: ${url}`);
  };
  const bootstrap: EditorBootstrap = {
    page_id: "page-id", page_type: "named", date: "", name: "current", title: "current", body: "本文",
    expected_updated_at: "2026-08-26T11:00:00+09:00", save_message: "", linked_pages: [], linked_pages_has_more: false
  };

  try {
    await act(async () => {
      root.render(createElement(AuthoringEditor, { bootstrap }));
      await Promise.resolve();
    });
    await act(async () => {
      container.querySelector<HTMLButtonElement>(".content-inbox__tab")!.click();
      await Promise.resolve();
    });
    await act(async () => {
      container.querySelector<HTMLButtonElement>(".content-inbox__sync")!.click();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

    assert.deepEqual(requests.filter((url) => url.startsWith("/api/inbox")), [
      "/api/inbox", "/api/inbox/sync", "/api/inbox/sync/run-1", "/api/inbox"
    ]);
    assert.equal(container.querySelector(".content-inbox__kind")?.textContent, "Raindrop");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
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
    "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"
  );
});

test("falls back when a maximum resolution YouTube thumbnail is unavailable", () => {
  const image = document.createElement("img");
  image.src = "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg";
  image.dataset.youtubeThumbnailFallback = "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg";

  useYouTubeThumbnailFallback(image);

  assert.equal(image.src, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg");
  assert.equal(image.dataset.youtubeThumbnailFallback, undefined);
});

test("shows the YouTube thumbnail and URL after a player error", () => {
  const wrapper = document.createElement("div");
  wrapper.className = "youtube-player";
  wrapper.innerHTML = '<iframe data-youtube-player-frame></iframe><a class="youtube-player__fallback" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">URL</a>';
  const iframe = wrapper.querySelector("iframe")!;

  showYouTubeFallback(iframe);

  assert.equal(wrapper.classList.contains("youtube-player--fallback"), true);
  assert.equal(wrapper.querySelector<HTMLAnchorElement>(".youtube-player__fallback")?.href, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
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
  assert.match(editor.getHTML(), /YouTubeで見る/);
  assert.match(editor.getHTML(), /aria-label="YouTubeで動画を見る"/);
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

test("navigates an unfocused wiki link through the editor mouse event path", () => {
  const editorElement = document.createElement("div");
  document.body.append(editorElement);
  const editor = new Editor({
    element: editorElement,
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example) foo bar",
    contentType: "markdown"
  });
  const link = editor.view.dom.querySelector<HTMLAnchorElement>('a[href="/example"]');

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
      clientY: 2
    });
    link.dispatchEvent(mouseDown);

    const mouseUp = new window.MouseEvent("mouseup", {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 2,
      clientY: 2
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

test("keeps a wiki link collapsed when the cursor is immediately after it", () => {
  const editor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)test",
    contentType: "markdown"
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
    contentType: "markdown"
  });

  editor.commands.setTextSelection(8);
  editor.view.dom.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true }));
  editor.commands.insertContent("あ");

  assert.equal(editor.view.composing, true);
  assert.equal(editor.getText(), "exampleあ");
  assert.equal(editor.view.dom.querySelector('a[href="/example"]')?.textContent, "example");
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

test("expands a wiki link only after the cursor enters its text", () => {
  const wikiEditor = new Editor({
    element: document.createElement("div"),
    extensions: EDITOR_EXTENSIONS,
    content: "[example](/example)",
    contentType: "markdown"
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
