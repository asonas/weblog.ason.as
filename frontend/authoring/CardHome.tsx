import {
  type ReactNode,
  type RefObject,
  useEffect,
  useRef,
  useState,
} from "react";
import { CoverPhoto } from "./CoverPhoto";
import { HomeCards } from "./HomeCards";
import "./cardHome.css";

export type HomePage = {
  id: string;
  title: string;
  route: string;
  created_at: string;
  updated_at: string;
  excerpt: string;
  image_url: string | null;
  is_diary: boolean;
};
type PageWindow = {
  pages: HomePage[];
  newer_cursor?: string | null;
  older_cursor?: string | null;
  has_newer?: boolean;
  has_older?: boolean;
};

export function CardHome({
  initialPages,
  tags,
  tagsStatus = "ready",
  archive,
  archiveRef,
  header,
  authentication,
}: {
  initialPages: HomePage[];
  tags: string[];
  tagsStatus?: "loading" | "ready" | "error";
  archive: Array<{ year: number; months: number[] }>;
  archiveRef: RefObject<HTMLDivElement | null>;
  header: ReactNode;
  authentication: ReactNode;
}) {
  const [query, setQuery] = useState(
    () => new URLSearchParams(window.location.search),
  );
  const [feed, setFeed] = useState<PageWindow>({ pages: [] });
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  const contentRef = useRef<HTMLElement | null>(null);
  const shouldFocus = useRef(false);
  const month = query.get("month");
  const featured =
    initialPages.find((page) => page.image_url) ?? initialPages[0];

  function navigate(next: URLSearchParams) {
    window.history.pushState(null, "", `/${next.size ? `?${next}` : ""}`);
    shouldFocus.current = true;
    setQuery(next);
  }
  useEffect(() => {
    const back = () => {
      shouldFocus.current = true;
      setQuery(new URLSearchParams(window.location.search));
    };
    window.addEventListener("popstate", back);
    return () => window.removeEventListener("popstate", back);
  }, []);
  useEffect(() => {
    void retry;
    const controller = new AbortController();
    const params = new URLSearchParams({ kind: "timeline" });
    for (const name of ["month", "before", "after"]) {
      const value = query.get(name);
      if (value) params.set(name, value);
    }
    setIsLoading(true);
    setError("");
    async function load() {
      try {
        const response = await fetch(`/api/pages?${params}`, {
          signal: controller.signal,
        });
        if (!response.ok) throw new Error("記事を読み込めませんでした。");
        const result: PageWindow = await response.json();
        if (!controller.signal.aborted) setFeed(result);
      } catch (reason) {
        if (!controller.signal.aborted)
          setError(
            reason instanceof Error
              ? reason.message
              : "記事を読み込めませんでした。",
          );
      } finally {
        if (!controller.signal.aborted) setIsLoading(false);
      }
    }
    void load();
    return () => controller.abort();
  }, [query, retry]);
  useEffect(() => {
    if (isLoading || !shouldFocus.current) return;
    shouldFocus.current = false;
    contentRef.current?.focus({ preventScroll: true });
    contentRef.current?.scrollIntoView({ block: "start" });
  }, [isLoading]);

  function turnPage(direction: "before" | "after", cursor: string) {
    const next = new URLSearchParams();
    if (month) next.set("month", month);
    next.set(direction, cursor);
    navigate(next);
  }

  return (
    <div className="cover-journal card-home" id="home-top">
      <header
        className="cover-journal__hero"
        data-has-cover={String(Boolean(featured?.image_url))}
      >
        {featured?.image_url && <CoverPhoto url={featured.image_url} hero />}
        {header}
        {featured && (
          <div className="cover-journal__lead">
            <strong>
              <a href={`/${encodeURIComponent(featured.route)}`}>
                {featured.title}
              </a>
            </strong>
            {featured.excerpt && <small>{featured.excerpt}</small>}
          </div>
        )}
      </header>
      <nav
        className="card-home__tags"
        aria-label="最近更新されたタグ"
        aria-busy={tagsStatus === "loading"}
      >
        {tagsStatus === "loading" ? (
          <>
            <span className="visually-hidden" role="status">
              タグを読み込んでいます…
            </span>
            {[0, 1].map((row) => (
              <div className="card-home__tag-row" aria-hidden="true" key={row}>
                {[180, 72, 104, 224, 136, 88, 160, 112].map((width) => (
                  <span
                    className="card-home__tag-skeleton"
                    style={{ width }}
                    key={width}
                  />
                ))}
              </div>
            ))}
          </>
        ) : tags.length ? (
          [
            { name: "first", items: tags.slice(0, Math.ceil(tags.length / 2)) },
            { name: "second", items: tags.slice(Math.ceil(tags.length / 2)) },
          ].map(({ name, items }) => (
            <div className="card-home__tag-row" key={name}>
              {items.map((tag) => (
                <a href={`/${encodeURIComponent(tag)}`} key={tag}>
                  {tag}
                </a>
              ))}
            </div>
          ))
        ) : (
          <p className="card-home__tags-message">
            {tagsStatus === "error"
              ? "タグを読み込めませんでした。"
              : "まだタグはありません。"}
          </p>
        )}
      </nav>
      <section
        className="card-home__content"
        id="home-posts"
        ref={contentRef}
        tabIndex={-1}
        aria-label="新しい順の日記と記事"
        aria-busy={isLoading}
      >
        {month && (
          <div className="card-home__month">
            <h2>{month.replace(/^(\d{4})-0?(\d+)$/, "$1年$2月")}</h2>
            <a
              href="/"
              onClick={(event) => {
                if (
                  event.button ||
                  event.metaKey ||
                  event.ctrlKey ||
                  event.shiftKey ||
                  event.altKey
                )
                  return;
                event.preventDefault();
                navigate(new URLSearchParams());
              }}
            >
              最新に戻る
            </a>
          </div>
        )}
        {isLoading ? (
          <p role="status">読み込んでいます…</p>
        ) : error ? (
          <div role="alert">
            <p>{error}</p>
            <button
              type="button"
              onClick={() => setRetry((value) => value + 1)}
            >
              再読み込み
            </button>
          </div>
        ) : (
          <>
            <HomeCards entries={feed.pages} />
            {!feed.pages.length && (
              <p>
                {month
                  ? "この月の投稿はありません。"
                  : "まだ投稿がありません。"}
              </p>
            )}
          </>
        )}
        <nav className="card-home__paging" aria-label="一覧のページ切り替え">
          <button
            type="button"
            disabled={
              isLoading || !!error || !feed.has_newer || !feed.newer_cursor
            }
            onClick={() =>
              feed.newer_cursor && turnPage("after", feed.newer_cursor)
            }
          >
            ← 新しい投稿
          </button>
          <button
            type="button"
            disabled={
              isLoading || !!error || !feed.has_older || !feed.older_cursor
            }
            onClick={() =>
              feed.older_cursor && turnPage("before", feed.older_cursor)
            }
          >
            古い投稿 →
          </button>
        </nav>
      </section>
      <footer className="card-home__footer" id="home-calendar">
        <div className="card-home__footer-heading">
          <h2>過去の記事</h2>
          <a href="#home-top">ページの先頭へ ↑</a>
        </div>
        <div className="card-home__years" ref={archiveRef}>
          {archive.map(({ year, months }, index) => (
            <details
              key={`${year}-${month ?? "latest"}`}
              open={index === 0 || !!month?.startsWith(`${year}-`)}
            >
              <summary>
                {year}
                <span>年</span>
              </summary>
              <div className="card-home__months">
                {Array.from({ length: 12 }, (_, i) => i + 1).map((value) => {
                  const key = `${year}-${String(value).padStart(2, "0")}`;
                  return months.includes(value) ? (
                    <a
                      key={value}
                      href={`/?month=${key}`}
                      aria-label={`${year}年${value}月の記事`}
                      aria-current={month === key ? "date" : undefined}
                      onClick={(event) => {
                        if (
                          event.button ||
                          event.metaKey ||
                          event.ctrlKey ||
                          event.shiftKey ||
                          event.altKey
                        )
                          return;
                        event.preventDefault();
                        navigate(new URLSearchParams({ month: key }));
                      }}
                    >
                      {String(value).padStart(2, "0")}
                      <small>月</small>
                    </a>
                  ) : (
                    <span key={value}>
                      {String(value).padStart(2, "0")}
                      <small>月</small>
                    </span>
                  );
                })}
              </div>
            </details>
          ))}
        </div>
        <div className="card-home__colophon">
          <span>weblog.ason.as</span>
          <a href="/about">このサイトについて</a>
          <a href="/feed.xml">RSS</a>
          {authentication}
        </div>
      </footer>
    </div>
  );
}
