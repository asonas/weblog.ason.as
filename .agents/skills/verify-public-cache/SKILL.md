---
name: verify-public-cache
description: 記事の初回公開・更新・改名のあと、CloudFrontの公開キャッシュに古い版や関連ページが残らないことを、実コードの公開処理を操作列で全探索して確かめる。draft_publications.rb、draft_jobs.rb、draft_cache_store.rb、draft_output_store.rb、draft_renames.rb、public_cache.rb、draft_site.rb の公開・キャッシュ更新・改名・公開HTML配信を変更したとき、または公開キャッシュの検証を頼まれたときに使う。
---

# Verify public cache

性質: 公開処理が落ち着いたあと、記事のroute（`/route` と `/route/`、改名後は旧routeも）についてCloudFrontが保持する応答は、originが今返す版と同じものを指す。
破れたときの害: 読者は最大24時間（`s-maxage=86400`、障害時はさらに `stale-if-error=86400`）、作者が公開した記事の代わりに古い版や公開前の関連ページを見続ける。

## 変更が対象か判断する

1. 同期コミットからの差分を見る。何か出れば、この検証の対象になる変更である。

   ```sh
   git --no-pager diff c76da44 -- lib/weblog_authoring/draft_publications.rb lib/weblog_authoring/draft_publication.rb lib/weblog_authoring/draft_cache_store.rb lib/weblog_authoring/public_cache.rb lib/weblog_authoring/draft_jobs.rb lib/weblog_authoring/draft_output_store.rb lib/weblog_authoring/draft_renames.rb lib/weblog_authoring/draft_publisher.rb lib/weblog_authoring/draft_site.rb lib/weblog_authoring/webmention_site_publisher.rb lib/weblog_authoring/lambda_api.rb lib/weblog_authoring/published_article_reader.rb infra/production/hosting.tf infra/production/lambda.tf
   ```

2. 差分が下の「対応表」の関数に触れていれば、次の手順で検証を実行する。触れていなくても、`PUBLIC_HTML_CACHE_CONTROL`、CloudFrontのcache policy、`DYNAMIC_PUBLIC_ARTICLE_ROUTES` の変更は前提を変えるので、「前提」を読み直す。

## 実行する

1. 作業worktreeのルートで `mise exec -- bundle check` を確認する。不足していれば `mise exec -- bundle install` を実行する。Node、`node_modules`、AWS認証、ネットワークは使わない。
2. 次を実行する。手元で約1分かかる。

   ```sh
   mise exec -- bundle exec ruby .agents/skills/verify-public-cache/check.rb
   ```

3. 最終行の `要約:` を下の基準値と比べる。終了コードは不一致か例外が1件でもあれば1になるため、c76da44 では既知の発見2件により1になる。
4. 反例を1件だけ詳しく見るときは、要約の括弧内の `<初期状態>:<操作列>` を渡して再生する。

   ```sh
   mise exec -- bundle exec ruby .agents/skills/verify-public-cache/check.rb --replay S1:RFNE
   ```

   深さは `--s0-depth`（既定3）と `--s1-depth`（既定4）で変えられる。既定より浅くした結果を合格の根拠にしない。

## 結果を読む

c76da44 の基準値:

```text
要約: first_publication_hub=162(S0:E) rename_new_route=0 rename_old_route=6(S1:RFNE) same_route_update=0 other=0
```

- `[成功]` の種類は、探索した全操作列で不一致がなかった。`[失敗]` の種類には、操作数が最も少ない反例を手順として表示する。各手順の `-` 行は、その操作中に実コードで起きたこと（`DraftPublication#accept` の受付とキャッシュ要求、`finish_publication`・`finish_rename` による有効版の切替、CreateInvalidationの結果、読者のGETでCDNが保存した版）である。
- 要約が基準値と同じなら、既知の発見だけが残っている。種類が増えた、`[成功]` が `[失敗]` になった、件数や最短の反例が変わった場合は、変更が性質に影響している。その反例を `--replay` で再生し、手順をコードと照らして説明できるか確かめる。
- 表示された `article:vN` は記事の公開版（受付順の番号）、`hub` は未作成routeの関連ページ（`WebmentionSitePublisher#render_linked_page`）、`redirect:<route>` は改名元routeの転送、`status:404` は存在しないrouteを表す。

### 既知の発見（c76da44）

1. `first_publication_hub`: 初回公開でパージ要求を作らないため、公開前に保存された関連ページが残る。
   1. 公開記事 Index が `[[Topic]]` を含むので、未公開の `/Topic` には `DraftSite#call` が関連ページを `PUBLIC_HTML_CACHE_CONTROL`（`s-maxage=86400`）で返し、CDNが保存する。
   2. 作者が記事 Topic を初めて公開する。`DraftStore#accept_verified_publication` は `active` がないため `prepare_cache_request` を呼ばない。
   3. `DraftJobs#run` が `finish_publication` で v1 を有効にする。cache stageは作られない。
   4. CDNの `/Topic` と `/Topic/` は関連ページのまま、originは記事 v1 を返す。

   1c0bf08 で条件が `if active && verified["invalidate_cache"]` になり、`docs/runbooks/public-delivery-cost.md` も「初回公開ではパージ要求を作成しない」に変わった。一方 `docs/public-cache-policy-proposal.md` のパージ対象表は「記事の初回公開」も当該routeをパージするとしている。どちらが意図かはユーザーが決める。
2. `rename_old_route`: 改名のパージがAWSの一時失敗で再試行待ちの間に次の公開が有効になると、旧routeのパージが失われる。
   1. 公開済みの記事 Topic（v1）を Renamed へ改名して公開する。v2 のキャッシュ要求は `/Renamed` `/Renamed/` `/Topic` `/Topic/`。
   2. `DraftJobs#run(v2)` が `finish_rename` で v2 を有効にしたあと、CreateInvalidationが失敗し、cache stageは `retry_wait` になる。
   3. 再試行の前に作者が本文を直して公開する。`active` は v2（route Renamed）なので、v3 のキャッシュ要求は `/Renamed` `/Renamed/` だけになる。
   4. v3 が有効になると `DraftOutputStore#supersede_publication_stages` が v2 のcache stageを `superseded` にし、`DraftJobs#repair` も最新版と有効版しか見ない。
   5. CDNの `/Topic` は v1 のまま、originは `/Renamed` への転送を返す。

   同じ結果は、2つの `DraftJobs#run` が並行し、v2 の有効化からcache stageまでの間に v3 が有効になったときにも起こり得る。この並行実行は探索していない。

### 実バグとモデルの誤りを見分ける

- `DraftJobs#run の例外` が0件でなければ、まずスクリプトの準備やスタブの誤りを疑う。`--replay` で例外の出た手順を確認する。
- 反例の手順に `受付拒否` があれば、その操作は製品コードが正しく拒否している。不一致の原因はその前後の手順にある。
- 反例が `F`（AWSの一時失敗）に依存しているなら、AWSが同じ失敗を返し得るかを確かめる。依存していなければ、通常の公開操作だけで起きる。
- 反例をコードで説明できないときは、下の「前提」のどれに依存しているかを特定する。前提が本番と違っていればスクリプトを直し、本番どおりなら実バグとして報告する。

## 対応表

各要素は実コードを直接呼ぶ。1文字の操作は1回のメソッド呼び出しで、その中のDBトランザクションは製品コードのものをSQLiteでそのまま使う。

| 検証の要素 | 実コード |
| --- | --- |
| `E` 本文を編集して公開を受け付ける | `DraftStore#append`、`DraftPublication#prepare`・`#accept`、`DraftStore#accept_verified_publication`（`draft_publications.rb`）、`DraftCacheStore#prepare_cache_request`（`draft_cache_store.rb`） |
| `R` タイトルを Topic と Renamed の他方へ変えて公開を受け付ける | 上と同じ。加えて `DraftRenames#rename_impact`・`#stage_rename_versions`・`#accept_rename_batch`（`draft_renames.rb`） |
| `N`・`L` 公開ワーカーが古い順・新しい順に版を処理する | `DraftJobs#run`（`draft_jobs.rb`）、`DraftPublisher#run`、`DraftPublication#complete`、`DraftStore#finish_publication`・`DraftRenames#finish_rename`、`PublicCache#refresh`（`public_cache.rb`）、`DraftOutputStore#begin_publication_stage`・`#complete_publication_stage`・`#fail_publication_stage`・`#supersede_publication_stages`、`DraftCacheStore#wait_publication_cache` |
| `F` 次のCreateInvalidationを1回失敗させる | `Aws::CloudFront::Client` のスタブが `ServiceUnavailable` を返す |
| `P` 60秒後の定期修復 | `DraftJobs#repair`、`DraftOutputStore#publication_repair_jobs` |
| settle | 失敗を止め、未処理の版を古い順に `DraftJobs#run`、3601秒ずつ進めて `DraftJobs#repair` を4回 |
| 読者のGET | `DraftSite#call`（`draft_site.rb`）。未公開routeは `WebmentionSitePublisher#render_linked_page`、改名元routeは `LambdaApi` の301を返す |
| CDNが保存するか | `infra/production/hosting.tf` の `public_html` cache policy（`min_ttl = 0`、`default_ttl = 0`）に合わせ、`cache-control` に `no-store`・`no-cache`・`private` がなく `s-maxage` か `max-age` が正のときだけ保存する |
| 応答がどの版か | `DraftRenames#resolve_published_route` |
| パージ | `PublicCache#refresh` が送るCreateInvalidationのpathsをCDNから消す |

初期状態:

- `S0`: 記事 Topic は未公開。公開記事 Index が `[[Topic]]` と `[[Renamed]]` を含むので、両routeは関連ページを返す。
- `S1`: 記事 Topic は v1 で公開済み。CDNは期限切れで空。`S0` から `E`、`N` を実コードで実行して作る。

## 範囲と前提

探索の範囲:

- `S0` から操作3つまで、`S1` から操作4つまでの全操作列（259件と1555件）。各操作列の最後にsettleして判定する。
- 記事は Topic の1本、route は ASCII の `Topic` と `Renamed` の2つ。参照元は Index の1本。
- 読者は毎回の操作の後と、各CreateInvalidationが反映された直後に、4つのpathをすべて取得する。保存済みのpathはCDNが応答し、originを呼ばない。

前提（本番との違い）:

- 下書きworker（`lambda/draft_worker`）の復元は、headごとのMarkdownを返すブロックに置き換えている。Atom・検索の出力は常に最新として扱う。
- CreateInvalidationは受け付けた時点でCDNから消える。同じCallerReferenceの再送は既存のbatchを返し、再度は消さない。GetInvalidationは1回目に `InProgress`、以降は `Completed` を返す。
- TTLの満了は扱わない。探索中の時刻は24時間より十分短い。
- 版の比較は本文ではなく、どの公開版・関連ページ・転送かで行う。Mentioned by days、関連ハブ、RSS、参照元記事の連鎖パージは設計上の対象外なので、本文の差としては数えない。

対象外:

- 並行する `DraftJobs#run` やAPI要求の、メソッド内部での割り込み。
- 日本語・空白を含むroute、旧percent encoding表記、クエリ文字列のキャッシュキー。CloudFrontの正規化はローカルで確かめられない。
- `linked_article_publications` が作る日記からのリンク先記事の公開（`DraftPublisher#run` 経由でキャッシュ要求を作らない）。
- 5回失敗して `needs_attention` になったcache stageと、管理画面からの再試行。
- tildeや長すぎるpathで `PublicCache.paths` がキャッシュ要求を作らない場合。
- 参照元記事、関連ハブ、RSS、トップ・検索のキャッシュ。

## 壊して確かめた記録（c76da44）

検証が破れを見つけられることを、製品コードを一時的に壊して確かめた。どれも確認後に `git checkout --` で戻し、`git status` で差分がないことと、要約が基準値に戻ることを確認した。

| 一時的な変更 | 要約 |
| --- | --- |
| `DraftJobs#run` のcache stageを html stage の前へ移し、有効化の条件を外す | `same_route_update=495(S1:E)`、`rename_new_route=461(S1:R)`、`rename_old_route=540(S1:R)` が新たに失敗。パージ直後の読者が旧版 v1 をCDNに戻す |
| `accept_verified_publication` から `routes << active.fetch("route") ...` を消す | `rename_old_route=665(S1:R)`。AWSの失敗なしの改名だけで旧routeが残る |
| 条件を1c0bf08より前の `if verified["invalidate_cache"]` に戻す | `first_publication_hub=0`。他は基準値と同じ |

深さを `--s0-depth 4 --s1-depth 5`（1555件と9331件、約6分）に広げても、失敗する種類は既知の2つだけだった。

## 意図した変更で検証を更新する

- 製品コードの関数名や呼び出し順が変わったら、`check.rb` の対応する操作と上の対応表を同じ変更で直す。各要素が実コードを呼ぶことを保つ。
- 不一致を消すために性質や判定を弱めない。ユーザーが既知の発見を仕様として受け入れると決めた場合だけ、その判断と日付を「既知の発見」に書き、基準値を更新する。
- 発見を直した変更では、該当する種類が `[成功]` になることを確かめ、基準値を更新する。
- 新しい操作や初期状態を足したら、壊した版のコードで新しい種類が `[失敗]` になることを一度確かめ、元に戻して `git status` で差分がないことを確認する。

## 同期記録

- 同期コミット: c76da44
- 検証した範囲: `lib/weblog_authoring/draft_publications.rb`（`accept_verified_publication`、`finish_publication`、`published_snapshot`）、`lib/weblog_authoring/draft_publication.rb`（`prepare`、`accept`、`complete`）、`lib/weblog_authoring/draft_cache_store.rb`（`prepare_cache_request`、`cache_request`、`wait_publication_cache`）、`lib/weblog_authoring/public_cache.rb`（`PublicCache.paths`、`PublicCache#refresh`）、`lib/weblog_authoring/draft_jobs.rb`（`run`、`repair`、`perform`）、`lib/weblog_authoring/draft_output_store.rb`（`begin_publication_stage`、`complete_publication_stage`、`fail_publication_stage`、`supersede_publication_stages`、`publication_repair_jobs`）、`lib/weblog_authoring/draft_renames.rb`（`rename_impact`、`stage_rename_versions`、`accept_rename_batch`、`finish_rename`、`resolve_published_route`）、`lib/weblog_authoring/draft_publisher.rb`（`run`）、`lib/weblog_authoring/draft_site.rb`（`call`、`dynamic_article`、`public_html`、`PUBLIC_HTML_CACHE_CONTROL`）、`lib/weblog_authoring/webmention_site_publisher.rb`（`render_linked_page`）、`lib/weblog_authoring/lambda_api.rb`（公開routeのGET分岐。改名元routeの301は `cache-control: no-cache`、未公開routeは404を返し、`DraftSite#call` が関連ページへ切り替える）、`lib/weblog_authoring/published_article_reader.rb`（`list_pages`。関連ページのリンク元を読む）、`infra/production/hosting.tf`（`aws_cloudfront_cache_policy.public_html`）、`infra/production/lambda.tf`（`DYNAMIC_PUBLIC_ARTICLE_ROUTES`）
- 同期コミットは、そのコミットで検証を実行し、対応表と前提がコードを正しく表していることを確かめてから進める。検証を実行しただけ、または結果が基準値と同じだっただけでは進めない。
