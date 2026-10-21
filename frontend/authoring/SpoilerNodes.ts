import { Node } from "@tiptap/core";
import type { DOMOutputSpec } from "@tiptap/pm/model";
import { markdownForEditor } from "./markdown";

function spoilerDOM(tag: "div" | "span"): DOMOutputSpec {
  return [
    tag,
    { class: "article-spoiler", "data-spoiler-open": "false" },
    [
      tag,
      { class: "article-spoiler__content", "aria-hidden": "true", inert: "" },
      0,
    ],
    [
      "button",
      {
        type: "button",
        class: "article-spoiler__toggle",
        "aria-expanded": "false",
        "aria-label": "スポイラーを表示",
        contenteditable: "false",
      },
      "クリックして表示",
    ],
  ];
}

export const Spoiler = Node.create({
  name: "spoiler",
  group: "inline",
  inline: true,
  content: "inline+",
  parseHTML: () => [
    {
      tag: "span.article-spoiler",
      contentElement: ".article-spoiler__content",
    },
  ],
  renderHTML: () => spoilerDOM("span"),
  markdownTokenizer: {
    name: "spoiler",
    level: "inline",
    start: "||",
    tokenize(source, _tokens, lexer) {
      const match = /^\|\|(?=\S)((?:\\.|`[^`]*`|[^\\\n])+?)\|\|/.exec(source);
      if (match)
        return {
          type: "spoiler",
          raw: match[0],
          tokens: lexer.inlineTokens(match[1]),
        };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode("spoiler", {}, helpers.parseInline(token.tokens || [])),
  renderMarkdown: (node, helpers) =>
    `||${helpers.renderChildren(node.content || [])}||`,
});

export const SpoilerBlock = Node.create({
  name: "spoilerBlock",
  group: "block",
  content: "block+",
  parseHTML: () => [
    { tag: "div.article-spoiler", contentElement: ".article-spoiler__content" },
  ],
  renderHTML: () => spoilerDOM("div"),
  markdownTokenizer: {
    name: "spoilerBlock",
    level: "block",
    start: (source) => source.search(/^\|\|/m),
    tokenize(source, _tokens, lexer) {
      const match =
        /^\|\|[ \t]*\n([\s\S]+?)^\|\|[ \t]*(?:\n|$)/m.exec(source) ||
        /^\|\|(?=\S)((?:\\.|[^\\\n])+?)\|\|[ \t]*(?:\n|$)/.exec(source);
      if (match?.index !== 0 || match[1].includes("||")) return;
      return {
        type: "spoilerBlock",
        raw: match[0],
        tokens: lexer.blockTokens(markdownForEditor(match[1])),
      };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode(
      "spoilerBlock",
      {},
      helpers.parseChildren(token.tokens || []),
    ),
  renderMarkdown: (node, helpers) =>
    `||\n${helpers.renderChildren(node.content || [], "\n\n")}\n||`,
});
