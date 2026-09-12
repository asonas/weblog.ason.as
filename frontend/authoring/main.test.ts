/// <reference types="node" />

import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";

import { JSDOM } from "jsdom";
import { act, createElement, createRef } from "react";
import { createRoot } from "react-dom/client";

const dom = new JSDOM(
  `<!doctype html><html><body>
  <header class="site-header"><nav class="header-nav"><div class="header-actions"></div></nav></header>
</body></html>`,
  { url: "http://127.0.0.1:5173/" },
);

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
  IS_REACT_ACT_ENVIRONMENT: true,
});
dom.window.HTMLElement.prototype.scrollIntoView = () => {};

Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});

window.matchMedia = () => ({
  matches: false,
  media: "",
  onchange: null,
  addEventListener: () => {},
  removeEventListener: () => {},
  addListener: () => {},
  removeListener: () => {},
  dispatchEvent: () => true,
});

class TestIntersectionObserver {
  disconnect() {}
  observe() {}
  takeRecords() {
    return [];
  }
  unobserve() {}
  readonly root = null;
  readonly rootMargin = "";
  readonly thresholds = [];
}

Object.assign(globalThis, { IntersectionObserver: TestIntersectionObserver });

registerHooks({
  load(url, context, nextLoad) {
    if (url.endsWith(".css")) {
      return {
        format: "module",
        source: "export default {};",
        shortCircuit: true,
      };
    }
    return nextLoad(url, context);
  },
});
const { App, CoverJournalHome, HeaderSearch, editorViewMode } = await import(
  "./main"
);
const { CardHome } = await import("./CardHome");
const { CoverPhoto } = await import("./CoverPhoto");

test("cover photos fall back to the original when a preview is unavailable", async () => {
  const container = document.createElement("div");
  const root = createRoot(container);
  await act(async () => {
    root.render(
      createElement(CoverPhoto, { url: "/assets/photo.png", hero: true }),
    );
  });
  const image = container.querySelector("img");
  assert.ok(image);
  assert.equal(image.getAttribute("src"), "/assets/photo.png");
  const source = container.querySelector("picture source");
  assert.ok(source);
  assert.equal(source.getAttribute("media"), "(max-width: 600px)");
  assert.equal(
    source.getAttribute("srcset"),
    "/assets/previews/640/photo.png.webp 640w, /assets/previews/1280/photo.png.webp 1280w",
  );
  await act(async () => {
    image.dispatchEvent(new dom.window.Event("error"));
  });
  assert.equal(image.getAttribute("src"), "/assets/photo.png");
  assert.equal(container.querySelector("source"), null);
  await act(async () => root.unmount());
});

const editorBootstrap = {
  page_id: "page-id",
  page_type: "named" as const,
  date: "",
  name: "article",
  title: "article",
  body: "body",
  expected_updated_at: "2026-08-30T00:00:00+09:00",
  save_message: "",
  linked_pages: [],
  linked_pages_has_more: false,
};

test("requires edit permission even on an explicit editor URL", () => {
  assert.equal(
    editorViewMode({
      bootstrap: editorBootstrap,
      canEdit: false,
      pathname: "/editor/page-id",
      search: "",
    }),
    "reading",
  );
  assert.equal(
    editorViewMode({
      bootstrap: editorBootstrap,
      canEdit: true,
      pathname: "/editor/page-id",
      search: "",
    }),
    "editing",
  );
});

test("opens only today's diary in editing mode by default", () => {
  const now = new Date("2026-08-29T15:30:00Z");
  const diary = {
    ...editorBootstrap,
    page_type: "date" as const,
    date: "2026-08-30",
    name: "",
    title: "2026-08-30",
  };

  assert.equal(
    editorViewMode({
      bootstrap: diary,
      canEdit: true,
      pathname: "/2026-08-30",
      search: "",
      now,
    }),
    "editing",
  );
  assert.equal(
    editorViewMode({
      bootstrap: diary,
      canEdit: true,
      pathname: "/2026-08-30",
      search: "?view=reading",
      now,
    }),
    "reading",
  );
  assert.equal(
    editorViewMode({
      bootstrap: { ...diary, date: "2026-08-29" },
      canEdit: true,
      pathname: "/2026-08-29",
      search: "",
      now,
    }),
    "reading",
  );
});

test("shows a home skeleton while initial home data is pending", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => new Promise<Response>(() => {});

  try {
    await act(async () =>
      root.render(
        createElement(App, {
          auth: {
            authenticated: false,
            authentication_required: false,
            can_edit: false,
            login: null,
            csrf_token: "",
          },
        }),
      ),
    );

    assert.ok(container.querySelector(".home-loading"));
    assert.ok(container.querySelectorAll(".home-loading__shimmer").length > 1);
    assert.equal(container.querySelector(".loading-state"), null);
    assert.equal(
      container.querySelector('[role="status"]')?.textContent,
      "記事を読み込んでいます",
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    container.remove();
  }
});

test("keeps today's title-routed diary in editing mode after reload", () => {
  const now = new Date("2026-09-04T15:30:00Z");

  assert.equal(
    editorViewMode({
      bootstrap: {
        ...editorBootstrap,
        name: "2026-09-05",
        title: "2026-09-05",
      },
      canEdit: true,
      pathname: "/2026-09-05",
      search: "",
      now,
    }),
    "editing",
  );
});

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

test("keeps the about link in the header and recent tags before the cards", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify({ pages: [] }));

  try {
    await act(async () =>
      root.render(
        createElement(CoverJournalHome, {
          initialWindow: { pages: [] },
          tags: ["TypeScript"],
          archive: [],
          archiveRef: createRef<HTMLDivElement>(),
          auth: {
            authenticated: false,
            authentication_required: false,
            can_edit: false,
            login: null,
            csrf_token: "",
          },
        }),
      ),
    );

    const about = container.querySelector<HTMLAnchorElement>(
      ".atlas-header a[href='/about']",
    );
    const tags = container.querySelector(".card-home__tags");
    assert.equal(about?.textContent, "このサイトについて");
    assert.equal(about?.getAttribute("href"), "/about");
    const aboutContainer = about?.parentElement;
    assert.ok(aboutContainer);
    assert.ok(tags);
    assert.ok(aboutContainer.compareDocumentPosition(tags) & 4);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
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
    return new Response(
      JSON.stringify({ pages: [], has_newer: false, has_older: false }),
      {
        headers: { "Content-Type": "application/json" },
      },
    );
  };

  try {
    await act(async () =>
      root.render(
        createElement(CoverJournalHome, {
          initialWindow: {
            pages: [
              {
                id: "page-1",
                title: "2026-08-30",
                route: "20260830",
                created_at: "2026-08-30T00:00:00Z",
                updated_at: "2026-08-30T00:00:00Z",
                excerpt: "日記",
                image_url: null,
                is_diary: true,
              },
            ],
          },
          tags: [],
          archive: [{ year: 2026, months: [8] }],
          archiveRef: createRef<HTMLDivElement>(),
          auth: {
            authenticated: false,
            authentication_required: false,
            can_edit: false,
            login: null,
            csrf_token: "",
          },
        }),
      ),
    );
    requests.length = 0;

    const august = container.querySelector<HTMLAnchorElement>(
      '[aria-label="2026年8月の記事"]',
    );
    assert.ok(august);
    await act(async () => august.click());

    assert.equal(window.location.pathname, "/");
    assert.deepEqual(requests, ["/api/pages?kind=timeline&month=2026-08"]);
    assert.equal(window.location.search, "?month=2026-08");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    window.history.replaceState(null, "", "/");
    container.remove();
  }
});

test("replaces card windows on explicit navigation and ignores an obsolete month response", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const page = (title: string) => ({
    id: title,
    title,
    route: title,
    created_at: "2026-09-07T00:00:00Z",
    updated_at: "2026-09-07T00:00:00Z",
    excerpt: "本文",
    image_url: null,
    is_diary: false,
  });
  const first = {
    pages: [page("最新の記事")],
    has_older: true,
    older_cursor: "older",
  };
  const requests: string[] = [];
  let resolveMonth: ((response: Response) => void) | undefined;
  globalThis.fetch = async (input) => {
    const url = String(input);
    requests.push(url);
    if (url.includes("month="))
      return new Promise<Response>((resolve) => {
        resolveMonth = resolve;
      });
    return new Response(
      JSON.stringify(
        url.includes("before=")
          ? {
              pages: [page("古い記事")],
              has_newer: true,
              newer_cursor: "newer",
            }
          : first,
      ),
    );
  };
  try {
    await act(async () =>
      root.render(
        createElement(CardHome, {
          initialPages: [],
          tags: [],
          archive: [{ year: 2026, months: [8] }],
          archiveRef: createRef<HTMLDivElement>(),
          header: null,
          authentication: null,
        }),
      ),
    );
    assert.equal(requests.length, 1);
    assert.ok(
      container.querySelector('.cf-card a[aria-label$="カバー画像なし"]'),
    );
    const older = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent?.includes("古い投稿"),
    );
    assert.ok(older);
    await act(async () => older.click());
    assert.equal(
      container.querySelector(".cf-card h2")?.textContent,
      "古い記事",
    );
    assert.equal(container.querySelectorAll(".cf-card").length, 1);
    const august = container.querySelector<HTMLAnchorElement>(
      '[aria-label="2026年8月の記事"]',
    );
    assert.ok(august);
    await act(async () => august.click());
    assert.ok(container.querySelector('[aria-busy="true"]'));
    const latest = container.querySelector<HTMLAnchorElement>(
      ".card-home__month a",
    );
    assert.ok(latest);
    await act(async () => latest.click());
    assert.equal(
      container.querySelector(".cf-card h2")?.textContent,
      "最新の記事",
    );
    await act(async () =>
      resolveMonth?.(
        new Response(JSON.stringify({ pages: [page("8月の記事")] })),
      ),
    );
    assert.equal(
      container.querySelector(".cf-card h2")?.textContent,
      "最新の記事",
    );
    assert.equal(window.location.search, "");
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    window.history.replaceState(null, "", "/");
    container.remove();
  }
});
