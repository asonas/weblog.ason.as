# 記事の執筆と保存

ユーザーは執筆メニューから新しい記事を開き、タイトルと本文を書く。入力は端末（IndexedDB）とサーバーに保存され、再読み込みしても、端末内データを持たない別のブラウザでも同じ内容が表示される。

## Sub-features

- `editor-open` 執筆メニューから空の編集画面を開き、URLに `?id=<記事ID>` が付く。
- `editor-save` タイトルと本文がサーバーに保存され、状態表示が「サーバーに保存済み」になる。
- `editor-reload` 再読み込み後も入力が残る。
- `editor-restore` 別のブラウザコンテキストでサーバーから復元される。
- `editor-pieces` かけら形式（`--pieces`）では本文欄が「1番目のかけら」になる。

## How to get to it (user POV)

- 執筆メニューの「記事を書く」（aria名「新しい記事を書く」）。
- `/draft-editor` を直接開く。
- 記事一覧の記事タイトルのリンクから既存の記事を開く。
- 存在しないパス（例 `/hoge-piyo`）を開くと、そのパスをタイトルにした編集画面になる。

## Driving it with drive.mjs

Preconditions:

- `launch.mjs`（legacy形式）で起動し、doctorが全項目 `OK`。

- **証明済みジャーニー.** `node .agents/skills/verify-weblog-authoring/scripts/drive.mjs .agents/skills/verify-weblog-authoring/journeys/draft-save-reload.mjs` が `editor-open`、`editor-save`、`editor-reload`、`editor-restore` と一覧への表示を一度に確かめ、`PASS` を出す。
- **編集画面を開く.** `page.getByRole("navigation", { name: "執筆メニュー" }).getByRole("link", { name: "新しい記事を書く" }).click()`。`getByLabel("タイトル", { exact: true })` が有効になるまで待つ。
- **書く.** `getByLabel("タイトル", { exact: true }).fill(...)` と `getByRole("textbox", { name: "本文", exact: true }).fill(...)`。本文はtextareaなので値は `inputValue()` で読む。
- **保存を待つ.** `getByRole("status")` のいずれかに「サーバーに保存済み」が出るまで待つ。タイトルのメタデータは本文より先にサーバーへ届くので、APIのタイトルだけを見て保存完了としない。
- **サーバーから読み直す.** `page.request.get(\`${webBase}/api/authoring/drafts/${id}?protocol=1&generation=1&cursor=0\`)` の `metadata.title.value` が入力値になる。
- **別端末で復元.** `context.browser().newContext()` の新しいページで同じURLを開き、本文とタイトルが一致する。
- **かけら形式.** `launch.mjs --pieces` で起動し、本文欄を `getByRole("textbox", { name: "1番目のかけら", exact: true })` で操作する。

## Gotchas

- 「サーバーに保存済み」の前に再読み込みすると、本文がまだサーバーにない状態を見て失敗する。
- 記事一覧ではタイトルがリンクとパス表示（`/<タイトル>`）の2か所に出る。`getByText` は複数一致するので `getByRole("link", { name: title, exact: true })` を使う。
- 「公開する」はfixtureのS3がstubで公開ページを生成しないため、この地図では検証できない。
- 本文のバイト数上限を超えると本文欄が `aria-invalid` になる。長文の検証では保存されないことが正しい振る舞いの場合がある。
