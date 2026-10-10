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
_SC="${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common"; if [ ! -f "$_SC/functions/devx_pr_review_all.sh" ]; then [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || { printf '[gh-verify:review-all] no shell-common under %s, and CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; _SC="$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common"; fi; unset -f devx_pr_review_all_parse 2>/dev/null || :; unalias devx_pr_review_all_parse 2>/dev/null || :; export SHELL_COMMON="$_SC"; [ -f "$_SC/functions/devx_pr_review_all.sh" ] && . "$_SC/functions/devx_pr_review_all.sh"; [ "$(command -v devx_pr_review_all_parse 2>/dev/null)" = devx_pr_review_all_parse ] || { unset SHELL_COMMON; printf '[gh-verify:review-all] %s did not load a usable shell-common. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }
```

Then call `devx_pr_review_all_parse "$@"`.

## Step 3 — no setup-mode gate any more

Step 3 used to load `_dotfiles_setup_mode` here to gate the `opencode` and
`hermes` lanes to the internal PC. dEitY719/gh-verify-skills#77 D-6 and
dEitY719/dotfiles#2069 removed that gate everywhere: every lane — `claude`,
`codex`, `opencode`, `agy`, `hermes` — is tried on every PC, and one whose CLI
or model env is missing simply comes back `skip`. Step 3 loads
`devx_pr_review_all.sh` with the same tiered loader as Step 1
(`duplicate-review-guard.md` carries the block) and calls
`devx_pr_review_all_fanout`, which sources `gh_pr_review.sh` from the
`SHELL_COMMON` that loader exported — the vendored copy when there is no
dotfiles checkout.
