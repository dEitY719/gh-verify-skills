#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/devx_pr_review_all.sh
# Synced 2026-09-05T10:16Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/functions/devx_pr_review_all.sh
# Pure arg parser for the devx:pr-review-all skill. Mirrors the
# gh_pr_review_parse contract: one `key=value` line per resolved arg on
# success, errors to stderr. Exit 0 ok/help, exit 2 arg error. Runtime
# checks (PR state, gh auth, CLI presence) belong to the skill body.
#
# This file lives under shell-common/functions/, so it is auto-sourced into
# the user's interactive shell. Every variable the parser assigns is `local`
# (house style here — see gh_pr_review.sh) so a call cannot clobber the
# user's `$pr` / `$remote`. Callers read the stdout `key=value` contract,
# never the shell variables.

# Advisory only (issue #1454, propagated by #1505): warn once on stderr when
# this file was sourced from a checkout that is a different git repo than
# $HOME/dotfiles. Never blocks, and deliberately NOT wrapped in an
# interactive guard — this is a pure function-defining library that
# non-interactive skill callers rely on; the guard function is itself a
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
    _dotfiles_root_guard_self "$_drg_self" "devx_pr_review_all"
else
    printf '[devx_pr_review_all] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
unset _drg_self _drg_helper

devx_pr_review_all_parse() {
    local pr=""
    local remote="origin"
    local reply_mode="inline"
    local reply_delay="8"
    local _no_reply=0
    local _remote_set=0
    local _force_review=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --defer-reply)
            [ "$#" -lt 2 ] && {
                echo "missing value for --defer-reply" >&2
                return 2
            }
            reply_delay="$2"
            reply_mode="defer"
            shift 2
            ;;
        --defer-reply=*)
            reply_delay="${1#--defer-reply=}"
            reply_mode="defer"
            shift
            ;;
        --no-reply)
            _no_reply=1
            shift
            ;;
        --force-review)
            _force_review=1
            shift
            ;;
        -h | --help | help)
            echo "help_requested=1"
            return 0
            ;;
        --*)
            echo "Unknown flag: $1" >&2
            return 2
            ;;
        *)
            if [ -z "$pr" ]; then
                pr="$1"
            elif [ "$_remote_set" -eq 0 ]; then
                remote="$1"
                _remote_set=1
            else
                echo "Unexpected positional arg: $1" >&2
                return 2
            fi
            shift
            ;;
        esac
    done

    case "$pr" in
    "")
        echo "missing required arg: <PR#>" >&2
        return 2
        ;;
    *[!0-9]*)
        echo "PR# must be a positive integer: '$pr'" >&2
        return 2
        ;;
    *[!0]*) ;;
    *)
        echo "PR# must be a positive integer: '$pr'" >&2
        return 2
        ;;
    esac

    if [ "${_no_reply:-0}" -eq 1 ]; then
        reply_mode="none"
    elif [ "$reply_mode" = "defer" ]; then
        case "$reply_delay" in
        "" | *[!0-9]*)
            echo "--defer-reply value must be a positive integer" >&2
            return 2
            ;;
        *[!0]*) ;;
        *)
            echo "--defer-reply value must be a positive integer" >&2
            return 2
            ;;
        esac
    fi

    printf '%s\n' "pr=$pr"
    printf '%s\n' "remote=$remote"
    printf '%s\n' "reply_mode=$reply_mode"
    printf '%s\n' "reply_delay=$reply_delay"
    printf '%s\n' "force_review=$_force_review"
    return 0
}

# ── Review verdict -> merge-gate label (issue #1527, fixed in #1562) ──
#
# Turns a reviewer lane's mandatory closing verdict line (`판정: ...` /
# `Verdict: ...`, rendered at runtime by `_gh_pr_review_common_prefix` in
# gh_pr_review.sh) into a label the merge train can gate on. Full rationale —
# the PR #1518 incident, the zsh word-splitting bug, the call-site contract —
# lives in claude/skills/devx-pr-review-all/references/review-verdict-label.md,
# which is the SSOT; this is the implementation.
#
#   devx_pr_review_all_lane_block <ai> [<head-sha>] <expected-login>  # raw
#     comments JSON on stdin (#1639) -> that lane's raw block, or nothing
#   devx_pr_review_all_verdict                       # lane output on stdin
#     -> blocking | concerns | lgtm | unknown
#   devx_pr_review_all_aggregate                     # verdict tokens on stdin,
#     -> label=review-blocked | label=review-passed | label=   (+ lanes=N)
#   devx_pr_review_all_apply_label <pr> <repo> [host] [head-sha] # verdict
#     tokens on stdin -> aggregates, then writes the label to the PR. One
#     `[OK]`/`[WARN]` line. Since #1636 it only ever WRITES `review-blocked`;
#     a non-blocking aggregate clears `review-blocked` and hands the
#     `review-passed` decision to `gh:pr-reply` — see that function's header.
#   devx_pr_review_all_write_label <label> <pr> <repo> [host] [head-sha]
#     -> the shared, verdict-free write primitive both producers use:
#     drop-opposite, add via `_gh_pr_edit_safe_label`, and (for
#     `review-passed` with a sha) the #1601 freshness marker. Machine-readable
#     `add=`/`marker=` tokens on stdout — see that function's header.
#   devx_pr_review_all_already_reviewed <ai> <head-sha> <expected-login>
#     # raw comments JSON on stdin (#1639) -> rc 0 when that lane already
#     posted a block for this exact head (#1613 duplicate-review guard) —
#     see that function's header.
#
# devx_pr_review_all_aggregate reads stdin, NOT positional args — load-bearing,
# not stylistic; see the doc for the zsh bug that forces it.
# devx_pr_review_all_apply_label takes the same stream for the same reason.
#
# Skipped lanes contribute NO line — "not checked" and "checked and passed"
# must never collapse into the same state (#1527 확정 사항).

devx_pr_review_all_verdict() {
    local _line _value _bracket_inner

    # Normalize before matching: fullwidth colon -> ASCII, strip the markdown
    # a reviewer may wrap the line in, drop a leading list dash. Then keep
    # only lines that *start* with the verdict key — a finding line like
    # `[BLOCKER] a.sh:1 — ...` must never be mistaken for the verdict.
    # Last one wins: the presets require the verdict to be the final line.
    _line=$(
        sed -e 's/：/:/g' -e 's/[*`_#>]//g' \
            -e 's/^[[:space:]]*-[[:space:]]*//' -e 's/^[[:space:]]*//' |
            grep -iE '^(판정|verdict)[[:space:]]*:' |
            tail -n 1
    )

    if [ -z "$_line" ]; then
        printf 'unknown\n'
        return 0
    fi

    _value=$(
        printf '%s\n' "$_line" |
            sed -e 's/^[^:]*://' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    )

    # The unanswered preset template echoed back verbatim is not a verdict.
    # Its signature is the bracketed alternation `[A|B|C]` — the pipe sits
    # INSIDE the first bracket pair. Checking for `[` and `|` anywhere in the
    # value (PR #1573 review, agy FOLLOW-UP) misclassified a real verdict
    # with a bracketed trailing detail, e.g. `[BLOCKING] | [5 findings]`, as
    # the template. Extract only the first bracket group's content and test
    # that for a pipe.
    case "$_value" in
    '['*)
        _bracket_inner=$(printf '%s\n' "$_value" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
        case "$_bracket_inner" in
        *'|'*)
            printf 'unknown\n'
            return 0
            ;;
        esac
        ;;
    esac

    _value=$(
        printf '%s\n' "$_value" |
            sed -e 's/[][]//g' -e 's/^[[:space:]]*//' |
            tr '[:lower:]' '[:upper:]'
    )

    case "$_value" in
    블로킹* | BLOCKING*) printf 'blocking\n' ;;
    우려있음* | CONCERNS*) printf 'concerns\n' ;;
    LGTM*) printf 'lgtm\n' ;;
    *) printf 'unknown\n' ;;
    esac
}

devx_pr_review_all_aggregate() {
    local _lanes=0 _blocking=0 _unresolved=0 _v _label

    # `|| [ -n "$_v" ]` so a final line with no trailing newline still counts.
    while IFS= read -r _v || [ -n "$_v" ]; do
        [ -n "$_v" ] || continue
        _lanes=$((_lanes + 1))
        case "$_v" in
        blocking) _blocking=1 ;;
        lgtm | concerns) ;;
        # `unknown` and anything unrecognized are the same thing: the lane
        # ran but its verdict could not be established. Fail closed.
        *) _unresolved=1 ;;
        esac
    done

    if [ "$_blocking" -eq 1 ]; then
        _label="review-blocked"
    elif [ "$_lanes" -eq 0 ] || [ "$_unresolved" -eq 1 ]; then
        _label=""
    else
        _label="review-passed"
    fi

    printf '%s\n' "label=$_label"
    printf '%s\n' "lanes=$_lanes"
    return 0
}

# Author filter for the marker readers below (#1639).
#
#   <raw comments JSON on stdin> | _devx_pr_review_all_login_bodies <login>
#     stdout: the `.body` of every comment whose `.user.login` is exactly
#     <login>, one body after another. Empty (rc 0) when nothing matches,
#     when <login> fails validation, or when stdin is not the expected JSON.
#
# Why a jq prefilter rather than each reader doing its own `gh api` lookup the
# way `_gh_pr_merge_train_review_passed_marker_sha` does: these readers are
# called once PER REVIEWER LANE against the SAME comment dump, which the
# caller fetches exactly once (see SKILL.md Step 3 / 3.5). Making them
# network-aware would multiply that one fetch by the lane count on every run —
# the fan-out cost #1636 was filed to contain. So the JSON arrives on stdin,
# already paid for, and the author check is a local `jq` pass over it.
#
# `--arg` (not a string-built filter): the login lands in jq as a DATA value,
# so a hostile login cannot close the filter's quoting and inject jq of its
# own. The validation below is belt-and-braces on top of that.
#
# Validation mirrors `_gh_pr_merge_train_review_passed_marker_sha` exactly —
# a plain GitHub username (`[A-Za-z0-9-]+`) or that same shape carrying a
# literal `[bot]` suffix, the form GitHub gives App identities in
# `.user.login` (`github-actions[bot]`). Rejecting brackets outright would
# make any bot-authenticated pipeline unable to trust a single one of its own
# markers. An empty or invalid login yields EMPTY output — never a fallback
# to "match every author", which is the whole vulnerability being closed.
#
# stdin is drained in full before any early return, so a producer piping into
# this never takes an EPIPE on the reject path. Validation never touches
# stdin, so it runs first; only the reject branch needs an explicit drain —
# on the accept branch `jq` reads stdin straight through to EOF itself, so
# buffering it into a shell variable first would just be a wasted copy.
_devx_pr_review_all_login_bodies() {
    local _login="${1-}" _base

    _base="$_login"
    case "$_base" in
        *'[bot]') _base="${_base%\[bot\]}" ;;
    esac
    case "$_base" in
        '' | *[!A-Za-z0-9-]*)
            cat >/dev/null
            return 0
            ;;
    esac

    # A missing `jq` binary silently fails the whole verdict/review-passed
    # gate closed on every PR, forever, with nothing on stderr to explain why
    # (PR #1641 review, codex FOLLOW-UP). Check it explicitly so that specific
    # cause gets one diagnostic line; a jq that IS present but errors on
    # malformed JSON still falls through to the `2>/dev/null` below and stays
    # silent — the caller already treats no-output as "no marker", and this
    # only distinguishes "not installed" from "found nothing".
    if ! command -v jq >/dev/null 2>&1; then
        printf '[devx_pr_review_all] jq not found — every ai-review/pr-reply-origins marker reads as absent (fail-closed, #1639/#1641).\n' >&2
        cat >/dev/null
        return 0
    fi

    jq -r --arg login "$_login" \
        '.[] | select(.user.login == $login) | .body' 2>/dev/null
    return 0
}

# Harvest one reviewer lane's raw output from the PR's RAW COMMENTS JSON on
# stdin — the array `gh api repos/<repo>/issues/<pr>/comments` answers with,
# each element carrying `.user.login` and `.body`.
# Reads it back from the `<!-- ai-review:<ai> -->` … `<!-- /ai-review:<ai> -->`
# markers `gh:pr-review` Step 6 posts (gh_pr_review.sh) — not from a lane's
# subagent return value, which never carries the verdict. Full rationale:
# claude/skills/devx-pr-review-all/references/review-verdict-label.md.
#
# `<expected-login>` is REQUIRED and load-bearing (#1639). Until it existed
# this function was handed pre-extracted body text (`--jq '.[].body'`) with
# the author already thrown away, so it harvested a well-formed marker from
# ANY commenter. On most repos anyone who can see the PR can comment on it —
# a far lower bar than the label-write access needed to attach
# `review-blocked` — so a hand-posted `<!-- ai-review:agy:<head> -->` block
# could dictate a lane's verdict and, through it, the merge gate. Filtering
# to the single login this pipeline authenticates as makes forging a lane
# verdict cost the same access as forging the label directly, which is the
# pre-existing, already-accepted trust boundary. A missing/invalid login
# harvests NOTHING (-> `unknown` downstream, fail-closed) rather than
# reverting to trusting every author. Same reasoning, same validator, as
# `_gh_pr_merge_train_review_passed_marker_sha` (PR #1608) — see
# claude/skills/gh-pr-merge-train/references/review-verdict-gate.md
# § "Marker authorship".
#
# Contract: the LAST complete block wins (a re-review supersedes); an
# unterminated block is never harvested. The optional <head-sha> is a
# freshness gate — given a sha, only `<!-- ai-review:<ai>:<sha> -->` blocks
# match, and a miss yields nothing (-> `unknown` downstream, fail-closed).
# Without it, sha-tagged and plain blocks both match and no freshness claim
# is made. The awk parser below is unchanged by the author check: it just
# sees a login-scoped body stream instead of an everyone stream.
#
#   devx_pr_review_all_lane_block <ai> [<head-sha>] <expected-login>
devx_pr_review_all_lane_block() {
    # Only <ai> ($1) needs an upfront check. An empty/invalid <expected-login>
    # ($3) is already fail-closed inside `_devx_pr_review_all_login_bodies`
    # itself — it drains stdin and yields nothing, so awk below sees an empty
    # stream and harvests nothing. Re-checking $3 here would just be a second
    # copy of that same rule.
    if [ -z "${1-}" ]; then
        cat >/dev/null
        return 0
    fi
    _devx_pr_review_all_login_bodies "$3" |
    awk -v ai="$1" -v sha="${2-}" '
        function tagof(line, pre, plen,   p, rest, e) {
            p = index(line, pre)
            if (p == 0) return ""
            rest = substr(line, p + plen)
            e = index(rest, " -->")
            if (e == 0) return ""
            return substr(rest, 1, e - 1)
        }
        function wanted(t) {
            if (sha != "") return (t == ai ":" sha)
            return (t == ai || substr(t, 1, length(ai) + 1) == ai ":")
        }
        BEGIN {
            # `beg`/`fin`, not `open`/`close`: `close` is an awk built-in and
            # using it as a variable is a syntax error in POSIX awk.
            beg = "<!-- ai-review:"
            fin = "<!-- /ai-review:"
            blen = length(beg)
            flen = length(fin)
        }
        {
            # A collapsed block — open and close markers on the same line —
            # must be handled before the open-tag rule below: that rule
            # `next`s immediately, so a close tag trailing on that same line
            # would never be inspected (PR #1573 review, agy+codex
            # independently).
            bp = index($0, beg)
            if (bp > 0 && wanted(tagof($0, beg, blen))) {
                bt = tagof($0, beg, blen)
                rest = substr($0, bp + blen + length(bt) + 4)
                fp = index(rest, fin)
                if (fp > 0 && wanted(tagof(rest, fin, flen))) {
                    last = substr(rest, 1, fp - 1)
                    next
                }
                collecting = 1
                buf = ""
                next
            }
            if (collecting && wanted(tagof($0, fin, flen))) {
                collecting = 0
                last = buf
                next
            }
            if (collecting) { buf = buf $0 "\n" }
        }
        END { printf "%s", last }
    '
}

# Duplicate-review guard (issue #1613): has <ai> ALREADY reviewed this exact
# head? Reads the PR's RAW COMMENTS JSON on stdin (same shape
# `devx_pr_review_all_lane_block` takes since #1639); rc 0 = yes (skip the
# lane), rc 1 = no (dispatch it). SSOT for the policy around it:
# claude/skills/devx-pr-review-all/references/duplicate-review-guard.md.
#
# Deliberately a thin wrapper over devx_pr_review_all_lane_block — the marker
# grammar has exactly one parser, so a future change to the `<!-- ai-review:
# <ai>:<sha> -->` shape cannot make the guard and the verdict harvester
# disagree. A non-empty block for that ai+sha pair is the evidence; anything
# else (no block, another sha, another lane, empty stdin) is "not yet
# reviewed", which fails OPEN — a missed skip only costs a duplicate review,
# while a false skip would silently lose a lane's verdict.
#
# <head-sha> is REQUIRED here, unlike in lane_block: without it an untagged or
# older block would match and every re-review would be skipped forever.
#
# <expected-login> is REQUIRED for the same reason (#1639), and is threaded
# straight through rather than defaulted: a marker from an untrusted author
# must not be able to SUPPRESS a lane either. Left unauthenticated, an
# outsider could post `<!-- ai-review:agy:<head> -->` and permanently silence
# that reviewer — the guard would read "already reviewed" and skip it every
# run. A missing login degrades to rc 1 here (fail OPEN, "not yet reviewed"),
# which is the same direction every other miss takes in this guard: a
# needless duplicate review costs budget, a wrongly skipped lane costs a
# verdict.
#
#   devx_pr_review_all_already_reviewed <ai> <head-sha> <expected-login>
devx_pr_review_all_already_reviewed() {
    local _ai="${1-}" _sha="${2-}" _login="${3-}" _block

    [ -n "$_ai" ] || return 1
    [ -n "$_sha" ] || return 1
    [ -n "$_login" ] || return 1

    _block=$(devx_pr_review_all_lane_block "$_ai" "$_sha" "$_login")
    [ -n "$_block" ]
}

# Delete one label from a PR, host-pinned and soft-fail. Internal: the two
# writers below both need "clear the opposite label first", and a second copy
# of the subshell/GH_HOST dance is exactly the drift `_gh_pr_drop_label`'s
# header warns about. Kept as a raw REST DELETE (not `_gh_pr_drop_label`)
# because this call site owns its own reporting: the caller turns the token
# below into one line, where the shared primitive prints its own.
#
# Prints exactly one token on stdout, never prose, and is rc 0 always:
#
#   drop=ok      the label was there and is gone
#   drop=absent  it was not there to begin with (HTTP 404) — the normal case
#   drop=failed  a REAL failure: auth, network, a wrong repo, GHES hiccup
#
# `drop=absent` exists because the overwhelmingly common outcome is that the
# opposite label was never on the PR, and warning on that would train the
# reader to ignore the warning. What must NOT stay silent is `drop=failed`:
# until PR #1637's review this function swallowed every outcome with
# `>/dev/null 2>&1 || :`, so a failed delete left BOTH verdict labels on the
# PR while the caller cheerfully printed "`review-blocked` cleared" (codex
# FOLLOW-UP).
#
# `2>&1 >/dev/null` — the ORDER is load-bearing: stderr is pointed at what is
# still the original stdout (the capture) BEFORE stdout is discarded. Written
# the other way round, stderr follows stdout into /dev/null and the 404
# discrimination has nothing to read. Same note, same reason, in
# claude/skills/gh-pr-reply/references/reply-pending-label-removal.sh.md.
_devx_pr_review_all_delete_label() {
    local _err _rc=0

    # `|| _rc=$?` rather than a bare capture: this file is sourced into
    # callers that may have `set -e` armed, where errexit would fire on the
    # non-zero substitution before the soft-fail branch below ran.
    _err=$(
        if [ -n "${4-}" ]; then
            # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped
            export GH_HOST="$4"
        fi
        gh api -X DELETE "repos/$3/issues/$2/labels/$1" 2>&1 >/dev/null
    ) || _rc=$?

    if [ "$_rc" -eq 0 ]; then
        printf 'drop=ok\n'
        return 0
    fi
    case "$_err" in
        *"HTTP 404"* | *"Not Found"*) printf 'drop=absent\n' ;;
        *) printf 'drop=failed\n' ;;
    esac
    return 0
}

# WRITE one verdict label to a PR. The verdict-free half of the old
# `devx_pr_review_all_apply_label`, split out by #1636 so both producers share
# one write path:
#
#   devx_pr_review_all_write_label <label> <pr> <repo> [host] [head-sha]
#
#   <label> — `review-passed` or `review-blocked`. Anything else is rc 2.
#
# It does, in order: delete the OPPOSITE label unconditionally (so a consumer
# can never see both), add <label> through `_gh_pr_edit_safe_label`, and — for
# `review-passed` with a [head-sha] — post the #1601 freshness marker comment.
# GH_HOST is pinned per call inside a subshell (#1403 / #1407).
#
# Reports three machine-readable lines on stdout instead of prose, in this
# FIXED order, because the two producers word their report lines differently
# and neither should have to re-derive what happened:
#
#   drop=ok | drop=absent | drop=failed | drop=skipped
#   add=ok | add=rc3 | add=failed | add=no-helper
#   marker=posted | marker=failed | marker=none
#
# `drop=` was added by PR #1637's review (codex FOLLOW-UP): a swallowed delete
# failure leaves both verdict labels on the PR, and the caller was reporting a
# clean flip. `drop=skipped` is the no-helper early return, which deliberately
# mutates nothing at all.
#
# Soft-fail: rc 0 for every labelling outcome (an unlabelled PR already reads
# as "not verified" downstream); only a usage error is rc 2.
#
# WHY THIS IS NOT A SELF-CERTIFICATION HOLE: this function takes a label, not
# a verdict, and it has always been the code that writes one. What decides the
# label lives in its callers — `devx_pr_review_all_apply_label` (an external
# reviewer's parsed verdict) and `_gh_pr_reply_apply_review_passed`
# (gh:pr-reply's own BLOCKER-resolution judgment, #1636). Splitting the two
# apart is what lets the second caller exist WITHOUT fabricating a fake
# verdict token to feed through the aggregator — a fake token would have
# misrepresented gh:pr-reply's judgment as a reviewer CLI's opinion in the
# label-application code, which is the one thing #1636 rules out.
devx_pr_review_all_write_label() {
    local _label="${1-}" _pr="${2-}" _repo="${3-}" _host="${4-}" _head_sha="${5-}"
    local _opposite _rc _marker _drop

    case "$_label" in
        review-passed) _opposite=review-blocked ;;
        review-blocked) _opposite=review-passed ;;
        *)
            printf '[devx-pr-review-all] usage: devx_pr_review_all_write_label <review-passed|review-blocked> <pr> <repo> [host] [head-sha]\n' >&2
            return 2
            ;;
    esac
    if [ -z "$_pr" ] || [ -z "$_repo" ]; then
        printf '[devx-pr-review-all] usage: devx_pr_review_all_write_label <review-passed|review-blocked> <pr> <repo> [host] [head-sha]\n' >&2
        return 2
    fi

    # The add-side helper lives in a sibling library. Both files are
    # auto-sourced into an interactive shell, but the skill's Bash tool calls
    # run `bash --noprofile --norc`, so source it on demand rather than
    # assuming the caller did.
    if ! command -v _gh_pr_edit_safe_label >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/gh_pr_edit_safe.sh" 2>/dev/null || :
    fi
    if ! command -v _gh_pr_edit_safe_label >/dev/null 2>&1; then
        # Reported BEFORE any mutation: with no way to add the new label,
        # deleting the opposite one would strip a valid verdict and put
        # nothing in its place. `drop=skipped` says exactly that — not
        # `drop=ok`, which would claim a delete that never ran.
        printf 'drop=skipped\n'
        printf 'add=no-helper\n'
        printf 'marker=none\n'
        return 0
    fi

    _drop=$(_devx_pr_review_all_delete_label "$_opposite" "$_pr" "$_repo" "$_host")

    # `|| _rc=$?`, not a bare subshell followed by `_rc=$?`: this file is
    # sourced into callers that may have `set -e` armed (bats test bodies do),
    # and there errexit fires on the subshell's non-zero exit BEFORE the
    # capture runs — the soft-fail contract would silently become a hard fail
    # on exactly the rc 3 path the caller most needs to report.
    _rc=0
    (
        if [ -n "$_host" ]; then
            # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped
            export GH_HOST="$_host"
        fi
        _gh_pr_edit_safe_label "$_pr" "$_label" --repo "$_repo"
    ) || _rc=$?

    # #1601 freshness marker: only on a successfully applied `review-passed`,
    # and only when the caller supplied the head sha it decided for. Soft-fail
    # — a failed post never changes the `add=` token — but never silent
    # either (PR #1608 review, agy + codex BLOCKER): a lost marker leaves the
    # label applied while `gh:pr-merge-train`'s freshness check will treat it
    # as CONFIRMED stale and self-heal it away on the very next tick, which
    # used to happen with no trace of why.
    _marker=none
    if [ "$_rc" -eq 0 ] && [ "$_label" = "review-passed" ] && [ -n "$_head_sha" ]; then
        _marker=posted
        (
            if [ -n "$_host" ]; then
                # shellcheck disable=SC2030,SC2031  # deliberately subshell-scoped
                export GH_HOST="$_host"
            fi
            gh api -X POST "repos/$_repo/issues/$_pr/comments" \
                -f "body=<!-- review-verdict:review-passed:$_head_sha -->"
        ) >/dev/null 2>&1 || _marker=failed
    fi

    printf '%s\n' "$_drop"
    case "$_rc" in
        0) printf 'add=ok\n' ;;
        3) printf 'add=rc3\n' ;;
        *) printf 'add=failed\n' ;;
    esac
    printf 'marker=%s\n' "$_marker"
    return 0
}

# Render `devx_pr_review_all_write_label`'s `drop=`/`add=`/`marker=` output
# into the caller's report lines. Both of `write_label`'s callers
# (`devx_pr_review_all_apply_label` below and `_gh_pr_reply_apply_review_passed`
# in gh_pr_reply_targeted_review.sh) used to re-derive this same
# parse-then-switch by hand — three of the four `add=` branches and the
# marker-failed line are worded identically in both, so the copies could only
# drift apart, never usefully differ (/simplify, PR #1637 review). Only the
# `add=ok` and generic-failure lines are caller-specific, since those are the
# two places the wording legitimately differs (English vs Korean, "labelled"
# vs "적용").
#
#   devx_pr_review_all_report_write_result <write-output> <pr> <repo> <label> <ok-line> <fail-line>
#
# `<write-output>` is exactly the lines `write_label` printed, matched by their
# `<key>=` prefix ONE LINE AT A TIME. The previous parse took two parameter
# expansions off the first newline — field 1 = everything before it, field 2 =
# everything after — which silently broke the moment a THIRD line existed: the
# `drop=` line PR #1637's review added landed first, so `_add` became `drop=…`
# (reported as a generic failure) and `_marker` became the remaining two lines
# (so the marker WARN stopped firing entirely). A key-prefixed scan cannot
# break that way again, and it does not care about line order.
devx_pr_review_all_report_write_result() {
    local _write="${1-}" _pr="${2-}" _repo="${3-}" _label="${4-}" _ok_line="${5-}" _fail_line="${6-}"
    local _add="" _marker="" _drop="" _line _opposite

    # `|| [ -n "$_line" ]` so a final line with no trailing newline still counts.
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            add=*) _add="${_line#add=}" ;;
            marker=*) _marker="${_line#marker=}" ;;
            drop=*) _drop="${_line#drop=}" ;;
        esac
    done <<EOF
$_write
EOF

    # shellcheck disable=SC2016  # backticks are markdown, not substitution
    case "$_add" in
        ok) printf '%s\n' "$_ok_line" ;;
        rc3) printf '[WARN] label `%s` missing in %s — provision it first (gh:label-bootstrap)\n' \
            "$_label" "$_repo" ;;
        no-helper) printf '[WARN] _gh_pr_edit_safe_label unavailable — PR #%s left unlabelled\n' "$_pr" ;;
        *) printf '%s\n' "$_fail_line" ;;
    esac
    if [ "$_marker" = "failed" ]; then
        printf '[WARN] review-passed freshness marker failed to post for PR #%s — a later merge-train check may see it as stale\n' "$_pr"
    fi
    # A failed opposite-label delete is the one outcome that leaves the PR in a
    # state no consumer expects: BOTH verdict labels present, with the caller's
    # own line claiming a clean flip (PR #1637 review, codex FOLLOW-UP). The
    # opposite is derived from <label>, so the WARN names the label that is
    # actually still there.
    if [ "$_drop" = "failed" ]; then
        case "$_label" in
            review-passed) _opposite=review-blocked ;;
            review-blocked) _opposite=review-passed ;;
            *) _opposite="$_label 의 반대 라벨" ;;
        esac
        printf '[WARN] 반대 라벨 %s 삭제 실패 — 두 판정 라벨이 공존할 수 있다 (PR #1637 review, codex FOLLOW-UP)\n' \
            "$_opposite"
    fi
    return 0
}

# Aggregate the verdict stream and WRITE the resulting label to the PR.
# This is the producer half of the merge gate (#1564): without it the two
# labels are never issued, `gh:pr-merge-train` reads "not verified" on every
# PR, and the gate degrades into a permanent skip.
#
#   <verdict tokens, one per line> | devx_pr_review_all_apply_label <pr> <repo> [host] [head-sha]
#
# Stdin, not positional args, for the zsh word-splitting reason
# devx_pr_review_all_aggregate's own header gives — a caller staging the
# verdicts in a variable and re-expanding it unquoted loses every lane but
# the first, which is #1527's original defect wearing a new hat.
#
# Contract (SSOT: claude/skills/devx-pr-review-all/references/review-verdict-label.md
# -> "Applying the label"):
#   - Since #1636 this function NEVER writes `review-passed`. A non-blocking
#     aggregate only clears an existing `review-blocked` and says so; the
#     `review-passed` decision moved to `gh:pr-reply` Step 6, which reaches it
#     from its own BLOCKER-resolution judgment without an external CLI re-call.
#     A PR left with neither label reads downstream exactly as it always has:
#     "not verified". See the reference doc's "Who applies `review-passed`".
#   - The OPPOSITE label is deleted first and unconditionally, so a re-review
#     that flips blocked -> passed cannot leave a consumer seeing both.
#   - The add goes through `_gh_pr_edit_safe_label`, never bare
#     `gh pr edit --add-label`: that silently exits 1 on repos with classic
#     Projects attached (#326). rc 3 means the label is missing in the repo
#     and the helper refused to auto-create it — provision it with
#     `gh:label-bootstrap`.
#   - Soft-fail throughout: rc is 0 for every labelling outcome, because an
#     unlabelled PR already reads as "not verified" downstream. Only a usage
#     error (rc 2) is a caller bug worth failing on.
#   - GH_HOST is pinned per call inside a subshell so a dual-host login cannot
#     write the label to the wrong server (#1403 / #1407), and the caller's own
#     GH_HOST is left untouched.
#
# [head-sha] (#1601) is still accepted, and is still what stamps the
# `<!-- review-verdict:review-passed:<head-sha> -->` freshness marker — but
# only via `devx_pr_review_all_write_label`, i.e. only for the caller that
# actually applies `review-passed`. On this function's own paths it is now
# inert: `review-blocked` never carried a marker (a stale block is the safe
# direction), and the non-blocking path writes no label to stamp. The
# argument stays in the signature so the Step 3.5 call site, the docs and the
# merge-train's reader contract need no churn.
devx_pr_review_all_apply_label() {
    local _pr="$1" _repo="$2" _host="${3-}" _head_sha="${4-}"
    local _agg _label _lanes _write _drop

    if [ -z "$_pr" ] || [ -z "$_repo" ]; then
        printf '[devx-pr-review-all] usage: devx_pr_review_all_apply_label <pr> <repo> [host] [head-sha]\n' >&2
        return 2
    fi

    _agg=$(devx_pr_review_all_aggregate)
    # `sed`, not `eval`: the values are controlled, but a parser that cannot
    # execute anything is the right default for something that gates a merge.
    _label=$(printf '%s\n' "$_agg" | sed -n 's/^label=//p')
    _lanes=$(printf '%s\n' "$_agg" | sed -n 's/^lanes=//p')

    if [ -z "$_label" ]; then
        printf '[WARN] no reviewer lane produced a verdict — PR #%s left unlabelled\n' "$_pr"
        return 0
    fi

    # #1636 — the label-ownership split. Every lane passed, but this producer
    # no longer certifies: it clears the stale block (mutual exclusion is
    # unchanged) and stops. `gh:pr-reply` applies `review-passed` after it has
    # replied to every comment and found no unresolved BLOCKER.
    if [ "$_label" = "review-passed" ]; then
        # This branch does not go through `devx_pr_review_all_write_label`, so
        # it reads the `drop=` token itself: claiming "`review-blocked` cleared"
        # after a failed DELETE is exactly the mis-report PR #1637's review
        # named (codex FOLLOW-UP). The `[OK]` wording is unchanged byte for
        # byte on the ok/absent paths — a delete that found nothing to delete
        # left the PR in precisely the intended state.
        _drop=$(_devx_pr_review_all_delete_label review-blocked "$_pr" "$_repo" "$_host")
        if [ "$_drop" = "drop=failed" ]; then
            # shellcheck disable=SC2016  # backticks are markdown, not substitution
            printf '[WARN] PR #%s: every lane non-blocking (%s lane(s)) — `review-blocked` 해제 실패, 라벨이 남아 있을 수 있다; `review-passed` is gh:pr-reply'"'"'s to apply (#1636)\n' \
                "$_pr" "$_lanes"
            return 0
        fi
        # shellcheck disable=SC2016  # backticks are markdown, not substitution
        printf '[OK] PR #%s: every lane non-blocking (%s lane(s)) — `review-blocked` cleared; `review-passed` is gh:pr-reply'"'"'s to apply (#1636)\n' \
            "$_pr" "$_lanes"
        return 0
    fi

    _write=$(devx_pr_review_all_write_label "$_label" "$_pr" "$_repo" "$_host" "$_head_sha")
    # The backticks below are markdown in the OK line (the label name renders
    # as code in a terminal-pasted comment), not command substitution —
    # single-quoted printf formats never expand.
    # shellcheck disable=SC2016
    devx_pr_review_all_report_write_result "$_write" "$_pr" "$_repo" "$_label" \
        "$(printf '[OK] PR #%s labelled `%s` (%s lane(s))' "$_pr" "$_label" "$_lanes")" \
        "$(printf '[WARN] labelling PR #%s failed — treat the PR as unverified' "$_pr")"
    return 0
}

# Self-check (issue #724): this file is sourced by the devx:pr-review-all skill
# in non-interactive bash. A syntax error mid-file or a future rename would
# leave the verdict path silently undefined — which reads as "no lane produced
# a verdict", i.e. every PR unlabelled and every merge skipped (#1564).
for _dpra_selfcheck_fn in \
    devx_pr_review_all_parse \
    devx_pr_review_all_verdict \
    devx_pr_review_all_aggregate \
    devx_pr_review_all_lane_block \
    devx_pr_review_all_already_reviewed \
    devx_pr_review_all_write_label \
    devx_pr_review_all_report_write_result \
    devx_pr_review_all_apply_label; do
    command -v "$_dpra_selfcheck_fn" >/dev/null 2>&1 && continue
    printf '[devx_pr_review_all] BUG: %s undefined after source — the review verdict gate will not run. See dotfiles #724 / #1564.\n' \
        "$_dpra_selfcheck_fn" >&2
done
unset _dpra_selfcheck_fn
:
