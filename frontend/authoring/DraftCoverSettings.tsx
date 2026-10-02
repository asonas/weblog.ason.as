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
    <section
      className="draft-cover-settings"
      aria-labelledby="draft-cover-heading"
    >
      <h3 id="draft-cover-heading">カバー画像</h3>
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
                  {!isLocal && <small>外部画像はカバーに指定できません</small>}
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
    </section>
  );
}
