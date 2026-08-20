# weblog.ason.as

Scrapboxの保存済みエクスポートを変換するツールと、localhostでMarkdown記事を書くRuby製の投稿画面を管理するリポジトリです。

記事の正本は`content/`のMarkdownとfrontmatterです。`data/index/authoring.sqlite3`はページ・Wikiリンク・逆リンクを検索するための再生成可能なインデックスで、`site/`は明示的な公開操作から作られる派生静的サイトです。

## Ruby投稿画面

Ruby 3.3.6をmiseで選択し、依存gemをインストールします。

```sh
mise exec -- ruby --version
mise exec -- bundle install
```

投稿サーバーは`content/`、`data/index/authoring.sqlite3`、`site/`をリポジトリルートから解決し、既定では`127.0.0.1:8000`だけで待ち受けます。LAN公開、認証、AWS、クラウド、外部APIは扱いません。

```sh
mise exec -- bin/authoring
```

ブラウザで`http://127.0.0.1:8000/`を開きます。`--host`には`127.0.0.1`、`localhost`、`::1`だけを指定できます。

Rackupから同じアプリを起動する場合も、bind先をloopbackに限定します。

```sh
mise exec -- bundle exec rackup -o 127.0.0.1 -p 8000 config.ru
```

保存前の本文はファイルやSQLiteへ書き込まず、保存操作で初めて`content/`へMarkdownを作成します。Wikiリンク先の空ページと逆リンクは自動的に構築されます。下書き保存だけでは`site/`を更新せず、画面から明示的に公開したときだけ静的サイトを差し替えます。

独立した記事プレビュー画面はありません。編集画面の左側にMarkdown入力欄、右側にライブプレビューを表示し、保存済み・未保存を問わずlocalhostの読み取り専用ページをWikiリンクから新しいタブで開けます。

## Scrapbox移行・静的生成

以下は既存のScrapbox移行と静的生成のためのPythonツールです。投稿サーバーの起動には使いません。

### セットアップ

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

## テスト

```sh
mise exec -- bundle exec ruby -Itest test/authoring/test_web.rb
mise exec -- bundle exec ruby -Itest test/authoring/test_e2e.rb
mise exec -- .venv/bin/python -m pytest -q
```

Rubyの投稿機能はlocalhostでの記事作成・編集・公開を対象にします。AWS配信、公開データAPI、編集履歴、OGP取得は扱いません。Python側では音声・動画も明示的なアセット取得の対象になりますが、再生用の変換は行いません。
