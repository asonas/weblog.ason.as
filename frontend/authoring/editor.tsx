import { Extension, type Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import { Plugin, TextSelection } from "@tiptap/pm/state";
import { EditorContent, useEditor } from "@tiptap/react";
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
  type PointerEvent as ReactPointerEvent,
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
          if (!transactions.some((transaction) => transaction.docChanged || transaction.selectionSet)) return null;
          if (transactions.some((transaction) => transaction.getMeta("wikiLinkRawEditing"))) return null;

          const cursor = newState.selection.empty ? newState.selection.from : -1;
          if (transactions.some((transaction) => transaction.selectionSet)) {
            const activeLinks: Array<{ from: number; to: number; text: string }> = [];
            newState.doc.descendants((node, from) => {
              if (activeLinks.length > 0 || !node.isText || !node.text || cursor < from || cursor > from + node.nodeSize) {
                return;
              }
              const link = node.marks.find((mark) => mark.type === linkType);
              if (typeof link?.attrs.href === "string" && link.attrs.href.startsWith("/")) {
                activeLinks.push({ from, to: from + node.nodeSize, text: node.text });
              }
            });
            const activeLink = activeLinks[0];
            if (activeLink) {
              const offset = Math.max(0, Math.min(cursor - activeLink.from, activeLink.text.length));
              const closingBrackets = cursor === activeLink.to ? 2 : 0;
              const transaction = newState.tr.replaceWith(
                activeLink.from,
                activeLink.to,
                newState.schema.text(`[[${activeLink.text}]]`)
              );
              return transaction
                .setSelection(TextSelection.create(
                  transaction.doc,
                  activeLink.from + 2 + offset + closingBrackets
                ))
                .setMeta("wikiLinkRawEditing", true);
            }
          }

          const matches: Array<{ from: number; to: number; pageName: string }> = [];
          const changedLinks: Array<{ from: number; to: number; pageName: string }> = [];
          newState.doc.descendants((node, position) => {
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
              if (cursor >= from && cursor <= to) continue;
              matches.push({ from, to, pageName });
            }
          });

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

function extractWikiLinkNames(body: string): Array<string> {
  return Array.from(body.matchAll(WIKI_LINK_PATTERN), (match) => match[1].trim())
    .filter((name, index, names) => name && names.indexOf(name) === index);
}

export function buildInternalUniverseGroups(
  body: string,
  route: string,
  linkedPageGroups: Array<LinkedPageGroup>
): Array<LinkedPageGroup> {
  const names = extractWikiLinkNames(body);
  if (route && !names.includes(route) && linkedPageGroups.some((group) =>
    group.kind === "wiki" && group.name === route
  )) {
    names.push(route);
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

function externalLinkLabel(url: string): string {
  try {
    return new URL(url).hostname;
  } catch (_error) {
    return url;
  }
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
  const layout = useMemo(() => internalGraphLayout(groups, width), [groups, width]);
  const activeNode = layout.pages.find((node) => node.page?.id === activePage?.id);
  const previewY = activeNode
    ? Math.max(112, Math.min((activeNode.y ?? 0) - 80, layout.height - 176))
    : 0;
  const externalUrls = useMemo(
    () => groups.filter((group) => group.kind === "url").map((group) => group.name),
    [groups]
  );

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
      {layout.topics.map((topic) => (
        <span
          className="internal-universe-group__topic-wrap"
          key={topic.id}
          onPointerEnter={() => onActiveTopicChange(topic.name || null)}
          onPointerLeave={() => onActiveTopicChange(null)}
          onFocus={() => onActiveTopicChange(topic.name || null)}
          onBlur={() => onActiveTopicChange(null)}
        >
          <a
            className="internal-universe-group__topic-node"
            href={topic.group?.kind === "url" ? topic.name : `/${encodePageName(topic.name || "")}`}
            data-universe-topic={topic.name}
            aria-label={topic.name}
            target={topic.group?.kind === "url" ? "_blank" : undefined}
            rel={topic.group?.kind === "url" ? "noreferrer" : undefined}
            style={{
              "--internal-topic-x": `${topic.x}px`,
              "--internal-topic-y": `${topic.y}px`
            } as CSSProperties}
          />
          <a
            className={`internal-universe-group__topic${topic.group?.kind === "url" ? " internal-universe-group__topic--external" : ""}`}
            href={topic.group?.kind === "url" ? topic.name : `/${encodePageName(topic.name || "")}`}
            target={topic.group?.kind === "url" ? "_blank" : undefined}
            rel={topic.group?.kind === "url" ? "noreferrer" : undefined}
            style={{
              "--internal-topic-x": `${topic.x}px`,
              "--internal-topic-y": `${topic.y}px`
            } as CSSProperties}
          >
            {topic.group?.kind === "url" ? (
              <EmbedCard
                url={topic.name || ""}
                metadata={embeds[topic.name || ""] || undefined}
                failed={embeds[topic.name || ""] === null}
              />
            ) : topic.name}
          </a>
        </span>
      ))}
      {layout.pages.map((node) => {
        const page = node.page;
        if (!page) return null;
        return (
          <a
            className="internal-universe-group__node"
            href={`/${encodePageName(page.route)}`}
            aria-label={page.title}
            key={page.id}
            style={{
              "--internal-node-x": `${node.x}px`,
              "--internal-node-y": `${node.y}px`
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
        const glassRect = relativeRect(editorShell, workspaceRect, EDITOR_FOCUS_RING_CLEARANCE);
        const width = workspace.clientWidth;
        const height = workspace.scrollHeight;
        setLayout({ editorRect: glassRect, obstacles, width, height });
        setTopicLines(topics.flatMap(({ kind, name }) => {
          const href = kind === "url"
            ? name
            : new URL(`/${encodePageName(name)}`, window.location.origin).href;
          const link = links.find((candidate) => candidate.href === href);
          const topic = workspace.querySelector<HTMLElement>(`[data-universe-topic="${CSS.escape(name)}"]`);
          if (!link || !topic) return [];
          const anchor = linkUnderlineAnchor(link, workspaceRect);
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

export const EDITOR_EXTENSIONS = [
  StarterKit.configure({
    dropcursor: false,
    gapcursor: false,
    underline: false,
    link: {
      openOnClick: false,
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

function statusMessage(page: PageResponse): string {
  return page.updated_at ? `保存済み・最終更新 ${page.updated_at}` : "保存済み";
}

export function AuthoringEditor({ bootstrap }: { bootstrap: EditorBootstrap }) {
  const [draft, setDraft] = useState<EditorDraft>(() => initialDraft(bootstrap));
  const [editorContentReady, setEditorContentReady] = useState(false);
  const [status, setStatus] = useState(bootstrap.save_message);
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [saving, setSaving] = useState(false);
  const [linkedPages, setLinkedPages] = useState(bootstrap.linked_pages || []);
  const [linkedPagesHasMore, setLinkedPagesHasMore] = useState(bootstrap.linked_pages_has_more || false);
  const [loadingLinkedPages, setLoadingLinkedPages] = useState(false);
  const [linkedPagesError, setLinkedPagesError] = useState("");
  const [activeUniverseTopic, setActiveUniverseTopic] = useState<string | null>(null);
  const draftRef = useRef(draft);
  const dirtyRef = useRef(false);
  const savingRef = useRef(false);
  const editVersionRef = useRef(0);
  const saveTimerRef = useRef<number | null>(null);
  const pendingSaveRef = useRef(false);
  const savedNameRef = useRef(bootstrap.name || bootstrap.title);
  const loadingLinkedPagesRef = useRef(false);
  const linkedPagesSentinelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    document.title = draft.title ? `${draft.title} : weblog.ason.as` : "weblog.ason.as";
  }, [draft.title]);
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
    }, 300);
  }, [savePage]);

  const handleDocumentChange = useCallback((markdown: string, hasBodyBlock: boolean) => {
    const next = updateDraft(splitEditorDocument(markdown));
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
    const isRenaming = next.pageId && next.pageType === "named" && next.title !== savedNameRef.current;
    if (isUnpersistedRouteRef.current && !next.body.trim()) return;
    if (!isRenaming && (next.pageId || (next.title && hasBodyBlock))) scheduleSave();
  }, [scheduleSave, setDirtyState, updateDraft]);

  const handleEditorBlur = useCallback(async (currentEditor: Editor) => {
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
    editable: document.documentElement.dataset.canEdit === "true",
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
  const universeEnabled = useUniverseEnabled();
  const linkedPageGroups = useMemo(() => groupLinkedPages(linkedPages), [linkedPages]);
  const embedUrls = useMemo(() => extractEmbeddableUrls(draft.body), [draft.body]);
  const internalUniverseGroups = useMemo(
    () => buildInternalUniverseGroups(draft.body, draft.name || draft.title, linkedPageGroups),
    [draft.body, draft.name, draft.title, linkedPageGroups]
  );
  const externalUniverseGroups = useMemo(() =>
    embedUrls.map((url) => linkedPageGroups.find((group) => group.kind === "url" && group.name === url) || {
      kind: "url" as const,
      name: url,
      pages: [],
      isTopicOnly: false
    }), [embedUrls, linkedPageGroups]);
  const universeGroups = useMemo(
    () => [...internalUniverseGroups, ...externalUniverseGroups],
    [externalUniverseGroups, internalUniverseGroups]
  );

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
              <EditorContent editor={editor} ref={handleEditorContentRef} />
            </div>
            {editorErrors.length > 0 && (
              <p className="input-error" role="alert">{editorErrors.join(" ")}</p>
            )}
          </section>
        </div>
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
          topics={universeGroups.map(({ kind, name }) => ({ kind, name }))}
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
