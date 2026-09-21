/// <reference types="node" />
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import {
  embedUrls,
  hydrateEmbedCard,
  parseEmbedTag,
  prefetchEmbedMetadata,
} from "./EmbedCard";

test("parses only a standalone HTTP embed tag", () => {
  assert.deepEqual(parseEmbedTag("[embed:https://example.com/a?b=1]\nrest"), {
    raw: "[embed:https://example.com/a?b=1]\n",
    url: "https://example.com/a?b=1",
  });
  assert.equal(parseEmbedTag("text [embed:https://example.com]"), null);
  assert.equal(parseEmbedTag("[embed:javascript:alert(1)]"), null);
});

test("finds unique standalone embed URLs and warms them before publishing", async () => {
  const first = "https://example.com/first";
  const second = "https://example.com/second";
  const body = `[embed:${first}]\n\n本文 [embed:https://example.com/inline]\n\n[embed:${second}]\n\n[embed:${first}]`;
  assert.deepEqual(embedUrls(body), [first, second]);
  const requested: string[] = [];
  await prefetchEmbedMetadata(body, async (input) => {
    requested.push(String(input));
    return new Response(null, { status: requested.length === 1 ? 200 : 502 });
  });
  assert.deepEqual(
    requested,
    [first, second].map((url) => `/api/embed?${new URLSearchParams({ url })}`),
  );
});

test("hydrates an embed placeholder with escaped OGP content", async () => {
  const dom = new JSDOM(
    '<a class="embed-card embed-card--loading" data-embed-url="https://example.com/post" href="https://example.com/post"><span class="embed-card__url">https://example.com/post</span></a>',
    { url: "https://weblog.ason.as/article" },
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    HTMLImageElement: dom.window.HTMLImageElement,
  });
  try {
    const card = document.querySelector<HTMLElement>(".embed-card");
    assert.ok(card);
    await hydrateEmbedCard(
      card,
      async () =>
        new Response(
          JSON.stringify({
            title: '<script>alert("title")</script>',
            description: "記事の説明",
            image_url: "https://example.com/cover.jpg",
            site_name: "Example",
            canonical_url: "https://example.com/canonical",
          }),
        ),
    );

    assert.equal(card.classList.contains("embed-card--loading"), false);
    assert.equal(card.dataset.embedState, "ready");
    assert.equal(card.getAttribute("href"), "https://example.com/canonical");
    assert.equal(
      card.querySelector("strong")?.textContent,
      '<script>alert("title")</script>',
    );
    assert.equal(card.querySelector("script"), null);
    assert.equal(card.querySelector("img")?.getAttribute("loading"), "lazy");
  } finally {
    dom.window.close();
  }
});

test("keeps the original URL fallback when OGP fetching fails", async () => {
  const dom = new JSDOM(
    '<a class="embed-card embed-card--loading" data-embed-url="https://example.com/post" href="https://example.com/post"><span class="embed-card__url">https://example.com/post</span></a>',
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
  });
  try {
    const card = document.querySelector<HTMLElement>(".embed-card");
    assert.ok(card);
    await hydrateEmbedCard(
      card,
      async () => new Response(null, { status: 502 }),
    );
    assert.equal(card.dataset.embedState, "failed");
    assert.equal(card.textContent, "https://example.com/post");
  } finally {
    dom.window.close();
  }
});
