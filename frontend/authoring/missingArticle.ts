export async function redirectMissingArticle(
  location: Pick<Location, "pathname" | "replace">,
  fetcher: typeof fetch = fetch,
) {
  const route = location.pathname.slice(1).replace(/\/$/, "");
  if (!route || route.includes("/") || route === "404.html") return;

  try {
    const title = decodeURIComponent(route);
    const response = await fetcher("/api/auth/session", {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) return;
    const auth: unknown = await response.json();
    if (
      typeof auth !== "object" ||
      auth === null ||
      !("can_edit" in auth) ||
      auth.can_edit !== true
    )
      return;
    location.replace(`/draft-editor?${new URLSearchParams({ title })}`);
  } catch {
    // Keep the public 404 readable when authentication is unavailable.
  }
}

if (typeof window !== "undefined") {
  void showMentionedTopic().then((shown) => {
    if (!shown) void redirectMissingArticle(window.location);
  });
}

async function showMentionedTopic(): Promise<boolean> {
  try {
    const route = decodeURIComponent(
      window.location.pathname.slice(1).replace(/\/$/, ""),
    );
    if (!route || route.includes("/") || route === "404.html") return false;
    const response = await fetch(
      `/api/mentioned-by-days?${new URLSearchParams({ route })}`,
      { cache: "no-store" },
    );
    if (!response.ok) return false;
    const mentions: MentionedDays = await response.json();
    if (!mentions.days.length) return false;
    const main = document.querySelector("main");
    if (!main) return false;
    const article = document.createElement("article");
    article.className = "article-workspace article-workspace--reading";
    article.dataset.editingHref = `/draft-editor?${new URLSearchParams({ title: route })}`;
    const heading = document.createElement("header");
    heading.className = "article-reading-header";
    const title = document.createElement("h1");
    title.textContent = route;
    heading.append(title);
    const canvas = document.createElement("div");
    canvas.className = "editor-canvas";
    const universe = document.createElement("div");
    universe.dataset.publicUniverse = JSON.stringify({
      route,
      id: "",
      wiki: [],
      urls: [],
    });
    article.append(heading, canvas, universe);
    main.replaceChildren(article);
    main.id = "main";
    main.className = "page-shell";
    document.title = `${route} | weblog.ason.as`;
    const header = document.createElement("header");
    header.className = "site-header";
    header.innerHTML =
      '<nav class="header-nav" aria-label="主要ナビゲーション"><a href="/">weblog.ason.as</a><span class="header-actions"></span></nav>';
    main.before(header);
    document.body.style.maxWidth = "none";
    document.body.style.margin = "0";
    document.body.style.padding = "0";
    await import("./publicArticle.css");
    const { enhancePublicArticle, enhancePublicArticleEditing } = await import(
      "./publicArticle"
    );
    article.dataset.publicArticle = "1";
    void enhancePublicArticleEditing(article);
    mountMentionedByDays(article, enhancePublicArticle, fetch, mentions);
    return true;
  } catch {
    return false;
  }
}

import { type MentionedDays, mountMentionedByDays } from "./mentionedByDays";
