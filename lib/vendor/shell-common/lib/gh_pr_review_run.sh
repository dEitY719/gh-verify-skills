#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_run.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_run.sh
# gh-pr-review orchestration — _gh_pr_review_main and its stage functions.
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

# _gh_pr_review_disarm_trap — shared by every INT/TERM exit path inside
# gh_pr_review (the trap body itself included) so the disarm-and-restore
# pair lives in exactly one place instead of six near-identical copies.
# Relies on bash/zsh-sh-emulation dynamic scoping to see the caller's
# `_saved_traps` local without it being passed as an argument — same
# scoping `_gh_pr_review_*` helpers already lean on throughout this file.
_gh_pr_review_disarm_trap() {
    trap - INT TERM
    [ -z "${_saved_traps-}" ] || eval "$_saved_traps"
}

# ----------------------------------------------------------------------------
# Stage functions (#2382). Each one is a step of _gh_pr_review_main and reads
# and writes the orchestrator's locals through bash/zsh dynamic scoping — the
# same mechanism _gh_pr_review_disarm_trap uses — so the locals stay declared
# (and GH_HOST stays function-local) in _gh_pr_review_main alone. A stage
# returns the status the orchestrator must return; 0 means "go on".
#
# Only the stages BEFORE the INT/TERM trap is armed, and the post stage after
# the CLI run, are split out. Temp allocation, the prompt build and the CLI
# dispatch stay inline in _gh_pr_review_main: their `cmd || { … }` and
# standalone-subshell shapes are what make a Ctrl-C report 130 under zsh
# (#1294), and a function boundary in between would change which frame the
# trap's `return 130` leaves.
# ----------------------------------------------------------------------------

# Step 1b — copy the parser's `key=value` lines into the orchestrator's locals
# ($1 = gh_pr_review_parse output). The keys are a fixed allow-list
# (ai/review/user/post_comment/pr/remote/paths); any other key is silently
# ignored. `eval "$_parsed"` would be shorter but would let a shell
# metacharacter inside a user-supplied value (e.g. `--review "$(rm -rf …)"`)
# execute — the `while read` loop treats each value as data, not code.
#   writes: ai review user post_comment pr remote paths
_gh_pr_review_stage_read_args() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _k _v
    while IFS='=' read -r _k _v; do
        case "$_k" in
        ai) ai="$_v" ;;
        review) review="$_v" ;;
        user) user="$_v" ;;
        post_comment) post_comment="$_v" ;;
        pr) pr="$_v" ;;
        remote) remote="$_v" ;;
        paths) paths="$_v" ;;
        esac
    done <<EOT
$1
EOT
}

# Step 2 — tool pre-flight: gh, git, the requested AI CLI, and gh auth for
# the remote's host.
#   reads: ai remote. writes: nothing.
_gh_pr_review_stage_preflight() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    if ! command -v gh >/dev/null 2>&1; then
        ux_error "Required CLI 'gh' not found in PATH"
        return 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        ux_error "Required CLI 'git' not found in PATH"
        return 1
    fi
    _ai_cli_require "$ai" || return $?
    _gh_pr_review_require_auth "$remote" || return 1
}

# Step 2b — resolve the target: TARGET_REPO, the GH_HOST pin, PR_NUMBER, the
# PR metadata (state/isDraft/base/head/head_sha), its state gate, and the
# claude account dir (CFG_DIR).
#   reads: ai user remote pr. writes: TARGET_REPO GH_HOST PR_NUMBER base head
#   head_sha CFG_DIR. GH_HOST MUST be a local of the caller, or the pin leaks.
_gh_pr_review_stage_resolve() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    # Resolve target repo by parsing the user-supplied remote's URL
    # directly. Bypasses `gh repo view`'s default-repo auto-detection —
    # the user-supplied `$remote` arg now actually controls the lookup
    # (issue #694 Bug C). Helper writes the actionable failure (which
    # remote, which URL) to stderr on its own; no `2>/dev/null` to
    # swallow the real cause.
    if ! TARGET_REPO=$(_gh_pr_review_resolve_target_repo "$remote"); then
        return 1
    fi
    # Writes the orchestrator's function-local GH_HOST copy: the pin
    # reaches every gh child but is restored on return, so a caller that
    # sources this file keeps its own GH_HOST.
    _gh_pr_review_pin_host "$remote"

    # Resolve PR number — explicit arg wins, otherwise auto-detect.
    if ! PR_NUMBER=$(_gh_pr_review_resolve_pr_number "$pr"); then
        return 1
    fi

    # One consolidated `gh pr view` fetches state + isDraft + base/head
    # refs + the head sha in a single round-trip; the preflight gate, the
    # diff header, and the Step 6 marker tag all consume this single JSON
    # blob (Rule 19 — fewer process forks, fewer network calls).
    local _meta state isDraft
    if ! _meta=$(_gh_pr_review_fetch_meta "$PR_NUMBER" "$TARGET_REPO"); then
        return 1
    fi
    if [ -z "$_meta" ]; then
        ux_error "PR #$PR_NUMBER could not be fetched from $TARGET_REPO"
        return 1
    fi
    state=$(printf '%s' "$_meta" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')
    isDraft=$(printf '%s' "$_meta" | sed -n 's/.*"isDraft":\(true\|false\).*/\1/p')
    base=$(printf '%s' "$_meta" | sed -n 's/.*"baseRefName":"\([^"]*\)".*/\1/p')
    head=$(printf '%s' "$_meta" | sed -n 's/.*"headRefName":"\([^"]*\)".*/\1/p')
    head_sha=$(printf '%s' "$_meta" | sed -n 's/.*"headRefOid":"\([^"]*\)".*/\1/p')

    if ! _gh_pr_review_preflight_pr_state "$PR_NUMBER" "$state" "$isDraft"; then
        return 1
    fi

    # Resolve claude account up front so an unknown name fails before
    # the (potentially long) AI CLI invocation.
    if [ "$ai" = "claude" ] && [ -n "$user" ]; then
        if ! CFG_DIR=$(_ai_cli_resolve_claude_account "$user"); then
            return 1
        fi
    fi
    return 0
}

# Step 6 + 7 — metrics, comment body, post, and the `[OK]` report line.
#   reads: PROMPT_BYTES review START_TS BODY_FILE ai AI_OUT head_sha PR_NUMBER
#   TARGET_REPO post_comment. writes: nothing outside its own locals.
_gh_pr_review_stage_post() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local TOKENS HUMAN_H ELAPSED
    TOKENS=$(_ai_cli_estimate_tokens "$PROMPT_BYTES")
    HUMAN_H=$(_gh_pr_review_human_h "$review")
    ELAPSED=$((($(date +%s) - START_TS) / 60))

    _gh_pr_review_build_comment_body "$BODY_FILE" "$ai" "$review" "$AI_OUT" \
        "$TOKENS" "$HUMAN_H" "$ELAPSED" "$head_sha"

    local COMMENT_RESULT
    COMMENT_RESULT=$(_gh_pr_review_post_comment "$PR_NUMBER" "$TARGET_REPO" \
        "$BODY_FILE" "$post_comment")

    # ---- Step 7: report ----
    printf '[OK] PR #%s reviewed by %s (--review=%s) — comment: %s\n' \
        "$PR_NUMBER" "$ai" "$review" "$COMMENT_RESULT"
}

# gh_pr_review — orchestrator. Maps SKILL.md Steps 1–7 to this function.
_gh_pr_review_main() {
    # zsh compatibility — keep the rest of the function POSIX-shaped.
    if [ -n "${ZSH_VERSION-}" ]; then
        emulate -L sh
    fi

    case "${1:-}" in
    "" | -h | --help | help)
        gh_pr_review_help
        return 0
        ;;
    esac

    local START_TS
    START_TS=$(date +%s)

    # ---- Step 1: parse args ----
    local _parsed _parse_rc _stage_rc
    _parsed=$(gh_pr_review_parse "$@")
    _parse_rc=$?
    if [ "$_parse_rc" -ne 0 ]; then
        return "$_parse_rc"
    fi
    if printf '%s\n' "$_parsed" | grep -q '^help_requested=1$'; then
        gh_pr_review_help
        return 0
    fi
    local ai="" review="" user="" post_comment="" pr="" remote="" paths=""
    _gh_pr_review_stage_read_args "$_parsed"

    # ---- Step 2: pre-flight + target resolution ----
    # Every local a stage writes is declared here, so it dies with this frame.
    # `|| _stage_rc=$?`, not a bare call + `$?`: the INT/TERM trap is not armed
    # yet, and a caller's ambient `set -e` must not exit on a failing stage.
    _stage_rc=0
    _gh_pr_review_stage_preflight || _stage_rc=$?
    [ "$_stage_rc" -eq 0 ] || return "$_stage_rc"
    local TARGET_REPO="" PR_NUMBER="" base="" head="" head_sha="" CFG_DIR=""
    local GH_HOST="${GH_HOST-}"
    _gh_pr_review_stage_resolve || return 1

    # ---- Step 3 + 4: build prompt + diff into a temp file ----
    # AI_STDERR_FILE is _ai_cli_run's stderr capture, allocated
    # here rather than inside that helper so the INT/TERM handler below can
    # reach it too (issue #1294 — see the helper's own comment).
    local PROMPT_FILE BODY_FILE AI_OUT AI_STDERR_FILE PROMPT_BYTES
    PROMPT_FILE=$(_ai_cli_mktemp_prompt "$ai" "$PR_NUMBER") || {
        ux_error "Could not create prompt temp file under /tmp"
        return 1
    }
    # Issue #1286 — interrupt cleanup. Without a trap, Ctrl-C during the
    # (potentially minutes-long) external AI CLI run, or during the
    # `gh pr diff` inside the prompt builder, unwinds this function
    # outright: none of the `rm -f` cascades below ever run and all three
    # temp files leak into /tmp. A later run that recycles the same PID
    # then hits the noclobber fallback and fails closed on its own litter.
    #
    # Installed here — right after the first successful allocation — so it
    # covers the earliest point any of the four files can exist. AI_OUT,
    # BODY_FILE and AI_STDERR_FILE are still empty strings at this instant;
    # `rm -f ""` is a documented no-op, so the single handler stays correct
    # throughout.
    #
    # The handler ends in `return 130` (128 + SIGINT) on purpose: a trap
    # action alone does NOT abort the function — both bash and zsh resume
    # at the next command after the handler returns, which would carry a
    # half-finished run into Step 6 and post a comment built from files
    # the handler just deleted.
    #
    # Issue #1294 — for that `return 130` to reach the *caller* under zsh,
    # the interrupted command must not be evaluated as a condition. zsh
    # discards a trap's return status when the signal lands in an `if` test
    # (the `if` then falls through with its own status 0), and likewise for
    # a *subshell* on the left of `||`. Measured under zsh 5.9: `if ! cmd`
    # → 0, `( … ) || rc=$?` → 0, but `cmd || rc=$?` → 130 and `( … )`
    # followed by `rc=$?` → 130. bash reports 130 for all four. So every
    # guard from here to Step 5 is written as `cmd || { … }`, and Step 5's
    # subshell stands alone with its status read on the next line; the
    # surviving `if`s only test `[ … ]`, which cannot be interrupted.
    #
    # Every `return` past this point must disarm the handler first. This
    # function is sourced into the user's interactive shell, so a leaked
    # handler would silently override their Ctrl-C at the prompt on every
    # later command — and reference locals that no longer exist.
    #
    # Disarming is `trap - INT TERM` *plus* re-arming whatever the caller
    # already had: bash traps are global to the shell, so a bare reset
    # deletes the caller's own handler as a side effect (bats' own
    # `bats_interrupt_trap` is a live example of a caller that has one).
    # zsh needs no snapshot — under `emulate -L sh` its traps are
    # function-local, so the caller's are restored on return for free.
    # Every disarm point below — including the trap body itself — goes
    # through `_gh_pr_review_disarm_trap` so the reset-plus-restore pair
    # can't drift out of sync between the six exit paths.
    local _saved_traps=""
    if [ -n "${BASH_VERSION-}" ]; then
        _saved_traps=$(
            trap -p INT
            trap -p TERM
        )
    fi
    trap 'rm -f "$PROMPT_FILE" "$AI_OUT" "$BODY_FILE" "$AI_STDERR_FILE" 2>/dev/null; _gh_pr_review_disarm_trap; return 130' INT TERM

    AI_OUT=$(_ai_cli_mktemp_safe "/tmp/gh-pr-review-out.XXXXXX") || {
        ux_error "Could not create AI output temp file under /tmp"
        _gh_pr_review_disarm_trap
        rm -f "$PROMPT_FILE"
        return 1
    }
    BODY_FILE=$(_ai_cli_mktemp_safe "/tmp/gh-pr-review-body.XXXXXX") || {
        ux_error "Could not create comment body temp file under /tmp"
        _gh_pr_review_disarm_trap
        rm -f "$PROMPT_FILE" "$AI_OUT"
        return 1
    }

    _gh_pr_review_build_prompt "$review" "$PROMPT_FILE" \
        "$PR_NUMBER" "$TARGET_REPO" "${base:-?}" "${head:-?}" "$paths" || {
        _gh_pr_review_disarm_trap
        rm -f "$PROMPT_FILE" "$AI_OUT" "$BODY_FILE"
        return 1
    }

    # Measure the prompt *now*, while the file is guaranteed to exist — it
    # was just written one line above. Step 6's token estimate used to
    # re-read PROMPT_FILE from disk, long after the AI CLI ran, and issue
    # #1474 showed the file can be gone by then (root cause still open);
    # the footer then reported a floor-1000 estimate that looked like a
    # normal small PR. Capturing the byte count here decouples the reported
    # figure from the file's lifetime. A failed read is reported, never
    # silently folded into 0 — that is the exact ambiguity #1474 was about.
    PROMPT_BYTES=$(wc -c <"$PROMPT_FILE" 2>/dev/null) || {
        echo "[WARN] Could not read prompt file for the token estimate — file missing?" >&2
        PROMPT_BYTES=0
    }

    # ---- Step 5: dispatch external AI CLI ----
    # Tee CLI stdout: stream to the user's terminal verbatim AND capture
    # it for the PR comment body. `set -o pipefail` is scoped to this
    # subshell so a non-zero exit from `_ai_cli_run` propagates
    # past the trailing `tee`; without it the pipeline always inherits
    # tee's (usually 0) exit code and the failure branch never runs.
    #
    # The CLI's stderr capture is allocated here, not inside
    # _ai_cli_run, so the handler above can delete it on Ctrl-C —
    # a helper-local path is invisible to it and leaked into /tmp
    # (issue #1294). Allocation failure is fatal for the same reason it is
    # inside the helper: without it a CLI failure has no diagnosable cause.
    AI_STDERR_FILE=$(_ai_cli_mktemp_safe "/tmp/gh-pr-review-stderr.$ai.XXXXXX") || {
        ux_error "Could not create stderr temp file under /tmp"
        _gh_pr_review_disarm_trap
        rm -f "$PROMPT_FILE" "$AI_OUT" "$BODY_FILE"
        return 1
    }
    # Standalone subshell + `$?` on the next line, per the zsh trap caveat
    # above (issue #1294 note at the trap) — do not fold this back into an `if`/`||` condition.
    # That shape is also what makes it errexit-unsafe (codex review, issue
    # #1294 follow-up): a bare compound command's non-zero status trips
    # `set -e` in the *caller's* shell before `_rc=$?` runs, skipping every
    # `disarm_trap`/`rm -f` below and leaving the INT/TERM handler armed.
    # `gh_pr_review` is sourced into interactive shells and scripts, so an
    # ambient errexit is not implausible. Suspending `-e` for just this one
    # statement keeps the standalone shape zsh needs while making the
    # caller's errexit setting irrelevant to it; `-e` is restored right
    # after `_rc` is captured.
    local _rc _had_errexit=0
    case "$-" in *e*) _had_errexit=1 ;; esac
    [ "$_had_errexit" -eq 1 ] && set +e
    (
        set -o pipefail
        _ai_cli_run "$ai" "$PROMPT_FILE" "$CFG_DIR" "$AI_STDERR_FILE" | tee "$AI_OUT"
    )
    _rc=$?
    [ "$_had_errexit" -eq 1 ] && set -e
    if [ "$_rc" -ne 0 ]; then
        _gh_pr_review_disarm_trap
        # AI_STDERR_FILE is deliberately NOT removed: a genuine CLI failure
        # leaves it for the user to inspect (the helper prints its path).
        rm -f "$PROMPT_FILE" "$AI_OUT" "$BODY_FILE"
        return "$_rc"
    fi
    # Issues #2084 / #2248: exit 0 is not a review — empty stdout or one
    # without a `판정:` / `Verdict:` line is rejected. The gate itself lives
    # in lib/ai_cli_run.sh (_ai_cli_check_output, #2381) so the issue
    # engine applies the identical rule. AI_STDERR_FILE is kept, as on the
    # failure branch above: with an empty or unfinished stdout it is the
    # only clue to what the CLI did. A verdict-less stdout is kept too — it
    # may hold real findings cut off before the last line.
    local _reject=""
    _reject=$(_ai_cli_check_output "$AI_OUT") || :
    if [ -n "$_reject" ]; then
        ux_error "External AI CLI '$ai' $_reject — no comment posted"
        echo "  full stderr saved to: $AI_STDERR_FILE" >&2
        _gh_pr_review_disarm_trap
        rm -f "$PROMPT_FILE" "$BODY_FILE"
        if grep -q '[^[:space:]]' "$AI_OUT" 2>/dev/null; then
            echo "  full stdout saved to: $AI_OUT" >&2
        else
            rm -f "$AI_OUT"
        fi
        return 1
    fi

    # ---- Step 6 + 7: post PR comment, report ----
    # A signal inside the stage runs the trap (cleanup + disarm) and leaves
    # the stage with 130; pass that on rather than reporting success.
    _gh_pr_review_stage_post
    _stage_rc=$?
    [ "$_stage_rc" -eq 0 ] || return "$_stage_rc"

    _gh_pr_review_disarm_trap
    rm -f "$PROMPT_FILE" "$AI_OUT" "$BODY_FILE" "$AI_STDERR_FILE"
    return 0
}
