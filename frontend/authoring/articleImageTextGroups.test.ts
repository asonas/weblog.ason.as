import assert from "node:assert/strict";
import test from "node:test";
import { Editor } from "@tiptap/core";
import { MarkdownManager } from "@tiptap/markdown";
import { JSDOM } from "jsdom";
import {
  ArticleImageTextGroup,
  groupPreviewImageText,
} from "./ArticleImageTextGroup";
import { groupPublicImageText } from "./articleImageTextGroups";

test("public images keep only their following paragraphs across image and piece boundaries", () => {
  const dom = new JSDOM(`<article><div class="public-article-body">
    <section class="article-piece"><p>導入</p>
      <p><span class="article-image"><img alt="1枚目"></span></p><p id="first">最初の説明</p><p>追加の説明</p>
      <p><span class="article-image"><img alt="2枚目"></span></p><p id="second">subの説明</p>
      <h2>次の話題</h2><p id="after-heading">別の文章</p>
      <p><a href="/linked"><span class="article-image"><img></span></a></p><p id="linked">リンクの説明</p>
    </section>
    <section class="article-piece"><p id="next-piece">次のかけら</p></section>
  </div></article>`);
  try {
    const article = dom.window.document.querySelector("article");
    assert.ok(article);
    const first = article.querySelector("#first");
    const second = article.querySelector("#second");
    groupPublicImageText(article);
    const groups = article.querySelectorAll(".article-image-text-group");
    assert.equal(groups.length, 2);
    assert.equal(groups[0].children.length, 3);
    assert.equal(groups[0].querySelector("img")?.alt, "1枚目");
    assert.equal(groups[1].querySelector("img")?.alt, "2枚目");
    assert.equal(first?.parentElement, groups[0]);
    assert.equal(second?.parentElement, groups[1]);
    for (const id of ["after-heading", "linked", "next-piece"]) {
      assert.equal(
        article.querySelector(`#${id}`)?.closest(".article-image-text-group"),
        null,
      );
    }
    const html = article.innerHTML;
    groupPublicImageText(article);
    assert.equal(article.innerHTML, html);
  } finally {
    dom.window.close();
  }
});

test("reading preview groups image prose while preserving Markdown and rebuilding updated content", async () => {
  const dom = new JSDOM("<!doctype html><div id='editor'></div>");
  Object.assign(globalThis, {
    document: dom.window.document,
    window: dom.window,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle,
  });
  const { ARTICLE_PREVIEW_EXTENSIONS } = await import("./articlePreviewEditor");
  const extensions = [...ARTICLE_PREVIEW_EXTENSIONS, ArticleImageTextGroup];
  const markdown = new MarkdownManager({ extensions });
  const source =
    "導入\n\n![1枚目](/first.webp)\n\n最初の説明\n\n追加の説明\n\n![2枚目](/second.webp)\n\nsubの説明\n\n## 次の話題\n\n別の文章\n\n---\n\n次のかけら";
  const element = document.getElementById("editor");
  assert.ok(element);
  const editor = new Editor({
    element,
    editable: false,
    extensions,
    content: groupPreviewImageText(markdown.parse(source)),
  });
  try {
    const groups = element.querySelectorAll(".article-image-text-group");
    assert.equal(groups.length, 2);
    assert.equal(groups[0].querySelector("img")?.alt, "1枚目");
    assert.equal(groups[1].querySelector("img")?.alt, "2枚目");
    assert.equal(groups[0].querySelectorAll("p").length, 2);
    assert.equal(groups[1].querySelector("p")?.textContent, "subの説明");
    assert.equal(
      element.querySelector("h2")?.closest(".article-image-text-group"),
      null,
    );
    assert.equal(editor.getMarkdown(), source);
    const updated = "![変更後](/third.webp)\n\n変更後の説明";
    editor.commands.setContent(groupPreviewImageText(markdown.parse(updated)), {
      emitUpdate: false,
    });
    assert.equal(
      element.querySelectorAll(".article-image-text-group").length,
      1,
    );
    assert.equal(
      element.querySelector(".article-image-text-group p")?.textContent,
      "変更後の説明",
    );
    assert.equal(editor.getMarkdown().trimEnd(), updated);
  } finally {
    editor.destroy();
    dom.window.close();
  }
});
