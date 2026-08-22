import { createRoot } from "react-dom/client";
import { useEffect, useState } from "react";

import { AuthoringEditor, type EditorBootstrap } from "./editor";
import "./styles.css";

const PALETTES = {
  loadmore: { name: "Loadmo.re", background: "#ededed", foreground: "#000000" },
  departure: { name: "Departure Mono", background: "#ffffff", foreground: "#ffa133" },
  orange: { name: "Orange", background: "#ea580c", foreground: "#ffffff" },
  apricot: { name: "Apricot", background: "#ffedd5", foreground: "#9a3412" },
  stone: { name: "Stone", background: "#292524", foreground: "#f5f5f4" },
  sky: { name: "Sky", background: "#e0f2fe", foreground: "#0369a1" },
  cream: { name: "Cream", background: "#fff7ed", foreground: "#7c2d12" },
  teal: { name: "Teal", background: "#ffffff", foreground: "#0d9488" },
  slate: { name: "Slate", background: "#0f172a", foreground: "#f8fafc" }
} as const;

type Palette = keyof typeof PALETTES;

const PALETTE_STORAGE_KEY = "weblog-palette";
const UNIVERSE_STORAGE_KEY = "weblog-universe";

function applyPalette(palette: Palette) {
  document.documentElement.dataset.theme = palette;
  const button = document.querySelector<HTMLButtonElement>("#theme-toggle");
  if (!button) return;

  button.setAttribute("aria-label", `配色を選ぶ。現在は${PALETTES[palette].name}`);
  button.title = `配色を選ぶ。現在は${PALETTES[palette].name}`;
  document.querySelectorAll<HTMLElement>("[data-palette]").forEach((option) => {
    option.setAttribute("aria-checked", String(option.dataset.palette === palette));
  });
}

function setupPaletteToggle() {
  let button = document.querySelector<HTMLButtonElement>("#theme-toggle");
  if (!button) {
    const actions = document.querySelector<HTMLElement>(".header-actions");
    if (actions) {
      button = document.createElement("button");
      button.id = "theme-toggle";
      button.className = "header-action theme-toggle";
      button.type = "button";
      button.textContent = "◐";
      actions.prepend(button);
    }
  }

  if (!button) return;

  const menu = document.createElement("div");
  menu.className = "theme-menu";
  menu.id = "theme-menu";
  menu.role = "menu";
  menu.hidden = true;
  for (const [id, option] of Object.entries(PALETTES) as Array<[Palette, typeof PALETTES[Palette]]>) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "theme-menu__option";
    item.dataset.palette = id;
    item.setAttribute("role", "menuitemradio");
    item.style.setProperty("--palette-background", option.background);
    item.style.setProperty("--palette-foreground", option.foreground);
    item.innerHTML = '<span class="theme-menu__swatch" aria-hidden="true"><i></i><i></i></span>';
    const label = document.createElement("span");
    label.textContent = option.name;
    item.append(label);
    menu.append(item);
  }
  button.after(menu);
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-controls", menu.id);

  const storedPalette = window.localStorage.getItem(PALETTE_STORAGE_KEY);
  let palette: Palette = storedPalette && storedPalette in PALETTES
    ? storedPalette as Palette
    : "departure";
  applyPalette(palette);

  const closeMenu = () => {
    menu.hidden = true;
    button.setAttribute("aria-expanded", "false");
  };
  button.addEventListener("click", () => {
    const willOpen = menu.hidden;
    menu.hidden = !willOpen;
    button.setAttribute("aria-expanded", String(willOpen));
  });
  menu.addEventListener("click", (event) => {
    const option = (event.target as Element).closest<HTMLElement>("[data-palette]");
    const nextPalette = option?.dataset.palette;
    if (!nextPalette || !(nextPalette in PALETTES)) return;
    palette = nextPalette as Palette;
    window.localStorage.setItem(PALETTE_STORAGE_KEY, palette);
    applyPalette(palette);
    closeMenu();
    button.focus();
  });
  document.addEventListener("click", (event) => {
    if (
      event.target instanceof Node &&
      !button.contains(event.target) &&
      !menu.contains(event.target)
    ) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || menu.hidden) return;
    closeMenu();
    button.focus();
  });
}

setupPaletteToggle();

type AuthState = {
  authenticated: boolean;
  authentication_required: boolean;
  can_edit: boolean;
  login: string | null;
  csrf_token: string;
};

async function setupAuthentication() {
  const auth = await fetchBootstrap<AuthState>("/api/auth/session");
  document.documentElement.dataset.canEdit = String(auth.can_edit);
  document.documentElement.dataset.csrfToken = auth.csrf_token;

  document.querySelectorAll<HTMLElement>("#new-page-action, #daily-page-action").forEach((action) => {
    action.hidden = !auth.can_edit;
  });

  const container = document.querySelector<HTMLElement>("#auth-action");
  if (!container) return;
  container.replaceChildren();

  if (auth.authenticated) {
    const form = document.createElement("form");
    form.action = "/api/auth/logout";
    form.method = "post";
    const csrf = document.createElement("input");
    csrf.type = "hidden";
    csrf.name = "csrf_token";
    csrf.value = auth.csrf_token;
    const button = document.createElement("button");
    button.className = "header-auth";
    button.type = "submit";
    button.textContent = `${auth.login || "GitHub"}からログアウト`;
    form.append(csrf, button);
    container.append(form);
    return;
  }

  if (auth.authentication_required) {
    const link = document.createElement("a");
    link.className = "header-auth";
    link.href = `/api/auth/github?${new URLSearchParams({ return_to: window.location.pathname + window.location.search })}`;
    link.textContent = "GitHubでログイン";
    container.append(link);
  }
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

  let enabled = window.localStorage.getItem(UNIVERSE_STORAGE_KEY) === "on";
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
};

type HomeBootstrap = {
  mode: "home";
  tags?: string[];
  pages: HomePage[];
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

function App({ initialBootstrap }: { initialBootstrap?: AppBootstrap }) {
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

  return bootstrap.mode === "home" ? <Home bootstrap={bootstrap} /> : <AuthoringEditor bootstrap={bootstrap} />;
}

function HomePageList({ pages }: { pages: HomePage[] }) {
  return pages.length === 0 ? (
    <p className="empty-home">まだ記事がありません</p>
  ) : (
    <ul className="home-page-list">
      {pages.map((page) => (
        <li className="home-page-card" key={page.id}>
          <a className="home-page-card__link" href={`/${encodeURIComponent(page.route)}`}>
            {page.image_url && (
              <img
                className="home-page-card__image"
                src={page.image_url}
                alt=""
                loading="lazy"
                referrerPolicy="no-referrer"
              />
            )}
            <span className="home-page-card__content">
              <span className="home-page-card__title">{page.title}</span>
              {page.excerpt && <span className="home-page-card__excerpt">{page.excerpt}</span>}
              <time className="home-page-card__date" dateTime={page.created_at}>
                {formatDate(page.created_at)}
              </time>
            </span>
          </a>
        </li>
      ))}
    </ul>
  );
}

function HomeArchive({ years }: { years: NonNullable<HomeBootstrap["archive"]> }) {
  if (years.length === 0) return null;

  return (
    <section className="home-archive" aria-labelledby="archive-heading">
      <h2 id="archive-heading">過去の記事</h2>
      <div className="home-archive__years">
        {years.map(({ year, months }) => (
          <section className="home-archive__year" aria-labelledby={`archive-${year}`} key={year}>
            <h3 id={`archive-${year}`}>{year}</h3>
            <div className="home-archive__months">
              {Array.from({ length: 12 }, (_, index) => index + 1).map((month) => {
                const label = String(month).padStart(2, "0");
                return months.includes(month) ? (
                  <a
                    href={`/${year}${label}`}
                    aria-label={`${year}年${month}月の記事`}
                    key={month}
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

function Home({ bootstrap }: { bootstrap: HomeBootstrap }) {
  const latestPage = bootstrap.pages[0];
  const tags = bootstrap.tags ?? [];
  const archive = bootstrap.archive ?? [];

  return (
    <div className="home-layout">
      <section className="home-intro" aria-label="概要と最近の記事">
        <div className="home-intro__panel home-intro__blank" aria-hidden="true" />
        {latestPage && (
          <a className="home-intro__panel home-intro__latest" href={`/${encodeURIComponent(latestPage.route)}`}>
            <span className="home-intro__label">最近の記事</span>
            <strong>{latestPage.title}</strong>
            {latestPage.excerpt && <span>{latestPage.excerpt}</span>}
          </a>
        )}
      </section>

      {tags.length > 0 && (
        <nav className="home-tags" aria-label="最近更新されたタグ">
          {tags.map((tag) => (
            <a href={`/${encodeURIComponent(tag)}`} key={tag}>{tag}</a>
          ))}
        </nav>
      )}

      <HomePageList pages={bootstrap.pages} />
      <HomeArchive years={archive} />
    </div>
  );
}

const root = document.querySelector<HTMLElement>("#authoring-root");
const data = document.querySelector<HTMLScriptElement>("#authoring-data");

async function start() {
  try {
    await setupAuthentication();
  } catch (_error) {
    document.documentElement.dataset.canEdit = "false";
  }

  if (root) {
    const initialBootstrap = data?.textContent ? JSON.parse(data.textContent) as AppBootstrap : undefined;
    createRoot(root).render(<App initialBootstrap={initialBootstrap} />);
  }
}

void start();
