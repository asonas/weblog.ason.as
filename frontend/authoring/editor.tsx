import { Extension, type Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import { Plugin, TextSelection } from "@tiptap/pm/state";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type RefObject
} from "react";

import { markdownForEditor, markdownForSource } from "./markdown";

function encodePageName(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

const WIKI_LINK_PATTERN = /\[\[([^\[\]]+)\]\]/g;

const WikiLinks = Extension.create({
  name: "wikiLinks",

  addProseMirrorPlugins() {
    const linkType = this.editor.schema.marks.link;
    return [
      new Plugin({
        appendTransaction(transactions, _oldState, newState) {
          if (!transactions.some((transaction) => transaction.docChanged)) return null;

          const matches: Array<{ from: number; to: number; pageName: string }> = [];
          newState.doc.descendants((node, position) => {
            if (!node.isText || !node.text) return;

            for (const match of node.text.matchAll(WIKI_LINK_PATTERN)) {
              const pageName = match[1].trim();
              if (!pageName || match.index === undefined) continue;

              const from = position + match.index;
              matches.push({ from, to: from + match[0].length, pageName });
            }
          });

          if (matches.length === 0) return null;

          const transaction = newState.tr;
          for (const match of matches.reverse()) {
            const href = `/${encodePageName(match.pageName)}`;
            const linkedText = newState.schema.text(match.pageName, [linkType.create({ href })]);
            transaction.replaceWith(match.from, match.to, linkedText);
          }
          return transaction;
        }
      })
    ];
  }
});

type LinkedPage = {
  id: string;
  title: string;
  route: string;
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
  expectedUpdatedAt: string;
};

type PageResponse = {
  id: string;
  page_type: "date" | "named";
  date: string | null;
  name: string | null;
  title: string | null;
  updated_at: string | null;
  route: string;
  linked_pages: EditorBootstrap["linked_pages"];
  linked_pages_has_more: boolean;
};

type RelatedPagesResponse = {
  pages: EditorBootstrap["linked_pages"];
  has_more: boolean;
};

type ApiError = Error & {
  fields?: Record<string, string[]>;
};

type JsonObject = Record<string, unknown>;
type HttpMethod = "POST" | "PATCH";

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

function extractEmbeddableUrls(body: string): Array<string> {
  const matches = body.match(/https?:\/\/[^\s<>\[\]\\"')]+/g) || [];
  const normalized = matches.map((url) =>
    url.replace(/\\(?=[^\w\s]|_)/g, "").replace(/[.,;:!?]+$/, "")
  );
  return Array.from(new Set(normalized))
    .filter((url) => !/\.(?:avif|gif|jpe?g|png|webp)(?:[?#]|$)/i.test(url));
}

function externalLinkLabel(url: string): string {
  try {
    return new URL(url).hostname;
  } catch (_error) {
    return url;
  }
}

function EmbedCard({ url }: { url: string }) {
  const [metadata, setMetadata] = useState<EmbedMetadata | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setMetadata(null);
    setFailed(false);
    void fetchJson<EmbedMetadata>(`/api/embed?${new URLSearchParams({ url }).toString()}`)
      .then(setMetadata)
      .catch(() => setFailed(true));
  }, [url]);

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
        <small>{metadata.site_name || externalLinkLabel(metadata.url)}</small>
        <strong>{metadata.title}</strong>
        {metadata.description && <span>{metadata.description}</span>}
        <span className="embed-card__url">{metadata.url}</span>
      </span>
      {metadata.image_url && (
        <img src={metadata.image_url} alt="" loading="lazy" referrerPolicy="no-referrer" />
      )}
    </div>
  );
}

type UniversePoint = { x: number; y: number };
type UniverseRect = { top: number; right: number; bottom: number; left: number };
type UniverseNode = UniversePoint & {
  url: string;
  anchor: UniversePoint;
  target: UniversePoint;
  vx: number;
  vy: number;
};
const UNIVERSE_NODE_RADIUS = 7;
const UNIVERSE_NODE_GAP = 15;

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

function Universe({
  urls,
  editor,
  workspaceRef
}: {
  urls: Array<string>;
  editor: Editor | null;
  workspaceRef: RefObject<HTMLDivElement | null>;
}) {
  const enabled = useUniverseEnabled();
  const [nodes, setNodes] = useState<Array<UniverseNode>>([]);
  const [activeUrl, setActiveUrl] = useState<string | null>(null);
  const closeTimerRef = useRef<number | null>(null);

  const closePreview = useCallback(() => {
    closeTimerRef.current = window.setTimeout(() => setActiveUrl(null), 120);
  }, []);

  const openPreview = useCallback((url: string) => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
    setActiveUrl(url);
  }, []);

  useLayoutEffect(() => {
    const workspace = workspaceRef.current;
    if (!enabled || !editor || !workspace || urls.length === 0) {
      setNodes([]);
      setActiveUrl(null);
      return;
    }

    let animationFrame = 0;
    let measureFrame = 0;
    const media = window.matchMedia("(min-width: 68.8125rem)");
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    const measure = () => {
      window.cancelAnimationFrame(measureFrame);
      window.cancelAnimationFrame(animationFrame);
      measureFrame = window.requestAnimationFrame(() => {
        if (!media.matches) {
          setNodes([]);
          return;
        }

        const workspaceRect = workspace.getBoundingClientRect();
        const editorShell = workspace.querySelector<HTMLElement>(".editor-shell");
        if (!editorShell) return;

        const anchors = new Map<string, UniversePoint>();
        const links = Array.from(editor.view.dom.querySelectorAll<HTMLAnchorElement>("a[href]"));
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
        const width = workspace.clientWidth;
        const height = workspace.scrollHeight;
        const nextNodes = initialUniverseNodes(urls, anchors, editorRect, width);

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
    media.addEventListener("change", measure);
    measure();

    return () => {
      window.cancelAnimationFrame(measureFrame);
      window.cancelAnimationFrame(animationFrame);
      observer.disconnect();
      editor.off("update", measure);
      media.removeEventListener("change", measure);
    };
  }, [editor, enabled, urls, workspaceRef]);

  useEffect(() => () => {
    if (closeTimerRef.current !== null) window.clearTimeout(closeTimerRef.current);
  }, []);

  if (!enabled || nodes.length === 0) return null;

  const activeNode = nodes.find((node) => node.url === activeUrl);
  const workspaceWidth = workspaceRef.current?.clientWidth || 0;
  const previewLeft = activeNode
    ? Math.max(16, Math.min(activeNode.x + 20, workspaceWidth - 272))
    : 0;
  const previewStyle = activeNode ? {
    "--universe-preview-x": `${previewLeft}px`,
    "--universe-preview-y": `${Math.max(0, activeNode.y - 64)}px`
  } as CSSProperties : undefined;

  return (
    <div className="universe" aria-label="ユニバース">
      <svg className="universe__graph" aria-hidden="true">
        {nodes.map((node) => (
          <line key={node.url} x1={node.anchor.x} y1={node.anchor.y} x2={node.x} y2={node.y} />
        ))}
      </svg>
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
      {activeNode && (
        <div
          className="universe__preview"
          id="universe-preview"
          role="tooltip"
          style={previewStyle}
          onMouseEnter={() => openPreview(activeNode.url)}
          onMouseLeave={closePreview}
        >
          <EmbedCard url={activeNode.url} />
        </div>
      )}
    </div>
  );
}

const EDITOR_EXTENSIONS = [
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
    expectedUpdatedAt: bootstrap.expected_updated_at
  };
}

function editorDocument(title: string, body: string): string {
  return [title, markdownForEditor(body)].filter((part) => part.length > 0).join("\n\n");
}

function splitEditorDocument(markdown: string): Pick<EditorDraft, "title" | "body"> {
  const [title = "", ...bodyLines] = markdownForSource(markdown).split("\n");
  return {
    title: title.trim(),
    body: bodyLines.join("\n").replace(/^\n+/, "")
  };
}

async function requestJson<T>(url: string, payload: JsonObject, method: HttpMethod = "POST"): Promise<T> {
  const response = await fetch(url, {
    method,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json"
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

function statusMessage(page: PageResponse): string {
  return page.updated_at ? `保存済み・最終更新 ${page.updated_at}` : "保存済み";
}

export function AuthoringEditor({ bootstrap }: { bootstrap: EditorBootstrap }) {
  const [draft, setDraft] = useState<EditorDraft>(() => initialDraft(bootstrap));
  const [status, setStatus] = useState(bootstrap.save_message);
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);
  const [linkedPages, setLinkedPages] = useState(bootstrap.linked_pages || []);
  const [linkedPagesHasMore, setLinkedPagesHasMore] = useState(bootstrap.linked_pages_has_more || false);
  const [loadingLinkedPages, setLoadingLinkedPages] = useState(false);
  const [linkedPagesError, setLinkedPagesError] = useState("");
  const draftRef = useRef(draft);
  const dirtyRef = useRef(false);
  const savingRef = useRef(false);
  const editVersionRef = useRef(0);
  const saveTimerRef = useRef<number | null>(null);
  const pendingSaveRef = useRef(false);
  const savedNameRef = useRef(bootstrap.name || bootstrap.title);
  const loadingLinkedPagesRef = useRef(false);
  const linkedPagesSentinelRef = useRef<HTMLDivElement | null>(null);
  const initialFocusAppliedRef = useRef(false);
  const workspaceRef = useRef<HTMLDivElement | null>(null);

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
    if (savingRef.current) {
      pendingSaveRef.current = true;
      return;
    }

    if (saveTimerRef.current !== null) {
      window.clearTimeout(saveTimerRef.current);
      saveTimerRef.current = null;
    }

    const snapshot = { ...draftRef.current };
    const savedVersion = editVersionRef.current;
    savingRef.current = true;
    setSaving(true);
    setStatus("保存中…");

    try {
      const endpoint = snapshot.pageId
        ? `/api/pages/${encodeURIComponent(snapshot.pageId)}`
        : "/api/pages";
      const page = await requestJson<PageResponse>(endpoint, {
        page_id: snapshot.pageId,
        page_type: snapshot.pageType,
        date: snapshot.date,
        name: snapshot.name || undefined,
        title: snapshot.title || undefined,
        body: snapshot.body,
        expected_updated_at: snapshot.expectedUpdatedAt || undefined
      }, snapshot.pageId ? "PATCH" : "POST");
      const current = draftRef.current;
      const next = {
        ...current,
        pageId: page.id,
        pageType: page.page_type,
        date: page.date || current.date,
        name: page.name || current.name,
        expectedUpdatedAt: page.updated_at || ""
      };
      draftRef.current = next;
      setDraft(next);
      savedNameRef.current = page.name || next.title;
      setLinkedPages(page.linked_pages || []);
      setLinkedPagesHasMore(page.linked_pages_has_more || false);
      if (!snapshot.pageId) {
        window.history.pushState(null, "", `/${encodePageName(page.route)}`);
      }
      setErrors({});
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
    }, 700);
  }, [savePage]);

  const handleDocumentChange = useCallback((markdown: string, hasBodyBlock: boolean) => {
    const next = updateDraft(splitEditorDocument(markdown));
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
    const isRenaming = next.pageId && next.pageType === "named" && next.title !== savedNameRef.current;
    if (!isRenaming && (next.pageId || (next.title && hasBodyBlock))) scheduleSave();
  }, [scheduleSave, setDirtyState, updateDraft]);

  const handleEditorBlur = useCallback(async (currentEditor: Editor) => {
    const current = draftRef.current;
    if (!current.pageId) {
      if (current.title.trim()) void savePage();
      return;
    }
    if (current.pageType !== "named" || current.title === savedNameRef.current) return;
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
      window.history.replaceState(null, "", `/${encodePageName(page.route)}`);
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
  }, [savePage, scheduleSave, setDirtyState, updateDraft]);

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
    onBlur: ({ editor: currentEditor }) => {
      void handleEditorBlur(currentEditor);
    }
  });

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
      if (!dirtyRef.current && !savingRef.current) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => {
      window.removeEventListener("beforeunload", handleBeforeUnload);
      if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    };
  }, []);

  const editorErrors = [
    ...(errors.title || []),
    ...(errors.body || []),
    ...(errors.form || [])
  ];
  const linkedPageGroups = useMemo(() => groupLinkedPages(linkedPages), [linkedPages]);
  const embedUrls = useMemo(() => extractEmbeddableUrls(draft.body), [draft.body]);

  return (
    <>
      <p className="visually-hidden" role="status" aria-live="polite" aria-busy={saving}>
        {status}
      </p>
      <div className="article-workspace" ref={workspaceRef}>
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
            <div className="wysiwyg-editor" aria-busy={saving}>
              <EditorContent editor={editor} />
            </div>
            {editorErrors.length > 0 && (
              <p className="input-error" role="alert">{editorErrors.join(" ")}</p>
            )}
          </section>
        </div>
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
        <Universe urls={embedUrls} editor={editor} workspaceRef={workspaceRef} />
      </div>
    </>
  );
}
