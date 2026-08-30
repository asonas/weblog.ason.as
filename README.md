# weblog.ason.as

Scrapbox移行ツールと記事作成画面を管理するリポジトリです。

## セットアップ

```sh
mise install
mise run setup
```

## 開発

```sh
mise run dev
```

ブラウザで`http://127.0.0.1:5173/`を開きます。
Frontendとbackendを個別に起動する場合は、`mise run dev:web`と`mise run dev:api`を使います。Webは`127.0.0.1:5173`、APIは`127.0.0.1:8000`を使用し、portが使用中の場合は起動に失敗します。

production用のsite artifactは次のcommandで`dist/site/`へ生成します。

```sh
mise run build
```

### Scrapboxの行更新日時を取り込む

`Include metadata`付きのScrapboxエクスポートから、開発用SQLiteへ行ごとの作成日時・最終更新日時・更新者IDを取り込みます。

```sh
mise exec -- bin/import-scrapbox-line-metadata \
  --input data/raw/asonas-memo-weblog.json \
  --database data/development/authoring.sqlite3
```

本文とScrapboxの行数が一致するページだけが対象です。取り込み後の保存では、内容が変わらない行の日時を維持し、追加・変更した行を保存時刻で更新します。

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

### 移行済み記事のリスト修復

ScrapboxのインデントをMarkdownのリストへ変換した結果を既存記事へ反映する場合は、通常の`bin/import-dsql`を再実行せず、修正専用コマンドを使います。`--before`の本文ハッシュと本番記事の現在の本文ハッシュが一致する記事だけを更新し、編集済みの記事、新規記事、移行元にない記事は変更しません。移行時の表現修正は記事自体の更新ではないため、`updated_at`も変更しません。`--apply`を付けない実行では本番データを読み取って分類するだけです。

```sh
mise exec -- npm run convert:scrapbox:all -- \
  --input /Users/asonas/Downloads/asonas-memo.json \
  --output /tmp/asonas-memo-weblog-corrected.json

mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bundle exec ruby bin/repair-scrapbox-lists \
    --host zjuauvwetzvab4i3bdfd47e3yu.dsql.ap-northeast-1.on.aws \
    --before data/raw/asonas-memo-weblog-before-list-repair.json \
    --corrected /tmp/asonas-memo-weblog-corrected.json
```

dry-runの結果を確認してから`--apply`を追加します。記事の削除や`--prune-excluded`はこの修復では行いません。

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
mise run check:portable
```

macOSとXcodeがある環境では、iOSを含む全体checkを実行できます。

```sh
mise run check
```

`check:ios`はiOSだけを検証します。coverageは言語別の`*:coverage`で実行し、
production credentialを使う確認とともに通常checkには含めません。

Terraformのmock testは対象resourceだけを評価するため、Terraform自身が
`Resource targeting is in effect`を表示します。実providerやproductionには接続しません。
XcodeはApp Intentsを使わないtargetに対してmetadata抽出skipのwarningを表示します。
SwiftおよびClangがproject sourceに対して出すwarningはerrorとして扱います。
