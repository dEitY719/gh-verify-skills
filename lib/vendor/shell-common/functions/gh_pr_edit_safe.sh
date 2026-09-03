# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/gh_pr_edit_safe.sh
# Synced 2026-09-03T08:20Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.

#!/bin/sh
# shellcheck shell=bash
# shell-common/functions/gh_pr_edit_safe.sh
# REST-fallback wrappers for `gh pr edit` PR mutations that fail silently on
# repos with a classic GitHub Projects board attached.
#
# Background (issue #326):
# `gh pr edit` issues a GraphQL request that resolves the PR's `projectCards`
# field. After the GitHub Projects(classic) sunset (2024-05) that field is
# deprecated, and GitHub returns a deprecation warning. `gh` treats the
# warning as a fatal error → exit 1, with the requested mutation NOT applied.
# Visible symptoms: silent label drops, body-update no-ops.
#
# These helpers retry via the REST endpoint, which is GraphQL-free and
# unaffected by the deprecation. The first attempt still uses `gh pr edit`
# so repos without a classic board pay no overhead.
#
# Usage:
#   _gh_pr_edit_safe_label  <pr-number> <label>     [--repo owner/name]
#   _gh_pr_edit_safe_body   <pr-number> <body-file> [--repo owner/name]
#   _gh_pr_drop_label       <pr-number> <label> <repo> [host]
#
# Repo resolution precedence:
#   1. Explicit --repo flag
#   2. GH_REPO env var
#   3. `gh repo view --json nameWithOwner --jq .nameWithOwner` (current dir)
#
# Return codes:
#   0  — primary `gh pr edit` succeeded, OR REST fallback applied successfully
#   1  — primary failed for a non-deprecation reason (stderr passed through)
#   2  — usage error (missing args, unknown option, repo unresolved)
#   3  — REST fallback refused (label does not exist; would auto-create)
#
# Defensive checks:
#   _gh_pr_edit_safe_label validates the label exists in the repo before
#   hitting the REST endpoint. Without this guard, POST /labels would
#   auto-create a missing label silently — see project memory
#   `feedback_gh_label_no_autocreate.md`.
#
# ---------------------------------------------------------------------------
# Verdict-label invalidation — SSOT for issue #1563
# ---------------------------------------------------------------------------
# `devx_pr_review_all_write_label` is the ONLY writer of the two verdict
# labels. Since #1636 the two labels have one producer each, both routed
# through that single write primitive:
#   review-blocked — `devx:pr-review-all` Step 3.5, via
#                    `devx_pr_review_all_apply_label`: at least one reviewer
#                    lane returned a blocking verdict
#   review-passed  — `gh:pr-reply` Step 6, via
#                    `_gh_pr_reply_apply_review_passed`: every comment was
#                    replied to and no BLOCKER-severity item is unresolved
# Both prove a claim about **one specific head commit**, not about the PR in
# general. So every skill that advances a PR's head (a push of any kind) must
# invalidate them, or a stale `review-passed` survives onto code nobody read
# (reproduced twice on PR #1529, via gh:pr-resolve-outdated and
# gh:pr-resolve-conflict force-pushing over a reviewed commit).
#
# _gh_pr_drop_label is that single shared primitive. Consumers:
#   gh:pr-reply             Step 6 — `review-passed` after `git push` of the
#                           fixes (#1636's own gate handles `review-blocked`
#                           indirectly, via `devx_pr_review_all_write_label`
#                           below — never through this primitive directly)
#   gh:pr-resolve-conflict  Step 5 — after a successful --force-with-lease,
#   gh:pr-resolve-outdated  Step 5 — after a successful --force-with-lease.
#                           Both reach this primitive through
#                           `_gh_pr_resolve_outdated_reconcile_review_passed`
#                           rather than calling it directly (#1698, extended
#                           to the conflict skill by #1700) — see the
#                           asymmetry note below.
#   gh:pr-merge             Step 4 — after a successful merge (#1636). Not an
#                           invalidation but a cleanup: the PR is closed and
#                           the label has no reader left, so leaving it on
#                           only makes a reopened PR look pre-verified.
#   gh:pr-resolve-ci-fail   Step 5 — immediately after a successful
#                           fast-forward push, before Step 6's optional
#                           `--wait` (#1705, timing fixed by #1711 codex
#                           review). Calls this primitive directly, with no
#                           reconciliation: a CI-fix commit changes file
#                           content by definition, so the patch-id "keep"
#                           path the two rebase skills have can never apply.
#
# The asymmetry rule (`review-passed` drops unconditionally; `review-blocked`
# never drops through this primitive at all):
#   - `review-passed` is dropped whenever a new head invalidates "this head
#     was reviewed"; dropping is always the safe direction because absence
#     means "not verified", not "blocked". `gh:pr-reply` drops it
#     unconditionally on `PUSHED_FIXES > 0` — a fix commit is new content by
#     definition. The two rebase skills instead RECONCILE (#1698 / #1700):
#     a rebase that reproduced a byte-identical diff (same `git patch-id`)
#     under a new SHA keeps the verdict and re-stamps its #1601 freshness
#     marker for the new head, because nothing a reviewer read actually
#     changed. That keep path is gated on the `review-verdict` marker
#     proving the verdict was genuinely issued for the old head, so it
#     re-confirms an existing grant and never manufactures a new one —
#     a PR nobody reviewed has no marker and still drops.
#   - `review-blocked` is never dropped by this primitive. It is cleared only
#     as the side effect of a NEW decision, both of which delete the opposite
#     label on their way through `devx_pr_review_all_write_label`:
#     `devx:pr-review-all` aggregating an all-non-blocking round, or
#     `gh:pr-reply` gating on `_gh_pr_reply_review_passed_gate` (see
#     claude/skills/gh-pr-reply/references/review-passed-gate.md) and applying
#     `review-passed`. The rule this replaced — `gh:pr-reply` dropping it on a
#     global accepted/declined count — pinned the label whenever any OTHER
#     reviewer's non-blocking suggestion was declined (PR #1609). A rebase
#     skill holds no verdict at all, so it must leave `review-blocked` in
#     place — the safe direction, not a bug.
#   - No skill may ADD either label by hand: both go through
#     `devx_pr_review_all_write_label`. "Never self-certify" (#1563 / #1616
#     NF-2) still holds for `review-blocked`, which only an external reviewer
#     verdict can issue. #1636 DELIBERATELY RELAXED it for `review-passed`:
#     `gh:pr-reply` now applies that label from its own BLOCKER-resolution
#     judgment with no external AI CLI re-call, because that re-call was the
#     cost and failure point jamming `gh:pr-merge-train`. The findings are
#     still external — an outside reviewer raised the BLOCKERs; gh:pr-reply
#     only confirms they were resolved, and one unresolved BLOCKER still
#     means no label.
#
#     Historical note (#1634, superseded): an earlier fix made `gh:pr-reply`
#     drop `review-blocked` unconditionally once Step 5's "reply to every
#     comment" contract was satisfied — regardless of whether the reviewer's
#     own BLOCKER item was fixed or merely declined with justification. #1636
#     replaces that with the stricter rule above: an unresolved BLOCKER
#     (declined or not) always withholds `review-passed`, and `review-blocked`
#     is only ever cleared as the side effect of actually earning it.
# Consuming reference docs link here instead of restating this rule.
#
# _gh_pr_drop_label return codes:
#   0  — label removed, OR it was verifiably already absent (idempotent)
#   1  — DELETE failed, and the label is still on the issue OR the state could
#        not be verified at all (stderr of the original DELETE passed through
#        so the caller can print its own `[WARN]`)
#   2  — usage error (missing pr / label / repo)
#
# How "already absent" is decided (PR #1583 review, codex BLOCKER): NOT from
# the DELETE's own error text. GitHub answers a label that is not on the issue,
# a repo that does not exist, a PR that does not exist and a wrong GH_HOST with
# the SAME generic `Not Found (HTTP 404)`. Trusting that text would report
# success to a caller whose repo slug or host was wrong, leaving a stale
# `review-passed` alive on reviewed-away code — the exact failure #1563 exists
# to prevent. So a failed DELETE is followed by a verification GET of the
# issue's ACTUAL label list:
#   GET ok + label absent  → genuinely idempotent, rc 0, silent
#   GET ok + label present → the DELETE really failed (permissions, 5xx), rc 1
#   GET failed             → state unknown (bad repo / PR / host / auth), rc 1
# Both calls pin GH_HOST through the same subshell, so the verification reads
# the very server the DELETE was aimed at.
#
# The label is percent-encoded before it is spliced into the DELETE URL path:
# it is a path SEGMENT there (unlike the POST above, where it rides in a `-f`
# body field), so a label containing `/` or a space would otherwise build a
# malformed path (agy review, PR #1583). The verification comparison uses the
# DECODED label — the GET returns decoded names.
#
# Unlike the two wrappers above, this helper has no `gh pr edit` primary
# attempt: a REST DELETE never resolves `projectCards`, so the classic-Projects
# GraphQL deprecation path (#326) cannot fire. REST is the whole contract.
#
# NOTE: This file intentionally has NO interactive guard. It is a pure
# function-defining library (no top-level side effects) consumed by the
# `gh:pr` skill in non-interactive bash (Claude Code's Bash tool runs
# `bash --noprofile --norc`). An interactive guard would `return 0`
# before defining `_gh_pr_edit_safe_label` / `_gh_pr_edit_safe_body`,
# breaking PR body / label edits with `command not found`. Mirrors the
# same NOTE in gh_project_status.sh (PR #497). See issue #720.

# Advisory only (issue #1454, propagated by #1505): warn once on stderr when
# this file was sourced from a checkout that is a different git repo than
# $HOME/dotfiles. Never blocks, and deliberately NOT wrapped in an
# interactive guard — see the NOTE above; the guard function is itself a
# silent no-op outside the genuine foreign-checkout case.
#
# The self-path branch must stay here at file top level — zsh rebinds $0 to
# the sourced file (FUNCTION_ARGZERO) only for this file's own statements,
# and inside a function $0 is the function's own name. Plain POSIX sh has
# neither $0-rebinding nor $BASH_SOURCE, and would abort on the bash array
# syntax, hence the $BASH_VERSION arm. Everything after it lives once, in
# _dotfiles_root_guard_self.
if [ -n "${ZSH_VERSION-}" ]; then
    _drg_self="$0"
elif [ -n "${BASH_VERSION-}" ]; then
    _drg_self="${BASH_SOURCE[0]-}"
else
    _drg_self=""
fi
_drg_helper="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/dotfiles_root.sh"
if [ -r "$_drg_helper" ]; then
    . "$_drg_helper" || true
fi
if command -v _dotfiles_root_guard_self >/dev/null 2>&1; then
    _dotfiles_root_guard_self "$_drg_self" "gh_pr_edit_safe"
else
    printf '[gh_pr_edit_safe] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
unset _drg_self _drg_helper

_gh_pr_edit_safe__deprecation_marker='Projects (classic) is being deprecated'

_gh_pr_edit_safe__resolve_repo() {
    if [ -n "$1" ]; then
        printf '%s' "$1"
        return 0
    fi
    if [ -n "${GH_REPO-}" ]; then
        printf '%s' "$GH_REPO"
        return 0
    fi
    gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
}

_gh_pr_edit_safe_label() {
    local _pr="$1" _label="$2"
    [ "$#" -ge 2 ] && shift 2

    local _repo_flag=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)
                if [ -z "${2-}" ]; then
                    printf '[gh-pr-edit-safe] --repo requires an argument\n' >&2
                    return 2
                fi
                _repo_flag="$2"
                shift 2
                ;;
            *)
                printf '[gh-pr-edit-safe] unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    if [ -z "$_pr" ] || [ -z "$_label" ]; then
        printf '[gh-pr-edit-safe] usage: _gh_pr_edit_safe_label <pr> <label> [--repo owner/name]\n' >&2
        return 2
    fi

    local _repo
    _repo=$(_gh_pr_edit_safe__resolve_repo "$_repo_flag")
    if [ -z "$_repo" ]; then
        printf '[gh-pr-edit-safe] could not resolve repo (pass --repo or set GH_REPO)\n' >&2
        return 2
    fi

    local _err
    _err=$(mktemp) || return 2

    if gh pr edit "$_pr" --repo "$_repo" --add-label "$_label" >/dev/null 2>"$_err"; then
        rm -f "$_err"
        return 0
    fi

    if ! grep -q "$_gh_pr_edit_safe__deprecation_marker" "$_err"; then
        cat "$_err" >&2
        rm -f "$_err"
        return 1
    fi

    # Deprecation-warning path: validate label exists before REST fallback,
    # else POST /labels would silently create a new label (issue #326).
    if ! gh label list --repo "$_repo" --limit 200 --json name --jq '.[].name' 2>/dev/null \
        | grep -Fxq "$_label"; then
        printf '[gh-pr-edit-safe] label "%s" not in %s; refusing REST fallback (would auto-create)\n' \
            "$_label" "$_repo" >&2
        rm -f "$_err"
        return 3
    fi

    if gh api -X POST "repos/$_repo/issues/$_pr/labels" \
        -f "labels[]=$_label" >/dev/null 2>"$_err"; then
        rm -f "$_err"
        return 0
    fi

    cat "$_err" >&2
    rm -f "$_err"
    return 1
}

_gh_pr_edit_safe_body() {
    local _pr="$1" _body_file="$2"
    [ "$#" -ge 2 ] && shift 2

    local _repo_flag=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)
                if [ -z "${2-}" ]; then
                    printf '[gh-pr-edit-safe] --repo requires an argument\n' >&2
                    return 2
                fi
                _repo_flag="$2"
                shift 2
                ;;
            *)
                printf '[gh-pr-edit-safe] unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    if [ -z "$_pr" ] || [ -z "$_body_file" ]; then
        printf '[gh-pr-edit-safe] usage: _gh_pr_edit_safe_body <pr> <body-file> [--repo owner/name]\n' >&2
        return 2
    fi
    if [ ! -f "$_body_file" ]; then
        printf '[gh-pr-edit-safe] body-file not found: %s\n' "$_body_file" >&2
        return 2
    fi

    local _repo
    _repo=$(_gh_pr_edit_safe__resolve_repo "$_repo_flag")
    if [ -z "$_repo" ]; then
        printf '[gh-pr-edit-safe] could not resolve repo (pass --repo or set GH_REPO)\n' >&2
        return 2
    fi

    local _err
    _err=$(mktemp) || return 2

    if gh pr edit "$_pr" --repo "$_repo" --body-file "$_body_file" >/dev/null 2>"$_err"; then
        rm -f "$_err"
        return 0
    fi

    if ! grep -q "$_gh_pr_edit_safe__deprecation_marker" "$_err"; then
        cat "$_err" >&2
        rm -f "$_err"
        return 1
    fi

    # Build {"body": "<file-contents>"} as JSON for the REST PATCH.
    # jq --rawfile slurps the file losslessly, preserving newlines and
    # escapes that would mangle if passed via shell args.
    local _payload
    if ! _payload=$(jq -n --rawfile body "$_body_file" '{body: $body}' 2>"$_err"); then
        cat "$_err" >&2
        rm -f "$_err"
        return 1
    fi

    if printf '%s' "$_payload" | gh api -X PATCH "repos/$_repo/pulls/$_pr" \
        --input - >/dev/null 2>"$_err"; then
        rm -f "$_err"
        return 0
    fi

    cat "$_err" >&2
    rm -f "$_err"
    return 1
}

# Percent-encode one string for use as a single URL path segment (RFC 3986:
# everything but the unreserved set `A-Za-z0-9-._~` is escaped, `/` included).
# Only ever fed a label name, so the O(n) loop costs nothing; it stays in-shell
# rather than shelling out to jq/python because this file is on the `gh:pr`
# hot path. `LC_ALL=C` makes ${#s} and the substring byte-wise, so multi-byte
# UTF-8 labels encode one %XX per byte, as the RFC requires. bash/zsh only —
# same as the `local` used throughout this file (see the shell=bash directive).
_gh_pr_edit_safe__urlencode() {
    local _s="$1" _out="" _c _i=0 _len
    local LC_ALL=C
    _len=${#_s}
    while [ "$_i" -lt "$_len" ]; do
        _c=${_s:_i:1}
        case "$_c" in
            [A-Za-z0-9._~-]) _out="$_out$_c" ;;
            *)               _out="$_out$(printf '%%%02X' "'$_c")" ;;
        esac
        _i=$((_i + 1))
    done
    printf '%s' "$_out"
}

_gh_pr_drop_label() {
    local _pr="$1" _label="$2" _repo="$3" _host="${4-}"

    if [ -z "$_pr" ] || [ -z "$_label" ] || [ -z "$_repo" ]; then
        printf '[gh-pr-edit-safe] usage: _gh_pr_drop_label <pr> <label> <repo> [host]\n' >&2
        return 2
    fi

    local _err
    _err=$(mktemp) || return 2

    # The label is a URL path SEGMENT here — encode it so `/` or a space in a
    # label name cannot forge a different path (PR #1583 review).
    local _label_enc
    _label_enc=$(_gh_pr_edit_safe__urlencode "$_label")

    # `gh api` takes no --repo flag, so the repo lives in the path (#658), and
    # the host is pinned via GH_HOST so a dual-host login cannot delete the
    # label off the wrong server (#1403 / #1407). The export happens inside a
    # subshell to leave the caller's GH_HOST untouched, and is skipped when no
    # host was passed so `gh`'s own default still applies.
    if (
        if [ -n "$_host" ]; then
            # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped, per the comment above
            export GH_HOST="$_host"
        fi
        gh api -X DELETE "repos/$_repo/issues/$_pr/labels/$_label_enc"
    ) >/dev/null 2>"$_err"; then
        rm -f "$_err"
        return 0
    fi

    # The DELETE failed, and `gh` collapses every failure into one non-zero
    # exit. Its stderr cannot tell "label not on this issue" apart from "no
    # such repo / PR / host" — GitHub returns the same generic
    # `Not Found (HTTP 404)` for all of them. So don't read the error text:
    # ask the issue for its real label list, over the same pinned host.
    local _labels
    _labels=$(
        if [ -n "$_host" ]; then
            # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped, per the comment above
            export GH_HOST="$_host"
        fi
        gh api "repos/$_repo/issues/$_pr/labels" --jq '.[].name' 2>/dev/null
    ) || {
        # Verification itself failed — the issue was never reached, so the
        # DELETE's failure is NOT a benign "already absent". Never swallow.
        cat "$_err" >&2
        rm -f "$_err"
        return 1
    }

    # Compare the DECODED label: the GET returns names, not URL segments.
    if ! printf '%s\n' "$_labels" | grep -Fxq -- "$_label"; then
        # Genuinely idempotent — "already gone" is the normal, most common
        # outcome, so it stays silent (the caller prints its own `[OK]`).
        rm -f "$_err"
        return 0
    fi

    # Label still on the issue: the DELETE really did fail.
    cat "$_err" >&2
    rm -f "$_err"
    return 1
}

# Self-check (issue #724): catch silent breakage where this file sources
# cleanly but its public wrappers never get defined — interactive-guard
# regression, syntax error mid-file, future rename. Without these wrappers
# label / body edits fall back to plain `gh pr edit`, which silently exits 1
# on repos with classic Projects attached (the original #326 bug this helper
# was written to absorb). `_gh_pr_drop_label` is covered too: undefined, every
# head-advancing skill silently keeps a stale `review-passed` (#1563). rc stays
# 0 — best-effort contract preserved.
if ! command -v _gh_pr_edit_safe_label >/dev/null 2>&1 \
    || ! command -v _gh_pr_edit_safe_body >/dev/null 2>&1 \
    || ! command -v _gh_pr_drop_label >/dev/null 2>&1; then
    printf '[gh_pr_edit_safe] BUG: _gh_pr_edit_safe_{label,body} / _gh_pr_drop_label undefined after source — PR edit safe-fallback will silently no-op. See dotfiles #724.\n' >&2
fi
:
