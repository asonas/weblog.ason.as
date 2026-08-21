# log.ason.as migration tools

Scrapboxの保存済みエクスポートを、NAS上で確認できるMarkdown・SQLite派生インデックス・静的プレビューへ変換するフェーズ0の実装です。

正本はMarkdownとアセットです。SQLiteは記事・アセット・内部リンク・逆リンクを探索するための再生成可能なインデックスとして扱います。AWSやScrapboxへ接続する処理は含みません。

## セットアップ

リポジトリのルートで実行します。

```sh
mise exec -- python3 -m venv .venv
mise exec -- .venv/bin/python -m pip install -e .
```

## ローカル執筆画面

執筆画面はlocalhostだけに bind します。LAN、認証、AWS、クラウド、外部APIへの公開や連携は行いません。

```sh
mise exec -- .venv/bin/python -m log_migration.authoring --content content --index data/index/authoring.sqlite3 --site site --host 127.0.0.1 --port 8000
```

`content/` のMarkdownが正本です。最初の保存を行うまでMarkdownファイルは作成されません。
`data/index/authoring.sqlite3` は再生成可能な検索用インデックス、`site/` は公開用の生成物であり、どちらも正本ではありません。
下書きの保存だけでは `site/` を更新しません。執筆画面で明示的に公開操作を行ったときだけ、公開用の静的サイトを生成します。

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
- `data/normalized/site/static/cards-data.json`: カードモードの範囲・深さ切り替え用の静的データ
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

## URLカードのOGP取得

通常の変換は引き続きネットワークへ接続しません。一般URLのタイトル、説明、`og:image` と画像を取得する場合だけ、次の明示的なコマンドを実行します。

```sh
mise exec -- .venv/bin/python -m log_migration.url_metadata \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/url-metadata.json \
  --assets data/normalized/assets \
  --report data/reports/url-metadata-report.json
```

取得結果を静的カードへ反映するには、通常の変換を取得済みJSON付きで再実行します。これはネットワークを使わず、`data/normalized/assets/` の画像を `site/assets/` へコピーしてカードの背景にします。

```sh
mise exec -- .venv/bin/python -m log_migration \
  --input data/raw/scrapbox.json \
  --output data/normalized \
  --report data/reports \
  --url-metadata data/normalized/url-metadata.json \
  --asset-dir data/normalized/assets
```

取得できないURL、OGPのないページ、壊れた画像は、ドメイン・タイトル・元URLを残したフォールバックカードとして表示されます。同じURLはmanifestの固定アセットIDと1つの画像ファイルを共有します。

## テスト

```sh
mise exec -- .venv/bin/python -m pytest -q
```

現フェーズでは、AWS配信、投稿アプリ、編集履歴は扱いません。音声・動画は明示的なアセット取得の対象になりますが、再生用の変換は行いません。まずNAS上で移行結果と記事・アセット間の関係を確認するための土台です。
