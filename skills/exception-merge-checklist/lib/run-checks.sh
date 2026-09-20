#!/bin/sh
# run-checks.sh — the ten checks of gh-verify:exception-merge-checklist, run
# once as a program instead of re-derived from prose on every invocation.
#
#   BUILD_CMD='bun run build' SKIP_BISECT=0 \
#       sh "$PLUGIN_ROOT/skills/exception-merge-checklist/lib/run-checks.sh" <PR> <owner/repo>
#
# EXECUTE it, never source it: it defines helper functions, chdir's into a
# throwaway worktree for C6 and relies on `exit`, none of which belong in the
# caller's shell.
#
# Reads   $1 = PR number, $2 = owner/repo (both required)
#         BUILD_CMD    C6's per-commit command; default `bun run build`
#         SKIP_BISECT  1 makes C6 `N/A (--skip-bisect)`
#         GH_HOST      passed through to every `gh` call, unset is fine
#
# Writes  stdout: exactly ten TSV rows, C1..C10 in order —
#             <id><TAB><PASS|WARN|FAIL|N/A><TAB><note>
#         stderr: nothing, unless the helper itself could not run
#
#         and two trailing rows in the same shape, so Step 3 renders the
#         report rather than re-counting it:
#             SCORE<TAB><passed>/10<TAB><w> WARN, <f> FAIL, <na> N/A
#             VERDICT<TAB><skill-exit-code><TAB><the Verdict line, verbatim>
#         VERDICT's second field is the exit code SKILL.md's Constraints give
#         the *skill* (0 when nothing FAILed, 1 otherwise) — the helper itself
#         still exits 0, because a FAIL verdict is not a helper failure.
#
# Exit    0  ten rows were produced, whatever the verdicts. Step 2's
#            "no fail-fast" rule is this exit code: a FAIL row is data, not an
#            error, so the caller cannot accidentally stop on the first one.
#         2  harness fault — the helper could not run at all. No rows, one
#            `[FATAL]` line on stderr. Distinct from "a check reported FAIL"
#            (dEitY719/gh-verify-skills#35, the `exit 0 always` escape hatch),
#            and it reuses SKILL.md's existing exit-2 "cannot proceed" code
#            rather than inventing a fourth number.
#
# A check that cannot MEASURE is never PASS and never FAIL. Absent tooling is
# `N/A` with the reason; a tool that was there and errored is `WARN` with the
# reason. Only a check that ran and decided says PASS or FAIL — CLAUDE.md,
# "Never report a pass you did not measure".

set -u

PR="${1:-}"
TARGET_REPO="${2:-}"
BUILD_CMD="${BUILD_CMD:-bun run build}"
SKIP_BISECT="${SKIP_BISECT:-0}"

fatal() {
    printf '[FATAL] gh-verify:exception-merge-checklist: %s\n' "$1" >&2
    exit 2
}

case "$PR" in
'' | *[!0-9]*) fatal "usage: run-checks.sh <pr-number> <owner/repo> (got PR '$PR')" ;;
esac
case "$TARGET_REPO" in
*/*) ;;
*) fatal "usage: run-checks.sh <pr-number> <owner/repo> (got repo '$TARGET_REPO')" ;;
esac
command -v gh >/dev/null 2>&1 || fatal "gh is not installed; every gating check needs it"
command -v git >/dev/null 2>&1 || fatal "git is not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fatal "not inside a git worktree; C6/C9/C10 read the PR diff locally"

TMP=$(mktemp -d) || fatal "could not create a temporary directory"
# C6's worktree is removed inside its own check so a failure there is still
# reported as a verdict; this trap is the backstop for every other exit path.
trap 'rm -rf "$TMP"; [ -n "${BISECT_WT:-}" ] && git worktree remove --force "$BISECT_WT" >/dev/null 2>&1; :' EXIT

# `gh` with the host pinned, output captured, exit status preserved. Callers
# branch on the status, so a network or auth error becomes WARN, not FAIL.
# Stderr is dropped rather than captured: the checks run concurrently, so one
# shared error file would interleave, and no branch reads it — a gh failure is
# reported as the row's WARN note, not as gh's own words.
ghc() { GH_HOST="${GH_HOST:-}" gh "$@" 2>/dev/null; }

# row <id> <verdict> <note> — notes are capped at 40 characters, the width
# references/report-template.md gives the Notes column.
row() { printf '%s\t%s\t%s\n' "$1" "$2" "$(printf '%.40s' "$3")" >"$TMP/$1"; }

# --- the PR's own metadata, read once ---------------------------------------
if ! PR_JSON=$(ghc pr view "$PR" --repo "$TARGET_REPO" \
    --json body,mergeable,statusCheckRollup,reviewDecision,baseRefName); then
    PR_JSON=""
fi
have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1
jqr() { [ "$have_jq" -eq 1 ] && printf '%s' "$PR_JSON" | jq -r "$1" 2>/dev/null; }

BASE=$(jqr '.baseRefName // empty')
[ -n "$BASE" ] && git fetch --quiet origin "$BASE" >/dev/null 2>&1

# One fetch, here, rather than the three the prose blocks each did on their own:
# C6, C9 and C10 all wanted `git fetch origin $BASE`, and running them in
# parallel (which Step 2 requires) would have had three of them contend on the
# same index.lock. Serial fetch, parallel checks.

# --- C1: linked SSOT issue ---------------------------------------------------
c1() {
    [ -n "$PR_JSON" ] || { row C1 WARN "PR metadata unavailable"; return; }
    [ "$have_jq" -eq 1 ] || { row C1 WARN "jq absent"; return; }
    body=$(jqr '.body // ""')
    ref=$(printf '%s' "$body" | grep -oE '(Closes|Resolves|Fixes|Refs) #[0-9]+' | head -n 1)
    [ -n "$ref" ] || { row C1 FAIL "no Closes/Resolves/Fixes/Refs"; return; }
    kw=${ref%% *}
    n=${ref##*#}
    if ! state=$(ghc issue view "$n" --repo "$TARGET_REPO" --json state --jq .state); then
        row C1 WARN "issue #$n unreadable"
        return
    fi
    [ "$state" = OPEN ] || { row C1 FAIL "issue #$n is $state"; return; }
    # The issue is identified and OPEN, so C2 has something to look a parent up
    # on — that holds for `Refs` too, which is why this is written before the
    # WARN branch below rather than only on the PASS path.
    printf '%s' "$n" >"$TMP/ssot"
    # `Refs` is WARN not FAIL: the relation exists, but the merge will not
    # auto-close the issue.
    [ "$kw" = Refs ] && { row C1 WARN "Refs #$n does not auto-close"; return; }
    row C1 PASS "$kw #$n"
}

# --- C2: parent issue --------------------------------------------------------
c2() {
    [ -s "$TMP/ssot" ] || { row C2 "N/A" "no SSOT issue (C1)"; return; }
    n=$(cat "$TMP/ssot")
    if ibody=$(ghc issue view "$n" --repo "$TARGET_REPO" --json body --jq .body); then
        if printf '%s' "$ibody" | grep -qE 'Parent( issue)?: #[0-9]+'; then
            row C2 PASS "Parent: in issue #$n body"
            return
        fi
    fi
    if sub=$(ghc api "repos/$TARGET_REPO/issues/$n" --jq '.sub_issues_summary.total // 0'); then
        [ "${sub:-0}" -gt 0 ] 2>/dev/null && { row C2 PASS "sub-issue relation"; return; }
        row C2 WARN "no parent link on #$n"
        return
    fi
    row C2 WARN "parent lookup failed"
}

# --- C3: mergeable -----------------------------------------------------------
c3() {
    [ -n "$PR_JSON" ] || { row C3 WARN "PR metadata unavailable"; return; }
    m=$(jqr '.mergeable // empty')
    case "$m" in
    MERGEABLE) row C3 PASS "MERGEABLE" ;;
    CONFLICTING) row C3 FAIL "CONFLICTING" ;;
    UNKNOWN | '') row C3 WARN "${m:-no mergeable field}" ;;
    *) row C3 WARN "$m" ;;
    esac
}

# --- C4: all CI green --------------------------------------------------------
c4() {
    [ -n "$PR_JSON" ] || { row C4 WARN "PR metadata unavailable"; return; }
    [ "$have_jq" -eq 1 ] || { row C4 WARN "jq absent"; return; }
    total=$(jqr '.statusCheckRollup | length')
    : "${total:=0}"
    [ "$total" -eq 0 ] && { row C4 "N/A" "no status checks"; return; }
    bad=$(jqr '[.statusCheckRollup[]
        | select((.conclusion // "") | IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED"))] | length')
    run=$(jqr '[.statusCheckRollup[]
        | select((.conclusion // "") == "") ] | length')
    [ "${bad:-0}" -gt 0 ] && { row C4 FAIL "$bad/$total not SUCCESS"; return; }
    [ "${run:-0}" -gt 0 ] && { row C4 WARN "$run/$total still running"; return; }
    row C4 PASS "$total/$total checks SUCCESS"
}

# --- C5: review APPROVED -----------------------------------------------------
c5() {
    [ -n "$PR_JSON" ] || { row C5 WARN "PR metadata unavailable"; return; }
    d=$(jqr '.reviewDecision // ""')
    case "$d" in
    APPROVED) row C5 PASS "APPROVED" ;;
    REVIEW_REQUIRED | CHANGES_REQUESTED) row C5 FAIL "$d" ;;
    '')
        # Empty means "no review decision to make". On a protected branch that
        # is still a gap; on an unprotected one it is the solo-repo case
        # gh-pr:merge already treats as WARN.
        if ghc api "repos/$TARGET_REPO/branches/$BASE/protection" >/dev/null; then
            row C5 WARN "protected but no decision"
        else
            row C5 WARN "branch unprotected"
        fi
        ;;
    *) row C5 WARN "$d" ;;
    esac
}

# --- C6: bisect-safe (per-commit build) — serial, walks every commit ---------
c6() {
    [ "$SKIP_BISECT" = 1 ] && { row C6 "N/A" "--skip-bisect"; return; }
    [ -n "$BASE" ] || { row C6 "N/A" "base branch unknown"; return; }
    git rev-parse --verify --quiet "origin/$BASE" >/dev/null || {
        row C6 "N/A" "origin/$BASE not fetched"
        return
    }
    # Never silently switch the build command (SKILL.md constraint): when the
    # default was not overridden and the repo has no `build` script, say so.
    if [ "$BUILD_CMD" = 'bun run build' ]; then
        if ! command -v bun >/dev/null 2>&1; then
            row C6 "N/A" "bun absent, no --build-cmd"
            return
        fi
        if [ ! -f package.json ] || ! grep -q '"build"' package.json 2>/dev/null; then
            row C6 "N/A" "no bun run build target"
            return
        fi
    fi
    BISECT_WT="$TMP/bisect"
    if ! git worktree add --detach "$BISECT_WT" HEAD >/dev/null 2>&1; then
        row C6 WARN "could not create worktree"
        BISECT_WT=""
        return
    fi
    if (cd "$BISECT_WT" && git rebase --exec "$BUILD_CMD" "origin/$BASE" >"$TMP/c6.log" 2>&1); then
        row C6 PASS "every commit builds"
    else
        (cd "$BISECT_WT" && git rebase --abort >/dev/null 2>&1) || :
        sha=$(grep -oE '[0-9a-f]{7,40}' "$TMP/c6.log" | head -n 1)
        row C6 FAIL "broken at ${sha:-unknown commit}"
    fi
    git worktree remove --force "$BISECT_WT" >/dev/null 2>&1 || :
    BISECT_WT=""
}

# --- C7: openapi.yaml parses -------------------------------------------------
c7() {
    spec=""
    for f in openapi.yaml ./*.openapi.yaml; do
        [ -f "$f" ] && { spec="$f"; break; }
    done
    [ -n "$spec" ] || { row C7 "N/A" "no openapi.yaml"; return; }
    command -v bunx >/dev/null 2>&1 || { row C7 "N/A" "bunx absent"; return; }
    # lsof is the portable listener probe (ss/netstat are GNU-only). Without it
    # the scan is skipped and the default port is used, which is a worse guess
    # but not a reason to skip the check.
    PORT=""
    if command -v lsof >/dev/null 2>&1; then
        p=4010
        while [ "$p" -le 4099 ]; do
            lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || { PORT=$p; break; }
            p=$((p + 1))
        done
    fi
    : "${PORT:=4010}"
    log="$TMP/prism.log"
    bunx @stoplight/prism-cli mock "$spec" --port "$PORT" >"$log" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 30 ]; do
        grep -q 'listening' "$log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
        i=$((i + 1))
    done
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
    if grep -q 'listening' "$log" 2>/dev/null; then
        row C7 PASS "Prism boot ${i}s"
    else
        row C7 FAIL "Prism never listened (${i}s)"
        cp "$log" "$TMP/c7.detail" 2>/dev/null || :
    fi
}

# --- C8: .openapi-lock matches -----------------------------------------------
c8() {
    [ -f .openapi-lock ] || { row C8 "N/A" "no .openapi-lock"; return; }
    command -v sha256sum >/dev/null 2>&1 || { row C8 "N/A" "sha256sum absent"; return; }
    if sha256sum -c .openapi-lock >"$TMP/c8.log" 2>&1; then
        row C8 PASS "lock matches"
    else
        row C8 FAIL "sha mismatch — regenerate"
    fi
}

# --- C9: prettier scope clean ------------------------------------------------
c9() {
    [ -n "$BASE" ] || { row C9 "N/A" "base branch unknown"; return; }
    git rev-parse --verify --quiet "origin/$BASE" >/dev/null || {
        row C9 "N/A" "origin/$BASE not fetched"
        return
    }
    git diff --name-only "origin/$BASE..HEAD" -- \
        '*.md' '*.json' '*.yml' '*.yaml' >"$TMP/c9.files" 2>/dev/null || :
    [ -s "$TMP/c9.files" ] || { row C9 "N/A" "no doc files changed"; return; }
    command -v bunx >/dev/null 2>&1 || { row C9 "N/A" "bunx absent"; return; }
    n=$(wc -l <"$TMP/c9.files" | tr -d ' ')
    # xargs, not $(...): a large PR's file list can exceed ARG_MAX. No `-r` —
    # that is GNU-only, and the `[ -s ]` above already proved the list non-empty.
    if xargs bunx prettier --check <"$TMP/c9.files" >"$TMP/c9.log" 2>&1; then
        row C9 PASS "$n doc file(s) clean"
    else
        row C9 FAIL "$n doc file(s), format drift"
    fi
}

# --- C10: test mocks complete ------------------------------------------------
c10() {
    [ -n "$BASE" ] || { row C10 "N/A" "base branch unknown"; return; }
    git rev-parse --verify --quiet "origin/$BASE" >/dev/null || {
        row C10 "N/A" "origin/$BASE not fetched"
        return
    }
    [ -d apps ] || { row C10 "N/A" "no apps/ tree"; return; }
    # Streamed, never captured: a large diff must not become a shell variable.
    if git diff "origin/$BASE..HEAD" -- 'apps/**/*.ts' 'apps/**/*.tsx' \
        ':!**/*.test.*' ':!**/*.spec.*' 2>/dev/null |
        grep -qE '^\+.*(cookies\(\)|headers\(\)|new NextRequest\()'; then
        if git diff "origin/$BASE..HEAD" -- \
            '**/*.test.ts' '**/*.test.tsx' '**/*.spec.ts' '**/*.spec.tsx' 2>/dev/null |
            grep -qE "^\+.*(vi\.mock\('next/headers'|vi\.mocked\((cookies|headers)\)|new NextRequest\()"; then
            row C10 PASS "new calls have mocks"
        else
            # Deliberately false-positive-prone: a WARN here is much cheaper
            # than missing the regression (checks.md C10 rationale, R6).
            row C10 WARN "new framework calls, no mocks"
        fi
    else
        row C10 PASS "no new framework calls"
    fi
}

# Step 2's run order, enforced here rather than by instruction: C1-C5 and
# C7-C10 are independent and run together; C6 walks every commit and is
# serial. C2 waits on C1 because it reads the issue number C1 resolved.
: >"$TMP/ssot"
(
    c1
    c2
) &
c3 &
c4 &
c5 &
c7 &
c8 &
c9 &
c10 &
wait
c6

pass=0
warn=0
fail=0
na=0
for id in C1 C2 C3 C4 C5 C6 C7 C8 C9 C10; do
    if [ -s "$TMP/$id" ]; then
        line=$(cat "$TMP/$id")
    else
        # A check that produced no row at all is a bug in this file, not a
        # verdict. Say so in the row rather than silently shipping nine.
        line=$(printf '%s\tWARN\t%s' "$id" "check produced no verdict")
    fi
    printf '%s\n' "$line"
    case "$line" in
    *"$(printf '\t')PASS$(printf '\t')"*) pass=$((pass + 1)) ;;
    *"$(printf '\t')WARN$(printf '\t')"*) warn=$((warn + 1)) ;;
    *"$(printf '\t')FAIL$(printf '\t')"*) fail=$((fail + 1)) ;;
    *) na=$((na + 1)) ;;
    esac
done

# The aggregation lives here so Step 3 only renders. references/checks.md ->
# "Result aggregation" and references/report-template.md -> "Verdict
# computation" state the same rule in prose; run-checks.selfcheck.sh pins it.
printf 'SCORE\t%d/10\t%d WARN, %d FAIL, %d N/A\n' "$pass" "$warn" "$fail" "$na"
if [ "$fail" -eq 0 ]; then
    printf 'VERDICT\t0\tsafe to merge\n'
else
    printf 'VERDICT\t1\t%d FAIL, %d WARN — NOT safe to merge\n' "$fail" "$warn"
fi

exit 0
