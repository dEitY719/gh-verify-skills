#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/tools/integrations/claude.sh
# Synced 2026-09-05T02:32Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.
# Bridge only. lib/vendor/shell-common/functions/gh_pr_review.sh recovers a
# missing `_dotfiles_setup_mode` by sourcing
# "$SHELL_COMMON/tools/integrations/claude.sh" behind a `[ -f ]` guard. Once the
# `_SC` fallback has exported SHELL_COMMON to this vendor root that path has to
# exist, or the guard fails silently, `_mode` stays empty and every internal-only
# CLI reports the misleading "~/.dotfiles-setup-mode != internal". The rest of
# upstream claude.sh (claude_yolo, account routing, ux_lib) is deliberately not
# vendored — only the one function this plugin's gates read.

# shellcheck source=/dev/null
. "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/dotfiles_setup_mode.sh"
