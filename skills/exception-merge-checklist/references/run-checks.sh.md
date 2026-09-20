# Step 2 — the verbatim call block

Step 2 pastes the block below. It is the whole of Step 2: the ten checks, their
run order, their degradation rules and the score live in
`lib/run-checks.sh`, not in the model's head
(dEitY719/gh-verify-skills#35).

It expects `PR` and `TARGET_REPO` bound by Step 1, and reads the two flag
variables Step 1 also binds — `BUILD_CMD` (from `--build-cmd`, default
`bun run build`) and `SKIP_BISECT` (`1` when `--skip-bisect` was given).

```sh
_EMC="${GH_VERIFY_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"                                    # tier 1, tier 2
[ -n "$_EMC" ] || {                                                                  # tier 5
    printf '[gh-verify:exception-merge-checklist] no plugin root: CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' >&2
    return 1 2>/dev/null || exit 1
}
_EMC="$_EMC/skills/exception-merge-checklist/lib/run-checks.sh"
[ -r "$_EMC" ] || {                                                                  # tier 5
    printf '[gh-verify:exception-merge-checklist] %s is not readable. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_EMC" >&2
    return 1 2>/dev/null || exit 1
}
BUILD_CMD="${BUILD_CMD:-bun run build}" SKIP_BISECT="${SKIP_BISECT:-0}" \
    sh "$_EMC" "$PR" "$TARGET_REPO"
```

## Why there is no `unset -f` / `command -v` proof here

That proof belongs to a block that **sources** a file into the caller's shell —
it is what separates "this load defined the function" from "something earlier
did" (`harness-skills`' `references/plugin-root.md`). This block *executes* a
file in its own process. Nothing is defined in the caller's shell, so there is
nothing to have been inherited and nothing to leave behind; `[ -r ]` plus the
script's own `[FATAL]` line is the whole proof. Same reasoning as
`gh-issue-skills`' `lib/claim-issue.sh`.

There is still **no tier that guesses**. With neither `GH_VERIFY_ROOT` nor
`CLAUDE_PLUGIN_ROOT` set the block stops and names the way out, rather than
composing a path from `$PWD` — which for this skill is the repository under
audit, so a hostile PR could otherwise ship the script the audit runs
(`harness-skills#22`).

## What comes back

Twelve tab-separated rows on stdout:

```
C1<TAB>PASS<TAB>Closes #7
…
C10<TAB>WARN<TAB>new framework calls, no mocks
SCORE<TAB>5/10<TAB>3 WARN, 2 FAIL, 0 N/A
VERDICT<TAB>1<TAB>2 FAIL, 3 WARN — NOT safe to merge
```

- **Exit 0 whatever the verdicts.** "No fail-fast" is this exit code rather
  than an instruction: a `FAIL` row is data, so the caller cannot stop on the
  first one.
- **Exit 2, one `[FATAL]` line on stderr, no rows** means the helper could not
  run at all — a missing argument, no `gh`, no git worktree. That is the
  escape hatch #35 asked for: a broken harness no longer arrives disguised as
  ten check verdicts. It reuses SKILL.md's existing exit-2 "cannot proceed"
  code rather than inventing a fourth number, so Step 2 propagates it as-is.
- **`VERDICT`'s second field is the exit code the *skill* returns** — 0 with no
  FAIL row, 1 otherwise, exactly the table in `references/checks.md` →
  "Result aggregation". The helper itself still exits 0, because a FAIL verdict
  is not a helper failure.

`lib/run-checks.selfcheck.sh` extracts the block above from this file and runs
it, so rewording a variable here without changing the script fails CI.
