# live — sourcing shell-common (the Step 1 loader block)

The block is a one-liner on purpose: every skill `Bash` call is a fresh
`bash --noprofile --norc`, so **nothing sourced in an earlier call carries
over**. Paste it into the same call that uses `devx_pr_verify_live_parse`.

It resolves `shell-common` in two tiers — the dotfiles checkout first
(`$DOTFILES_ROOT`, default `$HOME/dotfiles`), then this plugin's own vendored
copy under `$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common` — and fails loudly
with the install hint if neither yields a usable function. `unset -f` first so
a stale definition from an outer shell cannot win. Same shape as
`review-all/references/shell-common-source.md`.

## Step 1 — `devx_pr_verify_live_parse`

```sh
_SC="${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common"; if [ ! -f "$_SC/functions/devx_pr_verify_live.sh" ]; then [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || { printf '[gh-verify:live] no shell-common under %s, and CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; _SC="$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common"; fi; unset -f devx_pr_verify_live_parse 2>/dev/null || :; [ -f "$_SC/functions/devx_pr_verify_live.sh" ] && . "$_SC/functions/devx_pr_verify_live.sh"; command -v devx_pr_verify_live_parse >/dev/null 2>&1 || { printf '[gh-verify:live] %s did not load a usable shell-common. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; export SHELL_COMMON="$_SC"
```

Then call `devx_pr_verify_live_parse "$@"`.
