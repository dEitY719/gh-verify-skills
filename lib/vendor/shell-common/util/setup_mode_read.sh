#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/util/setup_mode_read.sh
# Synced 2026-10-17T01:33Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/util/setup_mode_read.sh
# SSOT for reading ~/.dotfiles-setup-mode (issue #1810).
#
# No interactive guard on purpose — same rationale as
# tools/custom/lib/install_helpers.sh: every consumer (shell init, hooks,
# claude/plugin/*.sh, bats) must be able to source this and get the function,
# including under DOTFILES_TEST_MODE=1. Pure function, no ux_* dependency.
#
# No re-source guard on purpose (#2158 review): re-sourcing only redefines
# functions (no forks), and a guard would keep `src` from picking up edits.

# _dotfiles_setup_mode — read ~/.dotfiles-setup-mode and canonicalise.
#
# Returns one of: public | internal | external | "" (file missing).
# Legacy numeric values ("1|2|3") written by older shell-common/setup.sh
# (pre-#571) are translated to their symbolic equivalents, so users
# don't hit a wedge after upgrading. Empty when the file doesn't exist
# (fresh install before setup.sh has run).
#
# `tr -d ' \t\n\r'` is load-bearing: a CRLF-saved file or a stray space
# silently fails every `[ "$mode" = internal ]` check without it (#1810).
_dotfiles_setup_mode() {
    # DOTFILES_SETUP_MODE env wins over the file (#2137): explicit mode passing.
    if [ -n "${DOTFILES_SETUP_MODE-}" ]; then
        _dsm_raw=$(printf '%s' "$DOTFILES_SETUP_MODE" | tr -d ' \t\n\r')
    else
        _dsm_file="$HOME/.dotfiles-setup-mode"
        [ -f "$_dsm_file" ] || { echo ""; return 0; }
        _dsm_raw=$(tr -d ' \t\n\r' < "$_dsm_file" 2>/dev/null)
    fi
    case "$_dsm_raw" in
        1|public)   echo "public" ;;
        2|internal) echo "internal" ;;
        3|external) echo "external" ;;
        *)          echo "$_dsm_raw" ;;
    esac
}

# _dotfiles_setup_mode_proxy [mode] — proxy policy of a mode (default: current).
#
# Prints "required" (internal: corporate proxy from env/proxy.local.sh),
# "forbidden" (public|external: an inherited proxy is wrong and gets unset), or
# "" (unset/unknown mode: leave the environment alone). Single owner of the
# "which mode uses a proxy" rule — util/setup_mode.sh and check_proxy.sh read it.
_dotfiles_setup_mode_proxy() {
    case "${1-$(_dotfiles_setup_mode)}" in
        internal)        echo "required" ;;
        public|external) echo "forbidden" ;;
        *)               echo "" ;;
    esac
}

# Policy queries (#2158) — consumers ask "what does this mode imply" instead of
# comparing `= internal` themselves, so a new mode is one edit here. Each takes
# an optional mode (default: current, DOTFILES_SETUP_MODE env first via
# _dotfiles_setup_mode) and always prints a value. An explicit empty argument
# means "no mode" (as an unset mode file), not "current" — `${1-...}`.

# _dotfiles_setup_mode_is <mode> — true when the current mode is <mode>.
_dotfiles_setup_mode_is() {
    [ "$(_dotfiles_setup_mode)" = "${1-}" ]
}

# _dotfiles_setup_mode_accounts [mode] — Claude account layout: "single"
# (internal: ~/.claude only, claude-accounts unused, #571) or "multi".
_dotfiles_setup_mode_accounts() {
    case "${1-$(_dotfiles_setup_mode)}" in
        internal) echo "single" ;;
        *)        echo "multi" ;;
    esac
}

# _dotfiles_setup_mode_gh_host [mode] — GitHub host class: "ghes" (internal,
# host from DOTFILES_GHES_HOST) or "github" (github.com).
_dotfiles_setup_mode_gh_host() {
    case "${1-$(_dotfiles_setup_mode)}" in
        internal) echo "ghes" ;;
        *)        echo "github" ;;
    esac
}

# _dotfiles_setup_mode_ca [mode] — CA trust: "custom" (internal: corporate
# proxy CA via security.local.sh), "system" (public|external), "none"
# (unset/unknown mode).
_dotfiles_setup_mode_ca() {
    case "${1-$(_dotfiles_setup_mode)}" in
        internal)        echo "custom" ;;
        public|external) echo "system" ;;
        *)               echo "none" ;;
    esac
}
