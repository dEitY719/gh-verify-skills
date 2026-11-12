#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_material.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_material.sh
# gh-pr-review PR material — PR number, metadata fetch, state preflight, diff path filter.
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

_gh_pr_review_resolve_pr_number() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    # Echoes the PR number; non-zero exit if neither arg nor branch resolves.
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    # Branch auto-detect: `gh pr view` must stay number-less so gh reads the
    # PR off the current branch, which also rules out `--repo` (gh: "argument
    # required when using the --repo flag"). The host still gets pinned.
    _gh_pr_review_ensure_host
    local pr
    if ! pr=$(gh pr view --json number -q .number 2>/dev/null); then
        ux_error "No PR found for current branch; pass PR number explicitly"
        return 1
    fi
    if [ -z "$pr" ]; then
        ux_error "No PR found for current branch; pass PR number explicitly"
        return 1
    fi
    printf '%s\n' "$pr"
}

# _gh_pr_review_fetch_meta — one-shot fetch of every PR field the main
# entrypoint needs (state, isDraft, baseRefName, headRefName,
# headRefOid). One network round-trip beats five. The raw JSON is echoed
# verbatim so the caller can extract whichever subset it cares about; on
# fetch failure (network blip, no permission, deleted PR, wrong host) it
# reports the error with gh's first non-empty stderr line as the cause and
# returns 1 (#2313).
#
# `headRefOid` rides along rather than costing a second `gh pr view`: it
# is only needed to tag the Step 6 comment marker (#1564), which is the
# same reason the other four are consolidated here.
_gh_pr_review_fetch_meta() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local pr="$1" repo="$2" _err _rc
    # stdout (the JSON) passes through on fd 3; only stderr is captured.
    {
        _err=$(gh pr view "$pr" --repo "$repo" \
            --json state,isDraft,baseRefName,headRefName,headRefOid 2>&1 >&3 3>&-)
        _rc=$?
    } 3>&1
    [ "$_rc" -eq 0 ] && return 0
    _err=$(printf '%s\n' "$_err" | sed -n '/[^[:space:]]/{p;q;}')
    ux_error "PR #$pr could not be fetched from $repo${_err:+: $_err}"
    return 1
}

# _gh_pr_review_preflight_pr_state — pure-shell gate on pre-fetched
# metadata. Decoupled from the `gh` call so the consolidation in
# `_gh_pr_review_fetch_meta` stays a single round-trip. CI status is
# intentionally NOT checked (opinion collection works on red CI too).
#
# Args: $1 = pr_number, $2 = state, $3 = isDraft ("true"/"false"/empty).
_gh_pr_review_preflight_pr_state() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local pr="$1" state="$2" draft="$3"
    case "$state" in
    OPEN) ;;
    "")
        ux_error "PR #$pr could not be fetched (empty state)"
        return 1
        ;;
    *)
        ux_error "PR #$pr is $state; aborting"
        return 1
        ;;
    esac
    if [ "$draft" = "true" ]; then
        ux_error "PR #$pr is DRAFT; aborting"
        return 1
    fi
    return 0
}

# _gh_pr_review_filter_diff_paths — unified diff on stdin, one or more
# repo-relative paths as args; emits only the `diff --git` sections whose
# old OR new path is one of them (a rename is therefore reachable from
# either side). Exit 2 with nothing on stdout when no path was given —
# a silent pass-through would hand the caller a full-PR diff it believed
# was scoped (issue #1616).
#
# `gh pr diff` has no pathspec of its own, so scoping happens here rather
# than at the API. The `a/X b/Y` split takes the FIRST ` b/`, which is
# unambiguous for every path that does not itself contain " b/".
_gh_pr_review_filter_diff_paths() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    if [ "$#" -eq 0 ]; then
        ux_error 'usage: _gh_pr_review_filter_diff_paths <path>...'
        return 2
    fi
    local _wanted=""
    local _p
    for _p in "$@"; do
        _wanted="${_wanted}${_p}
"
    done
    awk -v wanted="$_wanted" '
        BEGIN {
            n = split(wanted, w, "\n")
            for (i = 1; i <= n; i++) if (w[i] != "") want[w[i]] = 1
        }
        /^diff --git / {
            keep = 0
            line = substr($0, 12)
            sp = index(line, " b/")
            if (sp > 0) { ap = substr(line, 1, sp - 1); bp = substr(line, sp + 3) }
            else { ap = line; bp = "" }
            sub(/^a\//, "", ap)
            if ((ap in want) || (bp in want)) keep = 1
            if (keep) print
            next
        }
        keep { print }
    '
}
