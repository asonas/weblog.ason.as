#!/bin/sh
# Check DraftSync.tla with TLC, one run per rule, so that one broken rule does
# not hide another. Usage: check.sh [MaxEdits] [MaxRev]   (defaults: 3 3)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
max_edits=${1:-3}
max_rev=${2:-3}
rules="SavedMeansOnServer DeviceFirst AppliedOnce NoSilentOverwrite"

java_tool="java@temurin-21"
tlc_tool="http:tla2tools[url=https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar,checksum=sha256:936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88]@1.7.4"

mise install --quiet "$java_tool" "$tlc_tool" >/dev/null
jar="$(mise where "$tlc_tool")/tla2tools.jar"

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-draft-sync.XXXXXX")
trap 'command rm -rf "$work"' EXIT
cp "$here/DraftSync.tla" "$work/"

summary=""
failed=0
for rule in $rules; do
  printf 'SPECIFICATION Spec\nCONSTANTS\n  MaxEdits = %s\n  MaxRev = %s\nCONSTRAINT Bound\nINVARIANT %s\n' \
    "$max_edits" "$max_rev" "$rule" >"$work/$rule.cfg"
  if (cd "$work" && mise exec "$java_tool" -- java -XX:+UseParallelGC -cp "$jar" tlc2.TLC \
      -config "$rule.cfg" -workers 1 -metadir "$work/states-$rule" DraftSync.tla) \
      >"$work/$rule.out" 2>&1; then
    states=$(sed -n "s/.* \\([0-9,]*\\) distinct states found.*/\\1/p" "$work/$rule.out" | tail -1)
    summary="$summary $rule=成立"
  else
    if grep -q "is violated" "$work/$rule.out"; then
      summary="$summary $rule=違反"
      echo "== $rule: 違反。TLCの反例 =="
      sed -n '/is violated/,/distinct states found/p' "$work/$rule.out"
    elif grep -q "Deadlock reached" "$work/$rule.out"; then
      summary="$summary $rule=デッドロック"
      echo "== $rule: デッドロック。TLCの反例 =="
      sed -n '/Deadlock reached/,/distinct states found/p' "$work/$rule.out"
    else
      summary="$summary $rule=実行エラー"
      echo "== $rule: TLCが検査を完了できなかった =="
      cat "$work/$rule.out"
    fi
    failed=1
  fi
done

echo "要約:$summary 状態数=${states:-不明} (MaxEdits=$max_edits MaxRev=$max_rev)"
exit "$failed"
