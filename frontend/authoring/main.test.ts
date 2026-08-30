/// <reference types="node" />

import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

import { JSDOM } from "jsdom";
import { act, createElement, createRef } from "react";
import { createRoot } from "react-dom/client";

const dom = new JSDOM(`<!doctype html><html><body>
  <header class="site-header"><nav class="header-nav"><div class="header-actions"></div></nav></header>
</body></html>`, { url: "http://127.0.0.1:5173/" });

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  HTMLAnchorElement: dom.window.HTMLAnchorElement,
  MouseEvent: dom.window.MouseEvent,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle,
  IS_REACT_ACT_ENVIRONMENT: true
});

Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator
});

window.matchMedia = () => ({
  matches: false,
  media: "",
  onchange: null,
  addEventListener: () => {},
  removeEventListener: () => {},
  addListener: () => {},
  removeListener: () => {},
  dispatchEvent: () => true
});

class TestIntersectionObserver {
  disconnect() {}
  observe() {}
  takeRecords() { return []; }
  unobserve() {}
  readonly root = null;
  readonly rootMargin = "";
  readonly thresholds = [];
}

Object.assign(globalThis, { IntersectionObserver: TestIntersectionObserver });

registerHooks({
  load(url, context, nextLoad) {
    if (url.endsWith(".css")) {
      return { format: "module", source: "export default {};", shortCircuit: true };
    }
    return nextLoad(url, context);
  }
});
const { CoverJournalHome, HeaderSearch } = await import("./main");

test("keeps the shared search field in the header layout", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);

  try {
    await act(async () => root.render(createElement(HeaderSearch)));

    const search = document.querySelector(".site-header .site-search");
    assert.ok(search);
    assert.equal(search.parentElement?.className, "header-nav");
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test("selects a calendar month without navigating to its hub", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return new Response(JSON.stringify({ pages: [], has_newer: false, has_older: false }), {
      headers: { "Content-Type": "application/json" }
    });
  };

  try {
    await act(async () => root.render(createElement(CoverJournalHome, {
      initialWindow: {
        pages: [{
          id: "page-1",
          title: "2026-08-30",
          route: "20260830",
          created_at: "2026-08-30T00:00:00Z",
          updated_at: "2026-08-30T00:00:00Z",
          excerpt: "日記",
          image_url: null,
          is_diary: true
        }]
      },
      tags: [],
      archive: [{ year: 2026, months: [8] }],
      archiveRef: createRef<HTMLDivElement>(),
      auth: {
        authenticated: false,
        authentication_required: false,
        can_edit: false,
        login: null,
        csrf_token: ""
      }
    })));
    requests.length = 0;

    const august = container.querySelector<HTMLAnchorElement>('[aria-label="2026年8月の記事"]');
    assert.ok(august);
    await act(async () => august.click());

    assert.equal(window.location.pathname, "/");
    assert.deepEqual(requests.sort(), [
      "/api/pages?kind=article&month=2026-08",
      "/api/pages?kind=diary&month=2026-08"
    ]);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});
