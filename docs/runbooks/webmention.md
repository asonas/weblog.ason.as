# Webmention監視runbook

このrunbookは、Webmentionの受信、検証、静的公開、送信、cleanupのAlarm対応とMatrix通知経路を扱う。

通知は既存のSNS topic `weblog-inbox-sync-alerts-production` と `weblog-matrix-notifier-production` を共有する。
InboxのAlarmとは別に `webmention_alerting_enabled` で有効化するため、Inbox通知を同時に有効化する必要はない。
`ALARM` は対応開始、`OK` は復旧を表す。

## 通知を有効にする

Matrix bot、room、Secrets Manager、SNS subscriptionが設定済みであることを確認する。
secret値は表示しない。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws lambda get-function-configuration \
  --region ap-northeast-1 \
  --function-name weblog-matrix-notifier-production \
  --query '{State:State,LastUpdateStatus:LastUpdateStatus,SecretId:Environment.Variables.MATRIX_SECRET_ID}'
```

保存済みplanを作成し、`webmention_alerting_enabled` だけを有効にする。

```sh
export TF_VAR_webmention_receiver_enabled=true
export TF_VAR_webmention_verification_enabled=true
export TF_VAR_webmention_alerting_enabled=true

mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production init -input=false -lockfile=readonly
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production plan -input=false -out=webmention-alerting.tfplan
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production show webmention-alerting.tfplan
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production apply -input=false webmention-alerting.tfplan
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production plan -input=false

unset TF_VAR_webmention_receiver_enabled TF_VAR_webmention_verification_enabled TF_VAR_webmention_alerting_enabled
```

apply後、SNS topicへテスト用Alarmを1件publishし、Matrix roomへの到達を確認する。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws sns publish \
  --region ap-northeast-1 \
  --topic-arn arn:aws:sns:ap-northeast-1:282782318939:weblog-inbox-sync-alerts-production \
  --message '{"AlarmName":"weblog-webmention-test-production","AlarmDescription":"Notification path test","NewStateValue":"ALARM","NewStateReason":"Manual runbook verification"}'
```

## Dead letters

`dead-letters` は検証またはdelivery、`publish-dead-letters` は静的公開が規定回数失敗したことを表す。
対象Lambdaの同時刻のログを先に確認し、原因を修正してから管理画面のDLQ再投入を1回だけ実行する。
原因未解決のまま再投入しない。

## Queue backlog

`queue-age` または `queue-depth` Alarmでは、通常queue、DLQ、event source mapping、workerまたはpublisherのLambda Errorsを確認する。
event sourceを手動で作り直さず、Terraform stateとの差分とLambdaの直近エラーを修正する。

### Publisher初回有効化前のoutbox集約

publisherを停止したまま、DSQLのpending outboxを記事単位に監査する。
この操作はSQSメッセージを受信せず、DBも変更しない。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  bundle exec bin/compact-webmention-outbox \
  --host zjuauvwetzvab4i3bdfd47e3yu.dsql.ap-northeast-1.on.aws
```

dry-runの`pages`が想定した記事数、`retained`が`pages`と同数であることを確認する。
適用時は同じmain SHAから`--apply`を付けて実行する。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  bundle exec bin/compact-webmention-outbox \
  --host zjuauvwetzvab4i3bdfd47e3yu.dsql.ap-northeast-1.on.aws \
  --apply
```

適用後にdry-runを再実行し、pendingが記事ごとに1件であることを確認する。
旧outboxは削除せず`superseded`として保持するため、監査と再構成が可能である。
旧SQSメッセージは`pending`ではないoutboxを参照するため、publisher有効化後は公開処理を行わずに完了する。
SQS queueのpurgeは回復不能であり、この手順では実行しない。

publisherを有効にするときもsenderは無効のままにする。
EventBridgeによる最初の実行後、pending件数、S3更新、CloudFront invalidation、Lambda Errorsを確認する。

## Lambda errors

Alarm名の `receiver`、`worker`、`publisher`、`cleanup` から対象Lambdaを特定する。
CloudWatch Logsで同時刻の構造化結果と例外を確認する。
DSQL、SQS、S3、CloudFront、外部HTTPのうち、対象Lambdaが所有する境界だけを調べる。

## Receiver throttles

`receiver-throttles` はreserved concurrencyに達したことを表す。
API Gatewayのリクエスト数、receiver受付・拒否件数、queue滞留、費用を確認する。
正当な通知が継続的に拒否された実測がない限り、reserved concurrencyやroute throttleを引き上げない。

## Matrix notification failures

Matrixに届かない場合は、`weblog-matrix-notifier-production` のLambda Errorsと `/weblog/lambda/matrix-notifier-production` を確認する。
HTTP 401ではbot token、403ではroom参加と送信権限、404ではhomeserver URLとroom IDを確認する。
設定修正後はSNS topicへのテスト通知を再実行する。
