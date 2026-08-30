import { Extension, Node as TiptapNode, type Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import type { NodeType } from "@tiptap/pm/model";
import { NodeSelection, Plugin, TextSelection, type EditorState } from "@tiptap/pm/state";
import { EditorContent, useEditor } from "@tiptap/react";
import Image from "@tiptap/extension-image";
import StarterKit from "@tiptap/starter-kit";
import {
  forceCollide,
  forceLink,
  forceManyBody,
  forceSimulation,
  forceX,
  forceY,
  type SimulationLinkDatum,
  type SimulationNodeDatum
} from "d3-force";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent as ReactDragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type RefObject
} from "react";

import { markdownForEditor, markdownForSource } from "./markdown";

declare global {
  interface Window {
    YT?: {
      Player: new (element: HTMLIFrameElement, options: {
        events: { onError: () => void };
      }) => unknown;
    };
    onYouTubeIframeAPIReady?: () => void;
  }
}

let youtubeApiPromise: Promise<NonNullable<Window["YT"]>> | null = null;

function loadYouTubeApi(): Promise<NonNullable<Window["YT"]>> {
  if (window.YT?.Player) return Promise.resolve(window.YT);
  if (youtubeApiPromise) return youtubeApiPromise;

  youtubeApiPromise = new Promise((resolve) => {
    const previousReady = window.onYouTubeIframeAPIReady;
    window.onYouTubeIframeAPIReady = () => {
      previousReady?.();
      if (window.YT) resolve(window.YT);
    };
    if (!document.querySelector('script[src="https://www.youtube.com/iframe_api"]')) {
      const script = document.createElement("script");
      script.src = "https://www.youtube.com/iframe_api";
      script.async = true;
      document.head.append(script);
    }
  });
  return youtubeApiPromise;
}

export function showYouTubeFallback(iframe: HTMLIFrameElement): void {
  iframe.closest<HTMLElement>(".youtube-player")?.classList.add("youtube-player--fallback");
}

export function useYouTubeThumbnailFallback(image: HTMLImageElement): void {
  const fallback = image.dataset.youtubeThumbnailFallback;
  if (!fallback || image.src === fallback) return;
  delete image.dataset.youtubeThumbnailFallback;
  image.src = fallback;
}

function observeYouTubePlayers(root: HTMLElement): () => void {
  const fallbackThumbnail = (event: Event) => {
    if (event.target instanceof HTMLImageElement) useYouTubeThumbnailFallback(event.target);
  };
  const register = () => {
    const iframes = Array.from(root.querySelectorAll<HTMLIFrameElement>("iframe[data-youtube-player-frame]"))
      .filter((iframe) => iframe.dataset.youtubePlayerObserved !== "true");
    if (iframes.length === 0) return;
    for (const iframe of iframes) iframe.dataset.youtubePlayerObserved = "true";
    void loadYouTubeApi().then(({ Player }) => {
      for (const iframe of iframes) {
        if (!iframe.isConnected) continue;
        new Player(iframe, { events: { onError: () => showYouTubeFallback(iframe) } });
      }
    });
  };
  const observer = new MutationObserver(register);
  observer.observe(root, { childList: true, subtree: true });
  root.addEventListener("error", fallbackThumbnail, true);
  register();
  return () => {
    observer.disconnect();
    root.removeEventListener("error", fallbackThumbnail, true);
  };
}

function encodePageName(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

const WIKI_LINK_PATTERN = /\[\[([^\[\]]+)\]\]/g;
const IMAGE_MARKDOWN_PATTERN = /^!\[([^\]]*)\]\((.+)\)$/;

export function wrapSelectionInWikiLink(editor: Editor): boolean {
  const { from, to } = editor.state.selection;
  if (from === to) return false;

  const selectedText = editor.state.doc.textBetween(from, to);
  if (selectedText.length === 0) return false;

  return editor.chain()
    .insertContentAt({ from, to }, `[[${selectedText}]]`)
    .setTextSelection(from + selectedText.length + 2)
    .run();
}

const WikiLinks = Extension.create({
  name: "wikiLinks",

  addKeyboardShortcuts() {
    return {
      "Mod-k": () => wrapSelectionInWikiLink(this.editor)
    };
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    const linkType = this.editor.schema.marks.link;
    return [
      new Plugin({
        appendTransaction(transactions, oldState, newState) {
          if (!transactions.some((transaction) => transaction.docChanged || transaction.selectionSet)) return null;
          if (transactions.some((transaction) => transaction.getMeta("wikiLinkRawEditing"))) return null;
          if (editor.view.composing) return null;

          const cursor = newState.selection.empty ? newState.selection.from : -1;
          if (transactions.some((transaction) => transaction.selectionSet)) {
            const selectedByCursor = transactions.some(
              (transaction) => transaction.selectionSet && !transaction.docChanged
            );
            if (selectedByCursor) {
              const selection = newState.selection;
              const enteredImageFromBefore = selection instanceof NodeSelection
                && oldState.selection.to <= selection.from;
              const selectedImage = selection instanceof NodeSelection && selection.node.type.name === "image"
                ? { from: selection.from, to: selection.to, node: selection.node }
                : null;
              const src = selectedImage?.node.attrs.src;
              if (selectedImage && typeof src === "string" && src.length > 0) {
                const alt = typeof selectedImage.node.attrs.alt === "string" ? selectedImage.node.attrs.alt : "";
                const markdown = `![${alt}](${src})`;
                const paragraph = newState.schema.nodes.paragraph.create(null, newState.schema.text(markdown));
                const transaction = newState.tr.replaceWith(selectedImage.from, selectedImage.to, paragraph);
                return transaction
                  .setSelection(TextSelection.create(
                    transaction.doc,
                    selectedImage.from + (enteredImageFromBefore ? 1 : markdown.length + 1)
                  ))
                  .setMeta("wikiLinkRawEditing", true);
              }
            }

            const activeLinks: Array<{ from: number; to: number; text: string }> = [];
            newState.doc.descendants((node, from) => {
              const to = from + node.nodeSize;
              if (
                activeLinks.length > 0
                || !(newState.selection instanceof TextSelection)
                || !node.isText
                || !node.text
                || (newState.selection.empty
                  ? newState.selection.from <= from || newState.selection.from >= to
                  : newState.selection.from >= to || newState.selection.to <= from)
              ) {
                return;
              }
              const link = node.marks.find((mark) => mark.type === linkType);
              if (typeof link?.attrs.href === "string" && link.attrs.href.startsWith("/")) {
                activeLinks.push({ from, to, text: node.text });
              }
            });
            const activeLink = activeLinks[0];
            if (activeLink) {
              const markdown = `[[${activeLink.text}]]`;
              const transaction = newState.tr.replaceWith(
                activeLink.from,
                activeLink.to,
                newState.schema.text(markdown)
              );
              const mapSelectionPosition = (position: number) => {
                if (position <= activeLink.from) return position;
                if (position >= activeLink.to) return position + 4;
                return position + 2;
              };
              return transaction
                .setSelection(TextSelection.create(
                  transaction.doc,
                  mapSelectionPosition(newState.selection.anchor),
                  mapSelectionPosition(newState.selection.head)
                ))
                .setMeta("wikiLinkRawEditing", true);
            }
          }

          const matches: Array<{ from: number; to: number; pageName: string }> = [];
          const imageMatches: Array<{ from: number; to: number; alt: string; src: string }> = [];
          const changedLinks: Array<{ from: number; to: number; pageName: string }> = [];
          newState.doc.descendants((node, position) => {
            if (node.type.name === "paragraph" && node.childCount === 1 && node.firstChild?.isText) {
              const match = IMAGE_MARKDOWN_PATTERN.exec(node.textContent);
              const selectionTouchesImageMarkdown = newState.selection.from <= position + node.nodeSize - 1
                && newState.selection.to >= position + 1;
              if (match && !selectionTouchesImageMarkdown) {
                imageMatches.push({ from: position, to: position + node.nodeSize, alt: match[1], src: match[2] });
              }
            }
            if (!node.isText || !node.text) return;

            const link = node.marks.find((mark) => mark.type === linkType);
            const href = link?.attrs.href;
            if (typeof href === "string" && href.startsWith("/")) {
              try {
                const pageName = decodeURIComponent(href.slice(1));
                if (pageName !== node.text) {
                  changedLinks.push({ from: position, to: position + node.nodeSize, pageName: node.text });
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
              transaction.replaceWith(match.from, match.to, newState.schema.nodes.image.create({ src: match.src, alt: match.alt }));
            }
            return transaction;
          }

          if (matches.length === 0 && changedLinks.length === 0) return null;

          const transaction = newState.tr;
          for (const link of changedLinks) {
            transaction.addMark(
              link.from,
              link.to,
              linkType.create({ href: `/${encodePageName(link.pageName)}`, target: "_self" })
            );
          }
          for (const match of matches.reverse()) {
            const href = `/${encodePageName(match.pageName)}`;
            const linkedText = newState.schema.text(match.pageName, [linkType.create({ href })]);
            transaction.replaceWith(match.from, match.to, linkedText);
          }
          return transaction;
        },
      })
    ];
  }
});

type LinkedPage = {
  id: string;
  title: string;
  route: string;
  created_at: string;
  excerpt: string;
  image_url: string | null;
  related_by: Array<string>;
  related_urls?: Array<string>;
};

type LinkedPageGroup = {
  kind: "wiki" | "url";
  name: string;
  pages: Array<LinkedPage>;
  isTopicOnly: boolean;
};

type EmbedMetadata = {
  url: string;
  canonical_url: string;
  title: string;
  description: string | null;
  image_url: string | null;
  site_name: string | null;
  status: "ready" | "fallback";
};

export type EditorBootstrap = {
  page_id: string;
  page_type: "date" | "named";
  date: string;
  name: string;
  title: string;
  body: string;
  cover_mode?: "auto" | "explicit" | "none";
  cover_image_url?: string | null;
  resolved_cover_image_url?: string | null;
  line_updated_at?: Array<string | null>;
  expected_updated_at: string;
  save_message: string;
  linked_pages: Array<LinkedPage>;
  linked_pages_has_more: boolean;
};

type EditorDraft = {
  pageId: string;
  pageType: "date" | "named";
  date: string;
  name: string;
  title: string;
  body: string;
  coverMode: "auto" | "explicit" | "none";
  coverImageUrl: string | null;
  resolvedCoverImageUrl: string | null;
  expectedUpdatedAt: string;
};

type WikiLinkQuery = {
  from: number;
  to: number;
  value: string;
};

type WikiLinkSuggestionsResponse = {
  names: Array<string>;
};

export function wikiLinkQuery(editor: Editor): WikiLinkQuery | null {
  const selection = editor.state.selection;
  if (!selection.empty || !(selection instanceof TextSelection)) return null;

  const text = selection.$from.parent.textBetween(0, selection.$from.parentOffset, "\n", "\0");
  const match = /\[\[([^\[\]\n]*)$/.exec(text);
  if (!match) return null;

  return {
    from: selection.from - match[1].length,
    to: selection.from,
    value: match[1]
  };
}

export function matchingWikiLinkNames(names: Array<string>, query: string): Array<string> {
  return names.filter((name) => name.startsWith(query)).slice(0, 8);
}

export function nextWikiLinkSuggestionIndex(current: number, length: number, backwards: boolean): number {
  return (current + (backwards ? length - 1 : 1)) % length;
}

type PageResponse = {
  id: string;
  page_type: "date" | "named";
  date: string | null;
  name: string | null;
  title: string | null;
  updated_at: string | null;
  route?: string;
  body?: string;
  cover_mode?: "auto" | "explicit" | "none";
  cover_image_url?: string | null;
  resolved_cover_image_url?: string | null;
  line_updated_at?: Array<string | null>;
  linked_pages: EditorBootstrap["linked_pages"];
  linked_pages_has_more: boolean;
};

type RelatedPagesResponse = {
  pages: EditorBootstrap["linked_pages"];
  has_more: boolean;
};

type UploadResponse = {
  upload_url: string;
  fields: Record<string, string>;
  public_url: string;
};

type InboxItem = {
  id: string;
  source: "photo" | "bluesky" | "raindrop" | "c4p";
  kind: "photo" | "post" | "like" | "bookmark" | "track";
  source_id: string;
  occurred_at: string;
  ingested_at: string;
  expires_at: string;
  payload: Record<string, unknown>;
  used_in_pages: Array<{ id: string; route: string }>;
};

type InboxResponse = { items: Array<InboxItem> };
type InboxSyncResponse = { run_id: string; status: "queued" };
type InboxSyncStatus = {
  id: string;
  status: "queued" | "running" | "succeeded" | "completed_with_errors" | "failed";
};

type MaterialTab = "photo" | "raindrop";

type ApiError = Error & {
  fields?: Record<string, string[]>;
};

type JsonObject = Record<string, unknown>;
type HttpMethod = "POST" | "PATCH";
type ImageDragData = {
  items?: ArrayLike<{ kind: string; type: string }>;
  types?: ArrayLike<string>;
};

const PAGE_REFRESH_INTERVAL = 15_000;
const INBOX_ITEM_DRAG_TYPE = "application/x-weblog-inbox-item-id";
const LINE_UPDATE_DATE_FORMATTER = new Intl.DateTimeFormat("ja-JP", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
  timeZone: "Asia/Tokyo"
});

export function lineUpdateLabel(value: string, now = new Date()): string {
  const updatedAt = new Date(value);
  const elapsedSeconds = Math.max(0, Math.floor((now.getTime() - updatedAt.getTime()) / 1000));
  if (elapsedSeconds < 60) return "たった今更新";
  if (elapsedSeconds < 60 * 60) return `${Math.floor(elapsedSeconds / 60)}分前に更新`;
  if (elapsedSeconds < 24 * 60 * 60) return `${Math.floor(elapsedSeconds / (60 * 60))}時間前に更新`;
  if (elapsedSeconds < 30 * 24 * 60 * 60) return `${Math.floor(elapsedSeconds / (24 * 60 * 60))}日前に更新`;
  return `${LINE_UPDATE_DATE_FORMATTER.format(updatedAt)}に更新`;
}

export function lineUpdateStrength(value: string, now = new Date()): number {
  const elapsedSeconds = Math.max(0, (now.getTime() - new Date(value).getTime()) / 1000);
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

export function pendingLineUpdates(
  savedBody: string,
  draftBody: string,
  updates: Array<string | null>
): Array<string | null> {
  const updatesByLine = new Map<string, Array<string | null>>();
  savedBody.split("\n").forEach((line, index) => {
    const lineUpdates = updatesByLine.get(line) || [];
    lineUpdates.push(updates[index] || null);
    updatesByLine.set(line, lineUpdates);
  });

  return draftBody.split("\n").map((line) => {
    const update = updatesByLine.get(line)?.shift() || null;
    return isVisibleLine(line) ? update : null;
  });
}

type LineUpdateMarker = {
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
  if (!text.includes("\n")) return text.trim() || block.querySelector("img, iframe") ? [block.getBoundingClientRect()] : [];

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

function LineUpdateRail({ body, editor, updates }: {
  body: string;
  editor: Editor | null;
  updates: Array<string | null>;
}) {
  const lines = body.split("\n");
  const [markers, setMarkers] = useState<Array<LineUpdateMarker>>([]);

  useLayoutEffect(() => {
    if (!editor) return;

    const measure = () => {
      const editorElement = editor.view.dom;
      const shell = editorElement.closest<HTMLElement>(".editor-shell");
      if (!shell) return;

      const shellRect = shell.getBoundingClientRect();
      const blocks = Array.from(editorElement.children).slice(1) as Array<HTMLElement>;
      const visibleUpdates = lines.flatMap((line, index) => isVisibleLine(line) ? [updates[index] || null] : []);
      let updateIndex = 0;
      const visibleBlocks = blocks.flatMap((block, blockIndex) => {
        return blockLineRects(block).map((rect, lineIndex) => ({
          blockIndex,
          lineIndex,
          blockSize: rect.height,
          insetBlockStart: rect.top - shellRect.top,
          updatedAt: visibleUpdates[updateIndex++] || null
        }));
      });
      setMarkers(visibleBlocks.map((block, index) => {
        const next = visibleBlocks[index + 1];
        const isAdjacent = next && (
          (next.blockIndex === block.blockIndex && next.lineIndex === block.lineIndex + 1) ||
          (next.blockIndex === block.blockIndex + 1 && next.lineIndex === 0)
        );
        const blockSize = isAdjacent
          ? next.insetBlockStart - block.insetBlockStart
          : block.blockSize;
        return { blockSize, insetBlockStart: block.insetBlockStart, updatedAt: block.updatedAt };
      }));
    };

    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(editor.view.dom);
    return () => observer.disconnect();
  }, [body, editor, updates]);

  return (
    <div className="line-update-rail" aria-hidden="true">
      {markers.map((marker, index) => {
        const updatedAt = marker.updatedAt;
        const strength = updatedAt ? lineUpdateStrength(updatedAt) : 0;
        const state = updatedAt && strength > 0 ? "updated" : updatedAt ? "expired" : "pending";
        return (
          <span
            className="line-update-rail__segment"
            data-state={state}
            data-label={state === "updated" ? lineUpdateLabel(updatedAt!) : undefined}
            title={state === "updated" ? lineUpdateLabel(updatedAt!) : undefined}
            style={state === "updated" ? {
              "--line-update-strength": `${strength * 100}%`,
              blockSize: marker.blockSize,
              insetBlockStart: marker.insetBlockStart
            } as CSSProperties : {
              blockSize: marker.blockSize,
              insetBlockStart: marker.insetBlockStart
            }}
            key={index}
          />
        );
      })}
    </div>
  );
}

export function isImageDrag(dataTransfer: ImageDragData | null): boolean {
  if (!dataTransfer) return false;
  if (Array.from(dataTransfer.items || []).some((item) => item.kind === "file" && item.type.startsWith("image/"))) {
    return true;
  }
  return Array.from(dataTransfer.types || []).includes(INBOX_ITEM_DRAG_TYPE);
}

function inboxPhotoUrl(item: InboxItem): string | null {
  const url = item.payload.preview_url;
  return item.source === "photo" && item.kind === "photo" && typeof url === "string" ? url : null;
}

export function autoCoverImageUrl(body: string): string | null {
  return /!\[[^\]]*\]\((\/assets\/[^\s)]+)(?:\s+[^)]*)?\)/.exec(body)?.[1] || null;
}

function inboxItemLabel(item: InboxItem): string {
  if (item.source === "photo") return "写真";
  if (item.source === "bluesky" && item.kind === "like") return "Bluesky いいね";
  if (item.source === "bluesky") return "Bluesky 投稿";
  if (item.source === "raindrop") return "Raindrop";
  return "c4p";
}

function inboxItemName(item: InboxItem): string {
  if (item.source === "raindrop" && item.kind === "bookmark") {
    if (typeof item.payload.title === "string" && item.payload.title.trim()) return item.payload.title.trim();
    return typeof item.payload.url === "string" ? item.payload.url : "Raindrop素材";
  }
  return new Date(item.occurred_at).toLocaleString("ja-JP");
}

function PhotoMaterialIcon() {
  return (
    // Adapted from Wikimedia Commons "Photo icon.svg", released under CC0 1.0.
    <svg aria-hidden="true" viewBox="0 0 24 24">
      <path d="M4 3h16a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Zm0 2v14h16V5H4Zm3.5 2.5a2 2 0 1 1 0 4 2 2 0 0 1 0-4ZM5 17l4-4 2.5 2.5 2-2L19 19H5v-2Z" />
    </svg>
  );
}

function groupLinkedPages(pages: Array<LinkedPage>): Array<LinkedPageGroup> {
  const grouped = new Map<string, { kind: "wiki" | "url"; name: string; pages: Array<LinkedPage> }>();

  for (const page of pages) {
    for (const relation of page.related_by || []) {
      const key = `wiki:${relation}`;
      const group = grouped.get(key) || { kind: "wiki" as const, name: relation, pages: [] };
      group.pages.push(page);
      grouped.set(key, group);
    }
    for (const url of page.related_urls || []) {
      const key = `url:${url}`;
      const group = grouped.get(key) || { kind: "url" as const, name: url, pages: [] };
      group.pages.push(page);
      grouped.set(key, group);
    }
  }

  return Array.from(grouped.values(), ({ kind, name, pages: relatedPages }) => {
    const topicPage = kind === "wiki" ? relatedPages.find((page) => page.route === name) : undefined;
    const isTopicOnly = kind === "wiki" && name === "日記" && topicPage !== undefined;
    return {
      kind,
      name,
      pages: isTopicOnly ? [topicPage] : relatedPages,
      isTopicOnly
    };
  });
}

export function extractEmbeddableUrls(body: string): Array<string> {
  let fence: { marker: string; length: number } | null = null;
  const visibleLines = body.split("\n").filter((line) => {
    const match = /^\s*(`{3,}|~{3,})/.exec(line);
    const wasFenced = fence !== null;
    if (match) {
      const marker = match[1][0];
      if (!fence) fence = { marker, length: match[1].length };
      else if (marker === fence.marker && match[1].length >= fence.length) fence = null;
    }
    return !wasFenced && !match;
  }).map((line) => line.replace(/(`+).*?\1/g, ""));
  const matches = visibleLines.join("\n").match(/https?:\/\/[^\s<>\[\]\\"')]+/g) || [];
  const normalized = matches.map((url) =>
    url.replace(/\\(?=[^\w\s]|_)/g, "").replace(/[.,;:!?]+$/, "")
  );
  return Array.from(new Set(normalized))
    .filter((url) => !/\.(?:avif|gif|jpe?g|png|webp)(?:[?#]|$)/i.test(url));
}

function extractWikiLinkNames(body: string): Array<string> {
  return Array.from(body.matchAll(WIKI_LINK_PATTERN), (match) => match[1].trim())
    .filter((name, index, names) => name && names.indexOf(name) === index);
}

export function universeReferences(body: string) {
  const wikiLinkNames = extractWikiLinkNames(body);
  const externalUrls = extractEmbeddableUrls(body);
  return {
    wikiLinkNames,
    externalUrls,
    wikiLinkKey: JSON.stringify(wikiLinkNames),
    externalUrlKey: JSON.stringify(externalUrls)
  };
}

function buildInternalUniverseGroupsFromNames(
  wikiLinkNames: Array<string>,
  route: string,
  linkedPageGroups: Array<LinkedPageGroup>
): Array<LinkedPageGroup> {
  const names = wikiLinkNames.filter((name) => name !== route);
  if (linkedPageGroups.some((group) => group.kind === "wiki" && group.name === route)) {
    names.unshift(route);
  }

  return names.map((name) => {
    const group = linkedPageGroups.find((candidate) => candidate.kind === "wiki" && candidate.name === name);
    return group ? {
      ...group,
      pages: group.pages.filter((page) => page.route !== name)
    } : {
      kind: "wiki" as const,
      name,
      pages: [],
      isTopicOnly: false
    };
  });
}

export function buildInternalUniverseGroups(
  body: string,
  route: string,
  linkedPageGroups: Array<LinkedPageGroup>
): Array<LinkedPageGroup> {
  return buildInternalUniverseGroupsFromNames(extractWikiLinkNames(body), route, linkedPageGroups);
}

function externalLinkLabel(url: string): string {
  try {
    return new URL(url).hostname;
  } catch (_error) {
    return url;
  }
}

export function youtubeVideoId(rawUrl: string): string | null {
  try {
    const url = new URL(rawUrl);
    const hostname = url.hostname.toLowerCase().replace(/^www\./, "");
    let videoId: string | null = null;
    if (hostname === "youtu.be") videoId = url.pathname.split("/").filter(Boolean)[0] || null;
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

export function embedImageUrl(url: string, metadata?: EmbedMetadata): string | null {
  if (metadata?.image_url) return metadata.image_url;
  const videoId = youtubeVideoId(url);
  return videoId ? `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg` : null;
}

function EmbedCard({
  url,
  metadata,
  failed = false
}: {
  url: string;
  metadata?: EmbedMetadata;
  failed?: boolean;
}) {
  const imageUrl = embedImageUrl(url, metadata);
  const videoId = youtubeVideoId(url);
  const fallbackImageUrl = !metadata?.image_url && videoId
    ? `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`
    : undefined;
  if (!metadata) {
    return (
      <div className="embed-card embed-card--loading" role="status">
        <span>{failed ? "リンク情報を取得できませんでした" : "リンク情報を読み込んでいます"}</span>
        <small>{url}</small>
      </div>
    );
  }

  return (
    <div className="embed-card">
      <span className="embed-card__content">
        <strong>{metadata.title}</strong>
        {metadata.description && <span>{metadata.description}</span>}
        <span className="embed-card__url">{metadata.url}</span>
      </span>
      {imageUrl && (
        <img
          src={imageUrl}
          alt=""
          loading="lazy"
          referrerPolicy="no-referrer"
          data-youtube-thumbnail-fallback={fallbackImageUrl}
          onError={(event) => useYouTubeThumbnailFallback(event.currentTarget)}
        />
      )}
    </div>
  );
}

function stableNumber(value: string): number {
  let hash = 0;
  for (const character of value) {
    hash = (hash * 31 + character.charCodeAt(0)) >>> 0;
  }
  return hash;
}

type InternalGraphNode = SimulationNodeDatum & {
  id: string;
  kind: "topic" | "page";
  name?: string;
  group?: LinkedPageGroup;
  page?: LinkedPage;
  rank: number;
  radius: number;
  targetX: number;
  targetY: number;
};

type InternalGraphLink = SimulationLinkDatum<InternalGraphNode> & {
  source: string | InternalGraphNode;
  target: string | InternalGraphNode;
};

type InternalGraphLayout = {
  height: number;
  links: Array<{ source: InternalGraphNode; target: InternalGraphNode }>;
  pages: Array<InternalGraphNode>;
  topics: Array<InternalGraphNode>;
};

const EMPTY_INTERNAL_GRAPH_LAYOUT: InternalGraphLayout = {
  height: 520,
  links: [],
  pages: [],
  topics: []
};

type InternalGraphRect = {
  top: number;
  right: number;
  bottom: number;
  left: number;
};

function internalTopicRect(node: InternalGraphNode): InternalGraphRect {
  const halfWidth = node.radius + 10;
  const halfHeight = node.group?.kind === "url" ? 112 : (node.name?.length || 0) > 16 ? 44 : 32;
  return {
    top: (node.y ?? 0) - halfHeight,
    right: (node.x ?? 0) + halfWidth,
    bottom: (node.y ?? 0) + halfHeight,
    left: (node.x ?? 0) - halfWidth
  };
}

function pointInInternalRect(point: UniversePoint, rect: InternalGraphRect): boolean {
  return point.x >= rect.left && point.x <= rect.right && point.y >= rect.top && point.y <= rect.bottom;
}

function internalSegmentsIntersect(
  start: UniversePoint,
  end: UniversePoint,
  edgeStart: UniversePoint,
  edgeEnd: UniversePoint
): boolean {
  const cross = (a: UniversePoint, b: UniversePoint, c: UniversePoint) =>
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
  const first = cross(start, end, edgeStart);
  const second = cross(start, end, edgeEnd);
  const third = cross(edgeStart, edgeEnd, start);
  const fourth = cross(edgeStart, edgeEnd, end);
  return first * second <= 0 && third * fourth <= 0;
}

function internalSegmentIntersectsRect(
  start: UniversePoint,
  end: UniversePoint,
  rect: InternalGraphRect
): boolean {
  if (pointInInternalRect(start, rect) || pointInInternalRect(end, rect)) return true;
  const topLeft = { x: rect.left, y: rect.top };
  const topRight = { x: rect.right, y: rect.top };
  const bottomRight = { x: rect.right, y: rect.bottom };
  const bottomLeft = { x: rect.left, y: rect.bottom };
  return [
    [topLeft, topRight],
    [topRight, bottomRight],
    [bottomRight, bottomLeft],
    [bottomLeft, topLeft]
  ].some(([edgeStart, edgeEnd]) => internalSegmentsIntersect(start, end, edgeStart, edgeEnd));
}

function separateTopicsFromLinks(
  topics: Array<InternalGraphNode>,
  links: Array<{ source: InternalGraphNode; target: InternalGraphNode }>,
  width: number
): void {
  for (let iteration = 0; iteration < 120; iteration += 1) {
    let moved = false;
    for (const topic of topics) {
      const rect = internalTopicRect(topic);
      for (const link of links) {
        if (link.source.id === topic.id) continue;
        const start = { x: link.source.x ?? 0, y: link.source.y ?? 0 };
        const end = { x: link.target.x ?? 0, y: link.target.y ?? 0 };
        if (!internalSegmentIntersectsRect(start, end, rect)) continue;

        const dx = end.x - start.x;
        const dy = end.y - start.y;
        const length = Math.max(1, Math.hypot(dx, dy));
        const side = dx * ((topic.y ?? 0) - start.y) - dy * ((topic.x ?? 0) - start.x);
        const direction = side === 0 ? (stableNumber(topic.id) % 2 === 0 ? 1 : -1) : Math.sign(side);
        topic.x = (topic.x ?? topic.targetX) + (-dy / length) * direction * 5;
        topic.y = (topic.y ?? topic.targetY) + (dx / length) * direction * 5;
        moved = true;
      }
      topic.x = Math.max(topic.radius, Math.min(width - topic.radius, topic.x ?? topic.targetX));
      const verticalInset = topic.group?.kind === "url" ? 112 : 48;
      topic.y = Math.max(verticalInset, Math.min(240, topic.y ?? topic.targetY));
    }
    if (!moved) return;
  }
}

function internalGraphLayout(groups: Array<LinkedPageGroup>, width: number): InternalGraphLayout {
  const PAGE_NODE_RADIUS = 13;
  const PAGE_NODE_CLEARANCE = 16;
  const PAGE_NODE_MIN_DISTANCE = 54;
  const pageRanks = new Map<string, number>();
  const pagesById = new Map<string, LinkedPage>();
  for (const group of groups) {
    group.pages.forEach((page, index) => {
      pagesById.set(page.id, page);
      pageRanks.set(page.id, Math.min(pageRanks.get(page.id) ?? index, index));
    });
  }

  const pageCount = pagesById.size;
  const hasExternalTopic = groups.some((group) => group.kind === "url");
  const pageStartY = hasExternalTopic ? 360 : 230;
  const height = Math.max(hasExternalTopic ? 680 : 520, pageStartY + 80 + Math.sqrt(Math.max(pageCount, 1)) * 82);
  const topics = groups.map((group, index): InternalGraphNode => {
    const targetX = width * (index + 1) / (groups.length + 1);
    const targetY = 92 + stableNumber(group.name) % 42;
    return {
      id: `topic:${group.name}`,
      kind: "topic",
      name: group.name,
      group,
      rank: 0,
      radius: group.kind === "url" ? 150 : Math.min(120, 58 + Math.sqrt(group.name.length) * 11),
      targetX,
      targetY,
      x: targetX,
      y: targetY
    };
  });
  const pages = Array.from(pagesById.values(), (page): InternalGraphNode => {
    const rank = pageRanks.get(page.id) ?? 0;
    const seed = stableNumber(page.id);
    const targetX = width * (0.18 + seed % 640 / 1000);
    const targetY = Math.min(height - 42, pageStartY + rank * 22);
    return {
      id: `page:${page.id}`,
      kind: "page",
      page,
      rank,
      radius: PAGE_NODE_RADIUS,
      targetX,
      targetY,
      x: targetX,
      y: targetY
    };
  });
  const nodes = [...topics, ...pages];
  const links: Array<InternalGraphLink> = groups.flatMap((group) =>
    group.pages.map((page) => ({
      source: `topic:${group.name}`,
      target: `page:${page.id}`
    }))
  );

  const simulation = forceSimulation(nodes)
    .stop()
    .force("link", forceLink<InternalGraphNode, InternalGraphLink>(links)
      .id((node) => node.id)
      .distance((link) => {
        const target = typeof link.target === "string" ? undefined : link.target;
        return 118 + Math.min(target?.rank ?? 0, 12) * 7;
      })
      .strength(0.34))
    .force("charge", forceManyBody<InternalGraphNode>()
      .strength((node) => node.kind === "topic" ? -520 : -72)
      .distanceMax(520))
    .force("collision", forceCollide<InternalGraphNode>()
      .radius((node) => node.radius + (node.kind === "topic" ? 18 : PAGE_NODE_CLEARANCE))
      .iterations(6))
    .force("x", forceX<InternalGraphNode>((node) => node.targetX)
      .strength((node) => node.kind === "topic" ? 0.42 : 0.045))
    .force("y", forceY<InternalGraphNode>((node) => node.targetY)
      .strength((node) => node.kind === "topic" ? 0.58 : 0.16));

  simulation.tick(300);
  for (const node of nodes) {
    const horizontalInset = node.kind === "topic" ? node.radius : 18;
    node.x = Math.max(horizontalInset, Math.min(width - horizontalInset, node.x ?? node.targetX));
    if (node.kind === "topic") {
      const verticalInset = node.group?.kind === "url" ? 112 : 54;
      node.y = Math.max(verticalInset, Math.min(220, node.y ?? node.targetY));
    } else {
      node.y = Math.max(pageStartY - 25, Math.min(height - 28, node.y ?? node.targetY));
    }
  }

  for (let iteration = 0; iteration < 48; iteration += 1) {
    let moved = false;
    for (let leftIndex = 0; leftIndex < pages.length; leftIndex += 1) {
      for (let rightIndex = leftIndex + 1; rightIndex < pages.length; rightIndex += 1) {
        const left = pages[leftIndex];
        const right = pages[rightIndex];
        let dx = (right.x ?? right.targetX) - (left.x ?? left.targetX);
        let dy = (right.y ?? right.targetY) - (left.y ?? left.targetY);
        let distance = Math.hypot(dx, dy);
        if (distance >= PAGE_NODE_MIN_DISTANCE) continue;

        if (distance < 0.001) {
          const angle = stableNumber(`${left.id}:${right.id}`) % 360 * Math.PI / 180;
          dx = Math.cos(angle);
          dy = Math.sin(angle);
          distance = 1;
        }
        const displacement = (PAGE_NODE_MIN_DISTANCE - distance) / 2 + 0.5;
        const unitX = dx / distance;
        const unitY = dy / distance;
        left.x = (left.x ?? left.targetX) - unitX * displacement;
        left.y = (left.y ?? left.targetY) - unitY * displacement;
        right.x = (right.x ?? right.targetX) + unitX * displacement;
        right.y = (right.y ?? right.targetY) + unitY * displacement;
        moved = true;
      }
    }
    for (const page of pages) {
      page.x = Math.max(24, Math.min(width - 24, page.x ?? page.targetX));
      page.y = Math.max(pageStartY - 25, Math.min(height - 28, page.y ?? page.targetY));
    }
    if (!moved) break;
  }

  const resolvedLinks = links.map((link) => ({
    source: link.source as InternalGraphNode,
    target: link.target as InternalGraphNode
  }));
  separateTopicsFromLinks(topics, resolvedLinks, width);

  return {
    height,
    links: resolvedLinks,
    pages,
    topics
  };
}

export function internalNodeVisual(
  connectionCount: number,
  createdAt: number,
  oldestCreatedAt: number,
  newestCreatedAt: number
) {
  const weight = Math.sqrt(Math.max(0, connectionCount - 1));
  const span = newestCreatedAt - oldestCreatedAt;
  const recency = span > 0 ? Math.max(0, Math.min(1, (createdAt - oldestCreatedAt) / span)) : 1;
  return {
    opacity: 0.35 + recency * 0.65,
    size: Math.min(26, 14 + weight * 3)
  };
}

function InternalUniverseGraph({
  groups,
  onActiveTopicChange
}: {
  groups: Array<LinkedPageGroup>;
  onActiveTopicChange: (topic: string | null) => void;
}) {
  const [activePage, setActivePage] = useState<LinkedPage | null>(null);
  const [previewSide, setPreviewSide] = useState<"left" | "right">("right");
  const [width, setWidth] = useState(() => Math.max(1100, window.innerWidth));
  const [embeds, setEmbeds] = useState<Record<string, EmbedMetadata | null>>({});
  const closeTimerRef = useRef<number | null>(null);
  const graphRef = useRef<HTMLElement | null>(null);
  const [layout, setLayout] = useState<InternalGraphLayout>(EMPTY_INTERNAL_GRAPH_LAYOUT);
  const connectionCounts = useMemo(() => {
    const counts = new Map<string, number>();
    layout.links.forEach(({ target }) => counts.set(target.id, (counts.get(target.id) || 0) + 1));
    return counts;
  }, [layout]);
  const pageCreatedAtRange = useMemo(() => {
    const timestamps = layout.pages.map((node) => Date.parse(node.page?.created_at || ""));
    return { oldest: Math.min(...timestamps), newest: Math.max(...timestamps) };
  }, [layout.pages]);
  const activeNode = layout.pages.find((node) => node.page?.id === activePage?.id);
  const previewY = activeNode
    ? Math.max(112, Math.min((activeNode.y ?? 0) - 80, layout.height - 176))
    : 0;
  const externalUrls = useMemo(
    () => groups.filter((group) => group.kind === "url").map((group) => group.name),
    [groups]
  );

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setLayout(internalGraphLayout(groups, width));
    }, 300);
    return () => window.clearTimeout(timer);
  }, [groups, width]);

  useEffect(() => {
    let active = true;
    void Promise.all(externalUrls.map(async (url) => {
      try {
        return { url, metadata: await fetchJson<EmbedMetadata>(`/api/embed?${new URLSearchParams({ url })}`) };
      } catch (_error) {
        return { url, metadata: null };
      }
    })).then((results) => {
      if (active) setEmbeds(Object.fromEntries(results.map(({ url, metadata }) => [url, metadata])));
    });
    return () => {
      active = false;
    };
  }, [externalUrls]);

  useLayoutEffect(() => {
    const graph = graphRef.current;
    if (!graph) return;
    const updateWidth = () => setWidth(graph.getBoundingClientRect().width);
    updateWidth();
    const observer = new ResizeObserver(updateWidth);
    observer.observe(graph);
    return () => observer.disconnect();
  }, []);
  const showPreview = (page: LinkedPage, side: "left" | "right") => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    setPreviewSide(side);
    setActivePage(page);
  };
  const previewSideForNode = (
    node: HTMLElement,
    preferredSide: "left" | "right"
  ): "left" | "right" => {
    const nodeRect = node.getBoundingClientRect();
    const previewWidth = 256;
    const canShowRight = nodeRect.right + 18 + previewWidth <= window.innerWidth - 16;
    const canShowLeft = nodeRect.left - 18 - previewWidth >= 16;
    if (preferredSide === "right" && !canShowRight && canShowLeft) return "left";
    if (preferredSide === "left" && !canShowLeft && canShowRight) return "right";
    return preferredSide;
  };
  const showPreviewFromPointer = (page: LinkedPage, event: ReactPointerEvent<HTMLAnchorElement>) => {
    const node = event.currentTarget;
    const nodeRect = node.getBoundingClientRect();
    const nodeCenter = nodeRect.left + nodeRect.width / 2;
    const preferredSide = event.clientX >= nodeCenter ? "right" : "left";
    showPreview(page, previewSideForNode(node, preferredSide));
  };
  const schedulePreviewClose = () => {
    closeTimerRef.current = window.setTimeout(() => setActivePage(null), 100);
  };

  return (
    <section
      className="internal-universe-groups"
      aria-label="内部リンクでつながる記事"
      data-universe-obstacle
      ref={graphRef}
      style={{ blockSize: `${layout.height}px` }}
    >
      <svg viewBox={`0 0 ${width} ${layout.height}`} preserveAspectRatio="none" aria-hidden="true">
        {layout.links.map(({ source, target }) => (
          <line
            key={`${source.id}:${target.id}`}
            x1={source.x}
            y1={source.y}
            x2={target.x}
            y2={target.y}
          />
        ))}
      </svg>
      {layout.topics.map((topic) => {
        const name = topic.name || "";
        const style = {
          "--internal-topic-x": `${topic.x}px`,
          "--internal-topic-y": `${topic.y}px`
        } as CSSProperties;
        const content = topic.group?.kind === "url" ? (
          <EmbedCard
            url={name}
            metadata={embeds[name] || undefined}
            failed={embeds[name] === null}
          />
        ) : name;
        return <span
          className="internal-universe-group__topic-wrap"
          key={topic.id}
          onPointerEnter={() => onActiveTopicChange(name || null)}
          onPointerLeave={() => onActiveTopicChange(null)}
          onFocus={() => onActiveTopicChange(name || null)}
          onBlur={() => onActiveTopicChange(null)}
        >
          <a
            className="internal-universe-group__topic-node"
            href={topic.group?.kind === "url" ? name : `/${encodePageName(name)}`}
            data-universe-topic={name}
            aria-label={name}
            target={topic.group?.kind === "url" ? "_blank" : undefined}
            rel={topic.group?.kind === "url" ? "noreferrer" : undefined}
            style={style}
          />
          {topic.group?.kind === "url" && youtubeVideoId(name) ? <span
            className="internal-universe-group__topic internal-universe-group__topic--external"
            style={style}
          >
            {content}
          </span> : <a
            className={`internal-universe-group__topic${topic.group?.kind === "url" ? " internal-universe-group__topic--external" : ""}`}
            href={topic.group?.kind === "url" ? name : `/${encodePageName(name)}`}
            target={topic.group?.kind === "url" ? "_blank" : undefined}
            rel={topic.group?.kind === "url" ? "noreferrer" : undefined}
            style={style}
          >
            {content}
          </a>}
        </span>
      })}
      {layout.pages.map((node) => {
        const page = node.page;
        if (!page) return null;
        const connectionCount = connectionCounts.get(node.id) || 1;
        const visual = internalNodeVisual(
          connectionCount,
          Date.parse(page.created_at),
          pageCreatedAtRange.oldest,
          pageCreatedAtRange.newest
        );
        return (
          <a
            className="internal-universe-group__node"
            href={`/${encodePageName(page.route)}`}
            aria-label={`${page.title}（関連${connectionCount}件）`}
            key={page.id}
            style={{
              "--internal-node-x": `${node.x}px`,
              "--internal-node-y": `${node.y}px`,
              "--internal-node-size": `${visual.size}px`,
              "--internal-node-opacity": visual.opacity
            } as CSSProperties}
            onPointerEnter={(event) => showPreviewFromPointer(page, event)}
            onMouseLeave={schedulePreviewClose}
            onFocus={(event) => {
              const preferredSide = (node.x ?? 0) < width / 2 ? "right" : "left";
              showPreview(page, previewSideForNode(event.currentTarget, preferredSide));
            }}
            onBlur={schedulePreviewClose}
          />
        );
      })}
      {activePage && activeNode && (
        <a
          className="internal-universe-group__preview page-card__link"
          href={`/${encodePageName(activePage.route)}`}
          style={{
            "--internal-preview-anchor-x": `${activeNode.x}px`,
            "--internal-preview-y": `${previewY}px`
          } as CSSProperties}
          data-side={previewSide}
          onMouseEnter={() => showPreview(activePage, previewSide)}
          onMouseLeave={schedulePreviewClose}
        >
          {activePage.image_url && (
            <img className="page-card__image" src={activePage.image_url} alt="" loading="lazy" />
          )}
          <span className="page-card__title">{activePage.title}</span>
          {activePage.excerpt && <span className="page-card__excerpt">{activePage.excerpt}</span>}
        </a>
      )}
    </section>
  );
}

type UniversePoint = { x: number; y: number };
type UniverseRect = { top: number; right: number; bottom: number; left: number };
type UniverseSize = { width: number; height: number };
type UniverseLayout = {
  editorRect: UniverseRect;
  obstacles: Array<UniverseRect>;
  width: number;
  height: number;
};
type UniverseTopicLine = {
  name: string;
  kind: "wiki" | "url";
  anchor: UniversePoint;
  start: UniversePoint;
  end: UniversePoint;
};
type UniverseNode = UniversePoint & {
  url: string;
  anchor: UniversePoint;
  target: UniversePoint;
  vx: number;
  vy: number;
};
const UNIVERSE_NODE_RADIUS = 7;
const UNIVERSE_NODE_GAP = 15;
const UNIVERSE_PREVIEW_GAP = 20;
const EDITOR_FOCUS_RING_CLEARANCE = 6;

function useUniverseEnabled(): boolean {
  const [enabled, setEnabled] = useState(document.documentElement.dataset.universe === "on");

  useEffect(() => {
    const update = () => setEnabled(document.documentElement.dataset.universe === "on");
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-universe"]
    });
    update();
    return () => observer.disconnect();
  }, []);

  return enabled;
}

function relativeRect(element: Element, containerRect: DOMRect, padding = 0): UniverseRect {
  const rect = element.getBoundingClientRect();
  return {
    top: rect.top - containerRect.top - padding,
    right: rect.right - containerRect.left + padding,
    bottom: rect.bottom - containerRect.top + padding,
    left: rect.left - containerRect.left - padding
  };
}

function constrainNode(node: UniverseNode, obstacles: Array<UniverseRect>, width: number, height: number) {
  for (const obstacle of obstacles) {
    const left = obstacle.left - UNIVERSE_NODE_RADIUS;
    const right = obstacle.right + UNIVERSE_NODE_RADIUS;
    const top = obstacle.top - UNIVERSE_NODE_RADIUS;
    const bottom = obstacle.bottom + UNIVERSE_NODE_RADIUS;
    if (node.x <= left || node.x >= right || node.y <= top || node.y >= bottom) continue;

    const exits = [
      { distance: node.x - left, x: left, y: node.y },
      { distance: right - node.x, x: right, y: node.y },
      { distance: node.y - top, x: node.x, y: top },
      { distance: bottom - node.y, x: node.x, y: bottom }
    ];
    const nearest = exits.reduce((current, candidate) =>
      candidate.distance < current.distance ? candidate : current
    );
    node.x = nearest.x;
    node.y = nearest.y;
    node.vx *= 0.25;
    node.vy *= 0.25;
  }

  node.x = Math.min(width - UNIVERSE_NODE_RADIUS, Math.max(UNIVERSE_NODE_RADIUS, node.x));
  node.y = Math.min(height - UNIVERSE_NODE_RADIUS, Math.max(UNIVERSE_NODE_RADIUS, node.y));
}

function tickUniverse(nodes: Array<UniverseNode>, obstacles: Array<UniverseRect>, width: number, height: number) {
  for (const node of nodes) {
    node.vx += (node.target.x - node.x) * 0.018;
    node.vy += (node.target.y - node.y) * 0.018;
  }

  for (let index = 0; index < nodes.length; index += 1) {
    for (let otherIndex = index + 1; otherIndex < nodes.length; otherIndex += 1) {
      const node = nodes[index];
      const other = nodes[otherIndex];
      const dx = other.x - node.x;
      const dy = other.y - node.y;
      const distance = Math.hypot(dx, dy) || 0.01;
      const minimum = UNIVERSE_NODE_RADIUS * 2 + UNIVERSE_NODE_GAP;
      if (distance >= minimum) continue;

      const force = (minimum - distance) * 0.08;
      const forceX = dx / distance * force;
      const forceY = dy / distance * force;
      node.vx -= forceX;
      node.vy -= forceY;
      other.vx += forceX;
      other.vy += forceY;
    }
  }

  for (const node of nodes) {
    node.vx *= 0.82;
    node.vy *= 0.82;
    node.x += node.vx;
    node.y += node.vy;
    constrainNode(node, obstacles, width, height);
  }
}

function universeSeed(url: string): number {
  let seed = 0;
  for (const character of url) {
    seed = (seed * 31 + character.charCodeAt(0)) >>> 0;
  }
  return seed;
}

function initialUniverseNodes(
  urls: Array<string>,
  anchors: Map<string, UniversePoint>,
  editorRect: UniverseRect,
  width: number
): Array<UniverseNode> {
  const preferredSide = width - editorRect.right >= editorRect.left ? "right" : "left";

  return urls.flatMap((url, index) => {
    const anchor = anchors.get(url);
    if (!anchor) return [];

    const seed = universeSeed(url);
    const side = index % 2 === 0 ? preferredSide : preferredSide === "right" ? "left" : "right";
    const horizontalDistance = 34 + seed % 104;
    const verticalOffset = (Math.floor(seed / 104) % 81) - 40;
    const targetX = side === "right"
      ? editorRect.right + horizontalDistance
      : editorRect.left - horizontalDistance;
    const targetY = anchor.y + verticalOffset;
    return [{
      url,
      anchor,
      target: { x: targetX, y: targetY },
      x: targetX + (side === "right" ? 18 : -18),
      y: targetY + (index % 2 === 0 ? -12 : 12),
      vx: 0,
      vy: 0
    }];
  });
}

function rectOverlapArea(rect: UniverseRect, other: UniverseRect): number {
  const width = Math.max(0, Math.min(rect.right, other.right) - Math.max(rect.left, other.left));
  const height = Math.max(0, Math.min(rect.bottom, other.bottom) - Math.max(rect.top, other.top));
  return width * height;
}

function previewPosition(
  node: UniverseNode,
  nodes: Array<UniverseNode>,
  size: UniverseSize,
  layout: UniverseLayout
): UniversePoint {
  const candidates = [
    { x: node.x + UNIVERSE_PREVIEW_GAP, y: node.y - size.height / 2 },
    { x: node.x + UNIVERSE_PREVIEW_GAP, y: node.y + UNIVERSE_PREVIEW_GAP },
    { x: node.x + UNIVERSE_PREVIEW_GAP, y: node.y - size.height - UNIVERSE_PREVIEW_GAP },
    { x: node.x - size.width - UNIVERSE_PREVIEW_GAP, y: node.y - size.height / 2 },
    { x: node.x - size.width - UNIVERSE_PREVIEW_GAP, y: node.y + UNIVERSE_PREVIEW_GAP },
    { x: node.x - size.width - UNIVERSE_PREVIEW_GAP, y: node.y - size.height - UNIVERSE_PREVIEW_GAP },
    { x: node.x - size.width / 2, y: node.y + UNIVERSE_PREVIEW_GAP },
    { x: node.x - size.width / 2, y: node.y - size.height - UNIVERSE_PREVIEW_GAP }
  ];
  const nodeRects = nodes
    .filter((candidate) => candidate.url !== node.url)
    .map((candidate) => ({
      top: candidate.y - UNIVERSE_NODE_RADIUS,
      right: candidate.x + UNIVERSE_NODE_RADIUS,
      bottom: candidate.y + UNIVERSE_NODE_RADIUS,
      left: candidate.x - UNIVERSE_NODE_RADIUS
    }));

  return candidates
    .map((candidate) => {
      const x = Math.max(16, Math.min(candidate.x, layout.width - size.width - 16));
      const y = Math.max(0, Math.min(candidate.y, layout.height - size.height));
      const rect = { top: y, right: x + size.width, bottom: y + size.height, left: x };
      const obstacleOverlap = layout.obstacles
        .reduce((total, obstacle) => total + rectOverlapArea(rect, obstacle), 0);
      const nodeOverlap = nodeRects
        .reduce((total, nodeRect) => total + rectOverlapArea(rect, nodeRect), 0);
      const overlap = obstacleOverlap + nodeOverlap * 1000;
      return { x, y, overlap };
    })
    .reduce((best, candidate) => candidate.overlap < best.overlap ? candidate : best);
}

function editorEdgePoint(anchor: UniversePoint, node: UniversePoint, rect: UniverseRect): UniversePoint {
  const dx = node.x - anchor.x;
  const dy = node.y - anchor.y;
  const candidates: Array<{ t: number; point: UniversePoint }> = [];

  for (const x of [rect.left, rect.right]) {
    if (dx === 0) continue;
    const t = (x - anchor.x) / dx;
    const y = anchor.y + dy * t;
    if (t >= 0 && t <= 1 && y >= rect.top && y <= rect.bottom) {
      candidates.push({ t, point: { x, y } });
    }
  }
  for (const y of [rect.top, rect.bottom]) {
    if (dy === 0) continue;
    const t = (y - anchor.y) / dy;
    const x = anchor.x + dx * t;
    if (t >= 0 && t <= 1 && x >= rect.left && x <= rect.right) {
      candidates.push({ t, point: { x, y } });
    }
  }

  if (candidates.length === 0) return anchor;
  return candidates.reduce((nearest, candidate) =>
    candidate.t < nearest.t ? candidate : nearest
  ).point;
}

function linkUnderlineAnchor(link: HTMLAnchorElement, workspaceRect: DOMRect): UniversePoint {
  const textLength = link.textContent?.length || 0;
  const targetOffset = Math.floor(Math.max(0, textLength - 1) / 2);
  const walker = document.createTreeWalker(link, NodeFilter.SHOW_TEXT);
  let consumed = 0;
  let textNode = walker.nextNode();

  while (textNode) {
    const length = textNode.textContent?.length || 0;
    if (targetOffset < consumed + length) {
      const range = document.createRange();
      const offset = targetOffset - consumed;
      range.setStart(textNode, offset);
      range.setEnd(textNode, Math.min(offset + 1, length));
      const rect = range.getBoundingClientRect();
      if (rect.width > 0 || rect.height > 0) {
        return {
          x: rect.left - workspaceRect.left + rect.width / 2,
          y: rect.bottom - workspaceRect.top - 1
        };
      }
    }
    consumed += length;
    textNode = walker.nextNode();
  }

  const rect = link.getBoundingClientRect();
  return {
    x: rect.left - workspaceRect.left + rect.width / 2,
    y: rect.bottom - workspaceRect.top - 1
  };
}

export function topicSourceElement(
  editorRoot: HTMLElement,
  kind: LinkedPageGroup["kind"],
  name: string
): HTMLElement | null {
  if (kind === "url" && youtubeVideoId(name)) {
    const player = Array.from(editorRoot.querySelectorAll<HTMLElement>("[data-youtube-player]"))
      .find((candidate) => candidate.dataset.youtubePlayer === name);
    if (player) return player;
  }
  const href = kind === "url"
    ? name
    : new URL(`/${encodePageName(name)}`, window.location.origin).href;
  const link = Array.from(editorRoot.querySelectorAll<HTMLAnchorElement>("a[href]"))
    .find((candidate) => candidate.href === href);
  if (link) return link;
  return null;
}

function elementCenter(element: HTMLElement, workspaceRect: DOMRect): UniversePoint {
  const rect = element.getBoundingClientRect();
  return {
    x: rect.left - workspaceRect.left + rect.width / 2,
    y: rect.top - workspaceRect.top + rect.height / 2
  };
}

function Universe({
  urls,
  topics,
  activeTopic,
  editor,
  editorContentReady,
  enabled,
  workspaceRef
}: {
  urls: Array<string>;
  topics: Array<Pick<LinkedPageGroup, "kind" | "name">>;
  activeTopic: string | null;
  editor: Editor | null;
  editorContentReady: boolean;
  enabled: boolean;
  workspaceRef: RefObject<HTMLDivElement | null>;
}) {
  const [nodes, setNodes] = useState<Array<UniverseNode>>([]);
  const [topicLines, setTopicLines] = useState<Array<UniverseTopicLine>>([]);
  const [embeds, setEmbeds] = useState<Record<string, EmbedMetadata | null>>({});
  const [failedEmbeds, setFailedEmbeds] = useState<Array<string>>([]);
  const [cardSizes, setCardSizes] = useState<Record<string, UniverseSize>>({});
  const [layout, setLayout] = useState<UniverseLayout | null>(null);
  const [activeUrl, setActiveUrl] = useState<string | null>(null);
  const closeTimerRef = useRef<number | null>(null);
  const measurementsRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!enabled) return;

    let active = true;
    void Promise.all(urls.map(async (url) => {
      try {
        const metadata = await fetchJson<EmbedMetadata>(`/api/embed?${new URLSearchParams({ url }).toString()}`);
        return { url, metadata };
      } catch (_error) {
        return { url, metadata: null };
      }
    })).then((results) => {
      if (!active) return;
      setEmbeds(Object.fromEntries(results.map(({ url, metadata }) => [url, metadata])));
      setFailedEmbeds(results.filter(({ metadata }) => metadata === null).map(({ url }) => url));
    });

    return () => {
      active = false;
    };
  }, [enabled, urls]);

  useLayoutEffect(() => {
    const measurements = measurementsRef.current;
    if (!enabled || !measurements) return;

    const update = () => {
      const nextSizes = Object.fromEntries(
        Array.from(measurements.querySelectorAll<HTMLElement>("[data-universe-card]"))
          .map((element) => [element.dataset.universeCard || "", {
            width: element.offsetWidth,
            height: element.offsetHeight
          }])
          .filter(([url]) => url)
      );
      setCardSizes(nextSizes);
    };
    const observer = new ResizeObserver(update);
    measurements.querySelectorAll<HTMLElement>("[data-universe-card]")
      .forEach((element) => observer.observe(element));
    update();
    return () => observer.disconnect();
  }, [embeds, enabled, urls]);

  const closePreview = useCallback(() => {
    closeTimerRef.current = window.setTimeout(() => setActiveUrl(null), 120);
  }, []);

  const openPreview = useCallback((url: string) => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    setActiveUrl(url);
  }, []);

  useLayoutEffect(() => {
    const workspace = workspaceRef.current;
    if (!enabled || !editor || !editorContentReady || !workspace || (urls.length === 0 && topics.length === 0)) {
      setNodes([]);
      setTopicLines([]);
      setActiveUrl(null);
      return;
    }

    let animationFrame = 0;
    let measureFrame = 0;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    const measure = () => {
      window.cancelAnimationFrame(measureFrame);
      window.cancelAnimationFrame(animationFrame);
      measureFrame = window.requestAnimationFrame(() => {
        const workspaceRect = workspace.getBoundingClientRect();
        const editorShell = workspace.querySelector<HTMLElement>(".editor-shell");
        if (!editorShell) return;

        const anchors = new Map<string, UniversePoint>();
        const links = Array.from(editor.view.dom.querySelectorAll<HTMLAnchorElement>("a[href]:not(.youtube-player__fallback)"));
        for (const url of urls) {
          const link = links.find((candidate) => candidate.href === url);
          if (!link) continue;
          const rect = link.getBoundingClientRect();
          anchors.set(url, {
            x: rect.left - workspaceRect.left + rect.width / 2,
            y: rect.top - workspaceRect.top + rect.height / 2
          });
        }

        const obstacles = Array.from(workspace.querySelectorAll<HTMLElement>("[data-universe-obstacle]"))
          .map((element) => relativeRect(element, workspaceRect, 20));
        const editorRect = relativeRect(editorShell, workspaceRect, 20);
        const focusRingClearance = editor.view.dom.matches(":focus-visible")
          ? EDITOR_FOCUS_RING_CLEARANCE
          : 0;
        const glassRect = relativeRect(editorShell, workspaceRect, focusRingClearance);
        const width = workspace.clientWidth;
        const height = workspace.scrollHeight;
        setLayout({ editorRect: glassRect, obstacles, width, height });
        setTopicLines((currentLines) => topics.flatMap(({ kind, name }) => {
          const source = topicSourceElement(editor.view.dom, kind, name);
          const topic = workspace.querySelector<HTMLElement>(`[data-universe-topic="${CSS.escape(name)}"]`);
          if (!topic) return [];
          if (!source) {
            const currentLine = currentLines.find((line) => line.kind === kind && line.name === name);
            return currentLine ? [currentLine] : [];
          }
          const anchor = source instanceof HTMLAnchorElement
            ? linkUnderlineAnchor(source, workspaceRect)
            : elementCenter(source, workspaceRect);
          const topicRect = relativeRect(topic, workspaceRect);
          const center = {
            x: (topicRect.left + topicRect.right) / 2,
            y: (topicRect.top + topicRect.bottom) / 2
          };
          return [{
            name,
            kind,
            anchor,
            start: editorEdgePoint(anchor, center, glassRect),
            end: editorEdgePoint(center, anchor, topicRect)
          }];
        }));
        const nextNodes = initialUniverseNodes(urls, anchors, editorRect, width);

        if (nextNodes.length === 0) {
          setNodes([]);
          return;
        }

        if (reducedMotion.matches) {
          for (let iteration = 0; iteration < 100; iteration += 1) {
            tickUniverse(nextNodes, obstacles, width, height);
          }
          setNodes(nextNodes.map((node) => ({ ...node })));
          return;
        }

        let iteration = 0;
        const animate = () => {
          tickUniverse(nextNodes, obstacles, width, height);
          setNodes(nextNodes.map((node) => ({ ...node })));
          iteration += 1;
          if (iteration < 100) animationFrame = window.requestAnimationFrame(animate);
        };
        animate();
      });
    };

    const observer = new ResizeObserver(measure);
    observer.observe(workspace);
    workspace.querySelectorAll<HTMLElement>("[data-universe-obstacle]")
      .forEach((element) => observer.observe(element));
    editor.on("update", measure);
    editor.on("focus", measure);
    editor.on("blur", measure);
    measure();

    return () => {
      window.cancelAnimationFrame(measureFrame);
      window.cancelAnimationFrame(animationFrame);
      observer.disconnect();
      editor.off("update", measure);
      editor.off("focus", measure);
      editor.off("blur", measure);
    };
  }, [editor, editorContentReady, enabled, topics, urls, workspaceRef]);

  useEffect(() => () => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
  }, []);

  if (!enabled) return null;

  const activeNode = nodes.find((node) => node.url === activeUrl);
  const activeTopicLine = topicLines.find((line) => line.name === activeTopic);
  const activeSize = activeNode ? cardSizes[activeNode.url] || { width: 256, height: 128 } : null;
  const activePosition = activeNode && activeSize && layout
    ? previewPosition(activeNode, nodes, activeSize, layout)
    : null;
  const previewStyle = activePosition ? {
    "--universe-preview-x": `${activePosition.x}px`,
    "--universe-preview-y": `${activePosition.y}px`
  } as CSSProperties : undefined;

  return (
    <div className="universe" aria-label="ユニバース">
      {layout && (
        <>
          <svg className="universe__graph" aria-hidden="true">
            {nodes.map((node) => {
              const start = editorEdgePoint(node.anchor, node, layout.editorRect);
              return <line className="universe__external-line" key={node.url} x1={start.x} y1={start.y} x2={node.x} y2={node.y} />;
            })}
            {topicLines.map((line) => (
              <line
                className={line.kind === "url" ? "universe__external-line" : "universe__internal-line"}
                key={`topic:${line.name}`}
                x1={line.start.x}
                y1={line.start.y}
                x2={line.end.x}
                y2={line.end.y}
              />
            ))}
          </svg>
          {activeTopicLine && (
            <svg className="universe__graph universe__graph--active" aria-hidden="true">
              <line
                className={`${activeTopicLine.kind === "url" ? "universe__external-line" : "universe__internal-line"} universe__internal-line--active`}
                x1={activeTopicLine.anchor.x}
                y1={activeTopicLine.anchor.y}
                x2={activeTopicLine.start.x}
                y2={activeTopicLine.start.y}
              />
            </svg>
          )}
        </>
      )}
      <div className="universe__nodes">
        {nodes.map((node) => (
          <a
            className="universe__node"
            href={node.url}
            target="_blank"
            rel="noreferrer"
            aria-label={`${externalLinkLabel(node.url)}を開く`}
            aria-describedby={activeUrl === node.url ? "universe-preview" : undefined}
            key={node.url}
            style={{ "--universe-x": `${node.x}px`, "--universe-y": `${node.y}px` } as CSSProperties}
            onMouseEnter={() => openPreview(node.url)}
            onMouseLeave={closePreview}
            onFocus={() => openPreview(node.url)}
            onBlur={closePreview}
          />
        ))}
      </div>
      {activeNode && previewStyle && (
        <div
          className="universe__preview"
          id="universe-preview"
          role="tooltip"
          style={previewStyle}
          onMouseEnter={() => openPreview(activeNode.url)}
          onMouseLeave={closePreview}
        >
          <EmbedCard
            url={activeNode.url}
            metadata={embeds[activeNode.url] || undefined}
            failed={failedEmbeds.includes(activeNode.url)}
          />
        </div>
      )}
      <div className="universe__measurements" ref={measurementsRef} aria-hidden="true">
        {urls.map((url) => (
          <div data-universe-card={url} key={url}>
            <EmbedCard
              url={url}
              metadata={embeds[url] || undefined}
              failed={failedEmbeds.includes(url)}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

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
      nodeType.create({ url: replacement.url })
    );
  }
  return transaction;
}

const YouTubePlayer = TiptapNode.create({
  name: "youtubePlayer",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { url: { default: "" } };
  },

  parseHTML() {
    return [{
      tag: "div[data-youtube-player]",
      getAttrs: (element) => ({ url: (element as HTMLElement).dataset.youtubePlayer || "" })
    }];
  },

  renderHTML({ node }) {
    const url = node.attrs.url as string;
    const videoId = youtubeVideoId(url);
    const thumbnailUrl = `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg`;
    const fallbackThumbnailUrl = `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`;
    return [
      "div",
      { class: "youtube-player", "data-youtube-player": url },
      ["iframe", {
        src: `https://www.youtube.com/embed/${videoId}?enablejsapi=1`,
        "data-youtube-player-frame": "",
        title: "YouTube動画",
        loading: "lazy",
        allow: "accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture",
        referrerpolicy: "strict-origin-when-cross-origin",
        allowfullscreen: ""
      }],
      ["a", {
        class: "youtube-player__fallback",
        href: url,
        target: "_blank",
        rel: "noreferrer",
        "aria-label": "YouTubeで動画を見る"
      },
      ["img", {
        src: thumbnailUrl,
        alt: "",
        loading: "lazy",
        "data-youtube-thumbnail-fallback": fallbackThumbnailUrl
      }],
      ["span", { class: "youtube-player__brand", "aria-hidden": "true" }, "YouTube"],
      ["span", { class: "youtube-player__details" },
        ["strong", {}, "YouTubeで見る"],
        ["span", { class: "youtube-player__url" }, url]]]
    ];
  },

  renderMarkdown: (node) => node.attrs?.url || "",

  onCreate() {
    const transaction = replaceYouTubeParagraphs(this.editor.state, this.type);
    if (transaction) this.editor.view.dispatch(transaction);
  },

  addProseMirrorPlugins() {
    return [new Plugin({
      appendTransaction: (transactions, oldState, state) => {
        if (transactions.some((transaction) => transaction.getMeta("youtubePlayerRawEditing"))) return null;
        if (transactions.some((transaction) => transaction.selectionSet)) {
          const selection = state.selection;
          const enteredFromBefore = selection instanceof NodeSelection
            && oldState.selection.to <= selection.from;
          if (selection instanceof NodeSelection && selection.node.type === this.type) {
            const url = selection.node.attrs.url;
            if (typeof url === "string" && url.length > 0) {
              const paragraph = state.schema.nodes.paragraph.create(null, state.schema.text(url));
              const transaction = state.tr.replaceWith(selection.from, selection.to, paragraph);
              return transaction
                .setSelection(TextSelection.create(
                  transaction.doc,
                  selection.from + (enteredFromBefore ? 1 : url.length + 1)
                ))
                .setMeta("youtubePlayerRawEditing", true);
            }
          }
        }
        return replaceYouTubeParagraphs(state, this.type);
      }
    })];
  }
});

export const EDITOR_EXTENSIONS = [
  StarterKit.configure({
    dropcursor: false,
    gapcursor: false,
    underline: false,
    link: {
      openOnClick: true,
      autolink: false,
      linkOnPaste: false,
      HTMLAttributes: {
        target: "_self"
      }
    }
  }),
  WikiLinks,
  Image.configure({ allowBase64: false }),
  YouTubePlayer,
  Markdown.configure({ indentation: { style: "space", size: 2 } })
];

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function initialDraft(bootstrap: EditorBootstrap): EditorDraft {
  return {
    pageId: bootstrap.page_id,
    pageType: bootstrap.page_type,
    date: bootstrap.date,
    name: bootstrap.name,
    title: bootstrap.title,
    body: bootstrap.body,
    coverMode: bootstrap.cover_mode || "auto",
    coverImageUrl: bootstrap.cover_image_url || null,
    resolvedCoverImageUrl: bootstrap.resolved_cover_image_url || null,
    expectedUpdatedAt: bootstrap.expected_updated_at
  };
}

export function editorDocumentTitle(title: string, environment?: string): string {
  const pageTitle = title ? `${title} : weblog.ason.as` : "weblog.ason.as";
  return environment === "development" ? `[dev] ${pageTitle}` : pageTitle;
}

function editorDocument(title: string, body: string): string {
  return [title, markdownForEditor(body)].filter((part) => part.length > 0).join("\n\n");
}

export function replaceEditorContentPreservingSelection(editor: Editor, content: string): void {
  const { anchor, head } = editor.state.selection;
  editor.commands.setContent(content, {
    contentType: "markdown",
    emitUpdate: false
  });

  const resolvePosition = (position: number) =>
    editor.state.doc.resolve(Math.min(position, editor.state.doc.content.size));
  const transaction = editor.state.tr.setSelection(TextSelection.between(
    resolvePosition(anchor),
    resolvePosition(head)
  ));
  editor.view.dispatch(transaction);
}

function splitEditorDocument(markdown: string): Pick<EditorDraft, "title" | "body"> {
  const [title = "", ...bodyLines] = markdownForSource(markdown).split("\n");
  return {
    title: title.trim(),
    body: bodyLines.join("\n").replace(/^\n+/, "")
  };
}

export function ensureBodySelection(editor: Editor): void {
  const title = editor.state.doc.firstChild;
  if (!title || editor.state.selection.from > title.nodeSize) return;

  const bodyStart = title.nodeSize;
  const transaction = editor.state.tr.insert(bodyStart, editor.schema.nodes.paragraph.create());
  transaction.setSelection(TextSelection.create(transaction.doc, bodyStart + 1));
  editor.view.dispatch(transaction);
}

async function requestJson<T>(url: string, payload: JsonObject, method: HttpMethod = "POST"): Promise<T> {
  const csrfToken = document.documentElement.dataset.csrfToken;
  const response = await fetch(url, {
    method,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {})
    },
    body: JSON.stringify(payload)
  });

  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    const error = new Error(typeof result.error === "string" ? result.error : "操作を完了できませんでした") as ApiError;
    if (isJsonObject(result.errors)) {
      error.fields = result.errors as Record<string, string[]>;
    }
    throw error;
  }

  return raw as T;
}

async function fetchJson<T>(url: string): Promise<T> {
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    throw new Error(typeof result.error === "string" ? result.error : "操作を完了できませんでした");
  }

  return raw as T;
}

async function fetchPageIfChanged(
  pageId: string,
  etag: string | null
): Promise<{ page: PageResponse | null; etag: string | null }> {
  const response = await fetch(`/api/pages/${encodeURIComponent(pageId)}`, {
    headers: {
      Accept: "application/json",
      ...(etag ? { "If-None-Match": etag } : {})
    }
  });
  if (response.status === 304) return { page: null, etag };

  const page = await response.json() as PageResponse;
  if (!response.ok) throw new Error("ページを同期できませんでした");

  return { page, etag: response.headers.get("etag") };
}

async function uploadImage(file: File, inboxDate?: string): Promise<string> {
  const upload = await requestJson<UploadResponse>("/api/uploads", {
    content_type: file.type,
    size: file.size,
    ...(inboxDate ? { inbox_date: inboxDate } : {})
  });
  const form = new FormData();
  for (const [key, value] of Object.entries(upload.fields)) form.append(key, value);
  form.append("file", file);
  const response = await fetch(upload.upload_url, { method: "POST", body: form });
  if (!response.ok) throw new Error("画像をS3へ送信できませんでした");
  return upload.public_url;
}

function statusMessage(page: PageResponse): string {
  return page.updated_at ? `保存済み・最終更新 ${page.updated_at}` : "保存済み";
}

export function AuthoringEditor({
  bootstrap,
  canEdit = document.documentElement.dataset.canEdit === "true"
}: {
  bootstrap: EditorBootstrap;
  canEdit?: boolean;
}) {
  const [draft, setDraft] = useState<EditorDraft>(() => initialDraft(bootstrap));
  const [editorContentReady, setEditorContentReady] = useState(false);
  const [status, setStatus] = useState(bootstrap.save_message);
  const [lineUpdatedAt, setLineUpdatedAt] = useState(bootstrap.line_updated_at || []);
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);
  const [uploadingImages, setUploadingImages] = useState(false);
  const [draggingImages, setDraggingImages] = useState(false);
  const [imageUploadStatus, setImageUploadStatus] = useState("");
  const [materialStatus, setMaterialStatus] = useState("");
  const [inboxItems, setInboxItems] = useState<Array<InboxItem>>([]);
  const [activeMaterialTab, setActiveMaterialTab] = useState<MaterialTab>("photo");
  const [materialSheetOpen, setMaterialSheetOpen] = useState(false);
  const [materialSheetViewport, setMaterialSheetViewport] = useState(
    () => window.matchMedia?.("(max-width: 52rem)").matches ?? false
  );
  const [loadingInbox, setLoadingInbox] = useState(false);
  const [syncingInbox, setSyncingInbox] = useState(false);
  const [linkedPages, setLinkedPages] = useState(bootstrap.linked_pages || []);
  const [linkedPagesHasMore, setLinkedPagesHasMore] = useState(bootstrap.linked_pages_has_more || false);
  const [loadingLinkedPages, setLoadingLinkedPages] = useState(false);
  const [linkedPagesError, setLinkedPagesError] = useState("");
  const [activeUniverseTopic, setActiveUniverseTopic] = useState<string | null>(null);
  const [wikiLinkNames, setWikiLinkNames] = useState<Array<string>>([]);
  const [wikiLinkQueryState, setWikiLinkQueryState] = useState<WikiLinkQuery | null>(null);
  const [activeWikiLinkSuggestion, setActiveWikiLinkSuggestion] = useState(0);
  const draftRef = useRef(draft);
  const dirtyRef = useRef(false);
  const savingRef = useRef(false);
  const editVersionRef = useRef(0);
  const saveTimerRef = useRef<number | null>(null);
  const pendingSaveRef = useRef(false);
  const savedBodyRef = useRef(bootstrap.body);
  const savedNameRef = useRef(bootstrap.name || bootstrap.title);
  const loadingLinkedPagesRef = useRef(false);
  const linkedPagesSentinelRef = useRef<HTMLDivElement | null>(null);
  const pageEtagRef = useRef<string | null>(null);
  const refreshingPageRef = useRef(false);
  const imageDragDepthRef = useRef(0);
  const consumedInboxItemIdsRef = useRef<Array<string>>([]);
  const materialDrawerRef = useRef<HTMLElement | null>(null);
  const materialSheetButtonRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    document.title = editorDocumentTitle(draft.title, document.documentElement.dataset.environment);
  }, [draft.title]);
  useEffect(() => {
    document.documentElement.dataset.view = canEdit ? "article-editing" : "reading";
    return () => {
      delete document.documentElement.dataset.view;
    };
  }, [canEdit]);
  useEffect(() => {
    const media = window.matchMedia?.("(max-width: 52rem)");
    if (!media) return;
    const update = () => {
      setMaterialSheetViewport(media.matches);
      if (!media.matches) setMaterialSheetOpen(false);
    };
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  const closeMaterialSheet = useCallback(() => {
    setMaterialSheetOpen(false);
    window.setTimeout(() => materialSheetButtonRef.current?.focus(), 0);
  }, []);
  useEffect(() => {
    if (!materialSheetViewport || !materialSheetOpen) return;
    const drawer = materialDrawerRef.current;
    const workspace = workspaceRef.current;
    if (!drawer || !workspace) return;
    const inertTargets = Array.from(workspace.children).filter(
      (element): element is HTMLElement => element instanceof HTMLElement
        && element !== drawer
        && !element.classList.contains("content-inbox__backdrop")
    );
    inertTargets.forEach((target) => target.setAttribute("inert", ""));
    document.body.style.overflow = "hidden";
    const focusable = () => Array.from(drawer.querySelectorAll<HTMLElement>(
      'button:not([disabled]), input:not([disabled]), [href], [tabindex]:not([tabindex="-1"])'
    ));
    focusable()[0]?.focus();
    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeMaterialSheet();
        return;
      }
      if (event.key !== "Tab") return;
      const controls = focusable();
      if (controls.length === 0) return;
      const first = controls[0];
      const last = controls.at(-1)!;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
      inertTargets.forEach((target) => target.removeAttribute("inert"));
      document.body.style.removeProperty("overflow");
    };
  }, [closeMaterialSheet, materialSheetOpen, materialSheetViewport]);
  const initialFocusAppliedRef = useRef(false);
  const editorContentReadyFrameRef = useRef<number | null>(null);
  const workspaceRef = useRef<HTMLDivElement | null>(null);
  const isUnpersistedRouteRef = useRef(
    !bootstrap.page_id &&
    bootstrap.title.length > 0 &&
    window.location.pathname !== "/" &&
    window.location.pathname !== "/editor/new"
  );

  const handleEditorContentRef = useCallback((element: HTMLDivElement | null) => {
    if (editorContentReadyFrameRef.current !== null) {
      window.cancelAnimationFrame(editorContentReadyFrameRef.current);
    }
    if (!element) {
      setEditorContentReady(false);
      return;
    }
    editorContentReadyFrameRef.current = window.requestAnimationFrame(() => {
      setEditorContentReady(true);
    });
  }, []);

  const updateDraft = useCallback((changes: Partial<EditorDraft>) => {
    const next = { ...draftRef.current, ...changes };
    draftRef.current = next;
    setDraft(next);
    return next;
  }, []);

  const setDirtyState = useCallback((value: boolean) => {
    dirtyRef.current = value;
  }, []);

  const savePage = useCallback(async () => {
    if (!draftRef.current.pageId && !draftRef.current.title.trim()) return;
    if (isUnpersistedRouteRef.current && !draftRef.current.body.trim()) return;
    if (savingRef.current) {
      pendingSaveRef.current = true;
      return;
    }

    if (saveTimerRef.current !== null) {
      window.clearTimeout(saveTimerRef.current);
      saveTimerRef.current = null;
    }

    const snapshot = { ...draftRef.current };
    const consumedInboxItemIds = [...consumedInboxItemIdsRef.current];
    const savedVersion = editVersionRef.current;
    savingRef.current = true;
    setSaving(true);
    setStatus("保存中…");

    try {
      const endpoint = snapshot.pageId
        ? `/api/authoring/pages/${encodeURIComponent(snapshot.pageId)}`
        : "/api/authoring/pages";
      const page = await requestJson<PageResponse>(endpoint, {
        page_id: snapshot.pageId,
        page_type: snapshot.pageType,
        date: snapshot.date,
        name: snapshot.name || undefined,
        title: snapshot.title || undefined,
        body: snapshot.body,
        cover_mode: snapshot.coverMode,
        cover_image_url: snapshot.coverImageUrl,
        expected_updated_at: snapshot.expectedUpdatedAt || undefined,
        consumed_inbox_item_ids: consumedInboxItemIds
      }, snapshot.pageId ? "PATCH" : "POST");
      const current = draftRef.current;
      const next = {
        ...current,
        pageId: page.id,
        pageType: page.page_type,
        date: page.date || current.date,
        name: page.name || current.name,
        coverMode: page.cover_mode || current.coverMode,
        coverImageUrl: page.cover_image_url ?? current.coverImageUrl,
        resolvedCoverImageUrl: page.resolved_cover_image_url ?? current.resolvedCoverImageUrl,
        expectedUpdatedAt: page.updated_at || ""
      };
      draftRef.current = next;
      setDraft(next);
      savedNameRef.current = page.name || next.title;
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
      savedBodyRef.current = snapshot.body;
      setLineUpdatedAt(page.line_updated_at || []);
      if (!snapshot.pageId) {
        window.history.pushState(null, "", `/${encodePageName(page.route || page.name || next.title)}`);
      }
      setErrors({});
      consumedInboxItemIdsRef.current = consumedInboxItemIdsRef.current.filter(
        (itemId) => !consumedInboxItemIds.includes(itemId)
      );
      setStatus(statusMessage(page));
      setDirtyState(editVersionRef.current !== savedVersion);
      if (editVersionRef.current !== savedVersion) pendingSaveRef.current = true;
    } catch (error) {
      const apiError = error as ApiError;
      const nextErrors = apiError.fields || { form: [apiError.message] };
      setErrors(nextErrors);
      setStatus(apiError.message);
      setDirtyState(true);
    } finally {
      savingRef.current = false;
      setSaving(false);
      if (pendingSaveRef.current) {
        pendingSaveRef.current = false;
        window.setTimeout(() => void savePage(), 0);
      }
    }
  }, [setDirtyState]);

  const scheduleSave = useCallback(() => {
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      saveTimerRef.current = null;
      void savePage();
    }, 300);
  }, [savePage]);

  const updateCover = useCallback((
    coverMode: EditorDraft["coverMode"],
    coverImageUrl: string | null,
    resolvedCoverImageUrl: string | null
  ) => {
    updateDraft({ coverMode, coverImageUrl, resolvedCoverImageUrl });
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
    scheduleSave();
  }, [scheduleSave, setDirtyState, updateDraft]);

  const handleDocumentChange = useCallback((markdown: string, hasBodyBlock: boolean) => {
    if (!canEdit) return;
    const next = updateDraft(splitEditorDocument(markdown));
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
    const isRenaming = next.pageId && next.pageType === "named" && next.title !== savedNameRef.current;
    if (isUnpersistedRouteRef.current && !next.body.trim()) return;
    if (!isRenaming && (next.pageId || (next.title && hasBodyBlock))) scheduleSave();
  }, [canEdit, scheduleSave, setDirtyState, updateDraft]);

  const handleEditorBlur = useCallback(async (currentEditor: Editor) => {
    if (!canEdit) return;
    const current = draftRef.current;
    if (!current.pageId) {
      if (current.title.trim()) void savePage();
      return;
    }
    if (current.pageType !== "named" || current.title === savedNameRef.current) {
      if (dirtyRef.current) void savePage();
      return;
    }
    if (savingRef.current) {
      window.setTimeout(() => void handleEditorBlur(currentEditor), 50);
      return;
    }

    const previousName = savedNameRef.current;
    if (!current.title.trim() || !window.confirm(`タイトルを「${previousName}」から「${current.title}」へ変更しますか？`)) {
      updateDraft({ title: previousName });
      currentEditor.commands.setContent(editorDocument(previousName, current.body), {
        contentType: "markdown",
        emitUpdate: false
      });
      scheduleSave();
      return;
    }

    if (saveTimerRef.current !== null) {
      window.clearTimeout(saveTimerRef.current);
      saveTimerRef.current = null;
    }
    const savedVersion = editVersionRef.current;
    savingRef.current = true;
    setSaving(true);
    setStatus("変更中…");

    try {
      const page = await requestJson<PageResponse>("/api/rename", {
        page_id: current.pageId,
        name: current.title,
        body: current.body,
        expected_updated_at: current.expectedUpdatedAt || undefined
      });
      const nextName = page.name || current.title;
      const next = updateDraft({
        name: nextName,
        title: nextName,
        expectedUpdatedAt: page.updated_at || ""
      });
      savedNameRef.current = nextName;
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
      currentEditor.commands.setContent(editorDocument(nextName, next.body), {
        contentType: "markdown",
        emitUpdate: false
      });
      window.history.replaceState(null, "", `/${encodePageName(page.route || page.name || next.title)}`);
      setErrors({});
      setStatus(statusMessage(page));
      setDirtyState(editVersionRef.current !== savedVersion);
    } catch (error) {
      const apiError = error as ApiError;
      setErrors(apiError.fields || { title: [apiError.message] });
      setStatus(apiError.message);
      setDirtyState(true);
    } finally {
      savingRef.current = false;
      setSaving(false);
    }
  }, [canEdit, savePage, scheduleSave, setDirtyState, updateDraft]);

  const loadMoreLinkedPages = useCallback(async () => {
    if (!linkedPagesHasMore || loadingLinkedPagesRef.current) return;

    const route = draftRef.current.name || draftRef.current.title;
    if (!route) return;

    loadingLinkedPagesRef.current = true;
    setLoadingLinkedPages(true);
    setLinkedPagesError("");
    const query = new URLSearchParams({ route, offset: String(linkedPages.length) });
    if (draftRef.current.pageId) query.set("excluding_id", draftRef.current.pageId);

    try {
      const result = await fetchJson<RelatedPagesResponse>(`/api/related?${query.toString()}`);
      setLinkedPages((current) => [...current, ...result.pages]);
      setLinkedPagesHasMore(result.has_more);
    } catch (error) {
      setLinkedPagesError((error as Error).message);
    } finally {
      loadingLinkedPagesRef.current = false;
      setLoadingLinkedPages(false);
    }
  }, [linkedPages.length, linkedPagesHasMore]);

  useEffect(() => {
    if (linkedPages.length === 0 && linkedPagesHasMore) void loadMoreLinkedPages();
  }, [linkedPages.length, linkedPagesHasMore, loadMoreLinkedPages]);

  useEffect(() => {
    const sentinel = linkedPagesSentinelRef.current;
    if (!sentinel || !linkedPagesHasMore) return;

    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) void loadMoreLinkedPages();
    }, { rootMargin: "320px 0px" });
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [linkedPagesHasMore, loadMoreLinkedPages]);

  const editor = useEditor({
    extensions: EDITOR_EXTENSIONS,
    content: editorDocument(bootstrap.title, bootstrap.body),
    contentType: "markdown",
    editable: canEdit,
    editorProps: {
      attributes: {
        role: "textbox",
        "aria-multiline": "true",
        "aria-label": "記事"
      }
    },
    onUpdate: ({ editor: currentEditor }) => {
      handleDocumentChange(currentEditor.getMarkdown(), currentEditor.state.doc.childCount > 1);
    },
    onTransaction: ({ editor: currentEditor }) => {
      setWikiLinkQueryState(wikiLinkQuery(currentEditor));
      setActiveWikiLinkSuggestion(0);
    },
    onBlur: ({ editor: currentEditor }) => {
      void handleEditorBlur(currentEditor);
    }
  });

  useEffect(() => {
    if (!editor) return;
    return observeYouTubePlayers(editor.view.dom);
  }, [editor]);

  const wikiLinkSuggestions = useMemo(
    () => wikiLinkQueryState ? matchingWikiLinkNames(wikiLinkNames, wikiLinkQueryState.value) : [],
    [wikiLinkNames, wikiLinkQueryState]
  );

  useEffect(() => {
    if (!editor?.isEditable) return;
    void fetchJson<WikiLinkSuggestionsResponse>("/api/page-names")
      .then((response) => setWikiLinkNames(response.names))
      .catch(() => setWikiLinkNames([]));
  }, [editor?.isEditable]);

  const acceptWikiLinkSuggestion = useCallback((name: string) => {
    if (!editor || !wikiLinkQueryState) return;
    editor.chain()
      .focus()
      .insertContentAt({ from: wikiLinkQueryState.from, to: wikiLinkQueryState.to }, `${name}]]`)
      .run();
    setWikiLinkQueryState(null);
  }, [editor, wikiLinkQueryState]);

  useEffect(() => {
    if (!editor || wikiLinkSuggestions.length === 0) return;
    editor.view.dom.setAttribute("aria-controls", "wiki-link-suggestions");
    editor.view.dom.setAttribute("aria-activedescendant", `wiki-link-suggestion-${activeWikiLinkSuggestion}`);
    return () => {
      editor.view.dom.removeAttribute("aria-controls");
      editor.view.dom.removeAttribute("aria-activedescendant");
    };
  }, [activeWikiLinkSuggestion, editor, wikiLinkSuggestions.length]);

  const handleWikiLinkSuggestionKeyDown = useCallback((event: ReactKeyboardEvent) => {
    if (wikiLinkSuggestions.length === 0) return;
    if (event.key === "Escape") {
      event.preventDefault();
      setWikiLinkQueryState(null);
    } else if (event.key === "Enter") {
      event.preventDefault();
      acceptWikiLinkSuggestion(wikiLinkSuggestions[activeWikiLinkSuggestion]);
    } else if (event.key === "Tab" || event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const backwards = event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey);
      setActiveWikiLinkSuggestion((current) =>
        nextWikiLinkSuggestionIndex(current, wikiLinkSuggestions.length, backwards)
      );
    }
  }, [acceptWikiLinkSuggestion, activeWikiLinkSuggestion, wikiLinkSuggestions]);

  const wikiLinkSuggestionStyle = useMemo(() => {
    if (!editor || !wikiLinkQueryState || wikiLinkSuggestions.length === 0 || !workspaceRef.current) return undefined;
    const caret = editor.view.coordsAtPos(wikiLinkQueryState.to);
    const workspace = workspaceRef.current.getBoundingClientRect();
    return {
      left: caret.left - workspace.left,
      top: caret.top - workspace.top
    } satisfies CSSProperties;
  }, [editor, wikiLinkQueryState, wikiLinkSuggestions.length]);

  const refreshPage = useCallback(async () => {
    const pageId = draftRef.current.pageId;
    if (!editor || !pageId || document.hidden || refreshingPageRef.current) return;

    refreshingPageRef.current = true;
    try {
      const result = await fetchPageIfChanged(pageId, pageEtagRef.current);
      pageEtagRef.current = result.etag;
      const page = result.page;
      if (!page) return;
      setLineUpdatedAt(page.line_updated_at || []);

      const current = draftRef.current;
      const contentChanged = page.updated_at !== current.expectedUpdatedAt;
      if (canEdit && (dirtyRef.current || savingRef.current)) {
        if (contentChanged) {
          setErrors((currentErrors) => ({
            ...currentErrors,
            form: ["ページが別の編集で更新されています"]
          }));
        }
        return;
      }

      if (contentChanged && page.body !== undefined) {
        const title = page.name || page.title || current.title;
        updateDraft({
          pageType: page.page_type,
          date: page.date || current.date,
          name: page.name || current.name,
          title,
          body: page.body,
          expectedUpdatedAt: page.updated_at || "",
          coverMode: page.cover_mode || current.coverMode,
          coverImageUrl: page.cover_image_url ?? current.coverImageUrl,
          resolvedCoverImageUrl: page.resolved_cover_image_url ?? current.resolvedCoverImageUrl
        });
        savedBodyRef.current = page.body;
        savedNameRef.current = page.name || title;
        replaceEditorContentPreservingSelection(editor, editorDocument(title, page.body));
        window.history.replaceState(null, "", `/${encodePageName(page.route || page.name || current.title)}`);
        setStatus(statusMessage(page));
      }
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
    } catch (_error) {
      // A later poll or visibility change retries transient refresh failures.
    } finally {
      refreshingPageRef.current = false;
    }
  }, [canEdit, editor, updateDraft]);

  useEffect(() => {
    if (!editor || !draftRef.current.pageId) return;

    let interval: number | null = null;
    const stop = () => {
      if (interval !== null) window.clearInterval(interval);
      interval = null;
    };
    const start = () => {
      stop();
      if (document.hidden) return;
      void refreshPage();
      interval = window.setInterval(() => void refreshPage(), PAGE_REFRESH_INTERVAL);
    };
    const handleVisibilityChange = () => start();

    document.addEventListener("visibilitychange", handleVisibilityChange);
    start();
    return () => {
      stop();
      document.removeEventListener("visibilitychange", handleVisibilityChange);
    };
  }, [editor, refreshPage]);

  const handleImageFiles = useCallback(async (files: Array<File>) => {
    if (!editor || files.length === 0 || uploadingImages) return;
    if (!draftRef.current.title.trim()) {
      const message = "先にタイトルを入力してください";
      setStatus(message);
      setImageUploadStatus(message);
      editor.commands.focus("start");
      return;
    }
    setUploadingImages(true);
    setImageUploadStatus("画像を処理中…");
    setStatus("画像を処理中…");
    try {
      for (const [index, source] of files.entries()) {
        setStatus(`画像を処理中… ${index + 1}/${files.length}`);
        setImageUploadStatus(`画像を処理中… ${index + 1}/${files.length}`);
        const { prepareImage } = await import("./imageUpload");
        const prepared = await prepareImage(source);
        setStatus(`画像をアップロード中… ${index + 1}/${files.length}`);
        setImageUploadStatus(`画像をアップロード中… ${index + 1}/${files.length}`);
        const url = await uploadImage(prepared.file);
        ensureBodySelection(editor);
        editor.chain().focus().setImage({ src: url, alt: "" }).run();
      }
      setStatus("画像を追加しました");
      setImageUploadStatus("");
    } catch (error) {
      const message = error instanceof Error ? error.message : "画像を追加できませんでした";
      setStatus(message);
      setImageUploadStatus(message);
    } finally {
      setUploadingImages(false);
    }
  }, [editor, uploadingImages]);

  const refreshInbox = useCallback(async () => {
    const result = await fetchJson<InboxResponse>("/api/inbox");
    const consumed = new Set(consumedInboxItemIdsRef.current);
    setInboxItems(result.items.filter((item) => !consumed.has(item.id)));
  }, []);

  const syncInbox = useCallback(async () => {
    if (syncingInbox) return;

    setSyncingInbox(true);
    try {
      const started = await requestJson<InboxSyncResponse>("/api/inbox/sync", {});
      let run = await fetchJson<InboxSyncStatus>(`/api/inbox/sync/${encodeURIComponent(started.run_id)}`);
      while (run.status === "queued" || run.status === "running") {
        await new Promise((resolve) => window.setTimeout(resolve, 1_000));
        run = await fetchJson<InboxSyncStatus>(`/api/inbox/sync/${encodeURIComponent(started.run_id)}`);
      }
      await refreshInbox();
      setImageUploadStatus(run.status === "completed_with_errors" ? "一部の素材を更新できませんでした" : "");
    } catch (error) {
      setImageUploadStatus(error instanceof Error ? error.message : "インボックスを更新できませんでした");
    } finally {
      setSyncingInbox(false);
    }
  }, [refreshInbox, syncingInbox]);

  useEffect(() => {
    if (!editor?.isEditable) return;
    void refreshInbox().catch((error: unknown) => {
      setImageUploadStatus(error instanceof Error ? error.message : "インボックスを読み込めませんでした");
    });
  }, [editor?.isEditable, refreshInbox]);

  const visibleInboxItems = inboxItems.filter((item) => activeMaterialTab === "photo"
    ? item.source === "photo" && item.kind === "photo"
    : item.source === "raindrop" && item.kind === "bookmark");

  const handleMaterialTabKeyDown = useCallback((event: ReactKeyboardEvent<HTMLButtonElement>) => {
    const tabs: Array<MaterialTab> = ["photo", "raindrop"];
    const current = tabs.indexOf(activeMaterialTab);
    let next = current;
    if (event.key === "ArrowDown" || event.key === "ArrowRight") next = (current + 1) % tabs.length;
    else if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = (current - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    else return;
    event.preventDefault();
    const nextTab = tabs[next];
    const tabList = event.currentTarget.parentElement;
    setActiveMaterialTab(nextTab);
    window.setTimeout(() => {
      tabList?.querySelector<HTMLButtonElement>(`[role="tab"][data-material-tab="${nextTab}"]`)
        ?.focus();
    }, 0);
  }, [activeMaterialTab]);

  const adoptInboxImage = useCallback(async (itemId: string) => {
    if (!editor || loadingInbox) return;
    setLoadingInbox(true);
    try {
      const result = await requestJson<{ public_url: string }>("/api/inbox/adopt", { item_id: itemId });
      consumedInboxItemIdsRef.current = [...consumedInboxItemIdsRef.current, itemId];
      ensureBodySelection(editor);
      editor.chain().focus().setImage({ src: result.public_url, alt: "" }).run();
      setInboxItems((items) => items.map((item) => item.id === itemId ? {
        ...item,
        used_in_pages: item.used_in_pages.some((page) => page.id === draftRef.current.pageId)
          ? item.used_in_pages
          : [...item.used_in_pages, { id: draftRef.current.pageId, route: draftRef.current.name || draftRef.current.title }]
      } : item));
      setImageUploadStatus("");
      setMaterialStatus("写真を本文へ追加しました");
    } catch (error) {
      setImageUploadStatus(error instanceof Error ? error.message : "写真を記事へ追加できませんでした");
    } finally {
      setLoadingInbox(false);
    }
  }, [editor, loadingInbox]);

  const insertInboxItem = useCallback((itemId: string) => {
    const item = inboxItems.find((candidate) => candidate.id === itemId);
    if (!item) return;
    if (item.source === "photo" && item.kind === "photo") {
      void adoptInboxImage(itemId);
      return;
    }
    const url = item.source === "raindrop" && item.kind === "bookmark" ? item.payload.url : null;
    if (!editor || typeof url !== "string") return;

    consumedInboxItemIdsRef.current = [...consumedInboxItemIdsRef.current, itemId];
    ensureBodySelection(editor);
    editor.chain().insertContent({
      type: "paragraph",
      content: [{ type: "text", text: url }]
    }).run();
    setInboxItems((items) => items.map((candidate) => candidate.id === itemId ? {
      ...candidate,
      used_in_pages: candidate.used_in_pages.some((page) => page.id === draftRef.current.pageId)
        ? candidate.used_in_pages
        : [...candidate.used_in_pages, { id: draftRef.current.pageId, route: draftRef.current.name || draftRef.current.title }]
    } : candidate));
    setImageUploadStatus("");
    setMaterialStatus("Raindropを本文へ追加しました");
  }, [adoptInboxImage, editor, inboxItems]);

  const setInboxPhotoAsCover = useCallback(async (itemId: string) => {
    if (loadingInbox) return;
    setLoadingInbox(true);
    try {
      const result = await requestJson<{ public_url: string }>("/api/inbox/adopt", { item_id: itemId });
      consumedInboxItemIdsRef.current = [...consumedInboxItemIdsRef.current, itemId];
      updateCover("explicit", result.public_url, result.public_url);
      setImageUploadStatus("");
      setMaterialStatus("写真をカバーに設定しました");
    } catch (error) {
      setImageUploadStatus(error instanceof Error ? error.message : "写真をカバーに設定できませんでした");
    } finally {
      setLoadingInbox(false);
    }
  }, [loadingInbox, updateCover]);

  const handleCoverDrop = useCallback(async (event: ReactDragEvent<HTMLDivElement>) => {
    event.preventDefault();
    const itemId = event.dataTransfer.getData(INBOX_ITEM_DRAG_TYPE);
    if (itemId) {
      const item = inboxItems.find((candidate) => candidate.id === itemId);
      if (item?.source === "photo" && item.kind === "photo") void setInboxPhotoAsCover(itemId);
      return;
    }

    const file = Array.from(event.dataTransfer.files).find((candidate) => candidate.type.startsWith("image/"));
    if (!file || uploadingImages) return;
    setUploadingImages(true);
    try {
      const { prepareImage } = await import("./imageUpload");
      const prepared = await prepareImage(file);
      const url = await uploadImage(prepared.file);
      updateCover("explicit", url, url);
      setImageUploadStatus("");
    } catch (error) {
      setImageUploadStatus(error instanceof Error ? error.message : "画像をカバーに設定できませんでした");
    } finally {
      setUploadingImages(false);
    }
  }, [inboxItems, setInboxPhotoAsCover, updateCover, uploadingImages]);

  useEffect(() => {
    if (!editor || !editor.isEditable) return;
    const element = editor.view.dom;
    const dragenter = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer)) return;
      event.preventDefault();
      imageDragDepthRef.current += 1;
      setDraggingImages(true);
    };
    const dragover = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer)) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
    };
    const dragleave = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer)) return;
      imageDragDepthRef.current = Math.max(0, imageDragDepthRef.current - 1);
      if (imageDragDepthRef.current === 0) setDraggingImages(false);
    };
    const paste = (event: ClipboardEvent) => {
      const files = Array.from(event.clipboardData?.files || []).filter((file) => file.type.startsWith("image/"));
      if (files.length === 0) return;
      event.preventDefault();
      void handleImageFiles(files);
    };
    const drop = (event: DragEvent) => {
      imageDragDepthRef.current = 0;
      setDraggingImages(false);
      const inboxItemId = event.dataTransfer?.getData(INBOX_ITEM_DRAG_TYPE);
      if (inboxItemId) {
        event.preventDefault();
        event.stopImmediatePropagation();
        const position = editor.view.posAtCoords({ left: event.clientX, top: event.clientY });
        if (position) editor.commands.setTextSelection(position.pos);
        insertInboxItem(inboxItemId);
        return;
      }
      const files = Array.from(event.dataTransfer?.files || []).filter((file) => file.type.startsWith("image/"));
      if (files.length === 0) return;
      event.preventDefault();
      const position = editor.view.posAtCoords({ left: event.clientX, top: event.clientY });
      if (position) editor.commands.setTextSelection(position.pos);
      void handleImageFiles(files);
    };
    element.addEventListener("dragenter", dragenter, true);
    element.addEventListener("dragover", dragover, true);
    element.addEventListener("dragleave", dragleave, true);
    element.addEventListener("paste", paste);
    element.addEventListener("drop", drop, true);
    return () => {
      element.removeEventListener("dragenter", dragenter, true);
      element.removeEventListener("dragover", dragover, true);
      element.removeEventListener("dragleave", dragleave, true);
      element.removeEventListener("paste", paste);
      element.removeEventListener("drop", drop, true);
    };
  }, [editor, handleImageFiles, insertInboxItem]);

  useEffect(() => {
    if (!editor || initialFocusAppliedRef.current) return;

    const search = new URLSearchParams(window.location.search);
    const isDailyEditor = search.get("new") === "daily" || search.get("template") === "daily";
    const isNewEditor = search.get("new") === "1" || window.location.pathname === "/editor/new";
    if (!isDailyEditor && !isNewEditor) return;

    initialFocusAppliedRef.current = true;
    if (!isDailyEditor) {
      editor.commands.focus("start");
      return;
    }

    const title = editor.state.doc.firstChild;
    if (!title) {
      editor.commands.focus("start");
      return;
    }

    const bodyStart = title.nodeSize;
    const transaction = editor.state.tr.insert(bodyStart, editor.schema.nodes.paragraph.create());
    transaction.setSelection(TextSelection.create(transaction.doc, bodyStart + 1));
    transaction.setMeta("preventUpdate", true);
    editor.view.dispatch(transaction);
    editor.view.focus();
  }, [editor]);

  useEffect(() => {
    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!canEdit) return;
      if (!dirtyRef.current && !savingRef.current) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => {
      window.removeEventListener("beforeunload", handleBeforeUnload);
      if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    };
  }, [canEdit]);

  const editorErrors = [
    ...(errors.title || []),
    ...(errors.body || []),
    ...(errors.form || [])
  ];
  const universeEnabled = useUniverseEnabled();
  const linkedPageGroups = useMemo(() => groupLinkedPages(linkedPages), [linkedPages]);
  const references = useMemo(() => universeReferences(draft.body), [draft.body]);
  const internalUniverseGroups = useMemo(
    () => buildInternalUniverseGroupsFromNames(
      references.wikiLinkNames,
      draft.name || draft.title,
      linkedPageGroups
    ),
    [references.wikiLinkKey, draft.name, draft.title, linkedPageGroups]
  );
  const externalUniverseGroups = useMemo(() =>
    references.externalUrls.map((url) => linkedPageGroups.find((group) => group.kind === "url" && group.name === url) || {
      kind: "url" as const,
      name: url,
      pages: [],
      isTopicOnly: false
    }), [references.externalUrlKey, linkedPageGroups]);
  const universeGroups = useMemo(
    () => [...internalUniverseGroups, ...externalUniverseGroups],
    [externalUniverseGroups, internalUniverseGroups]
  );
  const universeTopics = useMemo(
    () => universeGroups.map(({ kind, name }) => ({ kind, name })),
    [universeGroups]
  );
  const visibleLineUpdates = useMemo(
    () => pendingLineUpdates(savedBodyRef.current, draft.body, lineUpdatedAt),
    [draft.body, lineUpdatedAt]
  );

  return (
    <>
      <p className="visually-hidden" role="status" aria-live="polite" aria-busy={saving}>
        {status}
      </p>
      <p className="visually-hidden" role="status" aria-live="polite">
        {materialStatus}
      </p>
      <div className={`article-workspace${canEdit ? "" : " article-workspace--reading"}`} ref={workspaceRef}>
        {canEdit && (
          <div
            className={`article-editing-cover${draft.resolvedCoverImageUrl ? "" : " article-editing-cover--empty"}`}
            onDragOver={(event) => {
              if (isImageDrag(event.dataTransfer)) event.preventDefault();
            }}
            onDrop={(event) => void handleCoverDrop(event)}
          >
            {draft.resolvedCoverImageUrl
              ? <img src={draft.resolvedCoverImageUrl} alt="" />
              : <span className="article-editing-cover__prompt">画像をドロップしてカバーに設定</span>}
            <fieldset className="article-editing-cover__actions" role="radiogroup" aria-label="カバーモード">
              <legend className="visually-hidden">カバーモード</legend>
              <label>
                <input
                  type="radio"
                  name="cover-mode"
                  value="auto"
                  checked={draft.coverMode === "auto"}
                  onChange={() => updateCover("auto", null, autoCoverImageUrl(draft.body))}
                />
                自動
              </label>
              <label>
                <input
                  type="radio"
                  name="cover-mode"
                  value="explicit"
                  checked={draft.coverMode === "explicit"}
                  disabled={!draft.coverImageUrl}
                  onChange={() => updateCover("explicit", draft.coverImageUrl, draft.coverImageUrl)}
                />
                指定画像
              </label>
              <label>
                <input
                  type="radio"
                  name="cover-mode"
                  value="none"
                  checked={draft.coverMode === "none"}
                  onChange={() => updateCover("none", null, null)}
                />
                なし
              </label>
            </fieldset>
          </div>
        )}
        {!canEdit && (
          <header className={`article-reading-header${bootstrap.resolved_cover_image_url ? " article-reading-header--covered" : ""}`}>
            {bootstrap.resolved_cover_image_url && (
              <img src={bootstrap.resolved_cover_image_url} alt="" />
            )}
            <h1>{draft.title}</h1>
          </header>
        )}
        {wikiLinkSuggestionStyle && (
          <div
            className="wiki-link-suggestions"
            id="wiki-link-suggestions"
            role="listbox"
            aria-label="Wikiリンク候補"
            style={wikiLinkSuggestionStyle}
          >
            {wikiLinkSuggestions.map((name, index) => (
              <button
                className="wiki-link-suggestions__option"
                id={`wiki-link-suggestion-${index}`}
                type="button"
                role="option"
                tabIndex={-1}
                aria-selected={index === activeWikiLinkSuggestion}
                key={name}
                onMouseDown={(event) => event.preventDefault()}
                onClick={() => acceptWikiLinkSuggestion(name)}
              >
                {name}
              </button>
            ))}
          </div>
        )}
        <div className="editor-canvas">
          <section
            className="editor-shell"
            data-universe-obstacle
            aria-label="記事を編集"
            onClick={(event) => {
              if (!editor || editor.view.dom.contains(event.target as Node)) return;
              editor.commands.focus("end");
            }}
          >
            <LineUpdateRail body={draft.body} editor={editor} updates={visibleLineUpdates} />
            {draggingImages && (
              <div className="editor-shell__drop-target" role="status">
                ここにドロップして記事へ追加
              </div>
            )}
            {editor?.isEditable && imageUploadStatus && (
              <div className="editor-shell__actions" onClick={(event) => event.stopPropagation()}>
                <span className="editor-shell__upload-status" role="status">{imageUploadStatus}</span>
              </div>
            )}
            <div
              className="wysiwyg-editor"
              aria-busy={saving}
              onKeyDownCapture={handleWikiLinkSuggestionKeyDown}
            >
              <EditorContent editor={editor} ref={handleEditorContentRef} />
            </div>
            {editorErrors.length > 0 && (
              <p className="input-error" role="alert">{editorErrors.join(" ")}</p>
            )}
          </section>
        </div>
        {editor?.isEditable && materialSheetViewport && !materialSheetOpen && (
          <button
            ref={materialSheetButtonRef}
            className="content-inbox__open"
            type="button"
            aria-haspopup="dialog"
            onClick={() => setMaterialSheetOpen(true)}
          >
            素材
          </button>
        )}
        {editor?.isEditable && materialSheetViewport && materialSheetOpen && (
          <div className="content-inbox__backdrop" onPointerDown={closeMaterialSheet} />
        )}
        {editor?.isEditable && (!materialSheetViewport || materialSheetOpen) && (
          <aside
            ref={materialDrawerRef}
            className={`content-inbox-drawer${materialSheetViewport ? " content-inbox-drawer--sheet" : ""}`}
            aria-label="素材"
            role={materialSheetViewport ? "dialog" : undefined}
            aria-modal={materialSheetViewport ? "true" : undefined}
          >
            <section id="content-inbox-panel" className="content-inbox">
              <div className="content-inbox__toolbar">
                <strong>{activeMaterialTab === "photo" ? "写真" : "Raindrop"}</strong>
                {materialSheetViewport && (
                  <button type="button" className="content-inbox__close" onClick={closeMaterialSheet}>閉じる</button>
                )}
                <button
                  type="button"
                  className="content-inbox__sync"
                  aria-label="素材を更新"
                  title="素材を更新"
                  disabled={syncingInbox}
                  onClick={() => void syncInbox()}
                >
                  <svg aria-hidden="true" viewBox="0 0 24 24">
                    <path d="M20 7v5h-5M4 17v-5h5M18.5 9A7 7 0 0 0 6 7M5.5 15A7 7 0 0 0 18 17" />
                  </svg>
                </button>
              </div>
              {visibleInboxItems.length === 0 ? (
                <p className="content-inbox__empty">素材はありません</p>
              ) : (
                <ol className={`content-inbox__items content-inbox__items--${activeMaterialTab}`}>
                  {visibleInboxItems.map((item) => {
                    const photoUrl = inboxPhotoUrl(item);
                    return (
                      <li key={item.id}>
                        <button
                          type="button"
                          className="content-inbox__item"
                          disabled={loadingInbox || (photoUrl === null && item.source !== "raindrop")}
                          draggable={photoUrl !== null || item.source === "raindrop"}
                          onDragStart={(event) => {
                            event.dataTransfer.setData(INBOX_ITEM_DRAG_TYPE, item.id);
                            event.dataTransfer.effectAllowed = "copy";
                          }}
                          aria-label={`${inboxItemName(item)}を本文へ追加`}
                          onClick={() => insertInboxItem(item.id)}
                        >
                          {photoUrl && <img src={photoUrl} alt="" loading="lazy" />}
                          {activeMaterialTab === "raindrop" && <span className="content-inbox__kind">{inboxItemLabel(item)}</span>}
                          {item.used_in_pages.map((page) => (
                            <span className="content-inbox__usage" key={page.id}>{page.route}で使用済み</span>
                          ))}
                          {activeMaterialTab === "raindrop" && (
                            <time dateTime={item.occurred_at}>
                              {new Date(item.occurred_at).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" })}
                            </time>
                          )}
                        </button>
                        {photoUrl && (
                          <button
                            type="button"
                            className="content-inbox__cover-action"
                            aria-label={`${inboxItemName(item)}をカバーに設定`}
                            disabled={loadingInbox}
                            onClick={() => void setInboxPhotoAsCover(item.id)}
                          >
                            カバー
                          </button>
                        )}
                      </li>
                    );
                  })}
                </ol>
              )}
            </section>
            <div className="content-inbox__tabs" role="tablist" aria-label="素材の種類">
              <button
                type="button"
                role="tab"
                data-material-tab="photo"
                tabIndex={activeMaterialTab === "photo" ? 0 : -1}
                aria-selected={activeMaterialTab === "photo"}
                aria-controls="content-inbox-panel"
                aria-label="写真"
                title="写真"
                onClick={() => setActiveMaterialTab("photo")}
                onKeyDown={handleMaterialTabKeyDown}
              >
                <PhotoMaterialIcon />
              </button>
              <button
                type="button"
                role="tab"
                data-material-tab="raindrop"
                tabIndex={activeMaterialTab === "raindrop" ? 0 : -1}
                aria-selected={activeMaterialTab === "raindrop"}
                aria-controls="content-inbox-panel"
                aria-label="Raindrop"
                title="Raindrop"
                onClick={() => setActiveMaterialTab("raindrop")}
                onKeyDown={handleMaterialTabKeyDown}
              >
                <span className="content-inbox__raindrop-icon" aria-hidden="true" />
              </button>
            </div>
          </aside>
        )}
        {universeEnabled && universeGroups.length > 0 && (
          <InternalUniverseGraph
            groups={universeGroups}
            onActiveTopicChange={setActiveUniverseTopic}
          />
        )}
        {linkedPageGroups.length > 0 && (
          <section className="linked-pages" data-universe-obstacle aria-labelledby="related-pages-heading">
          <h2 id="related-pages-heading">関連する記事</h2>
          <div className="linked-page-groups">
            {linkedPageGroups.map((group) => (
              <section
                className="linked-page-group"
                key={group.name}
                aria-label={group.isTopicOnly ? `${group.name}へのリンク` : undefined}
                aria-labelledby={group.isTopicOnly ? undefined : `related-${encodePageName(group.name)}`}
              >
                {!group.isTopicOnly && (
                  <h3 id={`related-${encodePageName(group.name)}`}>
                    <a
                      href={group.kind === "wiki" ? `/${encodePageName(group.name)}` : group.name}
                      target={group.kind === "url" ? "_blank" : undefined}
                      rel={group.kind === "url" ? "noreferrer" : undefined}
                    >
                      {group.kind === "url" ? externalLinkLabel(group.name) : group.name}
                    </a>
                  </h3>
                )}
                <ul className="page-card-list" aria-label={group.isTopicOnly ? `${group.name}へのリンク` : undefined}>
                  {group.pages.map((page) => (
                    <li className="page-card" key={page.id}>
                      <a className="page-card__link" href={`/${encodePageName(page.route)}`}>
                        {page.image_url && (
                          <img
                            className="page-card__image"
                            src={page.image_url}
                            alt=""
                            loading="lazy"
                            referrerPolicy="no-referrer"
                          />
                        )}
                        <span className="page-card__title">{page.title}</span>
                        {page.excerpt && <span className="page-card__excerpt">{page.excerpt}</span>}
                      </a>
                    </li>
                  ))}
                </ul>
              </section>
            ))}
          </div>
          {(linkedPagesHasMore || loadingLinkedPages || linkedPagesError) && (
            <div className="linked-pages__more" ref={linkedPagesSentinelRef}>
              {linkedPagesHasMore && (
                <button type="button" onClick={() => void loadMoreLinkedPages()} disabled={loadingLinkedPages}>
                  {loadingLinkedPages ? "読み込んでいます" : "続きを読む"}
                </button>
              )}
              {linkedPagesError && <p role="alert">{linkedPagesError}</p>}
            </div>
          )}
          <p className="visually-hidden" role="status" aria-live="polite">
            {loadingLinkedPages ? "関連する記事を読み込んでいます" : ""}
          </p>
          </section>
        )}
        <Universe
          urls={[]}
          topics={universeTopics}
          activeTopic={activeUniverseTopic}
          editor={editor}
          editorContentReady={editorContentReady}
          enabled={universeEnabled}
          workspaceRef={workspaceRef}
        />
      </div>
    </>
  );
}
