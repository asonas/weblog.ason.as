import {
  forceCollide,
  forceLink,
  forceManyBody,
  forceSimulation,
  forceX,
  forceY,
  type SimulationNodeDatum,
} from "d3-force";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createPortal } from "react-dom";

type Page = {
  id: string;
  route: string;
  title: string;
  excerpt: string;
  created_at?: string;
  image_url?: string | null;
  related_by?: string[];
};
type Group = { kind: "wiki" | "url"; name: string; pages: Page[] };
type Node = SimulationNodeDatum & {
  id: string;
  title: string;
  href: string;
  kind: "root" | "direct" | "incoming" | "related";
  calendar: boolean;
  page?: Page;
  tx: number;
  ty: number;
};
type Edge = { source: Node; target: Node; incoming: boolean; primary: boolean };
type Props = {
  groups: Group[];
  pages: Page[];
  route: string;
  hasMore: boolean;
  loading: boolean;
  error?: string;
  loadMore: () => void;
};
const isCalendar = (name: string) =>
  /^(?:[日月火水木金土]曜日|\d{4}(?:0[1-9]|1[0-2])|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])|日記)$/.test(
    name,
  );
function httpUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return (url.protocol === "https:" || url.protocol === "http:") &&
      !url.username &&
      !url.password
      ? url.href
      : null;
  } catch {
    return null;
  }
}
function externalLinkLabel(value: string): string {
  const url = new URL(value);
  return url.hostname + url.pathname + url.search + url.hash;
}
function universeNodeVisual(
  connectionCount: number,
  createdAt: number,
  oldestCreatedAt: number,
  newestCreatedAt: number,
) {
  const weight = Math.sqrt(Math.max(0, connectionCount - 1));
  const span = newestCreatedAt - oldestCreatedAt;
  const recency =
    span > 0
      ? Math.max(0, Math.min(1, (createdAt - oldestCreatedAt) / span))
      : 1;
  return {
    opacity: 0.35 + recency * 0.65,
    size: Math.min(26, 14 + weight * 3),
  };
}
const href = (name: string) =>
  `/${encodeURIComponent(name).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`)}`;
export function UniverseGraph({
  groups,
  pages,
  route,
  hasMore,
  loading,
  error,
  loadMore,
}: Props) {
  const [active, setActive] = useState<string | null>(null);
  const [keyboardFocus, setKeyboardFocus] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [failedImage, setFailedImage] = useState<string | null>(null);
  const detailId = useId();
  const triggerRef = useRef<SVGElement | null>(null);
  const focusDetailRef = useRef(false);
  const layerRef = useRef<SVGGElement | null>(null);
  const [embeds, setEmbeds] = useState<
    Record<
      string,
      {
        title: string;
        description: string | null;
        image_url: string | null;
      } | null
    >
  >({});
  const containerRef = useRef<HTMLElement | null>(null);
  const [canvasWidth, setCanvasWidth] = useState(1000);
  const detailRef = useRef<HTMLElement | null>(null);
  const closeDetail = useCallback((restoreFocus = false) => {
    setSelected(null);
    if (restoreFocus) triggerRef.current?.focus({ preventScroll: true });
  }, []);
  useEffect(() => {
    if (!selected) return;
    const dismiss = (event: MouseEvent) => {
      if (
        event.target instanceof globalThis.Node &&
        !detailRef.current?.contains(event.target)
      )
        setSelected(null);
    };
    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        closeDetail(true);
      }
    };
    document.addEventListener("click", dismiss);
    document.addEventListener("keydown", handleEscape);
    return () => {
      document.removeEventListener("click", dismiss);
      document.removeEventListener("keydown", handleEscape);
    };
  }, [selected, closeDetail]);
  const [isMobile, setIsMobile] = useState(
    () => window.matchMedia("(max-width: 700px)").matches,
  );
  const [lane, setLane] = useState("links");
  useEffect(() => {
    const media = window.matchMedia("(max-width: 700px)");
    const update = () => {
      setIsMobile(media.matches);
      setActive(null);
      setSelected(null);
    };
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  useEffect(() => {
    if (!containerRef.current) return;
    const observer = new ResizeObserver(([entry]) => {
      if (!entry || entry.contentRect.width <= 0) return;
      setCanvasWidth(entry.contentRect.width);
      setActive(null);
    });
    observer.observe(containerRef.current);
    return () => observer.disconnect();
  }, []);
  const graph = useMemo(() => {
    const nodes = new Map<string, Node>();
    const edges: Edge[] = [];
    const root: Node = {
      id: "root",
      title: route,
      href: href(route),
      kind: "root",
      calendar: false,
      tx: 500,
      ty: 48,
      fx: 500,
      fy: 48,
    };
    nodes.set(root.id, root);
    const direct = groups
      .filter((group) => group.kind !== "url" || httpUrl(group.name))
      .filter((g) => g.kind === "url" || g.name !== route)
      .filter(
        (g) =>
          !isMobile ||
          (lane === "calendar"
            ? isCalendar(g.name)
            : lane === "links" && !isCalendar(g.name)),
      );
    let wordIndex = 0,
      calendarIndex = 0;
    direct.forEach((group) => {
      const calendar = isCalendar(group.name);
      const position = calendar ? calendarIndex++ : wordIndex++;
      const tx = calendar
          ? 760 + (position % 2) * 55
          : 160 + (position % 2) * 150,
        ty = calendar ? 180 + position * 155 : 170 + position * 90;
      const page = pages.find((p) => p.route === group.name);
      const node: Node = {
        id: `${group.kind}:${group.name}`,
        title:
          group.kind === "url" ? externalLinkLabel(group.name) : group.name,
        href: group.kind === "url" ? group.name : href(group.name),
        kind: "direct",
        calendar: isCalendar(group.name),
        page,
        tx,
        ty,
        x: tx,
        y: ty,
      };
      nodes.set(node.id, node);
      edges.push({
        source: root,
        target: node,
        incoming: false,
        primary: true,
      });
    });
    function pageNode(page: Page, kind: Node["kind"], tx: number, ty: number) {
      const id = `wiki:${page.route}`;
      let node = nodes.get(id);
      if (!node) {
        node = {
          id,
          title: page.title,
          href: href(page.route),
          kind,
          calendar: isCalendar(page.route),
          page,
          tx,
          ty,
          x: tx,
          y: ty,
        };
        nodes.set(id, node);
      }
      if (kind === "incoming") node.kind = "incoming";
      return node;
    }
    pages
      .filter(
        (p) =>
          (!isMobile || lane === "incoming") &&
          p.route !== route &&
          p.related_by?.includes(route),
      )
      .forEach((page, index) => {
        const node = pageNode(page, "incoming", 500, 220 + index * 145);
        node.tx = 500;
        node.ty = 220 + index * 145;
        edges.push({
          source: node,
          target: root,
          incoming: true,
          primary: true,
        });
      });
    direct.forEach((group) => {
      const source = nodes.get(`${group.kind}:${group.name}`);
      if (!source) return;
      group.pages.forEach((page, index) => {
        if (page.route === route || page.route === group.name) return;
        const angle = index * 2.399,
          radius = 45 + Math.sqrt(index) * 13;
        const target = pageNode(
          page,
          "related",
          source.tx + Math.cos(angle) * radius,
          source.ty + 110 + Math.sin(angle) * radius,
        );
        edges.push({ source, target, incoming: false, primary: false });
      });
    });
    const list = [...nodes.values()];
    const bottom = Math.max(810, ...list.map((node) => node.ty + 100));
    if (!isMobile)
      forceSimulation(list)
        .stop()
        .force(
          "link",
          forceLink<Node, Edge>(edges)
            .id((n) => n.id)
            .distance((e) => (e.primary ? 240 : 68))
            .strength((e) => (e.primary ? 0.08 : 0.22)),
        )
        .force("charge", forceManyBody().strength(-85))
        .force(
          "collide",
          forceCollide<Node>()
            .radius((n) => (n.kind === "related" ? 13 : 72))
            .iterations(3),
        )
        .force("x", forceX<Node>((n) => n.tx).strength(0.4))
        .force("y", forceY<Node>((n) => n.ty).strength(0.18))
        .tick(240);
    list.forEach((n) => {
      n.x = Math.max(105, Math.min(895, n.x || 500));
      n.y = Math.max(
        n.kind === "root" ? 48 : 150,
        Math.min(bottom, n.y ?? 300),
      );
      if (n.kind === "incoming") n.x = 500;
      if (n.kind === "direct")
        n.x = n.calendar ? Math.max(720, n.x) : Math.min(280, n.x);
    });
    let height = 900;
    if (isMobile) {
      root.x = 195;
      root.y = 42;
      const primary = list.filter(
        (n) => n.kind !== "root" && n.kind !== "related",
      );
      primary.forEach((n, index) => {
        n.x = primary.length === 1 ? 195 : index % 2 === 0 ? 100 : 290;
        n.y = 155 + Math.floor(index / 2) * 210;
      });
      const positioned = new Set<string>();
      primary.forEach((source) => {
        const children = edges
          .filter(
            (e) =>
              !e.primary &&
              e.source.id === source.id &&
              e.target.kind === "related",
          )
          .map((e) => e.target);
        children.forEach((n, index) => {
          if (positioned.has(n.id)) return;
          positioned.add(n.id);
          const angle = index * 2.399,
            r = 15 + Math.sqrt((index + 1) / children.length) * 46;
          n.x = (source.x || 0) + Math.cos(angle) * r;
          n.y = (source.y || 0) + 95 + Math.sin(angle) * r;
        });
      });
      height = Math.max(380, 230 + Math.ceil(primary.length / 2) * 210);
      for (const node of list) node.x = ((node.x ?? 195) * canvasWidth) / 390;
    } else {
      const spacing = Math.max(0.85, Math.min(1.1, canvasWidth / 1000));
      list.forEach((n) => {
        n.x =
          canvasWidth / 2 + (((n.x || 500) - 500) * (canvasWidth - 200)) / 800;
        n.y = 48 + ((n.y || 48) - 48) * spacing;
      });
      height = 48 + (bottom + 42) * spacing;
    }
    return { nodes: list, edges, height };
  }, [groups, pages, route, isMobile, lane, canvasWidth]);
  const pageVisuals = useMemo(() => {
    const dates = pages
      .map((page) => Date.parse(page.created_at || ""))
      .filter(Number.isFinite);
    const oldest = dates.length ? Math.min(...dates) : 0;
    const newest = dates.length ? Math.max(...dates) : 0;
    const counts = new Map<string, number>();
    for (const edge of graph.edges) {
      for (const node of [edge.source, edge.target])
        counts.set(node.id, (counts.get(node.id) || 0) + 1);
    }
    return new Map(
      graph.nodes
        .filter((node) => node.page)
        .map((node) => {
          const createdAt = Date.parse(node.page?.created_at || "");
          return [
            node.id,
            universeNodeVisual(
              counts.get(node.id) || 1,
              Number.isFinite(createdAt) ? createdAt : newest,
              oldest,
              newest,
            ),
          ];
        }),
    );
  }, [graph, pages]);
  const focused = selected || active || keyboardFocus,
    neighbors = new Set([focused]);
  for (const e of graph.edges)
    if (e.source.id === focused || e.target.id === focused) {
      neighbors.add(e.source.id);
      neighbors.add(e.target.id);
    }
  const detail = graph.nodes.find((n) => n.id === selected);
  useLayoutEffect(() => {
    const card = detailRef.current;
    const trigger = triggerRef.current;
    if (!detail || !card || !trigger || isMobile) return;
    const position = () => {
      const anchor = trigger.querySelector("circle")?.getBoundingClientRect();
      if (!anchor) return;
      const bounds = card.getBoundingClientRect();
      const x = anchor.left + anchor.width / 2;
      const y = anchor.top + anchor.height / 2;
      const below = y + 44;
      const top =
        below + bounds.height <= window.innerHeight - 16
          ? below
          : y - 24 - bounds.height;
      card.style.left = `${Math.max(16, Math.min(x - bounds.width / 2, window.innerWidth - bounds.width - 16))}px`;
      card.style.top = `${Math.max(16, Math.min(top, window.innerHeight - bounds.height - 16))}px`;
    };
    position();
    const observer = new ResizeObserver(position);
    observer.observe(card);
    if (containerRef.current) observer.observe(containerRef.current);
    window.addEventListener("resize", position);
    window.addEventListener("scroll", position, true);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", position);
      window.removeEventListener("scroll", position, true);
      card.style.removeProperty("left");
      card.style.removeProperty("top");
    };
  }, [detail, isMobile]);
  useEffect(() => {
    if (selected && focusDetailRef.current) {
      detailRef.current?.focus({ preventScroll: true });
      focusDetailRef.current = false;
    }
  }, [selected]);
  const externalUrl = detail?.id.startsWith("url:") ? detail.href : null;
  const imageUrl = httpUrl(
    externalUrl ? embeds[externalUrl]?.image_url : detail?.page?.image_url,
  );
  const hasImage = Boolean(imageUrl && imageUrl !== failedImage);
  useEffect(() => {
    if (!externalUrl || embeds[externalUrl] !== undefined) return;
    const controller = new AbortController();
    const timeout = window.setTimeout(() => {
      controller.abort();
      setEmbeds((current) => ({ ...current, [externalUrl]: null }));
    }, 10000);
    void fetch(`/api/embed?${new URLSearchParams({ url: externalUrl })}`, {
      signal: controller.signal,
    })
      .then((response) => {
        if (!response.ok) throw new Error("Embed unavailable");
        return response.json();
      })
      .then((metadata: unknown) => {
        if (controller.signal.aborted) return;
        if (
          !metadata ||
          typeof metadata !== "object" ||
          !("title" in metadata) ||
          typeof metadata.title !== "string"
        )
          throw new Error("Invalid embed metadata");
        const title = metadata.title;
        setEmbeds((current) => ({
          ...current,
          [externalUrl]: {
            title,
            description:
              "description" in metadata &&
              typeof metadata.description === "string"
                ? metadata.description
                : null,
            image_url:
              "image_url" in metadata ? httpUrl(metadata.image_url) : null,
          },
        }));
      })
      .catch(() => {
        if (!controller.signal.aborted)
          setEmbeds((current) => ({ ...current, [externalUrl]: null }));
      })
      .finally(() => window.clearTimeout(timeout));
    return () => {
      window.clearTimeout(timeout);
      controller.abort();
    };
  }, [externalUrl, embeds]);
  function nodeAt(clientX: number, clientY: number) {
    const matrix = layerRef.current?.getScreenCTM?.();
    if (!matrix) return null;
    let closest: string | null = null,
      distance = Infinity;
    for (const node of graph.nodes) {
      if (isMobile && node.kind === "related") continue;
      const point = new DOMPoint(node.x || 0, node.y || 0).matrixTransform(
        matrix,
      );
      const candidate = Math.hypot(point.x - clientX, point.y - clientY);
      const visibleRadius =
        ((pageVisuals.get(node.id)?.size || 13) / 2) *
        Math.hypot(matrix.a, matrix.b);
      if (
        candidate < distance &&
        candidate <= Math.max(node.kind === "related" ? 12 : 24, visibleRadius)
      ) {
        closest = node.id;
        distance = candidate;
      }
    }
    if (closest) return closest;
    // Transient labels never change the hit map.
    for (const element of layerRef.current?.querySelectorAll<HTMLElement>(
      "[data-hit-label]",
    ) || []) {
      const rect = element.getBoundingClientRect();
      if (
        clientX >= rect.left &&
        clientX <= rect.right &&
        clientY >= rect.top &&
        clientY <= rect.bottom
      )
        return element.dataset.hitLabel || null;
    }
    return null;
  }
  return (
    <section
      ref={containerRef}
      className="ug-root"
      id="universe"
      aria-label="ユニバース"
    >
      <div className="ug-divider" />
      {isMobile ? (
        <nav className="ug-lanes" aria-label="つながりの領域">
          {[
            ["links", "話題"],
            ["incoming", "リンク元"],
            ["calendar", "日付"],
          ].map(([key, label]) => (
            <button
              type="button"
              key={key}
              aria-pressed={lane === key}
              onClick={() => {
                setLane(key);
                setSelected(null);
                setActive(null);
              }}
            >
              {label}
            </button>
          ))}
        </nav>
      ) : null}
      <svg
        className="ug-canvas"
        data-hovered-node={active || ""}
        viewBox={`0 0 ${canvasWidth} ${graph.height}`}
        aria-label="名前付きの点は直接のリンク先とリンク元、小さな点は関連記事"
        onPointerDown={() => {
          setKeyboardFocus(null);
        }}
        onPointerMove={(e) => {
          if (e.pointerType !== "touch")
            setActive(nodeAt(e.clientX, e.clientY));
        }}
        onPointerLeave={() => setActive(null)}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.stopPropagation();
            closeDetail(true);
          }
        }}
        onClick={(e) => {
          e.stopPropagation();
          const id = nodeAt(e.clientX, e.clientY);
          triggerRef.current =
            [
              ...(layerRef.current?.querySelectorAll<SVGElement>(
                "[data-node-id]",
              ) || []),
            ].find((node) => node.dataset.nodeId === id) || null;
          focusDetailRef.current = false;
          setSelected((current) => (current === id ? null : id));
        }}
      >
        <line
          x1={canvasWidth / 2}
          y1="0"
          x2={canvasWidth / 2}
          y2={isMobile ? 42 : 48}
          className="ug-stem"
        />
        <g ref={layerRef}>
          {graph.edges.map((e) => (
            <line
              key={`${e.source.id}:${e.target.id}:${e.primary}`}
              x1={e.source.x}
              y1={e.source.y}
              x2={e.target.x}
              y2={e.target.y}
              className={`ug-edge ${e.primary ? "ug-primary" : ""} ${e.incoming ? "ug-incoming" : ""} ${e.target.calendar ? "ug-time" : ""}`}
              opacity={
                focused
                  ? e.source.id === focused || e.target.id === focused
                    ? 1
                    : 0.08
                  : 1
              }
            />
          ))}
          {graph.nodes.map((n) => (
            // biome-ignore lint/a11y/useSemanticElements: SVG nodes use shared hit testing; Enter and Space provide keyboard activation.
            <g
              key={n.id}
              data-node-id={n.id}
              transform={`translate(${n.x} ${n.y})`}
              className={`ug-node ug-node-${n.kind} ${n.calendar ? "ug-time" : ""}`}
              opacity={focused && !neighbors.has(n.id) ? 0.22 : 1}
              role="button"
              tabIndex={isMobile && n.kind === "related" ? -1 : 0}
              aria-label={`${n.title}${n.kind === "incoming" ? "、この記事へのリンク元" : ""}`}
              aria-expanded={selected === n.id}
              data-selected={selected === n.id}
              aria-controls={selected === n.id ? detailId : undefined}
              aria-hidden={isMobile && n.kind === "related" ? true : undefined}
              onFocus={() => setKeyboardFocus(n.id)}
              onBlur={() => setKeyboardFocus(null)}
              onKeyDown={(e) => {
                if (e.key === "Enter" || e.key === " ") {
                  e.preventDefault();
                  triggerRef.current = e.currentTarget;
                  focusDetailRef.current = selected !== n.id;
                  setSelected(selected === n.id ? null : n.id);
                }
              }}
            >
              <circle className="ug-hit" r="19" />
              <circle
                r={
                  n.kind === "root"
                    ? 9
                    : (pageVisuals.get(n.id)?.size || 13) / 2
                }
                fillOpacity={pageVisuals.get(n.id)?.opacity ?? 1}
              />
              {(n.kind !== "related" || focused === n.id) && (
                <foreignObject
                  x={isMobile ? -Math.min(82, canvasWidth / 4 - 8) : -100}
                  y="13"
                  width={isMobile ? Math.min(164, canvasWidth / 2 - 16) : 200}
                  height="78"
                >
                  <div
                    className="ug-label"
                    data-hit-label={n.kind !== "related" ? n.id : undefined}
                  >
                    {n.title}
                  </div>
                </foreignObject>
              )}
            </g>
          ))}
        </g>
      </svg>
      {detail &&
        createPortal(
          <aside
            ref={detailRef}
            id={detailId}
            tabIndex={-1}
            aria-label={detail.title}
            className={`ug-detail ${hasImage ? "ug-detail-with-image" : ""}`}
          >
            <header className="ug-detail-header">
              <a
                href={detail.href}
                target={externalUrl ? "_blank" : undefined}
                rel={externalUrl ? "noreferrer" : undefined}
                title="リンク先を開く"
              >
                <span className="visually-hidden">
                  {externalUrl ? "リンク先を新しいタブで開く" : "記事を開く"}
                </span>
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M14 4h6v6M20 4 10 14M10 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-5" />
                </svg>
              </a>
              <button
                type="button"
                onClick={() => closeDetail(true)}
                aria-label="詳細を閉じる"
                title="詳細を閉じる"
              >
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path d="m6 6 12 12M18 6 6 18" />
                </svg>
              </button>
            </header>
            {externalUrl ? (
              <a
                className="ug-ogp"
                href={externalUrl}
                target="_blank"
                rel="noreferrer"
              >
                {hasImage && imageUrl && (
                  <img
                    src={imageUrl}
                    alt=""
                    referrerPolicy="no-referrer"
                    onError={() => setFailedImage(imageUrl)}
                  />
                )}
                <div className="ug-detail-body">
                  <strong>{embeds[externalUrl]?.title || detail.title}</strong>
                  {embeds[externalUrl]?.description && (
                    <p>{embeds[externalUrl]?.description}</p>
                  )}
                  <span>{detail.title} ↗</span>
                  {embeds[externalUrl] === undefined && (
                    <small role="status">プレビューを読み込み中…</small>
                  )}
                  {embeds[externalUrl] === null && (
                    <small role="status">
                      プレビューを取得できませんでした。リンク先は開けます。
                    </small>
                  )}
                </div>
              </a>
            ) : (
              <>
                {hasImage && imageUrl && (
                  <a className="ug-ogp" href={detail.href}>
                    <img
                      src={imageUrl}
                      alt={detail.title}
                      referrerPolicy="no-referrer"
                      onError={() => setFailedImage(imageUrl)}
                    />
                  </a>
                )}
                <div className="ug-detail-body">
                  <a href={detail.href}>{detail.title} ↗</a>
                  <p>{detail.page?.excerpt}</p>
                </div>
              </>
            )}
            {isMobile && (
              <div className="ug-detail-links">
                {graph.edges
                  .filter((e) => !e.primary && e.source.id === detail.id)
                  .map((e) => (
                    <a key={e.target.id} href={e.target.href}>
                      {e.target.title} ↗
                    </a>
                  ))}
              </div>
            )}
          </aside>,
          document.body,
        )}
      <footer className="ug-footer">
        {hasMore && (
          <button type="button" disabled={loading} onClick={loadMore}>
            {loading ? "読み込み中…" : "続きを読み込む"}
          </button>
        )}
        {error && <p role="alert">{error}</p>}
      </footer>
    </section>
  );
}
