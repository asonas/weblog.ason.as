import { type Editor, Extension, Node as TiptapNode } from "@tiptap/core";
import { CodeBlockLowlight } from "@tiptap/extension-code-block-lowlight";
import { TableKit } from "@tiptap/extension-table";
import { Markdown } from "@tiptap/markdown";
import type { NodeType } from "@tiptap/pm/model";
import {
  type EditorState,
  NodeSelection,
  Plugin,
  TextSelection,
} from "@tiptap/pm/state";
import StarterKit from "@tiptap/starter-kit";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import ini from "highlight.js/lib/languages/ini";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { createLowlight } from "lowlight";
import { type CSSProperties, useLayoutEffect, useState } from "react";
import { EmbedCard } from "./EmbedCard";
import { MarkdownClipboard } from "./MarkdownClipboard";
import { SelectableImage } from "./SelectableImage";
import { SpeakerDeckPlayer } from "./speakerDeck";
import { Video } from "./Video";
import { VideoUploadCards } from "./VideoUploadCard";
import { XPost } from "./XPost";

const lowlight = createLowlight({
  bash,
  css,
  diff,
  ini,
  javascript,
  json,
  markdown,
  ruby,
  rust,
  swift,
  typescript,
  xml,
  yaml,
});

function encodePageName(name: string): string {
  return encodeURIComponent(name).replace(
    /[!'()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

const WIKI_LINK_PATTERN = /\[\[([^[\]]+)\]\]/g;
const IMAGE_MARKDOWN_PATTERN = /^!\[([^\]]*)\]\((.+)\)$/;

export function wrapSelectionInWikiLink(editor: Editor): boolean {
  const { from, to } = editor.state.selection;
  if (from === to) return false;

  const selectedText = editor.state.doc.textBetween(from, to);
  if (selectedText.length === 0) return false;

  return editor
    .chain()
    .insertContentAt({ from, to }, `[[${selectedText}]]`)
    .setTextSelection(from + selectedText.length + 2)
    .run();
}

const WikiLinks = Extension.create({
  name: "wikiLinks",

  addKeyboardShortcuts() {
    return {
      "Mod-k": () => wrapSelectionInWikiLink(this.editor),
    };
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    const linkType = this.editor.schema.marks.link;
    return [
      new Plugin({
        appendTransaction(transactions, oldState, newState) {
          if (
            !transactions.some(
              (transaction) =>
                transaction.docChanged || transaction.selectionSet,
            )
          )
            return null;
          if (
            transactions.some((transaction) =>
              transaction.getMeta("wikiLinkRawEditing"),
            )
          )
            return null;
          if (editor.view.composing) return null;

          if (
            editor.isEditable &&
            transactions.some((transaction) => transaction.selectionSet)
          ) {
            const selectedByCursor = transactions.some(
              (transaction) =>
                transaction.selectionSet && !transaction.docChanged,
            );
            if (selectedByCursor) {
              const selection = newState.selection;
              const enteredImageFromBefore =
                selection instanceof NodeSelection &&
                oldState.selection.to <= selection.from;
              const selectedImage =
                selection instanceof NodeSelection &&
                selection.node.type.name === "image"
                  ? {
                      from: selection.from,
                      to: selection.to,
                      node: selection.node,
                    }
                  : null;
              const src = selectedImage?.node.attrs.src;
              if (selectedImage && typeof src === "string" && src.length > 0) {
                const alt =
                  typeof selectedImage.node.attrs.alt === "string"
                    ? selectedImage.node.attrs.alt
                    : "";
                const markdown = `![${alt}](${src})`;
                const paragraph = newState.schema.nodes.paragraph.create(
                  null,
                  newState.schema.text(markdown),
                );
                const transaction = newState.tr.replaceWith(
                  selectedImage.from,
                  selectedImage.to,
                  paragraph,
                );
                return transaction
                  .setSelection(
                    TextSelection.create(
                      transaction.doc,
                      selectedImage.from +
                        (enteredImageFromBefore ? 1 : markdown.length + 1),
                    ),
                  )
                  .setMeta("wikiLinkRawEditing", true);
              }
            }

            const activeLinks: Array<{
              from: number;
              to: number;
              text: string;
            }> = [];
            newState.doc.descendants((node, from) => {
              const to = from + node.nodeSize;
              if (
                activeLinks.length > 0 ||
                !(newState.selection instanceof TextSelection) ||
                !node.isText ||
                !node.text ||
                (newState.selection.empty
                  ? newState.selection.from <= from ||
                    newState.selection.from >= to
                  : newState.selection.from >= to ||
                    newState.selection.to <= from)
              ) {
                return;
              }
              const link = node.marks.find((mark) => mark.type === linkType);
              if (
                typeof link?.attrs.href === "string" &&
                link.attrs.href.startsWith("/")
              ) {
                activeLinks.push({ from, to, text: node.text });
              }
            });
            const activeLink = activeLinks[0];
            if (activeLink) {
              const markdown = `[[${activeLink.text}]]`;
              const transaction = newState.tr.replaceWith(
                activeLink.from,
                activeLink.to,
                newState.schema.text(markdown),
              );
              const mapSelectionPosition = (position: number) => {
                if (position <= activeLink.from) return position;
                if (position >= activeLink.to) return position + 4;
                return position + 2;
              };
              return transaction
                .setSelection(
                  TextSelection.create(
                    transaction.doc,
                    mapSelectionPosition(newState.selection.anchor),
                    mapSelectionPosition(newState.selection.head),
                  ),
                )
                .setMeta("wikiLinkRawEditing", true);
            }
          }

          const matches: Array<{ from: number; to: number; pageName: string }> =
            [];
          const imageMatches: Array<{
            from: number;
            to: number;
            alt: string;
            src: string;
          }> = [];
          const changedLinks: Array<{
            from: number;
            to: number;
            pageName: string;
          }> = [];
          newState.doc.descendants((node, position) => {
            if (
              node.type.name === "paragraph" &&
              node.childCount === 1 &&
              node.firstChild?.isText
            ) {
              const match = IMAGE_MARKDOWN_PATTERN.exec(node.textContent);
              const selectionTouchesImageMarkdown =
                newState.selection.from <= position + node.nodeSize - 1 &&
                newState.selection.to >= position + 1;
              if (match && !selectionTouchesImageMarkdown) {
                imageMatches.push({
                  from: position,
                  to: position + node.nodeSize,
                  alt: match[1],
                  src: match[2],
                });
              }
            }
            if (!node.isText || !node.text) return;

            const link = node.marks.find((mark) => mark.type === linkType);
            const href = link?.attrs.href;
            if (typeof href === "string" && href.startsWith("/")) {
              try {
                const pageName = decodeURIComponent(href.slice(1));
                if (pageName !== node.text) {
                  changedLinks.push({
                    from: position,
                    to: position + node.nodeSize,
                    pageName: node.text,
                  });
                }
              } catch (_error) {
                // Malformed internal links remain untouched.
              }
            }

            for (const match of node.text.matchAll(WIKI_LINK_PATTERN)) {
              const pageName = match[1].trim();
              if (!pageName || match.index === undefined) continue;

              const from = position + match.index;
              const to = from + match[0].length;
              const selectionIsInside = newState.selection.empty
                ? newState.selection.from > from && newState.selection.from < to
                : newState.selection.from < to && newState.selection.to > from;
              if (selectionIsInside) continue;
              matches.push({ from, to, pageName });
            }
          });

          if (imageMatches.length > 0) {
            const transaction = newState.tr;
            for (const match of imageMatches.reverse()) {
              transaction.replaceWith(
                match.from,
                match.to,
                newState.schema.nodes.image.create({
                  src: match.src,
                  alt: match.alt,
                }),
              );
            }
            return transaction;
          }

          if (matches.length === 0 && changedLinks.length === 0) return null;

          const transaction = newState.tr;
          for (const link of changedLinks) {
            transaction.addMark(
              link.from,
              link.to,
              linkType.create({
                href: `/${encodePageName(link.pageName)}`,
                target: "_self",
              }),
            );
          }
          for (const match of matches.reverse()) {
            const href = `/${encodePageName(match.pageName)}`;
            const linkedText = newState.schema.text(match.pageName, [
              linkType.create({ href }),
            ]);
            transaction.replaceWith(match.from, match.to, linkedText);
          }
          return transaction;
        },
      }),
    ];
  },
});

const CodeLineNavigation = Extension.create({
  name: "codeLineNavigation",
  priority: 1_000,

  addKeyboardShortcuts() {
    return {
      "Ctrl-a": () => {
        const { $head } = this.editor.state.selection;
        if ($head.parent.type.name !== "codeBlock") return false;

        const lineStart = $head.parent.textContent.lastIndexOf(
          "\n",
          $head.parentOffset - 1,
        );
        const position =
          lineStart === -1 ? $head.start() : $head.start() + lineStart + 1;
        return this.editor.commands.setTextSelection(position);
      },
      "Ctrl-e": () => {
        const { $head } = this.editor.state.selection;
        if ($head.parent.type.name !== "codeBlock") return false;

        const lineEnd = $head.parent.textContent.indexOf(
          "\n",
          $head.parentOffset,
        );
        const position = lineEnd === -1 ? $head.end() : $head.start() + lineEnd;
        return this.editor.commands.setTextSelection(position);
      },
    };
  },
});

type JsonObject = Record<string, unknown>;

const LINE_UPDATE_DATE_FORMATTER = new Intl.DateTimeFormat("ja-JP", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  timeZone: "Asia/Tokyo",
});

export function lineUpdateLabel(value: string, now = new Date()): string {
  const updatedAt = new Date(value);
  const elapsedSeconds = Math.max(
    0,
    Math.floor((now.getTime() - updatedAt.getTime()) / 1000),
  );
  if (elapsedSeconds < 60) return "たった今更新";
  if (elapsedSeconds < 60 * 60)
    return `${Math.floor(elapsedSeconds / 60)}分前に更新`;
  if (elapsedSeconds < 24 * 60 * 60)
    return `${Math.floor(elapsedSeconds / (60 * 60))}時間前に更新`;
  if (elapsedSeconds < 30 * 24 * 60 * 60)
    return `${Math.floor(elapsedSeconds / (24 * 60 * 60))}日前に更新`;
  return `${LINE_UPDATE_DATE_FORMATTER.format(updatedAt)}に更新`;
}

export function lineUpdateStrength(value: string, now = new Date()): number {
  const elapsedSeconds = Math.max(
    0,
    (now.getTime() - new Date(value).getTime()) / 1000,
  );
  if (elapsedSeconds < 60 * 60) return 1;
  if (elapsedSeconds < 24 * 60 * 60) return 0.85;
  if (elapsedSeconds < 7 * 24 * 60 * 60) return 0.65;
  if (elapsedSeconds < 30 * 24 * 60 * 60) return 0.45;
  if (elapsedSeconds < 90 * 24 * 60 * 60) return 0.25;
  return 0;
}

export function isVisibleLine(line: string): boolean {
  const value = line.trim();
  return value.length > 0 && value !== "&nbsp;";
}

type LineUpdateMarker = {
  key: string;
  blockSize: number;
  insetBlockStart: number;
  updatedAt: string | null;
};

function blockLineRects(block: HTMLElement): Array<DOMRect> {
  const document = block.ownerDocument;
  const walker = document.createTreeWalker(block, 4);
  const textNodes: Array<Text> = [];
  while (walker.nextNode()) textNodes.push(walker.currentNode as Text);
  const text = textNodes.map((node) => node.data).join("");
  if (!text.includes("\n"))
    return text.trim() || block.querySelector("img, iframe")
      ? [block.getBoundingClientRect()]
      : [];

  const locate = (offset: number): [Text, number] | null => {
    let consumed = 0;
    for (const node of textNodes) {
      if (offset <= consumed + node.length) return [node, offset - consumed];
      consumed += node.length;
    }
    return null;
  };

  let offset = 0;
  return text.split("\n").flatMap((line) => {
    const start = offset;
    const end = start + line.length;
    offset = end + 1;
    if (!isVisibleLine(line)) return [];
    const startPosition = locate(start);
    const endPosition = locate(end);
    if (!startPosition || !endPosition) return [];
    const range = document.createRange();
    range.setStart(...startPosition);
    range.setEnd(...endPosition);
    return typeof range.getBoundingClientRect === "function"
      ? [range.getBoundingClientRect()]
      : [block.getBoundingClientRect()];
  });
}

export function LineUpdateRail({
  body,
  editor,
  updates,
  includesTitle = true,
}: {
  body: string;
  editor: Editor | null;
  updates: Array<string | null>;
  includesTitle?: boolean;
}) {
  const [markers, setMarkers] = useState<Array<LineUpdateMarker>>([]);

  useLayoutEffect(() => {
    if (!editor) return;
    const lines = body.split("\n");

    const measure = () => {
      const editorElement = editor.view.dom;
      const shell = editorElement.closest<HTMLElement>(".editor-shell");
      if (!shell) return;

      const shellRect = shell.getBoundingClientRect();
      const blocks = Array.from(editorElement.children).slice(
        includesTitle ? 1 : 0,
      ) as Array<HTMLElement>;
      const visibleUpdates = lines.flatMap((line, index) =>
        isVisibleLine(line) ? [updates[index] || null] : [],
      );
      let updateIndex = 0;
      const visibleBlocks = blocks.flatMap((block, blockIndex) => {
        return blockLineRects(block).map((rect, lineIndex) => ({
          blockIndex,
          lineIndex,
          blockSize: rect.height,
          insetBlockStart: rect.top - shellRect.top,
          updatedAt: visibleUpdates[updateIndex++] || null,
        }));
      });
      setMarkers(
        visibleBlocks.map((block, index) => {
          const next = visibleBlocks[index + 1];
          const isAdjacent =
            next &&
            ((next.blockIndex === block.blockIndex &&
              next.lineIndex === block.lineIndex + 1) ||
              (next.blockIndex === block.blockIndex + 1 &&
                next.lineIndex === 0));
          const blockSize = isAdjacent
            ? next.insetBlockStart - block.insetBlockStart
            : block.blockSize;
          return {
            key: `${block.blockIndex}:${block.lineIndex}`,
            blockSize,
            insetBlockStart: block.insetBlockStart,
            updatedAt: block.updatedAt,
          };
        }),
      );
    };

    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(editor.view.dom);
    return () => observer.disconnect();
  }, [body, editor, updates, includesTitle]);

  return (
    <div className="line-update-rail" aria-hidden="true">
      {markers.map((marker) => {
        const updatedAt = marker.updatedAt;
        const strength = updatedAt ? lineUpdateStrength(updatedAt) : 0;
        const state =
          updatedAt && strength > 0
            ? "updated"
            : updatedAt
              ? "expired"
              : "pending";
        const label =
          updatedAt && strength > 0 ? lineUpdateLabel(updatedAt) : undefined;
        return (
          <span
            className="line-update-rail__segment"
            data-state={state}
            data-label={label}
            title={label}
            style={
              state === "updated"
                ? ({
                    "--line-update-strength": `${strength * 100}%`,
                    blockSize: marker.blockSize,
                    insetBlockStart: marker.insetBlockStart,
                  } as CSSProperties)
                : {
                    blockSize: marker.blockSize,
                    insetBlockStart: marker.insetBlockStart,
                  }
            }
            key={marker.key}
          />
        );
      })}
    </div>
  );
}

export function autoCoverImageUrl(body: string): string | null {
  return (
    /!\[[^\]]*\]\((\/assets\/[^\s)]+)(?:\s+[^)]*)?\)/.exec(body)?.[1] || null
  );
}

export function youtubeVideoId(rawUrl: string): string | null {
  try {
    const url = new URL(rawUrl);
    const hostname = url.hostname.toLowerCase().replace(/^www\./, "");
    let videoId: string | null = null;
    if (hostname === "youtu.be")
      videoId = url.pathname.split("/").filter(Boolean)[0] || null;
    if (hostname === "youtube.com" || hostname.endsWith(".youtube.com")) {
      if (url.pathname === "/watch") videoId = url.searchParams.get("v");
      else if (/^\/(?:shorts|live|embed)\//.test(url.pathname)) {
        videoId = url.pathname.split("/").filter(Boolean)[1] || null;
      }
    }
    return videoId?.match(/^[A-Za-z0-9_-]{11}$/) ? videoId : null;
  } catch (_error) {
    return null;
  }
}

function blueskyPostIdentity(
  rawUrl: string,
): { did: string; rkey: string } | null {
  try {
    const url = new URL(rawUrl);
    if (
      url.protocol !== "https:" ||
      url.hostname !== "bsky.app" ||
      url.search ||
      url.hash
    )
      return null;
    const match = url.pathname.match(
      /^\/profile\/(did:plc:[a-z0-9]+)\/post\/([a-z0-9]+)$/,
    );
    return match ? { did: match[1], rkey: match[2] } : null;
  } catch (_error) {
    return null;
  }
}

const BLUESKY_EMBED_ORIGIN = "https://embed.bsky.app";

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function blueskyEmbedId(identity: { did: string; rkey: string }) {
  return `${identity.did}-${identity.rkey}`;
}

function resizeBlueskyEmbed(event: MessageEvent) {
  if (event.origin !== BLUESKY_EMBED_ORIGIN) return;
  if (!isJsonObject(event.data)) return;

  const { id, height } = event.data;
  if (typeof id !== "string" || typeof height !== "number" || height <= 0)
    return;

  const iframe = Array.from(
    document.querySelectorAll<HTMLIFrameElement>("iframe[data-bluesky-id]"),
  ).find((candidate) => candidate.dataset.blueskyId === id);
  if (iframe) iframe.style.height = `${height}px`;
}

window.addEventListener("message", resizeBlueskyEmbed);

function replaceYouTubeParagraphs(state: EditorState, nodeType: NodeType) {
  const replacements: Array<{ from: number; to: number; url: string }> = [];
  state.doc.forEach((node, offset, index) => {
    const url = node.textContent.trim();
    if (index > 0 && node.type.name === "paragraph" && youtubeVideoId(url)) {
      replacements.push({ from: offset, to: offset + node.nodeSize, url });
    }
  });
  if (replacements.length === 0) return null;

  const transaction = state.tr;
  for (const replacement of replacements.reverse()) {
    transaction.replaceWith(
      replacement.from,
      replacement.to,
      nodeType.create({ url: replacement.url }),
    );
  }
  return transaction;
}

function replaceBlueskyParagraphs(state: EditorState, nodeType: NodeType) {
  const replacements: Array<{ from: number; to: number; url: string }> = [];
  state.doc.forEach((node, offset, index) => {
    const url = node.textContent.trim();
    if (
      index > 0 &&
      node.type.name === "paragraph" &&
      blueskyPostIdentity(url)
    ) {
      replacements.push({ from: offset, to: offset + node.nodeSize, url });
    }
  });
  if (replacements.length === 0) return null;

  const transaction = state.tr;
  for (const replacement of replacements.reverse()) {
    transaction.replaceWith(
      replacement.from,
      replacement.to,
      nodeType.create({ url: replacement.url }),
    );
  }
  return transaction;
}

const BlueskyPlayer = TiptapNode.create({
  name: "blueskyPlayer",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { url: { default: "" } };
  },

  parseHTML() {
    return [
      {
        tag: "div[data-bluesky-player]",
        getAttrs: (element) => ({
          url: (element as HTMLElement).dataset.blueskyPlayer || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    const url = node.attrs.url as string;
    const identity = blueskyPostIdentity(url);
    const embedId = identity ? blueskyEmbedId(identity) : "";
    const src = identity
      ? `${BLUESKY_EMBED_ORIGIN}/embed/${identity.did}/app.bsky.feed.post/${identity.rkey}?${new URLSearchParams({ id: embedId })}`
      : "";
    return [
      "div",
      { class: "bluesky-player", "data-bluesky-player": url },
      [
        "iframe",
        {
          src,
          title: "Bluesky投稿",
          loading: "lazy",
          "data-bluesky-id": embedId,
          scrolling: "no",
        },
      ],
      [
        "a",
        {
          href: url,
          target: "_blank",
          rel: "noreferrer",
        },
        url,
      ],
    ];
  },

  renderMarkdown: (node) => node.attrs?.url || "",

  onCreate() {
    const transaction = replaceBlueskyParagraphs(this.editor.state, this.type);
    if (transaction) this.editor.view.dispatch(transaction);
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    return [
      new Plugin({
        appendTransaction: (transactions, oldState, state) => {
          if (
            transactions.some((transaction) =>
              transaction.getMeta("blueskyPlayerRawEditing"),
            )
          )
            return null;
          if (
            editor.isEditable &&
            transactions.some((transaction) => transaction.selectionSet)
          ) {
            const selection = state.selection;
            const enteredFromBefore =
              selection instanceof NodeSelection &&
              oldState.selection.to <= selection.from;
            if (
              selection instanceof NodeSelection &&
              selection.node.type === this.type
            ) {
              const url = selection.node.attrs.url;
              if (typeof url === "string" && url.length > 0) {
                const paragraph = state.schema.nodes.paragraph.create(
                  null,
                  state.schema.text(url),
                );
                const transaction = state.tr.replaceWith(
                  selection.from,
                  selection.to,
                  paragraph,
                );
                return transaction
                  .setSelection(
                    TextSelection.create(
                      transaction.doc,
                      selection.from + (enteredFromBefore ? 1 : url.length + 1),
                    ),
                  )
                  .setMeta("blueskyPlayerRawEditing", true);
              }
            }
          }
          return replaceBlueskyParagraphs(state, this.type);
        },
      }),
    ];
  },
});

const YouTubePlayer = TiptapNode.create({
  name: "youtubePlayer",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { url: { default: "" } };
  },

  parseHTML() {
    return [
      {
        tag: "div[data-youtube-player]",
        getAttrs: (element) => ({
          url: (element as HTMLElement).dataset.youtubePlayer || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    const url = node.attrs.url as string;
    const videoId = youtubeVideoId(url);
    const thumbnailUrl = `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`;
    const fallbackThumbnailUrl = `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`;
    return [
      "div",
      { class: "youtube-player", "data-youtube-player": url },
      [
        "iframe",
        {
          src: `https://www.youtube.com/embed/${videoId}?enablejsapi=1`,
          "data-youtube-player-frame": "",
          title: "YouTube動画",
          loading: "lazy",
          allow:
            "accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture",
          referrerpolicy: "strict-origin-when-cross-origin",
          allowfullscreen: "",
        },
      ],
      [
        "a",
        {
          class: "youtube-player__fallback",
          href: url,
          target: "_blank",
          rel: "noreferrer",
          "aria-label": "YouTubeで動画を見る",
        },
        [
          "img",
          {
            src: thumbnailUrl,
            alt: "",
            loading: "lazy",
            "data-youtube-thumbnail-fallback": fallbackThumbnailUrl,
          },
        ],
        [
          "span",
          { class: "youtube-player__brand", "aria-hidden": "true" },
          "YouTube",
        ],
        [
          "span",
          { class: "youtube-player__details" },
          ["strong", {}, "YouTubeで見る"],
          ["span", { class: "youtube-player__url" }, url],
        ],
      ],
    ];
  },

  renderMarkdown: (node) => node.attrs?.url || "",

  onCreate() {
    const transaction = replaceYouTubeParagraphs(this.editor.state, this.type);
    if (transaction) this.editor.view.dispatch(transaction);
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    return [
      new Plugin({
        appendTransaction: (transactions, oldState, state) => {
          if (
            transactions.some((transaction) =>
              transaction.getMeta("youtubePlayerRawEditing"),
            )
          )
            return null;
          if (
            editor.isEditable &&
            transactions.some((transaction) => transaction.selectionSet)
          ) {
            const selection = state.selection;
            const enteredFromBefore =
              selection instanceof NodeSelection &&
              oldState.selection.to <= selection.from;
            if (
              selection instanceof NodeSelection &&
              selection.node.type === this.type
            ) {
              const url = selection.node.attrs.url;
              if (typeof url === "string" && url.length > 0) {
                const paragraph = state.schema.nodes.paragraph.create(
                  null,
                  state.schema.text(url),
                );
                const transaction = state.tr.replaceWith(
                  selection.from,
                  selection.to,
                  paragraph,
                );
                return transaction
                  .setSelection(
                    TextSelection.create(
                      transaction.doc,
                      selection.from + (enteredFromBefore ? 1 : url.length + 1),
                    ),
                  )
                  .setMeta("youtubePlayerRawEditing", true);
              }
            }
          }
          return replaceYouTubeParagraphs(state, this.type);
        },
      }),
    ];
  },
});

export const ARTICLE_PREVIEW_EXTENSIONS = [
  StarterKit.configure({
    codeBlock: false,
    dropcursor: false,
    gapcursor: false,
    underline: false,
    link: {
      openOnClick: true,
      autolink: false,
      linkOnPaste: false,
      HTMLAttributes: {
        target: "_self",
      },
    },
  }),
  CodeBlockLowlight.configure({ lowlight }),
  CodeLineNavigation,
  WikiLinks,
  SelectableImage.configure({ allowBase64: false }),
  Video,
  VideoUploadCards,
  EmbedCard,
  YouTubePlayer,
  BlueskyPlayer,
  SpeakerDeckPlayer,
  XPost,
  TableKit,
  Markdown.configure({ indentation: { style: "space", size: 2 } }),
  MarkdownClipboard,
];
