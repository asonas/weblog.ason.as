import type { HomePage } from "./CardHome";
import { CoverPhoto } from "./CoverPhoto";
import { GeneratedCover } from "./GeneratedCover";
import "./homeCards.css";

export function HomeCardsSkeleton() {
  return (
    <div className="cf-grid home-loading__cards" aria-hidden="true">
      {["first", "second", "third", "fourth", "fifth", "sixth"].map((card) => (
        <div className="home-loading__card" key={card}>
          <div className="home-loading__card-media cf-media">
            <div className="cf-cover-caption">
              <span className="cf-category home-loading__category home-loading__shimmer" />
              <div className="cf-title home-loading__card-title">
                <span className="home-loading__shimmer" />
                <span className="home-loading__shimmer" />
              </div>
            </div>
          </div>
          <div className="cf-copy home-loading__card-copy">
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
                  <div className="cf-cover-caption">
                    <span
                      className="cf-category"
                      data-kind={page.is_diary ? "diary" : "article"}
                    >
                      {page.is_diary ? "日記" : "記事"}
                    </span>
                    <h2 className="cf-title">
                      {page.is_diary ? (
                        <time dateTime={page.route}>{page.title}</time>
                      ) : (
                        page.title
                      )}
                    </h2>
                  </div>
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
