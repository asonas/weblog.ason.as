import { EditorContent, useEditor } from "@tiptap/react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { DraftMetadata } from "./draftSession";
import { autoCoverImageUrl, EDITOR_EXTENSIONS, LineUpdateRail } from "./editor";
import { markdownForEditor } from "./markdown";
import { PublicArticlePresentation } from "./PublicArticlePresentation";

const MEDIA_PATTERN =
  /!\[[^\]]*\]\(|:::video |https?:\/\/(?:www\.)?(?:youtube\.com|youtu\.be|speakerdeck\.com|bsky\.app|x\.com|twitter\.com)\//;

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
  pageNames: Array<string>;
  sourceBlockIndex: number;
};

export function DraftPreview({
  body,
  metadata,
  pageNames,
  sourceBlockIndex,
}: DraftPreviewProps) {
  const root = useRef<HTMLDivElement>(null);
  const navigation = useRef<HTMLDivElement>(null);
  const isOnline = useOnlineStatus();
  useEffect(() => {
    const header = document.querySelector<HTMLElement>("body > .site-header");
    const host = navigation.current;
    if (!header || !host) return;
    const next = header.nextSibling;
    host.append(header);
    return () => {
      document.body.insertBefore(header, next);
    };
  }, []);
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

  // biome-ignore lint/correctness/useExhaustiveDependencies: body replacement updates the editor DOM before link state is applied.
  useEffect(() => {
    const container = root.current;
    if (!container) return;
    const names = new Set(pageNames);
    const wikiLinkNames = new Set(
      Array.from(body.matchAll(/\[\[([^[\]\n]+)\]\]/g), (match) =>
        match[1].trim(),
      ),
    );
    for (const link of container.querySelectorAll<HTMLAnchorElement>(
      '.public-article-body a[href^="/"]',
    )) {
      const name = decodeURIComponent(link.pathname.slice(1));
      if (!wikiLinkNames.has(name)) continue;
      link.classList.add("wiki-link");
      link.classList.toggle("wiki-link--existing", names.has(name));
      link.classList.toggle("wiki-link--missing", !names.has(name));
    }
  }, [body, editor, pageNames]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: body replacement updates block geometry before scroll synchronization.
  useEffect(() => {
    const container = root.current;
    const scroller = container?.closest<HTMLElement>(".draft-preview");
    const blocks = container?.querySelectorAll<HTMLElement>(
      ".public-article-body > *",
    );
    if (!container || !scroller || !blocks || blocks.length === 0) return;
    const target = blocks[Math.min(sourceBlockIndex, blocks.length - 1)];
    const scrollerRect = scroller.getBoundingClientRect();
    const targetRect = target.getBoundingClientRect();
    scroller.scrollTop += targetRect.top - scrollerRect.top - 24;
  }, [body, editor, sourceBlockIndex]);

  useEffect(() => {
    const container = root.current;
    if (!container) return;
    const mediaState = (event: Event) => {
      const media = event.target;
      if (!(media instanceof HTMLElement)) return;
      media
        .closest<HTMLElement>(
          ".article-image, .article-video, .youtube-player, .speakerdeck-player, .bluesky-player, .x-post",
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
      <div ref={navigation} />
      <PublicArticlePresentation
        className="draft-preview__article"
        coverImageUrl={resolvedCoverImageUrl}
        title={
          metadata.title.trim() ||
          (metadata.page_type === "date" && metadata.page_date) ||
          "無題"
        }
      >
        <div className="editor-shell">
          <LineUpdateRail
            body={body}
            editor={editor}
            updates={[]}
            includesTitle={false}
          />
          <EditorContent editor={editor} />
        </div>
      </PublicArticlePresentation>
      {!isOnline && MEDIA_PATTERN.test(body) && (
        <p className="draft-preview__offline-media" role="status">
          オフラインのため画像や埋め込みを表示できません。本文の表示は更新されています。
        </p>
      )}
    </div>
  );
}
