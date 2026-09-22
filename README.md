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

## テスト

```sh
mise run check:portable
```

macOSとXcodeがある環境では、iOSを含む全体checkを実行できます。

```sh
mise run check
```

`check:ios`はiOSだけを検証します。
coverageは言語別の`*:coverage`で実行します。
production credentialを使う読み取り確認は`mise run check:production`で実行します。
どちらも通常checkには含めません。

変更箇所に近いfocused checkは、次のtaskを使います。

```sh
mise run ruby:lint
mise run ruby:typecheck
mise run ruby:test
mise run frontend:lint
mise run frontend:typecheck
mise run frontend:test
mise run bluesky-oauth:lint
mise run bluesky-oauth:typecheck
mise run bluesky-oauth:test
mise run scrapbox:lint
mise run scrapbox:typecheck
mise run scrapbox:test
mise run terraform:check
mise run check:ios
```

production deployment、OAuth rotation、障害時の確認と復旧は、[production runbook](docs/production-runbook.md)を参照してください。

Terraformのmock testは対象resourceだけを評価するため、Terraform自身が
`Resource targeting is in effect`を表示します。実providerやproductionには接続しません。
XcodeはApp Intentsを使わないtargetに対してmetadata抽出skipのwarningを表示します。
SwiftおよびClangがproject sourceに対して出すwarningはerrorとして扱います。
