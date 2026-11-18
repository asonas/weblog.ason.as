# 公開配信の費用を計測する

全公開ページを最新の表示releaseで配信するため、まず12記事の動的配信と保存HTMLの配信を同じ計測で比較する。
追加配信費用と追加計測費用の合計は月$3程度を判断基準とする。これは課金の強制上限ではない。
調査によるCloudFront invalidation、追加のカスタムメトリクス、常時監視ダッシュボードは追加しない。
通常の手動公開に限るキャッシュ更新は、下記の有効化手順に従う。一括再生成・移行・デプロイには連動させない。

## 公開時のキャッシュ更新を有効にする

実装は `PUBLIC_CACHE_DISTRIBUTION_ID` が設定されている場合だけ有効になる。Terraformの希望設定 `public_cache_enabled` はtrue。初回のapplyは新コードとスキーマのdeployment成功後に行う。無効時は公開HTMLの共有TTL180秒を維持し、パージ要求を作成しない。

1. 通常のdeployment経路で、DBの `article_cache_requests` テーブル、API・公開ワーカーの新コードを先に配備する。`bin/bootstrap-dsql` がテーブル作成と既存DBロールへの権限付与を行う。既存記事を再公開しない。
2. `public_cache_distribution_id` が本サイトのdistributionに一致することを確認する。公開ワーカーにはそのdistributionだけのCreateInvalidation/GetInvalidation、APIには使用数集計の読み取りと専用S3オブジェクトの読み書きを設定する。
3. 本番適用の承認範囲で、既存の機能フラグ・計測期限を維持したfresh planを保存し、`public_cache_enabled=true` と必要な権限・最大TTLの変更だけを確認して、そのplanをapplyする。再planで意図しない差分がないことを確認する。
4. 明示的に公開する少数の記事で、公開版切替後にそのURLの2パスだけが発行されること、同じ公開操作の再試行で追加batchが作られないこと、完了後の新しいHTMLとヘッダーを確認する。日本語と空白を含む記事では標準URLと旧percent encoding表記の両方を確認する。全ページ巡回・全体パージはしない。

有効時は共有TTL86400秒（24時間）、SWR300秒、障害時猶予86400秒。初回公開と内容を変えた再公開では、公開版が有効になった後に当該記事routeの末尾スラッシュ有無の2パス、改名は旧・新routeの最大4パスを対象にする。Mentioned by days、関連ハブ、RSS、参照元記事を連鎖してパージしない。tildeや長すぎるパスは送信せず、記事一覧の公開キャッシュ欄に理由を残し、TTL更新に任せる。CloudFrontの最大TTLは障害時猶予を含む172800秒にする。

パージの対象は、認証された手動公開の受け付け時に公開版と一緒に保存する。公開版が有効になってから既存の公開ジョブが実行し、AWSの完了待ちは定期修復または管理画面の再試行で確認する。記事の公開完了とキャッシュ更新完了は別の状態で、処理中は公開済みでも古いHTMLが見えることがある。AWSの一時失敗は同じCallerReferenceで再試行する。

管理画面の記事一覧は保存済みの月次使用数を表示する。「AWSの使用数を確認」で、当月UTCのbatchとパス数を照合する。取得済みbatchの件数はS3の `operations/public-cache-usage.json` に保存し、同月の確認済み実績を再利用する。削除済みやtenant配信の未観測分があるため、アカウント全体の無料枠残数は不明として扱う。本サイトと確認できた通常distributionの使用数を、無料枠1,000パスと合わせて表示する。画面表示だけではAWSの全履歴を再取得しない。

切り戻す場合は `public_cache_enabled=false` に戻す。同フラグが長いTTLと新しいパージ要求の作成を同時に止める。ただし配信済みの長いTTLはその期間残るため、緊急の取り下げを即時保証するものではない。残ったジョブの処理や緊急の対象パージは、件数と公開状態を確認して判断する。

設計と試算は [公開キャッシュの設計](../public-cache-policy-proposal.md) を参照。

## 取得量と費用

- 既存CloudFrontログは全distributionが対象。`representative_article_logs` を再利用する。
- Botの調査にはUser-Agentと接続元IPも記録する。公開閲覧と管理・APIを分け、Botを名乗るアクセス、同じ接続元の頻度、キャッシュMissを集計する。User-Agentだけで正規Botと確定せず、必要なら公式IP範囲と照合する。
- アクセスログは非公開S3で30日保持する。IPは集計結果へ掲載せず、Cookie・Referer・クエリ文字列は記録しない。2026-10-10の項目追加後は、まず3日分を観測して追加ログ量とBotの割合を確認する。
- `public/robots.txt` はbuild成果物と通常のdeploymentに含め、S3から配信する。公開記事の巡回を許可し、管理・API・認証への巡回を避けてもらう。例外としてMCPのサービス情報 `GET /api/agents` だけは `/llms.txt` から案内するので許可する。robots.txtはアクセス制御ではなく、従わないBotの拒否は観測結果に基づいて別途判断する。
- `operation_metrics` はLambda呼び出しの10%だけに1行出す。リクエストIDのハッシュで採取する。
- `operation_metrics_until` はUnix秒。有効期限は一度の観測につき最大7日先とし、延長は観測結果を見て判断する。
  未設定・期限切れなら追加ログを出さない。デプロイで期限を自動更新しない。
- SQL本文・引数・記事名・本文・Cookie・例外メッセージを出力しない。SQLごとのログも出さない。
- 請求明細はCUR 2.0の日次・リソース別CSV/GZIPを専用の非公開S3へ出力する。
  同月分は上書き、90日で削除。日々Cost Explorerを呼ばない。Athenaは使用しない。
- 取得は週1回を基本とし、同じ期間の再分析では取得済みファイルを使う。
  調査のための繰り返しGET、全ページ巡回、キャッシュ無効化は行わない。

2026-10-02に既存の `AWS/Lambda Invocations` を1回ずつ取得した。
UTC 09-25〜10-01の全Lambdaの最大値は22,744回/日、authoringの最大値は22,231回/日。
最大値が30日継続し、全Lambdaが対象、10%採取、1行1KiBと仮定すると追加ログは約0.065GiB/月。
東京のStandardログ取り込み単価はPricing APIで$0.76/GBを確認した
（SKU `CWB2GTZJXNX3TA6H`、2026-09-01適用）。取り込みだけの概算は約$0.05/月。
保存・取得・CURのS3書き込み・Lambda処理時間は別途加算する。無料枠を前提にしない。
この試算はトラフィック増に対する上限保証ではない。

追加計測全体の見込みが月$0.20を超えるなら、採取率・取得頻度・保持を先に見直す。
月$3の枠を計測だけで使わない。保存量はログ行の実バイト数とCUR出力の実サイズで確認する。
既存のauthoring/search-indexerロググループは無期限保持だったため、過去ログを削除する変更は含めない。
追加出力は期限で止まるが、そのログの保存は既存グループの保持設定に従う。

## ログの意味

2026-10-13の費用対策では、公開RSSの共有キャッシュを60分（`s-maxage=3600`）、ブラウザ側を5分に設定する。RSSの公開反映が遅れることは許容する。公開記事の共有TTLは180秒のままにする。
下書きの定期更新確認は60秒とし、入力の保存とフォーカス復帰時の確認は維持する。リンク関連ページは、存在確認と描画を同じ一覧取得で行い、見つからない場合はshellを取得しない。リンク元の専用索引は追加しない。

`workload` はpublic_html / public_api / authoring / publication / scheduled_maintenance、
およびinbox・webmention・draft workerの固定分類。
`delivery` はdynamic / stored / linked。dynamicの場合は `display_release` も記録する。
`code_revision` は実行イメージのcontent hashで、デプロイmanifestと照合する。

`sql_count` はアプリが呼び出したexec/exec_params/queryの回数で、失敗した試行も含む。
BEGIN/COMMIT/ROLLBACKなどのトランザクション制御と接続確立は含めない。
`sql_ms` はドライバ呼び出しの経過時間であり、DSQLのCPU時間・DPU・課金額ではない。
`db_retries` はRubyのpoolがブロックを再実行した回数。Workerは再試行を実装していないため0。
`duration_ms` はハンドラの時間で、Lambdaの課金時間・cold init全体とは異なる。
Lambdaの課金は既存REPORT行のBilled DurationかCURのリソース別使用量を使う。

CloudWatchのReadDPU/ComputeDPU/WriteDPU/TotalDPUはクラスタ全体の概算である。
SQL回数の割合でDPU課金を各用途へ配賦して「実額」と呼ばない。
時間帯別の用途・処理量と照合し、必要なら代表SELECTに限定してEXPLAIN ANALYZE VERBOSEを実行する。
これは実際にSQLを実行するため、全リクエストへの常設はしない。
ローカルの移行・実験スクリプトやOAuthなど、計測対象外の処理分は未帰属として残す。

## ローカル集計

`scripts/report-public-cost.py` はネットワークに接続しない。
`--operations` はAWS CLI `logs filter-log-events` のJSON、`--cur` はCSVまたはCSV.GZ。
期間はUTC、開始日を含み終了日を含まない。入力が途中で切れたログexportはエラーにする。
CURは同じmanifestに記載されたファイルだけを指定し、古いrevisionを混ぜない。
同一リクエスト・明細の重複取得は二重計上しない。
日次CURでは同じ `identity_line_item_id` が別の日にも現れるため、使用開始・終了日時を含めて重複を判定する。

```sh
mise exec -- python3 scripts/report-public-cost.py \
  --operations /private/tmp/weblog-cost/authoring.json \
  --operations /private/tmp/weblog-cost/draft-worker.json \
  --cur /private/tmp/weblog-cost/report.csv.gz \
  --start 2026-10-03 --end 2026-10-10
```

採取件数と採取率から推定した件数を分けて出力する。未観測日は$0と扱わない。
少数サンプルしかない用途は参考値とし、前後で曜日・閲覧量・編集・移行の条件を併記する。
CURには請求確定前の修正が入るため、取得日時・対象期間・manifestをローカルファイルと一緒に保存する。

## Markdown応答とキャッシュキー

記事とトップページは、`Accept: text/markdown` を含むリクエストにMarkdownを返す。
CloudFront Function `weblog-public-format-production` が `Accept` を `x-weblog-format: markdown` か `html` に正規化し、公開HTML用のキャッシュポリシーはこのヘッダーだけをキーに含める。
1つのURLのキャッシュは最大2種類で、`Accept` の値の違いではキーが増えない。
配信元は `x-weblog-format` だけで出し分ける。`Accept` を直接見る実装にすると、HTMLのキーにMarkdownが保存される。

閲覧者への `Vary: Accept, Accept-Encoding` は、CloudFrontのresponse headers policyが付ける。配信元が返す `Vary: Accept` は、CloudFrontを通ると閲覧者に届かない（2026-11-17に本番で観測）。

Markdownを止める時は `public_markdown_enabled=false` でapplyする。Functionは常に `html` を設定し、Markdown側のキーに残った応答は、参照されないままTTLで消える。

キャッシュキーに含めるヘッダーを変える時は、次の順で行う。順序を変えると、片方の形式がもう片方のキーに最大24時間保存される。

1. 新しいキーのキャッシュポリシーを別のリソースとして作り、それを読むFunctionの関連付けと一緒にdistributionを切り替えてapplyする。この時点のFunctionは、新しい形式を選ばない設定にしておく。既存のポリシーを書き換えると、Functionの関連付けより先にキーだけが変わる。
2. distributionが `Deployed` になってから、新しいヘッダーを読む版のアプリをデプロイする。mainへのpushで自動デプロイされるので、pushは手順1の後にする。先にデプロイすると、閲覧者がそのヘッダーを直接送って、別の形式のキーに応答を保存できる。
3. Functionで新しい形式を有効にしてapplyする。
4. 使わなくなったポリシーの定義を消してapplyする。手順1と同じapplyで消すと、distributionの更新より先に削除が実行され、`CachePolicyInUse` で失敗する。

- ポリシーが切り替わると、既存のキャッシュは新しいキーで取り直しになり、配信元へのリクエストが一時的に増える。invalidationは発行しない。
- `/feed.xml` と `/sitemap.xml` は常に `html` に正規化し、同じ内容を2つのキーに持たない。
- 記事の公開時のinvalidationはpath単位で、HTMLとMarkdownの両方が消える。[AWSのinvalidationの説明](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/invalidation-specifying-objects.html)
- CloudFront Functionは月200万回まで無料で、公開HTML用のポリシーを使うbehaviorの全リクエストで実行される。

## キャッシュされないリクエストの上限

CloudFrontにキャッシュが無いリクエストは、API GatewayとLambdaの料金が1件ごとにかかる。次の設定で量を抑える。料金の上限を保証する設定ではない。API Gatewayのスロットリングは、AWSの説明ではbest effortの目標値である。

- トップページと公開ページの404は、配信元が `s-maxage=60` を返し、同じURLへの繰り返しをCloudFrontが60秒受け止める。CloudFrontの `error_caching_min_ttl` は0のままにする。上げると、CachingDisabled以外のbehaviorの403と404すべてに同じ保持時間が付く。キャッシュしてよい404だけを、配信元のヘッダーで指定する。
- 公開ページのルート（`GET /`、`HEAD /`、`GET /{path+}`、`HEAD /{path+}`、`GET /search`）は、API Gatewayでルートごとに毎秒1件、バースト5件に制限する。値は `public_page_throttling_rate_limit` と `public_page_throttling_burst_limit` で変える。
- 認証なしで届くGETのルート（`GET /api/pages`、`/api/tags`、`/api/search`、`/health` など12ルート）は、ルートごとに毎秒5件、バースト20件に制限する。値は `public_api_throttling_rate_limit` と `public_api_throttling_burst_limit` で変える。作者の管理画面も同じルートを使うので、公開ページより緩くしている。

上限は閲覧者ごとではなくルートごとである。クローラーが存在しないURLを順に叩いて `GET /{path+}` の上限を使い切っている間は、キャッシュに無い記事を開いた閲覧者にも429が返る。記事の `stale-if-error` は429には働かない。キャッシュ済みのページは影響を受けない。読み取りAPIの上限を使い切られている間は、作者の管理画面の一覧や検索にも429が返る。

次のルートは、他のルートの枠を使い切られても届くよう、制限を掛けていない。

- `GET /api/auth/session`、下書きと書き込みのAPI、`GET /draft-editor`、`GET /authoring/{path+}`: 作者がログイン状態を保ち、編集を始めて保存できるようにする。エディタと管理画面は、`GET /{path+}` に落ちないよう個別のルートにしている
- `GET /api/embed`: 公開時と記事の表示時に、埋め込みの数だけ並列に呼ばれる。429になったカードは再試行されないので、制限すると埋め込みの多い記事でカードが欠ける
- `GET /feed.xml`、`GET /sitemap.xml`: 1時間キャッシュされ、期限切れの再取得が429になるとフィードリーダーやクローラーに届かなくなる。これらも個別のルートにしている

公開ページの1ルートを上限いっぱいまで30日間叩かれ続けた時の配信元の料金は、約259万件、約17ドルになる。制限を掛けた公開ページの5ルートすべてを使い切られると約84ドルになる。内訳は、API Gatewayが100万件あたり1.29ドル、Lambdaのリクエストが同0.20ドル、実行時間が512MB・0.75秒で同約5.00ドルである（東京リージョン、AWSの価格表の2026-11-12公開分）。0.75秒は、2026-11-17に存在しないURLへの応答2件をAPI Gatewayのアクセスログで測った値で、請求上の実行時間そのものではない。読み取りAPIは1ルートあたり約1,296万件で、API GatewayとLambdaのリクエスト料金だけで約19ドルになり、実行時間の料金が加わる。CloudFront、DSQLの読み取り、S3、アクセスログの料金は含まない。

429が増えていないかは、API Gatewayのアクセスログで `routeKey` と `status` を見る。

```sh
aws logs filter-log-events --log-group-name /aws/apigateway/weblog-authoring-production \
  --filter-pattern '{ $.status = 429 }' --start-time "$(($(date +%s) - 3600))000"
```

## 記事タイトル入りのOG画像

カバー画像の無い記事は、タイトルを描いた画像（1200×630のPNG）を `og:image` に使う。カバー画像のある記事は、そのカバー画像を使う。判定は `CoverImage.resolve` による。

- 画像は記事の公開時に、公開ワーカー（`weblog-search-indexer-production`）が1回だけ作って `assets/og/` に置く。リクエストのたびに画像を作る経路は無い。クローラーが画像のURLを叩いても、CloudFrontとS3の配信になるだけである。
- キーは `assets/og/<タイトルとテンプレートの版から作ったハッシュ>.png`。記事HTMLはタイトルからこのURLを組み立てるので、画像の有無をデータベースに持たない。タイトルを変えるとURLも変わる。フォントやレイアウトを変える時は `OgImage::TEMPLATE` を上げる。
- 生成は、記事の公開版が有効になった後に行う。失敗しても公開は止まらない。公開ワーカーのログに `Could not create the Open Graph image` が出て、その記事の `og:image` は404になる。
- 1回の公開で画像の生成を始めてから20秒を過ぎると、リンク先の記事の分を含めて、以降の工程（存在確認、描画、書き込み）を始めない。進行中の工程は最後まで行うので、公開ワーカーが画像に使う時間は20秒を数秒超える事がある。
- 生成されなかった画像は、同じ公開処理の再試行や毎時の修復では作られない。下の一括生成のコマンドで埋める。記事を取り込むコマンド（`bin/import-external-articles`）で公開した記事も同じである。
- フォントファイルを読めなかった時は、別のフォントで描かずに生成を失敗させる。
- トップページ用の画像は `assets/og/home-v1.png`。

公開済みの記事への適用と、生成に失敗した記事の穴埋めは、手元から次のコマンドで行う。既定は予行で、何も書かない。書き込みは `assets/og/` へのPutObjectだけで、invalidationは発行しない。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  bundle exec bin/backfill-og-images --host "$DSQL_HOST" --site-bucket weblog-asonas-site-production-282782318939 --home
```

出力の `to_write` が書き込む枚数である。確かめてから `--apply` を付けて実行する。手元のlibvipsは文字を描ける構成（Homebrewの `vips`）である必要がある。

`OgImage::TEMPLATE` を上げた時は、全記事の画像を作り直す事になる。先に予行で枚数を確かめる。記事HTMLの `og:image` は、CloudFrontのキャッシュの期限（最大24時間）で新しいURLに入れ替わる。

## 有効化と配信拡大

1. 計測コードを配備する。初期値の有効期限0ではログは追加されない。
2. Terraform init、期限付き保存planを作成して全変更を確認し、そのplanをapplyする。
   現在の `article_pieces_enabled=true`、Webmention receiver/verification=trueを維持する。
   新規CUR関連5リソースと計測環境変数以外の変更を混ぜない。
3. 再planが意図せず設定を戻さないこと、少数の実リクエストでログ分類と採取率を確認する。
4. CURの初回配送を確認する。AWSは開始まで最大24時間としている。
5. 計測費用と、同じ記事・操作条件での配信差を確認して、通常記事・日記へ対象を拡大する。
   続けてabout・トップ・残りの公開経路を確認する。管理・下書きは共有キャッシュに含めない。
6. 表示releaseを切り替えるだけで過去記事も更新されること、本文・OGP・改名・404・HEADを確認する。
   キャッシュTTL180秒を使い、全ページへのinvalidationや再公開はしない。
7. 追加費用が月$3を超える見込み、または表示・性能の悪化があれば拡大を止め、対象設定を戻す。
   保存HTMLと古いassetは移行中も残す。旧HTML生成の停止は別工程（#193）。

関連: GitHub #184（全体）、#189（代表記事）、#190〜#192（拡大）。

## 2026-10-02の設定

CUR `weblog-daily-cost` を作成し、サービスの状態はHEALTHY。
計測する8 Lambdaに10%採取と `operation_metrics_until=1791552600`
（2026-10-09 22:30 JST）を設定した。期限延長を伴わないTerraform操作でも、この値を明示して維持する。
CUR専用バケットの配送権限はAWSの検証に必要なバケット全体へのPutObjectとし、
配送元サービス・アカウント・export ARNの条件で制限する。

## 全公開記事への拡大と3日後の確認

`DYNAMIC_PUBLIC_ARTICLE_ROUTES=*` で、公開済み版を持つすべての記事・日記・aboutを最新の表示releaseで描画する。
未作成Wikiリンクの関連ページも同じreleaseを使い、180秒の共有キャッシュ対象にする。
トップ・検索は既存の `index.html` を使い、デプロイごとに最新のasset参照へ更新する。
トップの一覧を初期HTMLへ埋め込む変更はこの切替に含まない（#191）。
管理・認証・下書き・API・404のキャッシュ境界、旧HTML生成と保存HTMLは維持する。

切替後72時間を目安に、同じ期間幅の切替前ログと比較する。
2026-10-07に切り替えた場合、10月10日にログと到着済み請求データを一次確認する。
丸3日分のUTC請求期間は10月8〜10日で、10月11〜12日に反映状況を確認する。
請求が未反映の時間帯は0ドルにせず、ログの速報と請求ベースの結果を分ける。
この観測の停止期限は2026-10-12 22:30 JST（`operation_metrics_until=1791811800`）とし、
計測率10%を維持する。デプロイ・Terraform applyでは期限を自動延長しない。
実際の切替時刻、表示release、元の設定を切替記録に残し、日付は反映が遅れた場合に修正する。

切り戻しは `DYNAMIC_PUBLIC_ARTICLE_ROUTES` を次の元のリストへ戻す。
Terraformの `lambda.tf` と保存planを使い、他の機能フラグと観測期限を維持する。

```text
Monitor+,2026-09-26,2026-09-25,2026-09-24,Webmentionクラブ,2026-09-23,2026-09-22,2026-09-21,2026-09-19,2026-09-18,2026-09-17,2026-09-16
```

必要なら旧方式だけに戻すため空文字にする。旧HTML・assetは削除せず、invalidationは発行しない。
表示release自体の不具合は既存のrelease復帰手順を使い、通常TTLの残り最大3分程度を待つ。
追加配信・計測費用が月$3を超える見込み、または表示・応答の回帰があれば拡大を戻す。
全体移行後7日間は旧生成を残す。3日後の費用確認だけを根拠に旧生成を停止しない。

一次資料:
- https://docs.aws.amazon.com/aurora-dsql/latest/userguide/cloudwatch-monitoring.html
- https://docs.aws.amazon.com/cur/latest/userguide/dataexports-create.html
- https://aws.amazon.com/cloudwatch/pricing/
