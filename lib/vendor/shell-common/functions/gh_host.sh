#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/gh_host.sh
# Synced 2026-10-10T03:07Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/gh_host.sh
# Resolve the active GitHub host and parse owner/repo from remote URLs.
#
# SSOT for host routing based on `_dotfiles_setup_mode` (issue #703).
# `github.com` is hard-coded in several hooks and scripts; that breaks
# the `internal` PC where the real target is the GHES host
# (`$DOTFILES_GHES_HOST`, #1965). Replacing those hard-coded literals with `_gh_resolve_host`
# keeps `external` / `public` / missing-file environments on
# `github.com` (regression-zero) while routing `internal` to GHE.
#
# Host mapping (from issue #703):
#
#   _dotfiles_setup_mode | Host
#   ---------------------+--------------------------
#   internal             | $DOTFILES_GHES_HOST (unset: warn, github.com)
#   external             | github.com
#   public               | github.com
#   "" (file missing)    | github.com
#   <anything else>      | github.com (fail-safe)
#
# The GHES host name is an internal identifier, so it never appears in
# this public repo (#1944/#1965): it comes from `DOTFILES_GHES_HOST`, set
# by the gitignored shell-common/env/internal.local.sh. No other script
# should grow a second copy of the mapping.
#
# PR #704 review (gemini-code-assist) — no interactive guard.
# CLAUDE.md only mandates the guard for files that produce output at
# file scope; this file defines functions and exits, so the guard
# would have blocked non-interactive callers (`. gh_host.sh` inside
# hooks / one-shot scripts) from seeing the functions at all. Keeping
# the body pure-definitions makes the file safe to source from any
# context — interactive, non-interactive, or `bash -c`.

# Advisory only (issue #1454, propagated by #1505): warn once on stderr when
# this file was sourced from a checkout that is a different git repo than
# $HOME/dotfiles. Never blocks, and deliberately NOT wrapped in an
# interactive guard — see the PR #704 note above; the guard function is
# itself a silent no-op outside the genuine foreign-checkout case.
#
# The self-path branch must stay here at file top level — zsh rebinds $0 to
# the sourced file (FUNCTION_ARGZERO) only for this file's own statements,
# and inside a function $0 is the function's own name. This file is real
# POSIX sh sourced by git hooks, so the bash array form is reached only
# when $BASH_VERSION proves bash: dash aborts with "Bad substitution" the
# moment it expands ${BASH_SOURCE[0]}. Everything after the branch lives
# once, in _dotfiles_root_guard_self.
if [ -n "${ZSH_VERSION-}" ]; then
    _drg_self="$0"
elif [ -n "${BASH_VERSION-}" ]; then
    # shellcheck disable=SC3028  # bash-only var, gated by $BASH_VERSION above
    _drg_self="${BASH_SOURCE[0]-}"
else
    _drg_self=""
fi
_drg_helper="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/dotfiles_root.sh"
if [ -r "$_drg_helper" ]; then
    . "$_drg_helper" || true
fi
if command -v _dotfiles_root_guard_self >/dev/null 2>&1; then
    _dotfiles_root_guard_self "$_drg_self" "gh_host"
else
    printf '[gh_host] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
# Setup-mode reader SSOT (#1810), from this file's own shell-common first so a
# minimal-env hook (no SHELL_COMMON, isolated $HOME) still resolves internal.
if ! command -v _dotfiles_setup_mode >/dev/null 2>&1; then
    for _grh_lib in "${_drg_self%/*}/../util/setup_mode_read.sh" \
        "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/util/setup_mode_read.sh"; do
        if [ -r "$_grh_lib" ]; then
            . "$_grh_lib"
            break
        fi
    done
    unset _grh_lib
fi
unset _drg_self _drg_helper

# _gh_ghes_host — print the internal GHES host, or nothing when unknown.
#
# `$DOTFILES_GHES_HOST` wins. Hooks and one-shot scripts source this file
# without the loaders (so env/internal.sh never ran and the variable is not
# exported); for them, read the assignment out of internal.local.sh. The
# file is parsed, never sourced, so a hook does not execute it. Public PCs
# have no such file and get empty output — github.com behavior unchanged.
_gh_ghes_host() {
    if [ -n "${DOTFILES_GHES_HOST-}" ]; then
        printf '%s\n' "$DOTFILES_GHES_HOST"
        return 0
    fi
    _ggh_file="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/env/internal.local.sh"
    if [ -r "$_ggh_file" ]; then
        sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}DOTFILES_GHES_HOST=[\"']\{0,1\}\([A-Za-z0-9.-]*\).*/\2/p" \
            "$_ggh_file" 2>/dev/null | sed -n '$p'
    fi
    unset _ggh_file
}

# _gh_resolve_host — print the active GitHub host on stdout.
#
# Mode comes from `_dotfiles_setup_mode`, sourced at the top of this file so
# non-interactive callers (hooks, one-shot scripts) that load gh_host.sh
# without the shell loader still get it. Before issue #718 a missing reader
# meant an unconditional `github.com`, which silently broke
# `claude/hooks/post-gh-pr-create.sh` on internal PCs. An unreachable lib
# still degrades to "" (github.com), never an error.
_gh_resolve_host() {
    _grh_mode=""
    if command -v _dotfiles_setup_mode >/dev/null 2>&1; then
        _grh_mode=$(_dotfiles_setup_mode 2>/dev/null || echo "")
    fi
    if [ "$_grh_mode" = "internal" ]; then
        _grh_ghes=$(_gh_ghes_host)
        if [ -n "$_grh_ghes" ]; then
            printf '%s\n' "$_grh_ghes"
        else
            # Never hard-fail and never route silently: say why gh will
            # talk to github.com instead of the GHES host.
            printf '[gh_host] internal mode but DOTFILES_GHES_HOST is unset (see shell-common/env/internal.local.example) — falling back to github.com\n' >&2
            echo "github.com"
        fi
        unset _grh_ghes
    else
        # external / public / "" (file missing) / unknown -> github.com
        echo "github.com"
    fi
    unset _grh_mode
}

# _gh_match_known_host — print the known GitHub host a URL matches, or
# fail with exit 1 when the URL doesn't point at any host this repo
# knows about. Single source of truth for the host allowlist so
# `_gh_parse_owner_repo_url` and `_gh_host_from_url` never carry two
# independent copies of the domain list to drift out of sync.
#
# GHE is matched first so a future `github.com`-suffixed GHE domain
# cannot be swallowed by the github.com glob.
#
# Anchored on both sides (issue #1403 PR review, codex/agy) — a plain
# `*github.com*` substring glob also matches `https://notgithub.com/...`
# or `https://github.com.evil.net/...`, silently misclassifying an
# unrelated host as github.com and defeating the whole point of this
# file. The host must be preceded by `://`, `@`, or the start of the
# string, and followed by `:`, `/`, or the end of the string.
#
# The GHE host comes from `_gh_ghes_host` (quoted in the patterns, so its
# dots are literal); when it is unknown only github.com is recognized.
# `_gh_parse_owner_repo_url` strips the matched host this function prints,
# so no other function grows a second copy of the matching logic.
_gh_match_known_host() {
    _gmk_ghes=$(_gh_ghes_host)
    if [ -n "$_gmk_ghes" ]; then
        case "${1:-}" in
            *://"$_gmk_ghes"/*|*://"$_gmk_ghes"|\
            *@"$_gmk_ghes":*|*@"$_gmk_ghes"/*|*@"$_gmk_ghes"|\
            "$_gmk_ghes"/*|"$_gmk_ghes":*|"$_gmk_ghes")
                printf '%s\n' "$_gmk_ghes"
                unset _gmk_ghes
                return 0 ;;
        esac
    fi
    unset _gmk_ghes
    case "${1:-}" in
        *://github.com/*|*://github.com|\
        *@github.com:*|*@github.com/*|*@github.com|\
        github.com/*|github.com:*|github.com)
            echo "github.com" ;;
        *) return 1 ;;
    esac
}

# _gh_parse_owner_repo_url — parse `owner/repo` out of a git remote URL.
#
# Accepts the common shapes:
#
#   https://github.com/owner/repo(.git)
#   git@github.com:owner/repo(.git)
#   ssh://git@github.com/owner/repo(.git)
#   git+https://github.com/owner/repo
#
# and the GHE equivalents at `$DOTFILES_GHES_HOST`. Returns 0 with
# `owner/repo` on stdout, or 1 with an error message on stderr when
# the URL is empty, points at a non-github host, or doesn't yield a
# clean two-segment slug.
#
# Used by F-4 (gh_pr_review.sh URL parser) and F-5 (kanban setup).
_gh_parse_owner_repo_url() {
    _gpu_url="${1:-}"
    if [ -z "$_gpu_url" ]; then
        echo "empty remote URL" >&2
        return 1
    fi
    if ! _gpu_host=$(_gh_match_known_host "$_gpu_url"); then
        echo "remote URL is not a github remote: $_gpu_url" >&2
        unset _gpu_url _gpu_host
        return 1
    fi
    # Strip through the last occurrence of the matched host (quoted: dots
    # literal), then the [:/] separators.
    _gpu_slug=$(printf '%s' "${_gpu_url##*"$_gpu_host"}" |
        sed -E 's#^[:/]+##; s#\.git/?$##; s#/$##')
    if ! printf '%s' "$_gpu_slug" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
        echo "Could not parse owner/repo from remote URL: $_gpu_url" >&2
        unset _gpu_url _gpu_slug _gpu_host
        return 1
    fi
    printf '%s\n' "$_gpu_slug"
    unset _gpu_url _gpu_slug _gpu_host
}

# _gh_host_from_url — print the GitHub host a git remote URL points at.
#
# Answers a different question than `_gh_resolve_host`: that one maps the
# *PC's* setup-mode to a host, this one reads the host out of the *remote
# URL we are actually about to talk to*. Both are needed because the two
# can legitimately disagree — on an `internal` PC `origin` is the GHE
# remote while `upstream` is a pull-only `github.com` remote (see
# `docs/.ssot/pc-environment.md` section 3), so a skill that resolved
# `owner/repo` from `upstream` must send `GH_HOST=github.com`, not the
# setup-mode's GHES host.
#
# This is the fix for issue #1403: `gh` without `--repo`/`GH_HOST` follows
# its own `gh repo set-default`, not git's `origin`, so on a dual-host
# login it can query the wrong host and report "issue not found" with
# exit 0. Pairing this function's output with `_gh_parse_owner_repo_url`'s
# output guarantees host and repo are read from one and the same URL and
# therefore can never name different servers.
#
# Accepts the same URL shapes as `_gh_parse_owner_repo_url`. Returns 0
# with the bare hostname on stdout, or 1 with an error on stderr when the
# URL is empty or is not a known github remote. Callers that have no URL
# at all (no git remote in scope) should fall back to `_gh_resolve_host`.
#
# Delegates the actual host matching to `_gh_match_known_host` — see
# that function's comment for where to extend the domain list.
_gh_host_from_url() {
    _ghu_url="${1:-}"
    if [ -z "$_ghu_url" ]; then
        echo "empty remote URL" >&2
        unset _ghu_url
        return 1
    fi
    if ! _ghu_host=$(_gh_match_known_host "$_ghu_url"); then
        echo "remote URL is not a github remote: $_ghu_url" >&2
        unset _ghu_url _ghu_host
        return 1
    fi
    printf '%s\n' "$_ghu_host"
    unset _ghu_url _ghu_host
}
