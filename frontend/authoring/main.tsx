import { createRoot } from "react-dom/client";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { RefObject } from "react";

import { AuthoringEditor, type EditorBootstrap } from "./editor";
import { SearchPage, SiteSearch } from "./search";
import "./styles.css";

const UNIVERSE_STORAGE_KEY = "weblog-universe";

type AuthState = {
  authenticated: boolean;
  authentication_required: boolean;
  can_edit: boolean;
  login: string | null;
  csrf_token: string;
};

const DEFAULT_AUTH_STATE: AuthState = {
  authenticated: false,
  authentication_required: true,
  can_edit: false,
  login: null,
  csrf_token: ""
};

async function setupAuthentication(): Promise<AuthState> {
  const auth = await fetchBootstrap<AuthState>("/api/auth/session");
  document.documentElement.dataset.canEdit = String(auth.can_edit);
  document.documentElement.dataset.csrfToken = auth.csrf_token;

  document.querySelectorAll<HTMLElement>("#new-page-action, #daily-page-action").forEach((action) => {
    action.hidden = !auth.can_edit;
  });
  return auth;
}

function applyUniverse(enabled: boolean) {
  document.documentElement.dataset.universe = enabled ? "on" : "off";
  const button = document.querySelector<HTMLButtonElement>("#universe-toggle");
  if (!button) return;

  button.setAttribute("aria-pressed", String(enabled));
  button.setAttribute("aria-label", enabled ? "ユニバースを閉じる" : "ユニバースを開く");
  button.title = enabled ? "ユニバースを閉じる" : "ユニバースを開く";
}

function setupUniverseToggle() {
  const button = document.querySelector<HTMLButtonElement>("#universe-toggle");
  if (!button) return;

  let enabled = window.localStorage.getItem(UNIVERSE_STORAGE_KEY) !== "off";
  applyUniverse(enabled);
  button.addEventListener("click", () => {
    enabled = !enabled;
    window.localStorage.setItem(UNIVERSE_STORAGE_KEY, enabled ? "on" : "off");
    applyUniverse(enabled);
  });
}

setupUniverseToggle();

type HomePage = {
  id: string;
  title: string;
  route: string;
  created_at: string;
  updated_at: string;
  excerpt: string;
  image_url: string | null;
  is_diary: boolean;
};

type HomeBootstrap = {
  mode: "home";
  tags?: string[];
  pages: HomePage[];
  newer_cursor?: string | null;
  older_cursor?: string | null;
  has_newer?: boolean;
  has_older?: boolean;
  archive?: Array<{
    year: number;
    months: number[];
  }>;
};

type AppBootstrap = (EditorBootstrap & { mode: "editor" }) | HomeBootstrap;

const DATE_PARTS_FORMATTER = new Intl.DateTimeFormat("ja-JP", {
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  timeZone: "Asia/Tokyo"
});

function formatDate(value: string): string {
  const parts = DATE_PARTS_FORMATTER.formatToParts(new Date(value));
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((candidate) => candidate.type === type)?.value || "";
  return `${part("year")}-${part("month")}-${part("day")}`;
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function fetchBootstrap<T>(url: string): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, { headers: { Accept: "application/json" } });
  } catch (_error) {
    throw new Error("APIに接続できません。Sinatraを127.0.0.1:8000で起動してください");
  }

  const responseText = await response.text();
  let raw: unknown;
  try {
    raw = JSON.parse(responseText);
  } catch (_error) {
    throw new Error(`APIからJSONではない応答が返されました（HTTP ${response.status}）`);
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    throw new Error(typeof result.error === "string" ? result.error : "ページを読み込めませんでした");
  }

  return raw as T;
}

function routeBootstrapUrl(): string {
  const path = window.location.pathname;
  if (path === "/") {
    const newPage = new URLSearchParams(window.location.search).get("new");
    if (newPage === "daily") return "/api/editor/new?template=daily";
    if (newPage === "1") return "/api/editor/new?type=named";
    return "/api/pages";
  }
  if (path === "/editor/new") return `/api/editor/new${window.location.search}`;

  const prefix = "/editor/";
  if (path.startsWith(prefix)) {
    const pageId = path.slice(prefix.length).replace(/\/$/, "");
    if (pageId && !pageId.includes("/")) return `/api/pages/${encodeURIComponent(pageId)}`;
  }

  const route = path.slice(1).replace(/\/$/, "");
  if (route && !route.includes("/")) return `/api/routes/${route}`;

  throw new Error("対応していないページです");
}

function App({ initialBootstrap, auth }: { initialBootstrap?: AppBootstrap; auth: AuthState }) {
  const [bootstrap, setBootstrap] = useState<AppBootstrap | null>(initialBootstrap || null);
  const [error, setError] = useState<string | null>(null);
  const [requestVersion, setRequestVersion] = useState(0);

  useEffect(() => {
    if (initialBootstrap) return;

    let active = true;
    void fetchBootstrap<AppBootstrap>(routeBootstrapUrl())
      .then((nextBootstrap) => {
        if (active) setBootstrap(nextBootstrap);
      })
      .catch((reason: unknown) => {
        if (active) setError(reason instanceof Error ? reason.message : "ページを読み込めませんでした");
      });

    return () => {
      active = false;
    };
  }, [initialBootstrap, requestVersion]);

  if (error) {
    return (
      <>
        <p role="alert">{error}</p>
        <button
          type="button"
          onClick={() => {
            setError(null);
            setBootstrap(null);
            setRequestVersion((version) => version + 1);
          }}
        >
          再読み込み
        </button>
      </>
    );
  }
  if (!bootstrap) {
    return <p className="loading-state" role="status">記事を読み込んでいます</p>;
  }

  if (bootstrap.mode === "home") return <Home bootstrap={bootstrap} auth={auth} />;

  const header = document.querySelector<HTMLElement>(".site-header");
  return <>
    {header && createPortal(<SiteSearch />, header)}
    <AuthoringEditor key={auth.can_edit ? "editable" : "readonly"} bootstrap={bootstrap} />
  </>;
}

function RootApp({ initialBootstrap, initialAuth }: { initialBootstrap?: AppBootstrap; initialAuth: AuthState }) {
  const [auth, setAuth] = useState(initialAuth);

  useEffect(() => {
    let active = true;
    void setupAuthentication()
      .then((nextAuth) => {
        if (active) setAuth(nextAuth);
      })
      .catch(() => {
        document.documentElement.dataset.canEdit = "false";
      });

    return () => {
      active = false;
    };
  }, []);

  const header = document.querySelector<HTMLElement>(".site-header");
  if (window.location.pathname === "/search") {
    return <>
      {header && createPortal(<SiteSearch />, header)}
      <SearchPage />
    </>;
  }
  return <App initialBootstrap={initialBootstrap} auth={auth} />;
}

function HomeTags({ tags, fitMobileRows = false }: { tags: string[]; fitMobileRows?: boolean }) {
  const tagsRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!fitMobileRows) return;
    const tagsElement = tagsRef.current;
    if (!tagsElement) return;

    const fitRows = () => {
      const links = Array.from(tagsElement.querySelectorAll<HTMLAnchorElement>("a"));
      links.forEach((link) => { link.hidden = false; });
      if (!window.matchMedia("(max-width: 36rem)").matches) return;

      const rowStarts: number[] = [];
      links.forEach((link) => {
        if (!rowStarts.includes(link.offsetTop)) rowStarts.push(link.offsetTop);
        if (rowStarts.length > 2) link.hidden = true;
      });
    };

    fitRows();
    window.addEventListener("resize", fitRows);
    return () => window.removeEventListener("resize", fitRows);
  }, [fitMobileRows, tags]);

  if (tags.length === 0) return null;

  return (
    <nav className="home-tags" aria-label="最近更新されたタグ" ref={tagsRef}>
      {tags.map((tag) => (
        <a href={`/${encodeURIComponent(tag)}`} key={tag}>{tag}</a>
      ))}
    </nav>
  );
}

function HomeArchive({ years, heading = "過去の記事", selectedMonth, onSelectMonth }: {
  years: NonNullable<HomeBootstrap["archive"]>;
  heading?: string;
  selectedMonth?: string | null;
  onSelectMonth?: (month: string) => void;
}) {
  if (years.length === 0) return null;

  return (
    <section
      className="home-archive"
      aria-label={heading ? undefined : "記事の年月アーカイブ"}
      aria-labelledby={heading ? "archive-heading" : undefined}
    >
      {heading && <h2 id="archive-heading">{heading}</h2>}
      <div className="home-archive__years">
        {years.map(({ year, months }) => (
          <section className="home-archive__year" aria-labelledby={`archive-${year}`} key={year}>
            <h3 id={`archive-${year}`}>{year}</h3>
            <div className="home-archive__months">
              {Array.from({ length: 12 }, (_, index) => index + 1).map((month) => {
                const label = String(month).padStart(2, "0");
                const monthKey = `${year}-${label}`;
                return months.includes(month) ? (
                  <a
                    href={`/${year}${label}`}
                    aria-label={`${year}年${month}月の記事`}
                    aria-current={selectedMonth === monthKey ? "true" : undefined}
                    key={month}
                    onClick={onSelectMonth ? (event) => {
                      event.preventDefault();
                      onSelectMonth(monthKey);
                    } : undefined}
                  >
                    {label}
                  </a>
                ) : <span aria-hidden="true" key={month}>{label}</span>;
              })}
            </div>
          </section>
        ))}
      </div>
    </section>
  );
}

function GitHubAuthentication({ auth }: { auth: AuthState }) {
  if (!auth.authentication_required) return null;

  const icon = (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 .7a11.5 11.5 0 0 0-3.64 22.41c.58.11.79-.25.79-.56v-2.23c-3.22.7-3.9-1.37-3.9-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.71.08-.71 1.17.08 1.78 1.2 1.78 1.2 1.04 1.78 2.72 1.27 3.38.97.1-.75.4-1.27.74-1.56-2.57-.29-5.27-1.29-5.27-5.68 0-1.26.45-2.28 1.2-3.09-.12-.29-.52-1.47.11-3.05 0 0 .98-.31 3.16 1.18A11 11 0 0 1 12 6.12c.98 0 1.95.13 2.86.39 2.2-1.49 3.17-1.18 3.17-1.18.63 1.58.23 2.76.11 3.05.75.81 1.2 1.83 1.2 3.09 0 4.4-2.71 5.38-5.29 5.67.42.36.79 1.06.79 2.14v3.27c0 .31.21.68.8.56A11.5 11.5 0 0 0 12 .7Z"/>
    </svg>
  );

  if (auth.authenticated) {
    return (
      <form className="home-auth" action="/api/auth/logout" method="post">
        <input type="hidden" name="csrf_token" value={auth.csrf_token} />
        <button type="submit" aria-label={`${auth.login || "GitHub"}からログアウト`} title="GitHubからログアウト">
          {icon}
        </button>
      </form>
    );
  }

  const query = new URLSearchParams({ return_to: window.location.pathname + window.location.search });
  return (
    <div className="home-auth">
      <a href={`/api/auth/github?${query}`} aria-label="GitHubでログイン" title="GitHubでログイン">
        {icon}
      </a>
    </div>
  );
}

function HeaderDock() {
  const actionsDockRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const dock = actionsDockRef.current;
    const header = document.querySelector<HTMLElement>(".site-header");
    const navigation = header?.querySelector<HTMLElement>(".header-nav");
    const actions = navigation?.querySelector<HTMLElement>(".header-actions");
    if (!dock || !header || !navigation || !actions) return;

    dock.append(actions);
    header.hidden = true;
    return () => {
      navigation.append(actions);
      header.hidden = false;
    };
  }, []);

  return (
    <div className="atlas-header">
      <h1><a href="/">weblog.ason.as</a></h1>
      <div className="atlas-header__actions" ref={actionsDockRef} />
      <div className="atlas-header__search"><SiteSearch /></div>
    </div>
  );
}

type PageWindow = Pick<HomeBootstrap,
  "pages" | "newer_cursor" | "older_cursor" | "has_newer" | "has_older"
>;

function AtlasEntry({ page }: { page: HomePage }) {
  return (
    <article className="atlas-entry">
      <a href={`/${encodeURIComponent(page.route)}`}>
        {page.image_url && <img src={page.image_url} alt="" loading="lazy" referrerPolicy="no-referrer" />}
        <span className="atlas-entry__body">
          <strong>{page.title}</strong>
          {page.excerpt && <span>{page.excerpt}</span>}
        </span>
      </a>
    </article>
  );
}

function FeedColumn({ kind, heading, initialPages, selectedMonth }: {
  kind: "diary" | "article";
  heading: string;
  initialPages: HomePage[];
  selectedMonth: string | null;
}) {
  const [windowState, setWindowState] = useState<PageWindow>({ pages: initialPages });
  const [isLoading, setIsLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const loadingRef = useRef(false);
  const columnRef = useRef<HTMLElement | null>(null);
  const newerRef = useRef<HTMLDivElement | null>(null);
  const olderRef = useRef<HTMLDivElement | null>(null);

  const loadWindow = async (url: string, direction: "replace" | "newer" | "older") => {
    if (loadingRef.current) return;
    loadingRef.current = true;
    setIsLoading(true);
    setLoadError(null);
    const previousHeight = columnRef.current?.scrollHeight ?? 0;
    try {
      const response = await fetchBootstrap<PageWindow>(url);
      setWindowState((current) => ({
        pages: direction === "replace" ? response.pages
          : direction === "newer" ? [...response.pages, ...current.pages]
            : [...current.pages, ...response.pages],
        newer_cursor: direction === "older" ? current.newer_cursor : response.newer_cursor,
        older_cursor: direction === "newer" ? current.older_cursor : response.older_cursor,
        has_newer: direction === "older" ? current.has_newer : response.has_newer,
        has_older: direction === "newer" ? current.has_older : response.has_older
      }));
      if (direction === "newer") {
        requestAnimationFrame(() => {
          const nextHeight = columnRef.current?.scrollHeight ?? previousHeight;
          window.scrollBy({ top: nextHeight - previousHeight });
        });
      }
    } catch (reason: unknown) {
      setLoadError(reason instanceof Error ? reason.message : "記事を読み込めませんでした");
    } finally {
      loadingRef.current = false;
      setIsLoading(false);
    }
  };

  useEffect(() => {
    const query = new URLSearchParams({ kind });
    if (selectedMonth) query.set("month", selectedMonth);
    void loadWindow(`/api/pages?${query}`, "replace");
  }, [kind, selectedMonth]);

  useEffect(() => {
    const newerTarget = newerRef.current;
    const olderTarget = olderRef.current;
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting || loadingRef.current) continue;
        if (entry.target === newerTarget && windowState.has_newer && windowState.newer_cursor) {
          void loadWindow(`/api/pages?kind=${kind}&after=${encodeURIComponent(windowState.newer_cursor)}`, "newer");
          return;
        }
        if (entry.target === olderTarget && windowState.has_older && windowState.older_cursor) {
          void loadWindow(`/api/pages?kind=${kind}&before=${encodeURIComponent(windowState.older_cursor)}`, "older");
          return;
        }
      }
    }, { rootMargin: "480px 0px" });
    if (newerTarget) observer.observe(newerTarget);
    if (olderTarget) observer.observe(olderTarget);
    return () => observer.disconnect();
  }, [kind, windowState]);

  return (
    <section className={`atlas-split__column atlas-split__${kind}`} aria-label={`${heading}フィード`} aria-busy={isLoading} ref={columnRef}>
      <header><h2>{heading}</h2></header>
      {loadError && <p className="atlas-stream__error" role="alert">{loadError}</p>}
      <div className="atlas-stream__sentinel" ref={newerRef}>
        {!windowState.has_newer && selectedMonth && <span>最新まで表示しています</span>}
      </div>
      {windowState.pages.map((page) => <AtlasEntry page={page} key={page.id} />)}
      <div className="atlas-stream__sentinel" ref={olderRef}>
        {!windowState.has_older && <span>最初まで表示しています</span>}
      </div>
    </section>
  );
}

function SplitFeed({ initialPages, selectedMonth }: { initialPages: HomePage[]; selectedMonth: string | null }) {
  return (
    <div className="atlas-split">
      <FeedColumn
        kind="diary"
        heading="日記"
        initialPages={initialPages.filter((page) => page.is_diary)}
        selectedMonth={selectedMonth}
      />
      <FeedColumn
        kind="article"
        heading="記事"
        initialPages={initialPages.filter((page) => !page.is_diary)}
        selectedMonth={selectedMonth}
      />
    </div>
  );
}

function AtlasHome({ initialWindow, tags, archive, archiveRef, auth }: {
  initialWindow: PageWindow;
  tags: string[];
  archive: NonNullable<HomeBootstrap["archive"]>;
  archiveRef: RefObject<HTMLDivElement | null>;
  auth: AuthState;
}) {
  const [calendarOpen, setCalendarOpen] = useState(() => !window.matchMedia("(max-width: 36rem)").matches);
  const [selectedMonth, setSelectedMonth] = useState<string | null>(null);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 36rem)");
    const update = () => setCalendarOpen(!media.matches);
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  return (
    <div className="home-variant home-variant--atlas">
      <aside className="atlas-rail">
        <HeaderDock />
        <HomeTags tags={tags} fitMobileRows />
        <div className="atlas-calendar" ref={archiveRef}>
          <details
            className="atlas-calendar__details"
            open={calendarOpen}
            onToggle={(event) => setCalendarOpen(event.currentTarget.open)}
          >
            <summary aria-label={calendarOpen ? "年月アーカイブを閉じる" : "年月アーカイブを開く"}>
              <svg className="atlas-calendar__open-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path d="M7 2v3M17 2v3M3.5 9h17M5 4h14a1.5 1.5 0 0 1 1.5 1.5v14A1.5 1.5 0 0 1 19 21H5a1.5 1.5 0 0 1-1.5-1.5v-14A1.5 1.5 0 0 1 5 4Z" />
              </svg>
              <svg className="atlas-calendar__close-icon" viewBox="0 0 24 24" aria-hidden="true">
                <path d="m6 6 12 12M18 6 6 18" />
              </svg>
            </summary>
            <HomeArchive
              years={archive}
              heading=""
              selectedMonth={selectedMonth}
              onSelectMonth={setSelectedMonth}
            />
            <GitHubAuthentication auth={auth} />
          </details>
        </div>
      </aside>
      <section className="atlas-stream" aria-label="記事">
        {initialWindow.pages.length === 0
          ? <p className="empty-home">まだ記事がありません</p>
          : <SplitFeed initialPages={initialWindow.pages} selectedMonth={selectedMonth} />}
      </section>
    </div>
  );
}

function Home({ bootstrap, auth }: { bootstrap: HomeBootstrap; auth: AuthState }) {
  const [tags, setTags] = useState(bootstrap.tags ?? []);
  const [archive, setArchive] = useState(bootstrap.archive ?? []);
  const archiveRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    void fetchBootstrap<{ tags: string[] }>("/api/tags")
      .then((response) => setTags(response.tags))
      .catch(() => setTags([]));
  }, []);

  useEffect(() => {
    const target = archiveRef.current;
    if (!target) return;
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      void fetchBootstrap<{ archive: NonNullable<HomeBootstrap["archive"]> }>("/api/archive")
        .then((response) => setArchive(response.archive))
        .catch(() => setArchive([]));
    }, { rootMargin: "320px 0px" });
    observer.observe(target);
    return () => observer.disconnect();
  }, []);

  return (
    <div className="home-layout">
      <AtlasHome initialWindow={bootstrap} tags={tags} archive={archive} archiveRef={archiveRef} auth={auth} />
    </div>
  );
}

const root = document.querySelector<HTMLElement>("#authoring-root");
const data = document.querySelector<HTMLScriptElement>("#authoring-data");

function start() {
  if (root) {
    const initialBootstrap = data?.textContent ? JSON.parse(data.textContent) as AppBootstrap : undefined;
    createRoot(root).render(<RootApp initialBootstrap={initialBootstrap} initialAuth={DEFAULT_AUTH_STATE} />);
  }
}

start();
