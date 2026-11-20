/// <reference types="node" />
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { insertAfterArticleBody } from "./articleBodyEnd";

const order = (html: string, count: number) => {
  const { document } = new JSDOM(html).window;
  const article = document.querySelector("article");
  assert.ok(article);
  // 後から差し込んだ物ほど本文の近くに入る
  for (let index = count; index >= 1; index -= 1) {
    const element = document.createElement("section");
    element.className = `inserted-${index}`;
    assert.equal(insertAfterArticleBody(article, element), true);
  }
  return Array.from(article.children, (child) => child.className);
};

test("keeps the feedback link directly below the body", () => {
  assert.deepEqual(
    order(
      "<article><div class='editor-canvas'></div><p class='article-feedback'></p><section class='external-mentions'></section><div data-public-universe></div></article>",
      2,
    ),
    [
      "editor-canvas",
      "article-feedback",
      "inserted-1",
      "inserted-2",
      "external-mentions",
      "",
    ],
  );
});

test("places sections directly below the body when the feedback link sits elsewhere", () => {
  assert.deepEqual(
    order(
      "<article><div class='editor-canvas'></div><div data-public-universe></div><p class='article-feedback'></p></article>",
      1,
    ),
    ["editor-canvas", "inserted-1", "", "article-feedback"],
  );
});

test("reports pages without a body", () => {
  const { document } = new JSDOM("<article></article>").window;
  const article = document.querySelector("article");
  assert.ok(article);
  assert.equal(
    insertAfterArticleBody(article, document.createElement("div")),
    false,
  );
});
