import type { CSSProperties } from "react";
import type { HomePage } from "./CardHome";
import { CoverPhoto } from "./CoverPhoto";
import { coverPalettes } from "./coverPalettes";
import "./homeCards.css";

export function HomeCards({ entries }: { entries: HomePage[] }) {
  return (
    <section className="cf" aria-label="新しい順の日記と記事">
      <div className="cf-grid">
        {entries.map((page) => {
          const seed = [...page.id].reduce(
            (value, char) => value + char.charCodeAt(0),
            0,
          );
          const palette =
            coverPalettes[page.id] ??
            Object.values(coverPalettes)[
              seed % Object.keys(coverPalettes).length
            ];
          const coverStyle: CSSProperties & Record<`--cf-${string}`, string> = {
            "--cf-color-a": palette[0],
            "--cf-color-b": palette[1],
            "--cf-x": `${15 + (seed % 45)}%`,
            "--cf-y": `${10 + (seed % 35)}%`,
          };
          const missingCoverMarker = !page.image_url && (
            <span className="cf-empty-marker" aria-hidden="true">
              <svg
                aria-hidden="true"
                viewBox="0 0 32 32"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M12 5h13a2 2 0 0 1 2 2v13M5 12v13a2 2 0 0 0 2 2h13M5 5l22 22" />
                <path d="m7 24 6-7 4 4M21 15l4 5" />
                <circle cx="21" cy="10" r="2" />
              </svg>
            </span>
          );
          return (
            <article className="cf-card" key={page.id}>
              <a
                href={`/${encodeURIComponent(page.route)}`}
                aria-label={`${page.is_diary ? "日記" : "記事"}：${page.title}${page.image_url ? "" : "。カバー画像なし"}`}
              >
                <div className="cf-media">
                  {page.image_url ? (
                    <CoverPhoto url={page.image_url} />
                  ) : (
                    <div
                      className="cf-generated"
                      style={coverStyle}
                      aria-hidden="true"
                      data-palette-source="https://randoma11y.com/"
                    />
                  )}
                  {missingCoverMarker}
                  <h2 className="cf-title">
                    {page.is_diary ? (
                      <time dateTime={page.route}>{page.title}</time>
                    ) : (
                      page.title
                    )}
                  </h2>
                </div>
                <div className="cf-copy">
                  <p>
                    {page.excerpt
                      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
                      .replace(/(^|\s)#{1,6}\s/g, " ")}
                  </p>
                </div>
              </a>
            </article>
          );
        })}
      </div>
    </section>
  );
}
