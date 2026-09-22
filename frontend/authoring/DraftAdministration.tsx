import { useCallback, useEffect, useRef, useState } from "react";
import { AuthoringIcon } from "./AuthoringIcon";
import { DraftArticleMenu } from "./DraftArticleMenu";
import { DraftNavigation } from "./DraftNavigation";
import { storeDraftInitialBody } from "./draftInitialBody";
import {
  type DraftMetadata,
  draftRoute,
  type LocalDraftSummary,
  readLocalDraftSummaries,
} from "./draftSession";
import "./draftEditor.css";
import "./draftAdministration.css";
import "./authoringTheme.css";

type Article = {
  id: string;
  head: number;
  metadata: DraftMetadata;
  updated_at: string;
  published_at: string | null;
  webmention_count: number | null;
  public_route: string | null;
  public_hash: string | null;
  state: "draft" | "public" | "unpublished_changes" | "unknown";
  state_error?: string;
  publication: {
    id: string;
    status: string;
    error?: string;
    stages: { stage: string; status: string; error?: string }[];
  } | null;
};
type Row = Article & { local?: LocalDraftSummary; localOnly?: boolean };
const FILTERS = [
  ["all", "すべて"],
  ["draft", "下書き"],
  ["unpublished_changes", "未公開の変更あり"],
  ["public", "公開中"],
  ["attention", "要確認"],
] as const;
type Filter = (typeof FILTERS)[number][0];
const STATES = {
  draft: "下書き",
  public: "公開中",
  unpublished_changes: "未公開の変更あり",
  unknown: "状態を確認できません",
};
const STAGES: Record<string, string> = {
  html: "ページ",
  atom: "フィード",
  search: "検索",
};
type ArticlePage = { articles: Article[]; cursor: string | null };
function needsAttention(row: Row) {
  return (
    row.state === "unknown" ||
    Boolean(row.state_error) ||
    row.publication?.status === "needs_attention" ||
    row.publication?.status === "superseded" ||
    row.publication?.stages.some((stage) =>
      ["needs_attention", "retry_wait"].includes(stage.status),
    )
  );
}
function serverStatus(row: Row, available: boolean) {
  if (row.localOnly)
    return available
      ? { label: "端末のみ", detail: "サーバー未保存", tone: "pending" }
      : {
          label: "保存未確認",
          detail: "サーバー保存を未確認",
          tone: "unknown",
        };
  if (row.local?.pending)
    return {
      label: "未送信あり",
      detail: "端末に未送信の変更あり",
      tone: "pending",
    };
  if (row.local && row.local.cursor < row.head)
    return {
      label: "更新あり",
      detail: "サーバーに新しい変更あり",
      tone: "pending",
    };
  return { label: "保存済み", detail: "サーバーに保存済み", tone: "saved" };
}

export function DraftAdministration({ csrf }: { csrf: () => Promise<string> }) {
  const [articles, setArticles] = useState<Article[]>([]);
  const [local, setLocal] = useState<LocalDraftSummary[]>([]);
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [cursor, setCursor] = useState<string | null>(null);
  const [available, setAvailable] = useState(false);
  const [error, setError] = useState("");
  const [localError, setLocalError] = useState("");
  const [busy, setBusy] = useState(false);
  const request = useRef<AbortController | null>(null);

  const load = useCallback(
    async (nextCursor: string | null = null) => {
      const isReload = nextCursor === null;
      request.current?.abort();
      const controller = new AbortController();
      request.current = controller;
      if (isReload) {
        setLoading(true);
        setLoadingMore(false);
      } else setLoadingMore(true);
      setError("");
      if (isReload) setAvailable(false);
      if (isReload)
        void readLocalDraftSummaries()
          .then((value) => {
            if (!controller.signal.aborted) {
              setLocal(value);
              setLocalError("");
            }
          })
          .catch(() => {
            if (!controller.signal.aborted)
              setLocalError(
                "この端末の保存領域を読めません。サーバー上の記事のみ表示します。",
              );
          });
      try {
        const params = new URLSearchParams({ q: debouncedQuery });
        if (nextCursor) params.set("cursor", nextCursor);
        const response = await fetch(`/api/authoring/drafts?${params}`, {
          signal: controller.signal,
        });
        if (!response.ok)
          throw new Error(
            "サーバーの記事一覧を取得できません。通信やログイン状態を確認してください。",
          );
        const page: ArticlePage = await response.json();
        setArticles((current) =>
          isReload ? page.articles : [...current, ...page.articles],
        );
        setCursor(page.cursor);
        setAvailable(true);
      } catch (failure) {
        if (!controller.signal.aborted)
          setError(
            failure instanceof Error
              ? failure.message
              : "一覧を取得できません。",
          );
      } finally {
        if (!controller.signal.aborted) {
          setLoading(false);
          setLoadingMore(false);
        }
      }
    },
    [debouncedQuery],
  );
  const reload = useCallback(() => load(), [load]);
  useEffect(() => {
    const timeout = window.setTimeout(() => setDebouncedQuery(query), 250);
    return () => window.clearTimeout(timeout);
  }, [query]);
  useEffect(() => {
    void reload();
    const refresh = () => {
      void reload();
    };
    window.addEventListener("focus", refresh);
    window.addEventListener("online", refresh);
    return () => {
      request.current?.abort();
      window.removeEventListener("focus", refresh);
      window.removeEventListener("online", refresh);
    };
  }, [reload]);

  const byId = new Map(local.map((row) => [row.id, row]));
  const rows: Row[] = articles.map((row) => ({
    ...row,
    state:
      row.public_hash && byId.get(row.id)?.pending
        ? byId.get(row.id)?.contentHash === row.public_hash
          ? "public"
          : "unpublished_changes"
        : row.state,
    local: byId.get(row.id),
  }));
  const remoteIds = new Set(articles.map((row) => row.id));
  if (cursor === null && (!available || debouncedQuery === ""))
    for (const saved of local)
      if (!remoteIds.has(saved.id))
        rows.push({
          id: saved.id,
          metadata: saved.metadata,
          head: 0,
          updated_at: "",
          published_at: null,
          webmention_count: null,
          public_route: null,
          public_hash: null,
          state: available ? "draft" : "unknown",
          publication: null,
          local: saved,
          localOnly: true,
        });
  const matches = (row: Row, value: Filter) =>
    value === "all" ||
    (value === "attention" ? needsAttention(row) : row.state === value);
  const visible = rows
    .filter(
      (row) =>
        matches(row, filter) &&
        [
          row.metadata.title,
          row.local?.metadata.title,
          row.public_route,
          draftRoute(row.local?.metadata || row.metadata),
          `${window.location.origin}/${row.public_route || draftRoute(row.metadata)}`,
          `${window.location.origin}/${encodeURIComponent(row.public_route || draftRoute(row.metadata))}`,
        ].some((value) =>
          value?.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
        ),
    )
    .sort(
      (a, b) =>
        b.updated_at.localeCompare(a.updated_at) || a.id.localeCompare(b.id),
    );

  const create = useCallback(
    async (daily: boolean) => {
      setBusy(true);
      setError("");
      try {
        const now = new Date();
        const date = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
        const id = crypto.randomUUID();
        const response = await fetch(
          daily ? "/api/authoring/drafts/daily" : `/api/authoring/drafts/${id}`,
          {
            method: daily ? "POST" : "PUT",
            headers: {
              "content-type": "application/json",
              "x-csrf-token": await csrf(),
            },
            body: JSON.stringify(
              daily ? { date } : { protocol: 1, generation: 1 },
            ),
          },
        );
        if (!response.ok)
          throw new Error(
            "下書きを作成できません。オンライン状態で再試行してください。",
          );
        const created: { id: string; initial_body?: string } =
          await response.json();
        if (created.initial_body)
          storeDraftInitialBody(
            sessionStorage,
            created.id,
            created.initial_body,
          );
        window.location.assign(
          `/draft-editor?id=${encodeURIComponent(created.id)}`,
        );
      } catch (failure) {
        setError(
          failure instanceof Error ? failure.message : "作成できません。",
        );
        setBusy(false);
      }
    },
    [csrf],
  );
  useEffect(() => {
    const url = new URL(window.location.href);
    if (url.searchParams.get("daily") !== "1") return;
    url.searchParams.delete("daily");
    window.history.replaceState(null, "", url);
    void create(true);
  }, [create]);
  async function retry(row: Row) {
    if (!row.publication) return;
    setBusy(true);
    setError("");
    try {
      const response = await fetch(
        `/api/authoring/drafts/${row.id}/publications/${row.publication.id}/run`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-csrf-token": await csrf(),
          },
          body: "{}",
        },
      );
      if (!response.ok)
        throw new Error(
          "公開処理を再試行できませんでした。保存済みの本文は保持されています。",
        );
      await reload();
    } catch (failure) {
      setError(
        failure instanceof Error ? failure.message : "再試行できません。",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="draft-admin">
      <a className="draft-admin-skip" href="#draft-admin-ledger">
        記事一覧へ移動
      </a>
      <DraftNavigation />
      <section
        id="draft-admin-ledger"
        className="draft-admin-ledger"
        aria-label="記事一覧"
      >
        <header className="draft-admin-heading">
          <h1>記事の管理</h1>
        </header>
        <div className="draft-admin-tools">
          <label className="draft-admin-search-label">
            記事を検索
            <input
              className="draft-admin-search"
              type="search"
              aria-label="タイトルまたはURLで検索"
              placeholder="タイトルまたはURL"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </label>
          <button
            type="button"
            disabled={loading || busy}
            onClick={() => void reload()}
          >
            <AuthoringIcon name="refresh" />
            再読み込み
          </button>
        </div>
        <nav className="draft-admin-filters" aria-label="記事の状態">
          {FILTERS.map(([value, label]) => (
            <button
              key={value}
              type="button"
              aria-pressed={filter === value}
              onClick={() => setFilter(value)}
            >
              {label}
            </button>
          ))}
        </nav>
        <div className="draft-admin-count">
          <span role="status">
            {loading
              ? "記事を読み込み中…"
              : `${visible.length}件を表示${cursor ? "・続きあり" : ""}${available ? "" : "（取得済み分）"}`}
          </span>
        </div>
        {error && <p role="alert">{error}</p>}
        {localError && <p role="alert">{localError}</p>}
        {!loading && !visible.length && (
          <p>
            {query
              ? "一致する記事はありません。"
              : "この状態の記事はありません。"}
          </p>
        )}
        <table className="draft-admin-table">
          <caption className="visually-hidden">
            記事の状態と承認済みWebmention、投稿日、最終更新日
          </caption>
          <thead>
            <tr>
              <th scope="col">記事タイトル</th>
              <th scope="col">
                <span className="visually-hidden">操作</span>
              </th>
              <th scope="col">ステータス</th>
              <th scope="col">公開処理</th>
              <th scope="col">
                Webmention
                <span className="draft-admin-column-note">承認済み</span>
              </th>
              <th scope="col">投稿日</th>
              <th scope="col">最終更新日</th>
              <th scope="col">
                <span className="visually-hidden">公開記事</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {visible.map((row) => {
              const title =
                (row.local?.pending
                  ? row.local.metadata.title
                  : row.metadata.title) || "無題";
              const editHref = `/draft-editor?id=${encodeURIComponent(row.id)}${row.state === "draft" ? "" : `&state=${row.state}`}`;
              const attention = needsAttention(row);
              const saveStatus = serverStatus(row, available);
              const retryable =
                row.publication &&
                row.publication.status !== "superseded" &&
                (attention || row.publication.status === "accepted");
              return (
                <tr
                  key={row.id}
                  data-state={attention ? "attention" : row.state}
                >
                  <th scope="row" className="draft-admin-article">
                    <a className="draft-admin-title" href={editHref}>
                      {title}
                    </a>
                    <span className="draft-admin-route">
                      /
                      {row.public_route ||
                        draftRoute(
                          row.local?.pending
                            ? row.local.metadata
                            : row.metadata,
                        )}
                    </span>
                  </th>
                  <td className="draft-admin-menu-cell">
                    <DraftArticleMenu
                      title={title}
                      editHref={editHref}
                      busy={busy}
                      onRetry={retryable ? () => void retry(row) : undefined}
                    />
                  </td>
                  <td
                    className="draft-admin-status-cell"
                    data-label="ステータス"
                  >
                    <div className="draft-admin-row-status">
                      <span
                        className="draft-admin-state"
                        data-state={row.state}
                      >
                        {row.localOnly
                          ? "端末に保存した記事"
                          : STATES[row.state]}
                      </span>
                      <span
                        className="draft-admin-save-status"
                        role="img"
                        data-tone={saveStatus.tone}
                        aria-label={saveStatus.detail}
                        title={saveStatus.detail}
                      >
                        {saveStatus.tone === "saved" && (
                          <AuthoringIcon name="check" />
                        )}
                        {saveStatus.label}
                      </span>
                      {attention && (
                        <span
                          className="draft-admin-state"
                          data-state="attention"
                        >
                          要確認
                        </span>
                      )}
                    </div>
                    {row.state_error && (
                      <p className="draft-admin-row-error">{row.state_error}</p>
                    )}
                  </td>
                  <td
                    className="draft-admin-publication-cell"
                    data-label="公開処理"
                  >
                    {row.publication ? (
                      <div className="draft-admin-publication">
                        {row.publication.stages.length === 0 && (
                          <p>
                            {row.publication.status === "completed"
                              ? "詳細記録なし"
                              : row.publication.status === "superseded"
                                ? "失効済み"
                                : "公開処理中"}
                          </p>
                        )}
                        {row.publication.status === "superseded" && (
                          <p>
                            この公開処理は失効しました。エディタで内容を再確認してください。
                          </p>
                        )}
                        <ul className="draft-admin-stages">
                          {row.publication.stages.map((stage) => (
                            <li key={stage.stage} data-state={stage.status}>
                              <span>{STAGES[stage.stage] || stage.stage}</span>
                              {stage.status === "completed" && (
                                <span
                                  className="draft-admin-stage-check"
                                  role="img"
                                  aria-label="反映済み"
                                  title="反映済み"
                                >
                                  <AuthoringIcon name="check" />
                                </span>
                              )}
                              {stage.status === "completed"
                                ? null
                                : stage.status === "retry_wait"
                                  ? "再試行待ち"
                                  : stage.status === "needs_attention"
                                    ? "要確認"
                                    : stage.status === "superseded"
                                      ? "失効済み"
                                      : "処理中"}
                            </li>
                          ))}
                        </ul>
                        {row.publication.stages
                          .filter((stage) => stage.error)
                          .map((stage) => (
                            <p
                              className="draft-admin-row-error"
                              key={stage.stage}
                            >
                              {STAGES[stage.stage] || stage.stage}：
                              {stage.error}
                            </p>
                          ))}
                      </div>
                    ) : (
                      "—"
                    )}
                    {row.publication?.error && (
                      <p className="draft-admin-row-error">
                        {row.publication.error}
                      </p>
                    )}
                  </td>
                  <td
                    className="draft-admin-mentions"
                    data-label="Webmention（承認済み）"
                  >
                    {row.webmention_count ?? "—"}
                  </td>
                  <td className="draft-admin-date" data-label="投稿日">
                    <ArticleDate
                      value={row.published_at}
                      empty={row.localOnly ? "未確認" : "未公開"}
                    />
                  </td>
                  <td className="draft-admin-date" data-label="最終更新日">
                    <ArticleDate value={row.updated_at} empty="未保存" />
                  </td>
                  <td className="draft-admin-open">
                    {row.public_route && (
                      <a
                        className="draft-admin-icon"
                        href={`/${encodeURIComponent(row.public_route)}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        aria-label={`${title}の公開記事を開く（新しいタブ）`}
                        title="公開記事を開く（新しいタブ）"
                      >
                        <AuthoringIcon name="external" />
                      </a>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {cursor && (
          <button
            className="draft-admin-more"
            type="button"
            disabled={loadingMore || busy}
            onClick={() => void load(cursor)}
          >
            {loadingMore ? "読み込み中…" : "さらに読み込む"}
          </button>
        )}
      </section>
    </div>
  );
}

function ArticleDate({
  value,
  empty,
}: {
  value: string | null;
  empty: string;
}) {
  if (!value) return <span>{empty}</span>;
  const date = new Date(value);
  return (
    <time dateTime={value}>
      <span>
        {date.toLocaleDateString("ja-JP", {
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
        })}
      </span>
      <span>
        {date.toLocaleTimeString("ja-JP", {
          hour: "2-digit",
          minute: "2-digit",
        })}
      </span>
    </time>
  );
}
