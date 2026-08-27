import { useEffect, useId, useRef, useState, type KeyboardEvent, type RefObject } from "react";

export type SearchResult = {
  route: string;
  title: string;
  excerpt: string;
  updated_at: string;
};

type SearchState = "idle" | "loading" | "ready" | "error";

async function fetchSearch(query: string, signal: AbortSignal): Promise<SearchResult[]> {
  const params = new URLSearchParams({ q: query, limit: "10" });
  const response = await fetch(`/api/search?${params}`, {
    headers: { Accept: "application/json" },
    signal
  });
  if (!response.ok) throw new Error("検索結果を読み込めませんでした");
  const body = await response.json() as { results: SearchResult[] };
  return body.results;
}

function useSearch(query: string) {
  const [results, setResults] = useState<SearchResult[]>([]);
  const [state, setState] = useState<SearchState>("idle");

  useEffect(() => {
    const normalized = query.trim();
    if (!normalized) {
      setResults([]);
      setState("idle");
      return;
    }
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      setState("loading");
      void fetchSearch(normalized, controller.signal)
        .then((nextResults) => {
          setResults(nextResults);
          setState("ready");
        })
        .catch((error: unknown) => {
          if (error instanceof DOMException && error.name === "AbortError") return;
          setResults([]);
          setState("error");
        });
    }, 180);
    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [query]);

  return { results, state };
}

function searchPageUrl(query: string) {
  return `/search?${new URLSearchParams({ q: query.trim() })}`;
}

function SearchField({
  query,
  setQuery,
  inputRef,
  onKeyDown
}: {
  query: string;
  setQuery: (value: string) => void;
  inputRef?: RefObject<HTMLInputElement | null>;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
}) {
  return <label className="site-search__field">
    <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/></svg>
    <input
      ref={inputRef}
      type="search"
      value={query}
      onChange={(event) => setQuery(event.target.value)}
      onKeyDown={onKeyDown}
      placeholder="記事を検索"
      aria-label="記事を検索"
    />
    {query && <button type="button" onClick={() => setQuery("")} aria-label="入力を消去">×</button>}
  </label>;
}

function SearchResults({
  id,
  query,
  results,
  state,
}: {
  id: string;
  query: string;
  results: SearchResult[];
  state: SearchState;
}) {
  return <div className="site-search__results" id={id} aria-label="検索結果" aria-live="polite">
    {state === "idle" && <p className="site-search__message">キーワードを入力してください</p>}
    {state === "loading" && <p className="site-search__message" role="status">検索しています</p>}
    {state === "error" && <p className="site-search__message" role="alert">検索結果を読み込めませんでした。もう一度お試しください</p>}
    {state === "ready" && results.length === 0 && <p className="site-search__message">「{query.trim()}」に一致する記事はありません</p>}
    {results.map((result) => <a
      href={`/${encodeURIComponent(result.route)}`}
      key={result.route}
    >
      <strong>{result.title}</strong>
      {result.excerpt && <span>{result.excerpt}</span>}
    </a>)}
  </div>;
}

function SearchContents({ query, setQuery, results, state, inputRef, showResults = true }: {
  query: string;
  setQuery: (value: string) => void;
  results: SearchResult[];
  state: SearchState;
  inputRef?: RefObject<HTMLInputElement | null>;
  showResults?: boolean;
}) {
  const resultId = useId();

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" && query.trim()) {
      event.preventDefault();
      window.location.assign(searchPageUrl(query));
    }
  };

  return <>
    <SearchField query={query} setQuery={setQuery} inputRef={inputRef} onKeyDown={onKeyDown} />
    {showResults && <SearchResults id={resultId} query={query} results={results} state={state} />}
  </>;
}

export function SiteSearch({ initialQuery = "" }: { initialQuery?: string }) {
  const [desktopOpen, setDesktopOpen] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [query, setQuery] = useState(initialQuery);
  const search = useSearch(query);
  const desktopRef = useRef<HTMLDivElement>(null);
  const mobileInputRef = useRef<HTMLInputElement>(null);
  const mobileButtonRef = useRef<HTMLButtonElement>(null);
  const closeMobile = () => {
    setMobileOpen(false);
    window.setTimeout(() => mobileButtonRef.current?.focus(), 0);
  };

  useEffect(() => {
    const close = (event: PointerEvent) => {
      if (event.target instanceof Node && !desktopRef.current?.contains(event.target)) setDesktopOpen(false);
    };
    const openAfterKeyboardFocus = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Tab") return;
      window.setTimeout(() => {
        if (desktopRef.current?.contains(document.activeElement)) setDesktopOpen(true);
      }, 0);
    };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keyup", openAfterKeyboardFocus);
    return () => {
      document.removeEventListener("pointerdown", close);
      document.removeEventListener("keyup", openAfterKeyboardFocus);
    };
  }, []);
  useEffect(() => {
    if (mobileOpen) mobileInputRef.current?.focus();
  }, [mobileOpen]);
  useEffect(() => {
    if (!mobileOpen) return;
    const viewport = window.visualViewport;
    const resize = () => document.documentElement.style.setProperty(
      "--search-viewport-height",
      `${viewport?.height ?? window.innerHeight}px`
    );
    resize();
    viewport?.addEventListener("resize", resize);
    return () => {
      viewport?.removeEventListener("resize", resize);
      document.documentElement.style.removeProperty("--search-viewport-height");
    };
  }, [mobileOpen]);
  useEffect(() => {
    if (!mobileOpen) return;
    const main = document.querySelector<HTMLElement>("#main");
    const navigation = document.querySelector<HTMLElement>(".header-nav");
    const searchRoot = mobileButtonRef.current?.closest<HTMLElement>(".site-search");
    const inertTargets: HTMLElement[] = [];
    if (main && searchRoot && main.contains(searchRoot)) {
      let current: HTMLElement | null = searchRoot;
      while (current && current !== main) {
        const parent: HTMLElement | null = current.parentElement;
        if (!parent) break;
        Array.from(parent.children).forEach((sibling) => {
          if (sibling !== current && sibling instanceof HTMLElement) inertTargets.push(sibling);
        });
        current = parent;
      }
    } else if (main) {
      inertTargets.push(main);
    }
    inertTargets.forEach((target) => target.setAttribute("inert", ""));
    navigation?.setAttribute("inert", "");
    document.body.style.overflow = "hidden";
    const close = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") closeMobile();
    };
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("keydown", close);
      inertTargets.forEach((target) => target.removeAttribute("inert"));
      navigation?.removeAttribute("inert");
      document.body.style.removeProperty("overflow");
    };
  }, [mobileOpen]);

  return <div className="site-search">
    <div
      className={`site-search__desktop${desktopOpen ? " is-open" : ""}`}
      ref={desktopRef}
      onPointerDown={() => setDesktopOpen(true)}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setDesktopOpen(false);
      }}
    >
      <div>
        <SearchContents query={query} setQuery={setQuery} showResults={desktopOpen} {...search} />
      </div>
      {desktopOpen && query.trim() && <a className="site-search__all" href={searchPageUrl(query)}>すべての検索結果を表示</a>}
    </div>
    <button ref={mobileButtonRef} className="site-search__mobile-button" type="button" onClick={() => setMobileOpen(true)} aria-label="記事を検索" disabled={mobileOpen}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m16 16 4 4"/></svg>
    </button>
    {mobileOpen && <div className="site-search__backdrop" onPointerDown={closeMobile}>
      <section className="site-search__sheet" role="dialog" aria-modal="true" aria-label="記事を検索" onPointerDown={(event) => event.stopPropagation()}>
        <div className="site-search__handle" aria-hidden="true" />
        <div className="site-search__sheet-header">
          <div><SearchContents query={query} setQuery={setQuery} inputRef={mobileInputRef} {...search} /></div>
          <button type="button" onClick={closeMobile}>閉じる</button>
        </div>
      </section>
    </div>}
  </div>;
}

export function SearchPage() {
  const [query, setQuery] = useState(() => new URLSearchParams(window.location.search).get("q") || "");
  const search = useSearch(query);
  return <section className="search-page">
    <h1>記事を検索</h1>
    <SearchContents query={query} setQuery={setQuery} {...search} />
  </section>;
}
