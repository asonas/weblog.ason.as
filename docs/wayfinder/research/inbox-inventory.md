# 現行の写真インボックスと保存基盤

## 結論

現行の写真インボックスは、DBを使わずS3の `assets/inbox/YYYY/MM/DD/` を未使用項目の正本としている。採用時は `assets/uploads/YYYY/MM/` へコピーしてから元オブジェクトを削除するため、「インボックス用パスに残っているものだけを未使用として期限削除する」という契約はそのまま再利用できる。

一方、汎用コンテンツ・インボックスにはS3オブジェクトを持たない項目もあるため、既存のS3一覧だけでは共通インベントリにならない。Aurora DSQLには現在 `pages` と `links` しかなく、共通項目、ソース固有ID、発生日時、取り込み日時、期限を保存する表は新設が必要である。

## 再利用できる契約

- 写真の一時領域は `assets/inbox/YYYY/MM/DD/<uuid>.<ext>`、公開領域は `assets/uploads/YYYY/MM/<uuid>.<ext>` と分離されている。採用処理はキー形式を検証し、公開領域へコピーできた後で一時オブジェクトを削除する。[`image_upload.rb`](../../../lib/weblog_authoring/image_upload.rb) [`image_inbox.rb`](../../../lib/weblog_authoring/image_inbox.rb)
- ブラウザはAPIから有効期間5分のS3 Presigned POSTを受け取り、S3へ直接送信する。許可形式はGIF、JPEG、PNG、WebP、上限は25MBである。[`image_upload.rb`](../../../lib/weblog_authoring/image_upload.rb)
- 一覧取得と採用APIはGitHubログイン済みかつ許可された数値ユーザーIDを要求する。Presigned POSTの発行と採用はさらにCSRF検証を行う。単一ユーザーのWeb編集画面向け認可境界として再利用できる。[`lambda_api.rb`](../../../lib/weblog_authoring/lambda_api.rb)
- UIにはクリックとドラッグ＆ドロップの双方から同じ採用処理を呼ぶ経路があり、採用後はローカル一覧から項目を除去する。挿入位置もドロップ座標から決めている。[`editor.tsx`](../../../frontend/authoring/editor.tsx)
- LambdaのIAMは一時領域の一覧、取得、削除と、一時・公開領域への書き込みに限定されている。パス分離を権限境界としても使っている。[`iam.tf`](../../../infra/production/iam.tf)
- S3バケットは非公開かつAES256暗号化で、CloudFront経由で同一サイトの相対URLとして画像を配信する。[`hosting.tf`](../../../infra/production/hosting.tf)

## 変更が必要な制約

- S3の期限は現在30日であり、希望する約14日とは一致しない。バケットはバージョニング有効で、現行ルールは現行版を30日、非現行版を1日で期限切れにする。[`hosting.tf`](../../../infra/production/hosting.tf)
- 一覧は記事の日付に対応するS3プレフィックスを指定して取得し、S3の `LastModified` で並べる。EXIF撮影日時の抽出、全日付をまたぐ時系列一覧、登録日時と発生日時の分離はない。[`image_inbox.rb`](../../../lib/weblog_authoring/image_inbox.rb)
- Web側の前処理は画像をWebPへ再エンコードする場合がある。コードはEXIFを読み取らず、再エンコード後のファイルへEXIFを引き継ぐ処理もない。撮影日時を使うなら、変換前に端末またはクライアントで抽出してAPIへ明示的に渡す必要がある。[`imageUpload.ts`](../../../frontend/authoring/imageUpload.ts)
- S3 CORSは `https://weblog.ason.as` からのPOSTだけを許可する。ただしネイティブアプリのHTTPクライアントは通常ブラウザCORSの対象外である。モバイル用の認証方式とPresigned POST発行契約は、既存のGitHubセッションCookieとCSRFをそのまま前提にできない。[`hosting.tf`](../../../infra/production/hosting.tf) [`lambda_api.rb`](../../../lib/weblog_authoring/lambda_api.rb)
- 採用はS3のコピーと削除という2操作であり、トランザクションではない。コピー成功後の削除失敗では、一時領域と公開領域の双方に残る可能性がある。再試行時の冪等性と、DB項目を導入した後の整合手順を決める必要がある。[`image_inbox.rb`](../../../lib/weblog_authoring/image_inbox.rb)
- 現在のAurora DSQLスキーマには記事とリンクしかない。汎用インボックスのDB保持、使用時削除、14日後削除を担うスキーマや定期削除処理は存在しない。[`dsql_bootstrap.rb`](../../../lib/weblog_authoring/dsql_bootstrap.rb)
- API GatewayとCloudFrontには既存 `/api/inbox` 経路を通せるが、Lambdaは15秒タイムアウトである。外部ソースの定期取得を同じ同期リクエストへ載せる根拠はなく、収集実行基盤は別途決定が必要である。[`api_gateway.tf`](../../../infra/production/api_gateway.tf) [`lambda.tf`](../../../infra/production/lambda.tf)

## 後続チケットへ渡す判断材料

- 写真はS3パスを使用状態の正本にできるが、DBを共通インベントリとする場合も、写真の使用済み状態を長期保持せず、採用成功後にDB行を削除する構成ならパス契約と揃えられる。
- 期限判定は表示用の `occurred_at` ではなく、取り込み時刻を表す別の値を使う必要がある。そうしないと古い撮影日の写真がアップロード直後に失効する。
- 写真の14日削除はS3 Lifecycleへ任せられる。DB側はAurora DSQLに自動TTLがある前提を置かず、期限付き削除を実行する仕組みを設計対象にする。
- S3のLifecycle削除とDB削除は同時には起きないため、一覧や採用では「DB行はあるがオブジェクトがない」「オブジェクトはあるがDB行がない」を安全に収束させる必要がある。
- ネイティブiOSアプリは、既存の画像形式・25MB上限・Presigned POST方式を再利用できる。認証、撮影日時の受け渡し、重複防止は新しいAPI契約として決める必要がある。

## 調査範囲

ローカルコードとTerraformを一次資料として確認した。実稼働AWSリソースのdrift、実データ件数、S3 Lifecycleの実行状況はこの調査では確認していない。
