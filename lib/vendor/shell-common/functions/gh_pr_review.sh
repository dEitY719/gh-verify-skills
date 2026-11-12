#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/gh_pr_review.sh
# Synced 2026-11-12T03:50Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
case $- in *i*) ;; *) [ -n "${DOTFILES_FORCE_INIT-}" ] || return 0 ;; esac
# shell-common/functions/gh_pr_review.sh
# gh-pr-review — synchronous PR review delegation to an external AI CLI.
# Sibling of gh-pr-approve (gh_pr_approve.sh) and gh-pr-reply
# (gh_pr_reply.sh). Reads the same `--ai <codex|agy|claude|opencode|hermes>`
# contract but does a single-shot opinion-collection run inline (no worktree
# spawn, no detached worker) — the skill's only side effect is one PR comment
# unless `--no-post-comment` is set.
#
# SSOT: this file is the entry point for the Step 1 arg-parse logic, the AI
# CLI dispatch, the prompt builder, and the PR comment body builder, whose
# bodies live in the lib/ modules it loads below (#2382). The matching
# claude/skills/gh-pr-review/SKILL.md delegates to gh_pr_review on
# Steps 1, 4 (PROMPT_FILE path allocation only), 5, and 6. The bats fixture
# tests/bats/functions/_fixtures/gh_pr_review_arg_parse.sh sources this
# file so the arg-parse contract has exactly one definition.

# Advisory only (issue #1454): a stale copy of this file living in another
# directory named `dotfiles` once got sourced instead of this one, surfacing
# as a bogus "Unknown --ai value". The guard compares our own load path
# against $HOME/dotfiles and warns on a mismatch; it never blocks.
#
# Self-path: zsh never populates $BASH_SOURCE, so reading it there left the
# guard permanently inert. zsh instead rebinds $0 to the file being sourced
# (FUNCTION_ARGZERO, on by default) for the duration of this top-level code,
# so branch on the shell — the same idiom as functions/my_help.sh. This
# branch is irreducibly per-file: inside a function, $0 is the function's
# own name, so it cannot move into dotfiles_root.sh.
#
# Everything after it (probe + call + #724 diagnostic) lives exactly once,
# in _dotfiles_root_guard_self (issue #1505).
if [ -n "${ZSH_VERSION-}" ]; then
    _drg_self="$0"
elif [ -n "${BASH_VERSION-}" ]; then
    _drg_self="${BASH_SOURCE[0]-}"
else
    _drg_self=""
fi
_drg_helper="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/dotfiles_root.sh"
if [ -r "$_drg_helper" ]; then
    . "$_drg_helper" || true
fi
if command -v _dotfiles_root_guard_self >/dev/null 2>&1; then
    _dotfiles_root_guard_self "$_drg_self" "gh-pr-review"
else
    printf '[gh-pr-review] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
unset _drg_helper

# ux_lib (issue #2257): error lines go through ux_error like the sibling
# gh_pr_approve.sh / gh_pr_reply.sh. The gh-pr:review skill and the bats
# fixtures source this file into a bare non-interactive shell where the
# loader never ran, so load ux_lib here when ux_error is missing; a
# vendored shell-common without tools/ux_lib gets a plain stderr stand-in
# so no error message is ever lost to "command not found". Any ux_error
# already defined wins on purpose -- e.g. devx_pr_review_all_fanout defines
# a plain one first so lane skip reasons carry no glyph.
if ! command -v ux_error >/dev/null 2>&1; then
    _gpr_ux_lib="${SHELL_COMMON:-${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common}/tools/ux_lib/ux_lib.sh"
    # shellcheck disable=SC1090
    [ -r "$_gpr_ux_lib" ] && . "$_gpr_ux_lib"
    unset _gpr_ux_lib
    if ! command -v ux_error >/dev/null 2>&1; then
        ux_error() { printf '%s\n' "$1" >&2; }
    fi
fi

# Everything but help and the public names lives in lib/, one file per
# responsibility (#2382): the AI CLI runner and output gate (ai_cli_run.sh,
# #2381, shared with the issue review engine), argument parsing, target
# resolution, PR material, prompt, comment, and the orchestrator. Each path
# is spelled out, not built from a loop variable, so a vendoring repo's
# closure check sees every file this one reaches. A shell-common without
# lib/ (the vendored-copy bats fixtures link only functions/) falls back to
# the lib beside this file's real location. The root is picked ONCE, so the
# modules never mix two checkouts (an old ai_cli_run.sh with new callers),
# and a module that is still missing fails the source with status 1 instead
# of leaving a half-defined command behind (PR #2386 review).
_gpr_lib_dir=""
if [ ! -d "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib" ] && [ -n "$_drg_self" ]; then
    _gpr_lib_dir=$(cd -P -- "$(dirname -- "$_drg_self")/../lib" 2>/dev/null && pwd) ||
        _gpr_lib_dir=""
fi
for _gpr_lib in \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/ai_cli_run.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_args.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_target.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_material.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_prompt.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_comment.sh" \
    "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/gh_pr_review_run.sh"; do
    [ -z "$_gpr_lib_dir" ] || _gpr_lib="$_gpr_lib_dir/${_gpr_lib##*/}"
    # shellcheck disable=SC1090
    if [ ! -r "$_gpr_lib" ] || ! . "$_gpr_lib"; then
        ux_error "[gh-pr-review] could not load $_gpr_lib (#2382)"
        unset _gpr_lib _gpr_lib_dir _drg_self
        return 1
    fi
done
unset _gpr_lib _gpr_lib_dir _drg_self

# ============================================================================
# Help (the orchestrator itself is lib/gh_pr_review_run.sh)
# ============================================================================

gh_pr_review_help() {
    # The hyphenated alias is the canonical user-facing command name;
    # the help text mirrors claude/skills/gh-pr-review/references/help.md
    # so `gh-pr-review -h` and `/gh-pr-review help` produce equivalent
    # surface area.
    cat <<'EOF'
gh-pr-review — delegate a GitHub PR's review to an external AI CLI
for a second opinion. Streams the AI's findings to stdout and posts
them as a PR comment by default. Does NOT submit a decision.

Usage:
  gh-pr-review --ai <codex|agy|claude|opencode|hermes> [flags] [<pr-number>] [<remote>]
  gh-pr-review -h | --help | help

Flags:
  --ai <codex|agy|claude|opencode|hermes>
                               required; external CLI to delegate to
  --review <preset>            default 'default'; KR aliases supported
                               enum: default | quick | thorough |
                                     security | performance
                               KR:   보통 | 간단 | 꼼꼼 (꼼꼼하게) |
                                     보안 | 성능
  --user <name>                claude only; multi-account routing via
                               _claude_resolve_account
  --no-post-comment            skip the PR comment; stdout only
  --paths <path>               repeatable; review only these files. The
                               diff is filtered by path, so a scoped run
                               stays on the inline path however large the
                               whole PR is. No match -> exit 1 (#1616)

OpenCode:
  --ai opencode                model from
                               DOTFILES_OPENCODE_REVIEW_MODEL (unset ->
                               skipped); prompt is attached
                               with --file; execution runs in an
                               isolated temporary directory

Hermes:
  --ai hermes                  internal AI coding CLI;
                               prompt is attached with --file (invocation
                               shape unverified — see ai-cli-invocation.md)

Positional:
  <pr-number>                  optional — auto-detect from current
                               branch via `gh pr view`
  <remote>                     default 'origin'

Examples:
  gh-pr-review --ai codex 99
  gh-pr-review --ai agy --review thorough 99
  gh-pr-review --ai claude --review 꼼꼼 99
  gh-pr-review --ai claude --user work 99
  gh-pr-review --ai opencode 99
  gh-pr-review --ai hermes 99
  gh-pr-review --ai codex --no-post-comment 99
  gh-pr-review --ai codex 99 upstream

Exit codes:
  0 — review completed (or comment soft-failed but stdout has output)
  1 — runtime failure (missing CLI, unknown claude user, PR fetch
      failed, external CLI returned non-zero, gh not authenticated)
  2 — argument error (missing --ai, unknown --ai/--review, --user with
      non-claude --ai)
  130 — interrupted (Ctrl-C / SIGINT or SIGTERM); the handler reports
      128+SIGINT (130) for both signals deliberately — it does not
      distinguish TERM's conventional 143 — since either one aborts the
      same cleanup path. Temp files are removed and no PR comment is
      posted.
EOF
}

# ============================================================================
# Aliases — hyphenated command names per shell-common convention
# ============================================================================

# Public entry (#2195): the PATH executable tools/custom/gh_pr_review.sh (also
# ~/.local/bin/gh-pr-review) sources this file and calls _gh_pr_review_main; this thin
# wrapper keeps the `gh_pr_review` / `gh-pr-review` names in interactive shells.
gh_pr_review() {
    "${SHELL_COMMON:-${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common}"/tools/custom/gh_pr_review.sh "$@"
}

alias gh-pr-review='gh_pr_review'
alias gh-pr-review-help='gh_pr_review_help'

# Help registry (#2135): skipped when sourced without util/help_registry.sh.
command -v _register_help >/dev/null 2>&1 || return 0
_register_help gh_pr_review_help "[Development] gh-pr-review external-AI review delegation"
_register_func gh_pr_review "Delegate a PR review to an external AI CLI"
