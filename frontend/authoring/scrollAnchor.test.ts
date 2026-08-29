/// <reference types="node" />

import assert from "node:assert/strict";
import test, { beforeEach } from "node:test";

import { JSDOM } from "jsdom";

import { captureScrollAnchor, restoreScrollAnchor } from "./scrollAnchor";

const dom = new JSDOM("<!doctype html><body><div id=feed></div></body>");
const feed = dom.window.document.querySelector("#feed")!;

beforeEach(() => feed.replaceChildren());

function entry(top: number, bottom: number) {
  const element = dom.window.document.createElement("article");
  element.className = "atlas-entry";
  element.getBoundingClientRect = () => ({ top, bottom }) as DOMRect;
  feed.append(element);
  return element;
}

test("keeps the article crossing the viewport top as the scroll anchor", () => {
  entry(-240, -80);
  const visibleDiary = entry(-60, 100);
  entry(20, 180);

  const anchor = captureScrollAnchor(feed);

  assert.equal(anchor?.element, visibleDiary);
  assert.equal(anchor?.top, -60);
});

test("scrolls once by the anchor movement after articles are prepended", () => {
  const visibleArticle = entry(-40, 120);
  const anchor = captureScrollAnchor(feed)!;
  visibleArticle.getBoundingClientRect = () => ({ top: 440, bottom: 600 }) as DOMRect;
  const adjustments: number[] = [];

  restoreScrollAnchor(anchor, (top) => adjustments.push(top));

  assert.deepEqual(adjustments, [480]);
});
