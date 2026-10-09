#!/bin/bash
# Usage: bash scripts/set-production-jev-key.sh
# Terraform does not yet preserve this manually configured environment variable.
set -euo pipefail
set +x
umask 077

for dependency in mise jq; do
  command -v "$dependency" >/dev/null || { printf '%s が必要です。\n' "$dependency" >&2; exit 1; }
done

awsprod() {
  mise exec -- mairu exec --no-login \
    --server asonas-aws 282782318939/AdministratorAccess -- \
    aws --region ap-northeast-1 "$@"
}

typesafe_tmp=$(mktemp -d)
trap 'unset TYPESAFE_API_KEY; command rm -rf "$typesafe_tmp"' EXIT

awsprod lambda get-function-configuration \
  --function-name weblog-authoring-production \
  --query '{Environment:Environment,RevisionId:RevisionId}' \
  --output json > "$typesafe_tmp/current.json"

printf 'Jev APIキー: ' > /dev/tty
IFS= read -r -s TYPESAFE_API_KEY < /dev/tty
printf '\n' > /dev/tty
export TYPESAFE_API_KEY

jq -e '
  if (.Environment.Error != null) then error("Lambda環境変数を取得できませんでした")
  elif ((env.TYPESAFE_API_KEY // "") | test("\\S") | not) then error("APIキーが空です")
  else {
    Environment: {
      Variables: ((.Environment.Variables // {}) + {TYPESAFE_API_KEY: env.TYPESAFE_API_KEY})
    },
    RevisionId: .RevisionId
  } end
' "$typesafe_tmp/current.json" > "$typesafe_tmp/update.json"
unset TYPESAFE_API_KEY

awsprod lambda update-function-configuration \
  --function-name weblog-authoring-production \
  --cli-input-json "file://$typesafe_tmp/update.json" \
  --query '{FunctionName:FunctionName,LastUpdateStatus:LastUpdateStatus}'

awsprod lambda wait function-updated-v2 \
  --function-name weblog-authoring-production

awsprod lambda get-function-configuration \
  --function-name weblog-authoring-production \
  --query 'Environment.Variables.TYPESAFE_API_KEY' \
  --output json |
  jq -e '{configured: (type == "string" and length > 0)} | select(.configured)'

printf '本番のJev APIキーを設定しました。次回のTerraform適用時には保持する対応が必要です。\n'
