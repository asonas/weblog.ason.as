import {
  type KeyboardEvent,
  type RefObject,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
} from "react";
import { createPortal, flushSync } from "react-dom";
import { AuthoringIcon } from "./AuthoringIcon";

type SearchResult = {
  route: string;
  title: string;
  excerpt: string;
  updated_at: string;
};

type SearchState = "idle" | "loading" | "ready" | "error";

async function fetchSearch(
  query: string,
  signal: AbortSignal,
): Promise<SearchResult[]> {
  const params = new URLSearchParams({ q: query, limit: "10" });
  const response = await fetch(`/api/search?${params}`, {
    headers: { Accept: "application/json" },
    signal,
  });
  if (!response.ok) throw new Error("検索結果を読み込めませんでした");
  const body = (await response.json()) as { results: SearchResult[] };
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
          if (error instanceof DOMException && error.name === "AbortError")
            return;
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
  onKeyDown,
}: {
  query: string;
  setQuery: (value: string) => void;
  inputRef?: RefObject<HTMLInputElement | null>;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
}) {
  return (
    <div className="site-search__field">
      <AuthoringIcon name="search" />
      <input
        ref={inputRef}
        type="search"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
        onKeyDown={onKeyDown}
        placeholder="記事を検索"
        aria-label="記事を検索"
      />
      {query && (
        <button
          type="button"
          onClick={() => setQuery("")}
          aria-label="入力を消去"
        >
          <AuthoringIcon name="close" />
        </button>
      )}
    </div>
  );
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
  return (
    <section
      className="site-search__results"
      id={id}
      aria-label="検索結果"
      aria-live="polite"
    >
      {state === "idle" && (
        <p className="site-search__message">キーワードを入力してください</p>
      )}
      {state === "loading" && (
        <p className="site-search__message" role="status">
          検索しています
        </p>
      )}
      {state === "error" && (
        <p className="site-search__message" role="alert">
          検索結果を読み込めませんでした。もう一度お試しください
        </p>
      )}
      {state === "ready" && results.length === 0 && (
        <p className="site-search__message">
          「{query.trim()}」に一致する記事はありません
        </p>
      )}
      {results.map((result) => (
        <a href={`/${encodeURIComponent(result.route)}`} key={result.route}>
          <strong>{result.title}</strong>
          {result.excerpt && <span>{result.excerpt}</span>}
        </a>
      ))}
    </section>
  );
}

function SearchContents({
  query,
  setQuery,
  results,
  state,
  inputRef,
  showResults = true,
  showAllResultsLink = false,
}: {
  query: string;
  setQuery: (value: string) => void;
  results: SearchResult[];
  state: SearchState;
  inputRef?: RefObject<HTMLInputElement | null>;
  showResults?: boolean;
  showAllResultsLink?: boolean;
}) {
  const resultId = useId();

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" && query.trim()) {
      event.preventDefault();
      window.location.assign(searchPageUrl(query));
    }
  };

  return (
    <>
      <SearchField
        query={query}
        setQuery={setQuery}
        inputRef={inputRef}
        onKeyDown={onKeyDown}
      />
      {showResults && (
        <div className="site-search__panel">
          <SearchResults
            id={resultId}
            query={query}
            results={results}
            state={state}
          />
          {showAllResultsLink && query.trim() && (
            <a className="site-search__all" href={searchPageUrl(query)}>
              <span>検索結果ページへ</span>
              <span aria-hidden="true">→</span>
            </a>
          )}
        </div>
      )}
    </>
  );
}

export function SiteSearch({ initialQuery = "" }: { initialQuery?: string }) {
  const [desktopOpen, setDesktopOpen] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [query, setQuery] = useState(initialQuery);
  const search = useSearch(query);
  const desktopRef = useRef<HTMLDivElement>(null);
  const mobileInputRef = useRef<HTMLInputElement>(null);
  const mobileButtonRef = useRef<HTMLButtonElement>(null);
  const backdropRef = useRef<HTMLDivElement>(null);
  const closeMobile = useCallback(() => {
    setMobileOpen(false);
    window.setTimeout(
      () => mobileButtonRef.current?.focus({ preventScroll: true }),
      0,
    );
  }, []);

  useEffect(() => {
    const close = (event: PointerEvent) => {
      if (
        event.target instanceof Node &&
        !desktopRef.current?.contains(event.target)
      )
        setDesktopOpen(false);
    };
    const openAfterKeyboardFocus = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Tab") return;
      window.setTimeout(() => {
        if (desktopRef.current?.contains(document.activeElement))
          setDesktopOpen(true);
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
    if (!mobileOpen) return;
    const viewport = window.visualViewport;
    const resize = () =>
      document.documentElement.style.setProperty(
        "--search-viewport-height",
        `${viewport?.height ?? window.innerHeight}px`,
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
    const inertTargets = Array.from(document.body.children).filter(
      (element): element is HTMLElement =>
        element instanceof HTMLElement &&
        element !== backdropRef.current &&
        !element.hasAttribute("inert"),
    );
    inertTargets.forEach((target) => {
      target.setAttribute("inert", "");
    });
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const close = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") closeMobile();
      if (event.key === "Tab") {
        const controls = backdropRef.current?.querySelectorAll<HTMLElement>(
          "input, button, a[href]",
        );
        const first = controls?.[0];
        const last = controls?.[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }
    };
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("keydown", close);
      inertTargets.forEach((target) => {
        target.removeAttribute("inert");
      });
      document.body.style.overflow = previousOverflow;
    };
  }, [mobileOpen, closeMobile]);

  return (
    <div className="site-search">
      {/* The wrapper coordinates pointer and focus state for the nested search controls. */}
      {/* biome-ignore lint/a11y/useSemanticElements: keep the broadly supported div with an explicit landmark */}
      <div
        className={`site-search__desktop${desktopOpen ? " is-open" : ""}`}
        ref={desktopRef}
        role="search"
        onPointerDown={() => setDesktopOpen(true)}
        onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget))
            setDesktopOpen(false);
        }}
      >
        <div>
          <SearchContents
            query={query}
            setQuery={setQuery}
            showResults={desktopOpen}
            showAllResultsLink
            {...search}
          />
        </div>
      </div>
      <button
        ref={mobileButtonRef}
        className="site-search__mobile-button"
        type="button"
        onClick={() => {
          flushSync(() => setMobileOpen(true));
          mobileInputRef.current?.focus({ preventScroll: true });
        }}
        aria-label="記事を検索"
        disabled={mobileOpen}
      >
        <AuthoringIcon name="search" />
      </button>
      {mobileOpen &&
        createPortal(
          <div
            ref={backdropRef}
            className="site-search__backdrop"
            onPointerDown={closeMobile}
          >
            <section
              className="site-search__sheet"
              role="dialog"
              aria-modal="true"
              aria-label="記事を検索"
              onPointerDown={(event) => event.stopPropagation()}
            >
              <div className="site-search__handle" aria-hidden="true" />
              <div className="site-search__sheet-header">
                <div>
                  <SearchContents
                    query={query}
                    setQuery={setQuery}
                    inputRef={mobileInputRef}
                    {...search}
                  />
                </div>
                <button type="button" onClick={closeMobile}>
                  閉じる
                </button>
              </div>
            </section>
          </div>,
          document.body,
        )}
    </div>
  );
}

export function SearchPage() {
  const [query, setQuery] = useState(
    () => new URLSearchParams(window.location.search).get("q") || "",
  );
  const search = useSearch(query);
  return (
    <section className="search-page">
      <h1>記事を検索</h1>
      <SearchContents query={query} setQuery={setQuery} {...search} />
    </section>
  );
}
