import QRCode from "qrcode";
import { useEffect, useRef, useState } from "react";
import { DraftNavigation } from "./DraftNavigation";
import "./authoringTheme.css";
import "./draftAdministration.css";
import "./mobileDevices.css";

type Device = {
  id: string;
  name: string;
  created_at: string;
  last_used_at: string | null;
};

type Pairing = {
  code: string;
  expires_at: string;
  image: string;
  deviceIds: string[];
};

async function responseJson<T>(response: Response): Promise<T> {
  if (!response.ok) {
    throw new Error(
      response.status === 401 || response.status === 403
        ? "ログインし直してからお試しください。"
        : "通信に失敗しました。もう一度お試しください。",
    );
  }
  return response.json();
}

function dateLabel(value: string | null): string {
  return value
    ? new Date(value).toLocaleString("ja-JP")
    : "まだ利用されていません";
}

export function MobileDevices({ csrf }: { csrf: () => Promise<string> }) {
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [pairing, setPairing] = useState<Pairing | null>(null);
  const [loading, setLoading] = useState(true);
  const [issuing, setIssuing] = useState(false);
  const [revision, setRevision] = useState(0);
  const [error, setError] = useState("");
  const [listError, setListError] = useState("");
  const [notice, setNotice] = useState("");
  const issueButton = useRef<HTMLButtonElement>(null);
  const request = useRef<AbortController | null>(null);

  useEffect(() => () => request.current?.abort(), []);

  useEffect(() => {
    void revision;
    const controller = new AbortController();
    setLoading(true);
    void fetch("/api/mobile/devices", {
      signal: controller.signal,
      cache: "no-store",
      headers: { Accept: "application/json" },
    })
      .then(responseJson<{ devices: Device[] }>)
      .then((result) => {
        if (controller.signal.aborted) return;
        setDevices(result.devices);
        setListError("");
        if (pairing) {
          const connected = result.devices.find(
            (device) => !pairing.deviceIds.includes(device.id),
          );
          if (connected) {
            setPairing(null);
            setNotice(`${connected.name} をペアリングしました。`);
            issueButton.current?.focus();
          }
        }
      })
      .catch(() => {
        if (!controller.signal.aborted)
          setListError(
            "端末一覧を取得できませんでした。再読み込みしてください。",
          );
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });
    return () => controller.abort();
  }, [revision, pairing]);

  useEffect(() => {
    if (!pairing) return;
    const expire = () => {
      setPairing(null);
      setNotice("有効期限が切れました。新たにペアリングしてください。");
      issueButton.current?.focus();
    };
    const expiry = window.setTimeout(
      expire,
      Math.max(0, Date.parse(pairing.expires_at) - Date.now()),
    );
    const poll = window.setInterval(
      () => setRevision((value) => value + 1),
      3000,
    );
    return () => {
      window.clearTimeout(expiry);
      window.clearInterval(poll);
    };
  }, [pairing]);

  async function issuePairing() {
    if (request.current) return;
    const controller = new AbortController();
    request.current = controller;
    setIssuing(true);
    setPairing(null);
    setError("");
    setNotice("");
    try {
      const current = await responseJson<{ devices: Device[] }>(
        await fetch("/api/mobile/devices", {
          signal: controller.signal,
          cache: "no-store",
        }),
      );
      const result = await responseJson<{ code: string; expires_at: string }>(
        await fetch("/api/mobile/pairings", {
          method: "POST",
          signal: controller.signal,
          headers: {
            "X-CSRF-Token": await csrf(),
            "Content-Type": "application/json",
          },
          body: "{}",
        }),
      );
      const payload = JSON.stringify({
        type: "weblog-photo-inbox-pairing",
        version: 1,
        server: "https://weblog.ason.as",
        code: result.code,
        expires_at: result.expires_at,
      });
      const image = await QRCode.toDataURL(payload, {
        width: 320,
        margin: 4,
        errorCorrectionLevel: "M",
      });
      if (controller.signal.aborted) return;
      setPairing({
        ...result,
        image,
        deviceIds: current.devices.map((device) => device.id),
      });
      setNotice("QRコードを発行しました。アプリの設定から読み取ってください。");
    } catch (reason) {
      if (!controller.signal.aborted)
        setError(
          reason instanceof Error
            ? reason.message
            : "ペアリングコードを発行できませんでした。",
        );
    } finally {
      if (!controller.signal.aborted) setIssuing(false);
      request.current = null;
    }
  }

  return (
    <div className="draft-admin mobile-devices">
      <DraftNavigation />
      <main className="draft-admin-ledger">
        <header className="draft-admin-heading">
          <h1>端末</h1>
          <p>Photo Inboxと接続して、写真やメモをインボックスへ送れます。</p>
        </header>
        <div className="mobile-devices-tools">
          <button
            type="button"
            className="mobile-devices-primary"
            ref={issueButton}
            disabled={issuing}
            onClick={() => void issuePairing()}
          >
            {issuing ? "発行中…" : "新たにペアリング"}
          </button>
          <button
            type="button"
            disabled={loading}
            onClick={() => setRevision((value) => value + 1)}
          >
            再読み込み
          </button>
        </div>
        <p role="status">
          {notice ||
            (devices === null && loading ? "端末を読み込んでいます…" : "")}
        </p>
        {error && <p role="alert">{error}</p>}
        {listError && <p role="alert">{listError}</p>}
        {pairing && (
          <section
            className="mobile-pairing"
            aria-labelledby="mobile-pairing-title"
          >
            <img
              src={pairing.image}
              width="320"
              height="320"
              alt="ペアリング用QRコード"
            />
            <div>
              <h2 id="mobile-pairing-title">アプリでQRコードを読み取る</h2>
              <ol>
                <li>AndroidのPhoto Inboxで「設定」を開きます。</li>
                <li>
                  「QRコードを読み取る」を押し、このQRコードにカメラを向けます。
                </li>
                <li>接続が完了すると、下の端末一覧に表示されます。</li>
              </ol>
              <p>
                有効期限：
                <time dateTime={pairing.expires_at}>
                  {dateLabel(pairing.expires_at)}
                </time>
              </p>
              <p>カメラが使えない場合は、このコードを手入力できます。</p>
              <code className="mobile-pairing-code">{pairing.code}</code>
              <p className="mobile-pairing-note">
                1回限り有効です。新しく発行すると、前のコードは使えなくなります。
              </p>
            </div>
          </section>
        )}
        <section
          aria-labelledby="mobile-devices-title"
          className="mobile-devices-list"
        >
          <h2 id="mobile-devices-title">ペアリング済みの端末</h2>
          {devices?.length === 0 && (
            <p>まだペアリング済みの端末はありません。</p>
          )}
          <ul>
            {devices?.map((device) => (
              <li key={device.id}>
                <h3>{device.name}</h3>
                <dl>
                  <div>
                    <dt>接続日</dt>
                    <dd>{dateLabel(device.created_at)}</dd>
                  </div>
                  <div>
                    <dt>最終利用</dt>
                    <dd>{dateLabel(device.last_used_at)}</dd>
                  </div>
                </dl>
              </li>
            ))}
          </ul>
        </section>
      </main>
    </div>
  );
}
