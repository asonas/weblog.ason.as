# 他サイトの公開済み記事の取り込み

対象はLinear ASO-151。別サイトで公開済みの記事を、元の作成・公開・更新日時のまま `/<slug>` に取り込む。
`bin/import-external-articles` が公開版・下書き履歴・Atom IDをまとめて作る。通常の公開操作は経由しないため、
公開キャッシュの無効化依頼とWebmention送信依頼は作らない。HTMLとAtom・検索の出力は、公開後の修復処理が作る。

## 記事の扱い

- URLは `slug`。作業中の名前（`metadata.title`）もslugのままで、編集画面の挙動は通常の名前付き記事と同じ。
- 画面・`<title>`・`og:title`・Atom・検索には `display_title` を使う。`display_title` は取り込み時だけ設定でき、
  編集画面とAPIの保存からは変更できない。編集・再公開・Piece形式への変換後も公開版に残る。
- 一覧とAtomの並びは取り込んだ更新日時に従う。Atomは更新日時が新しい30件だけを載せるため、古い日時の記事は載らないことが多い。
  作成・公開・更新日時はISO 8601で、UTCのマイクロ秒に正規化して保存する。
- Atom IDは `<site_url>/<slug>` 。名前を変えても変わらない。

## manifest

```json
{
  "format": 1,
  "site_url": "https://weblog.ason.as",
  "source": "ason.as",
  "articles": [
    {
      "slug": "2026-06-15-kosendj-42",
      "display_title": "高専DJ 第42回の記録",
      "body": "本文のMarkdown",
      "created_at": "2026-06-15T09:00:00+09:00",
      "updated_at": "2026-06-20T12:00:00+09:00",
      "published_at": "2026-06-16T10:00:00+09:00",
      "cover_mode": "auto",
      "cover_image_url": null
    }
  ]
}
```

- 記事IDは `source` とslugから、版IDは記事IDから決まる。同じmanifestは何度実行しても同じIDになる。
- 日時はオフセット付きで書く。`updated_at` は `published_at` 以降にする。
- slugは名前の規則を満たし、日付だけの名前（`YYYY-MM-DD`）、`published`・`search`・`feed.xml` などのシステム用の名前は使えない。
- 本文の画像はすべて `/assets/` で始まるURLにする。違反はすべて列挙して停止する。
- 本文はUTF-8で512 KiB以内。改行は `\n` に揃えて保存する。

## 手順

1. 画像を `assets/uploads/YYYY/MM/<uuid>.<ext>`（jpg・png・webp・gif）へアップロードする。
   Content-Typeと `cache-control: public, max-age=31536000, immutable` を付ける。
   `assets/inbox/` と、`weblog-inbox-adoption` タグを付けた `assets/uploads/` のオブジェクトはライフサイクルで失効するため使わない。
   本文とカバー画像のURLを `/assets/uploads/...` に書き換えてからmanifestを確定する。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     aws s3 cp ./photo.jpg "s3://$SITE_BUCKET/assets/uploads/2026/06/$(uuidgen | tr A-Z a-z).jpg" \
       --content-type image/jpeg --cache-control "public, max-age=31536000, immutable"
   ```

2. 画像の寸法を登録する。公開HTMLは描画時に寸法を埋め込むため、取り込み前に行う。
   詳細は[既存画像の移行](../article-mobile-investigation.md#既存画像の移行)。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     mise exec -- bundle exec ruby bin/backfill-image-dimensions --host "$DSQL_HOST" --site-bucket "$SITE_BUCKET" --apply
   ```

3. cutoverが `open` であることを確認する。`open` 以外では取り込みを受け付けない。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     mise exec -- bundle exec ruby bin/draft-cutover status --host "$DSQL_HOST"
   ```

4. dry-runで計画を確認する。書き込みはしない。各記事は `new`、`already-imported`、`conflict`（理由付き）のどれかになり、
   `conflict` があると終了コード1で終わる。`conflict` は、同じIDの記事がある、slugが公開済みまたは下書きに予約済み、
   取り込み後に編集された、manifestが前回と違う、のいずれか。いずれも上書きしない。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     mise exec -- bundle exec ruby bin/import-external-articles --host "$DSQL_HOST" --manifest ./manifest.json
   ```

5. 計画を確認したら、同じホストを `--confirm-host` に指定して `--apply` を付ける。
   記事ごとのトランザクションで全件を保存してから、記事ごとに検証する。検証で失敗しても、それより後の記事も保存済みになっている。途中で止まったら原因を直し、同じコマンドを再実行する（取り込み済みは何もしない）。
   取り込みの取り消し機能はないので、dry-runの結果を必ず確認する。
   終了後に手順3の `status` を再実行し、`operations` が空であることを確認する。処理が強制終了すると
   実行中の記録（`draft_write`）が残ることがあり、残ったまま `paused` から `open` へ戻す操作はできない。
   残った記録を根拠なく消さない。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     mise exec -- bundle exec ruby bin/import-external-articles --host "$DSQL_HOST" --confirm-host "$DSQL_HOST" \
       --manifest ./manifest.json --apply
   ```

6. 公開HTML・Atom・検索を作るため、定期修復（`draft_repair`）を実行する。処理するのは `DRAFT_PUBLICATION_FUNCTION_NAME` の検索インデクサーのLambda。毎時の定期実行を待ってもよい。
   結果が `partial` なら、もう一度実行する（1回に処理する版は50件まで）。

   ```sh
   mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
     aws lambda invoke --region ap-northeast-1 --function-name weblog-search-indexer-production \
       --cli-binary-format raw-in-base64-out --payload '{"operation":"draft_repair"}' /tmp/draft-repair.json
   cat /tmp/draft-repair.json
   ```

## 確認

- `/<slug>` が200で、見出し・`<title>`・`og:title` が `display_title` になっている。画像が表示される。
- `/feed.xml` が更新されている。取り込んだ記事が新しい30件に入る場合は、`display_title` で載り、
  `<published>` と `<updated>` が元の日時になっている。
- サイト内検索で `display_title` の語から記事が見つかる。
- 一覧の並びが取り込んだ更新日時に従っている。
- 取り込み前にそのURLを開いていた場合、CloudFrontに古い応答が残ることがある。取り込みは無効化を依頼しないので、
  残っていれば `/<slug>` と `/<slug>/` だけを個別に無効化する。
