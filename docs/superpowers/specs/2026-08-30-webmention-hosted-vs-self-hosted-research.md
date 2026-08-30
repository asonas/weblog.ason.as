# Webmentionのホスト型サービスと自前実装の調査

## 調査対象

weblog.ason.as で、受信・表示・モデレーションを第1段階、送信を第2段階として導入する前提で、ホスト型サービスと自前実装の責任境界を比較する。

ホスト型サービスは、公式ドキュメントと公開実装から現行仕様を確認できた Webmention.io を具体例とする。送信専用サービスは受信方式の代替ではないため、必要な箇所だけ補足する。

## 先に分かったこと

- Webmention.io が外出しできるのは、Webmention の受信、source の検証、Microformats の抽出・正規化、保存、取得APIである。公式機能一覧に送信機能はない。[Webmention.io公式README](https://github.com/aaronpk/webmention.io#features)
- したがって双方向対応の選択肢は、実質的に「Webmention.ioで受信し、送信は別に実装する」か「送受信とも自前実装する」の2つになる。
- Webmention.ioのAPIを公開画面から直接読むだけでは、掲載前モデレーション、障害時の取りこぼし回復、外部サービス停止時の表示継続を満たせない。ホスト型を採用しても、取得結果を自サイトの専用テーブルへ同期し、掲載判断と公開表示の正本を自サイト側に置く必要がある。
- 最短の受信開始はWebmention.ioが有利である。標準適合の責任、検証履歴、更新・削除追従、データ保持を一つの境界で制御するなら自前実装が有利である。

この調査だけでは方式を確定しない。後続の「Webmentionの責任境界と配置を決める」で、上記のどちらを採るか決められる材料を揃える。

## 標準が要求する責任

### 受信側

受信endpointは `source` と `target` を受け取り、URLの妥当性、同一URLでないこと、`target` が自サイトのURLであることを確認する。受信内容を利用または表示する場合は `source` を自ら取得し、redirectを追従したうえで、`target` と一致するリンクが実在することを検証しなければならない。[W3C Webmention 3.2 Receiving Webmentions](https://www.w3.org/TR/webmention/#receiving-webmentions)

同じ `source` と `target` の再通知は更新として扱う。再取得時にリンクが消えているか、source が `404` または `410` なら、保存済みの言及を削除相当に更新する。[W3C Webmention 3.2.4 Verification](https://www.w3.org/TR/webmention/#webmention-verification)

仕様は非同期検証を推奨している。status URLを返す場合は `201 Created`、返さない場合は `202 Accepted`、同期完了なら `200 OK` を使える。[W3C Webmention 3.2.3 Request Verification](https://www.w3.org/TR/webmention/#request-verification)

任意のsource URLを取得するため、redirect回数、取得時間、取得byte数の制限が必要である。表示する外部コンテンツにはXSS対策が必要で、モデレーションと定期的な再検証も仕様上の対策として挙げられている。[W3C Webmention 4 Security Considerations](https://www.w3.org/TR/webmention/#security-considerations)

### 送信側

送信側はtargetを取得してredirectを追従し、HTTP `Link` header、HTMLの `link`、HTMLの `a` の順でendpointを発見する。相対URLを解決し、query stringを保持し、`application/x-www-form-urlencoded` の `source` と `target` をPOSTする。すべての `2xx` 応答を成功として扱う。[W3C Webmention 3.1 Sending Webmentions](https://www.w3.org/TR/webmention/#sending-webmentions)

記事更新時は、新規リンクだけでなく削除された過去のtargetにも再送し、endpointを再発見する。記事削除時もsourceを `410 Gone` またはtombstoneとして取得可能にしたうえで、過去のtargetへ再送する。[W3C Webmention 3.1.5 Sending Webmentions for Updated Posts](https://www.w3.org/TR/webmention/#sending-webmentions-for-updated-posts)

受信と送信は別の適合クラスである。仕様文書は適合確認用の [webmention.rocks](https://webmention.rocks/) を案内している。[W3C Webmention 2 Conformance](https://www.w3.org/TR/webmention/#conformance)

## Webmention.ioへ受信を委譲する場合

### 委譲できること

共通HTMLにアカウントのendpointを `rel="webmention"` として追加すると、Webmention.ioが受信を開始する。静的サイトや、本サイトのように全記事が共通SPA shellを返すサイトでも、endpointの広告自体は一箇所で済む。[Webmention.io公式トップ](https://webmention.io/)

Webmention.ioは非同期処理を行い、受信時にstatus URLを返す。公開実装ではtarget domainが登録siteに属するかを確認し、同じsource-targetの30秒以内の再送をrate limitしている。[Webmention.io受信controller](https://github.com/aaronpk/webmention.io/blob/main/controllers/webmention.rb)

取得APIは次を提供する。[Webmention.io API](https://github.com/aaronpk/webmention.io#api)

- 特定target、複数target、domain全体、account全体の言及取得
- JF2形式のauthor、source URL、公開日時、受信日時、ID、抽出content
- `in-reply-to`、`like-of`、`repost-of`、`bookmark-of`、`mention-of`、`rsvp` による絞り込み
- page/per-pageによるページングと、`since`/`since_id`による増分取得
- browserから取得できるCORS対応の公開target API

Webhookの再送機能はないが、同じデータをAPIから再取得できると公式FAQに記載されている。したがって通知だけに依存せず、`since_id` と定期的な照合を使うpull同期なら欠落回復を設計できる。[Webmention.io FAQ](https://github.com/aaronpk/webmention.io#faq)

### 自サイトに残る責任

Webmention.ioの公開target APIをReactから直接表示する構成は採用できない。今回の要件では、少なくとも次を自サイトに残す。

- Webmention.io APIからの増分同期と定期的な全体照合
- 専用テーブルへの保存と、同期cursorの永続化
- 技術検証結果と分離した、確認待ち・承認・拒否・削除の掲載状態
- 承認済みデータだけを返す公開APIと、安全化した表示
- 同期失敗の再試行、観測、外部停止中も既存表示を継続する振る舞い
- 第2段階の送信、更新・削除時の再送、delivery状態と再試行

Webmention.ioは受信データを自サービス側に保存し、抽出・正規化したJF2を返す。公式APIからraw response、検証履歴、保持期間を取得できることは確認できなかった。自サイトへの同期後も、受信時点の完全な監査情報まで所有できるとは扱わない。

### サービス継続性、費用、データ境界

公開実装はBSD Licenseであり、APIから全domain/accountをページング取得できるため、正規化済みデータの退避と将来の移行には足場がある。[Webmention.io LICENSE](https://github.com/aaronpk/webmention.io/blob/main/LICENSE.txt) [Webmention.io API](https://github.com/aaronpk/webmention.io#api)

一方、公式トップとREADMEからは、SLA、保持期間、利用上限、料金表、包括的なprivacy policy、raw検証データのexport手段を確認できなかった。これは無償または無制限であることを意味しない。採用判断では、保証のない外部依存として扱う。

公開リポジトリはarchivedではなく、2025-04-15に最終code pushがある。ただし、公開ソースがあることと hosted service の継続保証は別である。[Webmention.io GitHub repository](https://github.com/aaronpk/webmention.io)

公開されたself-host手順はRuby/Rack、MySQL、Redis、Muninを前提としており、現在のweblog.ason.asのLambda/DSQL構成へそのまま移植できるものではない。サービス停止時の現実的な移行先は、この実装を急遽運用することではなく、保存済みの自サイト正本を維持しつつ自前receiverへendpointを切り替えることである。[Webmention.io Development](https://github.com/aaronpk/webmention.io#development)

## 自前実装する場合

### 既存構成との適合

現在のCloudFrontは `/api/*` をAPI Gatewayへ転送し、POSTを許可し、cacheを無効化している。公開の `POST /api/webmentions` を追加する配信経路は既存構成内に置ける。[infra/production/hosting.tf](../../../infra/production/hosting.tf) [infra/production/api_gateway.tf](../../../infra/production/api_gateway.tf)

authoring Lambdaのtimeoutは15秒である。任意sourceの取得と検証をリクエスト中に完了させず、受信は入力とtarget所有を確認してqueueへ積み、workerが取得・検証する境界が適する。[infra/production/lambda.tf](../../../infra/production/lambda.tf)

現在の `inbox_items` は一定期間後の期限切れと「素材を採用して消費する」ライフサイクルを持ち、source/kindもCHECK制約で固定されている。更新・削除を長期追跡し、掲載判断を保持するWebmentionの正本には使わず、専用テーブルを設ける必要がある。[lib/weblog_authoring/dsql_bootstrap.rb](../../../lib/weblog_authoring/dsql_bootstrap.rb)

公開記事は共通HTMLをCloudFront/S3から返し、Reactが `/api/routes/{route}` から本文を取得する。endpoint広告は共通HTMLに置けるが、言及表示は承認済みmentionを記事APIへ含めるか、専用公開APIから取得する必要がある。[index.html](../../../index.html) [frontend/authoring/main.tsx](../../../frontend/authoring/main.tsx)

### 新たに負う運用責任

- SSRFを含む任意URL取得対策、redirect・timeout・byte上限、DNS/IP再評価
- source-targetの冪等性、非同期queue、再試行、dead-letter処理
- source再取得、完全一致リンク検証、更新・削除の反映、定期再検証
- 外部由来のauthor、photo、text、HTMLの安全化
- endpoint discovery、過去target集合、送信outbox、再送とdelivery観測
- receiverとsenderそれぞれの適合試験

既存AWS構成へ統合できるため、外部サービスへのデータ複製と継続性依存は避けられる。その代わり、実装費と保守費は受信件数よりも、セキュリティ境界、再試行、監視、仕様適合を維持する人的コストが支配的になる。AWSの増分利用料は、queue、Lambda実行、DSQL、ログ、外向き通信の実測負荷が決まるまで算定できない。

## 比較

| 観点 | Webmention.io受信 + 自前同期・送信 | 送受信とも自前 |
| --- | --- | --- |
| 第1段階の開始 | endpoint追加と同期で始められ、受信プロトコル実装を省ける | receiver、queue、fetch安全性、検証、永続化が必要 |
| 標準適合 | receiver中核はサービス依存。自サイトは同期・掲載、sender適合を担う | receiverとsenderの全責任を自サイトが担う |
| モデレーション | 自サイトDBへ同期すれば要件を満たせる。API直表示では満たせない | 検証結果と掲載状態を同じモデルで分離できる |
| データ所有 | 正規化済みデータは退避可能。raw取得・検証履歴・保持条件は未確認 | raw、検証、掲載、delivery履歴の保持方針を制御できる |
| 更新・削除 | サービス側の再検証結果を同期する境界と照合運用が必要 | 通知時と定期再検証を一つの状態機械で扱える |
| 送信 | 別の自前実装または送信サービスが必須 | 自前outboxとsenderが必要 |
| 障害時 | API停止中も同期済み表示は継続可能。新規受信・同期は遅延 | 自サイトのqueue/worker障害として観測・復旧できる |
| 継続性 | hosted serviceの保証は公式資料から確認できない。OSS/APIは移行の足場 | 外部サービス停止の影響はないが、自ら保守を継続する |
| 費用 | 公開料金・SLAを確認できず予測不能。同期・senderの自前費用も残る | AWS従量費と、セキュリティ・適合・運用の実装保守費を負う |

## 後続判断に渡す選択肢

### 選択肢A: Webmention.ioを受信アダプターとして使う

Webmention.ioを最終的な正本や公開APIにはせず、受信・検証・正規化を担う交換可能なアダプターとして扱う。自サイトは専用テーブルへpull同期し、モデレーション、公開、送信を所有する。

第1段階を早く検証できる一方、最終構成は外部receiver、自前同期、自前senderの三境界になる。仕様適合より早期の利用価値検証を優先するときに適する。

### 選択肢B: 最初からreceiverを自前実装する

公開endpointは速やかに受付だけを行い、SQS workerが安全にsourceを取得・検証し、専用DSQLテーブルを更新する。モデレーション、公開表示、sender outboxまで同じ正本を使う。

第1段階の実装範囲は広がるが、標準適合、更新・削除、監査、障害回復を一つの責任境界で設計できる。今回の地図が求める中核適合と長期運用を最初から完了条件に置くときに適する。

### 方式決定で答えるべき一点

「第1段階で、外部receiverから自サイト正本への同期という恒久的な境界を受け入れて受信開始を早めるか。それとも、その境界を増やさずreceiverの安全な実装と運用を先に負うか」を決めればよい。

Webmention.ioを公開画面から直接利用する案と、既存 `inbox_items` をWebmentionの正本に流用する案は、合意済みのモデレーション・更新削除追従・データ保全に適合しないため、後続候補から外せる。
