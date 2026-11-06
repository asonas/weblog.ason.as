# 端末のペアリング

ユーザーは端末画面でペアリング用のQRコードを発行し、写真inboxアプリでそれを読み取ると端末が一覧に加わる。コードは一度しか使えず、有効期限が切れるとQRコードが消える。

## Sub-features

- `devices-empty` 端末がないとき「まだペアリング済みの端末はありません。」を表示する。
- `devices-issue` 「新たにペアリング」でQRコード（`img`「ペアリング用QRコード」）を表示する。
- `devices-pair` コードの交換が成功すると端末名の見出しが現れ、QRコードが消え、状態表示に「ペアリングしました」が出る。
- `devices-expire` 有効期限が切れるとQRコードが消え、状態表示に「有効期限が切れました」が出る。

## How to get to it (user POV)

- 執筆メニューの「端末」（aria名「端末を管理」）、または `/authoring/devices` を開く。
- 交換はモバイルアプリが行う。ブラウザだけの検証では、アプリの代わりに交換APIを呼ぶ。

## Driving it with drive.mjs

Preconditions:

- doctorが全項目 `OK`。空のDBでは端末は0台。

- **開く.** `/authoring/articles` から `getByRole("link", { name: "端末を管理" })` を押し、`getByRole("heading", { name: "端末", exact: true })` を待つ。`getByText("まだペアリング済みの端末はありません。", { exact: true })` が見える。
- **発行.** `getByRole("button", { name: "新たにペアリング", exact: true })` を押し、`getByRole("img", { name: "ペアリング用QRコード" })` を待つ。画面上のコードは `.mobile-pairing-code` に出る。
- **交換（アプリの代役）.** `page.request.post(\`${webBase}/api/mobile/pairings/exchange\`, { data: { code, device_name: "Android test device" } })` が201。ブラウザ側で `getByRole("heading", { name: "Android test device" })` が現れ、QRコードが消える。同じコードの再交換は410。
- **QRの中身.** QRを読む検証は `jsqr` と `pngjs` で画像をデコードする。`test/browser/mobile_pairing.mjs` に手順がある。

## Gotchas

- 交換APIを呼ぶのはアプリの代役であって、ユーザー操作の証明ではない。報告では「交換はAPIで代行した」と書く。
- 有効期限は既定では長い。期限切れの検証は `page.route("**/api/mobile/pairings", ...)` で応答の `expires_at` だけを近い時刻に書き換える。
- QRの `server` は常に `https://weblog.ason.as` を指す。fixtureのURLにならないのは正しい。
