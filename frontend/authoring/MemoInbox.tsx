import { type RefObject, useEffect, useRef, useState } from "react";
import type { DraftSession } from "./draftSession";
import { type LocalMemo, MemoStore, memoNeedsSave } from "./memoStore";

function MemoCard({
  memo,
  store,
  session,
  report,
}: {
  memo: LocalMemo;
  store: MemoStore;
  session: DraftSession;
  report: (error: string) => void;
}) {
  const [body, setBody] = useState(memo.body);
  const [saving, setSaving] = useState(false);
  const [busy, setBusy] = useState(false);
  const [localError, setLocalError] = useState(false);
  const latest = useRef(memo.body);
  const key = useRef(memo.key);
  const writes = useRef(Promise.resolve());
  const pending = useRef(0);
  const composing = useRef(false);
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      if (pending.current || localError) event.preventDefault();
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [localError]);
  useEffect(() => {
    if (!pending.current && !composing.current) {
      latest.current = memo.body;
      setBody(memo.body);
    }
  }, [memo.body]);
  const edit = (value: string) => {
    const before = latest.current;
    latest.current = value;
    setBody(value);
    pending.current++;
    setSaving(true);
    writes.current = writes.current
      .then(async () => {
        key.current = await store.edit(key.current, value, before);
        setLocalError(false);
      })
      .catch((error: unknown) => {
        setLocalError(true);
        report(
          error instanceof Error
            ? error.message
            : "端末に保存できません。文章をコピーして退避してください。",
        );
      })
      .finally(() => {
        pending.current--;
        setSaving(pending.current > 0);
      });
  };
  const act = async (action: "adopt" | "delete") => {
    setBusy(true);
    try {
      await writes.current;
      if (action === "adopt") await store.adopt(key.current, session);
      else await store.remove(key.current);
    } catch (error) {
      report(
        error instanceof Error ? error.message : "操作を完了できませんでした",
      );
    } finally {
      setBusy(false);
    }
  };
  return (
    <article className="memo-inbox__memo">
      <textarea
        aria-label="メモ本文"
        value={body}
        onChange={(event) => edit(event.currentTarget.value)}
        onCompositionStart={() => {
          composing.current = true;
        }}
        onCompositionEnd={() => {
          composing.current = false;
        }}
        disabled={
          busy ||
          memo.flight?.kind === "adopt" ||
          memo.flight?.kind === "delete"
        }
      />
      <p role="status">
        {localError
          ? "端末に未保存・文章を退避してください"
          : saving
            ? "端末に保存中"
            : memo.flight || memoNeedsSave(memo)
              ? "端末に保存済み・送信待ち"
              : "保存済み"}
      </p>
      {memo.error && <p role="alert">{memo.error}</p>}
      <div className="memo-inbox__actions">
        {session.pieces && session.metadata.page_type === "date" && (
          <button
            type="button"
            disabled={
              busy || saving || session.isPublishing || Boolean(memo.flight)
            }
            onClick={() => void act("adopt")}
          >
            かけらとして取り込む
          </button>
        )}
        <button
          type="button"
          className="memo-inbox__delete"
          disabled={busy || saving || Boolean(memo.flight)}
          onClick={() => {
            if (window.confirm("このメモを削除しますか？")) void act("delete");
          }}
        >
          削除
        </button>
      </div>
    </article>
  );
}

export function MemoInbox({
  session,
  textarea,
}: {
  session: DraftSession;
  textarea: RefObject<HTMLTextAreaElement | null>;
}) {
  const [store, setStore] = useState<MemoStore>();
  const [memos, setMemos] = useState<LocalMemo[]>([]);
  const [error, setError] = useState("");
  const [selection, setSelection] = useState("");
  useEffect(() => {
    let closed = false;
    let opened: MemoStore | undefined;
    const load = () => {
      void opened
        ?.list()
        .then((items) => {
          if (!closed) {
            setMemos(items);
            setError(opened?.error || "");
          }
        })
        .catch((cause: unknown) =>
          setError(
            cause instanceof Error
              ? cause.message
              : "メモを読み込めませんでした",
          ),
        );
    };
    void MemoStore.open()
      .then((value) => {
        if (closed) {
          value.close();
          return;
        }
        opened = value;
        setStore(value);
        value.addEventListener("change", load);
        load();
        void value.sync().catch(() => {});
      })
      .catch((cause: unknown) =>
        setError(
          cause instanceof Error
            ? cause.message
            : "メモの保存領域を開けませんでした",
        ),
      );
    return () => {
      closed = true;
      opened?.removeEventListener("change", load);
      opened?.close();
    };
  }, []);
  // biome-ignore lint/correctness/useExhaustiveDependencies: Switching pieces changes the textarea referenced by the ref.
  useEffect(() => {
    const field = textarea.current;
    const update = () =>
      setSelection(
        field?.value.slice(field.selectionStart, field.selectionEnd) || "",
      );
    update();
    field?.addEventListener("select", update);
    field?.addEventListener("input", update);
    return () => {
      field?.removeEventListener("select", update);
      field?.removeEventListener("input", update);
    };
  }, [textarea, session.activePieceId]);
  const run = async (action: () => Promise<unknown>) => {
    try {
      await action();
      setError("");
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "操作を完了できませんでした",
      );
    }
  };
  return (
    <section className="draft-inbox__column memo-inbox" aria-label="メモ">
      <header className="draft-inbox__column-header">
        <h3>メモ</h3>
        <button
          type="button"
          className="draft-inbox__reload"
          aria-label="メモを追加"
          title="メモを追加"
          disabled={!store}
          onClick={() => store && void run(() => store.add())}
        >
          <svg
            viewBox="0 0 24 24"
            width="20"
            height="20"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            aria-hidden="true"
          >
            <path d="M12 5v14M5 12h14" />
          </svg>
        </button>
        <button
          type="button"
          className="draft-inbox__reload"
          aria-label="メモを同期"
          title="メモを同期"
          disabled={!store}
          onClick={() => store && void run(() => store.sync())}
        >
          <svg
            viewBox="0 0 24 24"
            width="20"
            height="20"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            {/* Regen Icons, MIT: ./regen-icons-LICENSE.txt */}
            <path d="M17.66 17.66A8 8 0 1 1 12 4M12 4Q17 4 19.5 8.5M14 9L19 9A1 1 0 0 0 20 8L20 3" />
          </svg>
        </button>
      </header>
      {selection && (
        <button
          type="button"
          disabled={!store}
          onClick={() => store && void run(() => store.add(selection))}
        >
          選択している内容をメモに保存する
        </button>
      )}
      {error && <p role="alert">{error}</p>}
      <div className="memo-inbox__list">
        {store &&
          memos.map((memo) => (
            <MemoCard
              key={memo.key}
              memo={memo}
              store={store}
              session={session}
              report={setError}
            />
          ))}
      </div>
    </section>
  );
}
