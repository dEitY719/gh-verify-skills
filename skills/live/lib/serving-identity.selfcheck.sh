#!/usr/bin/env bash
# Self-check for lib/serving-identity.sh (dEitY719/gh-verify-skills#63):
#
#   bash skills/live/lib/serving-identity.selfcheck.sh
#
# No network, no gh. The fixture is a local repo where a PR was REBASE-merged,
# so its head SHA was rewritten and never reached main — the exact state that
# made /live 3167 stop on a checkout that was serving the PR.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
SI="$ROOT/skills/live/lib/serving-identity.sh"
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "FAIL  jq is required by lib/serving-identity.sh"; exit 1; }
[ -r "$SI" ] || { echo "FAIL  $SI missing"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

has() { case "$2" in *"$3"*) printf 'ok    %s\n' "$1" ;;
        *) printf 'FAIL  %s: want [%s] in:\n%s\n' "$1" "$3" "$2"; FAIL=1 ;; esac; }
run() { printf '%s' "$1" | sh "$SI" "${@:2}" 2>&1; }

# --- fixture: feature commit F on a branch, main moves on (M), then a rebase
# merge replays F onto main as F' — F != F', and F is not an ancestor of main.
R="$TMP/repo"
git init -q -b main "$R"
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
echo base > "$R/a"; g add -A; g commit -qm base
BASE=$(g rev-parse HEAD)
g checkout -qb feature
echo 'useSyncExternalStore' > "$R/modal.tsx"; g add -A; g commit -qm feature
HEAD_OID=$(g rev-parse HEAD)
g checkout -q main
echo other > "$R/b"; g add -A; g commit -qm other
g cherry-pick "$HEAD_OID" >/dev/null || { echo "FAIL  fixture rebase-merge failed"; exit 1; }
MERGE_OID=$(g rev-parse HEAD)
[ "$HEAD_OID" != "$MERGE_OID" ] || { echo "FAIL  fixture did not rewrite the SHA"; exit 1; }

MERGED=$(jq -n --arg m "$MERGE_OID" --arg h "$HEAD_OID" \
    '{state:"MERGED",mergeCommit:{oid:$m},headRefOid:$h,baseRefName:"main"}')
OPEN=$(jq -n --arg h "$HEAD_OID" '{state:"OPEN",mergeCommit:null,headRefOid:$h,baseRefName:"main"}')

# Step 2: the target line alone, sourced from mergeCommit.
out=$(run "$MERGED")
has "target line uses mergeCommit" "$out" "TARGET_SHA=$MERGE_OID (source=mergeCommit, state=MERGED)"

# (a) rebase-merged PR, serving main: mergeCommit is the contract -> verified.
out=$(run "$MERGED" "$R")
has "(a) mergeCommit on rewritten main -> verified" "$out" "SERVING_IDENTITY=verified"

# (b) the same serving checkout judged by the head SHA -> mismatch. This is the
# false stop the contract exists to prevent; it proves the fixture is real.
out=$(run "$(jq -n --arg h "$HEAD_OID" '{state:"MERGED",mergeCommit:null,headRefOid:$h}')" "$R")
has "(b) headRefOid on rewritten main -> mismatch" "$out" "SERVING_IDENTITY=mismatch"

# Unmerged PR: mergeCommit is null, headRefOid is the fallback.
g checkout -q feature
out=$(run "$OPEN" "$R")
has "unmerged -> headRefOid fallback" "$out" "TARGET_SHA=$HEAD_OID (source=headRefOid, state=OPEN)"
has "unmerged on its branch -> verified" "$out" "SERVING_IDENTITY=verified"

# Serving checkout genuinely lacks the PR: stop, and say what was compared.
g checkout -q "$BASE"
out=$(run "$MERGED" "$R")
has "stale checkout -> mismatch" "$out" "SERVING_IDENTITY=mismatch"
has "stop names state + source" "$out" "(source=mergeCommit, state=MERGED)"
has "stop names serving HEAD + lag" "$out" "@ $BASE (behind by 2 commits)"
has "no content check -> no absence claim" "$out" "do not claim the feature is absent"

# F-3: SHA mismatch but the served module carries the diff's symbol -> WARN.
printf 'export function M(){ useSyncExternalStore() }\n' > "$TMP/served.js"
out=$(run "$MERGED" "$R" --content-url "file://$TMP/served.js" --symbol useSyncExternalStore)
has "content match -> [WARN]" "$out" "[WARN] SHA 불일치, 내용 일치"
has "content match -> unverified, not a stop" "$out" "SERVING_IDENTITY=unverified"

# ...and a symbol missing from the served module keeps the stop.
out=$(run "$MERGED" "$R" --content-url "file://$TMP/served.js" --symbol useSyncExternalStore --symbol NotThere)
has "content absent -> mismatch" "$out" "SERVING_IDENTITY=mismatch"
has "content absent names the symbol" "$out" "absent from file://$TMP/served.js: NotThere"

# Not a git checkout -> unverified with a reason.
out=$(run "$MERGED" "$TMP")
has "non-git serving root -> unverified" "$out" "SERVING_IDENTITY=unverified"

# Bad input is exit 2, never a verdict.
printf '{}' | sh "$SI" >/dev/null 2>&1; rc=$?
has "no sha in stdin -> exit 2" "rc=$rc" "rc=2"

exit "$FAIL"
