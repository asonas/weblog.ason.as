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

開発環境の記事HTMLは、リクエストごとにバックエンドが公開済みデータと`public.html`からレンダリングします。記事閲覧のためのビルドやHTMLファイルの事前生成は不要です。Viteが記事URLをバックエンドへ渡し、閲覧用のCSS・JavaScriptを開発モードで配信します。

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

`convert:scrapbox:all`では、例えば`[日記]`と`#日記`を`[[日記]]`にし、取得済みのGyazo画像も`![](/assets/asset_....jpg)`へ変換します。ハッシュタグの範囲はScrapboxパーサーの判定に従います。コード・テーブルブロック内の`#...`、インラインコード、URLのフラグメント、既存の`[[...]]`はハッシュタグ変換の対象外です。

変換はScrapboxエクスポートJSONを対象とし、ページ・行の日時などのメタデータを保持します。このコマンドはDB更新・HTML再生成・CloudFront invalidationを実行しません。移行済み記事への適用は別工程です。現在のMarkdown本文への一括再適用は、リストや画像なども再変換するため行わないでください。

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

以下のリスト修復は旧`pages`テーブル用です。公開・下書き機構への移行後は使わず、ハッシュタグ修復には後述の専用コマンドを使用します。

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

### 公開・下書き機構のハッシュタグ修復

`bin/repair-scrapbox-hashtags`は、確認済みの行差分JSON（`title`、`before`、`after`を持つ配列）から修復計画を作成します。`before`は旧変換結果、`after`はハッシュタグ対応後の変換結果です。記事内の一致する行だけを置換し、移行時のリスト記号の有無にも対応します。現在の本文・メタデータが公開版と異なる下書き、公開されていない記事、対応する行がない記事は除外します。

```sh
mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bundle exec ruby bin/repair-scrapbox-hashtags plan \
    --host "$DSQL_HOST" --differences /tmp/hashtag-differences.json \
    --backups /tmp/hashtag-backups --plan /tmp/hashtag-plan.json

mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bundle exec ruby bin/repair-scrapbox-hashtags apply \
    --host "$DSQL_HOST" --plan /tmp/hashtag-plan.json \
    --site-bucket "$SITE_BUCKET" --site-url https://weblog.ason.as
```

`plan`は読み取りのみで、公開本文・下書き履歴・日時をローカルに退避します。既存の退避ファイルは再利用するため、再調査には新しい保存先を指定します。`apply`は同じ計画の再実行に対応し、計画後に編集・公開があった記事では停止します。新しいHTMLをS3へ配置・検証してから、Yjs差分の追記と公開版の切替を記事単位のトランザクションで行います。旧公開版と下書き履歴を保持し、記事の作成・更新・公開日時を変更しません。旧`pages`とその行日時情報も変更しません。

この修復コマンドはCloudFront invalidationとWebmention送信を行いません。全件適用後は既存の公開派生データ修復処理でAtom・検索を更新し、公開HTML・下書き復元結果・日時の不変を検証します。作業記録と退避ファイルは適用後も保持してください。

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

Rubyタスクが認証情報なしで動作し、追跡対象ファイルを変更しないことは、`mise run ruby:test-tasks`で検証します。
この検証は`ruby:test`と`ruby:coverage`をそれぞれ実行するため、通常checkには含めません。

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
