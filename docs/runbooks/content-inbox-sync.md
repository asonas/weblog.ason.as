# コンテンツインボックス同期runbook

このrunbookは、外部ソースのscheduled同期、手動同期、Email通知、Matrix通知の復旧手順を扱う。

通知にはCloudWatch Alarm名、状態、理由、このrunbookの該当節が含まれる。
`ALARM` は対応開始、`OK` は復旧を表す。
同じAlarmが障害中に繰り返し通知されることはなく、正常状態へ戻った時点で復旧通知が1回送られる。

## 通知を有効にする

通知は初期状態では無効である。
Matrix botとEmail購読を設定してから有効にする。

1. 自宅のMatrix homeserverに通知専用botアカウントと非公開roomを作り、botをroomへ参加させる。
2. homeserver URL、room ID、bot access tokenを次のコマンドでSecrets Managerへ保存する。

```sh
read -r MATRIX_HOMESERVER_URL
read -r MATRIX_ROOM_ID
read -r -s MATRIX_ACCESS_TOKEN
export MATRIX_HOMESERVER_URL MATRIX_ROOM_ID MATRIX_ACCESS_TOKEN
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bin/configure-production-matrix
unset MATRIX_HOMESERVER_URL MATRIX_ROOM_ID MATRIX_ACCESS_TOKEN
```

3. 購読先メールアドレスを標準入力から読み取り、Terraform用の環境変数を設定する。

```sh
read -r TF_VAR_inbox_alert_email
export TF_VAR_inbox_alert_email
export TF_VAR_inbox_alerting_enabled=true
```

4. `infra/production`を初期化し、保存したplanの全resource summaryを確認してから、そのplanだけを適用する。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production init -input=false -lockfile=readonly
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production plan -input=false -out=inbox-alerting.tfplan
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production show inbox-alerting.tfplan
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production apply -input=false inbox-alerting.tfplan
```

5. 適用後に新しいplanを作り、意図しない差分が残っていないことを確認する。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  terraform -chdir=infra/production plan -input=false
unset TF_VAR_inbox_alert_email TF_VAR_inbox_alerting_enabled
```

6. SNSから届く確認メールのリンクを開き、購読を確定する。

通知経路はSNS topicへテスト用Alarm本文をpublishして確認する。
次のコマンドを実行すると、EmailとMatrixの両方へ同じテスト通知が届く。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws sns publish \
  --topic-arn arn:aws:sns:ap-northeast-1:282782318939:weblog-inbox-sync-alerts-production \
  --message '{"AlarmName":"weblog-inbox-test-production","AlarmDescription":"Notification path test","NewStateValue":"ALARM","NewStateReason":"Manual runbook verification"}'
```

## 最初に確認する情報

Alarm名から対象ソースと障害分類を確認する。
次にCloudWatch Logsの `/weblog/lambda/inbox-sync-production` から、通知時刻付近の `inbox_sync_source_result` を探す。
ログの `run_id` を使い、ログイン済みブラウザから `/api/inbox/sync/<run_id>` を取得すると、その実行に含まれるソース別結果を確認できる。

構造化ログには本文、token、認可code、外部APIのレスポンス本文を記録しない。
ログは14日後に削除される。

## Authentication and permissions

`immediate-failure` Alarmは、認証失効、権限不足、永続化失敗、分類できない例外を検出する。

Blueskyの `authentication` では、エディタからBluesky接続状態を確認する。
`reauthorization_required` なら、Bluesky OAuthを再接続してから更新対象をBlueskyにして手動同期する。

Raindropの `authentication` では、Secrets Managerの `weblog-authoring-production/inbox-sources` にあるtokenを更新する。
token値をCloudWatch Logs、Issue、コマンドライン引数へ出さない。

`persistence` では、Aurora DSQLの状態とInbox Sync Lambdaの `dsql:DbConnect` 権限を確認する。
原因を修正したら、失敗したソースだけをエディタから手動同期する。

手動同期が成功し、対象のAlarmが `OK` へ戻り、MatrixとEmailへ復旧通知が届けば復旧完了である。

## External API temporary failures

`retryable-failure` Alarmは、同じソースで `rate_limit`、`upstream`、`timeout`、`network` のいずれかが3回連続した場合に発報する。

外部サービスのstatusと直近3回の `inbox_sync_source_result` を確認する。
rate limit中は手動同期を繰り返さず、制限解除後に対象ソースを1回だけ手動同期する。

手動同期が成功し、対象のAlarmが `OK` へ戻り、MatrixとEmailへ復旧通知が届けば復旧完了である。

## Missing source success

`success-missing` Alarmは、BlueskyまたはRaindropの成功が3時間記録されなかった場合に発報する。

同じ時刻に `schedule-missing` または `lambda-errors` が発報していれば、先にその節を確認する。
scheduled実行が動いている場合は、対象ソースの直近結果と認証状態を確認する。

原因を修正して対象ソースを手動同期する。
成功メトリクスが記録され、Alarmが `OK` へ戻れば復旧完了である。

## Scheduled invocation

`schedule-missing` AlarmはEventBridgeの起動が3時間記録されない場合、`schedule-failed` AlarmはEventBridgeがLambdaを起動できない場合に発報する。

EventBridge rule `weblog-inbox-sync-production` が有効であり、targetとLambda permissionがTerraformのstateどおり存在することを確認する。
ruleやpermissionをコンソールで作り直さず、Terraformとの差分を修正し、保存したplanをmairu経由でローカル適用する。

次のscheduled実行または対象ソースの手動同期が成功し、Alarmが `OK` へ戻れば復旧完了である。

## Lambda errors

`lambda-errors` Alarmは、ソース別結果を記録できないLambda例外を検出する。

CloudWatch Logsで同じ時刻の例外を確認する。
DSQL接続、Secrets Manager取得、Bluesky OAuth Lambda呼び出し、Lambda imageの更新状態を順に確認する。

原因を修正して対象ソースを手動同期する。
実行が成功し、Alarmが `OK` へ戻れば復旧完了である。

## Matrix notification failures

Emailには届くがMatrixへ届かない場合は、`weblog-matrix-notifier-production` のLambda Errorsと `/weblog/lambda/matrix-notifier-production` を確認する。

HTTP 401ではbot access tokenを更新する。
HTTP 403ではbotがroomへ参加していることと、roomへメッセージを送信できる権限を確認する。
HTTP 404ではhomeserver URLとroom IDを確認する。

設定を更新したら、SNS topicへテスト通知をpublishする。
同じSNS message IDはMatrix transaction IDになるため、SNSから同じレコードが再配信されても同じメッセージを重複作成しない。
