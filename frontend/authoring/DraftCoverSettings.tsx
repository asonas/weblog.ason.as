import type { JSONContent } from "@tiptap/core";
import { MarkdownManager } from "@tiptap/markdown";
import { useMemo } from "react";
import {
  ARTICLE_PREVIEW_EXTENSIONS,
  autoCoverImageUrl,
} from "./articlePreviewEditor";
import type { DraftSession } from "./draftSession";
import { markdownForEditor } from "./markdown";

const markdown = new MarkdownManager({
  extensions: ARTICLE_PREVIEW_EXTENSIONS,
});

export function bodyCoverImages(
  body: string,
): Array<{ src: string; alt: string }> {
  const images = new Map<string, { src: string; alt: string }>();
  const visit = (node: JSONContent) => {
    if (node.type === "image" && typeof node.attrs?.src === "string") {
      const src = node.attrs.src;
      if (!images.has(src)) images.set(src, { src, alt: node.attrs.alt || "" });
    }
    node.content?.forEach(visit);
  };
  visit(markdown.parse(markdownForEditor(body)));
  return [...images.values()];
}

export function DraftCoverSettings({ session }: { session: DraftSession }) {
  const { metadata } = session;
  const body = session.markdown;
  const images = useMemo(() => bodyCoverImages(body), [body]);
  const firstLocalImage = images.find((image) =>
    /^\/assets\/[^\s]+$/.test(image.src),
  );
  const modes = [
    { value: "auto", label: "自動", description: "本文の最初の画像" },
    { value: "none", label: "なし", description: "タイトルのみ" },
    {
      value: "explicit",
      label: "画像を指定",
      description: "本文の画像から選ぶ",
    },
  ];
  const cover =
    metadata.cover_mode === "auto"
      ? autoCoverImageUrl(body)
      : metadata.cover_mode === "explicit"
        ? metadata.cover_image_url
        : null;
  return (
    <>
      <button
        className="draft-editor__icon-button"
        type="button"
        popoverTarget="draft-cover-settings"
        disabled={session.isPublishing}
        title={`カバー設定（${modes.find((mode) => mode.value === metadata.cover_mode)?.label}）`}
        aria-label="カバー設定"
      >
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <path d="M8.8 2.8h2.4l.5 1.9a6 6 0 0 1 1.2.7l1.9-.5L16 7l-1.4 1.4a6 6 0 0 1 0 1.3L16 11l-1.2 2.1-1.9-.5a6 6 0 0 1-1.2.7l-.5 1.9H8.8l-.5-1.9a6 6 0 0 1-1.2-.7l-1.9.5L4 11l1.4-1.3a6 6 0 0 1 0-1.3L4 7l1.2-2.1 1.9.5a6 6 0 0 1 1.2-.7z" />
          <circle cx="10" cy="9" r="2.2" />
        </svg>
      </button>
      <div
        id="draft-cover-settings"
        className="draft-cover-settings"
        popover="auto"
        role="dialog"
        aria-label="カバー設定"
      >
        <header>
          <h2>カバー</h2>
          <button
            type="button"
            popoverTarget="draft-cover-settings"
            popoverTargetAction="hide"
            aria-label="カバー設定を閉じる"
          >
            閉じる
          </button>
        </header>
        <fieldset>
          <legend className="visually-hidden">カバーの表示方法</legend>
          {modes.map((mode) => (
            <label key={mode.value}>
              <input
                type="radio"
                name="draft-cover-mode"
                value={mode.value}
                checked={metadata.cover_mode === mode.value}
                disabled={
                  session.isPublishing ||
                  (mode.value === "explicit" &&
                    !firstLocalImage &&
                    !metadata.cover_image_url)
                }
                onChange={() =>
                  session.setMetadata(
                    mode.value === "explicit"
                      ? {
                          cover_mode: mode.value,
                          cover_image_url:
                            metadata.cover_image_url ||
                            firstLocalImage?.src ||
                            "",
                        }
                      : { cover_mode: mode.value },
                  )
                }
              />
              <span>
                {mode.label}
                <small>{mode.description}</small>
              </span>
            </label>
          ))}
        </fieldset>
        {!firstLocalImage && !metadata.cover_image_url && (
          <p>
            カバーを指定するには、本文にアップロードした画像を追加してください。
          </p>
        )}
        {metadata.cover_mode === "explicit" && (
          <fieldset className="draft-cover-settings__choices">
            <legend>本文の画像</legend>
            {images.length === 0 && (
              <p>本文に画像を追加すると、ここから選べます。</p>
            )}
            {images.map((image, index) => {
              const isLocal = /^\/assets\/[^\s]+$/.test(image.src);
              const isSelected = metadata.cover_image_url === image.src;
              return (
                <label
                  key={image.src}
                  className="draft-cover-settings__choice"
                  data-selected={isSelected}
                >
                  <input
                    type="radio"
                    name="draft-cover-image"
                    checked={isSelected}
                    disabled={session.isPublishing || !isLocal}
                    onChange={() =>
                      session.setMetadata({ cover_image_url: image.src })
                    }
                    aria-label={`画像${index + 1}${image.alt ? `：${image.alt}` : ""}`}
                  />
                  <span>
                    <img src={image.src} alt={image.alt} loading="lazy" />
                    <small>{isSelected ? "選択中" : `画像${index + 1}`}</small>
                    {!isLocal && (
                      <small>外部画像はカバーに指定できません</small>
                    )}
                  </span>
                </label>
              );
            })}
            {cover && !images.some((image) => image.src === cover) && (
              <p>
                選択中のカバーは本文にありません。変更するには本文の画像を選んでください。
              </p>
            )}
          </fieldset>
        )}
        {cover && (
          <img
            className="draft-cover-settings__image"
            src={cover}
            alt="選択中のカバー"
          />
        )}
      </div>
    </>
  );
}
