#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/util/setup_mode_read.sh
# Synced 2026-10-10T03:07Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/util/setup_mode_read.sh
# SSOT for reading ~/.dotfiles-setup-mode (issue #1810).
#
# No interactive guard on purpose — same rationale as
# tools/custom/lib/install_helpers.sh: every consumer (shell init, hooks,
# claude/plugin/*.sh, bats) must be able to source this and get the function,
# including under DOTFILES_TEST_MODE=1. Pure function, no ux_* dependency.

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
    _dsm_file="$HOME/.dotfiles-setup-mode"
    [ -f "$_dsm_file" ] || { echo ""; return 0; }
    _dsm_raw=$(tr -d ' \t\n\r' < "$_dsm_file" 2>/dev/null)
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
