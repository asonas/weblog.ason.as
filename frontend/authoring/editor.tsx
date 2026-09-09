import { type Editor, Extension, Node as TiptapNode } from "@tiptap/core";
import Image from "@tiptap/extension-image";
import { Markdown } from "@tiptap/markdown";
import type { NodeType } from "@tiptap/pm/model";
import {
  type EditorState,
  NodeSelection,
  Plugin,
  TextSelection,
} from "@tiptap/pm/state";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import {
  type CSSProperties,
  type DragEvent as ReactDragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";
import { markdownForEditor, markdownForSource } from "./markdown";
import { AUTHORING_TELEMETRY_FLUSH_EVENT } from "./performanceTelemetry";
import { SpeakerDeckPlayer } from "./speakerDeck";
import { UniverseGraph } from "./UniverseGraph";
import { Video } from "./Video";
import { createVideoUploadCard, VideoUploadCards } from "./VideoUploadCard";

declare global {
  interface Window {
    YT?: {
      Player: new (
        element: HTMLIFrameElement,
        options: {
          events: { onError: () => void };
        },
      ) => unknown;
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
    if (
      !document.querySelector(
        'script[src="https://www.youtube.com/iframe_api"]',
      )
    ) {
      const script = document.createElement("script");
      script.src = "https://www.youtube.com/iframe_api";
      script.async = true;
      document.head.append(script);
    }
  });
  return youtubeApiPromise;
}

export function showYouTubeFallback(iframe: HTMLIFrameElement): void {
  iframe
    .closest<HTMLElement>(".youtube-player")
    ?.classList.add("youtube-player--fallback");
}

export function applyYouTubeThumbnailFallback(image: HTMLImageElement): void {
  const fallback = image.dataset.youtubeThumbnailFallback;
  if (!fallback || image.src === fallback) return;
  delete image.dataset.youtubeThumbnailFallback;
  image.src = fallback;
}

function observeYouTubePlayers(root: HTMLElement): () => void {
  const fallbackThumbnail = (event: Event) => {
    if (event.target instanceof HTMLImageElement)
      applyYouTubeThumbnailFallback(event.target);
  };
  const register = () => {
    const iframes = Array.from(
      root.querySelectorAll<HTMLIFrameElement>(
        "iframe[data-youtube-player-frame]",
      ),
    ).filter((iframe) => iframe.dataset.youtubePlayerObserved !== "true");
    if (iframes.length === 0) return;
    for (const iframe of iframes) iframe.dataset.youtubePlayerObserved = "true";
    void loadYouTubeApi().then(({ Player }) => {
      for (const iframe of iframes) {
        if (!iframe.isConnected) continue;
        new Player(iframe, {
          events: { onError: () => showYouTubeFallback(iframe) },
        });
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

type ExternalMention = {
  id: string;
  source_url: string;
  title: string | null;
  site_name: string | null;
  first_verified_at: string | null;
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
  external_mentions?: Array<ExternalMention>;
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

  const text = selection.$from.parent.textBetween(
    0,
    selection.$from.parentOffset,
    "\n",
    "\0",
  );
  const match = /\[\[([^[\]\n]*)$/.exec(text);
  if (!match) return null;

  const textAfterCursor = selection.$from.parent.textBetween(
    selection.$from.parentOffset,
    selection.$from.parent.content.size,
    "\n",
    "\0",
  );
  const linkRemainder = /^[^[\]\n]*\]\]/.exec(textAfterCursor)?.[0] || "";

  return {
    from: selection.from - match[1].length,
    to: selection.from + linkRemainder.length,
    value: match[1],
  };
}

export function matchingWikiLinkNames(
  names: Array<string>,
  query: string,
): Array<string> {
  return names.filter((name) => name.startsWith(query)).slice(0, 7);
}

export function nextWikiLinkSuggestionIndex(
  current: number,
  length: number,
  backwards: boolean,
): number {
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
  status:
    | "queued"
    | "running"
    | "succeeded"
    | "completed_with_errors"
    | "failed";
};
type MaterialTab = "photo" | "bluesky" | "raindrop";

type ApiError = Error & {
  fields?: Record<string, string[]>;
};

type JsonObject = Record<string, unknown>;
type HttpMethod = "POST" | "PATCH";
type ImageDragData = {
  items?: ArrayLike<{ kind: string; type: string }>;
  types?: ArrayLike<string>;
};

const INBOX_ITEM_DRAG_TYPE = "application/x-weblog-inbox-item-id";
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

export function pendingLineUpdates(
  savedBody: string,
  draftBody: string,
  updates: Array<string | null>,
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

function LineUpdateRail({
  body,
  editor,
  updates,
}: {
  body: string;
  editor: Editor | null;
  updates: Array<string | null>;
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
        1,
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
  }, [body, editor, updates]);

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

export function isImageDrag(dataTransfer: ImageDragData | null): boolean {
  if (!dataTransfer) return false;
  if (
    Array.from(dataTransfer.items || []).some(
      (item) => item.kind === "file" && item.type.startsWith("image/"),
    )
  ) {
    return true;
  }
  return Array.from(dataTransfer.types || []).includes(INBOX_ITEM_DRAG_TYPE);
}

function inboxPhotoUrl(item: InboxItem): string | null {
  const url = item.payload.preview_url;
  return item.source === "photo" &&
    item.kind === "photo" &&
    typeof url === "string"
    ? url
    : null;
}

export function autoCoverImageUrl(body: string): string | null {
  return (
    /!\[[^\]]*\]\((\/assets\/[^\s)]+)(?:\s+[^)]*)?\)/.exec(body)?.[1] || null
  );
}

function inboxItemLabel(item: InboxItem): string {
  if (item.source === "photo") return "写真";
  if (item.source === "bluesky" && item.kind === "like")
    return "Bluesky いいね";
  if (item.source === "bluesky") return "Bluesky 投稿";
  if (item.source === "raindrop") return "Raindrop";
  return "c4p";
}

function inboxItemName(item: InboxItem): string {
  if (item.source === "bluesky") return inboxItemLabel(item);
  if (item.source === "raindrop" && item.kind === "bookmark") {
    if (typeof item.payload.title === "string" && item.payload.title.trim())
      return item.payload.title.trim();
    return typeof item.payload.url === "string"
      ? item.payload.url
      : "Raindrop素材";
  }
  return new Date(item.occurred_at).toLocaleString("ja-JP");
}

function inboxPayloadString(item: InboxItem, key: string): string | null {
  const value = item.payload[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function inboxItemThumbnail(item: InboxItem): string | null {
  if (item.source === "raindrop") return inboxPayloadString(item, "cover");
  if (item.source === "bluesky")
    return inboxPayloadString(item, "thumbnail_url");
  return null;
}

function inboxItemTitle(item: InboxItem): string | null {
  if (item.source === "raindrop") return inboxPayloadString(item, "title");
  if (item.source === "bluesky" && item.kind === "like") {
    return (
      inboxPayloadString(item, "author_display_name") ||
      inboxPayloadString(item, "author_handle")
    );
  }
  return null;
}

function inboxItemExcerpt(item: InboxItem): string | null {
  if (item.source === "raindrop") return inboxPayloadString(item, "excerpt");
  if (item.source === "bluesky") return inboxPayloadString(item, "text");
  return null;
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
  const grouped = new Map<
    string,
    { kind: "wiki" | "url"; name: string; pages: Array<LinkedPage> }
  >();

  for (const page of pages) {
    for (const relation of page.related_by || []) {
      const key = `wiki:${relation}`;
      const group = grouped.get(key) || {
        kind: "wiki" as const,
        name: relation,
        pages: [],
      };
      group.pages.push(page);
      grouped.set(key, group);
    }
    for (const url of page.related_urls || []) {
      const key = `url:${url}`;
      const group = grouped.get(key) || {
        kind: "url" as const,
        name: url,
        pages: [],
      };
      group.pages.push(page);
      grouped.set(key, group);
    }
  }

  return Array.from(grouped.values(), ({ kind, name, pages: relatedPages }) => {
    const topicPage =
      kind === "wiki"
        ? relatedPages.find((page) => page.route === name)
        : undefined;
    const isTopicOnly =
      kind === "wiki" && name === "日記" && topicPage !== undefined;
    return {
      kind,
      name,
      pages: isTopicOnly ? [topicPage] : relatedPages,
      isTopicOnly,
    };
  });
}

export function extractEmbeddableUrls(body: string): Array<string> {
  let fence: { marker: string; length: number } | null = null;
  const visibleLines = body
    .split("\n")
    .filter((line) => {
      const match = /^\s*(`{3,}|~{3,})/.exec(line);
      const wasFenced = fence !== null;
      if (match) {
        const marker = match[1][0];
        if (!fence) fence = { marker, length: match[1].length };
        else if (marker === fence.marker && match[1].length >= fence.length)
          fence = null;
      }
      return !wasFenced && !match;
    })
    .map((line) => line.replace(/(`+).*?\1/g, ""));
  const matches =
    visibleLines.join("\n").match(/https?:\/\/[^\s<>[\]\\"')]+/g) || [];
  const normalized = matches.map((url) =>
    url.replace(/\\(?=[^\w\s]|_)/g, "").replace(/[.,;:!?]+$/, ""),
  );
  return Array.from(new Set(normalized)).filter(
    (url) => !/\.(?:avif|gif|jpe?g|png|webp)(?:[?#]|$)/i.test(url),
  );
}

function extractWikiLinkNames(body: string): Array<string> {
  return Array.from(body.matchAll(WIKI_LINK_PATTERN), (match) =>
    match[1].trim(),
  ).filter((name, index, names) => name && names.indexOf(name) === index);
}

export function universeReferences(body: string) {
  const wikiLinkNames = extractWikiLinkNames(body);
  const externalUrls = extractEmbeddableUrls(body);
  return {
    wikiLinkNames,
    externalUrls,
    wikiLinkKey: JSON.stringify(wikiLinkNames),
    externalUrlKey: JSON.stringify(externalUrls),
  };
}

const EMPTY_UNIVERSE_REFERENCES = {
  wikiLinkNames: [] as Array<string>,
  externalUrls: [] as Array<string>,
  wikiLinkKey: "[]",
  externalUrlKey: "[]",
};

function useUniverseReferences(body: string, enabled: boolean) {
  const [references, setReferences] = useState(() =>
    enabled ? universeReferences(body) : EMPTY_UNIVERSE_REFERENCES,
  );

  useEffect(() => {
    if (!enabled) {
      setReferences(EMPTY_UNIVERSE_REFERENCES);
      return;
    }
    const timer = window.setTimeout(() => {
      const next = universeReferences(body);
      setReferences((current) =>
        current.wikiLinkKey === next.wikiLinkKey &&
        current.externalUrlKey === next.externalUrlKey
          ? current
          : next,
      );
    }, 1000);
    return () => window.clearTimeout(timer);
  }, [body, enabled]);

  return references;
}

function buildInternalUniverseGroupsFromNames(
  wikiLinkNames: Array<string>,
  route: string,
  linkedPageGroups: Array<LinkedPageGroup>,
): Array<LinkedPageGroup> {
  const names = wikiLinkNames.filter((name) => name !== route);
  if (
    linkedPageGroups.some(
      (group) => group.kind === "wiki" && group.name === route,
    )
  ) {
    names.unshift(route);
  }

  return names.map((name) => {
    const group = linkedPageGroups.find(
      (candidate) => candidate.kind === "wiki" && candidate.name === name,
    );
    return group
      ? {
          ...group,
          pages: group.pages.filter((page) => page.route !== name),
        }
      : {
          kind: "wiki" as const,
          name,
          pages: [],
          isTopicOnly: false,
        };
  });
}

export function buildInternalUniverseGroups(
  body: string,
  route: string,
  linkedPageGroups: Array<LinkedPageGroup>,
): Array<LinkedPageGroup> {
  return buildInternalUniverseGroupsFromNames(
    extractWikiLinkNames(body),
    route,
    linkedPageGroups,
  );
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

export function blueskyPostIdentity(
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

export function embedImageUrl(
  url: string,
  metadata?: EmbedMetadata,
): string | null {
  if (metadata?.image_url) return metadata.image_url;
  const videoId = youtubeVideoId(url);
  return videoId ? `https://i.ytimg.com/vi/${videoId}/maxresdefault.jpg` : null;
}

function useUniverseEnabled(): boolean {
  const [enabled, setEnabled] = useState(
    document.documentElement.dataset.universe === "on",
  );

  useEffect(() => {
    const update = () =>
      setEnabled(document.documentElement.dataset.universe === "on");
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-universe"],
    });
    update();
    return () => observer.disconnect();
  }, []);

  return enabled;
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
        target: "_self",
      },
    },
  }),
  WikiLinks,
  Image.configure({ allowBase64: false }),
  Video,
  VideoUploadCards,
  YouTubePlayer,
  BlueskyPlayer,
  SpeakerDeckPlayer,
  Markdown.configure({ indentation: { style: "space", size: 2 } }),
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
    expectedUpdatedAt: bootstrap.expected_updated_at,
  };
}

export function editorDocumentTitle(
  title: string,
  environment?: string,
): string {
  const pageTitle = title ? `${title} : weblog.ason.as` : "weblog.ason.as";
  return environment === "development" ? `[dev] ${pageTitle}` : pageTitle;
}

function editorDocument(title: string, body: string): string {
  return [title, markdownForEditor(body)]
    .filter((part) => part.length > 0)
    .join("\n\n");
}

export function replaceEditorContentPreservingSelection(
  editor: Editor,
  content: string,
): void {
  const { anchor, head } = editor.state.selection;
  editor.commands.setContent(content, {
    contentType: "markdown",
    emitUpdate: false,
  });

  const resolvePosition = (position: number) =>
    editor.state.doc.resolve(Math.min(position, editor.state.doc.content.size));
  const transaction = editor.state.tr.setSelection(
    TextSelection.between(resolvePosition(anchor), resolvePosition(head)),
  );
  editor.view.dispatch(transaction);
}

function splitEditorDocument(
  markdown: string,
): Pick<EditorDraft, "title" | "body"> {
  const [title = "", ...bodyLines] = markdownForSource(markdown).split("\n");
  return {
    title: title.trim(),
    body: bodyLines.join("\n").replace(/^\n+/, ""),
  };
}

export function ensureBodySelection(editor: Editor): void {
  const title = editor.state.doc.firstChild;
  if (!title || editor.state.selection.from > title.nodeSize) return;

  const bodyStart = title.nodeSize;
  const transaction = editor.state.tr.insert(
    bodyStart,
    editor.schema.nodes.paragraph.create(),
  );
  transaction.setSelection(
    TextSelection.create(transaction.doc, bodyStart + 1),
  );
  editor.view.dispatch(transaction);
}

export function insertPastedJapaneseUrl(editor: Editor, text: string): boolean {
  const pastedText = text.trim();
  if (pastedText !== text || /\s/.test(pastedText)) return false;

  let url: URL;
  let label: string;
  try {
    url = new URL(pastedText);
    if (url.protocol !== "http:" && url.protocol !== "https:") return false;
    label = decodeURI(url.href);
  } catch (_error) {
    return false;
  }
  const hasNonAsciiCharacter = Array.from(label).some(
    (character) => (character.codePointAt(0) || 0) > 0x7f,
  );
  if (label === url.href || !hasNonAsciiCharacter) return false;

  editor
    .chain()
    .insertContent({
      type: "text",
      text: label,
      marks: [{ type: "link", attrs: { href: url.href } }],
    })
    .run();
  return true;
}

async function requestJson<T>(
  url: string,
  payload: JsonObject,
  method: HttpMethod = "POST",
): Promise<T> {
  const csrfToken = document.documentElement.dataset.csrfToken;
  const response = await fetch(url, {
    method,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
    },
    body: JSON.stringify(payload),
  });

  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    const error = new Error(
      typeof result.error === "string"
        ? result.error
        : "操作を完了できませんでした",
    ) as ApiError;
    if (isJsonObject(result.errors)) {
      error.fields = result.errors as Record<string, string[]>;
    }
    throw error;
  }

  return raw as T;
}

async function fetchJson<T>(url: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(url, {
    ...init,
    headers: { Accept: "application/json" },
  });
  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    throw new Error(
      typeof result.error === "string"
        ? result.error
        : "操作を完了できませんでした",
    );
  }

  return raw as T;
}

async function fetchPageIfChanged(
  pageId: string,
  etag: string | null,
): Promise<{ page: PageResponse | null; etag: string | null }> {
  const response = await fetch(`/api/pages/${encodeURIComponent(pageId)}`, {
    headers: {
      Accept: "application/json",
      ...(etag ? { "If-None-Match": etag } : {}),
    },
  });
  if (response.status === 304) return { page: null, etag };

  const page = (await response.json()) as PageResponse;
  if (!response.ok) throw new Error("ページを同期できませんでした");

  return { page, etag: response.headers.get("etag") };
}

async function uploadImage(file: File, inboxDate?: string): Promise<string> {
  const upload = await requestJson<UploadResponse>("/api/uploads", {
    content_type: file.type,
    size: file.size,
    ...(inboxDate ? { inbox_date: inboxDate } : {}),
  });
  const form = new FormData();
  for (const [key, value] of Object.entries(upload.fields))
    form.append(key, value);
  form.append("file", file);
  const response = await fetch(upload.upload_url, {
    method: "POST",
    body: form,
  });
  if (!response.ok) throw new Error("画像をS3へ送信できませんでした");
  return upload.public_url;
}

function statusMessage(page: PageResponse): string {
  return page.updated_at ? `保存済み・最終更新 ${page.updated_at}` : "保存済み";
}

export function AuthoringEditor({
  bootstrap,
  canEdit = document.documentElement.dataset.canEdit === "true",
  canSwitchToEdit = false,
  editingHref,
  readingHref,
}: {
  bootstrap: EditorBootstrap;
  canEdit?: boolean;
  canSwitchToEdit?: boolean;
  editingHref?: string;
  readingHref?: string;
}) {
  const [draft, setDraft] = useState<EditorDraft>(() =>
    initialDraft(bootstrap),
  );
  const [status, setStatus] = useState(bootstrap.save_message);
  const [lineUpdatedAt, setLineUpdatedAt] = useState(
    bootstrap.line_updated_at || [],
  );
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);
  const [uploadingImages, setUploadingImages] = useState(false);
  const videoAbortRef = useRef<AbortController | null>(null);
  useEffect(() => () => videoAbortRef.current?.abort(), []);
  const [draggingImages, setDraggingImages] = useState(false);
  const [imageUploadStatus, setImageUploadStatus] = useState("");
  const [materialStatus, setMaterialStatus] = useState("");
  const [inboxItems, setInboxItems] = useState<Array<InboxItem>>([]);
  const [activeMaterialTab, setActiveMaterialTab] =
    useState<MaterialTab>("photo");
  const [loadingInbox, setLoadingInbox] = useState(false);
  const [syncingInbox, setSyncingInbox] = useState(false);
  const [linkedPages, setLinkedPages] = useState(bootstrap.linked_pages || []);
  const [linkedPagesHasMore, setLinkedPagesHasMore] = useState(
    bootstrap.linked_pages_has_more || false,
  );
  const [loadingLinkedPages, setLoadingLinkedPages] = useState(false);
  const [linkedPagesError, setLinkedPagesError] = useState("");
  const [wikiLinkNames, setWikiLinkNames] = useState<Array<string>>([]);
  const [wikiLinkQueryState, setWikiLinkQueryState] =
    useState<WikiLinkQuery | null>(null);
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
  const pageWasHiddenRef = useRef(document.hidden);
  const imageDragDepthRef = useRef(0);
  const consumedInboxItemIdsRef = useRef<Array<string>>([]);

  useEffect(() => {
    document.title = editorDocumentTitle(
      draft.title,
      document.documentElement.dataset.environment,
    );
  }, [draft.title]);
  useEffect(() => {
    document.documentElement.dataset.view = canEdit
      ? "article-editing"
      : "reading";
    return () => {
      delete document.documentElement.dataset.view;
    };
  }, [canEdit]);
  const initialFocusAppliedRef = useRef(false);
  const workspaceRef = useRef<HTMLDivElement | null>(null);
  const isUnpersistedRouteRef = useRef(
    !bootstrap.page_id &&
      bootstrap.title.length > 0 &&
      window.location.pathname !== "/" &&
      window.location.pathname !== "/editor/new",
  );

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
    const saveStartedAt = performance.now();
    setDraft(snapshot);
    setErrors({});
    savingRef.current = true;
    setSaving(true);
    setStatus("保存中…");

    try {
      const endpoint = snapshot.pageId
        ? `/api/authoring/pages/${encodeURIComponent(snapshot.pageId)}`
        : "/api/authoring/pages";
      const page = await requestJson<PageResponse>(
        endpoint,
        {
          page_id: snapshot.pageId,
          page_type: snapshot.pageType,
          date: snapshot.date,
          name: snapshot.name || undefined,
          title: snapshot.title || undefined,
          body: snapshot.body,
          cover_mode: snapshot.coverMode,
          cover_image_url: snapshot.coverImageUrl,
          expected_updated_at: snapshot.expectedUpdatedAt || undefined,
          consumed_inbox_item_ids: consumedInboxItemIds,
        },
        snapshot.pageId ? "PATCH" : "POST",
      );
      const current = draftRef.current;
      const next = {
        ...current,
        pageId: page.id,
        pageType: page.page_type,
        date: page.date || current.date,
        name: page.name || current.name,
        coverMode: page.cover_mode || current.coverMode,
        coverImageUrl: page.cover_image_url ?? current.coverImageUrl,
        resolvedCoverImageUrl:
          page.resolved_cover_image_url ?? current.resolvedCoverImageUrl,
        expectedUpdatedAt: page.updated_at || "",
      };
      draftRef.current = next;
      setDraft(next);
      savedNameRef.current = page.name || next.title;
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
      savedBodyRef.current = snapshot.body;
      setLineUpdatedAt(page.line_updated_at || []);
      if (!snapshot.pageId) {
        window.history.pushState(
          null,
          "",
          `/${encodePageName(page.route || page.name || next.title)}`,
        );
      }
      setErrors({});
      consumedInboxItemIdsRef.current = consumedInboxItemIdsRef.current.filter(
        (itemId) => !consumedInboxItemIds.includes(itemId),
      );
      setStatus(statusMessage(page));
      setDirtyState(editVersionRef.current !== savedVersion);
      if (editVersionRef.current !== savedVersion)
        pendingSaveRef.current = true;
    } catch (error) {
      const apiError = error as ApiError;
      const nextErrors = apiError.fields || { form: [apiError.message] };
      setErrors(nextErrors);
      setStatus(apiError.message);
      setDirtyState(true);
    } finally {
      window.dispatchEvent(
        new window.CustomEvent(AUTHORING_TELEMETRY_FLUSH_EVENT, {
          detail: {
            body: snapshot.body,
            saveDurationMs: performance.now() - saveStartedAt,
          },
        }),
      );
      savingRef.current = false;
      setSaving(false);
      if (pendingSaveRef.current) {
        pendingSaveRef.current = false;
        window.setTimeout(() => void savePage(), 0);
      }
    }
  }, [setDirtyState]);

  const scheduleSave = useCallback(() => {
    if (saveTimerRef.current !== null)
      window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      saveTimerRef.current = null;
      void savePage();
    }, 300);
  }, [savePage]);

  const showReadingView = useCallback(async () => {
    if (!readingHref || savingRef.current) return;
    if (dirtyRef.current) {
      await savePage();
      if (dirtyRef.current) return;
    }
    window.location.assign(readingHref);
  }, [readingHref, savePage]);

  const updateCover = useCallback(
    (
      coverMode: EditorDraft["coverMode"],
      coverImageUrl: string | null,
      resolvedCoverImageUrl: string | null,
    ) => {
      updateDraft({ coverMode, coverImageUrl, resolvedCoverImageUrl });
      editVersionRef.current += 1;
      setErrors({});
      setDirtyState(true);
      scheduleSave();
    },
    [scheduleSave, setDirtyState, updateDraft],
  );

  const handleDocumentChange = useCallback(
    (markdown: string, hasBodyBlock: boolean) => {
      if (!canEdit) return;
      const next = { ...draftRef.current, ...splitEditorDocument(markdown) };
      draftRef.current = next;
      editVersionRef.current += 1;
      setDirtyState(true);
      const isRenaming =
        next.pageId &&
        next.pageType === "named" &&
        next.title !== savedNameRef.current;
      if (isUnpersistedRouteRef.current && !next.body.trim()) return;
      if (!isRenaming && (next.pageId || (next.title && hasBodyBlock)))
        scheduleSave();
    },
    [canEdit, scheduleSave, setDirtyState],
  );

  const handleEditorBlur = useCallback(
    async (currentEditor: Editor) => {
      if (!canEdit) return;
      const current = draftRef.current;
      if (!current.pageId) {
        if (current.title.trim()) void savePage();
        return;
      }
      if (
        current.pageType !== "named" ||
        current.title === savedNameRef.current
      ) {
        if (dirtyRef.current) void savePage();
        return;
      }
      if (savingRef.current) {
        window.setTimeout(() => void handleEditorBlur(currentEditor), 50);
        return;
      }

      const previousName = savedNameRef.current;
      if (
        !current.title.trim() ||
        !window.confirm(
          `タイトルを「${previousName}」から「${current.title}」へ変更しますか？`,
        )
      ) {
        updateDraft({ title: previousName });
        currentEditor.commands.setContent(
          editorDocument(previousName, current.body),
          {
            contentType: "markdown",
            emitUpdate: false,
          },
        );
        scheduleSave();
        return;
      }

      if (saveTimerRef.current !== null) {
        window.clearTimeout(saveTimerRef.current);
        saveTimerRef.current = null;
      }
      const savedVersion = editVersionRef.current;
      setDraft(current);
      setErrors({});
      savingRef.current = true;
      setSaving(true);
      setStatus("変更中…");

      try {
        const page = await requestJson<PageResponse>("/api/rename", {
          page_id: current.pageId,
          name: current.title,
          body: current.body,
          expected_updated_at: current.expectedUpdatedAt || undefined,
        });
        const nextName = page.name || current.title;
        const next = updateDraft({
          name: nextName,
          title: nextName,
          expectedUpdatedAt: page.updated_at || "",
        });
        savedNameRef.current = nextName;
        setLinkedPages(page.linked_pages || []);
        setLinkedPagesHasMore(page.linked_pages_has_more || false);
        currentEditor.commands.setContent(editorDocument(nextName, next.body), {
          contentType: "markdown",
          emitUpdate: false,
        });
        window.history.replaceState(
          null,
          "",
          `/${encodePageName(page.route || page.name || next.title)}`,
        );
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
    },
    [canEdit, savePage, scheduleSave, setDirtyState, updateDraft],
  );

  const loadMoreLinkedPages = useCallback(async () => {
    if (!linkedPagesHasMore || loadingLinkedPagesRef.current) return;

    const route = draftRef.current.name || draftRef.current.title;
    if (!route) return;

    loadingLinkedPagesRef.current = true;
    setLoadingLinkedPages(true);
    setLinkedPagesError("");
    const query = new URLSearchParams({
      route,
      offset: String(linkedPages.length),
    });
    if (draftRef.current.pageId)
      query.set("excluding_id", draftRef.current.pageId);

    try {
      const result = await fetchJson<RelatedPagesResponse>(
        `/api/related?${query.toString()}`,
      );
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
    if (linkedPages.length === 0 && linkedPagesHasMore)
      void loadMoreLinkedPages();
  }, [linkedPages.length, linkedPagesHasMore, loadMoreLinkedPages]);

  useEffect(() => {
    const sentinel = linkedPagesSentinelRef.current;
    if (!sentinel || !linkedPagesHasMore) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting))
          void loadMoreLinkedPages();
      },
      { rootMargin: "320px 0px" },
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [linkedPagesHasMore, loadMoreLinkedPages]);

  const editor = useEditor({
    extensions: EDITOR_EXTENSIONS,
    content: editorDocument(bootstrap.title, bootstrap.body),
    contentType: "markdown",
    editable: canEdit,
    shouldRerenderOnTransaction: false,
    editorProps: {
      attributes: {
        role: "textbox",
        "aria-multiline": "true",
        "aria-label": "記事",
      },
    },
    onUpdate: ({ editor: currentEditor }) => {
      handleDocumentChange(
        currentEditor.getMarkdown(),
        currentEditor.state.doc.childCount > 1,
      );
    },
    onTransaction: ({ editor: currentEditor }) => {
      setWikiLinkQueryState(wikiLinkQuery(currentEditor));
      setActiveWikiLinkSuggestion(0);
    },
    onBlur: ({ editor: currentEditor }) => {
      void handleEditorBlur(currentEditor);
    },
  });

  useEffect(() => {
    if (!editor) return;
    return observeYouTubePlayers(editor.view.dom);
  }, [editor]);

  const wikiLinkSuggestions = useMemo(
    () =>
      wikiLinkQueryState
        ? matchingWikiLinkNames(wikiLinkNames, wikiLinkQueryState.value)
        : [],
    [wikiLinkNames, wikiLinkQueryState],
  );

  useEffect(() => {
    if (!editor?.isEditable) return;
    void fetchJson<WikiLinkSuggestionsResponse>("/api/page-names")
      .then((response) => setWikiLinkNames(response.names))
      .catch(() => setWikiLinkNames([]));
  }, [editor?.isEditable]);

  const acceptWikiLinkSuggestion = useCallback(
    (name: string) => {
      if (!editor || !wikiLinkQueryState) return;
      editor
        .chain()
        .focus()
        .insertContentAt(
          { from: wikiLinkQueryState.from, to: wikiLinkQueryState.to },
          `${name}]]`,
        )
        .run();
      setWikiLinkQueryState(null);
    },
    [editor, wikiLinkQueryState],
  );

  useEffect(() => {
    if (!editor || wikiLinkSuggestions.length === 0) return;
    editor.view.dom.setAttribute("aria-controls", "wiki-link-suggestions");
    editor.view.dom.setAttribute(
      "aria-activedescendant",
      `wiki-link-suggestion-${activeWikiLinkSuggestion}`,
    );
    return () => {
      editor.view.dom.removeAttribute("aria-controls");
      editor.view.dom.removeAttribute("aria-activedescendant");
    };
  }, [activeWikiLinkSuggestion, editor, wikiLinkSuggestions.length]);

  const handleWikiLinkSuggestionKeyDown = useCallback(
    (event: ReactKeyboardEvent) => {
      if (wikiLinkSuggestions.length === 0) return;
      if (event.key === "Escape") {
        event.preventDefault();
        setWikiLinkQueryState(null);
      } else if (event.key === "Enter") {
        event.preventDefault();
        acceptWikiLinkSuggestion(wikiLinkSuggestions[activeWikiLinkSuggestion]);
      } else if (
        event.key === "Tab" ||
        event.key === "ArrowDown" ||
        event.key === "ArrowUp"
      ) {
        event.preventDefault();
        const backwards =
          event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey);
        setActiveWikiLinkSuggestion((current) =>
          nextWikiLinkSuggestionIndex(
            current,
            wikiLinkSuggestions.length,
            backwards,
          ),
        );
      }
    },
    [acceptWikiLinkSuggestion, activeWikiLinkSuggestion, wikiLinkSuggestions],
  );

  const wikiLinkSuggestionStyle = useMemo(() => {
    if (
      !editor ||
      !wikiLinkQueryState ||
      wikiLinkSuggestions.length === 0 ||
      !workspaceRef.current
    )
      return undefined;
    const caret = editor.view.coordsAtPos(wikiLinkQueryState.to);
    const workspace = workspaceRef.current.getBoundingClientRect();
    return {
      left: caret.left - workspace.left,
      top: caret.top - workspace.top,
    } satisfies CSSProperties;
  }, [editor, wikiLinkQueryState, wikiLinkSuggestions.length]);

  const refreshPage = useCallback(async () => {
    const pageId = draftRef.current.pageId;
    if (!editor || !pageId || document.hidden || refreshingPageRef.current)
      return;

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
            form: ["ページが別の編集で更新されています"],
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
          resolvedCoverImageUrl:
            page.resolved_cover_image_url ?? current.resolvedCoverImageUrl,
        });
        savedBodyRef.current = page.body;
        savedNameRef.current = page.name || title;
        replaceEditorContentPreservingSelection(
          editor,
          editorDocument(title, page.body),
        );
        window.history.replaceState(
          null,
          "",
          `/${encodePageName(page.route || page.name || current.title)}`,
        );
        setStatus(statusMessage(page));
      }
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
    } catch (_error) {
      // A later visibility change retries transient refresh failures.
    } finally {
      refreshingPageRef.current = false;
    }
  }, [canEdit, editor, updateDraft]);

  useEffect(() => {
    if (!editor || !draftRef.current.pageId) return;

    const handleVisibilityChange = () => {
      const wasHidden = pageWasHiddenRef.current;
      pageWasHiddenRef.current = document.hidden;
      if (wasHidden && !document.hidden) void refreshPage();
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    return () =>
      document.removeEventListener("visibilitychange", handleVisibilityChange);
  }, [editor, refreshPage]);

  const handleImageFiles = useCallback(
    async (files: Array<File>) => {
      if (
        !editor ||
        files.length === 0 ||
        uploadingImages ||
        videoAbortRef.current
      )
        return;
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
          setImageUploadStatus(
            `画像をアップロード中… ${index + 1}/${files.length}`,
          );
          const url = await uploadImage(prepared.file);
          ensureBodySelection(editor);
          editor.chain().focus().setImage({ src: url, alt: "" }).run();
        }
        setStatus("画像を追加しました");
        setImageUploadStatus("");
      } catch (error) {
        const message =
          error instanceof Error ? error.message : "画像を追加できませんでした";
        setStatus(message);
        setImageUploadStatus(message);
      } finally {
        setUploadingImages(false);
      }
    },
    [editor, uploadingImages],
  );

  const handleVideoFiles = useCallback(
    async (files: File[]) => {
      if (
        !editor?.isEditable ||
        !files.length ||
        uploadingImages ||
        videoAbortRef.current
      )
        return;
      if (!draftRef.current.title.trim()) {
        setImageUploadStatus("先にタイトルを入力してください");
        editor.commands.focus("start");
        return;
      }
      const controller = new AbortController();
      videoAbortRef.current = controller;
      setImageUploadStatus("");
      ensureBodySelection(editor);
      const cards = files.map((file) => ({
        file,
        card: createVideoUploadCard(editor, file, controller.signal),
      }));
      try {
        for (const { file, card } of cards) {
          while (!card.signal.aborted) {
            try {
              card.update("動画を確認中…");
              const { prepareVideo } = await import("./videoUpload");
              const prepared = await prepareVideo(
                file,
                card.signal,
                card.update,
              );
              const urls: { avc: string; av1?: string } = { avc: "" };
              for (const codec of ["avc", "av1"] as const) {
                const output = prepared[codec];
                if (!output) continue;
                card.signal.throwIfAborted();
                card.update(
                  `動画をアップロード中… ${codec === "avc" ? "H.264" : "AV1"}`,
                );
                const upload = await requestJson<UploadResponse>(
                  "/api/uploads",
                  {
                    content_type: "video/mp4",
                    size: output.size,
                  },
                );
                card.signal.throwIfAborted();
                const form = new FormData();
                for (const [key, value] of Object.entries(upload.fields))
                  form.append(key, value);
                form.append("file", output);
                const response = await fetch(upload.upload_url, {
                  method: "POST",
                  body: form,
                  signal: card.signal,
                });
                if (!response.ok)
                  throw new Error(
                    "動画を送信できませんでした。もう一度試してください",
                  );
                urls[codec] = upload.public_url;
              }
              card.signal.throwIfAborted();
              card.complete({
                ...urls,
                width: prepared.width,
                height: prepared.height,
              });
              break;
            } catch (error) {
              if (!(await card.retry(error))) break;
            }
          }
          card.dispose();
        }
      } finally {
        for (const { card } of cards) card.dispose();
        videoAbortRef.current = null;
      }
    },
    [editor, uploadingImages],
  );

  const refreshInbox = useCallback(async () => {
    const result = await fetchJson<InboxResponse>("/api/inbox");
    const consumed = new Set(consumedInboxItemIdsRef.current);
    setInboxItems(result.items.filter((item) => !consumed.has(item.id)));
  }, []);

  const syncInbox = useCallback(async () => {
    if (syncingInbox) return;

    setSyncingInbox(true);
    try {
      if (activeMaterialTab === "photo") {
        await refreshInbox();
        return;
      }
      const started = await requestJson<InboxSyncResponse>("/api/inbox/sync", {
        sources: [activeMaterialTab],
      });
      let run = await fetchJson<InboxSyncStatus>(
        `/api/inbox/sync/${encodeURIComponent(started.run_id)}`,
      );
      while (run.status === "queued" || run.status === "running") {
        await new Promise((resolve) => window.setTimeout(resolve, 1_000));
        run = await fetchJson<InboxSyncStatus>(
          `/api/inbox/sync/${encodeURIComponent(started.run_id)}`,
        );
      }
      await refreshInbox();
      setImageUploadStatus(
        run.status === "completed_with_errors"
          ? "一部の素材を更新できませんでした"
          : "",
      );
    } catch (error) {
      setImageUploadStatus(
        error instanceof Error
          ? error.message
          : "インボックスを更新できませんでした",
      );
    } finally {
      setSyncingInbox(false);
    }
  }, [activeMaterialTab, refreshInbox, syncingInbox]);

  useEffect(() => {
    if (!editor?.isEditable) return;
    void refreshInbox().catch((error: unknown) => {
      setImageUploadStatus(
        error instanceof Error
          ? error.message
          : "インボックスを読み込めませんでした",
      );
    });
  }, [editor?.isEditable, refreshInbox]);

  const visibleInboxItems = inboxItems.filter((item) => {
    if (activeMaterialTab === "photo")
      return item.source === "photo" && item.kind === "photo";
    if (activeMaterialTab === "bluesky") return item.source === "bluesky";
    return item.source === "raindrop" && item.kind === "bookmark";
  });

  const handleMaterialTabKeyDown = useCallback(
    (event: ReactKeyboardEvent<HTMLButtonElement>) => {
      const tabs: Array<MaterialTab> = ["photo", "bluesky", "raindrop"];
      const current = tabs.indexOf(activeMaterialTab);
      let next = current;
      if (event.key === "ArrowDown" || event.key === "ArrowRight")
        next = (current + 1) % tabs.length;
      else if (event.key === "ArrowUp" || event.key === "ArrowLeft")
        next = (current - 1 + tabs.length) % tabs.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = tabs.length - 1;
      else return;
      event.preventDefault();
      const nextTab = tabs[next];
      const tabList = event.currentTarget.parentElement;
      setActiveMaterialTab(nextTab);
      window.setTimeout(() => {
        tabList
          ?.querySelector<HTMLButtonElement>(
            `[role="tab"][data-material-tab="${nextTab}"]`,
          )
          ?.focus();
      }, 0);
    },
    [activeMaterialTab],
  );

  const adoptInboxImage = useCallback(
    async (itemId: string) => {
      if (!editor || loadingInbox) return;
      setLoadingInbox(true);
      try {
        const result = await requestJson<{ public_url: string }>(
          "/api/inbox/adopt",
          { item_id: itemId },
        );
        consumedInboxItemIdsRef.current = [
          ...consumedInboxItemIdsRef.current,
          itemId,
        ];
        ensureBodySelection(editor);
        editor
          .chain()
          .focus()
          .setImage({ src: result.public_url, alt: "" })
          .run();
        setInboxItems((items) =>
          items.map((item) =>
            item.id === itemId
              ? {
                  ...item,
                  used_in_pages: item.used_in_pages.some(
                    (page) => page.id === draftRef.current.pageId,
                  )
                    ? item.used_in_pages
                    : [
                        ...item.used_in_pages,
                        {
                          id: draftRef.current.pageId,
                          route:
                            draftRef.current.name || draftRef.current.title,
                        },
                      ],
                }
              : item,
          ),
        );
        setImageUploadStatus("");
        setMaterialStatus("写真を本文へ追加しました");
      } catch (error) {
        setImageUploadStatus(
          error instanceof Error
            ? error.message
            : "写真を記事へ追加できませんでした",
        );
      } finally {
        setLoadingInbox(false);
      }
    },
    [editor, loadingInbox],
  );

  const insertInboxItem = useCallback(
    (itemId: string) => {
      const item = inboxItems.find((candidate) => candidate.id === itemId);
      if (!item) return;
      if (item.source === "photo" && item.kind === "photo") {
        void adoptInboxImage(itemId);
        return;
      }
      const url =
        item.source === "raindrop" && item.kind === "bookmark"
          ? item.payload.url
          : item.source === "bluesky"
            ? item.payload.canonical_url
            : null;
      if (!editor || typeof url !== "string") return;

      consumedInboxItemIdsRef.current = [
        ...consumedInboxItemIdsRef.current,
        itemId,
      ];
      ensureBodySelection(editor);
      editor
        .chain()
        .insertContent({
          type: "paragraph",
          content: [{ type: "text", text: url }],
        })
        .run();
      setInboxItems((items) =>
        items.map((candidate) =>
          candidate.id === itemId
            ? {
                ...candidate,
                used_in_pages: candidate.used_in_pages.some(
                  (page) => page.id === draftRef.current.pageId,
                )
                  ? candidate.used_in_pages
                  : [
                      ...candidate.used_in_pages,
                      {
                        id: draftRef.current.pageId,
                        route: draftRef.current.name || draftRef.current.title,
                      },
                    ],
              }
            : candidate,
        ),
      );
      setImageUploadStatus("");
      setMaterialStatus(
        item.source === "bluesky"
          ? `${inboxItemLabel(item)}を本文へ追加しました`
          : "Raindropを本文へ追加しました",
      );
    },
    [adoptInboxImage, editor, inboxItems],
  );

  const setInboxPhotoAsCover = useCallback(
    async (itemId: string) => {
      if (loadingInbox) return;
      setLoadingInbox(true);
      try {
        const result = await requestJson<{ public_url: string }>(
          "/api/inbox/adopt",
          { item_id: itemId },
        );
        consumedInboxItemIdsRef.current = [
          ...consumedInboxItemIdsRef.current,
          itemId,
        ];
        updateCover("explicit", result.public_url, result.public_url);
        setImageUploadStatus("");
        setMaterialStatus("写真をカバーに設定しました");
      } catch (error) {
        setImageUploadStatus(
          error instanceof Error
            ? error.message
            : "写真をカバーに設定できませんでした",
        );
      } finally {
        setLoadingInbox(false);
      }
    },
    [loadingInbox, updateCover],
  );

  const handleCoverDrop = useCallback(
    async (event: ReactDragEvent<HTMLElement>) => {
      event.preventDefault();
      const itemId = event.dataTransfer.getData(INBOX_ITEM_DRAG_TYPE);
      if (itemId) {
        const item = inboxItems.find((candidate) => candidate.id === itemId);
        if (item?.source === "photo" && item.kind === "photo")
          void setInboxPhotoAsCover(itemId);
        return;
      }

      const file = Array.from(event.dataTransfer.files).find((candidate) =>
        candidate.type.startsWith("image/"),
      );
      if (!file || uploadingImages) return;
      setUploadingImages(true);
      try {
        const { prepareImage } = await import("./imageUpload");
        const prepared = await prepareImage(file);
        const url = await uploadImage(prepared.file);
        updateCover("explicit", url, url);
        setImageUploadStatus("");
      } catch (error) {
        setImageUploadStatus(
          error instanceof Error
            ? error.message
            : "画像をカバーに設定できませんでした",
        );
      } finally {
        setUploadingImages(false);
      }
    },
    [inboxItems, setInboxPhotoAsCover, updateCover, uploadingImages],
  );

  useEffect(() => {
    if (!editor?.isEditable) return;
    const element = editor.view.dom;
    const isVideoDrag = (transfer: DataTransfer | null) =>
      Array.from(transfer?.items || []).some(
        (item) => item.kind === "file" && item.type.startsWith("video/"),
      );
    const dragenter = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer) && !isVideoDrag(event.dataTransfer))
        return;
      event.preventDefault();
      imageDragDepthRef.current += 1;
      setDraggingImages(true);
    };
    const dragover = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer) && !isVideoDrag(event.dataTransfer))
        return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
    };
    const dragleave = (event: DragEvent) => {
      if (!isImageDrag(event.dataTransfer) && !isVideoDrag(event.dataTransfer))
        return;
      imageDragDepthRef.current = Math.max(0, imageDragDepthRef.current - 1);
      if (imageDragDepthRef.current === 0) setDraggingImages(false);
    };
    const paste = (event: ClipboardEvent) => {
      const videos = Array.from(event.clipboardData?.files || []).filter(
        (file) => file.type.startsWith("video/"),
      );
      if (videos.length) {
        event.preventDefault();
        if (
          Array.from(event.clipboardData?.files || []).some((file) =>
            file.type.startsWith("image/"),
          )
        ) {
          setImageUploadStatus("画像と動画は分けて追加してください");
          return;
        }
        void handleVideoFiles(videos);
        return;
      }
      const files = Array.from(event.clipboardData?.files || []).filter(
        (file) => file.type.startsWith("image/"),
      );
      if (files.length > 0) {
        event.preventDefault();
        void handleImageFiles(files);
        return;
      }
      const text = event.clipboardData?.getData("text/plain") || "";
      if (!insertPastedJapaneseUrl(editor, text)) return;
      event.preventDefault();
    };
    const drop = (event: DragEvent) => {
      imageDragDepthRef.current = 0;
      setDraggingImages(false);
      const inboxItemId = event.dataTransfer?.getData(INBOX_ITEM_DRAG_TYPE);
      if (inboxItemId) {
        event.preventDefault();
        event.stopImmediatePropagation();
        const position = editor.view.posAtCoords({
          left: event.clientX,
          top: event.clientY,
        });
        if (position) editor.commands.setTextSelection(position.pos);
        insertInboxItem(inboxItemId);
        return;
      }
      const files = Array.from(event.dataTransfer?.files || []).filter(
        (file) =>
          file.type.startsWith("image/") || file.type.startsWith("video/"),
      );
      if (files.length === 0) return;
      event.preventDefault();
      const position = editor.view.posAtCoords({
        left: event.clientX,
        top: event.clientY,
      });
      if (position) editor.commands.setTextSelection(position.pos);
      const videos = files.filter((file) => file.type.startsWith("video/"));
      if (videos.length && videos.length !== files.length) {
        setImageUploadStatus("画像と動画は分けて追加してください");
        return;
      }
      if (videos.length) void handleVideoFiles(videos);
      else void handleImageFiles(files);
    };
    element.addEventListener("dragenter", dragenter, true);
    element.addEventListener("dragover", dragover, true);
    element.addEventListener("dragleave", dragleave, true);
    element.addEventListener("paste", paste, true);
    element.addEventListener("drop", drop, true);
    return () => {
      element.removeEventListener("dragenter", dragenter, true);
      element.removeEventListener("dragover", dragover, true);
      element.removeEventListener("dragleave", dragleave, true);
      element.removeEventListener("paste", paste, true);
      element.removeEventListener("drop", drop, true);
    };
  }, [editor, handleImageFiles, handleVideoFiles, insertInboxItem]);

  useEffect(() => {
    if (!editor || initialFocusAppliedRef.current) return;

    const search = new URLSearchParams(window.location.search);
    const isDailyEditor =
      search.get("new") === "daily" || search.get("template") === "daily";
    const isNewEditor =
      search.get("new") === "1" || window.location.pathname === "/editor/new";
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
    const transaction = editor.state.tr.insert(
      bodyStart,
      editor.schema.nodes.paragraph.create(),
    );
    transaction.setSelection(
      TextSelection.create(transaction.doc, bodyStart + 1),
    );
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
      if (saveTimerRef.current !== null)
        window.clearTimeout(saveTimerRef.current);
    };
  }, [canEdit]);

  const editorErrors = [
    ...(errors.title || []),
    ...(errors.body || []),
    ...(errors.form || []),
  ];
  const universeEnabled = useUniverseEnabled();
  const linkedPageGroups = useMemo(
    () => groupLinkedPages(linkedPages),
    [linkedPages],
  );
  const references = useUniverseReferences(draft.body, universeEnabled);
  const internalUniverseGroups = useMemo(
    () =>
      buildInternalUniverseGroupsFromNames(
        references.wikiLinkNames,
        draft.name || draft.title,
        linkedPageGroups,
      ),
    [references.wikiLinkNames, draft.name, draft.title, linkedPageGroups],
  );
  const externalUniverseGroups = useMemo(
    () =>
      references.externalUrls.map(
        (url) =>
          linkedPageGroups.find(
            (group) => group.kind === "url" && group.name === url,
          ) || {
            kind: "url" as const,
            name: url,
            pages: [],
            isTopicOnly: false,
          },
      ),
    [references.externalUrls, linkedPageGroups],
  );
  const universeGroups = useMemo(
    () => [...internalUniverseGroups, ...externalUniverseGroups],
    [externalUniverseGroups, internalUniverseGroups],
  );
  const visibleLineUpdates = useMemo(
    () =>
      pendingLineUpdates(
        savedBodyRef.current,
        savedBodyRef.current,
        lineUpdatedAt,
      ),
    [lineUpdatedAt],
  );
  const headerActions = document.querySelector<HTMLElement>(
    ".site-header .header-actions",
  );

  return (
    <>
      {headerActions &&
        createPortal(
          canEdit && readingHref ? (
            <button
              type="button"
              className="header-action header-action--view-mode"
              disabled={saving}
              onClick={() => void showReadingView()}
            >
              閲覧
            </button>
          ) : canSwitchToEdit && editingHref ? (
            <a
              className="header-action header-action--view-mode"
              href={editingHref}
            >
              編集
            </a>
          ) : null,
          headerActions,
        )}
      <p
        className="visually-hidden"
        role="status"
        aria-live="polite"
        aria-busy={saving}
      >
        {status}
      </p>
      <p className="visually-hidden" role="status" aria-live="polite">
        {materialStatus}
      </p>
      <div
        className={`article-workspace${canEdit ? "" : " article-workspace--reading"}`}
        ref={workspaceRef}
      >
        {canEdit && (
          <section
            className={`article-editing-cover${draft.resolvedCoverImageUrl ? "" : " article-editing-cover--empty"}`}
            aria-label="記事カバー"
            onDragOver={(event) => {
              if (isImageDrag(event.dataTransfer)) event.preventDefault();
            }}
            onDrop={(event) => void handleCoverDrop(event)}
          >
            {draft.resolvedCoverImageUrl ? (
              <img src={draft.resolvedCoverImageUrl} alt="" />
            ) : (
              <span className="article-editing-cover__prompt">
                画像をドロップしてカバーに設定
              </span>
            )}
            <fieldset
              className="article-editing-cover__actions"
              aria-label="カバーモード"
            >
              <legend className="visually-hidden">カバーモード</legend>
              <label>
                <input
                  type="radio"
                  name="cover-mode"
                  value="auto"
                  checked={draft.coverMode === "auto"}
                  onChange={() =>
                    updateCover(
                      "auto",
                      null,
                      autoCoverImageUrl(draftRef.current.body),
                    )
                  }
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
                  onChange={() =>
                    updateCover(
                      "explicit",
                      draft.coverImageUrl,
                      draft.coverImageUrl,
                    )
                  }
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
          </section>
        )}
        {!canEdit && (
          <header
            className={`article-reading-header${bootstrap.resolved_cover_image_url ? " article-reading-header--covered" : ""}`}
          >
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
          {/* Keyboard users focus the editor directly; this handler only delegates clicks on surrounding whitespace. */}
          {/* biome-ignore lint/a11y/useKeyWithClickEvents: no keyboard equivalent is needed for whitespace */}
          <section
            className="editor-shell"
            aria-label="記事を編集"
            onClick={(event) => {
              if (
                event.target instanceof Element &&
                event.target.closest(".editor-shell__actions")
              )
                return;
              if (!editor || editor.view.dom.contains(event.target as Node))
                return;
              editor.commands.focus("end");
            }}
          >
            <LineUpdateRail
              body={savedBodyRef.current}
              editor={editor}
              updates={visibleLineUpdates}
            />
            {draggingImages && (
              <div className="editor-shell__drop-target" role="status">
                ここにドロップして記事へ追加
              </div>
            )}
            {editor?.isEditable && imageUploadStatus && (
              <p className="editor-shell__upload-status" role="status">
                {imageUploadStatus}
              </p>
            )}
            <div
              className="wysiwyg-editor"
              aria-busy={saving}
              onKeyDownCapture={handleWikiLinkSuggestionKeyDown}
            >
              <EditorContent editor={editor} />
            </div>
            {editorErrors.length > 0 && (
              <p className="input-error" role="alert">
                {editorErrors.join(" ")}
              </p>
            )}
          </section>
        </div>
        {editor?.isEditable && (
          <aside className="content-inbox-drawer" aria-label="素材">
            <section id="content-inbox-panel" className="content-inbox">
              <div className="content-inbox__toolbar">
                <strong>
                  {activeMaterialTab === "photo"
                    ? "写真"
                    : activeMaterialTab === "bluesky"
                      ? "Bluesky"
                      : "Raindrop"}
                </strong>
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
                <ol
                  className={`content-inbox__items content-inbox__items--${activeMaterialTab}`}
                >
                  {visibleInboxItems.map((item) => {
                    const photoUrl = inboxPhotoUrl(item);
                    const thumbnailUrl = inboxItemThumbnail(item);
                    const title = inboxItemTitle(item);
                    const excerpt = inboxItemExcerpt(item);
                    return (
                      <li key={item.id}>
                        <button
                          type="button"
                          className="content-inbox__item"
                          disabled={
                            loadingInbox ||
                            (photoUrl === null &&
                              item.source !== "raindrop" &&
                              item.source !== "bluesky")
                          }
                          draggable={
                            photoUrl !== null || item.source !== "photo"
                          }
                          onDragStart={(event) => {
                            event.dataTransfer.setData(
                              INBOX_ITEM_DRAG_TYPE,
                              item.id,
                            );
                            event.dataTransfer.effectAllowed = "copy";
                          }}
                          aria-label={`${inboxItemName(item)}を本文へ追加`}
                          onClick={() => insertInboxItem(item.id)}
                        >
                          {photoUrl && (
                            <img src={photoUrl} alt="" loading="lazy" />
                          )}
                          {activeMaterialTab !== "photo" && (
                            <span className="content-inbox__card">
                              {thumbnailUrl && (
                                <img
                                  className="content-inbox__thumbnail"
                                  src={thumbnailUrl}
                                  alt=""
                                  loading="lazy"
                                />
                              )}
                              <span className="content-inbox__details">
                                <span className="content-inbox__kind">
                                  {inboxItemLabel(item)}
                                </span>
                                {title && (
                                  <span className="content-inbox__title">
                                    {title}
                                  </span>
                                )}
                                {excerpt && (
                                  <span className="content-inbox__excerpt">
                                    {excerpt}
                                  </span>
                                )}
                              </span>
                            </span>
                          )}
                          {item.used_in_pages.map((page) => (
                            <span
                              className="content-inbox__usage"
                              key={page.id}
                            >
                              {page.route}で使用済み
                            </span>
                          ))}
                          {activeMaterialTab !== "photo" && (
                            <time dateTime={item.occurred_at}>
                              {new Date(item.occurred_at).toLocaleString(
                                "ja-JP",
                                {
                                  month: "numeric",
                                  day: "numeric",
                                  hour: "2-digit",
                                  minute: "2-digit",
                                },
                              )}
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
            <div
              className="content-inbox__tabs"
              role="tablist"
              aria-label="素材の種類"
            >
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
                data-material-tab="bluesky"
                tabIndex={activeMaterialTab === "bluesky" ? 0 : -1}
                aria-selected={activeMaterialTab === "bluesky"}
                aria-controls="content-inbox-panel"
                aria-label="Bluesky"
                title="Bluesky"
                onClick={() => setActiveMaterialTab("bluesky")}
                onKeyDown={handleMaterialTabKeyDown}
              >
                <span
                  className="content-inbox__bluesky-icon"
                  aria-hidden="true"
                >
                  B
                </span>
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
                <span
                  className="content-inbox__raindrop-icon"
                  aria-hidden="true"
                />
              </button>
            </div>
          </aside>
        )}
        {!editor?.isEditable &&
          bootstrap.external_mentions &&
          bootstrap.external_mentions.length > 0 && (
            <section
              className="external-mentions"
              aria-labelledby="external-mentions-heading"
            >
              <h2 id="external-mentions-heading">外部からの言及</h2>
              <ul>
                {bootstrap.external_mentions.map((mention) => (
                  <li key={mention.id}>
                    <a
                      href={mention.source_url}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {mention.title || mention.source_url}
                    </a>
                    {mention.site_name && <small>{mention.site_name}</small>}
                  </li>
                ))}
              </ul>
            </section>
          )}
        {universeEnabled &&
          (universeGroups.length > 0 ||
            linkedPages.length > 0 ||
            linkedPagesHasMore) && (
            <UniverseGraph
              key={draft.name || draft.title}
              groups={universeGroups}
              pages={linkedPages}
              route={draft.name || draft.title}
              hasMore={linkedPagesHasMore}
              loading={loadingLinkedPages}
              error={linkedPagesError}
              loadMore={() => void loadMoreLinkedPages()}
            />
          )}
        {linkedPageGroups.length > 0 && (
          <section
            className="linked-pages"
            aria-labelledby="related-pages-heading"
          >
            <h2 id="related-pages-heading">関連する記事</h2>
            <div className="linked-page-groups">
              {linkedPageGroups.map((group) => (
                <section
                  className="linked-page-group"
                  key={group.name}
                  aria-label={
                    group.isTopicOnly ? `${group.name}へのリンク` : undefined
                  }
                  aria-labelledby={
                    group.isTopicOnly
                      ? undefined
                      : `related-${encodePageName(group.name)}`
                  }
                >
                  {!group.isTopicOnly && (
                    <h3 id={`related-${encodePageName(group.name)}`}>
                      <a
                        href={
                          group.kind === "wiki"
                            ? `/${encodePageName(group.name)}`
                            : group.name
                        }
                        target={group.kind === "url" ? "_blank" : undefined}
                        rel={group.kind === "url" ? "noreferrer" : undefined}
                      >
                        {group.kind === "url"
                          ? externalLinkLabel(group.name)
                          : group.name}
                      </a>
                    </h3>
                  )}
                  <ul
                    className="page-card-list"
                    aria-label={
                      group.isTopicOnly ? `${group.name}へのリンク` : undefined
                    }
                  >
                    {group.pages.map((page) => (
                      <li className="page-card" key={page.id}>
                        <a
                          className="page-card__link"
                          href={`/${encodePageName(page.route)}`}
                        >
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
                          {page.excerpt && (
                            <span className="page-card__excerpt">
                              {page.excerpt}
                            </span>
                          )}
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
                  <button
                    type="button"
                    onClick={() => void loadMoreLinkedPages()}
                    disabled={loadingLinkedPages}
                  >
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
      </div>
    </>
  );
}
