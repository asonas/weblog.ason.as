/// <reference types="node" />
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";

registerHooks({
  load(url, context, nextLoad) {
    if (url.endsWith(".css"))
      return { format: "module", source: "", shortCircuit: true };
    return nextLoad(url, context);
  },
});
const { DiaryNavigation } = await import("./DiaryNavigation");

test("diary navigation puts newer dates on the left and clears links when changing articles", async () => {
  const dom = new JSDOM("<!doctype html><div id='root'></div>", {
    url: "https://weblog.ason.as/2026-09-10",
  });
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = document.getElementById("root");
  assert.ok(container);
  const root = createRoot(container);
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return Response.json({ newer: "2026-09-11", older: "2026-09-07" });
  };
  try {
    await act(async () => {
      root.render(createElement(DiaryNavigation, { route: "2026-09-10" }));
    });
    assert.deepEqual(requests, ["/api/diary-navigation?route=2026-09-10"]);
    assert.deepEqual(
      Array.from(container.querySelectorAll("a"), (link) => [
        link.getAttribute("href"),
        link.textContent,
      ]),
      [
        ["/2026-09-11", "← 次の日記2026年9月11日"],
        ["/2026-09-07", "前の日記 →2026年9月7日"],
      ],
    );
    await act(async () => {
      root.render(createElement(DiaryNavigation, { route: "普通の記事" }));
    });
    assert.equal(container.querySelector("nav"), null);
    assert.equal(requests.length, 1);
    globalThis.fetch = async () =>
      Response.json({ newer: null, older: "2026-09-10" });
    await act(async () => {
      root.render(createElement(DiaryNavigation, { route: "2026-09-11" }));
    });
    assert.equal(container.querySelectorAll("a").length, 1);
    assert.equal(
      container.querySelector("nav")?.firstElementChild?.textContent,
      "最新の日記です",
    );
    globalThis.fetch = async () => {
      throw new Error("offline");
    };
    await act(async () => {
      root.render(createElement(DiaryNavigation, { route: "2026-09-12" }));
    });
    assert.equal(container.querySelector("nav"), null);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    dom.window.close();
  }
});
