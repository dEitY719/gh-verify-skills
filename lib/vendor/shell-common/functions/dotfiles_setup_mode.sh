#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/tools/integrations/claude.sh (_dotfiles_setup_mode)
# Synced 2026-09-05T02:32Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/dotfiles_setup_mode.sh
#
# Extracted, not copied whole: upstream defines _dotfiles_setup_mode inside
# claude.sh, a 1500-line interactive integration file the rest of which this
# plugin does not need. Only this function is load-bearing here —
# gh-verify:review-all Step 3 gates its opencode and hermes lanes on it, and
# lib/vendor/shell-common/functions/gh_pr_review.sh's
# _gh_pr_review_require_internal_cli recovers through it. Undefined, both
# silently resolve to non-internal and those lanes skip with no explanation.

# _dotfiles_setup_mode — read ~/.dotfiles-setup-mode and canonicalise.
#
# Returns one of: public | internal | external | "" (file missing).
# Legacy numeric values ("1|2|3") written by older shell-common/setup.sh
# (pre-#571) are translated to their symbolic equivalents, so users
# don't hit a wedge after upgrading. Empty when the file doesn't exist
# (fresh install before setup.sh has run).
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
