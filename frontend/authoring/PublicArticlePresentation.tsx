import type { ReactNode } from "react";

type PublicArticleHeaderProps = {
  coverImageUrl: string | null;
  title: string;
};

export function PublicArticleHeader({
  coverImageUrl,
  title,
}: PublicArticleHeaderProps) {
  return (
    <header
      className={`article-reading-header${coverImageUrl ? " article-reading-header--covered" : ""}`}
    >
      {coverImageUrl && <img src={coverImageUrl} alt="" />}
      <h1>{title}</h1>
    </header>
  );
}

type PublicArticlePresentationProps = PublicArticleHeaderProps & {
  children: ReactNode;
  className?: string;
};

export function PublicArticlePresentation({
  children,
  className = "",
  coverImageUrl,
  title,
}: PublicArticlePresentationProps) {
  return (
    <article
      className={`article-workspace article-workspace--reading ${className}`.trim()}
    >
      <PublicArticleHeader coverImageUrl={coverImageUrl} title={title} />
      <div className="editor-canvas">{children}</div>
    </article>
  );
}
