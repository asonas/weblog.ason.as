import { EditorContent, useEditor } from "@tiptap/react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { DraftMetadata } from "./draftSession";
import { autoCoverImageUrl, EDITOR_EXTENSIONS } from "./editor";
import { markdownForEditor } from "./markdown";
import { PublicArticlePresentation } from "./PublicArticlePresentation";

const MEDIA_PATTERN =
  /!\[[^\]]*\]\(|:::video |https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be|speakerdeck\.com|bsky\.app)\//;

function coverImageUrl(body: string, metadata: DraftMetadata): string | null {
  if (metadata.cover_mode === "none") return null;
  if (metadata.cover_mode === "explicit")
    return metadata.cover_image_url || null;
  return autoCoverImageUrl(body);
}

function useOnlineStatus(): boolean {
  const [isOnline, setIsOnline] = useState(() => navigator.onLine);
  useEffect(() => {
    const update = () => setIsOnline(navigator.onLine);
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);
  return isOnline;
}

type DraftPreviewProps = {
  body: string;
  metadata: DraftMetadata;
};

export function DraftPreview({ body, metadata }: DraftPreviewProps) {
  const root = useRef<HTMLDivElement>(null);
  const isOnline = useOnlineStatus();
  const resolvedCoverImageUrl = useMemo(
    () => coverImageUrl(body, metadata),
    [body, metadata],
  );
  const editor = useEditor({
    extensions: EDITOR_EXTENSIONS,
    content: markdownForEditor(body),
    contentType: "markdown",
    editable: false,
    shouldRerenderOnTransaction: false,
    editorProps: {
      attributes: {
        "aria-label": "作業版の本文",
        class: "e-content ProseMirror public-article-body",
      },
    },
  });

  useEffect(() => {
    if (!editor || editor.getMarkdown() === markdownForEditor(body)) return;
    editor.commands.setContent(markdownForEditor(body), {
      contentType: "markdown",
      emitUpdate: false,
    });
  }, [body, editor]);

  useEffect(() => {
    const container = root.current;
    if (!container) return;
    const mediaState = (event: Event) => {
      const media = event.target;
      if (!(media instanceof HTMLElement)) return;
      media
        .closest<HTMLElement>(
          ".article-image, .article-video, .youtube-player, .speakerdeck-player, .bluesky-player",
        )
        ?.setAttribute(
          "data-media-state",
          event.type === "load" ? "ready" : "failed",
        );
    };
    const openPublishedLink = (event: MouseEvent) => {
      const target = event.target;
      if (!(target instanceof Element)) return;
      const link = target.closest<HTMLAnchorElement>("a[href]");
      if (!link) return;
      event.preventDefault();
      window.open(link.href, "_blank", "noopener,noreferrer");
    };
    container.addEventListener("load", mediaState, true);
    container.addEventListener("error", mediaState, true);
    container.addEventListener("click", openPublishedLink);
    return () => {
      container.removeEventListener("load", mediaState, true);
      container.removeEventListener("error", mediaState, true);
      container.removeEventListener("click", openPublishedLink);
    };
  }, []);

  return (
    <div ref={root} className="draft-preview__document">
      <PublicArticlePresentation
        className="draft-preview__article"
        coverImageUrl={resolvedCoverImageUrl}
        title={metadata.title || "無題"}
      >
        <EditorContent editor={editor} />
      </PublicArticlePresentation>
      {!isOnline && MEDIA_PATTERN.test(body) && (
        <p className="draft-preview__offline-media" role="status">
          オフラインのため画像や埋め込みを表示できません。本文の表示は更新されています。
        </p>
      )}
    </div>
  );
}
