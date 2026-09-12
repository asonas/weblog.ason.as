import type { HomePage } from "./CardHome";
import { CoverPhoto } from "./CoverPhoto";
import { GeneratedCover } from "./GeneratedCover";
import "./homeCards.css";

export function HomeCardsSkeleton() {
  return (
    <div className="home-loading__cards" aria-hidden="true">
      {["first", "second", "third", "fourth", "fifth", "sixth"].map((card) => (
        <div className="home-loading__card" key={card}>
          <div className="home-loading__shimmer home-loading__card-media" />
          <div className="home-loading__card-copy">
            <span className="home-loading__shimmer home-loading__card-line home-loading__card-line--long" />
            <span className="home-loading__shimmer home-loading__card-line" />
            <span className="home-loading__shimmer home-loading__card-line home-loading__card-line--short" />
          </div>
        </div>
      ))}
    </div>
  );
}

export function HomeCards({ entries }: { entries: HomePage[] }) {
  return (
    <section className="cf" aria-label="新しい順の日記と記事">
      <div className="cf-grid">
        {entries.map((page) => {
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
                    <GeneratedCover />
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
