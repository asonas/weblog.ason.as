import {
  type CSSProperties,
  type ClipboardEvent as ReactClipboardEvent,
  type DragEvent as ReactDragEvent,
  type KeyboardEvent as ReactKeyboardEvent,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import * as Y from "yjs";
import { AuthoringIcon } from "./AuthoringIcon";
import { DraftArticleSettings } from "./DraftArticleSettings";
import { DraftInbox } from "./DraftInbox";
import { DraftNavigation } from "./DraftNavigation";
import { DraftPreview } from "./DraftPreview";
import { DraftSuggestions } from "./DraftSuggestions";
import { takeDraftInitialBody } from "./draftInitialBody";
import {
  insertMarkdownBlock,
  markdownBlockIndexAt,
  markdownKeyEdit,
  suggestionHorizontalPosition,
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
import { draftMetadataForTitle, hasCustomDiaryTitle } from "./draftTitle";
import { prefetchEmbedMetadata } from "./EmbedCard";
import { DraftPieceControls, DraftTagInput } from "./PieceControls";
import { pieceSeparator } from "./pieceSeparator";
import "./draftEditor.css";
import "./authoringTheme.css";

type ProofreadingMessage = {
  ruleId: string;
  message: string;
  line: number;
  range: readonly [number, number];
};

type ProofreadingResponse = {
  messages: ProofreadingMessage[];
};

function articleDocumentTitle(title: string, environment?: string): string {
  const pageTitle = title ? `${title} | weblog.ason.as` : "weblog.ason.as";
  return environment === "development" ? `[dev] ${pageTitle}` : pageTitle;
}

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

type UploadResponse = {
  upload_url: string;
  fields: Record<string, string>;
  public_url: string;
};

async function uploadImage(file: File, csrf: () => Promise<string>) {
  const [{ imageDimensions }, { prepareImage }] = await Promise.all([
    import("./imageMetadata"),
    import("./imageUpload"),
  ]);
  const prepared = await prepareImage(file);
  const dimensions = imageDimensions(
    await prepared.file.arrayBuffer(),
    prepared.file.type,
  );
  if (!dimensions) throw new Error("画像の寸法を読み取れませんでした");
  const response = await fetch("/api/uploads", {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": await csrf(),
    },
    body: JSON.stringify({
      width: dimensions.width,
      height: dimensions.height,
      content_type: prepared.file.type,
      size: prepared.file.size,
    }),
  });
  const result = (await response.json()) as UploadResponse & { error?: string };
  if (!response.ok)
    throw new Error(result.error || "画像をアップロードできませんでした");
  const form = new FormData();
  for (const [key, value] of Object.entries(result.fields))
    form.append(key, value);
  form.append("file", prepared.file);
  const uploaded = await fetch(result.upload_url, {
    method: "POST",
    body: form,
  });
  if (!uploaded.ok) throw new Error("画像をS3へ送信できませんでした");
  if (!result.public_url.startsWith("/assets/uploads/"))
    throw new Error("画像のURLが不正です");
  return result.public_url;
}

function caretPosition(
  field: HTMLTextAreaElement,
  container: HTMLElement,
  suggestionHeight: number,
  suggestionWidth: number,
): CSSProperties {
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
    0,
    Math.min(
      field.clientHeight - lineHeight,
      marker.offsetTop - field.scrollTop,
    ),
  );
  const fieldRect = field.getBoundingClientRect();
  const containerRect = container.getBoundingClientRect();
  const vertical = suggestionVerticalPosition(
    caretTop,
    field.clientHeight,
    lineHeight,
    suggestionHeight,
  );
  // The menu belongs to the source pane, while the caret belongs to a piece.
  const result = {
    left:
      fieldRect.left -
      containerRect.left +
      container.scrollLeft -
      container.clientLeft +
      suggestionHorizontalPosition(
        marker.offsetLeft - field.scrollLeft,
        field.clientWidth,
        suggestionWidth,
      ),
    top:
      fieldRect.top -
      containerRect.top +
      container.scrollTop -
      container.clientTop +
      ("top" in vertical
        ? vertical.top
        : field.clientHeight - vertical.bottom - suggestionHeight),
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

export function DraftEditor({
  csrf,
  piecesEnabled = false,
}: {
  csrf: () => Promise<string>;
  piecesEnabled?: boolean;
}) {
  const [session, setSession] = useState<DraftSession>();
  const [dropPiece, setDropPiece] = useState<string>();
  const draggedPiece = useRef<string | undefined>(undefined);
  const pieceDiary = Boolean(session?.pieces);
  const [previewWidth, setPreviewWidth] = useState(1000);
  const workspace = useRef<HTMLDivElement>(null);
  const publicationDialog = useRef<HTMLDialogElement>(null);
  const [inboxHeight, setInboxHeight] = useState(() =>
    Math.round(window.innerHeight / 3),
  );
  const [loadError, setLoadError] = useState("");
  const [isPreviewOpen, setIsPreviewOpen] = useState(false);
  const [publicationError, setPublicationError] = useState("");
  const [webmentions, setWebmentions] =
    useState<Awaited<ReturnType<DraftSession["webmentionStatus"]>>>();
  const [webmentionStatus, setWebmentionStatus] = useState("");
  const [isSendingWebmentions, setIsSendingWebmentions] = useState(false);
  const [imageUploadError, setImageUploadError] = useState("");
  const [imageUploadStatus, setImageUploadStatus] = useState("");
  const videoUpload = useRef<AbortController | null>(null);
  useEffect(() => () => videoUpload.current?.abort(), []);
  const [publicationFlow, setPublicationFlow] = useState<
    "idle" | "running" | "success" | "error"
  >("idle");
  const [publicationIntent, setPublicationIntent] = useState<
    "publish" | "update"
  >("publish");
  const [wikiLinkNames, setWikiLinkNames] = useState<Array<string>>([]);
  const [wikiLinkQuery, setWikiLinkQuery] = useState<WikiLinkQuery | null>(
    null,
  );
  const [activeWikiLinkSuggestion, setActiveWikiLinkSuggestion] = useState(0);
  const [wikiLinkSuggestionStyle, setWikiLinkSuggestionStyle] =
    useState<CSSProperties>();
  const [previewBlockIndex, setPreviewBlockIndex] = useState(0);
  const [proofreadingMessages, setProofreadingMessages] = useState<
    ProofreadingMessage[]
  >([]);
  const [proofreadingStatus, setProofreadingStatus] = useState<string | null>(
    "本文を読み込んでいます",
  );
  const [, refresh] = useState(0);
  const textarea = useRef<HTMLTextAreaElement>(null);
  const wikiLinkSuggestionList = useRef<HTMLDivElement>(null);
  const composing = useRef(false);
  const [{ id, isNew, initialTitle, initialArticleState }] = useState(() => {
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
      initialTitle: isNew ? url.searchParams.get("title") : null,
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
    document.title = articleDocumentTitle(
      session?.metadata.title || "",
      document.documentElement.dataset.environment,
    );
  }, [session?.metadata.title]);

  useEffect(() => {
    let isActive = true;
    let opened: DraftSession | undefined;
    void DraftSession.open(id, csrf, isNew, piecesEnabled)
      .then(async (value) => {
        opened = value;
        if (!isActive) return value.close();
        if (initialTitle !== null && !value.metadata.title)
          value.setMetadata(draftMetadataForTitle(initialTitle));
        if (hasCustomDiaryTitle(value.metadata))
          value.setMetadata(draftMetadataForTitle(value.metadata.title));
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
        if (piecesEnabled && !isNew) await value.migrateIfNeeded();
        if (isActive) setSession(value);
        else value.close();
      })
      .catch((error: unknown) => {
        opened?.close();
        if (isActive) {
          setLoadError(
            error instanceof Error ? error.message : "下書きを開けませんでした",
          );
          setProofreadingStatus("文章を確認できませんでした");
        }
      });
    return () => {
      isActive = false;
      opened?.close();
    };
  }, [id, isNew, initialTitle, recoveryKey, csrf, piecesEnabled]);

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
    if (!session) return;
    setProofreadingMessages([]);
    let revision = 0;
    let timer: ReturnType<typeof setTimeout>;
    let request: AbortController | undefined;
    const schedule = () => {
      revision += 1;
      clearTimeout(timer);
      request?.abort();
      const currentRevision = revision;
      const text = session.body.toString();
      if (!text.trim()) {
        setProofreadingMessages([]);
        setProofreadingStatus("本文を入力すると確認します");
        return;
      }
      if (!navigator.onLine) {
        setProofreadingStatus("オフラインのため文章の確認を停止しています");
        return;
      }
      setProofreadingStatus(null);
      timer = setTimeout(async () => {
        if (composing.current) return;
        setProofreadingStatus("確認中");
        const controller = new AbortController();
        request = controller;
        try {
          const token = await csrf();
          if (controller.signal.aborted) return;
          const response = await fetch("/api/authoring/proofread", {
            method: "POST",
            credentials: "same-origin",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": token,
            },
            body: JSON.stringify({ text }),
            signal: AbortSignal.any([
              controller.signal,
              AbortSignal.timeout(30000),
            ]),
          });
          if (!response.ok) throw new Error("文章を確認できませんでした");
          const result: ProofreadingResponse = await response.json();
          if (currentRevision !== revision || composing.current) return;
          setProofreadingMessages(result.messages);
          setProofreadingStatus("");
        } catch {
          if (controller.signal.aborted || currentRevision !== revision) return;
          setProofreadingStatus(
            "文章を確認できませんでした。次の入力時に再試行します",
          );
        }
      }, 7000);
    };
    const observedBody = session.body;
    observedBody.observe(schedule);
    const field = textarea.current;
    field?.addEventListener("compositionend", schedule);
    window.addEventListener("online", schedule);
    window.addEventListener("offline", schedule);
    schedule();
    return () => {
      revision += 1;
      clearTimeout(timer);
      observedBody.unobserve(schedule);
      field?.removeEventListener("compositionend", schedule);
      window.removeEventListener("online", schedule);
      window.removeEventListener("offline", schedule);
      request?.abort();
    };
  }, [session, csrf, session?.activePieceId]);

  useLayoutEffect(() => {
    const field = textarea.current;
    if (!session || !field) return;
    const observedBody = session.body;
    field.value = observedBody.toString();
    let isComposing = false;
    let previousCaret = field.selectionStart;
    let selection = {
      start: Y.createRelativePositionFromTypeIndex(
        observedBody,
        field.selectionStart,
      ),
      end: Y.createRelativePositionFromTypeIndex(
        observedBody,
        field.selectionEnd,
      ),
      direction: field.selectionDirection,
    };
    const remember = () => {
      selection = {
        start: Y.createRelativePositionFromTypeIndex(
          observedBody,
          field.selectionStart,
        ),
        end: Y.createRelativePositionFromTypeIndex(
          observedBody,
          field.selectionEnd,
        ),
        direction: field.selectionDirection,
      };
    };
    const show = () => {
      if (!isComposing && field.value !== observedBody.toString()) {
        const scroll = field.scrollTop;
        field.value = observedBody.toString();
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
      if (isComposing || session.body !== observedBody) return;
      const split = session.pieces
        ? pieceSeparator(
            field.value,
            field.selectionStart,
            observedBody.toString(),
            previousCaret,
          )
        : null;
      if (split) {
        session.splitActivePiece(split.before, split.after);
        requestAnimationFrame(() => {
          textarea.current?.focus();
          textarea.current?.setSelectionRange(split.caret, split.caret);
        });
      } else session.setBody(field.value);
    };
    const startComposition = () => {
      isComposing = true;
      composing.current = true;
      session.setComposing(true);
    };
    const endComposition = () => {
      isComposing = false;
      composing.current = false;
      session.setComposing(false);
      input();
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
      previousCaret = field.selectionStart;
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
      composing.current = false;
      session.doc.off("beforeTransaction", remember);
      session.removeEventListener("change", show);
      field.removeEventListener("input", input);
      field.removeEventListener("beforeinput", beforeinput);
      field.removeEventListener("keydown", keydown);
      field.removeEventListener("compositionstart", startComposition);
      field.removeEventListener("compositionend", endComposition);
      window.removeEventListener("beforeunload", beforeUnload);
    };
  }, [session, session?.activePieceId]);

  const wikiLinkSuggestions = useMemo(
    () =>
      wikiLinkQuery
        ? wikiLinkNames
            .filter((name) => name.startsWith(wikiLinkQuery.value))
            .slice(0, 7)
        : [],
    [wikiLinkNames, wikiLinkQuery],
  );

  useLayoutEffect(() => {
    const field = textarea.current;
    const list = wikiLinkSuggestionList.current;
    if (!field || !list || wikiLinkSuggestions.length === 0) return;
    const updatePosition = () => {
      const container = list.offsetParent;
      if (!(container instanceof HTMLElement)) return;
      const { width, height } = list.getBoundingClientRect();
      setWikiLinkSuggestionStyle(
        caretPosition(field, container, height, width),
      );
    };
    updatePosition();
    const observer = new ResizeObserver(updatePosition);
    observer.observe(field);
    observer.observe(list);
    field.addEventListener("scroll", updatePosition);
    return () => {
      observer.disconnect();
      field.removeEventListener("scroll", updatePosition);
    };
  }, [wikiLinkSuggestions]);

  function updateCursorContext() {
    const field = textarea.current;
    if (!field) return;
    if (
      field.selectionStart === field.value.length &&
      field.selectionEnd === field.value.length
    )
      field.scrollTop = field.scrollHeight;
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
    setPreviewBlockIndex(
      markdownBlockIndexAt(
        session?.markdown || field.value,
        session?.previewPosition(field.selectionStart) ?? field.selectionStart,
      ),
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
    if (
      composing.current ||
      event.nativeEvent.isComposing ||
      event.nativeEvent.keyCode === 229
    )
      return;
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
        markdownBlockIndexAt(
          session.markdown,
          session.previewPosition(edit.selectionStart),
        ),
      );
      return;
    }
    if (wikiLinkSuggestions.length > 0 && event.key === "Escape") {
      event.preventDefault();
      setWikiLinkQuery(null);
      setWikiLinkSuggestionStyle(undefined);
    } else if (wikiLinkSuggestions.length > 0 && event.key === "Enter") {
      event.preventDefault();
      acceptWikiLinkSuggestion(wikiLinkSuggestions[activeWikiLinkSuggestion]);
    } else if (
      wikiLinkSuggestions.length > 0 &&
      ["Tab", "ArrowDown", "ArrowUp"].includes(event.key)
    ) {
      event.preventDefault();
      setActiveWikiLinkSuggestion(
        (current) =>
          (current +
            (event.shiftKey || event.key === "ArrowUp" ? -1 : 1) +
            wikiLinkSuggestions.length) %
          wikiLinkSuggestions.length,
      );
    } else if (
      field &&
      session &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      (event.key === "Tab" || event.key === "Enter")
    ) {
      const edit = markdownKeyEdit(
        field.value,
        field.selectionStart,
        field.selectionEnd,
        event.key,
        event.shiftKey,
      );
      if (!edit) return;
      event.preventDefault();
      field.value = edit.value;
      field.setSelectionRange(edit.selectionStart, edit.selectionEnd);
      if (edit.value !== session.body.toString()) session.setBody(edit.value);
      updateCursorContext();
    }
  }

  function exportMarkdown() {
    const blob = new Blob([session?.markdown || ""], {
      type: "text/markdown;charset=utf-8",
    });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `draft-${id}.md`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function insertImageFiles(
    files: Array<File>,
    selectionStart: number,
    selectionEnd: number,
  ) {
    if (files.length === 0 || !session || imageUploadStatus) return;
    const field = textarea.current;
    if (!field) return;
    setImageUploadError("");
    try {
      const markdown: Array<string> = [];
      for (const [index, file] of files.entries()) {
        setImageUploadStatus(
          `画像をアップロード中 ${index + 1}/${files.length}`,
        );
        markdown.push(`![](${await uploadImage(file, csrf)})`);
      }
      const next = insertMarkdownBlock(
        field.value,
        selectionStart,
        selectionEnd,
        markdown.join("\n\n"),
      );
      session.undo.stopCapturing();
      session.setBody(next.body);
      session.undo.stopCapturing();
      requestAnimationFrame(() => {
        field.focus();
        field.setSelectionRange(next.caret, next.caret);
      });
    } catch (error) {
      setImageUploadError(
        error instanceof Error ? error.message : "画像を追加できませんでした",
      );
    } finally {
      setImageUploadStatus("");
    }
  }

  async function insertVideoFiles(files: Array<File>) {
    const field = textarea.current;
    if (
      !field ||
      !session ||
      imageUploadStatus ||
      videoUpload.current ||
      session.isPublishing
    )
      return;
    if (files.some((file) => !file.type.startsWith("video/"))) {
      setImageUploadError("画像と動画は分けて追加してください");
      return;
    }
    const controller = new AbortController();
    videoUpload.current = controller;
    const start = field.selectionStart;
    const end = field.selectionEnd;
    const body = field.value;
    const pieceId = session.activePieceId;
    setImageUploadError("");
    setImageUploadStatus("動画の変換を準備中…");
    try {
      const { uploadVideo } = await import("./uploadVideo");
      const links: Array<string> = [];
      for (const file of files) {
        const video = await uploadVideo(
          file,
          csrf,
          controller.signal,
          setImageUploadStatus,
        );
        window.dispatchEvent(new Event("draft-video-uploaded"));
        const name = file.name
          .replace(/[\\[\]]/g, "\\$&")
          .replace(/[\r\n]/g, " ");
        links.push(`[${name || "動画"}](${video.avc})`);
      }
      controller.signal.throwIfAborted();
      if (session.activePieceId !== pieceId || field.value !== body)
        throw new Error(
          "本文が変更されたため挿入を中止しました。動画は素材一覧から追加できます。",
        );
      const next = insertMarkdownBlock(body, start, end, links.join("\n\n"));
      session.undo.stopCapturing();
      session.setBody(next.body);
      session.undo.stopCapturing();
      requestAnimationFrame(() => {
        field.focus();
        field.setSelectionRange(next.caret, next.caret);
      });
    } catch (error) {
      if (!controller.signal.aborted)
        setImageUploadError(
          error instanceof Error ? error.message : "動画を追加できませんでした",
        );
    } finally {
      videoUpload.current = null;
      setImageUploadStatus("");
    }
  }

  async function handleImageDrop(event: ReactDragEvent<HTMLTextAreaElement>) {
    if (
      Array.from(event.dataTransfer.files).some((file) =>
        file.type.startsWith("video/"),
      )
    ) {
      event.preventDefault();
      await insertVideoFiles(Array.from(event.dataTransfer.files));
      return;
    }
    const files = Array.from(event.dataTransfer.files).filter((file) =>
      file.type.startsWith("image/"),
    );
    if (files.length === 0 || !session || imageUploadStatus) return;
    event.preventDefault();
    const field = textarea.current;
    if (!field) return;
    await insertImageFiles(files, field.selectionStart, field.selectionEnd);
  }

  async function handleImagePaste(
    event: ReactClipboardEvent<HTMLTextAreaElement>,
  ) {
    if (
      Array.from(event.clipboardData.files).some((file) =>
        file.type.startsWith("video/"),
      )
    ) {
      event.preventDefault();
      await insertVideoFiles(Array.from(event.clipboardData.files));
      return;
    }
    const files = Array.from(event.clipboardData.files).filter((file) =>
      file.type.startsWith("image/"),
    );
    if (files.length === 0 || !session || imageUploadStatus) return;
    event.preventDefault();
    const field = event.currentTarget;
    await insertImageFiles(files, field.selectionStart, field.selectionEnd);
  }

  async function publish() {
    if (!session || session.isPublishing) return;
    setPublicationError("");
    setWebmentions(undefined);
    setWebmentionStatus("");
    setPublicationIntent(articleState === "draft" ? "publish" : "update");
    setPublicationFlow("running");
    publicationDialog.current?.showModal();
    try {
      await prefetchEmbedMetadata(
        textarea.current?.value || session.body.toString(),
      );
      const prepared = session.pendingPublication
        ? undefined
        : await session.preparePublication();
      if (prepared) {
        setArticleState(prepared.article_state);
        setPublicationIntent(
          prepared.article_state === "draft" ? "publish" : "update",
        );
      }
      await session.publish(prepared);
      setArticleState("public");
      setPublicationFlow("success");
      try {
        const mentions = await session.webmentionStatus();
        setWebmentions(mentions);
        if (mentions.pending)
          setWebmentionStatus("Webmentionの送信を待っています。");
        if (!mentions.enabled)
          setWebmentionStatus("Webmentionの送信は停止中です。");
      } catch {
        setWebmentionStatus("Webmentionの送信状況を取得できませんでした。");
      }
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

  const bytes = new TextEncoder().encode(session?.markdown || "").length;
  return (
    <section className="draft-editor" aria-label="下書き編集">
      <DraftNavigation>
        <section
          className="draft-proofreading"
          aria-labelledby="draft-proofreading-title"
        >
          <h2 id="draft-proofreading-title">
            文章の確認
            {proofreadingMessages.length > 0 && (
              <span> {proofreadingMessages.length}件</span>
            )}
          </h2>
          {proofreadingStatus && (
            <p role={proofreadingStatus === "確認中" ? "status" : undefined}>
              {proofreadingStatus}
            </p>
          )}
          {proofreadingStatus === "" && proofreadingMessages.length === 0 && (
            <p>指摘はありません</p>
          )}
          {proofreadingMessages.length > 0 && (
            <ol>
              {proofreadingMessages.map((item) => (
                <li
                  key={`${item.ruleId}-${item.range.join("-")}-${item.message}`}
                >
                  <button
                    type="button"
                    onClick={() => {
                      const field = textarea.current;
                      if (!field) return;
                      field.focus();
                      field.setSelectionRange(item.range[0], item.range[1]);
                    }}
                  >
                    <span>{item.line}行目</span>
                    <span>{item.message}</span>
                  </button>
                </li>
              ))}
            </ol>
          )}
        </section>
        {session && (
          <DraftSuggestions
            session={session}
            articleId={id}
            textarea={textarea}
            csrf={csrf}
          />
        )}
      </DraftNavigation>
      <div className="draft-editor__titlebar">
        <div className="draft-editor__heading-fields">
          <label className="visually-hidden" htmlFor="draft-title">
            タイトル
          </label>
          <input
            id="draft-title"
            placeholder="タイトル"
            value={session?.metadata.title || ""}
            disabled={!session || session.isPublishing}
            onChange={(event) => {
              session?.setMetadata(draftMetadataForTitle(event.target.value));
            }}
          />
          {session && <DraftTagInput session={session} />}
        </div>
        <div className="draft-editor__controls">
          {session && (
            <DraftArticleSettings
              session={session}
              onDownload={exportMarkdown}
              onDelete={
                articleState === "draft"
                  ? async () => {
                      if (
                        !window.confirm(
                          "未公開の下書き全体を削除しますか？取り込み元のメモはInboxへ戻ります。下書き内での加筆は削除されます。この操作は取り消せません。",
                        )
                      )
                        return;
                      await session.deleteDraft();
                      window.location.href = "/authoring/articles";
                    }
                  : undefined
              }
            />
          )}
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
            {session?.error && (
              <button type="button" onClick={recoverAsNewDraft}>
                内容を新しい下書きへ復旧
              </button>
            )}
          </div>
          <button
            className="draft-editor__publish"
            type="button"
            disabled={!session || session.isPublishing || !!imageUploadStatus}
            onClick={() => void publish()}
          >
            {session?.isPublishing
              ? articleState === "draft"
                ? "公開中"
                : "更新中"
              : session?.pendingPublication
                ? "公開を再試行"
                : articleState === "draft"
                  ? "公開する"
                  : "更新する"}
          </button>
        </div>
      </div>
      <div className="draft-editor__status">
        <p id="draft-size">
          {bytes >= DRAFT_BODY_LIMIT * 0.9
            ? `本文 ${Math.ceil(bytes / 1024)} / 512 KiB。上限を超えても本文は削除されません。`
            : ""}
        </p>
        <p role="status">{imageUploadStatus}</p>
        {videoUpload.current && (
          <button type="button" onClick={() => videoUpload.current?.abort()}>
            動画の追加をキャンセル
          </button>
        )}
        <p role="alert">
          {loadError || publicationError || imageUploadError || session?.error}
        </p>
        {session?.legacyRecovery && (
          <details>
            <summary>形式変換前の端末の本文を確認</summary>
            <p>
              未送信の文章を端末に退避しました。必要な変更を下のかけらへコピーしてください。公開済みの記事は維持しています。
            </p>
            <textarea
              aria-label="形式変換前の退避した本文"
              readOnly
              rows={8}
              value={session.legacyRecovery.body}
            />
          </details>
        )}
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
        <div
          className={`draft-editor__source${pieceDiary ? " draft-editor__source--pieces" : ""}`}
        >
          {(session?.pieces ? session.pieces.local.piece_ids : ["body"]).map(
            (id, index) => (
              <fieldset
                key={id}
                aria-label={
                  pieceDiary ? `${index + 1}番目のかけら` : "本文の編集"
                }
                data-piece-id={pieceDiary ? id : undefined}
                className={`draft-piece-editor${pieceDiary && id === session?.activePieceId ? " is-active" : ""}${dropPiece === id ? " is-drop-target" : ""}`}
                onDragOver={(event) => {
                  if (
                    !event.dataTransfer.types.includes(
                      "application/x-weblog-piece",
                    )
                  )
                    return;
                  event.preventDefault();
                  event.dataTransfer.dropEffect = "move";
                  setDropPiece(id);
                }}
                onDrop={(event) => {
                  const moved = event.dataTransfer.getData(
                    "application/x-weblog-piece",
                  );
                  if (!moved) return;
                  event.preventDefault();
                  session?.movePieceTo(moved, id);
                  setDropPiece(undefined);
                }}
              >
                {session?.pieces && (
                  <div className="draft-piece-editor__tools">
                    <button
                      type="button"
                      draggable
                      disabled={session.isPublishing}
                      aria-label="かけらを移動"
                      title="ドラッグ、または上下キーで移動"
                      onKeyDown={(event) => {
                        if (
                          event.key !== "ArrowUp" &&
                          event.key !== "ArrowDown"
                        )
                          return;
                        event.preventDefault();
                        session.movePiece(id, event.key === "ArrowUp" ? -1 : 1);
                      }}
                      onPointerDown={(event) => {
                        if (event.pointerType === "mouse") return;
                        event.currentTarget.setPointerCapture(event.pointerId);
                        draggedPiece.current = id;
                      }}
                      onPointerMove={(event) => {
                        if (
                          !event.currentTarget.hasPointerCapture(
                            event.pointerId,
                          )
                        )
                          return;
                        const target = document
                          .elementFromPoint(event.clientX, event.clientY)
                          ?.closest<HTMLElement>("[data-piece-id]");
                        setDropPiece(target?.dataset.pieceId);
                      }}
                      onPointerUp={(event) => {
                        if (
                          !event.currentTarget.hasPointerCapture(
                            event.pointerId,
                          )
                        )
                          return;
                        const target = document
                          .elementFromPoint(event.clientX, event.clientY)
                          ?.closest<HTMLElement>("[data-piece-id]")
                          ?.dataset.pieceId;
                        if (draggedPiece.current && target)
                          session.movePieceTo(draggedPiece.current, target);
                        event.currentTarget.releasePointerCapture(
                          event.pointerId,
                        );
                        draggedPiece.current = undefined;
                        setDropPiece(undefined);
                      }}
                      onPointerCancel={() => {
                        draggedPiece.current = undefined;
                        setDropPiece(undefined);
                      }}
                      onDragEnd={() => setDropPiece(undefined)}
                      onDragStart={(event) =>
                        event.dataTransfer.setData(
                          "application/x-weblog-piece",
                          id,
                        )
                      }
                    >
                      <AuthoringIcon name="dots" />
                    </button>
                    <button
                      type="button"
                      disabled={session.isPublishing}
                      aria-label="かけらを削除"
                      title="かけらを削除"
                      onClick={() => {
                        if (window.confirm("このかけらを削除しますか？")) {
                          session.removePiece(id);
                          requestAnimationFrame(() =>
                            textarea.current?.focus(),
                          );
                        }
                      }}
                    >
                      <AuthoringIcon name="close" />
                    </button>
                  </div>
                )}
                <textarea
                  ref={(field) => {
                    if (!pieceDiary || session?.activePieceId === id)
                      textarea.current = field;
                    else if (field && session)
                      field.value = session.doc
                        .getText(`piece:${id}`)
                        .toString();
                  }}
                  defaultValue={
                    pieceDiary
                      ? session?.doc.getText(`piece:${id}`).toString()
                      : undefined
                  }
                  rows={
                    pieceDiary
                      ? Math.max(
                          3,
                          (session?.doc
                            .getText(`piece:${id}`)
                            .toString()
                            .split("\n").length || 0) + 1,
                        )
                      : undefined
                  }
                  onFocus={() => {
                    if (pieceDiary && session?.activePieceId !== id)
                      session?.selectPiece(id);
                  }}
                  aria-label={pieceDiary ? `${index + 1}番目のかけら` : "本文"}
                  aria-describedby="draft-size"
                  aria-invalid={bytes > DRAFT_BODY_LIMIT}
                  disabled={
                    !session ||
                    session.isPublishing ||
                    !!imageUploadStatus ||
                    session.pieces?.local.piece_ids.length === 0
                  }
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
                  onKeyDown={(event) => {
                    handleWikiLinkSuggestionKeyDown(event);
                    if (
                      event.defaultPrevented ||
                      event.metaKey ||
                      event.ctrlKey ||
                      event.altKey ||
                      event.shiftKey ||
                      composing.current ||
                      !pieceDiary ||
                      !session?.pieces
                    )
                      return;
                    const field = event.currentTarget;
                    if (field.selectionStart !== field.selectionEnd) return;
                    const direction =
                      event.key === "ArrowUp" && field.selectionStart === 0
                        ? -1
                        : event.key === "ArrowDown" &&
                            field.selectionStart === field.value.length
                          ? 1
                          : 0;
                    const target =
                      session.pieces.local.piece_ids[index + direction];
                    if (!direction || !target) return;
                    event.preventDefault();
                    const caret =
                      direction < 0
                        ? session.doc.getText(`piece:${target}`).length
                        : 0;
                    session.selectPiece(target);
                    requestAnimationFrame(() => {
                      textarea.current?.focus();
                      textarea.current?.setSelectionRange(caret, caret);
                    });
                  }}
                  onDragOver={(event) => {
                    if (
                      Array.from(event.dataTransfer.items).some(
                        (item) =>
                          item.kind === "file" &&
                          (item.type.startsWith("image/") ||
                            item.type.startsWith("video/")),
                      )
                    ) {
                      event.preventDefault();
                      event.dataTransfer.dropEffect = "copy";
                    }
                  }}
                  onDrop={(event) => void handleImageDrop(event)}
                  onPaste={(event) => void handleImagePaste(event)}
                />
              </fieldset>
            ),
          )}
          {session && <DraftPieceControls session={session} />}
          {wikiLinkSuggestions.length > 0 && (
            <div
              ref={wikiLinkSuggestionList}
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
              body={session.markdown}
              pieces={session.contentPieces}
              tags={session.pieces?.local.tags}
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
          event.preventDefault();
          if (publicationFlow !== "running") event.currentTarget.close();
        }}
        onKeyDown={(event) => {
          if (event.key !== "Escape") return;
          event.preventDefault();
          if (publicationFlow !== "running") event.currentTarget.close();
        }}
        onClick={(event) => {
          if (
            publicationFlow === "running" ||
            event.target !== event.currentTarget
          )
            return;
          const bounds = event.currentTarget.getBoundingClientRect();
          if (
            event.clientX < bounds.left ||
            event.clientX > bounds.right ||
            event.clientY < bounds.top ||
            event.clientY > bounds.bottom
          )
            event.currentTarget.close();
        }}
      >
        <h2 id="draft-publication-title">
          {publicationFlow === "success"
            ? publicationIntent === "update"
              ? "記事を更新しました"
              : "記事を公開しました"
            : publicationFlow === "error"
              ? "処理を完了できませんでした"
              : publicationIntent === "publish"
                ? "記事を公開しています"
                : "記事を更新しています"}
        </h2>
        <p role="status" aria-live="polite">
          {publicationFlow === "running"
            ? session?.publicationStatus ||
              "本文と設定をサーバーへ保存しています。"
            : publicationFlow === "success"
              ? session?.publicationStatus ||
                "公開ページへの反映が完了しました。"
              : publicationError}
          {publicationFlow === "success" && webmentionStatus && (
            <>
              <br />
              {webmentionStatus}
            </>
          )}
        </p>
        <div className="draft-publication-dialog__actions">
          {publicationFlow === "success" && session && (
            <>
              <a href={`/${encodeURIComponent(draftRoute(session.metadata))}`}>
                記事を見る
              </a>
              <a href="/authoring/articles">記事一覧に戻る</a>
              {webmentions?.enabled &&
                (webmentions.targets.length > 0 || webmentions.pending) && (
                  <button
                    type="button"
                    disabled={isSendingWebmentions}
                    onClick={async () => {
                      if (isSendingWebmentions) return;
                      setIsSendingWebmentions(true);
                      try {
                        setWebmentions(
                          await session.sendWebmentions(webmentions.version_id),
                        );
                        setWebmentionStatus(
                          "Webmentionの送信を受け付けました。送信失敗はWebmention管理画面で確認できます。",
                        );
                      } catch (error) {
                        setWebmentionStatus(
                          error instanceof Error
                            ? error.message
                            : "Webmentionを送信できませんでした。再試行してください。",
                        );
                      } finally {
                        setIsSendingWebmentions(false);
                      }
                    }}
                  >
                    {isSendingWebmentions ? "送信を依頼中" : "Webmentionを送る"}
                  </button>
                )}
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
