# 代表記事の段階的な本番比較

Issue [#189](https://github.com/asonas/weblog.ason.as/issues/189) の切替前記録。対象はユーザーが指定した次の固定URLに限る。Lambdaの `DYNAMIC_PUBLIC_ARTICLE_ROUTES` には、URLを一度デコードした記事ルートを設定する。対象外の公開ページ、管理、認証、プレビュー、APIは切り替えない。

| URL | 設定するルート |
| --- | --- |
| https://weblog.ason.as/Monitor%2B | `Monitor+` |
| https://weblog.ason.as/2026-09-26 | `2026-09-26` |
| https://weblog.ason.as/2026-09-25 | `2026-09-25` |
| https://weblog.ason.as/2026-09-24 | `2026-09-24` |
| https://weblog.ason.as/Webmention%E3%82%AF%E3%83%A9%E3%83%96 | `Webmentionクラブ` |
| https://weblog.ason.as/2026-09-23 | `2026-09-23` |
| https://weblog.ason.as/2026-09-22 | `2026-09-22` |
| https://weblog.ason.as/2026-09-21 | `2026-09-21` |
| https://weblog.ason.as/2026-09-19 | `2026-09-19` |
| https://weblog.ason.as/2026-09-18 | `2026-09-18` |
| https://weblog.ason.as/2026-09-17 | `2026-09-17` |
| https://weblog.ason.as/2026-09-16 | `2026-09-16` |

2026-09-27の切替前確認では、12 URLのHEADがすべて200で、`Cache-Control: no-store`。本番Lambdaの許可リストは未設定、本番S3の `display-releases/current.json` は存在しない。ローカルmainは `dd21f63`、本番最終デプロイは `f596530`。現在の本番CloudFrontキャッシュポリシーのみ[#188](public-html-cache.md)で先に適用済み。これらは切替前の状態であり、動的配信の本番動作を示さない。

切替前のHTMLでは、12 URLのOGPタイトルがそれぞれ記事名に一致した。一方、参照する版付きassetsは公開時期によって異なり、CSSは5種類、JSは6種類だった。例えば09-26は `public-HFKCHaap.css` / `public-K15Mu7UV.js`、09-24は `public-LIGbC1mB.css` / `public-DYqQwIWf.js`、09-16は `public-CAVhuv2g.css` / `public-CVj5glhd.js` を参照した。これは古い記事が公開時のCSS/JSを読み続ける現象を実ページで確認したもの。

2026-09-27の読み取り専用fresh Terraform planは、全体で追加0・変更4・削除0。許可リストの追加以外に、Webmentionの既知の設定ドリフト3件があった。`aws_lambda_function.authoring` のみに絞った保存planは追加0・変更1・削除0で、変更は環境変数 `DYNAMIC_PUBLIC_ARTICLE_ROUTES` の追加だけだった。どちらも適用していない。切替時にはplanを新たに作り直す。

## 切替前の利用量

UTCの2026-09-20〜26について、CloudWatchとCost Explorerの読み取り値を保存する。CloudFrontはdistribution全体、Lambdaはauthoring関数全体、費用はアカウントのサービス単位であり、12記事だけの利用量・費用ではない。Cost Explorerの各日付は取得時点ですべて暫定値だった。09-21のDSQL費用が他の日より高い原因も未帰属で、通常閲覧費として平均しない。

| UTC日付 | CloudFront requests | authoring Lambda invocations | DSQL USD | API Gateway USD | S3 USD | Lambda USD | CloudFront USD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 09-20 | 2,785 | 945 | 0.036436 | 0.001253 | 0.006434 | 0.000014 | 0.000000 |
| 09-21 | 6,030 | 5,013 | 0.446924 | 0.006516 | 0.020483 | 0.000095 | 0.005007 |
| 09-22 | 6,146 | 5,186 | 0.119608 | 0.006721 | 0.014815 | 0.000038 | 0.000008 |
| 09-23 | 4,226 | 3,478 | 0.078115 | 0.004523 | 0.013038 | 0.000038 | 0.000010 |
| 09-24 | 3,962 | 2,860 | 0.063844 | 0.003722 | 0.013126 | 0.000038 | 0.000007 |
| 09-25 | 4,321 | 3,549 | 0.081407 | 0.004613 | 0.013041 | 0.000038 | 0.000009 |
| 09-26 | 6,316 | 4,915 | 0.066398 | 0.005188 | 0.010361 | 0.000026 | 0.000012 |

CloudFrontの[popular objects report](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/popular-objects-report.html)は追加ログなしで上位50 URLのrequest/Hit/Missを遡って確認できる。ただし12 URLがすべて上位に入る保証はなく、全URLの比較には別のアクセス記録が要る。比較期間は[標準ログv2](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logging.html)を専用の非公開S3バケットに保存し、30日で自動失効させる。記録するのは日付、時刻、メソッド、パス、状態、キャッシュ結果、リクエストID、応答バイト数、応答時間、初回バイト時間の10項目に絞り、IP・Cookie・クエリは記録しない。CloudFrontのログ配信自体に追加料金はなく、S3の保存・アクセス費は一時的な計測費として別記する。ログ配信はbest effortで遅延・欠落の可能性があるため、費用や閲覧の厳密な全数とは扱わない。

ログ到着と対象パスの記録を実証してから、UTCで連続7日の切替前期間を確定する。切替後も同じ曜日構成の連続7日を記録し、対象12 URLを日別・パス別に集計する。`GET`/`HEAD`、2xx/3xx/4xx/5xx、Hit/Missを分け、人工的な確認リクエストはリクエストIDで除く。計測が終わったら配信設定を削除し、保存済みログは期限切れ後にバケットを削除する。CloudFrontのinvalidationは使わない。

## 切替順序

1. 12 URLについて、本文・title/OGP・HTML内のCSS/JS参照・ETag・画像/埋め込み/Wikiリンク/Webmention/ユニバースの有無を記録する。特に `Monitor+` はエンコードした `+`、`Webmentionクラブ` は日本語ルートと外部言及を確認する。公開済みsnapshotと旧HTMLがそれぞれ存在することを確かめる。公開閲覧と管理操作を分けて数え、切替前の比較期間・計測回数・費用範囲を記録する。
2. 版付きCSS/JSを先行配置し、表示用リリースを配信できるコードをデプロイする。デプロイ完了、Lambdaコード版、`display-releases/current.json`、参照するassetsの存在を確認する。この段階で許可リストは空のままとする。
3. 本番stateをrefreshしたTerraformの全体planと、`aws_lambda_function.authoring` だけの保存planを別々に確認する。既知のWebmentionドリフトを混ぜない。後者が許可リスト追加だけであることを確認し、その保存planだけを適用する。適用後にfresh planで対象差分がないことを確認する。CloudFrontのinvalidationは行わない。
4. 各固定URLでGET/HEAD/条件付きGET、本文・title/OGP、CSS/JSの版と200、画像・埋め込み・Wikiリンク・Webmention・ユニバース、クエリ・Cookie・末尾スラッシュ・エンコードの扱いを確認する。未選定記事、API、feedは従来のままと確認する。初回Missと再取得Hit、180秒後のリリース更新、旧版への復帰を記録する。
5. 連続7日、日別の閲覧回数とページ構成を揃えて機能・本文表示時間・Hit/Miss・cold/warm・通常費用を比較する。サンプル不足や費用の帰属が不明なら延長または回数を制限した追加比較を行う。通常費用が現状以下で、機能と速度が通過した場合のみ拡大可とする。

## 費用と復帰

比較範囲はDSQLの読み取り、Lambda実行、S3のGET/保存、CloudFront/API Gatewayのリクエストと転送、公開時の旧HTML生成。無料枠・管理利用・一時的な移行/計測費を別記し、未測定値は0とみなさない。API Gatewayの既存アクセスログにはルートキーと応答時間はあるが個別記事パスがないため、記事別の閲覧量は上記のCloudFrontログから集計する。費用の帰属ができない場合は現状以下と判定しない。

切り戻しはLambdaの許可リストを空にしたfresh Terraform planを確認して適用する。保存済みHTMLと旧生成は維持するため、公開・renameを継続した記事も旧経路で読める。通常キャッシュの残り最大約180秒を待ち、同じURLの `no-store` と旧本文を確認する。表示用リリースだけの不具合なら `display-releases/current.json` を前の版へ戻し、HTML・assets・ETagの版を確認する。どちらもinvalidationに依存しない。予期しない5xxや本文/OGPの不一致があれば拡大を停止する。

本番切替と7日比較が済むまで#189は閉じない。
