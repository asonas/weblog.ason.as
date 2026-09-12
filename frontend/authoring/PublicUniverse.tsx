import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { DiaryNavigation } from "./DiaryNavigation";
import { SiteSearch } from "./search";
import { UniverseGraph } from "./UniverseGraph";

type Page = {
  id: string;
  route: string;
  title: string;
  excerpt: string;
  created_at: string;
  image_url: string | null;
  related_by: string[];
  related_urls?: string[];
};
type Article = { id: string; route: string; wiki: string[]; urls: string[] };

export function PublicUniverse({ article }: { article: Article }) {
  const [pages, setPages] = useState<Page[]>([]);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const pending = useRef(false);
  const loadMore = useCallback(async () => {
    if (pending.current || !hasMore) return;
    pending.current = true;
    setLoading(true);
    setError("");
    try {
      const query = new URLSearchParams({
        route: article.route,
        excluding_id: article.id,
        offset: String(pages.length),
      });
      const response = await fetch(`/api/related?${query}`, {
        signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw new Error("関連する記事を読み込めませんでした");
      const result: { pages: Page[]; has_more: boolean } =
        await response.json();
      setPages((current) => [...current, ...result.pages]);
      setHasMore(result.has_more);
    } catch {
      setError("関連する記事を読み込めませんでした");
    } finally {
      pending.current = false;
      setLoading(false);
    }
  }, [article.route, article.id, pages.length, hasMore]);
  useEffect(() => {
    if (pages.length === 0) void loadMore();
  }, [loadMore, pages.length]);
  const names = article.wiki.filter((name) => name !== article.route);
  if (pages.some((page) => page.related_by.includes(article.route)))
    names.unshift(article.route);
  const groups = [
    ...names.map((name) => ({
      kind: "wiki" as const,
      name,
      pages: pages.filter(
        (page) => page.related_by.includes(name) && page.route !== name,
      ),
    })),
    ...article.urls.map((name) => ({
      kind: "url" as const,
      name,
      pages: pages.filter((page) => page.related_urls?.includes(name)),
    })),
  ];
  return (
    <UniverseGraph
      route={article.route}
      groups={groups}
      pages={pages}
      hasMore={hasMore}
      loading={loading}
      error={error}
      loadMore={() => void loadMore()}
    />
  );
}

export function mountPublicReader() {
  const navigation = document.querySelector(".header-nav");
  if (navigation) {
    const search = document.createElement("div");
    search.style.display = "contents";
    navigation.append(search);
    createRoot(search).render(<SiteSearch />);
    document.querySelector("#public-search-fallback")?.remove();
  }
  const container = document.querySelector<HTMLElement>(
    "[data-public-universe]",
  );
  if (!container?.dataset.publicUniverse) return;
  const article: Article = JSON.parse(container.dataset.publicUniverse);
  if (/^\d{4}-\d{2}-\d{2}$/.test(article.route)) {
    const body = container.closest("article")?.querySelector(".editor-canvas");
    if (body) {
      const diaryNavigation = document.createElement("div");
      body.after(diaryNavigation);
      createRoot(diaryNavigation).render(
        <DiaryNavigation route={article.route} />,
      );
    }
  }
  const mount = () =>
    createRoot(container).render(<PublicUniverse article={article} />);
  if (!("IntersectionObserver" in window)) {
    mount();
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      mount();
    },
    { rootMargin: "600px" },
  );
  observer.observe(container);
}
