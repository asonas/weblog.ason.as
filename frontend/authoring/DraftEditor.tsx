import { useEffect, useRef, useState } from "react";
import * as Y from "yjs";
import {
  DRAFT_BODY_LIMIT,
  type DraftMetadata,
  DraftSession,
} from "./draftSession";
import "./draftEditor.css";

const FIELD_LABELS: Record<keyof DraftMetadata, string> = {
  title: "タイトル",
  page_type: "記事種別",
  cover_mode: "カバー",
  cover_image_url: "カバー画像のパス",
};

export function DraftEditor() {
  const [session, setSession] = useState<DraftSession>();
  const [loadError, setLoadError] = useState("");
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
    let isActive = true;
    let opened: DraftSession | undefined;
    void DraftSession.open(
      id,
      () => document.documentElement.dataset.csrfToken || "",
      isNew,
    )
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
  }, [id, isNew, recoveryKey]);

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
      <p>開発用の下書き保存です。公開ページは変更されません。</p>
      <label htmlFor="draft-title">タイトル</label>
      <input
        id="draft-title"
        value={session?.metadata.title || ""}
        disabled={!session}
        onChange={(event) =>
          session?.setMetadata({ title: event.target.value })
        }
      />
      <details>
        <summary>記事とカバーの設定</summary>
        <label htmlFor="draft-type">記事種別</label>
        <select
          id="draft-type"
          value={session?.metadata.page_type || "named"}
          disabled={!session}
          onChange={(event) =>
            session?.setMetadata({ page_type: event.target.value })
          }
        >
          <option value="named">記事</option>
          <option value="date">日記</option>
        </select>
        <label htmlFor="draft-cover-mode">カバー</label>
        <select
          id="draft-cover-mode"
          value={session?.metadata.cover_mode || "auto"}
          disabled={!session}
          onChange={(event) =>
            session?.setMetadata({
              cover_mode: event.target.value,
              cover_image_url:
                event.target.value === "explicit"
                  ? session.metadata.cover_image_url || ""
                  : null,
            })
          }
        >
          <option value="auto">自動</option>
          <option value="none">なし</option>
          <option value="explicit">指定</option>
        </select>
        {session?.metadata.cover_mode === "explicit" && (
          <>
            <label htmlFor="draft-cover">カバー画像のパス</label>
            <input
              id="draft-cover"
              value={session.metadata.cover_image_url || ""}
              onChange={(event) =>
                session.setMetadata({ cover_image_url: event.target.value })
              }
            />
          </>
        )}
      </details>
      <textarea
        ref={textarea}
        aria-label="本文"
        aria-describedby="draft-size"
        aria-invalid={bytes > DRAFT_BODY_LIMIT}
        disabled={!session}
        spellCheck={false}
      />
      <p id="draft-size">
        {bytes >= DRAFT_BODY_LIMIT * 0.9
          ? `本文 ${Math.ceil(bytes / 1024)} / 512 KiB。上限を超えても本文は削除されません。`
          : ""}
      </p>
      <p role="status">
        {session
          ? `${session.localStatus} · ${session.serverStatus}`
          : "読み込み中"}
      </p>
      <p role="alert">{loadError || session?.error}</p>
      {session?.metadataConflicts.map(({ field, local, remote, source }) => (
        <fieldset key={field} className="draft-editor__conflict">
          <legend>{FIELD_LABELS[field]}の競合</legend>
          <p>
            別の編集で同じ項目が変更されました。残す値を選んでください。本文と未送信の変更は端末に保持しています。
          </p>
          <p>この端末: {local || "（未設定）"}</p>
          <p>
            {source === "tab" ? "別タブ" : "サーバー"}: {remote || "（未設定）"}
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
        <a href="/draft-editor">別の下書きを書く</a>
      </div>
    </section>
  );
}
