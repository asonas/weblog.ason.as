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
  writing_excerpt: string;
  relation: "repeated" | "related";
};

type Suggestions = {
  enabled: boolean;
  links: LinkSuggestion[];
  related: RelatedPassage[];
};

type PieceResult = {
  suggestions: Suggestions;
  text: string;
  pieceId: string;
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
  const [results, setResults] = useState<PieceResult[]>([]);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const pieces = session.contentPieces || [
    { id: "body", body: session.body.toString() },
  ];
  const activePieceId = session.activePieceId || "body";
  const result = results.find(
    (item) =>
      item.pieceId === activePieceId && item.text === session.body.toString(),
  );

  useEffect(() => {
    const cache = new Map<string, PieceResult>();
    let timer: ReturnType<typeof setTimeout>;
    let request: AbortController | undefined;
    let revision = 0;
    let composing = false;
    let previousSnapshot = "";
    const schedule = (force = false) => {
      const currentPieces = session.contentPieces || [
        { id: "body", body: session.body.toString() },
      ];
      const snapshot = JSON.stringify(currentPieces);
      if (!force && snapshot === previousSnapshot) return;
      previousSnapshot = snapshot;
      const currentRevision = ++revision;
      clearTimeout(timer);
      request?.abort();
      for (const [id, item] of cache) {
        if (
          !currentPieces.some(
            (piece) => piece.id === id && piece.body === item.text,
          )
        )
          cache.delete(id);
      }
      setResults([...cache.values()]);
      setError("");
      if (!currentPieces.some((piece) => piece.body.trim())) {
        setStatus("本文を入力すると候補を探します");
        return;
      }
      if (!navigator.onLine) {
        setStatus("オフラインのため候補の確認を停止しています");
        return;
      }
      setStatus("");
      if (composing) return;
      const tooLong = currentPieces.some(
        (piece) => Array.from(piece.body).length > 8000,
      );
      const pending = currentPieces.filter(
        (piece) =>
          piece.body.trim() &&
          Array.from(piece.body).length <= 8000 &&
          !cache.has(piece.id),
      );
      if (!pending.length) {
        if (tooLong)
          setStatus("8,000文字を超えるかけらは候補の確認を省略します");
        return;
      }
      timer = setTimeout(async () => {
        const controller = new AbortController();
        request = controller;
        setStatus("候補を確認中");
        try {
          const token = await csrf();
          controller.signal.throwIfAborted();
          for (const piece of pending) {
            controller.signal.throwIfAborted();
            const response = await fetch("/api/authoring/suggestions", {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "X-CSRF-Token": token,
              },
              body: JSON.stringify({
                text: piece.body,
                article_id: articleId,
                piece_id: session.pieces ? piece.id : undefined,
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
            cache.set(piece.id, {
              suggestions,
              text: piece.body,
              pieceId: piece.id,
            });
            setResults([...cache.values()]);
            if (!suggestions.enabled) {
              setStatus("候補の確認は利用できません");
              return;
            }
          }
          setStatus(
            tooLong ? "8,000文字を超えるかけらは候補の確認を省略します" : "",
          );
        } catch {
          if (controller.signal.aborted || revision !== currentRevision) return;
          setStatus("");
          setError("候補を確認できませんでした。次の入力時に再試行します");
        }
      }, 7000);
    };
    const compositionStart = (event: Event) => {
      if (event.target !== textarea.current) return;
      composing = true;
      schedule(true);
    };
    const compositionEnd = () => {
      if (!composing) return;
      composing = false;
      schedule(true);
    };
    const changed = () => schedule();
    const connectionChanged = () => schedule(true);
    session.doc.on("update", changed);
    session.addEventListener("change", changed);
    document.addEventListener("compositionstart", compositionStart, true);
    document.addEventListener("compositionend", compositionEnd, true);
    window.addEventListener("online", connectionChanged);
    window.addEventListener("offline", connectionChanged);
    schedule();
    return () => {
      revision++;
      clearTimeout(timer);
      request?.abort();
      session.doc.off("update", changed);
      session.removeEventListener("change", changed);
      document.removeEventListener("compositionstart", compositionStart, true);
      document.removeEventListener("compositionend", compositionEnd, true);
      window.removeEventListener("online", connectionChanged);
      window.removeEventListener("offline", connectionChanged);
    };
  }, [session, articleId, csrf, textarea]);

  const isCurrent = () =>
    result &&
    result.pieceId === (session.activePieceId || "body") &&
    result.text === session.body.toString() &&
    !session.isPublishing;

  function applyLink(link: LinkSuggestion, source: PieceResult) {
    const currentPieces = session.contentPieces || [
      { id: "body", body: session.body.toString() },
    ];
    if (
      session.isPublishing ||
      !currentPieces.some(
        (piece) => piece.id === source.pieceId && piece.body === source.text,
      )
    )
      return;
    const [start, end] = link.range;
    if (source.text.slice(start, end) !== link.text) return;
    if (session.pieces) session.selectPiece(source.pieceId);
    if ((session.activePieceId || "body") !== source.pieceId) return;
    session.undo.stopCapturing();
    session.setBody(
      source.text.slice(0, start) + link.replacement + source.text.slice(end),
    );
    session.undo.stopCapturing();
    requestAnimationFrame(() => {
      textarea.current?.focus();
      textarea.current?.scrollIntoView({ block: "nearest" });
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
      <ol className="draft-link-suggestions">
        {pieces.flatMap((piece, index) => {
          const source = results.find(
            (item) => item.pieceId === piece.id && item.text === piece.body,
          );
          return (
            source?.suggestions.links.map((link) => {
              const before = source.text.slice(0, link.range[0]);
              const lines = before.split("\n");
              const column = Array.from(lines.at(-1) || "").length + 1;
              return (
                <li key={`${piece.id}:${link.range[0]}:${link.target}`}>
                  <button
                    type="button"
                    disabled={session.isPublishing}
                    onClick={() => applyLink(link, source)}
                  >
                    <span>
                      {session.pieces ? `${index + 1}番目のかけら · ` : ""}
                      {lines.length}行{column}文字目
                    </span>
                    <span>
                      {link.text} → {link.replacement}
                    </span>
                  </button>
                </li>
              );
            }) || []
          );
        })}
      </ol>
      {!status &&
        !error &&
        pieces
          .filter((piece) => piece.body.trim())
          .every((piece) =>
            results.some(
              (item) => item.pieceId === piece.id && item.text === piece.body,
            ),
          ) &&
        results.some((item) => item.suggestions.enabled) &&
        results.every((item) => item.suggestions.links.length === 0) && (
          <p>リンク候補はありません</p>
        )}
      <h2>過去に書いた内容</h2>
      {session.pieces && (
        <p>
          {pieces.findIndex((piece) => piece.id === activePieceId) + 1}
          番目のかけらと比較
        </p>
      )}
      <ol className="draft-related-passages">
        {result?.suggestions.related.map((passage) => (
          <li key={`${passage.article_id}:${passage.piece_id || ""}`}>
            <details>
              <summary>
                <span className="draft-related-passages__title">
                  {passage.title}
                </span>
                <span className="draft-related-passages__meta">
                  {passage.date && (
                    <time dateTime={passage.date}>{passage.date}</time>
                  )}
                  <span>
                    {passage.relation === "repeated"
                      ? "似た記述"
                      : "変化・比較"}
                  </span>
                </span>
                <span className="draft-related-passages__disclosure">
                  記述を比較
                </span>
              </summary>
              <div className="draft-related-passages__comparison">
                <p>
                  {passage.relation === "repeated"
                    ? "同じ経験・結論を書いている可能性があります。"
                    : "同じ具体的な話題について、変化や違いを比較できる候補です。"}
                </p>
                <h3>今のかけら</h3>
                <blockquote>{passage.writing_excerpt}</blockquote>
                <h3>過去の記述</h3>
                <blockquote>{passage.excerpt}</blockquote>
                <a href={passage.url} target="_blank" rel="noreferrer">
                  記事を開く
                </a>
                <button
                  type="button"
                  disabled={session.isPublishing}
                  onClick={() => insertReference(passage)}
                >
                  本文へリンクを挿入
                </button>
              </div>
            </details>
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
