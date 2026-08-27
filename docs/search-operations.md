# 検索品質と運用確認

## 品質基準

公開検索APIは、日本語、英数字、1文字、2文字の検索語を受け付ける。
固定評価では、タイトルに検索語を含む代表記事が上位10件に含まれることを確認する。

```console
mise exec -- ruby bin/check-search-quality
```

評価対象はスクリプト内の `CASES` に固定している。
代表記事を非公開にした場合や、より適切な記事が増えた場合は、検索仕様の変更とは分けて評価対象を更新する。

検索APIは `Cache-Control: private, no-store` を返す。
Lambdaの構造化ログには処理時間、インデックスの経過秒数、結果件数だけを記録し、検索語は記録しない。

## 鮮度

記事の保存後、authoring LambdaはFIFOキューへ更新要求を送る。
キューは5分の遅延後にインデクサーを起動し、インデクサーは新しいSQLiteとmanifestをS3へ公開する。
毎日03:00 JSTの定期実行は、保存時の通知を失った場合の回復経路である。

正常時の目標は保存から10分以内、通知または生成に失敗した場合の目標は翌日までである。
保存時刻と `search_index_completed` の `generated_at` を比較して確認する。

```console
mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess \
  aws logs tail /aws/lambda/weblog-search-indexer-production \
  --region ap-northeast-1 --since 1h --format short
```

## 障害時の確認

検索インデックスの生成失敗は記事の保存処理へ伝播しない。
検索APIは新しいmanifestまたはSQLiteを読み込めない場合、プロセス内に読み込み済みの旧世代を維持する。
旧世代がない場合だけ503を返す。

次の三つのalarmを確認する。

- `weblog-search-index-generation-errors-production`
- `weblog-search-index-queue-age-production`
- `weblog-search-index-dead-letters-production`

DLQにメッセージがある場合は、インデクサーのCloudWatch LogsでDSQLまたはS3の失敗を直し、元のFIFOキューへ更新要求を送り直す。
記事保存と閲覧は検索復旧を待たずに継続できる。

## 2026-08-27の本番基準値

- 公開インデックス：804記事、約4.8 MB
- インデクサー：直近24時間で15回起動、平均6.38秒、最大17.82秒
- 保存通知から新世代の公開：約5分16秒（21:16 JSTのSQS送信、21:21:16 JSTの生成完了）
- 検索API内部処理：warm時27〜65 ms、世代読込を伴う例で344〜478 ms
- DLQ：0件
- 検索関連alarm：すべて `OK`
- S3の検索オブジェクト：10世代とmanifest、合計約47 MB

同日の初期構築ではDSQL接続権限とS3権限による3回の失敗があり、その後の実行で新世代の公開に成功した。
この履歴から、失敗が記事保存を止めず、修正後の実行で復旧することを確認した。

## 費用

直近24時間の利用量を30日へ延ばすと、1 GBのインデクサーは約2,870 GB秒を使う。
Lambdaの公開単価で計算した実行料金は、無料利用枠を考慮しなくても月額約0.05 USDである。
SQSは月100万リクエスト、Lambdaは月40万GB秒の無料利用枠があり、現在の検索専用利用量はそれぞれを下回る。
EventBridgeの定期実行は1日1回である。

検索世代を1日15個ずつ保持すると、S3は月に約2.1 GB増える。
世代を無期限に保持する構成なので、検索専用費用が月額1,000円未満という基準は現状で満たすものの、S3使用量は定期的に確認する。

- [AWS Lambda Pricing](https://aws.amazon.com/lambda/pricing/)
- [Amazon SQS Pricing](https://aws.amazon.com/sqs/pricing/)
- [Amazon EventBridge Pricing](https://aws.amazon.com/eventbridge/pricing/)
- [Amazon S3 Pricing](https://aws.amazon.com/s3/pricing/)
