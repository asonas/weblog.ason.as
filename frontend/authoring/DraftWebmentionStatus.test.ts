/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";
import { setTimeout } from "node:timers/promises";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { DraftWebmentionStatus } from "./DraftWebmentionStatus";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  IS_REACT_ACT_ENVIRONMENT: true,
});

test("reads pending status once until explicitly refreshed and uses the send response", async () => {
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (_url, options) => {
    requests.push(options?.method || "GET");
    return Response.json({
      version_id: "published-version",
      targets: [],
      pending: options?.method !== "POST",
      enabled: true,
    });
  };
  const container = document.createElement("div");
  const root = createRoot(container);
  const render = (refresh: number) =>
    root.render(
      createElement(DraftWebmentionStatus, {
        id: "article",
        refresh,
        csrf: async () => "token",
      }),
    );
  try {
    await act(async () => render(0));
    assert.match(container.textContent || "", /送信を待っています/);
    await act(async () => {
      await setTimeout(3200);
      render(0);
    });
    assert.deepEqual(requests, ["GET"]);
    await act(async () => render(1));
    assert.deepEqual(requests, ["GET", "GET"]);
    const button = container.querySelector("button");
    assert(button);
    await act(async () => button.click());
    assert.deepEqual(requests, ["GET", "GET", "POST"]);
    assert.match(container.textContent || "", /送信を受け付けました/);
    assert.doesNotMatch(container.textContent || "", /送信を待っています/);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = originalFetch;
  }
});
