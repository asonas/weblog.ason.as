---
name: verify-weblog-authoring
description: weblog.ason.asの管理画面（/authoring/*、/draft-editor）を、一時DBのfixture APIとViteで起動し、Chromeでユーザーと同じ操作をして変更が動くことを証拠つきで確かめる。管理画面・エディタ・記事一覧・端末ペアリングの変更を実機の画面で検証するとき、または「動くことを確かめて」と頼まれたときに使う。
---

# 管理画面を実際に操作して検証する

`test/fixtures/drafts/server.rb` が一時ディレクトリのDBとstubしたS3でAPIを18082番に、Viteが15182番で管理画面を配信する。mainの開発DB、`mise run dev:api` のAWS認証（envchain、mairu）、本番には触れない。
起動・診断・操作・停止は、このスキルの `scripts/` を作業worktreeのルートから実行する。

## 前提

1. 作業worktreeのルートで `mise run dev:doctor` を実行し、`Node dependencies: OK` と `Ruby dependencies: OK` を確認する。最後の `API: 8000番の待受なし` はこの検証では使わないので無視してよい。
2. Node依存が不足し `node_modules` が存在しない場合は、`cmp package-lock.json <mainのパス>/package-lock.json` が一致するときだけ `ln -s <mainのパス>/node_modules node_modules` で一時リンクを作り、検証後に削除する。既存の `node_modules` があるかlockfileが異なる場合は `mise exec -- npm ci` を実行する。
3. Chrome（`channel: "chrome"`）がインストールされていること。sandboxがポートのbindやChrome起動を拒否した場合は、必要な権限で再実行する。

## 起動

```sh
node .agents/skills/verify-weblog-authoring/scripts/launch.mjs            # legacy形式、空のDB
node .agents/skills/verify-weblog-authoring/scripts/launch.mjs --pieces   # ARTICLE_PIECES_ENABLED=true（かけら形式）
node .agents/skills/verify-weblog-authoring/scripts/launch.mjs --legacy-diary  # 今日の日付のlegacy日記を1件seed
```

`ready: http://127.0.0.1:15182` が出たら使える。APIとViteの両方が起動時に生成したトークンを返し、`/authoring/articles` の取得が成功するまで待つ。状態は `tmp/verify-weblog-authoring/instance.json`、ログは同じディレクトリの `api.log` と `web.log` に残る。

`server.rb` がAPIのポートを18082番に固定しているため、同時に動かせるインスタンスは1台だけ。`test/browser/*.mjs` も同じ18082・15182番を使う。launchは既存の記録や待受があれば起動を拒否する。その待受を止めるのは、起動元が自分だと確かめた場合だけにする。

## 診断

```sh
node .agents/skills/verify-weblog-authoring/scripts/doctor.mjs
```

読み取り専用。起動プロセスが生きているか、待受PIDのcwdがこのworktreeか、APIとVite経由の両方が自分のトークンを返すか、`/api/auth/session` が `can_edit=true` か、を確かめる。1行でも `NG` があれば、そのインスタンスは操作しない。操作の前と、挙動がおかしいときに実行する。

## 操作

```sh
node .agents/skills/verify-weblog-authoring/scripts/drive.mjs <journey.mjs> [label]
```

ジャーニーは `export default async ({ page, context, webBase, evidence, shot, step }) => {}` を公開するファイルで、Playwright（`playwright-core`）の `page` を操作する。`shot(name)` は全画面のスクリーンショットを、`step(text)` は操作記録を保存する。drive.mjsはconsole、pageerror、失敗したリクエストを記録し、pageerrorが1件でもあればFAILにする。

- 既存のジャーニー: `journeys/draft-save-reload.mjs`（新しい記事を書き、サーバー保存・再読み込み・別コンテキストでの復元・一覧表示を確かめる）。
- 新しいジャーニーは `features/` の該当ファイルにある操作手順から書く。要素はroleとaccessible name（`getByRole`、`getByLabel`）で指定し、CSSクラスや位置に頼らない。
- 同じ機能の既存テスト `test/browser/*.mjs` があれば、まず読んで要素名と待ち方を借りる。どのテストが何を扱うかは `docs/browser-testing.md` にある。
- 遅延・通信失敗を再現するときは、その境界のリクエストだけを `page.route` で置き換える。APIの応答を一式mockしない。

## 証拠

`tmp/verify-weblog-authoring/evidence/<時刻>-<label>/` に、番号つきスクリーンショット、`journey.log`（操作・console・失敗リクエスト）、`result.json`（合否とpageerror）、失敗時は `failure.png` が残る。ジャーニーが自分で書いたファイル（例: `draft-api.json`）も同じ場所に置く。

- ユーザーが通る経路を操作する。内部のsetterやテスト専用エンドポイントで状態を作って、それを結果と呼ばない。
- 操作した瞬間と結果の両方を残す。最後の画面だけでは不十分。
- 保存の証明は画面表示だけにしない。APIからの読み直し（`/api/authoring/drafts/<id>?protocol=1&generation=1&cursor=0`）か、IndexedDBを持たない別のブラウザコンテキストでの再表示を添える。
- 報告にはジャーニー名、起動オプション（`--pieces` など）、証拠ディレクトリのパスを書く。到達できなかった経路は、試したコマンドと満たせなかった前提を書き、別の経路で代替して検証済みと書かない。

## 停止

```sh
node .agents/skills/verify-weblog-authoring/scripts/cleanup.mjs
```

launch.mjsが起動したプロセスグループだけをSIGTERMで止め、pumaが一時DBを削除する。停止しなければSIGKILLする。プロセス名でkillしない。`instance.json` を消し、ログと `evidence/` は残す。18082・15182番の待受が残っていれば起動元を報告して終了コード1を返すので、その場合は起動元を確かめてから対処する。失敗した試行の後も毎回実行する。手順2で作った `node_modules` の一時リンクも検証後に削除する。

## 機能の地図

`features/README.md` が検証の入口。変更が触れる機能のファイルを開き、そこに書かれた入口をすべて確かめる。地図に入口が複数あるのに1つだけ操作した場合は、その旨を報告する。

## 対象外

- 公開（`公開する`）: fixtureのS3はstubで、公開ページの生成と配信は確かめられない。公開処理は `docs/runbooks/pieces-production-release.md` を参照する。
- 公開サイトの見た目（`/`、記事ページ）: このfixtureは記事の公開HTMLを持たない。`test/browser/home_cover.mjs` を参照する。
- GitHubログイン、Bluesky OAuth、Raindropなど外部サービスとの実通信。
- 日本語IMEの変換中入力や実機キーボード。合成イベントでは確認できないので、実際に確かめた範囲を記録する。
