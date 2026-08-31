# Production runbook

このrunbookは、production deploymentの確認、GitHub OAuth credentialとsession secretのrotation、失敗時の復旧を扱います。
日常開発の手順は[README](../README.md)を参照してください。

## 原則

- secret値をGit、`.env`以外のtracked file、Terraform、GitHub Actions input、issue、log、command lineへ書かない。
- AWS credentialは`mairu exec --no-login`で非対話に取得する。
- production変更前にAWS account IDが`282782318939`であることを確認する。
- deployment対象は`Validate` workflowが成功したmainのSHAとする。
- application deploymentから`Apply production Terraform` workflowを起動しない。

## Deploymentの確認

mainへのpush後、`Validate`が成功すると、同じSHAを対象に`Deploy production`が起動します。
まずActionsで両workflowのhead SHAが一致していることを確認します。
`Deploy production`では、次の順序で成功を確認します。

1. checkout、site artifact metadata、Lambda image tagのSHA検証
2. database schema適用
3. 必要なLambda imageのbuildと更新
4. hash付きauthoring assetのupload
5. `index.html`のupload
6. CloudFront invalidationの完了
7. HTML、HTMLが参照する全authoring asset、`GET /api/pages`のsmoke check
8. `static/authoring/assets/`だけのstale object削除

Actions成功後、productionを読み取り専用checkで確認します。

```sh
mise run check:production
```

このcheckはAWS account、4つのLambdaのstateとlast update status、OAuth secretのmetadataだけを確認し、secret値を取得しません。

## GitHub OAuth credentialの更新

OAuth Appで新しいclient secretを発行してから、既存の唯一の更新入口である`bin/configure-production-oauth`を使います。
このcommandは現在のsession secretを保持し、client IDとclient secretだけを更新します。

secret値をshell historyへ残さないよう、値は標準入力から読み取ります。

```sh
read -r GITHUB_CLIENT_ID
read -r -s GITHUB_CLIENT_SECRET
export GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bin/configure-production-oauth
unset GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
```

commandはsecret値を表示せず、更新したSecrets Manager secret IDだけを表示します。
更新後は新しいブラウザsessionでGitHub loginを確認し、`mise run check:production`を実行します。
確認が終わるまで古いOAuth credentialを失効させません。

## Session secretのrotation

session secretのrotationはOAuth credential更新と分けて実行します。
`bin/rotate-production-session-secret`はOAuth client IDとclient secretを保持し、128文字の新しいsession secretをprocess内で生成します。
値は引数、標準出力、Terraform state、tracked fileへ出しません。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  mise exec -- bin/rotate-production-session-secret
```

rotationにより既存のlogin sessionは無効になります。
実行後はGitHubから再loginし、読み書き操作と`mise run check:production`を確認します。

## Failure pointと再開

| Failure point | Production state | 対応 |
| --- | --- | --- |
| Validate | 未変更 | failureを修正してmainへpushする。Deployは起動しない。 |
| SHA・artifact・Lambda baseline検証 | 未変更 | mismatchの原因を確認する。artifactの差し替えやtagの上書きはしない。 |
| database schema | schemaだけが一部適用された可能性がある | `bin/bootstrap-dsql`は冪等なので、原因修正後に同じmain SHAから再実行する。schemaを手作業で戻さない。 |
| Lambda buildまたは更新 | 一部Lambdaだけが対象SHAの場合がある | workflowを再実行する。各Lambdaは自身の稼働SHAから差分判定され、未完了のLambdaだけが更新される。 |
| asset upload | 新hash assetだけが追加された可能性がある | 旧HTMLと旧assetは残る。原因修正後に再実行する。 |
| HTML upload、invalidation、smoke check | 新HTMLが公開された可能性がある | 下記のS3 version復旧で直前のHTMLと必要なassetを戻し、invalidationとsmoke checkを行う。 |
| stale asset削除 | deployment smoke checkは成功済み | 通常は復旧不要。以前のHTMLへ戻す場合は、そのHTMLが参照するasset versionも一緒に復旧する。 |

実行中のdeploymentはcancelしません。
新しいmain SHAが到着しても、production変更開始済みのrunを完了させてから次のrunを進めます。

## Webの手動復旧

site bucketはversioningが有効です。
復旧対象のversion IDと内容を確認してから、同じkeyへcopyしてcurrent versionにします。

```sh
readonly SITE_BUCKET=weblog-asonas-site-production-282782318939

mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws s3api list-object-versions --bucket "$SITE_BUCKET" --prefix index.html
```

確認したversion IDをshell変数へ設定し、`index.html`を復旧します。

```sh
read -r VERSION_ID
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws s3api copy-object \
    --bucket "$SITE_BUCKET" \
    --key index.html \
    --copy-source "${SITE_BUCKET}/index.html?versionId=${VERSION_ID}" \
    --metadata-directive COPY
```

復旧したHTMLが参照する`static/authoring/assets/`の各keyも同じ方法でversionを確認し、削除済みならそのversionを同じkeyへcopyします。
投稿assetを置く`assets/`や`assets/inbox/`は変更しません。

復旧後はCloudFront invalidationを作成し、完了を待ちます。
最後に`bin/smoke-production https://weblog.ason.as`と`mise run check:production`を実行します。

## Lambdaの手動復旧

ECR image tagはimmutableで、`<40文字commit SHA>-<run attempt>`形式です。
Actionsの直前に成功したdeploymentから、各Lambdaの復旧対象tagを個別に決めます。
4つのLambdaが同じ時点とは限らないため、1つのtagを全functionへ一括適用しません。

現在値と候補imageを読み取り確認します。

```sh
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws lambda get-function --function-name weblog-authoring-production

mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws ecr describe-images --repository-name weblog-authoring-production
```

対象tagを確認後、対応するrepository URLを含む完全なimage URIでfunctionを更新し、完了を待ちます。

```sh
read -r IMAGE_URI
mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws lambda update-function-code \
    --function-name weblog-authoring-production \
    --image-uri "$IMAGE_URI"

mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- \
  aws lambda wait function-updated-v2 --function-name weblog-authoring-production
```

search indexer、inbox sync、Matrix notifier、Bluesky OAuthも、それぞれのrepositoryとfunctionで同じ確認を行います。
復旧後は`mise run check:production`を実行し、公開HTMLとAPIもsmoke checkします。
