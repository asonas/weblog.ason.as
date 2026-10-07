import { type RefObject, useEffect, useState } from "react";
import type { DraftSession } from "./draftSession";

type LinkSuggestion = {
  text: string;
  range: [number, number];
  target: string;
  title: string;
  replacement: string;
};

type RelatedPassage = {
  article_id: string;
  piece_id?: string;
  title: string;
  target: string;
  url: string;
  date: string | null;
  excerpt: string;
  relation: "repeated" | "related";
};

type Suggestions = {
  enabled: boolean;
  links: LinkSuggestion[];
  related: RelatedPassage[];
};

export function DraftSuggestions({
  session,
  articleId,
  textarea,
  csrf,
}: {
  session: DraftSession;
  articleId: string;
  textarea: RefObject<HTMLTextAreaElement | null>;
  csrf: () => Promise<string>;
}) {
  const [result, setResult] = useState<{
    suggestions: Suggestions;
    text: string;
    pieceId?: string;
  }>();
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const pieceId = session.activePieceId;

  useEffect(() => {
    const body = session.body;
    const field = textarea.current;
    let timer: ReturnType<typeof setTimeout>;
    let request: AbortController | undefined;
    let revision = 0;
    let composing = false;
    const schedule = () => {
      const currentRevision = ++revision;
      clearTimeout(timer);
      request?.abort();
      setResult(undefined);
      setError("");
      const text = body.toString();
      if (!text.trim()) {
        setStatus("本文を入力すると候補を探します");
        return;
      }
      if (Array.from(text).length > 8000) {
        setStatus("8,000文字以下のかけらで候補を探せます");
        return;
      }
      if (!navigator.onLine) {
        setStatus("オフラインのため候補の確認を停止しています");
        return;
      }
      setStatus("");
      if (composing) return;
      timer = setTimeout(async () => {
        const controller = new AbortController();
        request = controller;
        setStatus("候補を確認中");
        try {
          const token = await csrf();
          controller.signal.throwIfAborted();
          const response = await fetch("/api/authoring/suggestions", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": token,
            },
            body: JSON.stringify({
              text,
              article_id: articleId,
              piece_id: pieceId,
            }),
            signal: AbortSignal.any([
              controller.signal,
              AbortSignal.timeout(30000),
            ]),
          });
          if (!response.ok)
            throw new Error(
              "候補を確認できませんでした。次の入力時に再試行します",
            );
          const suggestions = (await response.json()) as Suggestions;
          if (revision !== currentRevision || composing) return;
          setResult({ suggestions, text, pieceId });
          setStatus(suggestions.enabled ? "" : "候補の確認は利用できません");
        } catch {
          if (controller.signal.aborted || revision !== currentRevision) return;
          setStatus("");
          setError("候補を確認できませんでした。次の入力時に再試行します");
        }
      }, 7000);
    };
    const compositionStart = () => {
      composing = true;
      schedule();
    };
    const compositionEnd = () => {
      composing = false;
      schedule();
    };
    body.observe(schedule);
    field?.addEventListener("compositionstart", compositionStart);
    field?.addEventListener("compositionend", compositionEnd);
    window.addEventListener("online", schedule);
    window.addEventListener("offline", schedule);
    schedule();
    return () => {
      revision++;
      clearTimeout(timer);
      request?.abort();
      body.unobserve(schedule);
      field?.removeEventListener("compositionstart", compositionStart);
      field?.removeEventListener("compositionend", compositionEnd);
      window.removeEventListener("online", schedule);
      window.removeEventListener("offline", schedule);
    };
  }, [session, pieceId, articleId, csrf, textarea]);

  const isCurrent = () =>
    result &&
    result.pieceId === session.activePieceId &&
    result.text === session.body.toString() &&
    !session.isPublishing;

  function applyLink(link: LinkSuggestion) {
    if (!isCurrent() || !result) return;
    const [start, end] = link.range;
    if (result.text.slice(start, end) !== link.text) return;
    session.undo.stopCapturing();
    session.setBody(
      result.text.slice(0, start) + link.replacement + result.text.slice(end),
    );
    session.undo.stopCapturing();
    requestAnimationFrame(() => {
      textarea.current?.focus();
      textarea.current?.setSelectionRange(
        start,
        start + link.replacement.length,
      );
    });
  }

  function insertReference(passage: RelatedPassage) {
    const field = textarea.current;
    if (!isCurrent() || !result || !field || /[[\]\r\n]/.test(passage.target))
      return;
    const position = field.selectionEnd;
    const link = `[[${passage.target}]]`;
    session.undo.stopCapturing();
    session.setBody(
      result.text.slice(0, position) + link + result.text.slice(position),
    );
    session.undo.stopCapturing();
    requestAnimationFrame(() => {
      field.focus();
      field.setSelectionRange(position + link.length, position + link.length);
    });
  }

  return (
    <section
      className="draft-proofreading draft-suggestions"
      aria-label="執筆の候補"
    >
      {status && <p role="status">{status}</p>}
      {error && <p role="alert">{error}</p>}
      <h2>リンク候補</h2>
      <p>クリックすると表示されたwikiリンクに置き換えます。</p>
      <ol>
        {result?.suggestions.links.map((link) => (
          <li key={`${link.range[0]}:${link.target}`}>
            <button
              type="button"
              disabled={session.isPublishing}
              onClick={() => applyLink(link)}
            >
              <span>{link.text}</span>
              <span>→ {link.replacement}</span>
            </button>
          </li>
        ))}
      </ol>
      {result?.suggestions.enabled && result.suggestions.links.length === 0 && (
        <p>リンク候補はありません</p>
      )}
      <h2>過去に書いた内容</h2>
      <ol>
        {result?.suggestions.related.map((passage) => (
          <li key={`${passage.article_id}:${passage.piece_id || ""}`}>
            <p>
              {passage.relation === "repeated"
                ? "以前にも似た内容"
                : "続き・比較として関連"}
            </p>
            <a href={passage.url} target="_blank" rel="noreferrer">
              {passage.title}
            </a>
            {passage.date && <time>{passage.date}</time>}
            <blockquote>{passage.excerpt}</blockquote>
            <button
              type="button"
              disabled={session.isPublishing}
              onClick={() => insertReference(passage)}
            >
              記事へのリンクを挿入
            </button>
          </li>
        ))}
      </ol>
      {result?.suggestions.enabled &&
        result.suggestions.related.length === 0 && (
          <p>関連する記述は見つかりませんでした</p>
        )}
    </section>
  );
}
