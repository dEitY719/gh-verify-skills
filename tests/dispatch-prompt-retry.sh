#!/usr/bin/env bash
# Behaviour check for the prompt retry loop in
# skills/post-merge-verify/references/dispatch.sh.md (dEitY719/gh-verify-skills#85).
#
#   bash tests/dispatch-prompt-retry.sh
#
# Runs the REAL first fence — extracted with the consumer's awk, as
# tests/dispatch-fence.sh does — against a throwaway git checkout and a stub
# `herdr` on PATH. The stub's `agent prompt` always answers a retryable code;
# what changes per case is what `herdr agent get` says about the agent:
#
#   landed   idle -> working, seq same  -> one send, no STUCK, [OK] dispatched
#   advanced idle, state_change_seq up  -> one send, no STUCK (it already ran)
#   never    idle, seq unchanged        -> 3 sends, STUCK rename + notification
#   busy     blocked before AND after   -> 3 sends, STUCK (status was not news)
#
# No network, no gh, no real herdr, no sleeps (PMV_SETTLE_SECONDS=0).
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DOC="$ROOT/skills/post-merge-verify/references/dispatch.sh.md"
FAIL=0
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

chk() { # chk <label> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"; FAIL=1; fi
}
has()   { case "$2" in *"$3"*) chk "$1" yes yes ;; *) chk "$1" missing "contains: $3" ;; esac; }
hasnt() { case "$2" in *"$3"*) chk "$1" present "absent: $3" ;; *) chk "$1" yes yes ;; esac; }

command -v jq >/dev/null 2>&1 || { printf 'skip  jq not installed\n'; exit 0; }

FENCE='```'
awk -v f="$FENCE" '$0 == f "bash" && !b { b = 1; next } $0 == f && b { exit } b' \
    "$DOC" > "$TMP/dispatch.sh"

# A main checkout with a remote to fetch and rebase from.
git init -q --bare "$TMP/remote.git"
git -c init.defaultBranch=main init -q "$TMP/main"
git -C "$TMP/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$TMP/main" branch -M main
git -C "$TMP/main" remote add origin "$TMP/remote.git"
git -C "$TMP/main" push -q origin main
MAIN=$(cd "$TMP/main" && pwd -P)
printf '[{"repo":"o/r","path":"%s","verify_skill":"gh-verify:merged"}]\n' "$MAIN" > "$TMP/watched.json"

mkdir "$TMP/bin"
cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_LOG"
case "$1 $2" in
"worktree list") printf '{"result":{"source":{"source_workspace_id":"wT"}}}\n' ;;
"tab create") printf '{"result":{"tab":{"tab_id":"wT:t1"},"pane":{"pane_id":"wT:p1"}}}\n' ;;
"agent start") printf '{"result":{}}\n' ;;
"agent prompt") printf '{"error":{"code":"timeout","message":"stub"}}\n'; exit 1 ;;
"agent get")
    n=$(grep -c '^agent prompt' "$HERDR_LOG")
    seq=10; st=$STUB_STATUS0
    [ "$n" -gt 0 ] && { seq=$STUB_SEQ_AFTER; st=$STUB_STATUS; }
    printf '{"result":{"agent":{"agent_status":"%s","state_change_seq":%s}}}\n' "$st" "$seq" ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/herdr"

# shellcheck disable=SC2016  # $1 expands in the child bash, on purpose
run_case() { # run_case <name> <status> <seq-after-send> [status-before-send]
    : > "$TMP/$1.log"
    ( cd "$MAIN" && env PATH="$TMP/bin:$PATH" HERDR_LOG="$TMP/$1.log" \
        STUB_STATUS="$2" STUB_SEQ_AFTER="$3" STUB_STATUS0="${4:-idle}" \
        DOTFILES_ROOT="$TMP/no-dotfiles" CLAUDE_PLUGIN_ROOT="$ROOT" \
        IW_WATCHED_REPOS="$TMP/watched.json" TARGET_REPO=o/r TARGET_HOST=github.com \
        PR_NUMBER=7 HEAD_BRANCH=gone BASE_BRANCH=main REMOTE=origin PMV_SETTLE_SECONDS=0 \
        bash -c '. "$1"' _ "$TMP/dispatch.sh" 2>&1 )
}
sends() { grep -c '^agent prompt' "$TMP/$1.log"; }

out=$(run_case landed working 10)
chk "landed: the prompt is sent once" "$(sends landed)" 1
has "landed: the raw herdr answer is logged" "$out" '"code":"timeout","message":"stub"'
has "landed: says it did not re-send" "$out" 'not re-sending'
has "landed: ends [OK] dispatched" "$out" '[OK] post-merge verification dispatched'
hasnt "landed: no STUCK rename" "$(cat "$TMP/landed.log")" 'tab rename'

out=$(run_case advanced idle 12)
chk "advanced: the prompt is sent once" "$(sends advanced)" 1
hasnt "advanced: no STUCK rename" "$(cat "$TMP/advanced.log")" 'tab rename'
has "advanced: ends [OK] dispatched" "$out" '[OK] post-merge verification dispatched'

out=$(run_case never idle 10)
chk "never: the prompt is retried up to the budget" "$(sends never)" 3
has "never: the tab is renamed STUCK" "$(cat "$TMP/never.log")" 'tab rename wT:t1 pr-7-STUCK'
has "never: the stall notification fires" "$(cat "$TMP/never.log")" 'notification show'
has "never: the failure keeps its code" "$out" 'failed (timeout) — attach and run it by hand'
hasnt "never: no [OK] line" "$out" '[OK] post-merge'

out=$(run_case busy blocked 10 blocked)
chk "busy: a status held before the send is not evidence" "$(sends busy)" 3
has "busy: the tab is renamed STUCK" "$(cat "$TMP/busy.log")" 'tab rename wT:t1 pr-7-STUCK'
hasnt "busy: no [OK] line" "$out" '[OK] post-merge'

[ "$FAIL" -eq 0 ] && echo "[OK] dispatch prompt retry" || echo "[FAIL] dispatch prompt retry"
exit "$FAIL"
