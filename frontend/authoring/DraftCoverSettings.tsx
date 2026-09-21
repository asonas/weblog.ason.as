import type { DraftSession } from "./draftSession";
import { autoCoverImageUrl } from "./editor";

export function DraftCoverSettings({ session }: { session: DraftSession }) {
  const { metadata } = session;
  const modes = [
    { value: "auto", label: "自動", description: "本文の最初の画像" },
    { value: "none", label: "なし", description: "タイトルのみ" },
    { value: "explicit", label: "画像を指定", description: "本文とは別に選ぶ" },
  ];
  const cover =
    metadata.cover_mode === "auto"
      ? autoCoverImageUrl(session.body.toString())
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
                disabled={session.isPublishing}
                onChange={() => session.setMetadata({ cover_mode: mode.value })}
              />
              <span>
                {mode.label}
                <small>{mode.description}</small>
              </span>
            </label>
          ))}
        </fieldset>
        {metadata.cover_mode === "explicit" && (
          <label>
            カバー画像のURL
            <input
              aria-label="カバー画像のパス"
              value={metadata.cover_image_url || ""}
              placeholder="/assets/uploads/…"
              disabled={session.isPublishing}
              onChange={(event) =>
                session.setMetadata({ cover_image_url: event.target.value })
              }
            />
          </label>
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
