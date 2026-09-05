#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/gh_host.sh
# Synced 2026-09-05T10:16Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/gh_host.sh
# Resolve the active GitHub host and parse owner/repo from remote URLs.
#
# SSOT for host routing based on `_dotfiles_setup_mode` (issue #703).
# `github.com` is hard-coded in several hooks and scripts; that breaks
# the `internal` PC where the real target is `github.samsungds.net`
# (GHE). Replacing those hard-coded literals with `_gh_resolve_host`
# keeps `external` / `public` / missing-file environments on
# `github.com` (regression-zero) while routing `internal` to GHE.
#
# Host mapping (from issue #703):
#
#   _dotfiles_setup_mode | Host
#   ---------------------+--------------------------
#   internal             | github.samsungds.net
#   external             | github.com
#   public               | github.com
#   "" (file missing)    | github.com
#   <anything else>      | github.com (fail-safe)
#
# When a future GHE domain appears, edit this file only — no other
# script should grow a second copy of the mapping.
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
unset _drg_self _drg_helper

# _gh_resolve_host — print the active GitHub host on stdout.
#
# Reads `_dotfiles_setup_mode` (defined in
# shell-common/tools/integrations/claude.sh). When that function isn't
# in scope, fall back to reading `~/.dotfiles-setup-mode` directly so
# non-interactive callers (hooks, one-shot scripts) that source
# gh_host.sh without the integrations layer still resolve `internal`
# correctly. Before issue #718 this branch unconditionally returned
# `github.com`, which silently broke `claude/hooks/post-gh-pr-create.sh`
# on internal PCs (host regex never matched the GHE PR URL → board
# sync skipped). The disk fallback mirrors the same canonicalisation
# that `_dotfiles_setup_mode` performs (legacy numeric values 1/2/3
# from pre-#571 setup.sh) so the two code paths agree.
_gh_resolve_host() {
    if command -v _dotfiles_setup_mode >/dev/null 2>&1; then
        _grh_mode=$(_dotfiles_setup_mode 2>/dev/null || echo "")
    else
        _grh_file="$HOME/.dotfiles-setup-mode"
        if [ -f "$_grh_file" ]; then
            _grh_mode=$(tr -d ' \t\n\r' < "$_grh_file" 2>/dev/null)
            case "$_grh_mode" in
                1) _grh_mode="public" ;;
                2) _grh_mode="internal" ;;
                3) _grh_mode="external" ;;
            esac
        else
            _grh_mode=""
        fi
        unset _grh_file
    fi
    case "$_grh_mode" in
        internal)           echo "github.samsungds.net" ;;
        external|public|"") echo "github.com" ;;
        *)                  echo "github.com" ;;
    esac
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
# When a new GHE domain is added, extend both `case` branches below (and
# the sed regex in `_gh_parse_owner_repo_url`, which still needs its own
# stripping pattern) — no other function should grow a second copy of
# the matching logic.
_gh_match_known_host() {
    case "${1:-}" in
        *://github.samsungds.net/*|*://github.samsungds.net|\
        *@github.samsungds.net:*|*@github.samsungds.net/*|*@github.samsungds.net|\
        github.samsungds.net/*|github.samsungds.net:*|github.samsungds.net)
            echo "github.samsungds.net" ;;
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
# and the GHE equivalents at `github.samsungds.net`. Returns 0 with
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
    if ! _gh_match_known_host "$_gpu_url" >/dev/null; then
        echo "remote URL is not a github remote: $_gpu_url" >&2
        return 1
    fi
    _gpu_slug=$(printf '%s' "$_gpu_url" |
        sed -E 's#^.*(github\.com|github\.samsungds\.net)[:/]+##; s#\.git/?$##; s#/$##')
    if ! printf '%s' "$_gpu_slug" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
        echo "Could not parse owner/repo from remote URL: $_gpu_url" >&2
        unset _gpu_url _gpu_slug
        return 1
    fi
    printf '%s\n' "$_gpu_slug"
    unset _gpu_url _gpu_slug
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
# setup-mode's `github.samsungds.net`.
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
