/// <reference types="node" />
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";

test("public reading keeps existing text and links while media load or fail", async () => {
  const dom = new JSDOM(
    `<!doctype html><article data-public-article="1"><h1>公開記事</h1><p>最初から読める本文</p><a href="/draft-editor?id=page-id">編集</a><span class="article-image"><img src="/assets/photo.webp" alt="写真"></span></article>`,
    { url: "https://weblog.ason.as/article" },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
    HTMLVideoElement: dom.window.HTMLVideoElement,
  });
  const requests: string[] = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    throw new Error("API unavailable");
  };
  try {
    const paragraph = document.querySelector("p");
    await import("./publicArticle");
    assert.equal(document.querySelector("p"), paragraph);
    assert.equal(paragraph?.textContent, "最初から読める本文");
    assert.equal(
      document.querySelector("a")?.getAttribute("href"),
      "/draft-editor?id=page-id",
    );
    assert.deepEqual(requests, []);
    const image = document.querySelector("img");
    assert.ok(image);
    image.dispatchEvent(new dom.window.Event("error"));
    assert.equal(image.parentElement?.dataset.mediaState, "failed");
    image.dispatchEvent(new dom.window.Event("load"));
    assert.equal(image.parentElement?.dataset.mediaState, "ready");
    assert.equal(document.querySelector("p"), paragraph);
  } finally {
    globalThis.fetch = originalFetch;
    dom.window.close();
  }
});

test("authenticated public reading restores the header edit action", async () => {
  const dom = new JSDOM(
    '<header class="site-header"><nav><span class="header-actions"><a href="/feed.xml">Feed</a></span></nav></header><article data-public-article="1" data-editing-href="/draft-editor?id=page-id"></article>',
    { url: "https://weblog.ason.as/article" },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
  });
  try {
    const { enhancePublicArticleEditing } = await import("./publicArticle");
    const article = document.querySelector<HTMLElement>("article");
    assert.ok(article);
    await enhancePublicArticleEditing(
      article,
      async () => new Response(JSON.stringify({ can_edit: false })),
    );
    assert.equal(document.querySelector(".header-action--view-mode"), null);
    await enhancePublicArticleEditing(
      article,
      async () => new Response(JSON.stringify({ can_edit: true })),
    );
    const edit = document.querySelector<HTMLAnchorElement>(
      ".header-action--view-mode",
    );
    assert.equal(edit?.getAttribute("aria-label"), "記事管理");
    assert.ok(edit?.querySelector('svg[aria-hidden="true"]'));
    assert.equal(edit?.getAttribute("href"), "/authoring/articles");
  } finally {
    dom.window.close();
  }
});

test("offscreen media keep their waiting state until they approach the viewport", async () => {
  const dom = new JSDOM(
    '<article><span class="article-image"><img src="/assets/slow.webp" loading="lazy"></span><figure class="article-video"><video></video></figure></article>',
    { url: "https://weblog.ason.as/article" },
  );
  let intersect:
    | ((
        entries: Array<{ target: HTMLElement; isIntersecting: boolean }>,
      ) => void)
    | undefined;
  class Observer {
    constructor(callback: NonNullable<typeof intersect>) {
      intersect = callback;
    }
    observe() {}
    unobserve() {}
  }
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
    HTMLVideoElement: dom.window.HTMLVideoElement,
    IntersectionObserver: Observer,
  });
  Object.assign(dom.window, { IntersectionObserver: Observer });
  const timers: Array<() => void> = [];
  dom.window.setTimeout = (callback) => {
    if (typeof callback === "function") timers.push(() => callback());
    return timers.length;
  };
  try {
    const { enhancePublicArticle } = await import("./publicArticle");
    const article = document.querySelector("article");
    const image = document.querySelector("img");
    const video = document.querySelector("video");
    assert.ok(article && image?.parentElement && video?.parentElement);
    enhancePublicArticle(article);
    for (const timer of timers.splice(0)) timer();
    assert.equal(image.parentElement.dataset.mediaState, undefined);
    assert.ok(intersect);
    intersect([
      { target: image.parentElement, isIntersecting: true },
      { target: video.parentElement, isIntersecting: true },
    ]);
    image.dispatchEvent(new dom.window.Event("load"));
    video.dispatchEvent(new dom.window.Event("loadeddata"));
    assert.equal(image.parentElement.dataset.mediaState, "ready");
    assert.equal(video.parentElement.dataset.mediaState, "ready");
  } finally {
    dom.window.close();
  }
});
