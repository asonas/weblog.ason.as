# 記事本文の校正

管理 API の `POST /api/authoring/proofread` はログイン・編集権限・CSRF を検証し、本文を専用の Node.js Lambda に渡す。校正処理は本文を保存せず、指摘と元の Markdown 上の位置を返す。入力上限は UTF-8 で 1,000,000 バイト。

`preset-ja-technical-writing` から `sentence-length`、`max-comma`、`max-ten`、`no-mix-dearu-desumasu`、`no-exclamation-question-mark` を除く。依存パッケージと形態素解析辞書は Lambda イメージに同梱する。

エディタは最後の入力から1秒後に校正する。新しい入力で古い応答を無効化し、オフライン中は校正を停止する。ネットワークの復帰時に再試行する。校正失敗は本文の編集・保存を止めない。

## ローカル

`mise run setup` はこのディレクトリの依存もインストールする。開発用 Ruby API は `local.mjs` を Node.js の子プロセスで呼ぶ。別の HTTP サーバーは不要。

```sh
mise exec -- npm ci --prefix lambda/proofreading
mise exec -- npm test --prefix lambda/proofreading
mise exec -- ruby -Itest test/authoring/test_proofreading.rb
```

## 初回の本番導入

Terraform の操作はローカルで実行し、各 apply の直前に保存した plan を確認する。

1. `infra/bootstrap` のデプロイ権限と、`infra/production` の校正用 ECR リポジトリを作成する。
2. `Dockerfile.proofreading` を Linux ARM64 向けにビルドし、その ECR リポジトリに `bootstrap` タグで配置する。
3. `infra/production` の残りの変更を適用する。専用 Lambda、管理 Lambda からの呼び出し権限、環境変数、API ルートが追加される。
4. アプリケーションをデプロイし、ログインした記事エディタで指摘を確認する。

以後は既存のイメージビルド・デプロイ・ロールバック workflow が `proofreading` を扱う。校正 Lambda の実行ロールはログ出力のみで、記事データベースやオブジェクトストレージへのアクセス権限を持たない。
