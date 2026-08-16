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

生成される主なものは次のとおりです。

- `data/normalized/posts/*.md`: 1 Scrapboxページにつき1記事のMarkdown
- `data/normalized/migration-map.json`: 元タイトルと固定記事IDの対応
- `data/normalized/index/log.sqlite3`: リンク探索用の派生インデックス
- `data/normalized/site/`: ウェブログ・記事ページ・カードモードの静的プレビュー
- `data/reports/migration-report.json` / `migration-report.md`: 移行確認レポート

静的サイトは、例えば次のコマンドでローカル確認できます。

```sh
mise exec -- .venv/bin/python -m http.server 8000 --directory data/normalized/site
```

## テスト

```sh
mise exec -- .venv/bin/python -m pytest -q
```

現フェーズでは、AWS配信、投稿アプリ、編集履歴、音声・動画の変換、OGP取得は扱いません。まずNAS上で移行結果と記事・アセット間の関係を確認するための土台です。
