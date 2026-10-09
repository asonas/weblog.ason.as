#!/bin/bash
# Usage: bash scripts/set-production-jev-key.sh
set -euo pipefail
set +x
umask 077

for dependency in mise jq; do
  command -v "$dependency" >/dev/null || { printf '%s が必要です。\n' "$dependency" >&2; exit 1; }
done

typesafe_tmp=$(mktemp -d)
trap 'unset TYPESAFE_API_KEY; command rm -rf "$typesafe_tmp"' EXIT

printf 'Jev APIキー: ' > /dev/tty
IFS= read -r -s TYPESAFE_API_KEY < /dev/tty
printf '\n' > /dev/tty
export TYPESAFE_API_KEY

jq -ne '
  if ((env.TYPESAFE_API_KEY // "") | test("\\S") | not) then error("APIキーが空です")
  else {
    Name: "/weblog-authoring-production/typesafe",
    Type: "SecureString",
    Value: env.TYPESAFE_API_KEY,
    Overwrite: true
  } end
' > "$typesafe_tmp/update.json"
unset TYPESAFE_API_KEY

mise exec -- mairu exec --no-login \
  --server asonas-aws 282782318939/AdministratorAccess -- \
  aws --region ap-northeast-1 ssm put-parameter \
  --cli-input-json "file://$typesafe_tmp/update.json" \
  --query '{Version:Version,Tier:Tier}'

printf '本番のJev APIキーをParameter Storeに保存しました。稼働中のLambdaは次の実行環境から新しいキーを読み込みます。\n'
