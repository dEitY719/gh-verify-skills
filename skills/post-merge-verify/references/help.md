# gh-verify:post-merge-verify — Help

## Arguments

| # | Name | Default | Description |
|---|------|---------|-------------|
| 1 | `<pr-number>` or `-h`/`--help`/`help` | — | The PR that was just merged (required unless help) |
| 2 | remote-name | `origin` | Git remote whose repo owns the PR; binds the repo slug and host, and is the remote step 5 fetches/rebases from |

## Usage

- `/gh-verify:post-merge-verify 51` — dispatch verification for PR #51 on `origin`'s repo
- `/gh-verify:post-merge-verify 51 upstream` — same, against the `upstream` remote
- `/gh-verify:post-merge-verify -h` / `--help` / `help` — print this help

Normally you do not type this: `gh:pr-merge` calls it at the end of its
Step 5. Run it by hand when a merge happened outside `gh:pr-merge`, or when a
dispatch soft-failed and you want to retry it.

## What it does

1. Reads the untracked watched-repos registry (`${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}`,
   the same file `issue_watcher_cron.sh` reads). **A repo that is not
   registered there gets nothing at all** — no output, no herdr call, no git call.
2. Checks `command -v jq` and `command -v herdr`. Either missing → silent
   no-op: the feature is unavailable, which is not an error worth a line.
3. `git worktree list --porcelain` → the local worktree of the merged head branch.
4. `herdr agent list` → the tab whose `cwd`/`foreground_cwd` sits on that
   worktree → `herdr tab close <tab_id>`.
5. In the **main checkout** (never a worktree, and only once it resolves to a
   git worktree root whose HEAD is on the PR's base branch):
   `git fetch <remote> <base>` + `git rebase <remote>/<base>`. The remote is
   argument 2 and the base branch is the PR's `baseRefName` — neither is
   hardcoded, because a watched repo may default to `master`/`develop` or be
   reached through `upstream`.
6. `git worktree add --detach <git-common-dir>/pr-post-merge-verify/pr-<N> <remote>/<base>`
   — the verification session's own directory, created if absent and reused if
   it is already there. It is **not** the main checkout: that one is shared
   with humans and other sessions, and step 5 rebases it (#1577).
7. `herdr tab create --cwd <that worktree> --label pr-<N>`. The herdr
   *workspace* is still looked up from the main checkout — it only groups the
   tab, and a worktree created a second ago has no workspace of its own.
8. `herdr agent start mv-<repo>-pr-<N> --kind claude --pane <pane>
   -- --dangerously-skip-permissions`.
9. `herdr agent prompt <agent> "/<verify-skill> <N>" --wait --until idle`,
   where `<verify-skill>` is the registry's `verify_skill` for that repo —
   allowlisted to `gh-verify:merged` or `gh-verify:live`, because it
   reaches the prompt of a `--dangerously-skip-permissions` session.
10. Prints the new tab id, the worktree it opened in, the agent name, and a
    `herdr agent attach` hint.

## What it will NOT do

- Act on a repo missing from the watched-repos registry — that is the whole opt-in.
- Resolve a rebase conflict, or merge/commit/push anything. A conflict is
  `rebase --abort`-ed so the checkout stays usable, then the run stops.
- Open a verification session on a stale or dirty main checkout, on one parked
  on a branch other than the PR's base, or on a detached HEAD. Verifying code
  that is not the merged code proves nothing, so step 5's failure is the one
  hard stop in the skill.
- Open more than one session per PR, batch several PRs into one session, or
  retry a failed dispatch.
- Remove the verification worktree it created. Its lifetime is the tab's, and
  the tab is closed by the operator once they have read the result — so a
  teardown here would delete the directory a live session is standing in.
- Make any *mutating* GitHub call — no PR, board, or label writes. Its only
  API call is reading the PR's `headRefName`/`baseRefName`, and only when the
  caller did not already pass them down.
- Fail its caller. Every other error is one `[WARN]` line and exit 0, so
  `gh:pr-merge`'s report always prints.
- Run from the unattended cron path (`pr_merge_train_cron.sh`) — explicitly
  out of scope in issue #1511.

## Exit behavior

Always 0. `[WARN]` on stdout is the failure channel; there is no failure the
caller is expected to react to.
