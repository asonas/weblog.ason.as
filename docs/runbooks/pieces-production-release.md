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
