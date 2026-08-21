import { createRoot } from "react-dom/client";
import { useEffect, useState } from "react";

import { AuthoringEditor, type EditorBootstrap } from "./editor";
import "./styles.css";

type Palette = "loadmore" | "departure";

const PALETTE_STORAGE_KEY = "weblog-palette";
const UNIVERSE_STORAGE_KEY = "weblog-universe";

function applyPalette(palette: Palette) {
  document.documentElement.dataset.theme = palette;
  const button = document.querySelector<HTMLButtonElement>("#theme-toggle");
  if (!button) return;

  const nextName = palette === "departure" ? "loadmo.re" : "Departure Mono";
  button.setAttribute("aria-label", `${nextName}の配色に切り替える`);
  button.title = `${nextName}の配色に切り替える`;
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

  const storedPalette = window.localStorage.getItem(PALETTE_STORAGE_KEY);
  let palette: Palette = storedPalette === "loadmore" ? "loadmore" : "departure";
  applyPalette(palette);

  button?.addEventListener("click", () => {
    palette = palette === "departure" ? "loadmore" : "departure";
    window.localStorage.setItem(PALETTE_STORAGE_KEY, palette);
    applyPalette(palette);
  });
}

setupPaletteToggle();

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
      <section className="home-intro" aria-labelledby="home-heading">
        <div className="home-intro__panel">
          <p className="home-intro__label">weblog</p>
          <h1 id="home-heading">思考と日々の記録を、つながりのまま残す。</h1>
          <p>日記、制作のメモ、見つけたものをひとつの場所に書き留めています。</p>
        </div>
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

if (root) {
  const initialBootstrap = data?.textContent ? JSON.parse(data.textContent) as AppBootstrap : undefined;
  createRoot(root).render(<App initialBootstrap={initialBootstrap} />);
}
