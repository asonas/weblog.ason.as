import { useEffect, useState } from "react";

type Usage = {
  checked_at: string | null;
  month?: string;
  scope: string;
  used_paths: number | null;
  site_used_paths: number | null;
  remaining_paths: number | null;
};

export function PublicCacheUsage({ csrf }: { csrf: () => Promise<string> }) {
  const [usage, setUsage] = useState<Usage | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    void fetch("/api/authoring/drafts/cache-usage", {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (response.ok) setUsage((await response.json()) as Usage);
      })
      .catch(() => {});
    return () => controller.abort();
  }, []);
  async function refresh() {
    setBusy(true);
    setError("");
    try {
      const response = await fetch("/api/authoring/drafts/cache-usage", {
        method: "POST",
        cache: "no-store",
        headers: { "X-CSRF-Token": await csrf() },
      });
      if (!response.ok) throw new Error("使用数を確認できませんでした。");
      setUsage((await response.json()) as Usage);
    } catch (error) {
      setError(
        error instanceof Error
          ? error.message
          : "使用数を確認できませんでした。",
      );
    } finally {
      setBusy(false);
    }
  }
  return (
    <section
      className="draft-admin-cache-usage"
      aria-label="キャッシュ更新の使用数"
    >
      <p>
        キャッシュ更新：
        {usage?.checked_at
          ? `${usage.month}（UTC）の本サイト ${usage.site_used_paths}パス・確認できた配信設定の合計 ${usage.used_paths}パス`
          : "使用数は未確認です"}
      </p>
      <p>
        無料枠はアカウント共通で月1,000パスです。削除済みの配信設定などを含む全体の残数は未確認です。
      </p>
      {usage?.checked_at && (
        <p>最終確認：{new Date(usage.checked_at).toLocaleString("ja-JP")}</p>
      )}
      <button type="button" disabled={busy} onClick={() => void refresh()}>
        {busy ? "確認中…" : "AWSの使用数を確認"}
      </button>
      {error && <p role="alert">{error}</p>}
    </section>
  );
}
