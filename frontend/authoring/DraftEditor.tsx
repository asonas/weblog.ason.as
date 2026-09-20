import { useEffect, useRef, useState } from "react";
import * as Y from "yjs";
import { DraftCoverSettings } from "./DraftCoverSettings";
import { DraftInbox } from "./DraftInbox";
import { DraftNavigation } from "./DraftNavigation";
import { DraftOfflineStatus } from "./DraftOfflineStatus";
import { DraftPreview } from "./DraftPreview";
import {
  DRAFT_BODY_LIMIT,
  type DraftMetadata,
  DraftSession,
  type PublicationConfirmation,
} from "./draftSession";
import "./draftEditor.css";

const FIELD_LABELS: Record<keyof DraftMetadata, string> = {
  title: "タイトル",
  page_type: "記事種別",
  page_date: "日記の日付（URL）",
  cover_mode: "カバー",
  cover_image_url: "カバー画像のパス",
};

export function DraftEditor({ csrf }: { csrf: () => Promise<string> }) {
  const [session, setSession] = useState<DraftSession>();
  const [inboxHeight, setInboxHeight] = useState(320);
  const [loadError, setLoadError] = useState("");
  const [isPreviewOpen, setIsPreviewOpen] = useState(false);
  const [confirmation, setConfirmation] = useState<PublicationConfirmation>();
  const [publicationError, setPublicationError] = useState("");
  const [, refresh] = useState(0);
  const textarea = useRef<HTMLTextAreaElement>(null);
  const [{ id, isNew }] = useState(() => {
    const url = new URL(window.location.href);
    const isNew =
      !url.searchParams.has("id") || url.searchParams.get("recovery") === "1";
    const id = url.searchParams.get("id") || crypto.randomUUID();
    url.searchParams.set("id", id);
    window.history.replaceState(null, "", url);
    return { id, isNew };
  });
  const recoveryKey = `draft-recovery:${id}`;
  useEffect(() => {
    document.documentElement.dataset.draftWorkspace = "true";
    return () => {
      delete document.documentElement.dataset.draftWorkspace;
    };
  }, []);

  useEffect(() => {
    let isActive = true;
    let opened: DraftSession | undefined;
    void DraftSession.open(id, csrf, isNew)
      .then((value) => {
        const recovery = sessionStorage.getItem(recoveryKey);
        if (recovery) {
          const parsed = JSON.parse(recovery) as {
            body: string;
            metadata: DraftMetadata;
          };
          value.setBody(parsed.body);
          value.setMetadata(parsed.metadata);
          sessionStorage.removeItem(recoveryKey);
          const url = new URL(window.location.href);
          url.searchParams.delete("recovery");
          window.history.replaceState(null, "", url);
        }
        opened = value;
        if (isActive) setSession(value);
        else value.close();
      })
      .catch((error: unknown) => {
        if (isActive)
          setLoadError(
            error instanceof Error ? error.message : "下書きを開けませんでした",
          );
      });
    return () => {
      isActive = false;
      opened?.close();
    };
  }, [id, isNew, recoveryKey, csrf]);

  useEffect(() => {
    const field = textarea.current;
    if (!session || !field) return;
    field.value = session.body.toString();
    let isComposing = false;
    let selection = {
      start: Y.createRelativePositionFromTypeIndex(session.body, 0),
      end: Y.createRelativePositionFromTypeIndex(session.body, 0),
      direction: field.selectionDirection,
    };
    const remember = () => {
      selection = {
        start: Y.createRelativePositionFromTypeIndex(
          session.body,
          field.selectionStart,
        ),
        end: Y.createRelativePositionFromTypeIndex(
          session.body,
          field.selectionEnd,
        ),
        direction: field.selectionDirection,
      };
    };
    const show = () => {
      if (!isComposing && field.value !== session.body.toString()) {
        const scroll = field.scrollTop;
        field.value = session.body.toString();
        const start =
          Y.createAbsolutePositionFromRelativePosition(
            selection.start,
            session.doc,
          )?.index ?? 0;
        const end =
          Y.createAbsolutePositionFromRelativePosition(
            selection.end,
            session.doc,
          )?.index ?? start;
        field.setSelectionRange(start, end, selection.direction);
        field.scrollTop = scroll;
      }
      refresh((value) => value + 1);
    };
    const input = () => {
      if (!isComposing) session.setBody(field.value);
    };
    const startComposition = () => {
      isComposing = true;
      session.setComposing(true);
    };
    const endComposition = () => {
      isComposing = false;
      input();
      session.setComposing(false);
    };
    const keydown = (event: KeyboardEvent) => {
      if (
        event.isComposing ||
        isComposing ||
        !(event.metaKey || event.ctrlKey) ||
        event.altKey
      )
        return;
      if (event.key.toLowerCase() === "z") {
        event.preventDefault();
        if (event.shiftKey) session.undo.redo();
        else session.undo.undo();
      } else if (event.ctrlKey && event.key.toLowerCase() === "y") {
        event.preventDefault();
        session.undo.redo();
      }
    };
    const beforeinput = (event: InputEvent) => {
      if (
        event.inputType === "historyUndo" ||
        event.inputType === "historyRedo"
      ) {
        event.preventDefault();
        if (event.inputType === "historyUndo") session.undo.undo();
        else session.undo.redo();
      }
    };
    const beforeUnload = (event: BeforeUnloadEvent) => {
      if (isComposing || session.localStatus !== "端末に保存済み")
        event.preventDefault();
    };
    session.doc.on("beforeTransaction", remember);
    session.addEventListener("change", show);
    field.addEventListener("input", input);
    field.addEventListener("beforeinput", beforeinput);
    field.addEventListener("keydown", keydown);
    field.addEventListener("compositionstart", startComposition);
    field.addEventListener("compositionend", endComposition);
    window.addEventListener("beforeunload", beforeUnload);
    return () => {
      session.doc.off("beforeTransaction", remember);
      session.removeEventListener("change", show);
      field.removeEventListener("input", input);
      field.removeEventListener("beforeinput", beforeinput);
      field.removeEventListener("keydown", keydown);
      field.removeEventListener("compositionstart", startComposition);
      field.removeEventListener("compositionend", endComposition);
      window.removeEventListener("beforeunload", beforeUnload);
    };
  }, [session]);

  function exportMarkdown() {
    const blob = new Blob(
      [textarea.current?.value || session?.body.toString() || ""],
      { type: "text/markdown;charset=utf-8" },
    );
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `draft-${id}.md`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function preparePublication() {
    if (!session) return;
    setPublicationError("");
    try {
      setConfirmation(await session.preparePublication());
    } catch (error) {
      setPublicationError(
        error instanceof Error ? error.message : "公開の準備に失敗しました",
      );
    }
  }

  async function publish() {
    if (!session) return;
    const confirmed = confirmation;
    setConfirmation(undefined);
    setPublicationError("");
    try {
      await session.publish(confirmed);
    } catch (error) {
      setPublicationError(
        error instanceof Error ? error.message : "公開に失敗しました",
      );
    }
  }

  function recoverAsNewDraft() {
    if (!session) return;
    const nextId = crypto.randomUUID();
    sessionStorage.setItem(
      `draft-recovery:${nextId}`,
      JSON.stringify({
        body: textarea.current?.value || session.body.toString(),
        metadata: session.metadata,
      }),
    );
    window.location.assign(`/draft-editor?id=${nextId}&recovery=1`);
  }

  const bytes = new TextEncoder().encode(session?.body.toString() || "").length;
  return (
    <section className="draft-editor" aria-label="下書き編集">
      <DraftNavigation />
      <div className="draft-editor__titlebar">
        <label className="visually-hidden" htmlFor="draft-title">
          タイトル
        </label>
        <input
          id="draft-title"
          placeholder="タイトル"
          value={session?.metadata.title || ""}
          disabled={!session || session.isPublishing}
          onChange={(event) =>
            session?.setMetadata({
              title: event.target.value,
              ...(session.metadata.page_type !== "date" ||
              (session.metadata.page_date &&
                session.metadata.title === session.metadata.page_date)
                ? {
                    page_type: /^\d{4}-\d{2}-\d{2}$/.test(
                      event.target.value.trim(),
                    )
                      ? "date"
                      : "named",
                    page_date: /^\d{4}-\d{2}-\d{2}$/.test(
                      event.target.value.trim(),
                    )
                      ? event.target.value.trim()
                      : "",
                  }
                : {}),
            })
          }
        />
        <button
          type="button"
          disabled={!session || session.isPublishing}
          onClick={() =>
            void (session?.pendingPublication
              ? publish()
              : preparePublication())
          }
        >
          {session?.pendingPublication
            ? "公開を再試行"
            : session?.isPublishing
              ? "公開内容を確認中"
              : "公開"}
        </button>
      </div>
      <div className="draft-editor__status">
        {session && <DraftCoverSettings session={session} />}
        {session?.metadata.page_type === "date" && (
          <label className="draft-editor__date">
            日付URL
            <input
              type="date"
              aria-label="日記の日付（URL）"
              value={
                session.metadata.page_date ||
                (/^\d{4}-\d{2}-\d{2}$/.test(session.metadata.title)
                  ? session.metadata.title
                  : "")
              }
              disabled={session.isPublishing}
              onChange={(event) =>
                session.setMetadata({ page_date: event.target.value })
              }
            />
          </label>
        )}
        <p id="draft-size">
          {bytes >= DRAFT_BODY_LIMIT * 0.9
            ? `本文 ${Math.ceil(bytes / 1024)} / 512 KiB。上限を超えても本文は削除されません。`
            : ""}
        </p>
        <p role="status">
          {session
            ? `${session.localStatus} · ${session.serverStatus}${session.publicationStatus ? ` · ${session.publicationStatus}` : ""}`
            : "読み込み中"}
        </p>
        <p role="alert">{loadError || publicationError || session?.error}</p>
        {session?.pendingOutputs && (
          <button
            type="button"
            disabled={session.isRetryingOutputs}
            onClick={() => void session.retryOutputs()}
          >
            {session.isRetryingOutputs
              ? "公開後の更新を再試行中"
              : "公開後の更新を再試行"}
          </button>
        )}

        {session?.metadataConflicts.map(({ field, local, remote, source }) => (
          <fieldset key={field} className="draft-editor__conflict">
            <legend>{FIELD_LABELS[field]}の競合</legend>
            <p>
              別の編集で同じ項目が変更されました。残す値を選んでください。本文と未送信の変更は端末に保持しています。
            </p>
            <p>この端末: {local || "（未設定）"}</p>
            <p>
              {source === "tab" ? "別タブ" : "サーバー"}:{" "}
              {remote || "（未設定）"}
            </p>
            <div className="draft-editor__actions">
              <button
                type="button"
                onClick={() => session.resolveMetadata(field, "local")}
              >
                この端末の値を使う
              </button>
              <button
                type="button"
                onClick={() => session.resolveMetadata(field, "remote")}
              >
                {source === "tab" ? "別タブの値を使う" : "サーバーの値を使う"}
              </button>
            </div>
          </fieldset>
        ))}
        <details className="draft-editor__recovery">
          <summary>保存と復旧</summary>
          <DraftOfflineStatus />
          <div className="draft-editor__actions">
            <button
              type="button"
              disabled={!session}
              onClick={() => void session?.sync()}
            >
              サーバー保存を再試行
            </button>
            <button type="button" disabled={!session} onClick={exportMarkdown}>
              本文をダウンロード
            </button>
            {session?.error && (
              <button type="button" onClick={recoverAsNewDraft}>
                内容を新しい下書きへ復旧
              </button>
            )}
          </div>
        </details>
      </div>
      {confirmation && (
        <section aria-label="公開内容の確認">
          <p>本文・タイトル・カバーを確認しましたか。この版を公開します。</p>
          {confirmation.rename && (
            <div>
              <p>
                URLを「{confirmation.rename.from}」から「
                {confirmation.rename.to}」へ変更します。
                旧URLは新URLへ転送されます。
              </p>
              <p>
                参照元{confirmation.rename.references.length}
                件の公開版のリンクも更新します。
                参照元で編集中の下書きは変更・公開しません。
              </p>
              <ul>
                {confirmation.rename.references.map((reference) => (
                  <li key={reference.article_id}>{reference.title}</li>
                ))}
              </ul>
            </div>
          )}
          <button type="button" onClick={() => void publish()}>
            この内容で公開
          </button>
          <button
            type="button"
            onClick={() => {
              setConfirmation(undefined);
              session?.cancelPublication();
            }}
          >
            キャンセル
          </button>
        </section>
      )}
      <div className="draft-editor__workspace">
        <div className="draft-editor__source">
          <textarea
            ref={textarea}
            aria-label="本文"
            aria-describedby="draft-size"
            aria-invalid={bytes > DRAFT_BODY_LIMIT}
            disabled={!session || session.isPublishing}
            spellCheck={false}
          />
        </div>
        <aside
          id="draft-preview"
          className={`draft-preview${isPreviewOpen ? " is-open" : ""}`}
          aria-label="作業版の表示"
        >
          {session && (
            <DraftPreview
              body={session.body.toString()}
              metadata={session.metadata}
            />
          )}
        </aside>
        <button
          className="draft-preview__pull"
          type="button"
          aria-controls="draft-preview"
          aria-expanded={isPreviewOpen}
          onClick={() => setIsPreviewOpen((value) => !value)}
        >
          {isPreviewOpen ? "閉じる" : "プレビュー"}
        </button>
      </div>
      {session && (
        <div
          className="draft-editor__inbox"
          style={{ height: `min(${inboxHeight}px, 55dvh)` }}
        >
          {/* biome-ignore lint/a11y/useSemanticElements: A focusable splitter controls pane size; it is not a document thematic break. */}
          <div
            className="draft-inbox__resize"
            role="separator"
            tabIndex={0}
            aria-label="インボックスの高さ"
            aria-orientation="horizontal"
            aria-valuemin={160}
            aria-valuemax={Math.max(160, Math.round(window.innerHeight * 0.55))}
            aria-valuenow={Math.min(
              inboxHeight,
              Math.max(160, Math.round(window.innerHeight * 0.55)),
            )}
            onKeyDown={(event) => {
              if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
              event.preventDefault();
              setInboxHeight((height) =>
                Math.max(
                  160,
                  Math.min(
                    window.innerHeight * 0.55,
                    height + (event.key === "ArrowUp" ? 24 : -24),
                  ),
                ),
              );
            }}
            onPointerDown={(event) => {
              event.currentTarget.setPointerCapture(event.pointerId);
              event.preventDefault();
            }}
            onPointerMove={(event) => {
              if (event.currentTarget.hasPointerCapture(event.pointerId))
                setInboxHeight(
                  Math.max(
                    160,
                    Math.min(
                      window.innerHeight * 0.55,
                      window.innerHeight - event.clientY,
                    ),
                  ),
                );
            }}
            onPointerUp={(event) =>
              event.currentTarget.releasePointerCapture(event.pointerId)
            }
          >
            <span />
          </div>
          <DraftInbox session={session} textarea={textarea} />
        </div>
      )}
    </section>
  );
}
