/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { PublicCacheUsage } from "./PublicCacheUsage";

test("loads saved usage, refreshes explicitly with CSRF, and keeps the last result on failure", async () => {
  const dom = new JSDOM("<html><body></body></html>");
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const originalFetch = globalThis.fetch;
  const requests: RequestInit[] = [];
  let fail = false;
  globalThis.fetch = async (_url, options = {}) => {
    requests.push(options);
    if (fail) return new Response(null, { status: 503 });
    return Response.json({
      checked_at: "2026-10-22T12:00:00Z",
      month: "2026-10",
      scope: "listed_distributions",
      used_paths: options.method === "POST" ? 6 : 4,
      site_used_paths: 2,
      remaining_paths: null,
    });
  };
  const root = createRoot(document.body);
  try {
    await act(async () => {
      root.render(
        createElement(PublicCacheUsage, { csrf: async () => "csrf" }),
      );
    });
    assert.deepEqual(
      requests.map((r) => r.method || "GET"),
      ["GET"],
    );
    assert.match(document.body.textContent || "", /合計 4パス/);
    const button = document.querySelector("button");
    assert.ok(button);
    await act(async () => button.click());
    assert.equal(new Headers(requests[1].headers).get("X-CSRF-Token"), "csrf");
    assert.match(document.body.textContent || "", /合計 6パス/);
    assert.match(document.body.textContent || "", /全体の残数は未確認/);
    fail = true;
    await act(async () => button.click());
    assert.match(document.body.textContent || "", /合計 6パス/);
    assert.match(
      document.querySelector('[role="alert"]')?.textContent || "",
      /確認できませんでした/,
    );
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
    dom.window.close();
  }
});
