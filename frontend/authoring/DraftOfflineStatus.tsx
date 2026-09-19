import { useEffect, useState } from "react";

export function DraftOfflineStatus() {
  const [message, setMessage] = useState("オフライン再開の準備中");
  useEffect(() => {
    let isActive = true;
    if (import.meta.env.DEV) {
      setMessage("オフライン再開はビルド済みの編集画面で利用できます");
      return;
    }
    const prepare = async () => {
      await navigator.serviceWorker.register("/draft-offline.js", {
        scope: "/draft-editor",
        updateViaCache: "none",
      });
      await navigator.serviceWorker.ready;
      if (isActive) setMessage("オフラインでも再開できます");
    };
    void prepare().catch(() => {
      if (isActive)
        setMessage(
          "オフライン再開の準備ができませんでした。接続中に画面を開き直してください。",
        );
    });
    return () => {
      isActive = false;
    };
  }, []);
  return <p aria-live="polite">{message}</p>;
}
