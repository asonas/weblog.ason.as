import { useEffect, useState } from "react";

type Status = {
  version_id: string;
  targets: string[];
  pending: boolean;
  enabled: boolean;
};

export function DraftWebmentionStatus({
  id,
  refresh,
  csrf,
}: {
  id: string;
  refresh: number;
  csrf: () => Promise<string>;
}) {
  const [status, setStatus] = useState<Status>();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState(0);
  const [message, setMessage] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    const read = async () => {
      try {
        const response = await fetch(
          `/api/authoring/drafts/${id}/webmentions`,
          {
            signal: controller.signal,
          },
        );
        if (!response.ok)
          throw new Error("Webmentionの送信状況を取得できません。");
        const next: Status = await response.json();
        if (controller.signal.aborted) return;
        setStatus(next);
        setError("");
      } catch {
        if (!controller.signal.aborted)
          setError("Webmentionの送信状況を取得できません。");
      }
    };
    void refresh;
    void revision;
    void read();
    return () => {
      controller.abort();
    };
  }, [id, refresh, revision]);

  async function send() {
    if (!status || busy) return;
    setBusy(true);
    setError("");
    try {
      const response = await fetch(`/api/authoring/drafts/${id}/webmentions`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": await csrf(),
        },
        body: JSON.stringify({ version_id: status.version_id }),
      });
      if (!response.ok)
        throw new Error(
          "Webmentionを送信できませんでした。再試行してください。",
        );
      setStatus(await response.json());
      setMessage(
        "Webmentionの送信を受け付けました。送信失敗はWebmention管理画面で確認できます。",
      );
    } catch (failure) {
      setError(
        failure instanceof Error
          ? failure.message
          : "Webmentionを送信できません。",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div>
      {message && <p role="status">{message}</p>}
      {error ? (
        <>
          <p role="status">{error}</p>
          <button
            type="button"
            onClick={() => setRevision((value) => value + 1)}
          >
            送信状況を再確認
          </button>
        </>
      ) : (
        status &&
        (!status.enabled ? (
          <p>Webmentionの送信は停止中です。</p>
        ) : status.pending ? (
          <p>Webmentionの送信を待っています。</p>
        ) : null)
      )}
      {status?.enabled && (status.targets.length > 0 || status.pending) && (
        <button type="button" disabled={busy} onClick={() => void send()}>
          {busy ? "送信を依頼中" : "Webmentionを送る"}
        </button>
      )}
    </div>
  );
}
