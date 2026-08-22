# weblog.ason.as

Scrapbox移行ツールと記事作成画面を管理するリポジトリです。

## セットアップ

```sh
mise install
mise run setup
mise exec -- npm run typecheck
mise exec -- npm run build
```

## 開発

```sh
# ターミナル1
mairu exec --no-login auto -- mise exec -- bin/authoring

# ターミナル2
mise exec -- npm run dev
```

ブラウザで`http://127.0.0.1:5173/`を開きます。

## Scrapbox移行・静的生成

以下は既存のScrapbox移行と静的生成のためのRubyツールです。投稿サーバーの起動とは独立したコマンドです。

### Scrapbox記法の変換

Scrapboxの内部リンクを、weblogのwikiリンクへ変換できます。入力JSONは変更せず、変換後のJSONを別ファイルへ出力します。

```sh
npm run convert:scrapbox:all -- \
  --input data/raw/asonas-memo-weblog.json \
  --output data/raw/asonas-memo-assets.json \
  --asset-manifest data/normalized/asset-manifest.json \
  --asset-fetch-report data/reports/asset-fetch-report.json
```

`convert:scrapbox:all`では、例えば`[日記]`を`[[日記]]`にし、取得済みのGyazo画像も`![](/assets/asset_....jpg)`へ変換します。

画像だけを変換し、Scrapbox内部リンクを変更しない場合は`convert:scrapbox:assets`を使います。

```sh
npm run convert:scrapbox:assets -- \
  --input data/raw/asonas-memo-weblog.json \
  --output data/raw/asonas-memo-assets.json \
  --asset-manifest data/normalized/asset-manifest.json \
  --asset-fetch-report data/reports/asset-fetch-report.json
```

どちらもmanifestの固定asset IDと取得レポートのファイル名を照合します。取得に失敗した画像、通常の外部URL、インラインコード中の記法、すでに変換済みの`[[日記]]`はそのまま保持します。`--asset-manifest`と`--asset-fetch-report`を省略した場合は、上記と同じ`data/normalized/asset-manifest.json`と`data/reports/asset-fetch-report.json`を使用します。

## 変換

保存済みエクスポートを `data/raw/` に置き、次のコマンドを実行します。

```sh
mise exec -- bin/migrate \
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
mise exec -- ruby -run -e httpd -- -p 8000 data/normalized/site
```

## アセット取得

通常の変換ではネットワークへ接続せず、URLのmanifestだけを生成します。画像・音声・動画などを取得する場合だけ、次のコマンドを実行します。

```sh
mise exec -- bin/fetch-assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

取得できないURLがあっても、元のMarkdownとmanifestは変更されません。取得結果はレポートで確認できます。

アセットは `data/normalized/assets/` に保存されます。取得済みファイルはGit管理外ですが、リポジトリの作業ディレクトリに残ります。Scrapboxエクスポートを再生成してから取得する場合は、次の2段階で実行します。

```sh
mise exec -- bin/migrate \
  --input data/raw/scrapbox.json \
  --output data/normalized \
  --report data/reports

mise exec -- bin/fetch-assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

## URLカードのOGP取得

通常の変換は引き続きネットワークへ接続しません。一般URLのタイトル、説明、`og:image` と画像を取得する場合だけ、次の明示的なコマンドを実行します。

```sh
mise exec -- bin/fetch-url-metadata \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/url-metadata.json \
  --assets data/normalized/assets \
  --report data/reports/url-metadata-report.json
```

取得結果を静的カードへ反映するには、通常の変換を取得済みJSON付きで再実行します。これはネットワークを使わず、`data/normalized/assets/` の画像を `site/assets/` へコピーしてカードの背景にします。

```sh
mise exec -- bin/migrate \
  --input data/raw/scrapbox.json \
  --output data/normalized \
  --report data/reports \
  --url-metadata data/normalized/url-metadata.json \
  --asset-dir data/normalized/assets
```

取得できないURL、OGPのないページ、壊れた画像は、ドメイン・タイトル・元URLを残したフォールバックカードとして表示されます。同じURLはmanifestの固定アセットIDと1つの画像ファイルを共有します。

## テスト

```sh
mise exec -- bundle exec ruby -Itest -e 'Dir["test/authoring/test_*.rb", "test/migration/test_*.rb"].sort.each { |file| require_relative file }'
```

Rubyの投稿機能はlocalhostでの記事作成・編集・公開を対象にします。
