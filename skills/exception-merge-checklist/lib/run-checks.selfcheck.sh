#!/usr/bin/env bash
# Self-check for lib/run-checks.sh — the verdict matrix in
# references/checks.md, run rather than read:
#
#   bash skills/exception-merge-checklist/lib/run-checks.selfcheck.sh
#
# No network, no gh auth, no live PR. `gh` is a shell script on a temporary
# PATH that answers from environment variables this file sets, and the repo
# under audit is a throwaway git tree — so every check's real control flow
# runs and only the one external program is faked. The four checks that need
# a Next.js/OpenAPI-shaped tree (C6-C10) are exercised through their N/A
# degradation paths, which is what the issue asked for: absent tooling must
# never read as FAIL.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
TARGET="$ROOT/skills/exception-merge-checklist/lib/run-checks.sh"
FAIL=0

command -v jq >/dev/null 2>&1 || { echo "FAIL  jq is required by lib/run-checks.sh and by this check"; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

chk() { # chk <label> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"; FAIL=1; fi
}
has() { case "$2" in *"$3"*) chk "$1" yes yes ;; *) chk "$1" "$2" "contains: $3" ;; esac; }

# --- the fake `gh` -----------------------------------------------------------
# GH_FAIL lists sub-commands that must fail, which is how the "tool was there
# and errored" rows (WARN, never FAIL) get exercised.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/sh
case " ${GH_FAIL:-} " in *" $1 "*) echo "gh: forced failure" >&2; exit 1 ;; esac
case "$1 ${2:-}" in
    "pr view")    printf '%s\n' "${GH_PR_JSON:?}" ;;
    "issue view") case " $* " in *" state "*) printf '%s\n' "${GH_ISSUE_STATE:-OPEN}" ;;
                                *) printf '%s\n' "${GH_ISSUE_BODY:-}" ;; esac ;;
    "api "*)      case "${2:-}" in
                      */protection) [ -n "${GH_PROTECTED:-}" ] || exit 1 ;;
                      *) printf '%s\n' "${GH_SUB_ISSUES:-0}" ;;
                  esac ;;
    *) exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# --- the repo under audit ----------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo hello > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -qm first
# `origin/main` without a network: a second repo cloned locally.
git -C "$REPO" remote add origin "$REPO/.git" 2>/dev/null || :

pr_json() { # pr_json <body> <mergeable> <rollup-json> <reviewDecision>
    BODY="$1" MERGE="$2" ROLL="$3" RD="$4" jq -nc \
        '{body: env.BODY, mergeable: env.MERGE, statusCheckRollup: (env.ROLL|fromjson), reviewDecision: env.RD, baseRefName: "main"}'
}

GREEN='[{"name":"a","conclusion":"SUCCESS"},{"name":"b","conclusion":"SUCCESS"}]'
RED='[{"name":"a","conclusion":"SUCCESS"},{"name":"b","conclusion":"FAILURE"}]'
RUNNING='[{"name":"a","conclusion":"SUCCESS"},{"name":"b","conclusion":""}]'

run() { # run <pr-json> [extra env assignments...] -> OUT, RC
    local payload="$1"; shift
    OUT=$(cd "$REPO" && env PATH="$TMP/bin:$PATH" GH_PR_JSON="$payload" \
        SKIP_BISECT="${SKIP_BISECT:-1}" "$@" sh "$TARGET" 42 acme/widget 2>&1)
    RC=$?
}
verdict() { printf '%s\n' "$OUT" | awk -F'\t' -v id="$1" '$1==id {print $2}'; }
note()    { printf '%s\n' "$OUT" | awk -F'\t' -v id="$1" '$1==id {print $3}'; }

# --- 1. shape: ten rows plus SCORE and VERDICT, in order, exit 0 -------------
CLEAN=$(pr_json 'Closes #7' MERGEABLE "$GREEN" APPROVED)
run "$CLEAN"
chk "clean run exits 0"      "$RC" 0
chk "row order is C1..C10, SCORE, VERDICT" \
    "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')" \
    "C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 SCORE VERDICT "
chk "every row is 3 TSV fields" \
    "$(printf '%s\n' "$OUT" | awk -F'\t' 'NF!=3' | wc -l | tr -d ' ')" 0
chk "every verdict is in the vocabulary" \
    "$(printf '%s\n' "$OUT" | head -10 | awk -F'\t' '$2!="PASS" && $2!="WARN" && $2!="FAIL" && $2!="N/A"' | wc -l | tr -d ' ')" 0
chk "notes fit the 40-char Notes column" \
    "$(printf '%s\n' "$OUT" | head -10 | awk -F'\t' 'length($3)>40' | wc -l | tr -d ' ')" 0

# --- 2. harness faults: exit 2, one [FATAL] line, no rows --------------------
fatal() { # fatal <label> <args...>
    local label="$1"; shift
    OUT=$(cd "$REPO" && env PATH="$TMP/bin:$PATH" GH_PR_JSON="$CLEAN" sh "$TARGET" "$@" 2>&1); RC=$?
    chk "$label exits 2" "$RC" 2
    chk "$label emits no rows" "$(printf '%s\n' "$OUT" | grep -c '^C[0-9]')" 0
    has "$label says FATAL" "$OUT" '[FATAL]'
}
fatal "no arguments"
fatal "non-numeric PR" not-a-number acme/widget
fatal "repo without a slash" 42 widget
mkdir -p "$TMP/empty"
OUT=$(cd "$REPO" && env PATH="$TMP/empty" GH_PR_JSON="$CLEAN" /bin/sh "$TARGET" 42 acme/widget 2>&1); RC=$?
chk "gh absent exits 2" "$RC" 2
has "gh absent names gh" "$OUT" 'gh is not installed'
OUT=$(cd "$TMP" && env PATH="$TMP/bin:$PATH" GH_PR_JSON="$CLEAN" sh "$TARGET" 42 acme/widget 2>&1); RC=$?
chk "outside a git worktree exits 2" "$RC" 2

# --- 3. C1 / C2: the SSOT issue link -----------------------------------------
run "$CLEAN"
chk "C1 PASS on Closes"      "$(verdict C1)" PASS
run "$(pr_json 'Refs #7' MERGEABLE "$GREEN" APPROVED)"
chk "C1 WARN on Refs"        "$(verdict C1)" WARN
has "C1 says why Refs warns" "$(note C1)" 'does not auto-close'
run "$(pr_json 'no link at all' MERGEABLE "$GREEN" APPROVED)"
chk "C1 FAIL with no keyword" "$(verdict C1)" FAIL
chk "C2 N/A when C1 found nothing" "$(verdict C2)" "N/A"
run "$CLEAN" GH_ISSUE_STATE=CLOSED
chk "C1 FAIL when the issue is CLOSED" "$(verdict C1)" FAIL
run "$CLEAN" GH_FAIL=issue
chk "C1 WARN when the issue is unreadable" "$(verdict C1)" WARN
run "$CLEAN" GH_ISSUE_BODY='Parent: #3'
chk "C2 PASS on a Parent: line" "$(verdict C2)" PASS
run "$CLEAN" GH_SUB_ISSUES=2
chk "C2 PASS on a sub-issue relation" "$(verdict C2)" PASS
run "$CLEAN" GH_SUB_ISSUES=0
chk "C2 WARN with no parent link" "$(verdict C2)" WARN

# --- 4. C3 / C4 / C5: the gating verdicts ------------------------------------
run "$(pr_json 'Closes #7' CONFLICTING "$GREEN" APPROVED)"
chk "C3 FAIL on CONFLICTING" "$(verdict C3)" FAIL
run "$(pr_json 'Closes #7' UNKNOWN "$GREEN" APPROVED)"
chk "C3 WARN on UNKNOWN"     "$(verdict C3)" WARN
run "$(pr_json 'Closes #7' MERGEABLE "$RED" APPROVED)"
chk "C4 FAIL on a failing job" "$(verdict C4)" FAIL
run "$(pr_json 'Closes #7' MERGEABLE "$RUNNING" APPROVED)"
chk "C4 WARN while CI runs"  "$(verdict C4)" WARN
run "$(pr_json 'Closes #7' MERGEABLE '[]' APPROVED)"
chk "C4 N/A with no status checks" "$(verdict C4)" "N/A"
run "$(pr_json 'Closes #7' MERGEABLE "$GREEN" CHANGES_REQUESTED)"
chk "C5 FAIL on CHANGES_REQUESTED" "$(verdict C5)" FAIL
run "$(pr_json 'Closes #7' MERGEABLE "$GREEN" '')"
chk "C5 WARN on an unprotected branch" "$(verdict C5)" WARN
has "C5 names the unprotected case"    "$(note C5)" 'unprotected'
run "$(pr_json 'Closes #7' MERGEABLE "$GREEN" '')" GH_PROTECTED=1
has "C5 distinguishes protected-but-undecided" "$(note C5)" 'protected but no decision'

# --- 5. an unreachable `gh` is WARN everywhere, never FAIL, and still exits 0 -
run "$CLEAN" GH_FAIL=pr
chk "gh pr view failure still exits 0" "$RC" 0
for id in C1 C3 C4 C5; do chk "$id WARN when the PR read failed" "$(verdict $id)" WARN; done
chk "no FAIL is invented from an unreadable PR" \
    "$(printf '%s\n' "$OUT" | head -10 | grep -c "$(printf '\tFAIL\t')")" 0

# --- 6. absent tooling degrades to N/A with a reason, never FAIL -------------
run "$CLEAN"
chk "C6 N/A under --skip-bisect"   "$(verdict C6)" "N/A"
chk "C6 says --skip-bisect"        "$(note C6)" "--skip-bisect"
chk "C7 N/A with no openapi.yaml"  "$(verdict C7)" "N/A"
chk "C8 N/A with no .openapi-lock" "$(verdict C8)" "N/A"
chk "C10 N/A with no apps/ tree"   "$(verdict C10)" "N/A"
for id in C6 C7 C8 C9 C10; do
    [ -n "$(note $id)" ] || { printf 'FAIL  %s N/A carries no reason\n' "$id"; FAIL=1; }
done
SKIP_BISECT=0 run "$CLEAN"
chk "C6 N/A rather than FAIL when there is no build target" "$(verdict C6)" "N/A"

# --- 7. the aggregation: SCORE and VERDICT ----------------------------------
# All-green metadata in a bare repo: C1-C5 decide, C6-C10 are N/A.
run "$CLEAN" GH_SUB_ISSUES=2
chk "SCORE counts the PASS rows"   "$(verdict SCORE)" "5/10"
has "SCORE counts the N/A rows"    "$(note SCORE)"    "0 WARN, 0 FAIL, 5 N/A"
chk "VERDICT gives the skill exit 0 with no FAIL" "$(verdict VERDICT)" 0
chk "VERDICT line is the template's"              "$(note VERDICT)" "safe to merge"
run "$(pr_json 'Closes #7' CONFLICTING "$RED" CHANGES_REQUESTED)" GH_SUB_ISSUES=2
chk "three FAILs leave two PASS"   "$(verdict SCORE)" "2/10"
has "WARN and FAIL both counted"   "$(note SCORE)"    "0 WARN, 3 FAIL, 5 N/A"
chk "VERDICT gives the skill exit 1 on any FAIL" "$(verdict VERDICT)" 1
has "VERDICT wording matches report-template.md" "$(note VERDICT)" "3 FAIL, 0 WARN — NOT safe to merge"
chk "the helper still exits 0 on a FAIL verdict" "$RC" 0
# A mixed board: WARN must be counted separately from PASS and from FAIL, and
# WARN alone must never flip the verdict (checks.md -> "Result aggregation").
run "$(pr_json 'Refs #7' UNKNOWN "$GREEN" APPROVED)" GH_SUB_ISSUES=2
has "WARN rows are counted"          "$(note SCORE)"   "2 WARN, 0 FAIL, 5 N/A"
chk "WARN rows are not counted as PASS" "$(verdict SCORE)" "3/10"
chk "WARN alone keeps the skill exit 0" "$(verdict VERDICT)" 0
chk "WARN alone is still safe to merge" "$(note VERDICT)" "safe to merge"

# --- 8. the same under every shell a harness might invoke it with ------------
for sh in sh bash zsh dash; do
    command -v "$sh" >/dev/null 2>&1 || { printf 'skip  %s not installed\n' "$sh"; continue; }
    got=$(cd "$REPO" && env PATH="$TMP/bin:$PATH" GH_PR_JSON="$CLEAN" SKIP_BISECT=1 \
        "$sh" "$TARGET" 42 acme/widget 2>/dev/null | cut -f1 | tr '\n' ' ')
    chk "$sh: emits the full row set" "$got" "C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 SCORE VERDICT "
done

# --- 9. doc-to-script drift guard -------------------------------------------
# references/run-checks.sh.md ships the call Step 2 pastes. Extract it from the
# shipped file and RUN it, so a reworded variable or a renamed flag fails here
# rather than at merge time in somebody's audit.
#
# The Step 1 values arrive as plain shell variables, not exported ones, because
# that is what Step 1 leaves behind — and it is the only way the block's own
# `VAR=... sh` forwarding is observable. Exporting them would let the script
# read them whether or not the block passed them on, which is exactly the
# drift this guard exists to catch.
awk '/^```sh$/ {on = 1; next} on && /^```$/ {exit} on' \
    "$ROOT/skills/exception-merge-checklist/references/run-checks.sh.md" > "$TMP/call.sh"
[ -s "$TMP/call.sh" ] || { echo "FAIL  run-checks.sh.md ships no sh block"; FAIL=1; }

paste_block() { # paste_block <skip-bisect> [plugin-root-or-empty] -> OUT, RC
    local skip="$1" root="${2-$ROOT}"
    local pre="PR=42; TARGET_REPO=acme/widget; SKIP_BISECT=$skip; BUILD_CMD='bun run build'; . \"\$1\""
    if [ -n "$root" ]; then
        OUT=$(cd "$REPO" && env PATH="$TMP/bin:$PATH" GH_PR_JSON="$CLEAN" \
            CLAUDE_PLUGIN_ROOT="$root" sh -c "$pre" _ "$TMP/call.sh" 2>&1)
    else
        OUT=$(cd "$ROOT" && env -u CLAUDE_PLUGIN_ROOT -u GH_VERIFY_ROOT \
            PATH="$TMP/bin:$PATH" GH_PR_JSON="$CLEAN" sh -c "$pre" _ "$TMP/call.sh" 2>&1)
    fi
    RC=$?
}

paste_block 1
chk "the shipped Step 2 block runs"       "$RC" 0
chk "the shipped block emits the row set" "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')" \
    "C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 SCORE VERDICT "
# SKIP_BISECT is observable in C6's note, so these two runs pin the block's
# forwarding of it — rename the variable in the doc and they stop agreeing.
chk "the shipped block forwards SKIP_BISECT=1" \
    "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="C6" {print $3}')" "--skip-bisect"
paste_block 0
chk "the shipped block forwards SKIP_BISECT=0" \
    "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="C6" {print $3}')" "no bun run build target"
# PR and TARGET_REPO reaching the script is observable as it not exiting 2.
chk "the shipped block forwards both positionals" "$RC" 0

# Tier 5: with no plugin root it must stop and name the way out, never compose
# a path from the cwd — which for this skill is the repository under audit
# (harness-skills#22). $ROOT genuinely holds the script, and that must not help.
paste_block 1 ""
chk "the shipped block stops with no plugin root" "$RC" 1
has "and names the way out" "$OUT" 'export CLAUDE_PLUGIN_ROOT'
chk "and emits no rows"     "$(printf '%s\n' "$OUT" | grep -c '^C[0-9]')" 0

[ "$FAIL" -eq 0 ] && echo "[OK] lib/run-checks.sh verdict matrix" || echo "[FAIL] lib/run-checks.sh"
exit "$FAIL"
