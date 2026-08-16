# log.ason.as migration tools

Scrapboxの保存済みエクスポートを、NAS上で確認できるMarkdown・SQLite派生インデックス・静的プレビューへ変換するフェーズ0の実装です。

正本はMarkdownとアセットです。SQLiteは記事・アセット・内部リンク・逆リンクを探索するための再生成可能なインデックスとして扱います。AWSやScrapboxへ接続する処理は含みません。

## セットアップ

リポジトリのルートで実行します。

```sh
mise exec -- python3 -m venv .venv
mise exec -- .venv/bin/python -m pip install -e .
```

## 変換

保存済みエクスポートを `data/raw/` に置き、次のコマンドを実行します。

```sh
mise exec -- .venv/bin/python -m log_migration \
  --input data/raw/scrapbox.json \
  --output data/normalized \
--report data/reports
```

`data/raw/`、`data/normalized/`、`data/reports/` はリポジトリ内のローカル作業データとして保持し、Gitにはコミットしません。`/tmp` ではなく、これらのディレクトリを使うことで、移行結果と取得済みアセットを同じ作業環境に残せます。

生成される主なものは次のとおりです。

- `data/normalized/posts/*.md`: 1 Scrapboxページにつき1記事のMarkdown
- `data/normalized/migration-map.json`: 元タイトルと固定記事IDの対応
- `data/normalized/asset-manifest.json`: 本文中の外部URLと参照元記事の対応
- `data/normalized/index/log.sqlite3`: リンク探索用の派生インデックス
- `data/normalized/site/`: ウェブログ・記事ページ・カードモードの静的プレビュー
- `data/reports/migration-report.json` / `migration-report.md`: 移行確認レポート

静的サイトは、例えば次のコマンドでローカル確認できます。

```sh
mise exec -- .venv/bin/python -m http.server 8000 --directory data/normalized/site
```

## アセット取得

通常の変換ではネットワークへ接続せず、URLのmanifestだけを生成します。画像・音声・動画などをNASへ取得する場合だけ、次の明示的なコマンドを実行します。

```sh
mise exec -- .venv/bin/python -m log_migration.assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

取得できないURLがあっても、元のMarkdownとmanifestは変更されません。取得結果はレポートで確認できます。

アセットは `data/normalized/assets/` に保存されます。取得済みファイルはGit管理外ですが、リポジトリの作業ディレクトリに残ります。Scrapboxエクスポートを再生成してから取得する場合は、次の2段階で実行します。

```sh
mise exec -- .venv/bin/python -m log_migration \
  --input data/raw/scrapbox.json \
  --output data/normalized \
  --report data/reports

mise exec -- .venv/bin/python -m log_migration.assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

## テスト

```sh
mise exec -- .venv/bin/python -m pytest -q
```

現フェーズでは、AWS配信、投稿アプリ、編集履歴、OGP取得は扱いません。音声・動画は明示的なアセット取得の対象になりますが、再生用の変換は行いません。まずNAS上で移行結果と記事・アセット間の関係を確認するための土台です。
