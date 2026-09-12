import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { installMobileArticleSheet } from "./mobileArticleSheet";

test("mobile article links open details, preserve normal links, and recover from failed loading", async () => {
  const dom = new JSDOM(
    '<article class="article-workspace--reading"><a id="internal" href="/next">次の記事</a><a id="external" href="https://example.com">外部</a><a id="anchor" href="#section">見出し</a><a id="search" href="/search">検索</a><a id="download" href="/file" download>保存</a><a id="blank" href="/next" target="_blank">別タブ</a></article>',
    { url: "https://weblog.ason.as/start" },
  );
  const originalFetch = globalThis.fetch;
  let isMobile = true;
  Object.assign(dom.window, {
    matchMedia: () => ({
      get matches() {
        return isMobile;
      },
      addEventListener() {},
      removeEventListener() {},
    }),
    scrollTo() {},
  });
  // jsdom has no native dialog implementation; browser checks cover focus and inertness.
  Object.assign(dom.window.HTMLDialogElement.prototype, {
    showModal(this: HTMLDialogElement) {
      this.open = true;
    },
    close(this: HTMLDialogElement) {
      this.open = false;
      this.dispatchEvent(new dom.window.Event("close"));
    },
  });
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    DOMParser: dom.window.DOMParser,
  });
  const requests: string[] = [];
  let fail = false;
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return new Response(
      fail
        ? "Unavailable"
        : '<article data-public-article="1"><h1>リンク先の記事</h1><div class="e-content"><p>記事本文</p><a href="/third">次へ</a><a href="/third">重複</a><a href="https://example.com/paper">参考論文</a><a href="#section">見出し</a><a href="javascript:alert(1)">無効</a><a href="http://[">壊れたURL</a><a href="/fourth">4番目</a><a href="/fifth">5番目</a><a href="/sixth">6番目</a></div><p>本文外の情報</p></article>',
      { status: fail ? 503 : 200 },
    );
  };
  const cleanup = installMobileArticleSheet();
  const click = (selector: string, options: MouseEventInit = {}) => {
    const event = new dom.window.MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      ...options,
    });
    const link = document.querySelector(selector);
    assert.ok(link);
    // Prevent jsdom navigation after recording whether the sheet intercepted the click.
    let intercepted = false;
    const observe = (current: Event) => {
      intercepted = current.defaultPrevented;
      current.preventDefault();
    };
    document.addEventListener("click", observe, { once: true });
    link.dispatchEvent(event);
    return intercepted;
  };
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  try {
    for (const selector of [
      "#external",
      "#anchor",
      "#search",
      "#download",
      "#blank",
    ])
      assert.equal(click(selector), false);
    assert.equal(click("#internal", { metaKey: true }), false);
    isMobile = false;
    assert.equal(click("#internal"), false);
    assert.deepEqual(requests, []);
    isMobile = true;
    assert.equal(click("#internal"), true);
    await settle();
    assert.equal(document.querySelector("dialog")?.open, true);
    assert.equal(
      document.querySelector("dialog h2")?.textContent,
      "リンク先の記事",
    );
    assert.equal(window.location.pathname, "/start");
    assert.match(
      document.querySelector(".article-sheet__excerpt")?.textContent || "",
      /^記事本文/,
    );
    assert.doesNotMatch(
      document.querySelector(".article-sheet__excerpt")?.textContent || "",
      /本文外の情報/,
    );
    assert.equal(
      document.querySelectorAll(".article-sheet__links a").length,
      4,
    );
    assert.equal(
      document.querySelector(".article-sheet__links > p")?.textContent,
      "この記事のリンク · 5件",
    );
    assert.equal(
      document.querySelector(".article-sheet__links small")?.textContent,
      "example.com",
    );
    assert.equal(click(".article-sheet__links a"), true);
    await settle();
    assert.deepEqual(requests, [
      "https://weblog.ason.as/next",
      "https://weblog.ason.as/third",
    ]);
    document.querySelector<HTMLButtonElement>("dialog button")?.click();
    assert.equal(document.activeElement?.id, "internal");
    assert.equal(document.body.style.position, "");
    fail = true;
    click("#internal");
    await settle();
    assert.match(
      document.querySelector('[role="status"]')?.textContent || "",
      /読み込めませんでした/,
    );
    assert.equal(
      document.querySelector("dialog > div > a")?.getAttribute("href"),
      "https://weblog.ason.as/next",
    );
    document.querySelector<HTMLButtonElement>("dialog button")?.click();
    globalThis.fetch = async () =>
      new Response(
        `<article data-public-article="1"><h1>公開記事</h1><div class="e-content"><p>https://www.gakkihaku.jp/</p></div><div data-public-universe='{"urls":["https://www.gakkihaku.jp/"]}'></div></article>`,
      );
    click("#internal");
    await settle();
    assert.equal(
      document.querySelector(".article-sheet__links a")?.getAttribute("href"),
      "https://www.gakkihaku.jp/",
    );
  } finally {
    cleanup();
    globalThis.fetch = originalFetch;
    dom.window.close();
  }
});
