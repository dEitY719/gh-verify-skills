# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/dotfiles_root.sh
# Synced 2026-09-03T08:20Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.

#!/bin/sh
# shell-common/functions/dotfiles_root.sh
#
# Canonicalize $DOTFILES_ROOT so it always resolves to the MAIN git worktree,
# never a linked worktree. Issue #589.
#
# Why: claude/setup.sh and claude_accounts_init evaluate ${DOTFILES_ROOT} at
# call time and embed that literal path into ~/.claude-*/{settings.json,
# statusline-command.sh, skills, docs, ...} symlinks. If setup.sh is invoked
# from a linked worktree, those symlinks point at the worktree path. When
# the worktree is removed later, the symlinks dangle → Claude Code silently
# falls back to default settings (no statusline, no hooks, no plugins). The
# user sees "왜 안 되지" with no error message.
#
# Strategy: when called inside a linked worktree, walk back to the main
# worktree via `git rev-parse --git-common-dir`. Pure POSIX, no bash-isms.

# Sourced both by interactive shells (loaders) and by non-interactive
# setup.sh runs. The interactive guard pattern is intentionally absent so
# setup.sh can rely on the function being defined even without
# DOTFILES_FORCE_INIT — there is no observable output until the function
# is invoked.

# Include-once sentinel (issue #1505): an interactive shell sources this
# file explicitly (bash/main.bash, zsh/main.zsh, for #589 canonicalization),
# then again via the functions/ autoloader's own pass over
# shell-common/functions/*.sh, then once more per #1454-guarded helper file
# below (each does `. "$SHELL_COMMON/functions/dotfiles_root.sh"` itself).
# Every repeat re-parses this file and redefines its functions for no
# benefit — skip repeats within one process. `return` (not `exit`) since
# this only ever runs as a sourced dot-script; the `|| exit 0` fallback
# covers the (unsupported) case of running it directly.
if [ -n "${_DOTFILES_ROOT_SH_SOURCED-}" ]; then
    # shellcheck disable=SC2317  # exit fallback only runs if this file is
    # executed directly (not sourced), so `return` succeeding makes it look
    # unreachable to static analysis.
    return 0 2>/dev/null || exit 0
fi
_DOTFILES_ROOT_SH_SOURCED=1

# _resolve_dotfiles_root_canonical CANDIDATE
#
# Echo the canonical (main-worktree) directory that should be used as
# $DOTFILES_ROOT, given CANDIDATE as the script-derived starting point.
#
# Behavior:
#   - CANDIDATE empty/missing → echo "$CANDIDATE" (no-op).
#   - DOTFILES_ROOT_NO_CANONICALIZE=1 in env → echo "$CANDIDATE" (escape
#     hatch for users intentionally testing a worktree's dotfiles).
#   - git unavailable → echo "$CANDIDATE" (minimal hosts).
#   - CANDIDATE is not a git worktree → echo "$CANDIDATE".
#   - CANDIDATE is the MAIN worktree → echo "$CANDIDATE".
#   - CANDIDATE is a linked worktree → echo the resolved main worktree path.
#
# Always returns 0 — a probing failure must fall back to CANDIDATE so this
# helper can never break a shell that was working before.
_resolve_dotfiles_root_canonical() {
    _rdrc_candidate="${1:-}"

    if [ -z "$_rdrc_candidate" ]; then
        printf '%s\n' ""
        return 0
    fi

    if [ ! -d "$_rdrc_candidate" ]; then
        printf '%s\n' "$_rdrc_candidate"
        return 0
    fi

    if [ "${DOTFILES_ROOT_NO_CANONICALIZE:-0}" = "1" ]; then
        printf '%s\n' "$_rdrc_candidate"
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        printf '%s\n' "$_rdrc_candidate"
        return 0
    fi

    # Compare --git-dir with --git-common-dir to safely detect *linked
    # worktrees only*. They differ only when the checkout is a linked
    # worktree of either a main repo or a submodule. They are equal for:
    #   - main worktree of a regular repo (.git == .git)
    #   - main checkout of a submodule (.git/modules/<sub> == itself)
    # In the equal case dirname walks to .git/modules (wrong target),
    # so short-circuit and return the candidate untouched. Reported by
    # gemini-code-assist on PR #593.
    _rdrc_git_dir=$(git -C "$_rdrc_candidate" rev-parse --git-dir 2>/dev/null) || {
        printf '%s\n' "$_rdrc_candidate"
        return 0
    }
    _rdrc_common=$(git -C "$_rdrc_candidate" rev-parse --git-common-dir 2>/dev/null) || {
        printf '%s\n' "$_rdrc_candidate"
        return 0
    }

    if [ -z "$_rdrc_common" ] || [ "$_rdrc_git_dir" = "$_rdrc_common" ]; then
        printf '%s\n' "$_rdrc_candidate"
        return 0
    fi

    case "$_rdrc_common" in
        /*) ;;
        *) _rdrc_common="$_rdrc_candidate/$_rdrc_common" ;;
    esac

    _rdrc_main=$(dirname "$_rdrc_common" 2>/dev/null)
    if [ -z "$_rdrc_main" ] || [ ! -d "$_rdrc_main" ]; then
        printf '%s\n' "$_rdrc_candidate"
        return 0
    fi

    _rdrc_main=$(cd "$_rdrc_main" 2>/dev/null && pwd) || {
        printf '%s\n' "$_rdrc_candidate"
        return 0
    }

    printf '%s\n' "$_rdrc_main"
}

# _dotfiles_root_canonicalize
#
# In-place: re-export $DOTFILES_ROOT (and $SHELL_COMMON) from a worktree
# path to the canonical main-worktree path. No-op if already canonical or
# if DOTFILES_ROOT is unset. Always returns 0 — a downgrade-safe wrapper
# loaders can call unconditionally.
_dotfiles_root_canonicalize() {
    [ -n "${DOTFILES_ROOT:-}" ] || return 0
    _drc_resolved=$(_resolve_dotfiles_root_canonical "$DOTFILES_ROOT")
    if [ -n "$_drc_resolved" ] && [ "$_drc_resolved" != "$DOTFILES_ROOT" ]; then
        DOTFILES_ROOT="$_drc_resolved"
        export DOTFILES_ROOT
        SHELL_COMMON="${DOTFILES_ROOT}/shell-common"
        export SHELL_COMMON
    fi
    return 0
}

# _dotfiles_root_git_common_dir DIR
#
# Echo the absolute, symlink-resolved --git-common-dir of DIR. Returns 1
# when DIR is not a git checkout or the path cannot be resolved.
_dotfiles_root_git_common_dir() {
    _drgcd_dir="${1:-}"
    [ -d "$_drgcd_dir" ] || return 1

    # --git-common-dir is relative to DIR for a main worktree ('.git') and
    # absolute for a linked worktree, so resolve it from inside DIR — one
    # subshell, since the second `cd` must run from wherever the first
    # landed.
    (
        cd "$_drgcd_dir" 2>/dev/null || exit 1
        _drgcd_rel=$(git rev-parse --git-common-dir 2>/dev/null) || exit 1
        [ -n "$_drgcd_rel" ] || exit 1
        cd "$_drgcd_rel" 2>/dev/null && pwd -P
    ) || return 1
}

# _dotfiles_root_canonical_common_dir CANONICAL_DIR
#
# Resolve CANONICAL_DIR's --git-common-dir into the global
# $_DOTFILES_ROOT_CANON_COMMON, memoized per process (issue #1505).
# Returns 0 with the global set and non-empty, or 1 with it emptied.
#
# Why memoize: _dotfiles_root_warn_if_foreign_source runs once per guarded
# helper file, and every one of those calls re-resolves the identical
# $HOME/dotfiles --git-common-dir — a subshell plus `git rev-parse` plus two
# `cd`s each time. With seven helpers wired into one shell startup that is
# six redundant fork storms.
#
# Why a global instead of stdout: a `$(...)` capture runs the function in a
# subshell, so the cache write would be discarded on every call and the
# memoization would silently never take effect. Callers must invoke this in
# the current shell and read the global.
#
# The cache is keyed on the *value of the CANONICAL_DIR argument itself*
# (issue #1505 PR #1548 review, codex+agy) — not on $HOME. The only current
# caller always builds its argument as "${HOME}/dotfiles", so a $HOME change
# already produces a different $1 and still busts the cache correctly; keying
# on $1 additionally keeps a same-$HOME call with a genuinely different
# CANONICAL_DIR (this function's own documented, general-purpose contract)
# from returning another directory's stale --git-common-dir. $HOME is
# reassigned within a single process both by the bats suite
# (setup_isolated_home) and by real `env HOME=... sh -c` callers, so it must
# still invalidate — which it does, transitively, via the argument. Only
# successful lookups are cached, so a $HOME/dotfiles that appears later in
# the same process is still picked up.
#
# The self side is deliberately NOT cached — it differs per call site and
# never repeats within one process.
_dotfiles_root_canonical_common_dir() {
    if [ "${_DOTFILES_ROOT_CANON_KEY-}" = "${1-}" ] \
        && [ -n "${_DOTFILES_ROOT_CANON_COMMON-}" ]; then
        return 0
    fi

    _DOTFILES_ROOT_CANON_COMMON=$(_dotfiles_root_git_common_dir "${1:-}") || {
        _DOTFILES_ROOT_CANON_COMMON=""
        return 1
    }
    if [ -z "$_DOTFILES_ROOT_CANON_COMMON" ]; then
        return 1
    fi

    _DOTFILES_ROOT_CANON_KEY="${1-}"
    return 0
}

# _dotfiles_root_warn_if_foreign_source SELF_PATH
#
# Advisory guard (issue #1454): print one WARN block to stderr when the
# caller was sourced from a checkout that is a different git repository
# than $HOME/dotfiles. SELF_PATH must be the caller's own
# ${BASH_SOURCE[0]} — $SHELL_COMMON is deliberately never read here, since
# a wrong $SHELL_COMMON is precisely the failure this detects; only the
# actual load path is trustworthy.
#
# A linked worktree of the same repository is NOT foreign (both resolve to
# the same --git-common-dir) and stays silent. Silent no-op when SELF_PATH
# is empty/missing, git is unavailable, or $HOME/dotfiles is absent or not
# a git repo — there is nothing to compare against, and warning in a
# sandboxed HOME would be pure noise.
#
# Never blocks: a user intentionally testing an alternate checkout is
# valid, so this only informs and always returns 0.
_dotfiles_root_warn_if_foreign_source() {
    _dwfs_self="${1:-}"
    [ -n "$_dwfs_self" ] || return 0
    [ -f "$_dwfs_self" ] || return 0
    command -v git >/dev/null 2>&1 || return 0

    [ -n "${HOME:-}" ] || return 0
    _dwfs_canonical="${HOME}/dotfiles"
    [ -d "$_dwfs_canonical" ] || return 0

    _dwfs_dir=$(dirname "$_dwfs_self" 2>/dev/null) || return 0

    _dwfs_self_common=$(_dotfiles_root_git_common_dir "$_dwfs_dir") || return 0
    # Called in the current shell, NOT via $(...) — the memoization writes a
    # global, which a subshell capture would throw away (issue #1505).
    _dotfiles_root_canonical_common_dir "$_dwfs_canonical" || return 0
    _dwfs_canonical_common="$_DOTFILES_ROOT_CANON_COMMON"

    [ "$_dwfs_self_common" != "$_dwfs_canonical_common" ] || return 0

    # Raw printf, not ux_lib: this runs during bootstrap and reaching
    # ux_lib.sh would require the very $SHELL_COMMON under suspicion.
    printf '%s\n' \
        "[WARN] dotfiles: loaded from a foreign checkout (issue #1454)" \
        "         loaded: ${_dwfs_self}" \
        "      canonical: ${_dwfs_canonical}" \
        "  Source shared files via \${SHELL_COMMON:-\$HOME/dotfiles/shell-common}/... — never by find/PATH discovery." \
        "  Ignore this if you are intentionally testing an alternate checkout." >&2

    return 0
}

# _dotfiles_root_guard_self SELF_PATH [LABEL]
#
# Single SSOT for the caller-side wiring of the #1454 guard (issue #1505).
# Every shared helper file that skills source non-interactively calls this
# right after sourcing dotfiles_root.sh, so the `command -v` probe, the
# call, and the #724 diagnostic exist exactly once repo-wide instead of
# being copy-pasted per file.
#
#   SELF_PATH — the caller's OWN load path. It must be computed in the
#               caller's top-level code, not here: zsh's FUNCTION_ARGZERO
#               rebinds $0 to the sourced file only for that file's own
#               top-level statements, so inside this function $0 is this
#               function's name and the caller's identity is unrecoverable.
#   LABEL     — short caller name for the #724 diagnostic prefix
#               (e.g. "gh_pr_reply"); defaults to "dotfiles".
#
# Defense in depth (#724): a helper that is present but failed to parse
# leaves _dotfiles_root_warn_if_foreign_source undefined. Say so once on
# stderr rather than disabling the guard in silence. Never fatal.
_dotfiles_root_guard_self() {
    if command -v _dotfiles_root_warn_if_foreign_source >/dev/null 2>&1; then
        _dotfiles_root_warn_if_foreign_source "${1:-}" || true
    else
        printf '[%s] %s missing or did not define _dotfiles_root_warn_if_foreign_source — #1454 guard skipped (#724).\n' \
            "${2:-dotfiles}" \
            "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/dotfiles_root.sh" >&2
    fi
    return 0
}
