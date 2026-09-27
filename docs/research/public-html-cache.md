# 選定記事の公開HTMLキャッシュ

Issue [#188](https://github.com/asonas/weblog.ason.as/issues/188) の実装・検証記録。2026-09-27に本番CloudFrontのキャッシュポリシーとdistributionだけを変更した。選定記事のアプリケーションコードと対象URLは未配信。

## 配信契約

`DYNAMIC_PUBLIC_ARTICLE_ROUTES` に列挙した記事だけが、公開済みsnapshotと現在の表示用リリースからHTMLを作り、`Cache-Control: public, max-age=0, s-maxage=180, stale-if-error=86400`とHTML本文由来のETagを返す。ブラウザは再検証し、共有キャッシュの通常TTLは180秒。条件付きGETは304と同じCache-Control/ETagを返し、HEADはGETと同じヘッダーで本文を返さない。Cookieやクエリは選定記事のHTML生成に使わず、認証情報や`Set-Cookie`も含めない。

CloudFrontの既定behaviorには、最小TTL 0、既定TTL 0、最大TTL 86,580秒のポリシーを付ける。パスはキャッシュキーに残る。クエリ、Cookie、追加ヘッダーはキーに含めず、選定記事ではこれらで本文・OGPが変わらない。末尾スラッシュや別のエンコード表現は別のキーになり得るが、公開経路の既存の正規化と応答を変更しない。選定記事以外の`no-store`/`no-cache`を最小TTL 0で尊重し、ヘッダーがない応答には既定TTL 0を適用する。

`/api/*`と`/feed.xml`は非キャッシュbehaviorを維持する。管理・認証・プレビューは選定一覧に入れず、既存の非公開応答または`no-store`を使う。旧記事HTML、CSS/JS、公開時の旧HTML生成は保持する。配信切替・切り戻しでinvalidationは実行しない。

CloudFrontは期限切れ後、配信元が接続不能または5xxの場合に保持済みHTMLを最大24時間使える。最大TTLを通常180秒と障害時86,400秒の合計以上にして切り詰めを避ける。ただしエッジから退避されたHTMLや、まだ一度もキャッシュしていないURLには保存保証がない。キャッシュ未保持時は配信元のエラーを返し、復旧後の次の再検証で新しいHTMLを取得する。正常なHTTP 200の誤表示は障害と判定されず、旧表示用リリースへの切り戻しが必要。切り戻し後も正常なエッジの旧HTMLは通常TTLの残り時間だけ残り得る。

根拠：[CloudFrontのTTLと`stale-if-error`](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Expiration.html)、[キャッシュポリシーの最小TTL](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cache-key-understand-cache-policy.html)、[キャッシュbehaviorのパスマッチ](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/DownloadDistValuesCacheBehavior.html)。CloudFrontのパスpatternでは任意の日本語記事URLを安全に個別指定できないため、配信元の応答ヘッダーで選定する。既存の[隔離試作](public-delivery-cdn.md)ではTTL60秒の更新と切り戻しを実CloudFrontで観測したが、今回の180秒・障害時24時間を実証したものではない。

## 検証境界と本番切替

ローカルでは、HTTPテストでGET/HEAD/304、ETag、クエリ・Cookie・末尾スラッシュで同じ公開HTML、未選定記事とAPIの非キャッシュを確認する。Terraform mockテストはTTLの上下限、既定behavior、APIとfeedの専用behaviorを確認する。これらはCloudFront実配信のHit/Missやstale応答の証拠ではない。

2026-09-27の実行結果はRuby公開HTTPテスト2件・45 assertion、RuboCop、Terraform validate、production rootのmockテスト12件が成功。実CloudFrontの180秒更新、5xx・接続失敗時のstale、未保持時のエラー、復旧後の更新は未観測。時間を進めたローカル模擬だけで24時間の保持を証明しない。

2026-09-27の初回読み取り専用初期化は`asonas-blog`ロールのstate `HeadObject`が403で停止し、同ロールのCloudFront `GetDistributionConfig`もAccessDeniedだった。AdministratorAccessの使用は自動承認レビューが最初に拒否したが、ユーザーの明示的な読み取り専用plan承認後に実行できた。Terraform planは`-lock=false`でstateロックを書かず、保存先を権限700の`/tmp/weblog-188-plan/`にした。

本番stateをrefreshした全体planは**1件追加、5件変更、削除0件**。意図したCloudFrontポリシーとdistributionに加え、Webmention再検証ルールを`ENABLED`から`DISABLED`、workerのイベントソースを`true`から`false`、receiverの環境変数を`true`から`false`に戻す差分が出た。S3バケットポリシーにも計画時に値が未確定となる変更が出た。これらを今回のキャッシュ変更に混ぜて適用しない。

CloudFrontポリシーとdistributionだけを対象にした別のfresh保存planは**1件追加、1件変更、削除0件**。ポリシーは最小/既定TTL 0、最大TTL 86,580秒で、Cookie・クエリ・追加ヘッダーをキャッシュキーに含めない。distributionは既定behaviorのポリシー差し替えと`/feed.xml`の非キャッシュbehavior追加だけで、`/api/*`と既存の静的assetsのbehaviorは同じ。

ユーザーがこの限定適用を承認した後、再初期化し、`public-html-approved.tfplan`をrefresh付きで新たに保存した。全変更を確認して、その保存planを適用し、**1件追加、1件変更、削除0件**で終了した。適用後の対象付きfresh planは差分なし。全体fresh planは**0件追加、3件変更、削除0件**で、上記Webmentionの3件だけが残り、S3バケットポリシーの計画時差分は消えた。全体planは適用していない。CloudFront APIでdistributionが`Deployed`、既定behaviorに新ポリシー`d4078009-fe13-4d31-a7f7-883dd42db37a`、`/api/*`と`/feed.xml`がCachingDisabled、静的assetsがCachingOptimizedのままと確認した。実サイトのHEADではトップが200・`no-store`、feedが200・`public, max-age=300`を返した。feedは専用behaviorでCloudFrontにキャッシュされない。選定記事の本番HTMLキャッシュはまだ観測していない。

対象URLの本番指定と配信切替は後続Issueで行う。切替後は同じURLの初回Miss・再取得HitとAge、180秒経過後の表示用リリース更新・元の版への復帰、HTMLが参照するCSS/JSの200、Cookie付き・クエリ付き・末尾スラッシュ・エンコードされたURL、非選定記事・管理・認証・API・feed、redirect・404・ETag/304・HEADを確認する。CloudFrontの接続失敗・5xx、キャッシュ未保持、復旧の観測には隔離した配信元が必要で、本番配信元を故意に停止しない。観測回数と費用上限を別途決める。24時間の全期間保持は短時間のローカル模擬から保証しない。
