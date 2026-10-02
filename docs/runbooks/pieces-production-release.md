# Piece・Inboxの運用入口

## 切替済みの基準

2026-10-01に公開・下書き機構の本番切替、17テーブルの改名、Piece作成フラグの有効化を実施しました。
実施時の検証・バックアップ・復帰結果は[切替記録](../history/2026-10-01-pieces-production-release.md#本番切り替え結果2026-10-01)にあります。
この記録は現在のAWS設定を保証するものではありません。

## 作業ごとの確認先

- 日常の配備と配備結果の確認: [production runbook](../production-runbook.md)。同じSHAのValidate、Deploy、smoke結果を確認する。
- 旧記事の個別移行、Piece形式、Inbox: [article-pieces-inbox](article-pieces-inbox.md)。一覧の「マイグレーションしてから編集」を入口にする。
- 開発APIの機能フラグとDB: [開発ガイド](../draft-authoring-development.md)。
- テーブル名の調査: `bin/rename-article-tables status` と[テーブル改名手順](article-table-rename.md)。改名済み環境に移行手順を再適用しない。
- モバイル配布: [iOS](../../ios/PhotoInbox/README.md#配布)、[Android](../../android/PhotoInbox/README.md#配布)。

本番の機能フラグを調べるときは、対象環境の `/api/auth/session` の機能項目とLambdaの `ARTICLE_PIECES_ENABLED` を照合します。
秘密値を含む環境変数全体は出力しません。設定変更は[production runbook](../production-runbook.md)とTerraform運用規範に従います。
