# 記事一覧と管理

ユーザーは記事一覧で保存済みの記事を状態ごとに確かめ、行のメニューから記事を削除し、今日の日記を開く。削除は確認ダイアログを経て、端末とサーバーの両方から消える。

## Sub-features

- `admin-list` `region`「記事一覧」に記事が表示され、件数が多いと「さらに読み込む」で続きを取得する。
- `admin-filter` `navigation`「記事の状態」で表示する状態を切り替える。
- `admin-delete` 行の操作メニューから「削除」し、確認で取り消すと残り、承認すると消える。
- `admin-daily` 執筆メニューの「今日の日記を書く」で今日の日記の編集画面を開く。

## How to get to it (user POV)

- 執筆メニューの「記事」（aria名「記事一覧」）、または `/authoring/articles` を開く。
- 今日の日記は執筆メニューの「日記を書く」（aria名「今日の日記を書く」、`/authoring/articles?daily=1`）。

## Driving it with drive.mjs

Preconditions:

- doctorが全項目 `OK`。DBは空なので、一覧と削除の検証では先に [記事の執筆と保存](./draft-editor.md) の手順で記事を作り、「サーバーに保存済み」を待つ。
- 既存の日記を開く検証は `launch.mjs --legacy-diary` で起動する。

- **一覧.** `page.goto(\`${webBase}/authoring/articles\`)` の後、`getByRole("region", { name: "記事一覧", exact: true }).getByRole("link", { name: <タイトル>, exact: true })` が見える。
- **削除を取り消す.** `page.on("dialog", ...)` で `dismiss()` を返すようにし、行 `page.locator("tbody tr").filter({ hasText: <タイトル> })` の `getByRole("button", { name: \`${タイトル}の操作\` })` を押し、`getByRole("menuitem", { name: "削除", exact: true })` を押す。行が残る。
- **削除する.** ダイアログを `accept()` にして同じ操作をする。行がdetachedになり、`fetch(\`/api/authoring/drafts/${id}?format=auto\`)` が404を返し、再読み込み後も行がない。
- **今日の日記.** 執筆メニューの `getByRole("link", { name: "今日の日記を書く", exact: true })` を押し、`getByLabel("タイトル", { exact: true })` が有効になる。

## Gotchas

- 確認ダイアログのメッセージには「取り消せません」が含まれる。ダイアログのハンドラを登録しないとPlaywrightが自動で閉じ、取り消し扱いになる。
- 「さらに読み込む」を出すには1ページ分を超える記事が必要。空のDBで再現できない場合は、`test/browser/draft_administration.mjs` のように一覧APIだけを `page.route` で置き換える。
- 執筆メニューの表示文字列（「記事」「日記を書く」）とaria名は異なる。roleで指定するときはaria名を使う。
