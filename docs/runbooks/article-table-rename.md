# Article モデル・テーブルの改名

対象は Issue #202。`PageDocument` を `ArticleDocument`、`DraftReader` を
`PublishedArticleReader` に改名し、記事・公開関連の17テーブルを改名する。
対応表は `ArticleTableRename::TABLES` を正とする。本文、ID、公開経路、日時、
編集中の同期データは変更しない。Piece や Inbox メモの導入は別工程。

## 実行条件

- 本番適用前に、実行するコードの SHA、旧 Lambda のバージョン／イメージ、
  Terraform の設定値、イベントソース・スケジュール・同時実行数を記録する。
- 復帰用のデータ退避を取得し、復元方法を確認する。
- `paused` は公開 GET/HEAD を止めない。API は `AUTHORING_MAINTENANCE=true`
  で起動し、DB 初期化前に HTTP 503 を返す状態にする。
  Terraform の変数は `authoring_maintenance`。標準値は false。
- この設定は authoring Lambda だけに効く。Draft Worker、Webmention の受信・
  検証・公開・再検証・outbox 処理、authoring performance Lambda、手動スクリプトを含む DB 利用元を停止する。
  キューやデータを削除せず、イベントソース／スケジュールを無効化し、直接実行も止める。
- すでに開始済みの処理が終了し、cutover の実行中 receipt がゼロであることを確認する。
  残った receipt を根拠なく消さない。公開 GET/HEAD と管理 API の 503 を確認する。
  CloudFront に残る静的 HTML は DB へアクセスしないため、停止の証拠には使わない。

`--stopped` は以上を運用者が確認したという宣言であり、自動停止機能ではない。
この手順書自体は本番操作の承認ではない。

## ローカル SQLite

開発 API と Worker を停止し、対象 DB を退避してから行う。テストのリハーサルには
`test/fixtures/drafts/article_tables_legacy.sql` の旧スキーマとサンプル記事を使う。

```sh
article_db=/absolute/path/to/drafts.sqlite3
mise exec -- ruby bin/rename-article-tables status --sqlite "$article_db"
mise exec -- ruby bin/rename-article-tables snapshot --sqlite "$article_db" > /tmp/article-before.json
mise exec -- ruby bin/rename-article-tables forward --sqlite "$article_db" --confirm-target "$article_db" --stopped --record /tmp/article-rename.jsonl
mise exec -- ruby bin/rename-article-tables snapshot --sqlite "$article_db" > /tmp/article-after.json
diff -u /tmp/article-before.json /tmp/article-after.json
```

改名後のコードで API を起動し、既存の公開記事の表示、下書きの再読み込み・保存・
公開を確認する。旧コードを改名後の DB に接続しない。

## 本番 DSQL

1. 既存コードで cutover を `paused` にし、処理を排出する。
2. 上記の DB 利用元を停止し、新コードを maintenance=true で配備する。
   通常の `deploy.yml` は Lambda 更新より先に bootstrap を実行するため、旧テーブルが
   あるとここで停止する。初回はビルド済みの新 authoring イメージを digest 固定で
   手動配備する必要がある。改名後に通常デプロイを再実行し、bootstrap と残りの
   Lambda の更新を完了する。bootstrap の旧名検査を迂回しない。
   新コードの通常リクエストを改名前に通さない。旧コードはこの環境変数を解釈しないため、
   新コードの配備完了と 503 を確認してから先へ進む。
3. DSQL の `status` と `snapshot` を保存する。以下の CLI の `--sqlite` を
   `--host "$article_host"` に置き換え、`--confirm-target` にも完全なホスト名を指定する。
   AWS 認証には `mairu exec --no-login` と必要最小限のロールを使う。
4. `forward` を実行する。DDL は1テーブルずつ実行し、進行記録を fsync してから進む。
   改名前後で各テーブルの行数・全列の SHA-256 が一致しなければ停止する。
5. 停止したまま `snapshot` を再取得し、手順3の記録との一致、旧名が残っていないこと、
   同期／cutover テーブルが維持されていることを確認する。
6. 全 DB 利用元が新コードであることを確認する。API を停止設定から戻し、
   公開記事と下書きの読み込みを確認する。cutover を `open` に戻し、保存・公開を確認する。
   Worker・イベントソース・スケジュールを記録した設定へ戻す。

Terraform の変更は毎回 init → 保存した plan の全変更確認 → その plan の apply →
再 plan の順に行う。Webmention など既存の有効化変数を維持する。

DSQL の `ALTER TABLE … RENAME TO` は
[AWS の対応構文](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/alter-table-syntax-support.html)
に記載されている。本番 DSQL での実行・権限確認はローカル SQLite の検証とは別に行う。

## 中断・復帰

- 旧名だけ存在: forward で改名する。新名だけ存在: forward はその表をスキップする。
- 両方存在／両方不在: 全体を事前検査で停止する。空テーブルを作ったり削除して帳尻を合わせない。
- 接続切断時: 停止状態を維持し `status` を確認して同じ forward を再実行できる。
  最初に保存した snapshot とも必ず比較する。再実行時の比較だけでは中断中の書き換えを検出できない。
- 改名前に戻す場合: 同じ対象・記録ファイルを指定して `reverse` を実行する。
  改名済みの表だけを逆順に戻す。データの上書きや再インポートはしない。
  元の snapshot との一致を確認してから、全利用元を旧コードへ戻し停止を解除する。
- 通常利用を再開した後の障害では、この記事の改名手順を使って古いデータを復元しない。

通常の `setup!` と DSQL bootstrap は、旧名が一つでも残っていれば停止する。
移行コマンドは不足テーブルの補充や既存データの補正を行わない。
