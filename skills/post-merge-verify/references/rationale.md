# Design notes (issue #1511)

## Why an opt-in registry rather than "every repo"

The dispatch opens a real terminal tab and burns a model session. Doing that
for every merge in every checkout on the machine is not a default anyone
would keep. `watched-repos.json` makes the blast radius a list you can read,
and makes "turn it off" a one-line delete rather than an env var nobody
remembers. An unregistered repo must therefore be **byte-identical** to the
pre-#1511 behavior — no `[INFO]`, no herdr call, nothing.

## Why this closes the implementation tab, when #1508 only suggests it

Issue #1508 covers the same `herdr agent list` cwd-matching detection but
stops at *suggesting* that a stale tab be closed. That is not in tension with
closing it here, and the difference is what the two know:

- #1508 detects a tab whose work status is **unknown** — the session may be
  mid-turn, may be waiting on the human, may be finished. Closing on that
  signal would kill live work, so it can only suggest.
- This skill runs on a **specific event**: the PR that tab was opened to
  implement has just been merged and its branch deleted. The tab's reason to
  exist is provably gone. That is a strictly stronger precondition than
  #1508's, so a stronger action follows from it.

Neither supersedes the other, and neither is a prerequisite for the other.

## Why the agent name does NOT carry the host (#1530)

The name is `mv-<repo>-pr-<N>`, built by `herdr_agent_name` in
`shell-common/functions/herdr_agent_name.sh` — the SSOT this skill shares with
`pr_merge_train_cron.sh` and `issue_watcher_cron.sh`.

It used to be `pmv-<host>-<owner>-<repo>-<N>`, mirroring `_PMT_AGENT_PREFIX`
on the #1403/#1407 argument that `owner/repo` is not unique across GitHub
servers. That argument is still true — but the name it produced was 37
characters for this repo and carried a dot besides, and herdr accepts only
`^[a-z][a-z0-9_-]{0,31}$`. So the host-qualified name did not identify
sessions across servers; it identified nothing, because `agent start` was
refused every single time and post-merge verification never ran once.

Thirty-two characters do not fit a host, an owner, a repo and a number. The
repo and the number are the parts that distinguish the work, so those stay.
The residual risk is real and bounded: two hosts carrying the same repo name
would collide on one agent. Today every watched target is one repository on
one host. When a second host joins the watch list, add a short digest of
`<host>/<owner>` at the helper — deliberately not pre-built.

## Why the base branch and remote are threaded in, not assumed

`fetch origin main` bakes in two assumptions the registry does not make. A
watched repo's default branch may be `master` or `develop`, and a registered
repo may be reached through `upstream` rather than `origin` — the skill even
advertises a `[remote]` positional it was then ignoring. Worse, rebasing
without first checking what `MAIN_ROOT`'s HEAD is on would rewrite the history
of whatever feature branch that checkout happened to be parked on. So the
remote comes from the positional, the base branch from the merged PR's
`baseRefName`, and a HEAD that is not on that branch (a detached one included)
stops the run the same way a dirty tree does.

`MAIN_ROOT` itself is validated first, before any step: `git -C "" status`
*fails*, and a failing status reads as "clean", after which
`git -C "$MAIN_ROOT" rebase --abort` would fire in whatever checkout the shell
happens to stand in. A path that is not a git worktree root makes the whole
dispatch unusable, so it is refused before the impl tab is even closed.

## Why a rebase failure is the only hard stop

Every other failure costs a missing convenience. This one costs a **wrong
answer**: a session started on a stale checkout would verify the previous
commit and report success. For `gh-verify:live` that is immediate and
total (the serving checkout *is* the evidence); for `gh-verify:merged`
the fresh clone insulates the verdict, but the human is still left believing
their `main` is current. So the run stops before any tab is created.

`git rebase --abort` runs on that path. That is restoration, not resolution —
picking sides in a conflict stays the human's call, but leaving the user's
main checkout parked mid-rebase would be a worse failure than the one being
reported.

## Why the verification session gets its own worktree (#1577)

The tab used to open in `MAIN_ROOT`, and the reasoning was sound as far as it
went: `gh-verify:merged` makes its own fresh clone, and the merged PR's
implementation worktree is being torn down, so the session needs no checkout of
its own. What that missed is that the main checkout is **shared**. Humans
`git pull` and check branches out in it, other AI sessions work in it, and
step 3 of this very dispatch rebases it — so on back-to-back merges the N+1th
dispatch moves the ground under the Nth session while it is still running. On
2026-08-28 the `pr-1567` tab disappeared exactly that way, with `~/dotfiles`'s
reflog showing an unrelated branch checkout and merge inside the verification
window.

So each PR gets `<git-common-dir>/pr-post-merge-verify/pr-<N>`, a detached
scratch worktree in the shape `gh:pr-merge-train` already uses
(`gh:pr-merge-train`'s `references/train-loop.md` (dotfiles dotfiles `claude/skills/gh-pr-merge-train/`) → "Detached scratch
worktree"). `--detach` is what makes it collide-free: it holds a commit, not a
branch name, so it never contests the base branch `MAIN_ROOT` has checked out.
No second `fetch` is issued for it — step 3 has just fetched
`$REMOTE/$BASE_BRANCH` and rebased onto it, so the ref is current by
construction. And `MAIN_ROOT` itself is unchanged: it is still the registry's
`path`, still what step 3 rebases. Only the tab's `--cwd` moved.

The herdr **workspace** is still looked up from `MAIN_ROOT`. That id only says
which workspace the new tab is grouped under; a worktree created seconds ago
has no workspace of its own on a first dispatch, so asking `herdr worktree
list` about it would answer nothing. Grouping and working directory are two
different questions here.

Lifetime is the tab's: created if absent, **reused** if present, so a manual
re-dispatch over a still-open tab is idempotent. There is deliberately no
teardown in this block — the operating rule until the pipeline stabilises is
that the human closes `pr-*` tabs after reading the result, and deleting the
directory a live session stands in is the failure being fixed, not a cleanup.
Who removes it, and when, belongs to a later tab-close hook or an
`_iw_cleanup_worktrees`-style "closed issue + no fan" rule.

## Why `herdr agent list` emptiness is "unknown", not "nothing running"

Lesson carried over from `_iw_live_agents` in
`shell-common/tools/custom/issue_watcher_cron.sh`: a herdr that answers
nothing is not a herdr saying no agent is there. Reading it as "nothing
running" is the one mistake this signal cannot afford, so the two answers get
two different lines: "herdr could not be queried — tab left alone" is a
`[WARN]`, and "no live herdr tab — nothing to close" is an `[INFO]`. Printing
the second for both would be exactly the conflation this section forbids.

Matching also uses **both** `cwd` and `foreground_cwd` (the pane's opening
directory and where its shell stands now), compares **physical** paths (a
worktree can be reached through a symlink), and refuses an empty path outright
— an empty prefix matches every agent and would close an unrelated tab. The
comparison is on a path **boundary**, not a bare `startswith`: `/work/repo-1`
must not match the sibling checkout `/work/repo-11`, while `/work/repo-1`
itself and anything under `/work/repo-1/` must.

## Why the pane id is read by leaf name

`herdr tab create` answers `.result.pane.pane_id` and `herdr workspace create`
answers `.result.root_pane.pane_id`; the CLI is free to add a third parent.
`pmv_json_first` scans for the first string under a flat key **anywhere** in
the document, so both shapes resolve without hardcoding a path — the same
helper as `_pmt_json_first`. Confirmed against herdr 0.7.5, whose
`herdr worktree list --json` answers `.result.source.source_workspace_id` for
the checkout it is asked about and `open_workspace_id` on each worktree entry.

## Out of scope, deliberately

- The unattended cron path (`pr_merge_train_cron.sh`) is untouched.
- No follow-up action when the verification itself fails — reading the result
  is the human's job.
- No batching or session cap when several PRs merge in a row: one session per
  PR, chosen for predictability over thrift.
