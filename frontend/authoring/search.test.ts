import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";

const dom = new JSDOM(
  '<header><nav class="header-nav"></nav></header><main id="main"></main>',
  { url: "http://localhost/search" },
);
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const { SiteSearch } = await import("./search");
const { createRoot } = await import("react-dom/client");

test("header search opens an interactive modal outside the inert navigation and closes", async () => {
  const navigation = document.querySelector(".header-nav");
  assert.ok(navigation);
  const root = createRoot(navigation);
  try {
    await act(async () => root.render(createElement(SiteSearch)));
    const trigger = navigation.querySelector<HTMLButtonElement>(
      ".site-search__mobile-button",
    );
    assert.ok(trigger);
    await act(async () => trigger.click());
    const modal = document.querySelector('[role="dialog"]');
    assert.ok(modal);
    assert.equal(
      Boolean(modal.closest("[inert]")),
      false,
      "modal must not inherit inert",
    );
    assert.equal(document.activeElement, modal.querySelector("input"));
    const close = modal.querySelector<HTMLButtonElement>(
      ".site-search__sheet-header > button",
    );
    assert.ok(close);
    await act(async () => close.click());
    assert.equal(document.querySelector('[role="dialog"]'), null);
    assert.equal(document.querySelector("[inert]"), null);
  } finally {
    await act(async () => root.unmount());
  }
});
