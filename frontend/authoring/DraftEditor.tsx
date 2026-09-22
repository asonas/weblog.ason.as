import {
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import * as Y from "yjs";
import { DraftCoverSettings } from "./DraftCoverSettings";
import { DraftInbox } from "./DraftInbox";
import { DraftNavigation } from "./DraftNavigation";
import { DraftPreview } from "./DraftPreview";
import { takeDraftInitialBody } from "./draftInitialBody";
import {
  markdownBlockIndexAt,
  suggestionVerticalPosition,
  textareaWikiLinkQuery,
  type WikiLinkQuery,
  wrapTextareaSelectionInWikiLink,
} from "./draftMarkdown";
import {
  DRAFT_BODY_LIMIT,
  type DraftMetadata,
  DraftSession,
  draftRoute,
} from "./draftSession";
import { prefetchEmbedMetadata } from "./EmbedCard";
import "./draftEditor.css";

const FIELD_LABELS: Record<keyof DraftMetadata, string> = {
  title: "タイトル",
  page_type: "記事種別",
  page_date: "日記の日付（URL）",
  cover_mode: "カバー",
  cover_image_url: "カバー画像のパス",
};

type WikiLinkSuggestionsResponse = {
  names: Array<string>;
};

function caretPosition(field: HTMLTextAreaElement): CSSProperties {
  const mirror = document.createElement("div");
  const style = getComputedStyle(field);
  for (const property of [
    "boxSizing",
    "fontFamily",
    "fontSize",
    "fontStyle",
    "fontWeight",
    "letterSpacing",
    "lineHeight",
    "paddingBlock",
    "paddingInline",
    "tabSize",
    "whiteSpace",
    "wordBreak",
    "overflowWrap",
  ]) {
    mirror.style.setProperty(
      property.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`),
      style.getPropertyValue(
        property.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`),
      ),
    );
  }
  mirror.style.position = "fixed";
  mirror.style.visibility = "hidden";
  mirror.style.inlineSize = `${field.clientWidth}px`;
  mirror.style.whiteSpace = "pre-wrap";
  mirror.style.overflowWrap = "break-word";
  mirror.textContent = field.value.slice(0, field.selectionStart);
  const marker = document.createElement("span");
  marker.textContent = "\u200b";
  mirror.append(marker);
  document.body.append(mirror);
  const lineHeight = Number.parseFloat(style.lineHeight);
  const caretTop = Math.max(
    lineHeight,
    Math.min(
      field.clientHeight - lineHeight,
      marker.offsetTop - field.scrollTop,
    ),
  );
  const result = {
    left: Math.min(
      field.clientWidth - 24,
      marker.offsetLeft - field.scrollLeft,
    ),
    ...suggestionVerticalPosition(caretTop + lineHeight, field.clientHeight),
  };
  mirror.remove();
  return result;
}

function draftStatusTone(status: string): "success" | "pending" | "error" {
  if (/できません|失敗|競合|確認できません/.test(status)) return "error";
  if (/保存済み|完了しました/.test(status)) return "success";
  return "pending";
}

function DraftStatusIcon({
  kind,
  status,
}: {
  kind: "device" | "server" | "publication";
  status: string;
}) {
  const tone = draftStatusTone(status);
  return (
    <span
      className="draft-editor__status-icon"
      data-kind={kind}
      data-tone={tone}
      title={status}
    >
      <svg viewBox="0 0 20 20" aria-hidden="true">
        {kind === "device" ? (
          <path d="M4 4.5h12v8H4zM2.5 15.5h15M7.5 12.5v3m5-3v3" />
        ) : kind === "server" ? (
          <path d="M4 3.5h12v5H4zM4 11.5h12v5H4zM7 6h.1M7 14h.1M10 6h4M10 14h4" />
        ) : (
          <path d="M10 16V5m0 0L6.5 8.5M10 5l3.5 3.5M4 12.5v4h12v-4" />
        )}
      </svg>
      <span className="visually-hidden">{status}</span>
    </span>
  );
}

export function DraftEditor({ csrf }: { csrf: () => Promise<string> }) {
  const [session, setSession] = useState<DraftSession>();
  const [previewWidth, setPreviewWidth] = useState(1000);
  const workspace = useRef<HTMLDivElement>(null);
  const publicationDialog = useRef<HTMLDialogElement>(null);
  const [inboxHeight, setInboxHeight] = useState(() =>
    Math.round(window.innerHeight / 3),
  );
  const [loadError, setLoadError] = useState("");
  const [isPreviewOpen, setIsPreviewOpen] = useState(false);
  const [publicationError, setPublicationError] = useState("");
  const [publicationFlow, setPublicationFlow] = useState<
    "idle" | "running" | "success" | "error"
  >("idle");
  const [publicationIntent, setPublicationIntent] = useState<
    "publish" | "save"
  >("publish");
  const [wikiLinkNames, setWikiLinkNames] = useState<Array<string>>([]);
  const [wikiLinkQuery, setWikiLinkQuery] = useState<WikiLinkQuery | null>(
    null,
  );
  const [activeWikiLinkSuggestion, setActiveWikiLinkSuggestion] = useState(0);
  const [wikiLinkSuggestionStyle, setWikiLinkSuggestionStyle] =
    useState<CSSProperties>();
  const [previewBlockIndex, setPreviewBlockIndex] = useState(0);
  const [, refresh] = useState(0);
  const textarea = useRef<HTMLTextAreaElement>(null);
  const [{ id, isNew, initialArticleState }] = useState(() => {
    const url = new URL(window.location.href);
    const isNew =
      !url.searchParams.has("id") || url.searchParams.get("recovery") === "1";
    const id = url.searchParams.get("id") || crypto.randomUUID();
    url.searchParams.set("id", id);
    window.history.replaceState(null, "", url);
    const state = url.searchParams.get("state");
    return {
      id,
      isNew,
      initialArticleState:
        state === "public" || state === "unpublished_changes" ? state : "draft",
    };
  });
  const [articleState, setArticleState] = useState(initialArticleState);
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
        const initialBody = takeDraftInitialBody(
          sessionStorage,
          id,
          value.body.toString(),
        );
        if (initialBody !== null) value.setBody(initialBody);
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
    if (!session) return;
    void fetch("/api/page-names", { credentials: "same-origin" })
      .then(async (response) => {
        if (!response.ok)
          throw new Error("Wikiリンク候補を取得できませんでした");
        return (await response.json()) as WikiLinkSuggestionsResponse;
      })
      .then((response) => setWikiLinkNames(response.names))
      .catch(() => setWikiLinkNames([]));
  }, [session]);

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

  const wikiLinkSuggestions = useMemo(
    () =>
      wikiLinkQuery
        ? wikiLinkNames
            .filter((name) => name.startsWith(wikiLinkQuery.value))
            .slice(0, 7)
        : [],
    [wikiLinkNames, wikiLinkQuery],
  );

  function updateCursorContext() {
    const field = textarea.current;
    if (!field) return;
    const query = textareaWikiLinkQuery(
      field.value,
      field.selectionStart,
      field.selectionEnd,
    );
    const isSameQuery =
      query?.from === wikiLinkQuery?.from &&
      query?.to === wikiLinkQuery?.to &&
      query?.value === wikiLinkQuery?.value;
    setWikiLinkQuery(query);
    if (!isSameQuery) setActiveWikiLinkSuggestion(0);
    setWikiLinkSuggestionStyle(query ? caretPosition(field) : undefined);
    setPreviewBlockIndex(
      markdownBlockIndexAt(field.value, field.selectionStart),
    );
  }

  function acceptWikiLinkSuggestion(name: string) {
    const field = textarea.current;
    if (!field || !session || !wikiLinkQuery) return;
    field.setRangeText(
      `${name}]]`,
      wikiLinkQuery.from,
      wikiLinkQuery.to,
      "end",
    );
    session.setBody(field.value);
    setWikiLinkQuery(null);
    setWikiLinkSuggestionStyle(undefined);
    field.focus();
  }

  function handleWikiLinkSuggestionKeyDown(
    event: ReactKeyboardEvent<HTMLTextAreaElement>,
  ) {
    if (event.nativeEvent.isComposing) return;
    const field = textarea.current;
    if (
      field &&
      (event.metaKey || event.ctrlKey) &&
      !event.altKey &&
      !event.shiftKey &&
      event.key.toLowerCase() === "k"
    ) {
      const edit = wrapTextareaSelectionInWikiLink(
        field.value,
        field.selectionStart,
        field.selectionEnd,
      );
      if (!edit || !session) return;
      event.preventDefault();
      field.value = edit.value;
      field.setSelectionRange(edit.selectionStart, edit.selectionEnd);
      session.setBody(edit.value);
      setPreviewBlockIndex(
        markdownBlockIndexAt(edit.value, edit.selectionStart),
      );
      return;
    }
    if (wikiLinkSuggestions.length === 0) return;
    if (event.key === "Escape") {
      event.preventDefault();
      setWikiLinkQuery(null);
      setWikiLinkSuggestionStyle(undefined);
    } else if (event.key === "Enter") {
      event.preventDefault();
      acceptWikiLinkSuggestion(wikiLinkSuggestions[activeWikiLinkSuggestion]);
    } else if (event.key === "Tab") {
      event.preventDefault();
      setActiveWikiLinkSuggestion(
        (current) =>
          (current + (event.shiftKey ? -1 : 1) + wikiLinkSuggestions.length) %
          wikiLinkSuggestions.length,
      );
    }
  }

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

  async function publish() {
    if (!session || session.isPublishing) return;
    setPublicationError("");
    setPublicationIntent(articleState === "draft" ? "publish" : "save");
    setPublicationFlow("running");
    publicationDialog.current?.showModal();
    try {
      await prefetchEmbedMetadata(
        textarea.current?.value || session.body.toString(),
      );
      const prepared = session.pendingPublication
        ? undefined
        : await session.preparePublication();
      if (prepared) setArticleState(prepared.article_state);
      await session.publish(prepared);
      setArticleState("public");
      setPublicationFlow("success");
    } catch (error) {
      setPublicationError(
        error instanceof Error ? error.message : "公開に失敗しました",
      );
      setPublicationFlow("error");
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
      <DraftNavigation editing />
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
        <div className="draft-editor__controls">
          {session && <DraftCoverSettings session={session} />}
          <div className="draft-editor__sync-status" role="status">
            {session ? (
              <>
                <DraftStatusIcon kind="device" status={session.localStatus} />
                <DraftStatusIcon kind="server" status={session.serverStatus} />
                {session.publicationStatus && (
                  <DraftStatusIcon
                    kind="publication"
                    status={session.publicationStatus}
                  />
                )}
              </>
            ) : (
              <DraftStatusIcon kind="device" status="読み込み中" />
            )}
          </div>
          <div className="draft-editor__save-actions">
            {session?.error && (
              <button type="button" onClick={() => void session.sync()}>
                サーバー保存を再試行
              </button>
            )}
            <button
              className="draft-editor__icon-button"
              type="button"
              disabled={!session}
              title="本文をダウンロード"
              aria-label="本文をダウンロード"
              onClick={exportMarkdown}
            >
              <svg viewBox="0 0 20 20" aria-hidden="true">
                <path d="M10 3.5v9m0 0L6.5 9M10 12.5 13.5 9M4 15.5h12" />
              </svg>
            </button>
            {session?.error && (
              <button type="button" onClick={recoverAsNewDraft}>
                内容を新しい下書きへ復旧
              </button>
            )}
          </div>
          <button
            className="draft-editor__publish"
            type="button"
            disabled={!session || session.isPublishing}
            onClick={() => void publish()}
          >
            {session?.isPublishing
              ? articleState === "draft"
                ? "公開中"
                : "保存中"
              : session?.pendingPublication
                ? "公開を再試行"
                : articleState === "draft"
                  ? "公開する"
                  : "保存する"}
          </button>
        </div>
      </div>
      <div className="draft-editor__status">
        <p id="draft-size">
          {bytes >= DRAFT_BODY_LIMIT * 0.9
            ? `本文 ${Math.ceil(bytes / 1024)} / 512 KiB。上限を超えても本文は削除されません。`
            : ""}
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
      </div>
      <div
        className="draft-editor__workspace"
        ref={workspace}
        style={{
          gridTemplateColumns: `minmax(16rem, 1fr) 12px minmax(16rem, ${previewWidth}px)`,
        }}
      >
        <div className="draft-editor__source">
          <textarea
            ref={textarea}
            aria-label="本文"
            aria-describedby="draft-size"
            aria-invalid={bytes > DRAFT_BODY_LIMIT}
            disabled={!session || session.isPublishing}
            spellCheck={false}
            aria-controls={
              wikiLinkSuggestions.length > 0
                ? "draft-wiki-link-suggestions"
                : undefined
            }
            aria-activedescendant={
              wikiLinkSuggestions.length > 0
                ? `draft-wiki-link-suggestion-${activeWikiLinkSuggestion}`
                : undefined
            }
            onInput={updateCursorContext}
            onClick={updateCursorContext}
            onKeyUp={(event) => {
              if (
                wikiLinkSuggestions.length === 0 ||
                !["Tab", "Enter", "Escape"].includes(event.key)
              )
                updateCursorContext();
            }}
            onSelect={updateCursorContext}
            onKeyDown={handleWikiLinkSuggestionKeyDown}
          />
          {wikiLinkSuggestionStyle && wikiLinkSuggestions.length > 0 && (
            <div
              className="wiki-link-suggestions draft-wiki-link-suggestions"
              id="draft-wiki-link-suggestions"
              role="listbox"
              aria-label="Wikiリンク候補"
              style={wikiLinkSuggestionStyle}
            >
              {wikiLinkSuggestions.map((name, index) => (
                <button
                  className="wiki-link-suggestions__option"
                  id={`draft-wiki-link-suggestion-${index}`}
                  type="button"
                  role="option"
                  tabIndex={-1}
                  aria-selected={index === activeWikiLinkSuggestion}
                  key={name}
                  onMouseDown={(event) => event.preventDefault()}
                  onClick={() => acceptWikiLinkSuggestion(name)}
                >
                  {name}
                </button>
              ))}
            </div>
          )}
        </div>
        {/* biome-ignore lint/a11y/useSemanticElements: A focusable separator implements the adjustable split pane. */}
        <div
          className="draft-editor__resize"
          role="separator"
          tabIndex={0}
          aria-label="プレビューの幅"
          aria-orientation="vertical"
          aria-valuemin={256}
          aria-valuemax={Math.max(
            256,
            (workspace.current?.clientWidth || 1132) - 268,
          )}
          aria-valuenow={previewWidth}
          onPointerDown={(event) =>
            event.currentTarget.setPointerCapture(event.pointerId)
          }
          onPointerMove={(event) => {
            if (!event.currentTarget.hasPointerCapture(event.pointerId)) return;
            const rect = workspace.current?.getBoundingClientRect();
            if (rect)
              setPreviewWidth(
                Math.max(
                  256,
                  Math.min(rect.width - 268, rect.right - event.clientX),
                ),
              );
          }}
          onPointerUp={(event) =>
            event.currentTarget.releasePointerCapture(event.pointerId)
          }
          onKeyDown={(event) => {
            if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
            event.preventDefault();
            setPreviewWidth((width) =>
              Math.max(
                256,
                Math.min(
                  (workspace.current?.clientWidth || 1132) - 268,
                  width + (event.key === "ArrowLeft" ? 24 : -24),
                ),
              ),
            );
          }}
        />
        <aside
          id="draft-preview"
          className={`draft-preview${isPreviewOpen ? " is-open" : ""}`}
          aria-label="作業版の表示"
        >
          {session && (
            <DraftPreview
              body={session.body.toString()}
              metadata={session.metadata}
              pageNames={wikiLinkNames}
              sourceBlockIndex={previewBlockIndex}
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
      <dialog
        className="draft-publication-dialog"
        ref={publicationDialog}
        aria-labelledby="draft-publication-title"
        onCancel={(event) => {
          if (publicationFlow === "running") event.preventDefault();
        }}
      >
        <h2 id="draft-publication-title">
          {publicationFlow === "success"
            ? publicationIntent === "save"
              ? "記事を保存しました"
              : "記事を公開しました"
            : publicationFlow === "error"
              ? "処理を完了できませんでした"
              : publicationIntent === "publish"
                ? "記事を公開しています"
                : "記事を保存しています"}
        </h2>
        <p role="status" aria-live="polite">
          {publicationFlow === "running"
            ? session?.publicationStatus ||
              "本文と設定をサーバーへ保存しています。"
            : publicationFlow === "success"
              ? session?.publicationStatus ||
                "公開ページへの反映が完了しました。"
              : publicationError}
        </p>
        <div className="draft-publication-dialog__actions">
          {publicationFlow === "success" && session && (
            <>
              <a href={`/${encodeURIComponent(draftRoute(session.metadata))}`}>
                記事を見る
              </a>
              <a href="/authoring/articles">記事一覧に戻る</a>
              <button
                type="button"
                onClick={() => publicationDialog.current?.close()}
              >
                編集を続ける
              </button>
            </>
          )}
          {publicationFlow === "error" && (
            <button
              type="button"
              onClick={() => publicationDialog.current?.close()}
            >
              エディタに戻る
            </button>
          )}
        </div>
      </dialog>
    </section>
  );
}
