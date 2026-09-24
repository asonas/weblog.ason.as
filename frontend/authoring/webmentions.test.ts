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

test("shows a readable error for an empty HTTP error response", async () => {
  globalThis.fetch = async () => new Response(null, { status: 404 });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(createElement(WebmentionModerationPage, { canEdit: true })),
    );
    assert.match(
      container.textContent || "",
      /Webmentionを読み込めませんでした（HTTP 404）/,
    );
    assert.doesNotMatch(container.textContent || "", /Unexpected end/);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test("offers display replacement only when approved display values changed", async () => {
  const snapshot = (title: string) => ({
    source_url: "https://example.com/post",
    title,
    site_name: "Example",
    content_hash: title,
  });
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        mentions: [
          {
            id: "same",
            source_url: "https://example.com/same",
            target_url: "https://weblog.ason.as/article",
            verification_status: "verified",
            moderation_status: "approved",
            approved: snapshot("Same title"),
            candidate: snapshot("Same title"),
          },
          {
            id: "changed",
            source_url: "https://example.com/changed",
            target_url: "https://weblog.ason.as/article",
            verification_status: "verified",
            moderation_status: "approved",
            approved: snapshot("Old title"),
            candidate: snapshot("New title"),
          },
        ],
        failures: [],
        delivery_failures: [],
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(createElement(WebmentionModerationPage, { canEdit: true })),
    );
    const card = container.querySelector<HTMLElement>("[data-state='changed']");
    assert(card);
    assert.match(card.textContent || "", /表示を更新/);
    assert.match(card.textContent || "", /現在の表示を維持/);
    assert.doesNotMatch(container.textContent || "", /Same title/);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
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
