import type { RefObject } from "react";
import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { createRoot } from "react-dom/client";
import { CardHome, type HomePage } from "./CardHome";
import { DesignSystemPage } from "./designSystem";
import { AuthoringEditor, type EditorBootstrap } from "./editor";
import { startAuthoringPerformanceTelemetry } from "./performanceTelemetry";
import { SearchPage, SiteSearch } from "./search";
import { WebmentionModerationPage } from "./webmentions";
import "./styles.css";
import "./universeGraph.css";

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
  csrf_token: "",
};

async function setupAuthentication(): Promise<AuthState> {
  const auth = await fetchBootstrap<AuthState>("/api/auth/session");
  document.documentElement.dataset.canEdit = String(auth.can_edit);
  document.documentElement.dataset.csrfToken = auth.csrf_token;

  document
    .querySelectorAll<HTMLElement>("#new-page-action, #daily-page-action")
    .forEach((action) => {
      action.hidden = !auth.can_edit;
    });
  const webmentionsAction = document.querySelector<HTMLElement>(
    "#webmentions-action",
  );
  if (webmentionsAction) webmentionsAction.hidden = !auth.can_edit;
  return auth;
}

function setupPublicHeader() {
  const update = () => {
    document.documentElement.dataset.headerScrolled = String(
      window.scrollY > 8,
    );
  };
  update();
  window.addEventListener("scroll", update, { passive: true });
}

document.documentElement.dataset.universe = "on";
setupPublicHeader();

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

export function HeaderSearch() {
  const navigation = document.querySelector<HTMLElement>(
    ".site-header .header-nav",
  );
  return navigation ? createPortal(<SiteSearch />, navigation) : null;
}

type AppBootstrap = (EditorBootstrap & { mode: "editor" }) | HomeBootstrap;

type EditorViewMode = "editing" | "reading";

declare const __BUILD_SHA__: string;
declare const __DEPLOYMENT_ENVIRONMENT__: string;

function AuthoringTelemetry({ auth, body }: { auth: AuthState; body: string }) {
  useEffect(() => {
    if (!auth.can_edit || !auth.csrf_token) return;
    if (
      __DEPLOYMENT_ENVIRONMENT__ !== "production" &&
      new URLSearchParams(window.location.search).get("telemetry") === "off"
    )
      return;
    return startAuthoringPerformanceTelemetry({
      body,
      csrfToken: auth.csrf_token,
      environment: __DEPLOYMENT_ENVIRONMENT__,
      serviceVersion: __BUILD_SHA__,
    });
  }, [auth.can_edit, auth.csrf_token, body]);
  return null;
}

function tokyoDate(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const value = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value || "";
  return `${value("year")}-${value("month")}-${value("day")}`;
}

export function editorViewMode({
  bootstrap,
  canEdit,
  pathname,
  search,
  now = new Date(),
}: {
  bootstrap: EditorBootstrap;
  canEdit: boolean;
  pathname: string;
  search: string;
  now?: Date;
}): EditorViewMode {
  if (!canEdit) return "reading";
  if (!bootstrap.page_id) return "editing";
  if (pathname === "/editor/new" || pathname.startsWith("/editor/"))
    return "editing";
  if (new URLSearchParams(search).get("view") === "reading") return "reading";
  const today = tokyoDate(now);
  if (
    (bootstrap.page_type === "date" && bootstrap.date === today) ||
    (bootstrap.page_type === "named" && bootstrap.name === today)
  )
    return "editing";
  return "reading";
}

function pageRoute(bootstrap: EditorBootstrap): string {
  return bootstrap.name || bootstrap.date || bootstrap.title;
}

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function fetchBootstrap<T>(url: string): Promise<T> {
  let response: Response;
  try {
    response = await fetch(url, { headers: { Accept: "application/json" } });
  } catch (_error) {
    throw new Error(
      "APIに接続できません。Sinatraを127.0.0.1:8000で起動してください",
    );
  }

  const responseText = await response.text();
  let raw: unknown;
  try {
    raw = JSON.parse(responseText);
  } catch (_error) {
    throw new Error(
      `APIからJSONではない応答が返されました（HTTP ${response.status}）`,
    );
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    throw new Error(
      typeof result.error === "string"
        ? result.error
        : "ページを読み込めませんでした",
    );
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
    if (pageId && !pageId.includes("/"))
      return `/api/pages/${encodeURIComponent(pageId)}`;
  }

  const route = path.slice(1).replace(/\/$/, "");
  if (route && !route.includes("/")) return `/api/routes/${route}`;

  throw new Error("対応していないページです");
}

function App({
  initialBootstrap,
  auth,
}: {
  initialBootstrap?: AppBootstrap;
  auth: AuthState;
}) {
  const [bootstrap, setBootstrap] = useState<AppBootstrap | null>(
    initialBootstrap || null,
  );
  const [error, setError] = useState<string | null>(null);
  const [requestVersion, setRequestVersion] = useState(0);

  useEffect(() => {
    if (initialBootstrap) return;
    void requestVersion;

    let active = true;
    void fetchBootstrap<AppBootstrap>(routeBootstrapUrl())
      .then((nextBootstrap) => {
        if (active) setBootstrap(nextBootstrap);
      })
      .catch((reason: unknown) => {
        if (active)
          setError(
            reason instanceof Error
              ? reason.message
              : "ページを読み込めませんでした",
          );
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
    return (
      <p className="loading-state" role="status">
        記事を読み込んでいます
      </p>
    );
  }

  if (bootstrap.mode === "home")
    return <Home bootstrap={bootstrap} auth={auth} />;

  const viewMode = editorViewMode({
    bootstrap,
    canEdit: auth.can_edit,
    pathname: window.location.pathname,
    search: window.location.search,
  });
  const route = pageRoute(bootstrap);
  const isTodaysDiary =
    bootstrap.page_type === "date" && bootstrap.date === tokyoDate(new Date());
  const readingHref = `/${encodeURIComponent(route)}${isTodaysDiary ? "?view=reading" : ""}`;
  const editingHref = isTodaysDiary
    ? `/${encodeURIComponent(route)}`
    : `/editor/${encodeURIComponent(bootstrap.page_id)}`;

  return (
    <>
      <HeaderSearch />
      {viewMode === "editing" && (
        <AuthoringTelemetry auth={auth} body={bootstrap.body} />
      )}
      <AuthoringEditor
        key={viewMode}
        bootstrap={bootstrap}
        canEdit={viewMode === "editing"}
        canSwitchToEdit={auth.can_edit && Boolean(bootstrap.page_id)}
        editingHref={editingHref}
        readingHref={readingHref}
      />
    </>
  );
}

function RootApp({
  initialBootstrap,
  initialAuth,
}: {
  initialBootstrap?: AppBootstrap;
  initialAuth: AuthState;
}) {
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

  if (window.location.pathname === "/search") {
    return (
      <>
        <HeaderSearch />
        <SearchPage />
      </>
    );
  }
  if (window.location.pathname === "/authoring/webmentions") {
    return (
      <>
        <HeaderSearch />
        <WebmentionModerationPage canEdit={auth.can_edit} />
      </>
    );
  }
  return <App initialBootstrap={initialBootstrap} auth={auth} />;
}

function GitHubAuthentication({ auth }: { auth: AuthState }) {
  if (!auth.authentication_required) return null;

  const icon = (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 .7a11.5 11.5 0 0 0-3.64 22.41c.58.11.79-.25.79-.56v-2.23c-3.22.7-3.9-1.37-3.9-1.37-.53-1.34-1.29-1.7-1.29-1.7-1.05-.72.08-.71.08-.71 1.17.08 1.78 1.2 1.78 1.2 1.04 1.78 2.72 1.27 3.38.97.1-.75.4-1.27.74-1.56-2.57-.29-5.27-1.29-5.27-5.68 0-1.26.45-2.28 1.2-3.09-.12-.29-.52-1.47.11-3.05 0 0 .98-.31 3.16 1.18A11 11 0 0 1 12 6.12c.98 0 1.95.13 2.86.39 2.2-1.49 3.17-1.18 3.17-1.18.63 1.58.23 2.76.11 3.05.75.81 1.2 1.83 1.2 3.09 0 4.4-2.71 5.38-5.29 5.67.42.36.79 1.06.79 2.14v3.27c0 .31.21.68.8.56A11.5 11.5 0 0 0 12 .7Z" />
    </svg>
  );

  if (auth.authenticated) {
    return (
      <form className="home-auth" action="/api/auth/logout" method="post">
        <input type="hidden" name="csrf_token" value={auth.csrf_token} />
        <button
          type="submit"
          aria-label={`${auth.login || "GitHub"}からログアウト`}
          title="GitHubからログアウト"
        >
          {icon}
        </button>
      </form>
    );
  }

  const query = new URLSearchParams({
    return_to: window.location.pathname + window.location.search,
  });
  return (
    <div className="home-auth">
      <a
        href={`/api/auth/github?${query}`}
        aria-label="GitHubでログイン"
        title="GitHubでログイン"
      >
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
      <h1>
        <a href="/">weblog.ason.as</a>
      </h1>
      <div className="atlas-header__actions" ref={actionsDockRef}>
        <a className="card-home__about" href="/about">
          このサイトについて
        </a>
      </div>
      <div className="atlas-header__search">
        <SiteSearch />
      </div>
    </div>
  );
}

export function CoverJournalHome({
  initialWindow,
  tags,
  archive,
  archiveRef,
  auth,
}: {
  initialWindow: Pick<HomeBootstrap, "pages">;
  tags: string[];
  archive: NonNullable<HomeBootstrap["archive"]>;
  archiveRef: RefObject<HTMLDivElement | null>;
  auth: AuthState;
}) {
  return (
    <CardHome
      initialPages={initialWindow.pages}
      tags={tags}
      archive={archive}
      archiveRef={archiveRef}
      header={<HeaderDock />}
      authentication={<GitHubAuthentication auth={auth} />}
    />
  );
}

function Home({
  bootstrap,
  auth,
}: {
  bootstrap: HomeBootstrap;
  auth: AuthState;
}) {
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
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        void fetchBootstrap<{ archive: NonNullable<HomeBootstrap["archive"]> }>(
          "/api/archive",
        )
          .then((response) => setArchive(response.archive))
          .catch(() => setArchive([]));
      },
      { rootMargin: "320px 0px" },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, []);

  return (
    <div className="home-layout">
      <CoverJournalHome
        initialWindow={bootstrap}
        tags={tags}
        archive={archive}
        archiveRef={archiveRef}
        auth={auth}
      />
    </div>
  );
}

const root = document.querySelector<HTMLElement>("#authoring-root");
const data = document.querySelector<HTMLScriptElement>("#authoring-data");

function start() {
  if (root) {
    if (import.meta.env.DEV && window.location.pathname === "/design-system") {
      document.documentElement.dataset.view = "design-system";
      document.title = "Design system · weblog.ason.as";
      createRoot(root).render(<DesignSystemPage />);
      return;
    }
    const initialBootstrap = data?.textContent
      ? (JSON.parse(data.textContent) as AppBootstrap)
      : undefined;
    createRoot(root).render(
      <RootApp
        initialBootstrap={initialBootstrap}
        initialAuth={DEFAULT_AUTH_STATE}
      />,
    );
  }
}

start();
