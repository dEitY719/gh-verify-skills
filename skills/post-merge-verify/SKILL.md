---
name: post-merge-verify
description: >-
  Closes the impl tab, rebases main, opens a herdr session for the repo's
  verify skill. Use for /gh-verify:post-merge-verify, /gh:pr-post-merge-verify,
  /gh-pr-post-merge-verify,
  "머지 후 검증 세션", "post-merge verify". Dispatch only: gh-pr:merge calls it,
  gh-verify:merged verifies.
license: MIT
allowed-tools: Bash, Read, Grep
metadata:
  model_recommendation:
    tier: haiku
    reason: "bounded shell/herdr orchestration off a JSON registry; every branch is soft-fail, no judgement calls"
    claude: prefer
    non_claude: advisory-only
---

# gh-verify:post-merge-verify — Dispatch a post-merge verification session

## Help

If arg #1 is `-h`/`--help`/`help`, output `references/help.md` verbatim and
stop (no herdr calls, no git calls). That file tables the positionals
`<pr-number> [remote]`.

## Role

Automates the manual post-merge routine for **registered repos only**: close
the tab that implemented the PR, bring the main checkout up to date, and hand
the verification to a fresh session. It never verifies anything itself and
never *writes* to GitHub — `gh-pr:merge` has already merged and reported.

**Every failure is soft** — one `[WARN]` line, exit 0 — because its caller's
report must print either way (F-6). The one exception is a stale main
checkout: verifying stale code proves nothing, so that stops the run.

## Step 1: Gate on the watched-repos registry (F-1)

```bash
WATCHED_FILE="${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}"
VERIFY_SKILL=""
if command -v jq >/dev/null 2>&1 && [ -r "$WATCHED_FILE" ]; then
    VERIFY_SKILL=$(jq -r --arg r "$TARGET_REPO" \
        '(if type == "array" then . else (.repos // []) end) | .[] | select(.repo == $r) | .verify_skill // empty' "$WATCHED_FILE" 2>/dev/null)
fi
```

- Empty `VERIFY_SKILL`, an unreadable file, or no `jq` → **do nothing at
  all**, no output. An unwatched repo behaves exactly as before dEitY719/dotfiles#1511.
- `jq` non-zero (the file exists but is not JSON) → one `[WARN]`, then skip.
- `VERIFY_SKILL` outside the allowlist (`gh-verify:merged`,
  `gh-verify:live`) → one `[WARN]`, stop before any herdr call. It reaches
  a `--dangerously-skip-permissions` agent's prompt, so it is never free text.
- `command -v herdr` missing → silent no-op.

Schema and registration procedure: `references/watched-repos-schema.md`.

## Step 2: Resolve the target repo + host

Same binding as `gh-pr:merge` — repo **and** host from one remote URL (dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407); see
`gh-pr:merge`'s `references/github-target.md` (dotfiles `claude/skills/gh-pr-merge/`). No API call is made: the slug is only the registry key and part of the agent name.

Also bind `HEAD_BRANCH` and `BASE_BRANCH` (the merged PR's head/base branches)
plus `REMOTE` (the `[remote]` positional, default `origin`). `gh-pr:merge`
already read both refs in its own Step 2 and passes them down; standalone,
recover them with the host-pinned `gh pr view` in `references/dispatch.sh.md`
→ "Inputs". Step 3 fetches and rebases with those — never a literal
`origin`/`main`.

## Step 3: Run the dispatch

Paste `references/dispatch.sh.md` verbatim. It performs, in order:

1. `git worktree list --porcelain` → the local path of the merged head branch.
2. `herdr agent list` → the `tab_id` whose `cwd`/`foreground_cwd` sits on that
   path → `herdr tab close <tab_id>`. Not found → note it and continue (F-2).
3. `git -C "$MAIN_ROOT" fetch "$REMOTE" "$BASE_BRANCH"` + `rebase "$REMOTE/$BASE_BRANCH"`,
   only once `MAIN_ROOT` is a git worktree root and its HEAD is on
   `BASE_BRANCH`. Dirty tree, wrong/detached branch, or conflict → `[WARN]`,
   `rebase --abort`, **stop** (F-3).
4. `git worktree add --detach "$PMV_SCRATCH" "$REMOTE/$BASE_BRANCH"` where
   `PMV_SCRATCH` is `<git-common-dir>/pr-post-merge-verify/pr-<N>` — created if
   absent, reused if present, never torn down here. Then
   `herdr tab create --workspace <ws> --cwd "$PMV_SCRATCH" --label "pr-<N>"` and
   `herdr agent start mv-<repo>-pr-<N> --kind claude --pane <pane>
   -- --dangerously-skip-permissions` (F-4). The session does **not** live in
   `MAIN_ROOT`: that checkout is shared, and step 3 rebases it (dEitY719/dotfiles#1577).
5. `herdr agent prompt <agent> "/<verify-skill> <N>" --wait --until idle` (F-5),
   then report the new `tab_id`, the agent name, and the `attach` hint.

Every decision above is mirrored executably in
dotfiles' `tests/bats/skills/_fixtures/gh_pr_post_merge_verify.sh` — change one, change both.

## Constraints

- Never resolve a rebase conflict, and never `--force` anything.
- Never open more than one session per PR — no batching, no retries.
- Never *write* to GitHub — the head/base ref read is its only API call, and
  never touch the unattended `pr_merge_train_cron.sh` path (dEitY719/dotfiles#1511 non-goal).
- Never act on a repo missing from the watched-repos registry.

## Related Skills

`gh-pr:merge` reads `references/dispatch.sh.md` and runs it inline at the end of
its Step 5 — never `Skill(gh-verify:post-merge-verify, ...)`, which vanished inside
`gh-pr:merge-train`'s loop (dEitY719/dotfiles#1565); this skill stays the standalone manual entry
point and the SSOT for that block · `gh-verify:merged`
/ `gh-verify:live` are what the dispatched session actually runs (the
registry picks which) · `gh-pr:merge-train` shares the herdr
workspace→tab→agent→prompt sequence via `pr_merge_train_cron.sh`.
