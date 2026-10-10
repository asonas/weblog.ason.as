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
    assert.equal(
      image.closest<HTMLElement>(".article-image")?.dataset.mediaState,
      "failed",
    );
    image.dispatchEvent(new dom.window.Event("load"));
    assert.equal(
      image.closest<HTMLElement>(".article-image")?.dataset.mediaState,
      "ready",
    );
    assert.equal(document.querySelector("p"), paragraph);
  } finally {
    globalThis.fetch = originalFetch;
    dom.window.close();
  }
});

test("article photos use source width and Escape collapses inline expansion", async () => {
  const dom = new JSDOM(
    '<article><span class="article-image"><img src="/assets/large.webp" width="2560" height="1707" alt="夕焼け"></span><span class="article-image"><img src="/assets/portrait.webp" width="1707" height="2560" alt="縦長の写真"></span><span class="article-image"><img src="/assets/dog.webp" alt="犬"></span><a href="/other"><span class="article-image"><img src="/assets/linked.webp" alt="リンク先の写真"></span></a></article>',
    { url: "https://weblog.ason.as/article" },
  );
  const header = dom.window.document.createElement("header");
  header.className = "site-header";
  header.getBoundingClientRect = () => new dom.window.DOMRect(0, 0, 1440, 68);
  dom.window.document.body.prepend(header);
  Object.defineProperty(dom.window, "innerHeight", {
    value: 900,
    configurable: true,
  });
  dom.window.scrollTo = () => {};
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
    HTMLVideoElement: dom.window.HTMLVideoElement,
  });
  try {
    const { enhancePublicArticle } = await import("./publicArticle");
    const article = document.querySelector<HTMLElement>("article");
    assert.ok(article);
    enhancePublicArticle(article);
    assert.equal(
      article.style.getPropertyValue("--expanded-image-height"),
      "624px",
    );
    Object.defineProperty(dom.window, "innerHeight", { value: 600 });
    window.dispatchEvent(new dom.window.Event("resize"));
    assert.equal(
      article.style.getPropertyValue("--expanded-image-height"),
      "399px",
    );
    const buttons = article.querySelectorAll<HTMLButtonElement>(
      ".article-image__zoom",
    );
    assert.equal(buttons.length, 3);
    assert.equal(article.querySelectorAll(".article-image__caption").length, 4);
    assert.equal(
      article.querySelector(".article-image__caption")?.textContent,
      "夕焼け",
    );
    assert.equal(buttons[0]?.querySelector("img")?.alt, "夕焼け");
    assert.equal(document.querySelector("dialog"), null);
    assert.equal(
      article.querySelector("a > .article-image > img")?.getAttribute("src"),
      "/assets/linked.webp",
    );
    assert.equal(
      buttons[0]?.parentElement?.style.getPropertyValue("--image-source-width"),
      "2560px",
    );
    const dog = buttons[2]?.querySelector("img");
    assert.ok(dog);
    Object.defineProperty(dog, "naturalWidth", { value: 424 });
    dog.dispatchEvent(new dom.window.Event("load"));
    assert.equal(
      buttons[2]?.parentElement?.style.getPropertyValue("--image-source-width"),
      "424px",
    );
    for (const button of buttons) {
      const image = button.querySelector("img");
      assert.ok(image);
      const originalSrc = image.getAttribute("src");
      button.click();
      assert.equal(
        button.parentElement?.classList.contains("article-image--expanded"),
        true,
      );
      assert.equal(button.getAttribute("aria-expanded"), "true");
      assert.match(button.getAttribute("aria-label") || "", /縮小$/);
      assert.equal(image.getAttribute("src"), originalSrc);
      button.click();
      assert.equal(
        button.parentElement?.classList.contains("article-image--expanded"),
        false,
      );
      assert.equal(button.getAttribute("aria-expanded"), "false");
    }
    buttons[0]?.click();
    buttons[2]?.click();
    window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Escape" }),
    );
    for (const button of [buttons[0], buttons[2]]) {
      assert.equal(
        button?.parentElement?.classList.contains("article-image--expanded"),
        false,
      );
      assert.equal(button?.getAttribute("aria-expanded"), "false");
      assert.match(button?.getAttribute("aria-label") || "", /拡大$/);
    }
  } finally {
    dom.window.close();
  }
});

test("only standalone portrait images wrap prose, including images loaded later", async () => {
  const dom = new JSDOM(
    `<article>
    <p><span class="article-image"><img id="portrait" src="/portrait.webp" width="400" height="800" alt="説明"></span></p>
    <p><span class="article-image"><img id="landscape" width="800" height="400"></span></p>
    <p>本文<span class="article-image"><img id="inline" width="400" height="800"></span></p>
    <p><a href="/other"><span class="article-image"><img id="linked" width="400" height="800"></span></a></p>
    <p><span class="article-image"><img id="loading"></span></p>
  </article>`,
    { url: "https://weblog.ason.as/article" },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
    HTMLVideoElement: dom.window.HTMLVideoElement,
  });
  dom.window.scrollTo = () => {};
  try {
    const { enhancePublicArticle } = await import("./publicArticle");
    const article = document.querySelector("article");
    assert.ok(article);
    enhancePublicArticle(article);
    const portrait = document
      .querySelector("#portrait")
      ?.closest(".article-image");
    assert.ok(portrait);
    assert.ok(portrait.classList.contains("article-image--portrait"));
    assert.equal(
      portrait.querySelector(".article-image__caption")?.textContent,
      "説明",
    );
    for (const id of ["landscape", "inline", "linked", "loading"]) {
      assert.equal(
        document
          .getElementById(id)
          ?.closest(".article-image")
          ?.classList.contains("article-image--portrait"),
        false,
        id,
      );
    }
    const loading = document.getElementById("loading");
    assert.ok(loading);
    Object.defineProperties(loading, {
      naturalWidth: { value: 400 },
      naturalHeight: { value: 800 },
    });
    loading.dispatchEvent(new dom.window.Event("load"));
    assert.ok(loading.closest(".article-image--portrait"));
    const button = portrait.querySelector("button");
    assert.ok(button);
    button.click();
    assert.ok(portrait.classList.contains("article-image--expanded"));
    assert.equal(document.querySelector("dialog"), null);
    window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Escape" }),
    );
    assert.equal(portrait.classList.contains("article-image--expanded"), false);
    assert.ok(portrait.classList.contains("article-image--portrait"));
  } finally {
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
    assert.equal(edit?.getAttribute("aria-label"), "この記事を編集");
    assert.ok(edit?.querySelector('svg[aria-hidden="true"]'));
    assert.equal(edit?.getAttribute("href"), "/draft-editor?id=page-id");
  } finally {
    dom.window.close();
  }
});

test("public Bluesky embeds follow the height sent by their own iframe", async () => {
  const dom = new JSDOM(
    '<article><div class="bluesky-player"><iframe data-bluesky-id="post-1"></iframe></div></article>',
    { url: "https://weblog.ason.as/article" },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
    HTMLVideoElement: dom.window.HTMLVideoElement,
  });
  try {
    const { enhancePublicArticle } = await import("./publicArticle");
    const article = document.querySelector<HTMLElement>("article");
    const iframe = document.querySelector<HTMLIFrameElement>("iframe");
    assert.ok(article && iframe);
    enhancePublicArticle(article);
    const sendHeight = (origin: string, id: string, height: number) => {
      window.dispatchEvent(
        new dom.window.MessageEvent("message", {
          origin,
          source: iframe.contentWindow,
          data: { id, height },
        }),
      );
    };
    sendHeight("https://example.com", "post-1", 198);
    sendHeight("https://embed.bsky.app", "other-post", 198);
    assert.equal(iframe.style.height, "");
    sendHeight("https://embed.bsky.app", "post-1", 198);
    assert.equal(iframe.style.height, "198px");
    sendHeight("https://embed.bsky.app", "post-1", 244);
    assert.equal(iframe.style.height, "244px");
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
    const imageContainer = image.parentElement;
    enhancePublicArticle(article);
    for (const timer of timers.splice(0)) timer();
    assert.equal(imageContainer.dataset.mediaState, undefined);
    assert.ok(intersect);
    intersect([
      { target: imageContainer, isIntersecting: true },
      { target: video.parentElement, isIntersecting: true },
    ]);
    image.dispatchEvent(new dom.window.Event("load"));
    video.dispatchEvent(new dom.window.Event("loadeddata"));
    assert.equal(imageContainer.dataset.mediaState, "ready");
    assert.equal(video.parentElement.dataset.mediaState, "ready");
  } finally {
    dom.window.close();
  }
});
