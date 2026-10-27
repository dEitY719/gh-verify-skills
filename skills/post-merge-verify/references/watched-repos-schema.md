# watched-repos registry — schema (F-1, issue dEitY719/dotfiles#1511, unified dEitY719/dotfiles#1555)

Location: `${IW_WATCHED_REPOS:-${HOME}/.avatars/issue-watcher/watched-repos.json}`
— the same untracked file `avatar_issue_watcher.sh` already reads, and the same
env-var override rule (`IW_WATCHED_REPOS`). This registry is **not** part of
the git repo: it lives outside `$DOTFILES_ROOT` and is not reviewed by any PR.

Before dEitY719/dotfiles#1555 this schema described a second, tracked SSOT file under
`docs/.ssot/` that only `gh-verify:post-merge-verify` read. That file is gone;
every registered repo's verification setting now lives as fields on the same
array entry issue-watcher already reads — since gh-verify-skills#93 the two keys
`post_merge_verify` and `post_merge_verify_skill` (see "Legacy `verify_skill`"
below for the key they replaced).

## Shape

Two top-level shapes, because the file is a personal SSOT this repo does not
own and cannot migrate — `avatar_issue_watcher.sh` has always accepted both, and
this skill's lookups now match that:

```jsonc
// A bare array (the common case) ...
[
  {
    "repo": "<owner>/<repo>",      // required — the registry key
    "path": "/home/you/dotfiles",  // required by issue-watcher; also this
                                    // skill's rebase target when present
    "host": "github.com",          // optional, defaults to github.com
    "post_merge_verify": true,     // optional, default false — see below
    "post_merge_verify_skill": "gh-verify:merged"  // optional, this default
  }
]
```

```jsonc
// ... or an object with a top-level "repos" array. Entries have the same
// shape either way.
{ "repos": [ { "repo": "<owner>/<repo>", "path": "...", "post_merge_verify": true } ] }
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
| `post_merge_verify` | no | JSON boolean, the on/off switch. Only `true` opens a verification tab; `false`, absent, or any other value (the string `"true"` included) means `gh-verify:post-merge-verify` no-ops for that repo — issue-watcher watches it just the same. |
| `post_merge_verify_skill` | no | **Allowlisted**: `gh-verify:merged` (the default when absent or empty) or `gh-verify:live`, nothing else. Typed into the new session verbatim (`/gh-verify:merged <N>`). Read only when `post_merge_verify` is `true`. |

## Legacy `verify_skill` (fallback, gh-verify-skills#93)

Before #93 a single `verify_skill` key did both jobs: its presence was the
on switch and its value the skill. An entry that has **no `post_merge_verify`
key** but a non-empty `verify_skill` is still honoured as
`post_merge_verify: true` + `post_merge_verify_skill: <its value>`, under the
same allowlist, and the dispatch prints one `[WARN]` naming the repo so the
entry gets migrated. Once `post_merge_verify` is present (even `false`), the
legacy key on that entry is ignored. Migrating the user's file is the job of
dotfiles' `avatar-watched-repos` sync tool, not of this skill; the fallback is
removed in a follow-up once every registry is migrated.

## Why `post_merge_verify_skill` is an allowlist, not free text

The value does not label anything — it is interpolated into
`herdr agent prompt` for a session started with
`--dangerously-skip-permissions`, i.e. it is an input to an unattended agent's
prompt. Adding a third verification skill means adding it to the allowlist in
both places, `references/dispatch.sh.md` and this table, and to the R-3 cases
in `tests/bats/gh_pr_post_merge_verify.bats`.

## Trust boundary changed by dEitY719/dotfiles#1555

Before this change, the skill choice (then `verify_skill`) lived in a **tracked** file — anyone
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

1. Add `"post_merge_verify": true` to the array entry whose `repo` is
   `<owner>/<repo>` (or add the whole `{repo, path, post_merge_verify}` entry if
   issue-watcher isn't already tracking that repo). `avatar_issue_watcher.sh
   --help` prints the resolved path; `IW_WATCHED_REPOS` overrides it for both
   dispatchers identically.
2. Pick the variant by what the repo can prove, and set it as
   `post_merge_verify_skill` (omit it for the `gh-verify:merged` default):
   - **`gh-verify:merged`** — no long-running app. It makes its own fresh
     clone of the merge commit, so the rebase is hygiene (the human is left
     on an up-to-date main), not a hard precondition.
   - **`gh-verify:live`** — there is a running dev app, and the proof is
     that the *serving checkout* is the target commit. Here the rebase **is**
     the precondition: an un-rebased checkout would have the session verify
     the previous commit and call it proven.

Setting `"post_merge_verify": false` (or removing the key, or the entry outright) is the
supported off switch for `gh-verify:post-merge-verify` — it restores exactly the
pre-dEitY719/dotfiles#1511 behavior for that repo, silently, without affecting issue-watcher's
own use of the same entry.

## Operator action after dEitY719/dotfiles#1555

This unification does not migrate data — the untracked file is outside the
repo and no code should write to a user's home directory on its behalf. Any
repo that had a skill set in the old tracked file needs `post_merge_verify`
added to the untracked file's matching entry by hand; until then `gh-verify:post-merge-verify`
silently no-ops for that repo (unattended merges themselves are unaffected).

The same holds for the default-path move to
`~/.avatars/issue-watcher/watched-repos.json` (dEitY719/dotfiles#2273): a
registry still at its pre-#2273 location is an unreadable file to this gate,
so every repo silently no-ops until the file is moved by hand or
`IW_WATCHED_REPOS` points at it.
