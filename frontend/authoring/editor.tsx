import { Extension, markInputRule } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { useCallback, useEffect, useRef, useState } from "react";

import { markdownForEditor, markdownForSource } from "./markdown";

function encodePageName(name: string): string {
  return encodeURIComponent(name).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

const WikiLinkInput = Extension.create({
  name: "wikiLinkInput",

  addInputRules() {
    return [
      markInputRule({
        find: /\[\[([^\[\]]+)\]\]$/,
        type: this.editor.schema.marks.link,
        getAttributes: (match) => ({
          href: `/${encodePageName(match[1].trim())}`
        })
      })
    ];
  }
});

export type EditorBootstrap = {
  page_id: string;
  page_type: "date" | "named";
  date: string;
  name: string;
  title: string;
  body: string;
  expected_updated_at: string;
  save_message: string;
};

type EditorDraft = {
  pageId: string;
  pageType: "date" | "named";
  date: string;
  name: string;
  title: string;
  body: string;
  expectedUpdatedAt: string;
};

type PageResponse = {
  id: string;
  page_type: "date" | "named";
  date: string | null;
  name: string | null;
  title: string | null;
  updated_at: string | null;
  route: string;
};

type ApiError = Error & {
  fields?: Record<string, string[]>;
};

type JsonObject = Record<string, unknown>;

const EDITOR_EXTENSIONS = [
  StarterKit.configure({
    dropcursor: false,
    gapcursor: false,
    underline: false,
    link: {
      openOnClick: false,
      autolink: false,
      linkOnPaste: false,
      HTMLAttributes: {
        target: "_blank",
        rel: "noopener noreferrer"
      }
    }
  }),
  WikiLinkInput,
  Markdown.configure({ indentation: { style: "space", size: 2 } })
];

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function initialDraft(bootstrap: EditorBootstrap): EditorDraft {
  return {
    pageId: bootstrap.page_id,
    pageType: bootstrap.page_type,
    date: bootstrap.date,
    name: bootstrap.name,
    title: bootstrap.title,
    body: bootstrap.body,
    expectedUpdatedAt: bootstrap.expected_updated_at
  };
}

async function requestJson<T>(url: string, payload: JsonObject): Promise<T> {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(payload)
  });

  let raw: unknown;
  try {
    raw = await response.json();
  } catch (_error) {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }

  if (!response.ok) {
    const result = isJsonObject(raw) ? raw : {};
    const error = new Error(typeof result.error === "string" ? result.error : "操作を完了できませんでした") as ApiError;
    if (isJsonObject(result.errors)) {
      error.fields = result.errors as Record<string, string[]>;
    }
    throw error;
  }

  return raw as T;
}

function statusMessage(page: PageResponse): string {
  return page.updated_at ? `自動公開済み・最終更新 ${page.updated_at}` : "自動公開済み";
}

export function AuthoringEditor({ bootstrap }: { bootstrap: EditorBootstrap }) {
  const [draft, setDraft] = useState<EditorDraft>(() => initialDraft(bootstrap));
  const [status, setStatus] = useState(bootstrap.save_message);
  const [errors, setErrors] = useState<Record<string, string[]>>({});
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [renameName, setRenameName] = useState(bootstrap.name);
  const draftRef = useRef(draft);
  const dirtyRef = useRef(false);
  const savingRef = useRef(false);
  const editVersionRef = useRef(0);
  const savedTitleRef = useRef(bootstrap.title);
  const saveTimerRef = useRef<number | null>(null);
  const pendingSaveRef = useRef(false);

  const updateDraft = useCallback((changes: Partial<EditorDraft>) => {
    const next = { ...draftRef.current, ...changes };
    draftRef.current = next;
    setDraft(next);
    return next;
  }, []);

  const setDirtyState = useCallback((value: boolean) => {
    dirtyRef.current = value;
    setDirty(value);
  }, []);

  const saveAndPublish = useCallback(async () => {
    if (!draftRef.current.pageId && !draftRef.current.title.trim()) return;
    if (savingRef.current) {
      pendingSaveRef.current = true;
      return;
    }

    if (saveTimerRef.current !== null) {
      window.clearTimeout(saveTimerRef.current);
      saveTimerRef.current = null;
    }

    const snapshot = { ...draftRef.current };
    const savedVersion = editVersionRef.current;
    savingRef.current = true;
    setSaving(true);
    setStatus("保存中…");

    try {
      const page = await requestJson<PageResponse>("/api/save-and-publish", {
        page_id: snapshot.pageId,
        page_type: snapshot.pageType,
        date: snapshot.date,
        name: snapshot.name || undefined,
        title: snapshot.title || undefined,
        body: snapshot.body,
        expected_updated_at: snapshot.expectedUpdatedAt || undefined
      });
      const current = draftRef.current;
      const next = {
        ...current,
        pageId: page.id,
        pageType: page.page_type,
        date: page.date || current.date,
        name: page.name || current.name,
        expectedUpdatedAt: page.updated_at || ""
      };
      draftRef.current = next;
      setDraft(next);
      setRenameName(next.name);
      savedTitleRef.current = snapshot.title;
      setErrors({});
      setStatus(statusMessage(page));
      setDirtyState(editVersionRef.current !== savedVersion);
      if (editVersionRef.current !== savedVersion) pendingSaveRef.current = true;
    } catch (error) {
      const apiError = error as ApiError;
      const nextErrors = apiError.fields || { form: [apiError.message] };
      setErrors(nextErrors);
      setStatus(apiError.message);
      setDirtyState(true);
    } finally {
      savingRef.current = false;
      setSaving(false);
      if (pendingSaveRef.current) {
        pendingSaveRef.current = false;
        window.setTimeout(() => void saveAndPublish(), 0);
      }
    }
  }, [setDirtyState]);

  const scheduleSave = useCallback(() => {
    if (!draftRef.current.pageId) return;
    if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    saveTimerRef.current = window.setTimeout(() => {
      saveTimerRef.current = null;
      void saveAndPublish();
    }, 700);
  }, [saveAndPublish]);

  const handleBodyChange = useCallback((markdown: string) => {
    updateDraft({ body: markdownForSource(markdown) });
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
    scheduleSave();
  }, [scheduleSave, setDirtyState, updateDraft]);

  const editor = useEditor({
    extensions: EDITOR_EXTENSIONS,
    content: markdownForEditor(bootstrap.body),
    contentType: "markdown",
    editorProps: {
      attributes: {
        role: "textbox",
        "aria-multiline": "true",
        "aria-labelledby": "body-label",
        "aria-describedby": "body-errors"
      }
    },
    onUpdate: ({ editor: currentEditor }) => {
      handleBodyChange(currentEditor.getMarkdown());
    }
  });

  const confirmTitle = useCallback(async () => {
    const current = draftRef.current;
    if (!current.title.trim()) {
      setErrors({ title: [current.pageType === "named" ? "ページ名を入力してください" : "タイトルを入力してください"] });
      setStatus("タイトルを確定できません");
      return;
    }
    if (current.title === savedTitleRef.current && current.pageId) return;
    setErrors({});
    await saveAndPublish();
  }, [saveAndPublish]);

  const handleTitleChange = useCallback((value: string) => {
    updateDraft({ title: value });
    editVersionRef.current += 1;
    setErrors({});
    setDirtyState(true);
  }, [setDirtyState, updateDraft]);

  const handleRename = useCallback(async () => {
    const current = draftRef.current;
    if (!current.pageId || current.pageType !== "named") return;
    if (dirtyRef.current || savingRef.current) {
      setStatus("保存が完了してからページ名を変更してください");
      return;
    }
    if (!renameName.trim()) return;

    try {
      const page = await requestJson<PageResponse>("/api/rename", {
        page_id: current.pageId,
        name: renameName
      });
      const nextName = page.name || "";
      updateDraft({ name: nextName, title: nextName });
      savedTitleRef.current = nextName;
      setRenameName(nextName);
      setStatus(statusMessage(page));
      setErrors({});
    } catch (error) {
      const apiError = error as ApiError;
      setErrors(apiError.fields || { name: [apiError.message] });
      setStatus(apiError.message);
    }
  }, [renameName, updateDraft]);

  useEffect(() => {
    const handleBeforeUnload = (event: BeforeUnloadEvent) => {
      if (!dirtyRef.current && !savingRef.current) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => {
      window.removeEventListener("beforeunload", handleBeforeUnload);
      if (saveTimerRef.current !== null) window.clearTimeout(saveTimerRef.current);
    };
  }, []);

  const titleErrors = errors.title || errors.name || [];
  const bodyErrors = errors.body || [];
  const formErrors = errors.form || [];
  const titleDisabled = draft.pageType === "named" && draft.pageId.length > 0;

  return (
    <>
      <h1>編集</h1>
      <p className="save-status" role="status" aria-live="polite" aria-busy={saving}>
        {status}
      </p>
      {formErrors.length > 0 && <p className="input-error" role="alert">{formErrors.join(" ")}</p>}
      <section className="editor-shell" aria-labelledby="editor-heading">
        <h2 id="editor-heading" className="visually-hidden">記事の編集</h2>
        <div className="field-group">
          <label htmlFor="title">{draft.pageType === "named" ? "ページ名（1行目）" : "タイトル（1行目）"}</label>
          <input
            id="title"
            name="title"
            value={draft.title}
            disabled={titleDisabled}
            aria-describedby="title-errors"
            aria-invalid={titleErrors.length > 0}
            onChange={(event) => handleTitleChange(event.target.value)}
            onBlur={() => void confirmTitle()}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                event.preventDefault();
                event.currentTarget.blur();
              }
            }}
          />
          <p id="title-errors" className="input-error" aria-live="polite">{titleErrors.join(" ")}</p>
        </div>
        <div className="field-group">
          <div id="body-label" className="field-label">本文</div>
          <div className="wysiwyg-editor" aria-busy={saving}>
            <EditorContent editor={editor} />
          </div>
          <p id="body-errors" className="input-error" aria-live="polite">{bodyErrors.join(" ")}</p>
          <p className="editor-help">タイトルを確定すると保存・公開します。本文は変更後に自動保存されます。</p>
        </div>
      </section>
      {draft.pageType === "named" && draft.pageId.length > 0 && (
        <section className="settings-panel" aria-labelledby="rename-heading">
          <h2 id="rename-heading">ページ設定</h2>
          <div className="field-group">
            <label htmlFor="page-name">ページ名</label>
            <input
              id="page-name"
              name="page-name"
              value={renameName}
              aria-describedby="rename-errors"
              aria-invalid={Boolean(errors.name)}
              onChange={(event) => setRenameName(event.target.value)}
            />
            <p id="rename-errors" className="input-error" aria-live="polite">{(errors.name || []).join(" ")}</p>
          </div>
          <button type="button" onClick={() => void handleRename()} disabled={saving || dirty}>ページ名を変更</button>
        </section>
      )}
    </>
  );
}
