import { useId, useLayoutEffect, useRef, useState } from "react";

const EMPTY_TAGS: string[] = [];

export function HomeTags({
  tags = EMPTY_TAGS,
  status = "loading",
}: {
  tags?: string[];
  status?: "loading" | "ready" | "error";
}) {
  const id = useId();
  const listRef = useRef<HTMLDivElement>(null);
  const [isExpanded, setIsExpanded] = useState(false);
  const [overflowTags, setOverflowTags] = useState<string[]>([]);
  useLayoutEffect(() => {
    const list = listRef.current;
    if (!list) return;
    const measure = () => {
      const links = [...list.querySelectorAll<HTMLAnchorElement>("a")];
      const rows = [...new Set(links.map((link) => link.offsetTop))].sort(
        (a, b) => a - b,
      );
      setOverflowTags(
        window.matchMedia("(max-width: 600px)").matches
          ? []
          : tags.filter(
              (_, index) =>
                (links[index]?.offsetTop ?? 0) >= (rows[3] ?? Infinity),
            ),
      );
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(list);
    for (const link of list.querySelectorAll("a")) observer.observe(link);
    return () => observer.disconnect();
  }, [tags]);
  return (
    <nav
      className="card-home__tags"
      aria-label="最近更新されたタグ"
      aria-busy={status === "loading"}
    >
      <div
        className="card-home__tag-list"
        id={id}
        ref={listRef}
        data-expanded={isExpanded}
      >
        {status !== "ready" || !tags.length ? (
          <p className="card-home__tags-message" role="status">
            {status === "loading"
              ? "タグを読み込み中…"
              : status === "error"
                ? "タグを読み込めませんでした。"
                : "まだタグはありません。"}
          </p>
        ) : (
          [
            tags.slice(0, Math.ceil(tags.length / 2)),
            tags.slice(Math.ceil(tags.length / 2)),
          ].map((items, row) => (
            <div
              className="card-home__tag-row"
              key={row === 0 ? "first" : "second"}
            >
              {items.map((tag) => (
                <a
                  href={`/${encodeURIComponent(tag)}`}
                  key={tag}
                  style={{
                    visibility:
                      !isExpanded && overflowTags.includes(tag)
                        ? "hidden"
                        : undefined,
                  }}
                >
                  {tag}
                </a>
              ))}
            </div>
          ))
        )}
      </div>
      <div className="card-home__tag-disclosure">
        {overflowTags.length > 0 && (
          <button
            type="button"
            aria-expanded={isExpanded}
            aria-controls={id}
            onClick={() => setIsExpanded(!isExpanded)}
          >
            {isExpanded ? "折りたたむ" : "すべて表示"}
          </button>
        )}
      </div>
    </nav>
  );
}
