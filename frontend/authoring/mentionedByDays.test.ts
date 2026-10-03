/// <reference types="node" />
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { mountMentionedByDays } from "./mentionedByDays";

test("diaries skip incoming mentions while ordinary articles still display them", async () => {
  const dom = new JSDOM(
    "<article><div class='editor-canvas'></div><div data-public-universe></div></article>",
  );
  const originalDocument = globalThis.document;
  globalThis.document = dom.window.document;
  try {
    const article = document.querySelector<HTMLElement>("article");
    const universe = document.querySelector<HTMLElement>(
      "[data-public-universe]",
    );
    assert.ok(article && universe);
    const requests: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      requests.push(String(input));
      return new Response(
        JSON.stringify({
          days: [
            {
              day: "2026-10-03",
              pieces: [
                {
                  id: "mention",
                  href: "/2026-10-03#piece-mention",
                  html: "<p>言及した本文</p>",
                },
              ],
            },
          ],
          cursor: null,
        }),
      );
    };
    universe.dataset.publicUniverse = JSON.stringify({
      route: "2026-10-02",
      wiki: ["日記"],
    });
    mountMentionedByDays(article, () => {}, fetcher);
    assert.deepEqual(requests, []);
    assert.equal(article.querySelector(".mentioned-by-days"), null);

    for (const metadata of [
      { route: "猫", wiki: [] },
      { route: "2026-10-02", wiki: [] },
    ]) {
      universe.dataset.publicUniverse = JSON.stringify(metadata);
      mountMentionedByDays(article, () => {}, fetcher);
      await new Promise((resolve) => setImmediate(resolve));
      const section: HTMLElement | null =
        article.querySelector(".mentioned-by-days");
      assert.ok(section);
      assert.equal(section.hidden, false);
      assert.equal(
        section.querySelector("blockquote")?.textContent,
        "言及した本文",
      );
      section.remove();
    }
    assert.equal(requests.length, 2);
  } finally {
    globalThis.document = originalDocument;
    dom.window.close();
  }
});
