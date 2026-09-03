# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/gh_project_status.sh
# Synced 2026-09-03T08:20Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.

#!/bin/sh
# shellcheck shell=bash
# shell-common/functions/gh_project_status.sh
# Push a projectV2 Status transition for an Issue or PR. Auto-discovers every
# projectV2 the target belongs to; for each project that has a "Status" field
# with an option matching the target name, updates the item's Status to that
# option.
#
# Failure is always quiet (returns 0) — the caller's primary job is shipping
# code, not board bookkeeping. Boards in repos that have no projectV2 attached
# (e.g. side projects without a board) are auto-detected: the helper finds
# zero project items and silently returns 0.
#
# Opt out with GH_PROJECT_STATUS_SYNC=0. The legacy gh-flow-era variable
# GH_FLOW_PROJECT_STATUS_SYNC=0 is still honored for backwards compatibility.
#
# Usage:
#   _gh_project_status_sync <issue|pr> <number> <target-status> \
#       [--only-from <list>] [--repo <owner/repo>]
#
# Examples:
#   _gh_project_status_sync issue 42 "In progress"
#   _gh_project_status_sync pr    17 "In review"
#   _gh_project_status_sync issue 42 "In progress" --only-from Backlog
#   _gh_project_status_sync issue 42 "In progress" --repo dEitY719/dotfiles
#
# Repo resolution (issue #1405), first hit wins:
#   1. --repo <owner/repo>   (explicit caller intent; an EMPTY value is
#                            treated as "not supplied" and falls through)
#   2. $GH_REPO              (gh's own override var; HOST/OWNER/REPO allowed)
#   3. $TARGET_REPO          (the gh:* skills' remote-pinning convention)
#   4. `gh repo view --json owner,name`  (auto-detect fallback)
#
# Why the explicit forms come first: a bare `gh repo view` answers "what did
# `gh repo set-default` pick", NOT "what is git's origin". In a working tree
# whose host serves several remotes/repos that can silently sync the wrong
# repo's board. An explicitly-supplied but malformed slug fails closed instead
# of falling through to auto-detect — a typo must not be masked by
# re-acquiring some other repo. The resolver reports that as rc 2 (vs rc 1 for
# a failed auto-detect) so the sync can skip its retry sleep: re-parsing the
# same bad string cannot produce a different answer.
#
# --only-from <list>: comma-separated whitelist of CURRENT Status values.
# If the item's current Status is not in the list, the transition is skipped
# for that project. Used to prevent regression — e.g. /gh-commit must not
# bounce an issue from "In review" back to "In progress" when a follow-up
# fix commit lands. Status names with internal spaces are supported
# ("Backlog,In progress"); do not pad with spaces around the comma.
#
# Verify pair (race absorption, issue #393):
# After every successful mutation the helper sleeps
# _GH_PROJECT_STATUS_VERIFY_SLEEP seconds (default 1) and re-queries the
# current Status. If the value reverted (a builtin workflow such as
# "Pull request linked to issue" overwrote our write asynchronously), the
# mutation is re-issued once. A second mismatch fails loud on stderr but
# still returns 0 to honor the helper's best-effort policy. Override
# _GH_PROJECT_STATUS_VERIFY_SLEEP=0 in tests to skip the wait.
#
# Fail-closed guard (issue #393, defense-in-depth):
# kind=pr + target="Approved" requires the PR's reviewDecision to equal
# APPROVED (looked up via `gh pr view --json reviewDecision`). Any other
# decision — REVIEW_REQUIRED, CHANGES_REQUESTED, or an unreachable gh —
# rejects the transition with exit code 2. Set
# _GH_PROJECT_STATUS_GUARD_APPROVED_BYPASS=1 for an emergency bypass.
# Other targets (In review / Done / Backlog / etc.) and kind=issue are
# never gated.
#
# Return codes:
#   0 — success / no-op / best-effort skip (network flake, no project, etc.)
#   2 — fail-closed policy rejection (Approved guard)
#
# NOTE: This file intentionally has NO interactive guard. It is a pure
# function-defining library (no top-level side effects) consumed by
# .github/workflows/project-board-sync.yml in non-interactive bash
# (`bash --noprofile --norc`). An interactive guard would `return 0`
# before defining `_gh_project_status_sync`, breaking the workflow with
# `command not found` (exit 127). See PR #497 / CI run 25601743398.

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
    _dotfiles_root_guard_self "$_drg_self" "gh_project_status"
else
    printf '[gh_project_status] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
unset _drg_self _drg_helper

# Ensure GH_HOST is set before any `gh` call so requests route to the
# correct host. On the internal PC (GHE = github.samsungds.net) a caller
# that does not export GH_HOST would otherwise let `gh` default to
# github.com, silently failing every ProjectV2 lookup and skipping the
# board sync (issue #804). We source the gh_host.sh SSOT and resolve the
# host via `_gh_resolve_host`, which maps `_dotfiles_setup_mode` to the
# right domain. A caller that already exported GH_HOST (an explicit host
# override) is left untouched -> regression-zero for github.com users.
_gh_project_status_ensure_host() {
    # Already set: still export it. A caller may have assigned GH_HOST as a
    # plain (non-exported) shell variable, in which case downstream `gh`
    # subprocesses would not inherit it without this export.
    if [ -n "${GH_HOST-}" ]; then
        export GH_HOST
        return 0
    fi
    # shellcheck disable=SC1091
    . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/gh_host.sh" 2>/dev/null || return 0
    if command -v _gh_resolve_host >/dev/null 2>&1; then
        GH_HOST=$(_gh_resolve_host)
        export GH_HOST
    fi
}

_gh_project_status_sync() {
    local _kind="$1" _num="$2" _target="$3"
    [ "$#" -ge 3 ] && shift 3

    local _only_from="" _repo_opt=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --only-from)
                if [ -z "${2-}" ]; then
                    printf '[gh-project-status] --only-from requires an argument\n' >&2
                    return 0
                fi
                _only_from="$2"
                shift 2
                ;;
            --repo)
                if [ "$#" -lt 2 ]; then
                    printf '[gh-project-status] --repo requires an argument\n' >&2
                    return 0
                fi
                # An explicitly EMPTY value means "no pin": fall through to the
                # $GH_REPO / $TARGET_REPO / auto-detect levels instead of
                # skipping the whole sync. Callers pass "$SOME_VAR" whose
                # binding can legitimately come back empty -- e.g.
                # claude/hooks/post-gh-pr-create.sh resolves GH_REPO from a
                # `gh repo view` that may transiently flake -- and turning that
                # into a hard skip would defeat this helper's own #341 retry.
                # A NON-empty but malformed slug still fails closed (#1405).
                _repo_opt="$2"
                shift 2
                ;;
            *)
                printf '[gh-project-status] unknown option: %s\n' "$1" >&2
                return 0
                ;;
        esac
    done

    # Opt-out: either env var disables the sync.
    if [ "${GH_PROJECT_STATUS_SYNC-1}" = "0" ] \
        || [ "${GH_FLOW_PROJECT_STATUS_SYNC-1}" = "0" ]; then
        return 0
    fi
    if [ -z "$_kind" ] || [ -z "$_num" ] || [ -z "$_target" ]; then
        return 0
    fi

    # Route every downstream `gh` call (repo view, pr view, graphql) to the
    # correct host before the first one fires (issue #804).
    _gh_project_status_ensure_host

    local _q_field
    case "$_kind" in
        issue) _q_field='issue' ;;
        pr) _q_field='pullRequest' ;;
        *)
            printf '[gh-project-status] invalid kind=%s, skipping\n' "$_kind" >&2
            return 0
            ;;
    esac

    # Resolve owner/repo (precedence documented in the file header, #1405),
    # with one 5s retry on transient failure of the `gh repo view` fallback
    # (e.g. graphql socket reset). Mirrors the mutation step's retry —
    # without it, a single transient `gh repo view` flake silently aborts
    # the whole sync (issue #341). Override _GH_PROJECT_STATUS_RETRY_SLEEP
    # in tests to skip the wait. Only rc 1 (auto-detect) is retried: rc 2 is
    # a malformed explicit pin, where the retry would re-parse the same
    # string and fail identically after sleeping for nothing (#1405).
    #
    # This block runs BEFORE the Approved guard so the guard's `gh pr view`
    # can carry an explicit --repo (#1405). A resolution failure must NOT
    # short-circuit the guard — that would turn a fail-closed policy check
    # into a fail-open skip — so on total failure we leave _resolved empty
    # and defer the "skipping" bail-out to after the guard.
    local _owner="" _repo="" _resolved="" _rrc=0
    _resolved=$(_gh_project_status_resolve_owner_repo "$_repo_opt") || { _rrc=$?; _resolved=""; }
    if [ "$_rrc" = "1" ]; then
        sleep "${_GH_PROJECT_STATUS_RETRY_SLEEP-5}"
        _resolved=$(_gh_project_status_resolve_owner_repo "$_repo_opt") || _resolved=""
    fi
    if [ -n "$_resolved" ]; then
        _owner="${_resolved%% *}"
        _repo="${_resolved#* }"
    fi

    # Fail-closed guard (issue #393): only an APPROVED PR may land in the
    # "Approved" column. Other Statuses are unaffected. UNKNOWN (gh pr view
    # failure, or an unresolved repo) is treated as non-APPROVED — preferring
    # a loud refusal over a possibly-incorrect mutation. Bypass via
    # _GH_PROJECT_STATUS_GUARD_APPROVED_BYPASS=1 (explicit operator intent).
    #
    # There is deliberately NO bare `gh pr view` fallback when the repo did
    # not resolve (PR #1409 review, codex BLOCKER). A bare call reads whatever
    # `gh repo set-default` picked, so it would answer with the reviewDecision
    # of a DIFFERENT repo's PR #<num> — and a coincidental APPROVED there would
    # open this fail-closed gate on an unreviewed PR. That is the exact
    # wrong-repo read #1405 exists to remove, so an unresolved repo is simply
    # UNKNOWN: refuse, and name the reason.
    if [ "$_kind" = "pr" ] \
        && [ "$_target" = "Approved" ] \
        && [ "${_GH_PROJECT_STATUS_GUARD_APPROVED_BYPASS-0}" != "1" ]; then
        local _decision
        if [ -n "$_owner" ]; then
            _decision=$(gh pr view "$_num" --repo "$_owner/$_repo" \
                        --json reviewDecision \
                        --jq '.reviewDecision? // empty' 2>/dev/null) \
                || _decision="UNKNOWN"
        else
            printf '[gh-project-status] cannot verify PR #%s approval: owner/repo unresolved — refusing "Approved"\n' \
                "$_num" >&2
            _decision="UNKNOWN"
        fi
        if [ -z "$_decision" ]; then
            _decision="UNKNOWN"
        fi
        if [ "$_decision" != "APPROVED" ]; then
            printf '[gh-project-status] refusing PR #%s -> "Approved": reviewDecision=%s\n' \
                "$_num" "$_decision" >&2
            printf '[gh-project-status]   bypass: _GH_PROJECT_STATUS_GUARD_APPROVED_BYPASS=1\n' >&2
            return 2
        fi
    fi

    # Deferred bail-out: the guard has had its say, so an unresolvable
    # owner/repo now degrades to the historical best-effort skip.
    if [ -z "$_resolved" ]; then
        printf '[gh-project-status] could not determine owner/repo, skipping\n' >&2
        return 0
    fi

    # Single query: per projectV2 item, return
    #   project.id | item.id | field.id | target_option.id | current_status_name
    # The current_status_name is needed for --only-from gating.
    #
    # Variables: $owner String!, $repo String!, $number Int!, $target String!
    local _records
    _records=$(gh api graphql \
        -f query="
          query(\$owner: String!, \$repo: String!, \$number: Int!, \$target: String!) {
            repository(owner: \$owner, name: \$repo) {
              ${_q_field}(number: \$number) {
                projectItems(first: 10) {
                  nodes {
                    id
                    fieldValueByName(name: \"Status\") {
                      ... on ProjectV2ItemFieldSingleSelectValue { name }
                    }
                    project {
                      id
                      field(name: \"Status\") {
                        ... on ProjectV2SingleSelectField {
                          id
                          options(names: [\$target]) { id name }
                        }
                      }
                    }
                  }
                }
              }
            }
          }" \
        -f owner="$_owner" -f repo="$_repo" -F number="$_num" -f target="$_target" \
        --jq ".data.repository.${_q_field}.projectItems.nodes[]
              | select(.project?.field?.options? | length > 0)
              | \"\(.project?.id)|\(.id)|\(.project?.field?.id)|\(.project?.field?.options?[0]?.id)|\(.fieldValueByName?.name? // \"\")\"" \
        2>/dev/null) || {
        printf '[gh-project-status] query failed for %s #%s (target=%s)\n' \
            "$_kind" "$_num" "$_target" >&2
        return 0
    }

    if [ -z "$_records" ]; then
        printf '[gh-project-status] %s #%s not in any project with "%s" option\n' \
            "$_kind" "$_num" "$_target" >&2
        return 0
    fi

    # Avoid subshell — heredoc instead of pipe (zsh/bash tracing parity).
    local _proj _item _field _option _current
    while IFS='|' read -r _proj _item _field _option _current; do
        [ -z "$_proj" ] && continue

        # --only-from guard: skip when current Status is not in the whitelist.
        if [ -n "$_only_from" ] \
            && ! _gh_project_status_in_list "$_current" "$_only_from"; then
            printf '[gh-project-status] %s #%s skipped (current="%s" not in only-from="%s")\n' \
                "$_kind" "$_num" "$_current" "$_only_from" >&2
            continue
        fi

        # Mutate + verify pair (issue #393). Retry-on-flake (5s, _RETRY_SLEEP)
        # and verify-then-re-set (1s, _VERIFY_SLEEP) live in the helper so
        # this loop body stays focused on per-project gating.
        _gh_project_status_set_and_verify \
            "$_kind" "$_num" "$_proj" "$_item" "$_field" "$_option" "$_target" \
            "$_owner/$_repo"
    done <<EOF
$_records
EOF

    return 0
}

# Run the projectV2 Status mutation, then verify the value stuck via a single
# follow-up GraphQL read. If a builtin workflow ("Pull request linked to
# issue", "Item closed", etc.) overwrote our write asynchronously, re-issue
# the mutation once. A second mismatch fails loud on stderr but still
# returns 0 — the helper's contract with callers is best-effort.
#
# Args: kind num proj item field option target [owner/repo]
#   The optional 8th positional pins the repo for the verify read (#1405).
#   Without it the verify would re-resolve via `gh repo view` and could read
#   a different repo's board than the one the mutation just wrote to.
# Returns: 0 (always — preserves the helper's best-effort policy).
#
# Sleep knobs:
#   _GH_PROJECT_STATUS_RETRY_SLEEP — wait between mutation attempts on flake
#                                    (default 5).
#   _GH_PROJECT_STATUS_VERIFY_SLEEP — wait before each verify read so the
#                                     builtin workflow has time to fire and
#                                     be observed (default 1).
# Both default to 0 in bats tests via env override.
_gh_project_status_set_and_verify() {
    local _kind="$1" _num="$2"
    local _proj="$3" _item="$4" _field="$5" _option="$6" _target="$7"
    local _repo_arg="${8-}"
    local _actual _retry_label=''

    if ! _gh_project_status_mutate "$_proj" "$_item" "$_field" "$_option"; then
        sleep "${_GH_PROJECT_STATUS_RETRY_SLEEP-5}"
        if ! _gh_project_status_mutate "$_proj" "$_item" "$_field" "$_option"; then
            printf '[gh-project-status] mutation failed for %s #%s (target=%s)\n' \
                "$_kind" "$_num" "$_target" >&2
            return 0
        fi
        _retry_label=' after 1 retry'
    fi

    # Verify pair as a 2-attempt loop: sleep → query → compare. If attempt 1
    # mismatches, log the race and re-mutate before attempt 2. A third
    # attempt is intentionally not made — it would risk a write-loop with
    # the builtin workflow. Always returns 0 (best-effort policy, #393).
    local _attempt
    for _attempt in 1 2; do
        sleep "${_GH_PROJECT_STATUS_VERIFY_SLEEP-1}"
        _actual=$(_gh_project_status_query_current "$_kind" "$_num" "$_repo_arg")

        if [ "$_actual" = "$_target" ]; then
            if [ "$_attempt" -eq 1 ]; then
                printf '[gh-project-status] %s #%s -> "%s" (verified%s)\n' \
                    "$_kind" "$_num" "$_target" "$_retry_label"
            else
                printf '[gh-project-status] %s #%s -> "%s" (verified after re-set)\n' \
                    "$_kind" "$_num" "$_target"
            fi
            return 0
        fi

        if [ "$_attempt" -eq 2 ]; then
            printf '[gh-project-status] ERROR: %s #%s verify failed twice (target="%s", actual="%s"). Manual intervention may be needed.\n' \
                "$_kind" "$_num" "$_target" "$_actual" >&2
            return 0
        fi

        # Race observed — re-set once before the second verify attempt.
        printf '[gh-project-status] %s #%s reverted to "%s", re-setting...\n' \
            "$_kind" "$_num" "$_actual" >&2
        if ! _gh_project_status_mutate "$_proj" "$_item" "$_field" "$_option"; then
            printf '[gh-project-status] ERROR: re-set mutation failed for %s #%s\n' \
                "$_kind" "$_num" >&2
            return 0
        fi
    done
}

# Best-effort read of the current Status for an issue/PR. Returns the first
# non-empty Status value found across the item's project memberships — for
# multi-board items the verify pair only checks one board's value, but every
# board runs the same builtin workflows so observing one race surface is
# sufficient for the recovery contract.
#
# Args: kind num [owner/repo]
#   The optional third positional pins the repo (issue #1405). It is handed
#   straight to _gh_project_status_resolve_owner_repo, so it accepts both
#   "OWNER/REPO" and "HOST/OWNER/REPO" and, when omitted/empty, falls back to
#   $GH_REPO -> $TARGET_REPO -> `gh repo view` auto-detect. A malformed
#   explicit value is a resolution failure, reported as rc 1 below (the
#   resolver's own rc 2 is folded in), never a silent fallback to
#   auto-detect.
# Output (stdout): current Status name, or nothing.
# Returns (four-way contract, issues #1354 and #1356):
#   0 + non-empty stdout — query succeeded, item has a Status value.
#   0 + empty stdout     — query succeeded but there is nothing to report:
#                          no projectV2 attached, item not on a board, or no
#                          Status field set. A legitimate "no board" answer.
#   1 + empty stdout     — the query itself failed for a generic reason:
#                          owner/repo resolution failed, the GraphQL read
#                          call below exited non-zero on a network/5xx/other
#                          error, or the caller passed empty/invalid args.
#                          Callers that gate on board state MUST fail closed
#                          here instead of treating it as "no board".
#   2 + empty stdout     — the query failed specifically because the `gh`
#                          token lacks the `project` (read:project) OAuth
#                          scope: GitHub answers the projectItems lookup
#                          with "insufficient scopes" / "Resource not
#                          accessible" no matter whether a board is even
#                          attached. Split out from rc 1 (#1356) so callers
#                          can tell the operator exactly what to fix instead
#                          of printing a generic "query failed". Still a
#                          failure — callers fail closed here too.
# Missing/invalid args (empty kind/num, or an unrecognized kind) also
# return 1 — a caller bug here must not be indistinguishable from "no
# board attached", or a gate built on this helper would silently open
# on its own misuse. Reviewer follow-up, PR #1355 (agy).
_gh_project_status_query_current() {
    local _kind="$1" _num="$2" _repo_arg="${3-}"
    [ -z "$_kind" ] && return 1
    [ -z "$_num" ] && return 1

    # Public entry point (gh-issue-implement 3.4 F-2 duplicate-status warning,
    # #1507; post-gh-pr-create.sh's PR-card poll) — also route to the
    # correct host when invoked directly without GH_HOST (issue #804).
    _gh_project_status_ensure_host

    local _q_field
    case "$_kind" in
        issue) _q_field='issue' ;;
        pr) _q_field='pullRequest' ;;
        *) return 1 ;;
    esac

    local _owner _repo _resolved
    # Resolution failure is a query failure, not "no board" (#1354). That
    # includes a malformed explicit repo argument (#1405) — callers gate on
    # board state and must fail closed here.
    _resolved=$(_gh_project_status_resolve_owner_repo "$_repo_arg") || return 1
    _owner="${_resolved%% *}"
    _repo="${_resolved#* }"

    # Substitute gh's output into a variable, then filter it — a
    # `gh ... | head -n 1` pipeline would report head's exit status, not
    # gh's, and the POSIX Golden Rules rule out ${PIPESTATUS[0]} (#1354).
    local _raw _nl _gql_query _gql_jq _gql_err
    _gql_query="
          query(\$owner: String!, \$repo: String!, \$number: Int!) {
            repository(owner: \$owner, name: \$repo) {
              ${_q_field}(number: \$number) {
                projectItems(first: 10) {
                  nodes {
                    fieldValueByName(name: \"Status\") {
                      ... on ProjectV2ItemFieldSingleSelectValue { name }
                    }
                  }
                }
              }
            }
          }"
    _gql_jq=".data.repository.${_q_field}.projectItems.nodes[]
              | .fieldValueByName?.name?
              | select(. != null and . != \"\")"

    # Variables: $owner String!, $repo String!, $number Int!
    if ! _raw=$(gh api graphql -f query="$_gql_query" \
        -f owner="$_owner" -f repo="$_repo" -F number="$_num" \
        --jq "$_gql_jq" \
        2>/dev/null); then
        # Do NOT merge stderr into the primary capture above: `gh` can write
        # update-notifier / proxy-warning noise to stderr even on a
        # *successful* call, which would corrupt _raw on the happy path
        # (agy review, PR #1357). Re-run stderr-only, read-only, purely to
        # classify the failure — rc 2 vs rc 1, see the contract above (#1356).
        # Variables: $owner String!, $repo String!, $number Int!
        _gql_err=$(gh api graphql -f query="$_gql_query" \
            -f owner="$_owner" -f repo="$_repo" -F number="$_num" \
            --jq "$_gql_jq" \
            2>&1 1>/dev/null)
        case "$_gql_err" in
            *"insufficient scopes"*|*"Resource not accessible"*) return 2 ;;
            *) return 1 ;;
        esac
    fi

    [ -z "$_raw" ] && return 0
    # First line only — projectItems(first: 10) can yield multiple rows.
    # Plain parameter expansion instead of `| head -n 1` to skip the fork.
    _nl='
'
    printf '%s\n' "${_raw%%"$_nl"*}"
}

# Normalize a repo slug into "<owner> <repo>" (issue #1405).
#
# Accepts "OWNER/REPO" or "HOST/OWNER/REPO" — the same two forms gh's own
# GH_REPO env var allows, so an operator can reuse a value they already
# export for `gh`. The host segment is validated but dropped: host routing
# is _gh_project_status_ensure_host's job, and the GraphQL calls downstream
# want owner + name separately.
#
# Args: <value>
# Output (stdout): "<owner> <repo>".
# Returns: 0 on success, 1 on anything that is not a valid slug — empty,
#          no slash, more than three segments, or any empty segment.
_gh_project_status_normalize_repo() {
    local _val="$1"

    case "$_val" in
        # Empty host segment, or four-plus segments (`*/*/*/*` needs three
        # slashes) — neither is a slug gh would accept either.
        /*|*/*/*/*) return 1 ;;
        # HOST/OWNER/REPO — drop the host segment.
        */*/*) _val="${_val#*/}" ;;
        # OWNER/REPO — already the wanted shape.
        */*) ;;
        # No slash at all, empty value included.
        *) return 1 ;;
    esac
    # Empty owner (`/repo`, only reachable via the host-stripped form) or
    # empty repo (`owner/`).
    case "$_val" in /*|*/) return 1 ;; esac

    printf '%s %s\n' "${_val%%/*}" "${_val#*/}"
    return 0
}

# Resolve the target GitHub owner/repo. Prints "<owner> <repo>" on success.
#
# Returns (split so callers can tell a retryable failure from a hopeless one):
#   1 — the `gh repo view` auto-detect failed (gh exit, empty or partial
#       output). Transient causes are common (socket reset), so this is the
#       one worth retrying (#341).
#   2 — an explicit value ($1 / $GH_REPO / $TARGET_REPO) is a malformed slug.
#       Deterministic: a retry re-parses the same string and fails the same
#       way, so retrying it would be pure latency.
#
# Args: [<repo>]  — optional explicit "OWNER/REPO" or "HOST/OWNER/REPO".
#
# Precedence, first non-empty wins (issue #1405):
#   1. $1        (explicit caller intent, e.g. sync's --repo)
#   2. $GH_REPO
#   3. $TARGET_REPO
#   4. `gh repo view --json owner,name`
#
# The first three go through _gh_project_status_normalize_repo and fail
# closed on a malformed value — deliberately NOT falling through to the
# auto-detect fallback. A bare `gh repo view` reports whatever
# `gh repo set-default` chose, not git's origin, so masking a typo'd slug
# with auto-detect could sync a completely different repo's board.
#
# Extracted so the auto-detect step in _gh_project_status_sync can mirror
# the mutation step's single-retry pattern (issue #341): without retry, one
# transient `gh repo view` socket reset silently aborts the sync.
_gh_project_status_resolve_owner_repo() {
    local _output _owner _repo _explicit=""

    if [ -n "${1-}" ]; then
        _explicit="$1"
    elif [ -n "${GH_REPO-}" ]; then
        _explicit="$GH_REPO"
    elif [ -n "${TARGET_REPO-}" ]; then
        _explicit="$TARGET_REPO"
    fi
    if [ -n "$_explicit" ]; then
        _gh_project_status_normalize_repo "$_explicit" || return 2
        return 0
    fi

    # Output contract is space-separated "<owner> <repo>", and callers split
    # it back on whitespace. That round-trip is safe only because GitHub
    # owner and repo names cannot contain whitespace (alphanumerics, `-`,
    # `_`, `.` only) — it is not a general-purpose serialization, and this
    # is the reason it does not need to be one (PR #1409 review, agy).
    _output=$(gh repo view --json owner,name --jq '"\(.owner.login) \(.name)"' 2>/dev/null) || return 1
    [ -z "$_output" ] && return 1
    if ! read -r _owner _repo <<EOF
$_output
EOF
    then
        return 1
    fi
    [ -z "$_owner" ] && return 1
    [ -z "$_repo" ] && return 1
    printf '%s %s\n' "$_owner" "$_repo"
    return 0
}

# Run the projectV2 Status mutation. Args: proj, item, field, option (all ids).
# Extracted to a helper so the loop can retry it once without duplicating
# the multi-line GraphQL query block. Stays silent — caller logs outcomes.
_gh_project_status_mutate() {
    # GraphQL variables ($proj, $item, ...) are NOT shell vars — they
    # are bound via the -f flags below, so single quotes are intended.
    # Variables: $proj ID!, $item ID!, $field ID!, $option String!
    # shellcheck disable=SC2016
    gh api graphql \
        -f query='
          mutation($proj: ID!, $item: ID!, $field: ID!, $option: String!) {
            updateProjectV2ItemFieldValue(input: {
              projectId: $proj
              itemId: $item
              fieldId: $field
              value: { singleSelectOptionId: $option }
            }) { clientMutationId }
          }' \
        -f proj="$1" -f item="$2" -f field="$3" -f option="$4" \
        >/dev/null 2>&1
}

# Print one closing-issue number per line for PR <num> in <owner/repo>.
# Stays silent on every failure mode (boards-not-set-up, GraphQL errors,
# missing args, malformed repo) so the caller's for-loop just iterates over
# nothing and the merge report is never blocked.
#
# Why this is a helper instead of `gh pr view --json closingIssuesReferences`:
# the `--json` projection on `gh` 2.45.0 does not list
# `closingIssuesReferences` in its allow-list — invoking it prints
# "Unknown JSON field" and exits non-zero (#264). The GraphQL schema has the
# connection so we go around the CLI's allow-list with a direct query.
#
# Args: <pr-number> <owner/repo>
_gh_pr_closing_issue_numbers() {
    local _pr="$1" _repo="$2"
    [ -z "$_pr" ] && return 0
    [ -z "$_repo" ] && return 0
    case "$_repo" in
        */*) ;;
        *) return 0 ;;
    esac
    local _owner _name
    _owner="${_repo%/*}"
    _name="${_repo#*/}"
    [ -z "$_owner" ] && return 0
    [ -z "$_name" ] && return 0

    # GraphQL variables ($owner, $repo, $num) are bound via the -f/-F flags
    # below, so single quotes around the query are intentional.
    # Variables: $owner String!, $repo String!, $num Int!
    # shellcheck disable=SC2016
    gh api graphql \
        -f owner="$_owner" -f repo="$_name" -F num="$_pr" \
        -f query='query($owner: String!, $repo: String!, $num: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $num) {
              closingIssuesReferences(first: 20) { nodes { number } }
            }
          }
        }' \
        --jq '.data.repository?.pullRequest?.closingIssuesReferences?.nodes[]?.number // empty' \
        2>/dev/null
    return 0
}

# Membership test: returns 0 when $1 equals any comma-separated entry of $2.
# Uses pure parameter expansion to keep Status names with internal spaces
# (e.g. "In progress") intact. Empty $1 never matches.
_gh_project_status_in_list() {
    local _val="$1" _list="$2"
    [ -z "$_val" ] && return 1
    case ",${_list}," in
        *",${_val},"*) return 0 ;;
    esac
    return 1
}

# Self-check (issue #724): catch silent breakage where this file is sourceable
# but a canonical function never gets defined — interactive-guard regression,
# syntax error inside a function block, future rename without updating
# callers, partial sourcing in a foreign env. Callers like /gh-commit and
# /gh-pr source the file then invoke the function with `|| true`, which
# absorbs `command not found` (rc 127) into a silent no-op and hides the
# breakage from the operator. Prints one stderr line per missing name; rc
# stays 0 so the helper's best-effort contract with `|| true` callers is
# preserved — never `return` out of the loop, that would break that contract
# and skip the remaining names.
#
# The list is data rather than a hardcoded `if` chain (#1421) so that adding
# a name costs one line and the warning can say *which* function is missing.
# A name earns a slot by being called from outside this file, or by being a
# dependency of one that is:
#   - _gh_project_status_sync          (write API; used by every gh-* skill)
#   - _gh_project_status_query_current (read API; gh-issue-implement 3.4 F-2
#     warning + post-gh-pr-create.sh's PR-card poll, #1507/#1513;
#     rc 0 = answered — value or "no board", rc 1 = query failed,
#     rc 2 = query failed on a missing `project` scope, see #1354/#1356)
#   - _gh_project_status_normalize_repo (slug parser; called cross-file by
#     claude/hooks/post-gh-pr-create.sh since #1405, and internally by
#     _gh_project_status_resolve_owner_repo — so `sync` and `query_current` are
#     functionally broken without it even while they stay defined. That is
#     the converse the old three-name check wrongly assumed, #1421)
#   - _gh_pr_closing_issue_numbers     (PR→issue link; gh-pr, gh-pr-merge)
# If any one is missing the helper is broken as a whole — fail loudly.
# Per gemini-code-assist review on PR #725; list extended per #1421.
for _gh_ps_selfcheck_fn in \
    _gh_project_status_sync \
    _gh_project_status_query_current \
    _gh_project_status_normalize_repo \
    _gh_pr_closing_issue_numbers; do
    command -v "$_gh_ps_selfcheck_fn" >/dev/null 2>&1 && continue
    printf '[gh_project_status] BUG: %s undefined after source — board sync / closing-issue link will silently no-op. See dotfiles #724.\n' \
        "$_gh_ps_selfcheck_fn" >&2
done
unset _gh_ps_selfcheck_fn
:
