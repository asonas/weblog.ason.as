import { useCallback, useEffect, useRef, useState } from "react";
import {
  type DraftMetadata,
  draftRoute,
  type LocalDraftSummary,
  readLocalDraftSummaries,
} from "./draftSession";
import "./draftAdministration.css";

type Article = {
  id: string;
  head: number;
  metadata: DraftMetadata;
  updated_at: string;
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
  html: "公開ページ",
  atom: "フィード",
  search: "検索",
};
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
    return available ? "サーバー未保存" : "サーバー保存を未確認";
  if (row.local?.pending) return "端末に未送信の変更あり";
  if (row.local && row.local.cursor < row.head)
    return "サーバーに新しい変更あり";
  return "サーバーに保存済み";
}

export function DraftAdministration({ csrf }: { csrf: () => Promise<string> }) {
  const [articles, setArticles] = useState<Article[]>([]);
  const [local, setLocal] = useState<LocalDraftSummary[]>([]);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [selectedId, setSelectedId] = useState("");
  const [loading, setLoading] = useState(true);
  const [available, setAvailable] = useState(false);
  const [error, setError] = useState("");
  const [localError, setLocalError] = useState("");
  const [busy, setBusy] = useState(false);
  const request = useRef<AbortController | null>(null);

  const reload = useCallback(async () => {
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setLoading(true);
    setError("");
    setAvailable(false);
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
      let cursor = "";
      const all: Article[] = [];
      do {
        const response = await fetch(
          `/api/authoring/drafts?cursor=${encodeURIComponent(cursor)}`,
          { signal: controller.signal },
        );
        if (!response.ok)
          throw new Error(
            "サーバーの記事一覧を取得できません。通信やログイン状態を確認してください。",
          );
        const page: { articles: Article[]; cursor: string | null } =
          await response.json();
        all.push(...page.articles);
        cursor = page.cursor || "";
        setArticles([...all]);
      } while (cursor);
      setAvailable(true);
    } catch (failure) {
      if (!controller.signal.aborted)
        setError(
          failure instanceof Error ? failure.message : "一覧を取得できません。",
        );
    } finally {
      if (!controller.signal.aborted) setLoading(false);
    }
  }, []);
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
  for (const saved of local)
    if (!remoteIds.has(saved.id))
      rows.push({
        id: saved.id,
        metadata: saved.metadata,
        head: 0,
        updated_at: "",
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
  const selected = visible.find((row) => row.id === selectedId) || visible[0];

  async function create(daily: boolean) {
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
      const created: { id: string } = await response.json();
      window.location.assign(
        `/draft-editor?id=${encodeURIComponent(created.id)}`,
      );
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : "作成できません。");
      setBusy(false);
    }
  }
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
      <aside className="draft-admin-rail" aria-label="記事の操作">
        <a className="draft-admin-brand" href="/">
          weblog.ason.as
        </a>
        <button
          className="draft-admin-primary"
          type="button"
          disabled={busy}
          onClick={() => void create(true)}
        >
          今日の日記を書く
        </button>
        <nav aria-label="記事の状態">
          {FILTERS.map(([value, label]) => (
            <button
              key={value}
              type="button"
              aria-pressed={filter === value}
              onClick={() => setFilter(value)}
            >
              {label}
              <span>{rows.filter((row) => matches(row, value)).length}</span>
            </button>
          ))}
        </nav>
        <button
          type="button"
          disabled={busy}
          onClick={() => void create(false)}
        >
          日記以外の記事を書く
        </button>
      </aside>
      <section className="draft-admin-ledger" aria-label="記事一覧">
        <input
          className="draft-admin-search"
          type="search"
          aria-label="タイトルまたはURLで検索"
          placeholder="タイトルまたはURLで検索"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="draft-admin-count">
          <span role="status">
            {loading
              ? "記事を読み込み中…"
              : `${visible.length}件${available ? "" : "（取得済み分）"}`}
          </span>
          <button
            type="button"
            disabled={loading || busy}
            onClick={() => void reload()}
          >
            再読み込み
          </button>
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
        <ul className="draft-admin-rows">
          {visible.map((row) => (
            <li key={row.id}>
              <button
                type="button"
                aria-pressed={selected?.id === row.id}
                onClick={() => setSelectedId(row.id)}
              >
                <strong>
                  {row.local?.pending
                    ? row.local.metadata.title || "無題"
                    : row.metadata.title || "無題"}
                </strong>
                <span className="draft-admin-route">
                  /{row.public_route || draftRoute(row.metadata)}
                </span>
                <span>
                  {row.localOnly ? "端末に保存した記事" : STATES[row.state]}
                  {row.local?.pending ? "・端末に変更あり" : ""}
                </span>
                <small>
                  {serverStatus(row, available)}
                  {row.updated_at &&
                    ` · ${new Date(row.updated_at).toLocaleString("ja-JP")}`}
                </small>
                {needsAttention(row) && !row.localOnly && (
                  <span>公開状態の確認が必要です</span>
                )}
              </button>
            </li>
          ))}
        </ul>
      </section>
      <section className="draft-admin-detail" aria-label="選択した記事">
        {selected ? (
          <>
            <h1>
              {selected.local?.pending
                ? selected.local.metadata.title || "無題"
                : selected.metadata.title || "無題"}
            </h1>
            <p>
              {selected.localOnly
                ? "サーバー上の状態を確認してから編集できます。"
                : STATES[selected.state]}
            </p>
            <dl>
              <dt>端末保存</dt>
              <dd>
                {selected.local ? "この端末に保存済み" : "この端末には未保存"}
              </dd>
              <dt>サーバー保存</dt>
              <dd>{serverStatus(selected, available)}</dd>
              <dt>公開処理</dt>
              <dd>
                {!selected.publication
                  ? "公開処理なし"
                  : selected.publication.status === "completed"
                    ? "公開ページを反映済み"
                    : selected.publication.status === "needs_attention"
                      ? "公開ページの反映に失敗"
                      : selected.publication.status === "superseded"
                        ? "この公開処理は失効しました。エディタで内容を再確認してください。"
                        : "公開処理中"}
              </dd>
            </dl>
            {selected.publication?.stages.map((stage) => (
              <p key={stage.stage}>
                {STAGES[stage.stage] || stage.stage}：
                {stage.status === "completed"
                  ? "反映済み"
                  : stage.status === "retry_wait"
                    ? "再試行待ち"
                    : stage.status === "needs_attention"
                      ? "要確認"
                      : stage.status === "superseded"
                        ? "失効済み"
                        : "処理中"}
                {stage.error && ` — ${stage.error}`}
              </p>
            ))}
            {(selected.state_error || selected.publication?.error) && (
              <p role="alert">
                {selected.state_error || selected.publication?.error}
              </p>
            )}
            <a
              className="draft-admin-edit"
              href={`/draft-editor?id=${encodeURIComponent(selected.id)}`}
            >
              編集・公開内容を確認
            </a>
            <p className="draft-admin-hint">
              プレビューと公開の確認はエディタで行います。
            </p>
            {selected.publication &&
              selected.publication.status !== "superseded" &&
              (needsAttention(selected) ||
                selected.publication.status === "accepted") && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void retry(selected)}
                >
                  公開処理を再試行
                </button>
              )}
            {selected.public_route && (
              <a href={`/${encodeURIComponent(selected.public_route)}`}>
                公開ページを開く
              </a>
            )}
          </>
        ) : (
          <p>記事を選択してください。</p>
        )}
      </section>
    </div>
  );
}
