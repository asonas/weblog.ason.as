import { useCallback, useEffect, useMemo, useState } from "react";

type WebmentionSnapshot = {
  source_url: string;
  title: string | null;
  site_name: string | null;
  content_hash: string;
};

type Webmention = {
  id: string;
  source_url: string;
  target_url: string;
  target_page_id: string;
  verification_status: string;
  moderation_status: "pending" | "approved" | "rejected";
  first_verified_at: string | null;
  last_notified_at: string;
  last_verified_at: string | null;
  candidate: WebmentionSnapshot | null;
  approved: WebmentionSnapshot | null;
};

type WebmentionFailure = {
  id: string;
  source_url: string;
  target_url: string;
  target_page_id: string | null;
  result: string;
  http_status: number | null;
  attempted_at: string;
};

type WebmentionDeliveryFailure = {
  id: string;
  page_id: string;
  source_url: string;
  target_url: string;
  status: string;
  attempt_count: number;
  http_status: number | null;
  error: string | null;
  updated_at: string;
};

type WebmentionFilter =
  | "active"
  | "approved"
  | "rejected"
  | "invalid"
  | "removed"
  | "delivery";

type WebmentionResponse = {
  mentions: Webmention[];
  failures: WebmentionFailure[];
  delivery_failures: WebmentionDeliveryFailure[];
};

const FILTER_LABELS: Record<WebmentionFilter, string> = {
  active: "要確認",
  approved: "承認済み",
  rejected: "拒否",
  invalid: "検証失敗",
  removed: "削除済み",
  delivery: "送信失敗",
};

function stateOf(mention: Webmention): WebmentionFilter | "changed" {
  if (mention.verification_status === "deleted") return "removed";
  if (mention.verification_status !== "verified") return "invalid";
  if (mention.approved && mention.candidate) return "changed";
  return mention.moderation_status === "pending"
    ? "active"
    : mention.moderation_status;
}

function stateLabel(mention: Webmention): string {
  const state = stateOf(mention);
  return state === "changed" ? "更新あり" : FILTER_LABELS[state];
}

function matchesFilter(mention: Webmention, filter: WebmentionFilter): boolean {
  if (filter === "delivery") return false;

  const state = stateOf(mention);
  return filter === "active"
    ? state === "active" || state === "changed"
    : state === filter;
}

async function responseJson<T>(response: Response): Promise<T> {
  const payload = (await response.json()) as T & { error?: string };
  if (!response.ok)
    throw new Error(payload.error || "Webmentionを読み込めませんでした");
  return payload;
}

async function loadWebmentions(): Promise<WebmentionResponse> {
  const response = await fetch("/api/webmentions", {
    headers: { Accept: "application/json" },
  });
  return responseJson<WebmentionResponse>(response);
}

async function updateDecision(
  id: string,
  decision: Webmention["moderation_status"],
): Promise<Webmention> {
  const response = await fetch(
    `/api/authoring/webmentions/${encodeURIComponent(id)}`,
    {
      method: "PATCH",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
      body: JSON.stringify({ decision }),
    },
  );
  return (await responseJson<{ mention: Webmention }>(response)).mention;
}

async function reverify(id: string): Promise<void> {
  const response = await fetch(
    `/api/authoring/webmentions/${encodeURIComponent(id)}/reverify`,
    {
      method: "POST",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
    },
  );
  await responseJson<{ status: string }>(response);
}

async function deleteWebmention(id: string): Promise<void> {
  const response = await fetch(
    `/api/authoring/webmentions/${encodeURIComponent(id)}`,
    {
      method: "DELETE",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
    },
  );
  await responseJson<{ deleted: boolean }>(response);
}

async function retryDelivery(id: string): Promise<void> {
  const response = await fetch(
    `/api/authoring/webmention-deliveries/${encodeURIComponent(id)}/retry`,
    {
      method: "POST",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
    },
  );
  await responseJson<{ status: string }>(response);
}

async function retryDeadLetters(
  kind: "verification" | "publishing",
): Promise<void> {
  const response = await fetch(
    `/api/authoring/webmention-dead-letters/${kind}/retry`,
    {
      method: "POST",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
    },
  );
  await responseJson<{ status: string; task_handle: string }>(response);
}

function displayTitle(mention: Webmention): string {
  return (
    mention.candidate?.title || mention.approved?.title || mention.source_url
  );
}

function displaySite(mention: Webmention): string {
  return (
    mention.candidate?.site_name ||
    mention.approved?.site_name ||
    new URL(mention.source_url).hostname
  );
}

function targetLabel(target: string): string {
  const url = new URL(target);
  const segment = url.pathname.split("/").filter(Boolean).at(-1);
  return segment ? decodeURIComponent(segment) : target;
}

function MentionActions({
  mention,
  busy,
  onDecision,
  onReverify,
}: {
  mention: Webmention;
  busy: boolean;
  onDecision: (decision: Webmention["moderation_status"]) => void;
  onReverify: () => void;
}) {
  const state = stateOf(mention);
  if (state === "invalid" || state === "removed") {
    return (
      <button type="button" disabled={busy} onClick={onReverify}>
        再検証
      </button>
    );
  }

  return (
    <span className="webmention-card__actions">
      {(state === "active" || state === "changed") && (
        <button
          type="button"
          className="is-primary"
          disabled={busy}
          onClick={() => onDecision("approved")}
        >
          承認
        </button>
      )}
      {(state === "active" || state === "changed") && (
        <button
          type="button"
          disabled={busy}
          onClick={() => onDecision("rejected")}
        >
          拒否
        </button>
      )}
      {(state === "approved" || state === "rejected") && (
        <button
          type="button"
          disabled={busy}
          onClick={() => onDecision("pending")}
        >
          判断を取り消す
        </button>
      )}
    </span>
  );
}

function MentionCard({
  mention,
  busy,
  onDecision,
  onReverify,
  onDelete,
}: {
  mention: Webmention;
  busy: boolean;
  onDecision: (decision: Webmention["moderation_status"]) => void;
  onReverify: () => void;
  onDelete: () => void;
}) {
  return (
    <article className="webmention-card" data-state={stateOf(mention)}>
      <header>
        <span className="webmention-card__badge">{stateLabel(mention)}</span>
        <a href={mention.target_url}>{targetLabel(mention.target_url)}</a>
      </header>
      <h3>{displayTitle(mention)}</h3>
      <p>
        <strong>{displaySite(mention)}</strong>
        <br />
        <a href={mention.source_url} target="_blank" rel="noreferrer">
          {mention.source_url}
        </a>
      </p>
      {mention.approved && mention.candidate && (
        <p className="webmention-card__detail">
          公開中: {mention.approved.title || mention.approved.source_url}
        </p>
      )}
      <MentionActions
        mention={mention}
        busy={busy}
        onDecision={onDecision}
        onReverify={onReverify}
      />
      <details className="webmention-card__danger">
        <summary>詳細操作</summary>
        <p>
          この言及関係と検証履歴を完全に削除します。再通知時は新規の言及として扱われます。
        </p>
        <button type="button" disabled={busy} onClick={onDelete}>
          履歴ごと完全削除
        </button>
      </details>
    </article>
  );
}

function FailureCard({
  failure,
  busy,
  onReverify,
}: {
  failure: WebmentionFailure;
  busy: boolean;
  onReverify: () => void;
}) {
  return (
    <article className="webmention-card" data-state="invalid">
      <header>
        <span className="webmention-card__badge">検証失敗</span>
        <a href={failure.target_url}>{targetLabel(failure.target_url)}</a>
      </header>
      <h3>{failure.result.replaceAll("_", " ")}</h3>
      <p>
        <a href={failure.source_url} target="_blank" rel="noreferrer">
          {failure.source_url}
        </a>
      </p>
      <p className="webmention-card__detail">
        {failure.http_status ? `HTTP ${failure.http_status} · ` : ""}
        {new Date(failure.attempted_at).toLocaleString("ja-JP")}
      </p>
      {failure.target_page_id && (
        <button type="button" disabled={busy} onClick={onReverify}>
          再検証
        </button>
      )}
    </article>
  );
}

function DeliveryFailureCard({
  failure,
  busy,
  onRetry,
}: {
  failure: WebmentionDeliveryFailure;
  busy: boolean;
  onRetry: () => void;
}) {
  return (
    <article className="webmention-card" data-state="invalid">
      <header>
        <span className="webmention-card__badge">送信失敗</span>
        <span>{failure.attempt_count}回試行</span>
      </header>
      <h3>{new URL(failure.target_url).hostname}</h3>
      <p>
        <a href={failure.target_url} target="_blank" rel="noreferrer">
          {failure.target_url}
        </a>
      </p>
      <p className="webmention-card__detail">
        {failure.http_status ? `HTTP ${failure.http_status} · ` : ""}
        {failure.error || failure.status}
        <br />
        {new Date(failure.updated_at).toLocaleString("ja-JP")}
      </p>
      <button type="button" disabled={busy} onClick={onRetry}>
        送信を再試行
      </button>
    </article>
  );
}

function PublicPreview({ mentions }: { mentions: Webmention[] }) {
  const target = mentions.at(0)?.target_url;
  const approved = target
    ? mentions.filter(
        (mention) =>
          mention.target_url === target &&
          mention.verification_status === "verified" &&
          mention.moderation_status === "approved" &&
          mention.approved,
      )
    : [];

  return (
    <article className="webmention-preview">
      <small>公開記事プレビュー</small>
      <h2>{target ? targetLabel(target) : "記事を選択してください"}</h2>
      {approved.length > 0 ? (
        <section>
          <h3>外部からの言及</h3>
          <ul>
            {approved.map((mention) => (
              <li key={mention.id}>
                <a href={mention.source_url} target="_blank" rel="noreferrer">
                  {mention.approved?.title || mention.source_url}
                </a>
                <small>{mention.approved?.site_name}</small>
              </li>
            ))}
          </ul>
        </section>
      ) : (
        <p>承認済みの言及はありません。</p>
      )}
    </article>
  );
}

export function WebmentionModerationPage({ canEdit }: { canEdit: boolean }) {
  const [mentions, setMentions] = useState<Webmention[]>([]);
  const [failures, setFailures] = useState<WebmentionFailure[]>([]);
  const [deliveryFailures, setDeliveryFailures] = useState<
    WebmentionDeliveryFailure[]
  >([]);
  const [filter, setFilter] = useState<WebmentionFilter>("active");
  const [loading, setLoading] = useState(canEdit);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [deadLetterBusy, setDeadLetterBusy] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const response = await loadWebmentions();
      setMentions(response.mentions);
      setFailures(response.failures);
      setDeliveryFailures(response.delivery_failures);
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Webmentionを読み込めませんでした",
      );
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    document.documentElement.dataset.view = "webmention-moderation";
    document.title = "言及 · weblog.ason.as";
    return () => {
      delete document.documentElement.dataset.view;
    };
  }, []);

  useEffect(() => {
    if (canEdit) void refresh();
  }, [canEdit, refresh]);

  const visible = useMemo(
    () => mentions.filter((mention) => matchesFilter(mention, filter)),
    [filter, mentions],
  );

  const decide = async (
    mention: Webmention,
    decision: Webmention["moderation_status"],
  ) => {
    setBusyId(mention.id);
    setError("");
    try {
      const updated = await updateDecision(mention.id, decision);
      setMentions((current) =>
        current.map((item) => (item.id === mention.id ? updated : item)),
      );
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "掲載判断を保存できませんでした",
      );
    } finally {
      setBusyId(null);
    }
  };

  const retry = async (mention: Webmention) => {
    setBusyId(mention.id);
    setError("");
    try {
      await reverify(mention.id);
      await refresh();
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "再検証を開始できませんでした",
      );
    } finally {
      setBusyId(null);
    }
  };

  const retryFailure = async (failure: WebmentionFailure) => {
    setBusyId(failure.id);
    setError("");
    try {
      await reverify(failure.id);
      await refresh();
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "再検証を開始できませんでした",
      );
    } finally {
      setBusyId(null);
    }
  };

  const retryFailedDelivery = async (failure: WebmentionDeliveryFailure) => {
    setBusyId(failure.id);
    setError("");
    try {
      await retryDelivery(failure.id);
      await refresh();
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Webmention送信を再試行できませんでした",
      );
    } finally {
      setBusyId(null);
    }
  };

  const remove = async (mention: Webmention) => {
    if (!window.confirm("この言及関係と履歴を完全に削除しますか？")) return;

    setBusyId(mention.id);
    setError("");
    try {
      await deleteWebmention(mention.id);
      setMentions((current) =>
        current.filter((item) => item.id !== mention.id),
      );
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "言及を完全削除できませんでした",
      );
    } finally {
      setBusyId(null);
    }
  };

  const redriveDeadLetters = async (kind: "verification" | "publishing") => {
    setDeadLetterBusy(kind);
    setError("");
    try {
      await retryDeadLetters(kind);
    } catch (reason: unknown) {
      setError(
        reason instanceof Error
          ? reason.message
          : "DLQの再投入を開始できませんでした",
      );
    } finally {
      setDeadLetterBusy(null);
    }
  };

  if (!canEdit) {
    return (
      <p className="webmention-access" role="status">
        言及の確認には編集権限が必要です。
      </p>
    );
  }

  return (
    <div className="webmention-workbench">
      <aside className="webmention-filters">
        <h1>言及</h1>
        <p>掲載判断が必要なものを上から処理します。</p>
        {(Object.keys(FILTER_LABELS) as WebmentionFilter[]).map((state) => (
          <button
            type="button"
            aria-pressed={filter === state}
            onClick={() => setFilter(state)}
            key={state}
          >
            {FILTER_LABELS[state]}
            <span>
              {mentions.filter((mention) => matchesFilter(mention, state))
                .length +
                (state === "invalid" ? failures.length : 0) +
                (state === "delivery" ? deliveryFailures.length : 0)}
            </span>
          </button>
        ))}
        <details className="webmention-dead-letters">
          <summary>DLQ操作</summary>
          <p>自動再試行を使い切った項目を元のキューへ戻します。</p>
          <button
            type="button"
            disabled={deadLetterBusy !== null}
            onClick={() => void redriveDeadLetters("verification")}
          >
            {deadLetterBusy === "verification"
              ? "再投入中"
              : "受信・送信DLQを再投入"}
          </button>
          <button
            type="button"
            disabled={deadLetterBusy !== null}
            onClick={() => void redriveDeadLetters("publishing")}
          >
            {deadLetterBusy === "publishing" ? "再投入中" : "公開DLQを再投入"}
          </button>
        </details>
      </aside>
      <main className="webmention-queue">
        <header>
          <small>判定キュー</small>
          <h2>{FILTER_LABELS[filter]}</h2>
          <button
            type="button"
            disabled={loading}
            onClick={() => void refresh()}
          >
            更新
          </button>
        </header>
        {error && (
          <p className="input-error" role="alert">
            {error}
          </p>
        )}
        {loading ? (
          <p role="status">言及を読み込んでいます</p>
        ) : visible.length === 0 &&
          !(filter === "invalid" && failures.length > 0) &&
          !(filter === "delivery" && deliveryFailures.length > 0) ? (
          <p>該当する言及はありません。</p>
        ) : (
          <div className="webmention-queue__list">
            {visible.map((mention) => (
              <MentionCard
                key={mention.id}
                mention={mention}
                busy={busyId === mention.id}
                onDecision={(decision) => void decide(mention, decision)}
                onReverify={() => void retry(mention)}
                onDelete={() => void remove(mention)}
              />
            ))}
            {filter === "invalid" &&
              failures.map((failure) => (
                <FailureCard
                  key={failure.id}
                  failure={failure}
                  busy={busyId === failure.id}
                  onReverify={() => void retryFailure(failure)}
                />
              ))}
            {filter === "delivery" &&
              deliveryFailures.map((failure) => (
                <DeliveryFailureCard
                  key={failure.id}
                  failure={failure}
                  busy={busyId === failure.id}
                  onRetry={() => void retryFailedDelivery(failure)}
                />
              ))}
          </div>
        )}
      </main>
      <PublicPreview mentions={visible.length > 0 ? visible : mentions} />
    </div>
  );
}
