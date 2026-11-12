#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_target.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_target.sh
# gh-pr-review target resolution — remote URL -> owner/repo, GH_HOST pin, auth gate.
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

# ============================================================================
# Section 5 — PR resolution + pre-flight
# ============================================================================

# _gh_pr_review_parse_remote_url — extracts `owner/repo` from a github
# remote URL. Accepts both forms produced by `git remote get-url`:
#
#   https://github.com/owner/repo.git
#   git@github.com:owner/repo.git
#   ssh://git@github.com/owner/repo.git
#   git+https://github.com/owner/repo
#
# Prints `owner/repo` to stdout and returns 0 on success. Returns 1 with
# an error message on stderr when the URL is not a github remote or the
# extracted value does not match the `owner/repo` shape.
#
# Issue #694 Bug C — the previous code called `gh repo view` without
# `-R <url>`, so the user-supplied `<remote>` argument was silently
# ignored and the real `gh` error was swallowed by `2>/dev/null`.
# Splitting URL parsing into a pure-shell helper makes the contract
# bats-testable and removes the network dependency from the resolution
# step entirely.
_gh_pr_review_parse_remote_url() {
    # Issue #703 — the parser used to be `github.com`-only, which made
    # /gh-pr-reply, /gh-pr-approve and /gh-pr-review reject GHE remotes
    # on the `internal` PC. Delegating to the SSOT helper in
    # shell-common/lib/gh_host.sh keeps both hosts working while
    # leaving this function's call sites untouched.
    # shellcheck disable=SC1091
    . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_host.sh"
    _gh_parse_owner_repo_url "$@"
}

# _gh_pr_review_resolve_target_repo — given a remote name in the current
# git repo, returns `owner/repo` by consulting `git remote get-url` and
# parsing the URL. On failure prints the actionable cause to stderr
# (which remote was tried, the URL value if any) and returns 1. Network
# round-trips are avoided entirely; gh's auth state and default-repo
# cache no longer affect this step (Bug C from issue #694).
_gh_pr_review_resolve_target_repo() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _remote="${1:-origin}"
    local _url
    if ! _url=$(git remote get-url "$_remote" 2>&1); then
        ux_error "Remote '$_remote' not found in this repo:"
        echo "  git remote get-url '$_remote' → $_url" >&2
        git remote -v >&2
        return 1
    fi
    local _slug
    if ! _slug=$(_gh_pr_review_parse_remote_url "$_url"); then
        echo "  remote='$_remote' url='$_url'" >&2
        return 1
    fi
    printf '%s\n' "$_slug"
    return 0
}

# _gh_pr_review_ensure_host — pin the gh server for a `gh` call that cannot
# carry `--repo`. Mirrors `_gh_project_status_ensure_host`
# (shell-common/lib/gh_project_status.sh) rather than growing a second
# mechanism: an already-set GH_HOST wins — and is re-exported, because a
# caller may have assigned it as a plain (non-exported) shell variable that
# `gh` subprocesses would not otherwise inherit — else the SSOT helper in
# gh_host.sh resolves one. Never fails the caller: if the helper is
# unavailable, `gh` simply keeps its own default host (#1403, #1407).
_gh_pr_review_ensure_host() {
    if [ -n "${GH_HOST-}" ]; then
        export GH_HOST
        return 0
    fi
    # shellcheck disable=SC1091
    . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_host.sh" 2>/dev/null || return 0
    if command -v _gh_resolve_host >/dev/null 2>&1; then
        GH_HOST=$(_gh_resolve_host)
        export GH_HOST
    fi
}

# _gh_pr_review_remote_host — print the GitHub host of <remote>'s URL, or
# nothing when the remote or its host cannot be resolved. Shared by the auth
# gate (#1905) and the GH_HOST pin (#2313) so both read the same host.
_gh_pr_review_remote_host() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _url
    _url=$(git remote get-url "${1:-origin}" 2>/dev/null) || return 0
    # shellcheck disable=SC1091
    . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_host.sh" 2>/dev/null || :
    _gh_host_from_url "$_url" 2>/dev/null || :
}

# _gh_pr_review_pin_host — export GH_HOST as <remote>'s URL host so every
# later `gh` call (meta fetch, diff, comment) talks to the PR's server even
# when the PR number is explicit and the caller logged into several hosts
# (#2313). An already-set GH_HOST wins and is only re-exported.
_gh_pr_review_pin_host() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    if [ -z "${GH_HOST-}" ]; then
        GH_HOST=$(_gh_pr_review_remote_host "$1")
        [ -n "$GH_HOST" ] || unset GH_HOST
    fi
    [ -z "${GH_HOST-}" ] || export GH_HOST
    return 0
}

# _gh_pr_review_require_auth — fail unless gh is authenticated for the host of
# <remote>'s URL. A bare `gh auth status` checks EVERY host in hosts.yml, so a
# dead login for an unrelated host (e.g. a stale internal-GHES stub on a public
# PC) fails the gate although the target host is fine (#1905). Falls back to the
# unscoped check when the host cannot be derived from the remote.
_gh_pr_review_require_auth() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _remote="${1:-origin}" _host
    _host=$(_gh_pr_review_remote_host "$_remote")
    if [ -n "$_host" ]; then
        if ! gh auth status --hostname "$_host" >/dev/null 2>&1; then
            ux_error "gh CLI not authenticated for $_host; run 'gh auth login -h $_host'"
            return 1
        fi
    elif ! gh auth status >/dev/null 2>&1; then
        ux_error "gh CLI not authenticated; run 'gh auth login'"
        return 1
    fi
    return 0
}
