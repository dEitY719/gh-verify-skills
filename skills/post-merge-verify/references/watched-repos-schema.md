# watched-repos registry — schema (F-1, issue dEitY719/dotfiles#1511, unified dEitY719/dotfiles#1555)

Location: `${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}`
— the same untracked file `issue_watcher_cron.sh` already reads, and the same
env-var override rule (`IW_WATCHED_REPOS`). This registry is **not** part of
the git repo: it lives outside `$DOTFILES_ROOT` and is not reviewed by any PR.

Before dEitY719/dotfiles#1555 this schema described a second, tracked SSOT file under
`docs/.ssot/` that only `gh-verify:post-merge-verify` read. That file is gone;
every registered repo's `verify_skill` now lives as a field on the same
array entry issue-watcher already reads.

## Shape

Two top-level shapes, because the file is a personal SSOT this repo does not
own and cannot migrate — `issue_watcher_cron.sh` has always accepted both, and
this skill's lookups now match that:

```jsonc
// A bare array (the common case) ...
[
  {
    "repo": "<owner>/<repo>",      // required — the registry key
    "path": "/home/you/dotfiles",  // required by issue-watcher; also this
                                    // skill's rebase target when present
    "host": "github.com",          // optional, defaults to github.com
    "verify_skill": "gh-verify:merged"  // optional — see below
  }
]
```

```jsonc
// ... or an object with a top-level "repos" array. Entries have the same
// shape either way.
{ "repos": [ { "repo": "<owner>/<repo>", "path": "...", "verify_skill": "..." } ] }
```

Every jq lookup in this skill starts with
`(if type == "array" then . else (.repos // []) end)` before matching on
`.repo` — dropping that guard makes the object-wrapped shape parse as if
empty (silent no-op), not an error.

| Key | Required | Meaning |
|---|---|---|
| `repo` | yes | `owner/repo` slug. The lookup key both dispatchers match on. |
| `path` | yes (for issue-watcher) | Absolute or `~`-relative path of the original checkout. `gh-verify:post-merge-verify` rebases this path when present; a `~`-prefix is expanded. A missing/empty `path` falls back to `git rev-parse --path-format=absolute --git-common-dir` (with `/.git` stripped), which still resolves the main checkout from inside a linked worktree. |
| `host` | no | Defaults to `github.com`. Read by issue-watcher; not consulted by `gh-verify:post-merge-verify` (host comes from the PR's own remote resolution). |
| `verify_skill` | no | **Allowlisted**: `gh-verify:merged` or `gh-verify:live`, nothing else. Typed into the new session as its dash form (`/gh-verify:merged <N>`). An entry with no `verify_skill` (or one whose repo isn't in this file at all) means `gh-verify:post-merge-verify` no-ops for that repo — issue-watcher watches it just the same. |

## Why `verify_skill` is an allowlist, not free text

The value does not label anything — it is interpolated into
`herdr agent prompt` for a session started with
`--dangerously-skip-permissions`, i.e. it is an input to an unattended agent's
prompt. Adding a third verification skill means adding it to the allowlist in
all three places: `references/dispatch.sh.md`,
dotfiles' `tests/bats/skills/_fixtures/gh_pr_post_merge_verify.sh`, and this table.

## Trust boundary changed by dEitY719/dotfiles#1555

Before this change, `verify_skill` lived in a **tracked** file — anyone
setting it went through a PR review, which was a first line of defense
against a malicious value reaching the `--dangerously-skip-permissions`
prompt. Unifying onto the untracked registry removes that line: the file is
now user-editable with no review and no lint holding its shape. **The
allowlist in `dispatch.sh.md` is the only remaining defense**, and per issue
dEitY719/dotfiles#1555's explicit decision it must not be loosened as part of this or any
adjacent change. A registry value outside the allowlist still gets exactly
one `[WARN]` line and stops before any herdr mutation — unchanged behavior,
now carrying more of the weight.

## Registering a repo

1. Add a `verify_skill` field to the array entry whose `repo` is
   `<owner>/<repo>` (or add the whole `{repo, path, verify_skill}` entry if
   issue-watcher isn't already tracking that repo). `issue_watcher_cron.sh
   --help` prints the resolved path; `IW_WATCHED_REPOS` overrides it for both
   dispatchers identically.
2. Pick the variant by what the repo can prove:
   - **`gh-verify:merged`** — no long-running app. It makes its own fresh
     clone of the merge commit, so the rebase is hygiene (the human is left
     on an up-to-date main), not a hard precondition.
   - **`gh-verify:live`** — there is a running dev app, and the proof is
     that the *serving checkout* is the target commit. Here the rebase **is**
     the precondition: an un-rebased checkout would have the session verify
     the previous commit and call it proven.

Removing `verify_skill` from an entry (or the entry outright) is the
supported off switch for `gh-verify:post-merge-verify` — it restores exactly the
pre-dEitY719/dotfiles#1511 behavior for that repo, silently, without affecting issue-watcher's
own use of the same entry.

## Operator action after dEitY719/dotfiles#1555

This unification does not migrate data — the untracked file is outside the
repo and no code should write to a user's home directory on its behalf. Any
repo that had a `verify_skill` in the old tracked file needs it added to the
untracked file's matching entry by hand; until then `gh-verify:post-merge-verify`
silently no-ops for that repo (unattended merges themselves are unaffected).
