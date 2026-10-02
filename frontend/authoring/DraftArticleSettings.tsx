import { useRef, useState } from "react";
import { AuthoringIcon } from "./AuthoringIcon";
import { DraftCoverSettings } from "./DraftCoverSettings";
import type { DraftSession } from "./draftSession";

export function DraftArticleSettings({
  session,
  onDownload,
  onDelete,
}: {
  session: DraftSession;
  onDownload: () => void;
  onDelete?: () => Promise<void>;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const [error, setError] = useState("");
  return (
    <>
      <button
        className="draft-editor__icon-button"
        type="button"
        title="記事の設定"
        aria-label="記事の設定"
        aria-haspopup="dialog"
        onClick={() => dialog.current?.showModal()}
      >
        <svg viewBox="0 0 20 20" aria-hidden="true">
          <path d="M8.8 2.8h2.4l.5 1.9a6 6 0 0 1 1.2.7l1.9-.5L16 7l-1.4 1.4a6 6 0 0 1 0 1.3L16 11l-1.2 2.1-1.9-.5a6 6 0 0 1-1.2.7l-.5 1.9H8.8l-.5-1.9a6 6 0 0 1-1.2-.7l-1.9.5L4 11l1.4-1.3a6 6 0 0 1 0-1.3L4 7l1.2-2.1 1.9.5a6 6 0 0 1 1.2-.7z" />
          <circle cx="10" cy="9" r="2.2" />
        </svg>
      </button>
      <dialog
        ref={dialog}
        className="draft-article-settings"
        aria-labelledby="draft-settings-heading"
      >
        <header>
          <h2 id="draft-settings-heading">記事の設定</h2>
          <button
            type="button"
            aria-label="記事の設定を閉じる"
            onClick={() => dialog.current?.close()}
          >
            閉じる
          </button>
        </header>
        <DraftCoverSettings session={session} />
        <section aria-labelledby="draft-download-heading">
          <h3 id="draft-download-heading">本文のダウンロード</h3>
          <button type="button" onClick={onDownload}>
            <svg viewBox="0 0 20 20" aria-hidden="true">
              <path d="M10 3.5v9m0 0L6.5 9M10 12.5 13.5 9M4 15.5h12" />
            </svg>
            Markdownをダウンロード
          </button>
        </section>
        {onDelete && (
          <section aria-labelledby="draft-delete-heading">
            <h3 id="draft-delete-heading">下書きの削除</h3>
            <p>この下書き全体を削除します。削除した内容は元に戻せません。</p>
            <button
              className="draft-editor__delete"
              type="button"
              disabled={session.isPublishing}
              onClick={() => {
                setError("");
                void onDelete().catch((failure: unknown) =>
                  setError(
                    failure instanceof Error
                      ? failure.message
                      : "削除できませんでした",
                  ),
                );
              }}
            >
              <AuthoringIcon name="trash" />
              未公開の下書きを削除
            </button>
            {error && <p role="alert">{error}</p>}
          </section>
        )}
      </dialog>
    </>
  );
}
