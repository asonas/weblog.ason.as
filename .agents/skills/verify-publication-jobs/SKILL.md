---
name: verify-publication-jobs
description: 記事の公開処理（受付、公開ワーカーのstage、再試行、失効、定期修復、記事一覧の表示）が、どの操作順でも古い版を公開せず、二重に版を作らず、止まったまま要確認も出さない状態にならないことを、実コードの公開処理を操作列で全探索して確かめる。draft_publications.rb、draft_publication.rb、draft_jobs.rb、draft_output_store.rb、draft_cache_store.rb、draft_administration.rb、draft_store.rb の公開・stage・一覧表示を変更したとき、または公開処理の検証を頼まれたときに使う。
---

# Verify publication jobs

性質: 作者がどの順で「公開する」「公開を再試行」「再試行」を押し、公開ワーカーがどの順で処理し、S3やCloudFrontがどこで失敗しても、公開中の版は最新の受付を追い越して古い版に戻らず、1つの公開要求から版は1つだけ作られ、障害が止めば最新の公開処理は完了するか記事一覧に要確認が出る。
破れたときの害: 読者が作者の直した記事の代わりに古い版を読み続ける、または作者が「反映済み」や「公開処理中」を見て安心している間に公開が止まり、誰も気づかない。

## 変更が対象か判断する

1. 同期コミットからの差分を見る。何か出れば、この検証の対象になる変更である。

   ```sh
   git --no-pager diff 81a8587 -- lib/weblog_authoring/draft_publications.rb lib/weblog_authoring/draft_publication.rb lib/weblog_authoring/draft_jobs.rb lib/weblog_authoring/draft_output_store.rb lib/weblog_authoring/draft_cache_store.rb lib/weblog_authoring/draft_administration.rb lib/weblog_authoring/draft_store.rb lib/weblog_authoring/draft_publisher.rb lib/weblog_authoring/public_cache.rb lib/weblog_authoring/draft_runtime.rb lib/weblog_authoring/lambda_api.rb frontend/authoring/DraftAdministration.tsx
   ```

2. 差分が下の「対応表」の関数に触れていれば、次の手順で検証を実行する。`draft_store.rb` は `administration_page` のSQL（一覧が見せる `latest_id`）だけが対象である。`DraftAdministration.tsx` の `needsAttention` を変えたら、`check.rb` の `attention?` を同じ条件に直してから実行する。
3. 公開キャッシュ（CDNに古い版が残るか）は対象外で、`verify-public-cache` スキルが扱う。`DraftJobs#run`、`DraftCacheStore` を変えたときは両方を実行する。

## 実行する

1. 作業worktreeのルートで `mise exec -- bundle check` を確認する。不足していれば `mise exec -- bundle install` を実行する。Node、AWS認証、ネットワークは使わない。
2. 次を実行する。手元で約1分かかる。

   ```sh
   mise exec -- bundle exec ruby .agents/skills/verify-publication-jobs/check.rb
   ```

3. 最終行の `要約:` を下の基準値と比べる。規則違反か例外が1件でもあれば終了コードは1になる。
4. 反例を1件だけ詳しく見るときは、要約の括弧内の `<初期状態>:<操作列>` を渡して再生する。各手順で実コードが返したjobとstageの状態、公開中の版が表示される。

   ```sh
   mise exec -- bundle exec ruby .agents/skills/verify-publication-jobs/check.rb --replay S0:EKT
   ```

   深さは `--s0-depth`（既定3）と `--s1-depth`（既定3）で変えられる。既定より浅くした結果を合格の根拠にしない。

## 結果を読む

基準値（81a8587）:

```text
要約: superseded_published=0 active_regressed=0 webmention_twice=0 duplicate_version=0 finished_not_live=0 silent_stall=0
```

規則（`check.rb` の `RULES`）。各操作の後と settle の各手順の後に確かめる。`silent_stall` だけは settle の最後に確かめる。

| 規則 | 破れたときの状態 | 読者・作者への害 |
| --- | --- | --- |
| `superseded_published` | 失効した版が公開中の版になる | 作者が「失効済み」と見た版を読者が読む |
| `active_regressed` | 公開中の版が、それより前に受け付けた版に戻る | 直したはずの記事が古い版に戻る |
| `webmention_twice` | Webmentionの送信要求が最初の公開以外でも作られる | 更新のたびにリンク先へ通知が飛ぶ |
| `duplicate_version` | 同じ request_id から版が2つ以上作られる | 応答が届かずに再送しただけで公開がやり直しになり、前の処理が失効する |
| `finished_not_live` | 記事一覧の公開処理がすべて反映済みなのに、公開中の版が最新の受付でない | 作者は反映済みと思うが、読者には古い版が見える |
| `silent_stall` | 障害が止んで落ち着いた後、最新の公開処理が完了せず、要確認も出ない | 公開が止まったまま誰も気づかない |

- `[成功]` の規則は、探索した全操作列で破れなかった。`[失敗]` の規則には、操作数が最も少ない反例を手順として表示する。各手順の `-` 行は、その操作中に実コードで起きたこと（`DraftPublication#accept` の結果、`DraftJobs#run` が返したjobとstage、公開中の版）である。
- `v1` `v2` は受付順の版の名前、`request-N` は「公開する」を押した順の公開要求である。
- 要約が基準値と同じなら、性質は保たれている。`[失敗]` が出たら、その反例を `--replay` で再生し、手順をコードと照らして説明できるか確かめる。

### 実バグとモデルの誤りを見分ける

- `DraftJobs の例外` が0件でなければ、まずスクリプトの準備やスタブの誤りを疑う。`--replay` で例外の出た手順を確認する。製品コードは失敗をstageに記録して例外を外へ出さないので、例外は通常スクリプト側の問題である。
- 反例に `受付拒否` があれば、その操作は製品コードが正しく拒否している。違反の原因はその前後の手順にある。
- 反例が `H`・`F`・`K`（S3やCloudFrontの失敗）に依存しているなら、本番のAWSが同じ失敗を返し得るかを確かめる。依存していなければ、通常の操作だけで起きる。
- `silent_stall` の反例では、settle後の一覧のjobとstageの状態が表示される。`queued`・`running` のstageが残っていれば、`DraftJobs#repair` がその版を拾う条件（最新版と公開中の版だけを見る）と、`DraftOutputStore#begin_publication_stage` の待ち時間を確かめる。
- 反例をコードで説明できないときは、下の「前提」のどれに依存しているかを特定する。前提が本番と違っていればスクリプトを直し、本番どおりなら実バグとして報告する。製品コードは、ユーザーに頼まれるまで直さない。

## 対応表

各操作は実コードを直接呼ぶ。1文字の操作はメソッド呼び出しの列で、その中のDBトランザクションは製品コードのものをSQLiteでそのまま使う。

| 検証の要素 | 実コード |
| --- | --- |
| `E` 本文を編集して「公開する」 | `DraftStore#append`、`DraftPublication#prepare`・`#accept`（`draft_publication.rb`）、`DraftStore#accept_verified_publication`（`draft_publications.rb`）、`DraftCacheStore#prepare_cache_request` |
| `U` 編集せずに「公開する」 | `DraftPublication#prepare`・`#accept`。公開中の版と同じ内容なら `accept_verified_publication` の `unchanged` 分岐（`latest_id = active_id`） |
| `D` 同じ request_id で再送 | `DraftPublication#accept` と `accept_verified_publication` の `publication_receipt_from`（`article_publication_receipts`）。エディタの `draftSession.ts` `publish` が `pendingPublication` を保持して再送する経路にあたる |
| `N`・`L` 公開ワーカーが古い順・新しい順に受付を処理 | `DraftJobs#run(retry_now: true)`（`draft_runtime.rb` の dispatch 処理と同じ引数）、`DraftPublisher#run`、`DraftPublication#complete`、`DraftStore#finish_publication`・`#fail_publication`、`DraftOutputStore#begin_publication_stage`・`#complete_publication_stage`・`#fail_publication_stage`・`#supersede_publication_stages`、`PublicCache#refresh`、`DraftCacheStore#wait_publication_cache` |
| `H` 次のHTML配置を1回失敗させる | `DraftPublisher` が使うS3の `put_object` を `IOError` で失敗させる（`FlakyObjects`） |
| `F` 次のCreateInvalidationを1回失敗させる | `Aws::CloudFront::Client` のスタブが `ServiceUnavailable` を返す |
| `K` S3障害が続き最新版のページ生成が5回失敗 | `put_object` を5回失敗させ、最新版に `DraftJobs#run` を5回、間に3601秒進める。`fail_publication_stage` が5回目で `needs_attention` にする |
| `T` 記事一覧で「再試行」 | `DraftAdministration.tsx` `retry` → `POST /publications/:version/run` → `DraftJobs#run(retry_now: true)`（`development_app.rb`、`lambda_api.rb`）。対象は一覧が示す最新版 |
| `P` 1時間進めて定期修復 | `DraftJobs#repair`、`DraftOutputStore#publication_repair_jobs`（`infra/production/draft_worker.tf` の `rate(1 hour)`） |
| settle | 失敗を止め、未処理の受付を古い順に `DraftJobs#run`、3601秒ずつ進めて `DraftJobs#repair` を4回 |
| 記事一覧の表示 | `DraftAdministration#list` → `article_row` の `publication`（`latest_id` のjobとstage）、`DraftStore#administration_page` |
| 要確認か | `check.rb` の `attention?`。`DraftAdministration.tsx` の `needsAttention` の公開処理部分（jobが `needs_attention`・`superseded`、stageが `needs_attention`・`retry_wait`）と同じ条件 |

初期状態:

- `S0`: 記事 Topic は作成済みで未公開。
- `S1`: 記事 Topic は v1 で公開済み、全stage完了。`S0` から `E`、`N`、settle を実コードで実行して作る。

## 範囲と前提

探索の範囲:

- `S0`・`S1` からそれぞれ操作3つまでの全操作列（各1111件）。各操作列の最後にsettleして `silent_stall` を判定する。
- 記事は Topic の1本。本文の内容は head ごとに変わるので、`E` のたびに別の内容になる。

前提（本番との違い）:

- 下書きworker（`lambda/draft_worker`）の復元は、headごとのMarkdownを返すブロックに置き換えている。Atom・検索の出力は常に最新として扱う（`CurrentOutputs`）。
- CloudFrontのGetInvalidationは1回目に `InProgress`、以降は `Completed` を返す。1回目は `PublicCache::Pending` になり、cache stageは `retry_wait` で待つ。
- 探索はUIより多くの操作を許す。`T` はどの状態でも押せるが、記事一覧は再試行を、公開処理が失効しておらず要確認か受付直後のときだけ見せる。`D` は受付拒否（409）の後でも再送するが、`draftSession.ts` の `publish` は409で `pendingPublication` を捨てる。操作を広げても違反は隠れないが、反例がUIでは押せない操作に依存していれば、それを先に確かめる。
- 公開を受け付けた直後のdispatch（`queue_publication_dispatch` と非同期のworker起動）は、`N`・`L` で取り出す待ち行列として扱う。dispatchの起動失敗は扱わない。

対象外:

- 並行する `DraftJobs#run` やAPI要求の、メソッド内部での割り込み。特に `finish_publication` の `latest_id` 照合は、順に実行する範囲では `DraftPublication#complete` の失効済みjobの早期returnより後ろにあり、この検証では効いていない（壊して確かめた記録のB3）。この照合が守るのは、v1の処理中にv2が有効になる並行実行で、ここでは探索していない。
- 5分を超えて止まった `running` stageの回収、Lambdaのタイムアウト。
- 改名のまとめ処理（`finish_rename`）、日記からのリンク先記事（`linked_article_publications`）、memos stage。
- 公開前の確認（`preparePublication`）とエディタの表示。エディタ側の保存は `verify-draft-sync` スキルが扱う。
- 公開キャッシュの中身。`verify-public-cache` スキルが扱う。

### 観察（規則にしていないもの）

- 正常なCloudFrontの更新待ち（`PublicCache::Pending` → cache stage `retry_wait`、エラー文「キャッシュ更新中です。」）でも、記事一覧に要確認が出る（`DraftAdministration.tsx` の `needsAttention` が `retry_wait` を含む）。要確認を作者の操作が必要なときだけに出すかはユーザーが決めていない。決まったら規則として加える。

## 壊して確かめた記録（81a8587）

検証が破れを見つけられることを、製品コードを一時的に壊して確かめた。どれも確認後に `git checkout -- lib` で戻し、`git status --short lib` で差分がないことと、要約が基準値に戻ることを確認した。

| 一時的な変更 | 要約 |
| --- | --- |
| B1: `finish_publication` の失効分岐で、jobを `superseded` にしたあと `active_id` も更新する | `superseded_published=116(S0:EE)` |
| B2: `finish_publication` の `unless head["active_id"]` を外し、有効化のたびにWebmention要求を作る | `webmention_twice=299(S1:E)` |
| B3: `finish_publication` の `latest_id` 照合を外す（`if false`） | 変化なし。順に実行する範囲では到達しない（対象外を参照） |
| B3b: B3に加えて `DraftPublication#complete` の失効済みjobの早期returnと `finish_publication` の完了済みjobの早期returnを外す | `active_regressed=18(S0:EEL)` |
| B4: `DraftStore#administration_page` が `COALESCE(h.active_id, h.latest_id) AS latest_id` を返す（一覧が公開中の版の処理を見せる） | `finished_not_live=295(S1:E)` |
| B5: `DraftPublication#accept` と `accept_verified_publication` のreceipt参照を外し、receiptのINSERTを `ON CONFLICT DO NOTHING` にする | `duplicate_version=73(S0:ED)` |
| B6: `finish_publication` から `active_id` を更新するUPDATEを消す | `silent_stall=1637(S1:)`、`webmention_twice=542(S1:E)` |

## 意図した変更で検証を更新する

- 製品コードの関数名や呼び出し順が変わったら、`check.rb` の対応する操作と上の対応表を同じ変更で直す。各操作が実コードを呼ぶことを保つ。
- 違反を消すために規則や判定を弱めない。ユーザーが違反を仕様として受け入れると決めた場合だけ、その判断と日付を「観察」に書き、規則を外して基準値を更新する。
- 新しい操作や初期状態、規則を足したら、壊した版のコードでその規則が `[失敗]` になることを一度確かめ、元に戻して `git status` で差分がないことを確認し、上の記録に足す。
- 反例の手順を図で見たいときや、設計の段階で状態の移り方を確かめたいときは、`/statechart` スキルで公開処理の状態図を描ける。

## 同期記録

- 同期コミット: 81a8587
- 検証した範囲: `lib/weblog_authoring/draft_publications.rb`（`accept_verified_publication`、`publication_receipt_from`、`finish_publication`、`fail_publication`、`published_snapshot`、`publication_job`）、`lib/weblog_authoring/draft_publication.rb`（`prepare`、`accept`、`complete`）、`lib/weblog_authoring/draft_jobs.rb`（`run`、`repair`、`perform`）、`lib/weblog_authoring/draft_output_store.rb`（`publication_stages`、`begin_publication_stage`、`complete_publication_stage`、`fail_publication_stage`、`supersede_publication_stages`、`publication_repair_jobs`、`cleanup_publication_stages`）、`lib/weblog_authoring/draft_cache_store.rb`（`prepare_cache_request`、`cache_request`、`wait_publication_cache`）、`lib/weblog_authoring/public_cache.rb`（`PublicCache#refresh`）、`lib/weblog_authoring/draft_publisher.rb`（`run`）、`lib/weblog_authoring/draft_administration.rb`（`list`、`article_row`）、`lib/weblog_authoring/draft_store.rb`（`administration_page`）、`lib/weblog_authoring/draft_runtime.rb`（dispatch の `retry_now: true`）、`lib/weblog_authoring/lambda_api.rb`・`development_app.rb`（`/publications/:version/run` の `retry_now: true`）、`frontend/authoring/DraftAdministration.tsx`（`needsAttention`、`retry`）、`infra/production/draft_worker.tf`（定期修復の `rate(1 hour)`）
- 同期コミットは、そのコミットで検証を実行し、対応表と前提がコードを正しく表していることを確かめてから進める。検証を実行しただけ、または結果が基準値と同じだっただけでは進めない。
