# Piece・Inbox機能の本番リリース準備

2026-10-01の開発環境で、かけら編集、日記の引用、関連記事、トップページ、
原典と追加参考色のパレットを確認した。開発環境のDBは本番へコピーしない。
既存日記をかけらに変換するCLIは開発専用であり、本番の一括変換には使わない。

## push前に確認すること

`main`へのpushはValidate成功後の本番デプロイを自動起動する。
今回のテーブル改名はLambda更新より先に通常bootstrapを通せないため、
改名の準備ができるまではpushしない。最新の成功デプロイは
[216d7a4の実行](https://github.com/asonas/weblog.ason.as/actions/runs/36652719138)。
これは2026-10-01のActions読み取り結果であり、AWS側の現行設定確認とは別である。

1. `mairu login asonas-aws` で本番用の資格情報を更新する。
2. 本番DSQLのテーブル名を読み取り確認する。

   ```sh
   mairu exec --no-login --server asonas-aws 282782318939/weblog-authoring-production -- \
     mise exec -- ruby bin/rename-article-tables status \
     --host zjuauvwetzvab4i3bdfd47e3yu.dsql.ap-northeast-1.on.aws
   ```

   2026-10-01に本番で17組すべての旧テーブルが存在し、新テーブルが存在しないことを確認した。
   authoring用ロールではLambda設定の参照が拒否されたため、AdministratorAccessで読み取り確認した。
   APIはActive / Successful、DRAFT_CUTOVER_ENABLEDはtrue。
   AUTHORING_MAINTENANCEとARTICLE_PIECES_ENABLEDは未設定だった。
   権限不足なら読み取りに必要なロールを確認し、DDLを試して権限を推測しない。
3. 本番のcutover、Lambdaイメージdigest、設定フラグ、スケジュール、
   イベントソース、実行中処理と退避先を記録する。
4. [テーブル改名手順](article-table-rename.md)に従って停止・退避・改名・比較・復帰を行う。
   未改名なら、maintenance状態の新authoringイメージをdigest固定で先に配備する。
   maintenanceの解除は改名と利用元の更新を確認してから行う。
5. [Piece導入手順](article-pieces-inbox.md)に従い、作成フラグをfalseに保って
   API・Worker・Webを揃える。公開HTMLの旧asset参照も更新する。
6. 新規日記の保存・再読込・公開、Inbox取り込み、引用・関連記事・トップを確認する。
   Terraformのフラグ有効化はローカルでfresh planを保存・全差分確認・そのplanをapplyし、
   再planで差分を確認する。Webmention送信など既存の設定は維持する。
7. iOS/Androidの配布は別工程とし、実機確認・署名・配布先を確認する。

テーブル名が旧・新の両方存在する場合や退避比較が一致しない場合は、
通常デプロイを進めず改名手順の中断・復旧に従う。
署名付きローカルmain統合、push、Actions成功、本番機能有効化、実機配布を
別の完了状態として記録する。

## 本番の事前確認（2026-10-01 14:40 JST）

- cutoverは`open`、実行中operationは0件。停止後に再確認する。
- 17組すべて旧名のみ存在。APIのイメージdigestは
  `sha256:ddadc2b139c5c8806a0036bb2c0b9f003016e64eefad6cad1a13645392e62ba9`。
- Lambda 12個のイメージ・revision・同時実行設定と、イベントソース3個・
  EventBridgeルール7個をローカルの運用記録へ保存した。
- 対象DSQLのAWS Backup recovery point、東京リージョンのvault、
  名前にBackupを含むIAMロールはいずれも0件。別方式の退避有無は未確認。
- `rename-article-tables snapshot`は件数・ハッシュであり、復元用データではない。
  この記録だけで「バックアップ済み」としない。
- ローカルDocker daemonは起動していない。イメージビルド用workflowは
  `workflow_call`専用で、単独dispatchできない。先行maintenanceイメージの
  作成経路も通常push前に用意する必要がある。

### 停止と復帰の対象

| 種類 | 対象 | 現在値・復帰値 |
| --- | --- | --- |
| EventBridge | weblog-draft-worker-production | ENABLED |
| EventBridge | weblog-inbox-sync-production | ENABLED |
| EventBridge | weblog-rss-feed-production | ENABLED |
| EventBridge | weblog-webmention-cleanup-production | ENABLED |
| EventBridge | weblog-webmention-reverification-production | ENABLED |
| EventBridge | weblog-search-index-nightly-production | DISABLEDのまま |
| EventBridge | weblog-webmention-outbox-dispatch-production | DISABLEDのまま |
| SQS event source | ad3ddd08-e995-4582-9c98-53d6d52f780d（検証Worker） | Enabled |
| SQS event source | ceb03ccc-b98c-4f5e-b8f1-ef03a521fc4f（公開Worker） | Disabledのまま |
| SQS event source | 23732515-63bc-4914-a7fe-c54bd33e2613（検索） | Disabledのまま |

API、Draft Worker、Webmention受信・検証・公開・cleanup、performance Lambdaの
直接起動も止める。キューは削除せず、新規起動を抑止して実行中処理の終了を確認する。
APIと検索Lambdaの`WEBMENTION_SENDER_ENABLED=true`、公開Workerの同フラグfalseを
現行値として保持する。過去のcutover evidenceのfalseを現在値として上書きしない。

### 次の実行順序

1. AWS Backup用vault・IAMロールをTerraformで準備する。
   fresh planの全変更を確認してから適用する。保持期間と復元先の扱いを決める。
2. 対象DSQLのオンデマンドバックアップを作成し、完了を確認する。
   別DSQLクラスタへ復元し、読み取りでテーブルとデータを照合して復元経路を実証する。
   [AWSの手順](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/backup-aurora-dsql.html)
   では復元時に新クラスタが作成される。既存ホストへそのまま戻る復元ではないため、
   必要なIAM接続権限と接続先変更の手順も確認する。
3. 新SHAからauthoringイメージを作成し、digestを記録する。
4. cutoverをpausedにし、上記の起動元を停止して処理を排出する。
   maintenanceイメージと設定を先行配備し、APIの503を確認する。
5. 停止後の最新バックアップと比較snapshotを保存し、17テーブルを改名する。
   同期・cutoverテーブルを含めて停止前後の内容を照合する。
6. mainをpushして通常デプロイを実行する。maintenanceを保ち、全利用元と
   bootstrap完了を確認する。Piece作成フラグはまだfalseとする。
7. API・cutover・起動元を記録した状態へ戻し、公開・保存を確認する。
   Pieceフラグを別のfresh Terraform planで有効化して機能を検証する。

改名後、通常利用の再開前に戻す場合は`reverse`と比較snapshot照合を行い、
記録した旧イメージへ戻す。データ破損時は別クラスタへの復元と接続先切り替えが
必要になるため、復元リハーサル完了前に本番の停止・改名へ進まない。

## バックアップ基盤の適用準備

`infra/production/backup.tf`をvalidateし、本番をrefreshした全体planと
先行バックアップ基盤だけのplanを保存した。先行planは以下の3件追加のみで、
既存リソースの変更・削除は0件。

- vault: `weblog-article-migration-production`（force_destroy=false）
- IAM role: `WeblogArticleMigrationBackup`（AWS Backupサービスのみ引受け）
- inline policy: `DSQLMigrationBackup`

バックアップ対象は本番DSQLのARNに限定する。復元先は新クラスタになるため、
作成・復元権限は東京リージョンの同一アカウント内cluster/*へ許可する。
KMS操作は`kms:ViaService=dsql.ap-northeast-1.amazonaws.com`に限定する。
SQL接続権限やDB行の更新・削除権限は、このサービスロールに付与しない。
権限は[AWSのバックアップ用ポリシー](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForBackup.html)
と[復元用ポリシー](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSBackupServiceRolePolicyForRestores.html)
のDSQL関連部分を参照した。実際のバックアップ・復元成功はまだ未検証。

全体planはAPIルート9件追加、Lambda環境変数3件更新も含むため、改名前には適用しない。
先行適用ではvaultとrole policyをtargetに指定した保存planを使う。
これは移行準備の例外的な段階適用であり、完了後に必ず全体planを再取得する。
本番変数はreceiver=true、verification=true、publisher=false、sender=trueを維持する。

最初の先行applyは自動承認レビューにより拒否された。その後、ユーザーから
3件の作成と低コストのバックアップ・復元確認を明示承認された。
fresh init・plan・全差分確認後に保存planを適用し、3件追加・変更削除0件で完了した。
適用後の全体planは予定済みのAPIルート9件追加とLambda環境変数3件更新のみ。
これらのAPI側変更はまだ適用していない。

### バックアップ試行と権限修正

- BackupJobId: `8f203414-940d-4814-8386-1c31b4ecd2d4`
- 2026-10-01 15:05 JSTに単発・7日保持で開始し、15:06 JSTにFAILED。
- AWS Backupは状態確認時に`dsql:GetBackupJob`を
  `arn:aws:dsql:ap-northeast-1:282782318939:cluster/*`へ要求した。
  本番クラスタARNだけの許可では拒否され、復元ポイントは取得できなかった。
- `GetBackupJob`と`StopBackupJob`の範囲拡張は自動承認レビューで拒否された。
  `backup.tf`の修正は実際のエラーが出た読み取りの`GetBackupJob`だけに絞った。
  開始・停止権限は本番クラスタARN限定のままとする。
  その後、ユーザーから`GetBackupJob`だけの拡張を明示承認された。
  fresh init・保存planの確認後に1ポリシーだけ更新した。開始・停止権限は拡張していない。
  適用後の全体planは予定済みのAPIルート9件追加・Lambda設定3件更新のみ。
- 本番の54業務テーブル・26,544行の件数と全列SHA-256を読み取り記録した。
  DB行やLambda稼働設定、cutoverは変更していない。

### 復元リハーサル結果（2026-10-01）

- 再試行BackupJobId: `0029fe56-079c-4712-bbbd-081522bdac87`
- RecoveryPointArn: `arn:aws:backup:ap-northeast-1:282782318939:recovery-point:21f341ad-cbae-41ec-ab88-5d8aa87bcc9f`
- バックアップは15:21 JSTにCOMPLETED。サイズ11,843,843 bytes。
  7日保持で、削除予定は2026-10-08 15:17 JST。
- RestoreJobId: `59e677d4-9027-4a37-a81d-a1eca892436d`
- 東京の別クラスタ`izud3b3wyt56vgtzfj5lehtlsy`へ復元し、15:26 JSTにCOMPLETED。
  54テーブル・26,544行すべての件数と全列SHA-256が、本番の記録と一致した。
- 照合終了後に上記の確認用クラスタだけの削除保護を解除し、削除を要求した。
  本番クラスタの削除保護と接続先は維持し、バックアップも保持している。
  GetClusterがResourceNotFoundを返し、確認用クラスタの削除完了を確認した。
- 本番は稼働したままのリハーサルである。改名直前の停止後バックアップと
  同時点の照合は別途必要。17テーブルの改名・main push・本番デプロイは未実施。

`get-recovery-point-restore-metadata`の`cluster_id`と`backup_size_bytes`は
`start-restore-job`に渡すと入力検証で拒否された。復元入力には
`aws:backup:request-id`と`regionalConfig`だけを渡し、後者は東京1リージョン・
削除保護trueとした。metadata検証失敗でもidempotency tokenが使用済みになる。
metadataを直して新tokenを使う前に、当日のRestoreJobsが0件、本番以外の東京DSQL
クラスタが0件と読み取り確認した。実際に作成した復元クラスタは1件のみ。

### 費用の制約

定期スケジュール、リージョン間コピー、cold storage移行、Backup restore testing
planは作成しない。通常vaultの単発バックアップを7日で自動削除し、復元確認は1回。
確認用クラスタはユーザー承認済みの終了後削除まで行い、対象ARNを記録する。
本番クラスタと復元ポイントは、この確認用クラスタ削除の対象にしない。

2026-10-01に公式AWS Price List APIで確認した東京の単価は、通常vaultのwarm保存が
$0.12/GB月、warm復元が$0.024/GB。DSQL保存は$0.40/GB月、照合時の処理は
$0.00001/DPU。CloudWatchの本番保存量最大11,846,383 bytesを課金量と仮定すると、
7日保存と1回復元の従量部分は合計$0.001未満。最小課金・実際のバックアップ量・
照合DPU・税を含む確定請求額ではない。復元ジョブ完了時のBytesと確認用クラスタの
存続時間を記録し、想定外のサイズなら照合や追加ジョブを開始せず確認する。
料金の根拠は[AWS Backup](https://aws.amazon.com/backup/pricing/)と
[Aurora DSQL](https://aws.amazon.com/rds/aurora/dsql/pricing/)。

基盤適用後のオンデマンドバックアップは次のコマンドで開始する。
保存期間は7日とし、本番の停止・改名直前にも最新バックアップを取得する。

```sh
mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- aws backup start-backup-job --region ap-northeast-1 \
  --backup-vault-name weblog-article-migration-production \
  --resource-arn arn:aws:dsql:ap-northeast-1:282782318939:cluster/zjuauvwetzvab4i3bdfd47e3yu \
  --iam-role-arn arn:aws:iam::282782318939:role/WeblogArticleMigrationBackup \
  --lifecycle DeleteAfterDays=7
```

BackupJobIdでdescribe-backup-jobを確認し、COMPLETEDとRecoveryPointArnを記録する。
get-recovery-point-restore-metadataで実データを取得してから、復元先は単一の東京
リージョン・AWS管理キー・削除保護ありの別クラスタとしてstart-restore-jobを実行する。
復元先を本番ホストへ自動切り替えしない。作成されたクラスタのホストでstatusと
snapshotを読み取り確認する。稼働中の本番との比較は時点差があり得るため、
停止後の同一バックアップ時点での照合を最終条件とする。
復元クラスタの削除は対象ARNを記録し、2026-10-01の終了後削除の承認範囲で行う。

## 先行maintenanceイメージの準備（2026-10-01）

既存のDockerfile.lambdaからローカルDocker Desktopでlinux/arm64イメージを作成した。
ビルド対象SHAは`a5c6ca48f02abfac4442410855280215cf6d787e`。
Parameter Store拡張は既存スクリプトで固定layer ARNとSHA-256を検証して取得した。

- repository: `282782318939.dkr.ecr.ap-northeast-1.amazonaws.com/weblog-authoring-production`
- digest: `sha256:10f61f0f95e090c4be494e9e420f32e43e802f98c2ee51cf674a0f3668b82480`
- CalVer tag: `authoring.2026-10-01.1`
- content tag: `content-07adcd60d274493e3551aa0fe52b949393fda7af12261ff090952a2615fc0b45`
- ECRの圧縮サイズ: 343,860,373 bytes。登録したイメージは1件、tagは2個。

content hashは既存workflowと同じgit ls-tree対象・linux/arm64の計算を使った。
後続の通常デプロイでもビルド入力が変わらなければ同じイメージを再利用できる。
ECR登録はLambda更新を行わない。登録後、本番Lambdaが旧digest
`sha256:ddadc2b139c5c8806a0036bb2c0b9f003016e64eefad6cad1a13645392e62ba9`のまま
Active / Successfulであることを読み取り確認した。一時ECR資格情報は削除済み。

### イメージの検証

- test_authoring_lambda.rb: 4 tests / 43 assertions成功。
- 実イメージをnetwork=none、DB・AWS資格情報なしで起動した。
  AUTHORING_MAINTENANCE=trueでGET、HEAD、POST、DELETEの4要求が503 / no-storeとなり、
  定期ジョブもmaintenance例外で停止することを確認した。
- 上記はローカルの実イメージ確認であり、本番Lambdaの503確認はまだ未実施。
  イメージ自体に停止フラグを固定していない。配備時の環境変数設定が必要。

### 先行配備のplan

本番rootをfresh initし、authoring Lambdaをtargetとする保存planを作成した。
差分はauthoringの環境変数1リソース更新のみ。AUTHORING_MAINTENANCE=trueと
ARTICLE_PIECES_ENABLED=falseを追加し、既存のWebmentionフラグを維持する。
このplanはまだapplyしていない。通常の全体planを改名前に適用しない。

本番の停止・配備時には、まずcutoverをpausedへ変更し起動元を停止・排出する。
停止承認後にfresh init・保存planを再取得し、そのplanを適用する。
この環境変数を無視する旧イメージから、上記のdigestへauthoring Lambdaだけを
update-function-codeで更新し、function-updated-v2を待つ。RevisionIdを指定して
意図しない同時更新を検出する。Lambda/API Gatewayへの直接HTTP要求で503を確認する。
Terraformのapply後は毎回全体planを再取得し、予定済みの未適用差分と照合する。

ここまでの作業では、本番の停止・DB改名・main push・Lambda更新を行っていない。

### 先行配備後の通常デプロイ

authoringだけ先行配備すると、build-authoringのdeploy出力はfalseになり得る。
その出力でWebmentionとperformanceの更新まで省略しないようworkflowを修正した。
これらは各LambdaのResolvedImageUriを調べ、固定digestが違う場合だけ更新する。
authoringが更新済みでも、旧イメージの利用元を更新できることと、同じdigestの
Lambdaを再更新しないことを、AWS CLIを外部境界で置き換えたプロセステストで確認した。
workflowテストは11 tests / 165 assertions成功。

通常デプロイは全Lambda更新とsite配信の後に本番smokeを実行する。
maintenance=trueのままではAPI smokeが失敗し得るため、全利用元の更新完了を確認した
段階で停止設定を解除する。workflowの配信・Lambda更新段階を確認してから、
fresh Terraform planで解除し、cutoverの復帰とsmokeを完了する。
503中のsmoke失敗をデプロイ成功として記録しない。
