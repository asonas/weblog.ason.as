import { createRoot } from "react-dom/client";
import { useEffect, useState } from "react";

import { AuthoringEditor, type EditorBootstrap } from "./editor";
import "./styles.css";

type HomePage = {
  id: string;
  title: string;
  route: string;
  updated_at: string;
};

type HomeBootstrap = {
  mode: "home";
  pages: HomePage[];
};

type AppBootstrap = (EditorBootstrap & { mode: "editor" }) | HomeBootstrap;

function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function fetchBootstrap<T>(url: string): Promise<T> {
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    throw new Error(typeof result.error === "string" ? result.error : "ページを読み込めませんでした");
  }

  return raw as T;
}

function routeBootstrapUrl(): string {
  const path = window.location.pathname;
  if (path === "/") return "/api/pages";
  if (path === "/editor/new") return `/api/editor/new${window.location.search}`;

  const prefix = "/editor/";
  if (path.startsWith(prefix)) {
    const pageId = path.slice(prefix.length).replace(/\/$/, "");
    if (pageId && !pageId.includes("/")) return `/api/pages/${encodeURIComponent(pageId)}`;
  }

  throw new Error("対応していないページです");
}

function App({ initialBootstrap }: { initialBootstrap?: AppBootstrap }) {
  const [bootstrap, setBootstrap] = useState<AppBootstrap | null>(initialBootstrap || null);
  const [error, setError] = useState<string | null>(null);

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
  }, [initialBootstrap]);

  if (error) return <p role="alert">{error}</p>;
  if (!bootstrap) return <p role="status">読み込み中…</p>;

  return bootstrap.mode === "home" ? <Home bootstrap={bootstrap} /> : <AuthoringEditor bootstrap={bootstrap} />;
}

function HomePageList({ pages }: { pages: HomePage[] }) {
  return pages.length === 0 ? (
    <p className="empty-home">まだ記事がありません</p>
  ) : (
    <ul className="home-page-list">
      {pages.map((page) => (
        <li key={page.id}>
          <a href={`/editor/${encodeURIComponent(page.id)}`}>{page.title}</a>
        </li>
      ))}
    </ul>
  );
}

function Home({ bootstrap }: { bootstrap: HomeBootstrap }) {
  return (
    <>
      <div className="home-heading">
        <h1>記事</h1>
        <a className="new-page-button" href="/editor/new" aria-label="新しい記事を作成">＋</a>
      </div>
      <HomePageList pages={bootstrap.pages} />
    </>
  );
}

const root = document.querySelector<HTMLElement>("#authoring-root");
const data = document.querySelector<HTMLScriptElement>("#authoring-data");

if (root) {
  const initialBootstrap = data?.textContent ? JSON.parse(data.textContent) as AppBootstrap : undefined;
  createRoot(root).render(<App initialBootstrap={initialBootstrap} />);
}
