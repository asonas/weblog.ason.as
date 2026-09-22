import { type RefObject, useCallback, useEffect, useState } from "react";
import type { DraftSession } from "./draftSession";
import { videoAssetPath } from "./Video";

type InboxSource = "photo" | "video" | "bluesky" | "raindrop";

type InboxItem = {
  id: string;
  source: InboxSource | "c4p";
  kind: "photo" | "video" | "post" | "like" | "bookmark" | "track";
  payload: Record<string, unknown>;
};

type InboxResponse = { items: Array<InboxItem> };
type InboxSyncResponse = { run_id: string; status: "queued" };
type InboxSyncStatus = {
  status:
    | "queued"
    | "running"
    | "succeeded"
    | "completed_with_errors"
    | "failed";
};

const COLUMNS: Array<{
  source: InboxSource;
  kind?: InboxItem["kind"];
  label: string;
}> = [
  { source: "photo", label: "写真" },
  { source: "video", label: "動画" },
  { source: "raindrop", label: "Raindrop" },
  { source: "bluesky", kind: "post", label: "Bsky（自分の投稿）" },
  { source: "bluesky", kind: "like", label: "Bsky（いいね）" },
];

function payloadString(item: InboxItem, key: string): string | null {
  const value = item.payload[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function httpUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:"
      ? url.href
      : null;
  } catch {
    return null;
  }
}

function insertMarkdownBlock(
  body: string,
  start: number,
  end: number,
  markdown: string,
): { body: string; caret: number } {
  const before = body.slice(0, start);
  const after = body.slice(end);
  const leading =
    before && !before.endsWith("\n\n")
      ? before.endsWith("\n")
        ? "\n"
        : "\n\n"
      : "";
  const trailing =
    after && !after.startsWith("\n\n")
      ? after.startsWith("\n")
        ? "\n"
        : "\n\n"
      : "";
  const inserted = `${leading}${markdown}${trailing}`;
  return {
    body: `${before}${inserted}${after}`,
    caret: before.length + leading.length + markdown.length,
  };
}

function itemMarkdown(item: InboxItem): string | null {
  if (item.source === "video") {
    const avc = videoAssetPath(item.payload.avc);
    if (!avc) return null;
    const av1 = videoAssetPath(item.payload.av1);
    const width = Number(item.payload.width);
    const height = Number(item.payload.height);
    const dimensions =
      Number.isInteger(width) &&
      width > 0 &&
      Number.isInteger(height) &&
      height > 0
        ? ` ${width}x${height}`
        : "";
    return `:::video ${avc}${av1 ? ` ${av1}` : ""}${dimensions} :::`;
  }
  if (item.source === "raindrop" && item.kind === "bookmark")
    return httpUrl(item.payload.url);
  if (item.source === "bluesky") return httpUrl(item.payload.canonical_url);
  return null;
}

async function responseJson<T>(response: Response): Promise<T> {
  let result: unknown;
  try {
    result = await response.json();
  } catch {
    throw new Error("サーバーからの応答を読み取れませんでした");
  }
  if (!response.ok) {
    const message =
      typeof result === "object" &&
      result !== null &&
      "error" in result &&
      typeof result.error === "string"
        ? result.error
        : "操作を完了できませんでした";
    throw new Error(message);
  }
  return result as T;
}

export function DraftInbox({
  session,
  textarea,
}: {
  session: DraftSession;
  textarea: RefObject<HTMLTextAreaElement | null>;
}) {
  const [items, setItems] = useState<Array<InboxItem>>([]);
  const [error, setError] = useState("");
  const [busyItem, setBusyItem] = useState<string>();
  const [syncingSource, setSyncingSource] = useState<InboxSource>();

  const load = useCallback(async () => {
    try {
      const response = await fetch("/api/inbox", {
        headers: { Accept: "application/json" },
      });
      const result = await responseJson<InboxResponse>(response);
      setItems(result.items);
      setError("");
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "素材を読み込めませんでした",
      );
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const sync = useCallback(
    async (source: InboxSource) => {
      if (syncingSource) return;
      if (!navigator.onLine) {
        setError("オフラインでは素材を更新できません");
        return;
      }
      setSyncingSource(source);
      setError("");
      try {
        if (source === "photo" || source === "video") {
          await load();
        } else {
          const csrfToken = document.documentElement.dataset.csrfToken;
          const response = await fetch("/api/inbox/sync", {
            method: "POST",
            headers: {
              Accept: "application/json",
              "Content-Type": "application/json",
              ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
            },
            body: JSON.stringify({ sources: [source] }),
          });
          const started = await responseJson<InboxSyncResponse>(response);
          let run: InboxSyncStatus = started;
          while (run.status === "queued" || run.status === "running") {
            await new Promise((resolve) => window.setTimeout(resolve, 1_000));
            run = await responseJson<InboxSyncStatus>(
              await fetch(
                `/api/inbox/sync/${encodeURIComponent(started.run_id)}`,
                { headers: { Accept: "application/json" } },
              ),
            );
          }
          await load();
          if (run.status === "failed")
            throw new Error("素材を更新できませんでした");
          if (run.status === "completed_with_errors")
            setError("一部の素材を更新できませんでした");
        }
      } catch (cause) {
        setError(
          cause instanceof Error ? cause.message : "素材を更新できませんでした",
        );
      } finally {
        setSyncingSource(undefined);
      }
    },
    [load, syncingSource],
  );

  const insert = useCallback(
    async (item: InboxItem) => {
      const field = textarea.current;
      if (!field || busyItem || session.isPublishing) return;
      if (!navigator.onLine) {
        setError(
          "オフラインでは素材を追加できません。本文の編集は続けられます。",
        );
        return;
      }

      setBusyItem(item.id);
      setError("");
      try {
        let markdown = itemMarkdown(item);
        if (item.source === "photo" && item.kind === "photo") {
          const csrfToken = document.documentElement.dataset.csrfToken;
          const response = await fetch("/api/inbox/adopt", {
            method: "POST",
            headers: {
              Accept: "application/json",
              "Content-Type": "application/json",
              ...(csrfToken ? { "X-CSRF-Token": csrfToken } : {}),
            },
            body: JSON.stringify({ item_id: item.id }),
          });
          const result = await responseJson<{ public_url: string }>(response);
          markdown = result.public_url.startsWith("/assets/uploads/")
            ? `![](${result.public_url})`
            : null;
        }
        if (!markdown)
          throw new Error("素材のURLが不正なため追加できませんでした");
        if (session.isPublishing)
          throw new Error(
            "公開処理中は素材を追加できません。完了後にもう一度選んでください。",
          );

        const next = insertMarkdownBlock(
          field.value,
          field.selectionStart,
          field.selectionEnd,
          markdown,
        );
        session.undo.stopCapturing();
        session.setBody(next.body);
        session.undo.stopCapturing();
        requestAnimationFrame(() => {
          field.focus();
          field.setSelectionRange(next.caret, next.caret);
        });
      } catch (cause) {
        setError(
          cause instanceof Error ? cause.message : "素材を追加できませんでした",
        );
      } finally {
        setBusyItem(undefined);
      }
    },
    [busyItem, session, textarea],
  );

  return (
    <section className="draft-inbox" aria-label="素材">
      <div className="draft-inbox__columns">
        {COLUMNS.map(({ source, kind, label }) => {
          const columnItems = items.filter(
            (item) => item.source === source && (!kind || item.kind === kind),
          );
          return (
            <section
              className="draft-inbox__column"
              aria-label={label}
              key={`${source}-${kind || "all"}`}
            >
              <header>
                <h2>
                  {label}{" "}
                  <span className="draft-inbox__count">
                    {columnItems.length}
                  </span>
                </h2>
                <button
                  className="draft-inbox__reload"
                  type="button"
                  onClick={() => void sync(source)}
                  aria-label={`${label}を再読み込み`}
                  disabled={Boolean(syncingSource)}
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
              {columnItems.length === 0 ? (
                <p className="draft-inbox__empty">素材はありません</p>
              ) : (
                <ol
                  className={
                    source === "photo" ? "draft-inbox__photos" : undefined
                  }
                >
                  {columnItems.map((item) => {
                    const photo = payloadString(item, "preview_url");
                    const thumbnail =
                      source === "raindrop"
                        ? payloadString(item, "cover")
                        : source === "bluesky"
                          ? payloadString(item, "thumbnail_url")
                          : null;
                    const title =
                      source === "raindrop"
                        ? payloadString(item, "title")
                        : source === "bluesky"
                          ? payloadString(item, "author_display_name") ||
                            payloadString(item, "author_handle")
                          : null;
                    const excerpt =
                      source === "raindrop"
                        ? payloadString(item, "excerpt")
                        : source === "bluesky"
                          ? payloadString(item, "text")
                          : null;
                    const video = videoAssetPath(item.payload.avc);
                    return (
                      <li key={item.id}>
                        <button
                          type="button"
                          className={`draft-inbox__item draft-inbox__item--${source}`}
                          aria-label={`${label}を本文へ追加`}
                          disabled={Boolean(busyItem) || session.isPublishing}
                          onClick={() => void insert(item)}
                        >
                          {source === "photo" && photo && (
                            <img src={photo} alt="" loading="lazy" />
                          )}
                          {source === "video" && video && (
                            <video
                              src={`${video}#t=0.001`}
                              preload="metadata"
                              muted
                              playsInline
                            />
                          )}
                          {(source === "raindrop" || source === "bluesky") && (
                            <span className="draft-inbox__details">
                              {thumbnail && (
                                <img src={thumbnail} alt="" loading="lazy" />
                              )}
                              <span>
                                {title && (
                                  <strong className="draft-inbox__item-title">
                                    {title}
                                  </strong>
                                )}
                                {excerpt && (
                                  <span className="draft-inbox__item-excerpt">
                                    {excerpt}
                                  </span>
                                )}
                              </span>
                            </span>
                          )}
                        </button>
                      </li>
                    );
                  })}
                </ol>
              )}
            </section>
          );
        })}
      </div>
      {error && (
        <p className="draft-inbox__error" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
