/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { createRoot } from "react-dom/client";

import { WebmentionModerationPage } from "./webmentions";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "https://weblog.ason.as/authoring/webmentions",
});

Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  MouseEvent: dom.window.MouseEvent,
  IS_REACT_ACT_ENVIRONMENT: true,
});

test("shows failed deliveries and requeues one from the moderation view", async () => {
  const requests: Array<{ url: string; method: string }> = [];
  globalThis.fetch = async (input, init) => {
    const url = input.toString();
    const method = init?.method || "GET";
    requests.push({ url, method });
    if (method === "POST") {
      return new Response(JSON.stringify({ status: "queued" }), {
        status: 202,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response(
      JSON.stringify({
        mentions: [],
        failures: [],
        delivery_failures: [
          {
            id: "delivery-id",
            page_id: "page-id",
            source_url: "https://weblog.ason.as/article",
            target_url: "https://example.com/post",
            status: "failed",
            attempt_count: 3,
            http_status: 503,
            error: "unavailable",
            updated_at: "2026-08-31T00:00:00Z",
          },
        ],
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };

  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(createElement(WebmentionModerationPage, { canEdit: true })),
    );
    const deliveryFilter = [...container.querySelectorAll("button")].find(
      (button) => button.textContent?.includes("送信失敗"),
    );
    assert(deliveryFilter);
    await act(async () =>
      deliveryFilter.dispatchEvent(new MouseEvent("click", { bubbles: true })),
    );

    const retry = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "送信を再試行",
    );
    assert(retry);
    await act(async () =>
      retry.dispatchEvent(new MouseEvent("click", { bubbles: true })),
    );

    assert(
      requests.some(
        (request) =>
          request.url ===
            "/api/authoring/webmention-deliveries/delivery-id/retry" &&
          request.method === "POST",
      ),
    );
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test("redrives a verification dead-letter queue from the moderation view", async () => {
  const requests: Array<{ url: string; method: string }> = [];
  globalThis.fetch = async (input, init) => {
    const url = input.toString();
    const method = init?.method || "GET";
    requests.push({ url, method });
    return new Response(
      JSON.stringify(
        method === "POST"
          ? { status: "started", task_handle: "task" }
          : { mentions: [], failures: [], delivery_failures: [] },
      ),
      {
        status: method === "POST" ? 202 : 200,
        headers: { "content-type": "application/json" },
      },
    );
  };

  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(createElement(WebmentionModerationPage, { canEdit: true })),
    );
    const retry = [...container.querySelectorAll("button")].find((button) =>
      button.textContent?.includes("受信・送信DLQを再投入"),
    );
    assert(retry);
    await act(async () =>
      retry.dispatchEvent(new MouseEvent("click", { bubbles: true })),
    );

    assert(
      requests.some(
        (request) =>
          request.url ===
            "/api/authoring/webmention-dead-letters/verification/retry" &&
          request.method === "POST",
      ),
    );
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});
