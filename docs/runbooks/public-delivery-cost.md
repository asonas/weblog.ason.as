# 公開配信の費用を計測する

全公開ページを最新の表示releaseで配信するため、まず12記事の動的配信と保存HTMLの配信を同じ計測で比較する。
追加配信費用と追加計測費用の合計は月$3程度を判断基準とする。これは課金の強制上限ではない。
CloudFront invalidation、追加のカスタムメトリクス、常時監視ダッシュボードは追加しない。

## 取得量と費用

- 既存CloudFrontログは全distributionが対象。`representative_article_logs` を再利用する。
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

一次資料:
- https://docs.aws.amazon.com/aurora-dsql/latest/userguide/cloudwatch-monitoring.html
- https://docs.aws.amazon.com/cur/latest/userguide/dataexports-create.html
- https://aws.amazon.com/cloudwatch/pricing/
