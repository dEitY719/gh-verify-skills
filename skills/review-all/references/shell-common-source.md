# review-all — sourcing shell-common (the two loader blocks)

Both blocks below are one-liners on purpose: every skill `Bash` call is a fresh
`bash --noprofile --norc`, so **nothing sourced in an earlier call carries over**.
Paste the block into the same call that uses the function it loads.

Each one resolves `shell-common` in two tiers — the dotfiles checkout first
(`$DOTFILES_ROOT`, default `$HOME/dotfiles`), then the plugin's own vendored copy
under `$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common` — and fails loudly with the
install hint if neither yields a usable function. `unset -f` first so a stale
definition from an outer shell cannot win.

## Step 1 — `devx_pr_review_all_parse`

```sh
_SC="${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common"; if [ ! -f "$_SC/functions/devx_pr_review_all.sh" ]; then [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || { printf '[gh-verify:review-all] no shell-common under %s, and CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; _SC="$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common"; fi; unset -f devx_pr_review_all_parse 2>/dev/null || :; [ -f "$_SC/functions/devx_pr_review_all.sh" ] && . "$_SC/functions/devx_pr_review_all.sh"; command -v devx_pr_review_all_parse >/dev/null 2>&1 || { printf '[gh-verify:review-all] %s did not load a usable shell-common. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; export SHELL_COMMON="$_SC"
```

Then call `devx_pr_review_all_parse "$@"`.

## Step 3 — `_dotfiles_setup_mode`

Gates the `opencode` and `hermes` lanes, which run on the internal PC only.

```sh
_SC="${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common"; if [ ! -f "$_SC/functions/dotfiles_setup_mode.sh" ]; then [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || { printf '[gh-verify:review-all] no shell-common under %s, and CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; _SC="$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common"; fi; unset -f _dotfiles_setup_mode 2>/dev/null || :; [ -f "$_SC/functions/dotfiles_setup_mode.sh" ] && . "$_SC/functions/dotfiles_setup_mode.sh"; command -v _dotfiles_setup_mode >/dev/null 2>&1 || { printf '[gh-verify:review-all] %s did not load a usable shell-common. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; export SHELL_COMMON="$_SC"; _dotfiles_setup_mode
```

Undefined, both gates read non-internal and skip — looking exactly like a
missing CLI.
