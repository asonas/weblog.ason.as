# Webmentionの管理

ユーザーは記事への言及（Webmention）を状態ごとのタブで確かめ、掲載するものを承認し、不要なものを拒否または履歴ごと削除する。

## Sub-features

- `mentions-open` 「Webmention」見出しの画面を開き、執筆メニューが同じ並びで残る。
- `mentions-tabs` `navigation`「Webmentionの状態」のタブ（要確認、承認済み、拒否、検証失敗、削除済み、送信失敗）で表示を切り替える。
- `mentions-moderate` 要確認の言及を「承認」または「拒否」する。内容が変わった言及では「表示を更新」「現在の表示を維持」になる。（未検証）
- `mentions-delete` 承認済みまたは拒否した言及を「履歴ごと完全削除」する。確認ダイアログを経る。（未検証）

## How to get to it (user POV)

- 執筆メニューの「Webmention」（aria名「Webmentionを管理」）、または `/authoring/webmentions` を開く。

## Driving it with drive.mjs

Preconditions:

- doctorが全項目 `OK`。空のDBなのでWebmentionは0件。

- **開く.** 執筆メニューの `getByRole("link", { name: "Webmentionを管理" })` を押し、`getByRole("heading", { name: "Webmention", exact: true })` を待つ。
- **タブ.** `getByRole("navigation", { name: "Webmentionの状態" }).getByRole("button", { name: /承認済み/ })` を押し、`getByRole("region", { name: "承認済み", exact: true })` が現れ、「承認済みの言及はありません。」が表示される。読み込み中の `status` が消えた後、`alert` が0件。この手順は `test/browser/draft_administration.mjs` が通している。
- **承認・拒否・削除.** 言及カードのボタン名は「承認」「拒否」「表示を更新」「現在の表示を維持」「履歴ごと完全削除」（`frontend/authoring/webmentions.tsx`）。承認と拒否は `PATCH /api/authoring/webmentions/<id>`、削除は `DELETE` を呼ぶ。

## Gotchas

- 受信した言及を作る経路（`lib/weblog_authoring/webmention_receiver.rb`）は、送信元ページの取得と公開済み記事の存在を前提にする。このfixtureには公開記事も外部ページもないため、空でない一覧に到達する手順はまだない。`mentions-moderate` と `mentions-delete` は未検証と報告し、タブの切り替えで代えて検証済みとしない。
- 一覧を作るために `GET /api/webmentions` の応答を `page.route` で差し替えると、承認・拒否のリクエストは実在しないIDに向かう。画面の振る舞いだけの確認になることを報告に書く。
