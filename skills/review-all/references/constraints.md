# Constraints (rationale) — for gh-verify:review-all

The SKILL.md body lists these as terse rules; the full rationale lives here.

- **Every reviewer lane is soft-fail — never hard-fail.** A missing CLI
  (`command -v` empty), an unset `DOTFILES_OPENCODE_REVIEW_MODEL`, a 402, a
  network reset, the 540s cap, or any other non-zero exit from `gh_pr_review`
  stops only that lane; `devx_pr_review_all_fanout` records it as
  `<ai>:<preset>:skip <reason>` and the other lanes and the rest of the flow
  continue. There is **no** internal-PC gate any more (#77 D-6,
  dEitY719/dotfiles#2069): `opencode` and `hermes` are tried on every PC and
  skip only if they actually fail. The Step 2.5 writers have already run
  either way. `gh-pr:review` does its own `command -v`/OPEN/draft pre-flight,
  so do **not** duplicate those as hard-fails here.

- **An erroring lane is a SKIP, not a lost verdict (#77 D-5 — reverses
  dEitY719/gh-verify-skills#14).** #14 split a lane that was never dispatched
  (`SKIP`) from one that ran and exited non-zero (`FAIL`), fed the second an
  `unknown` verdict in Step 3.5 and downgraded the report to `[WARN]`, so a PR
  that lost a reviewer stayed unlabelled. The trigger was agy hitting
  `prompt 131746B > 131072B argv limit` on a 62-file PR. #77 drops that on the
  user's explicit rule — "an error is a skip; do not dwell on it" — because
  with a reviewer subscription lapsed every PR would stay unlabelled and every
  report `[WARN]`. Now both cases are one `skip` row, fed nothing in Step 3.5,
  printed `<ai>:SKIP(<reason>)` in Step 6, and never a `[WARN]` cause on their
  own. Soft-fail still means "the reader is told": the reason is on the line.
  No false pass can result — `review-passed` is still `gh-pr:reply`'s alone
  (dEitY719/dotfiles#1636). The accepted cost: a lane that would have blocked
  and errored instead leaves no `review-blocked`.

- **Never run a bare `git commit`.** In a non-interactive AI shell a bare
  commit opens an editor for the message and hangs. Always pass `-m` with a
  conventional-commit message. `/simplify` edits files without staging them,
  so a plain `-m` finds nothing staged and fails with `no changes added to
  commit` — stage first with `git add -A`, then
  `git commit -m "refactor(<scope>): simplify per /simplify"`. **Not `-am`**
  (agy + codex, PR dEitY719/gh-verify-skills#28): `-a` stages modifications to
  *tracked* files only, and `/simplify` is free to **create** a file, which
  `-am` would silently leave behind as a dirty untracked path. `-A` is safe
  here only because Step 2.5's clean-tree gate ran first — see
  `references/simplify-lane.md`.

- **`/code-review --fix` is still NOT a fan-out lane — it is the claude
  self-fix, run as a `claude -p` child (#77 D-3 / D-4).** Claude Code v2.1.215
  made `/code-review` (and `/verify`) user-invocation-only: the docs mark it
  `disable-model-invocation`, so a skill calling `Skill(code-review, ...)` is
  rejected outright. Anthropic's two reasons stand: the review fans out a fleet
  of agents (the managed cloud `ultra` bills $15-25 per run), and `--fix`
  writes the working tree **outside the session's checkpoints** — `/rewind`
  cannot undo it, only git can.

  Until #77 that closed the question: the lane had sat here silently
  soft-failing on every run, and removal was the honest fix (shadowing the
  built-in with a same-named skill and prompting the user mid-flow were both
  rejected, and both stay rejected). #77 D-4 re-admits it by the user's
  explicit decision, but **only** as Step 2.5 substep c when `SELF=claude`,
  and in a form that answers both objections:

  - It is never a `Skill()` call. The skill runs
    `claude -p "/code-review high --fix <baseRefName>" --permission-mode acceptEdits`
    as a separate process, where a slash command in the prompt takes the
    user-input path. The AC-1 spike (#77 comment) proved it: 4 findings, 3
    fixed in the tree, no commit, rc 0 under `timeout 580` — D-3 path 1.
  - The checkpoint gap is closed by git: it runs only on a tree asserted clean,
    and its edits become their own `fix(<scope>): apply self-review findings
    (claude)` commit, so one `git revert` undoes it.
  - Only `high` (local, session tokens). `ultra` is out of scope.
  - Its stdout/stderr go to `mktemp` files **outside** the worktree: in the
    spike, `out.txt`/`err.txt` written to cwd were untracked and would have
    been swept into the orchestrator's `git add -A`.

  It is still never in the Step 3 fan-out: it writes the tree, and the fan-out
  is comment-only by construction (#18). The claude **reviewer** lane in Step 3
  is a different thing — `gh-pr:review --ai claude`, comment-only. Full
  procedure: `references/self-fix-pass.md`.

- **Each self-fix writer gets its own commit.** `fix(<scope>): apply
  self-review findings (<SELF>)` (substep c) and `refactor(<scope>): simplify
  per /simplify` (substep d) land separately from each other and from any fix
  commits `gh-pr:reply` makes later, keeping `git blame`/revert granular — a
  bad cleanup can be reverted without touching a correctness fix. Step 2.5
  pushes them in **one** push before any reviewer is dispatched.

- **`/simplify` runs alone, first, and never commits its own work**
  (dEitY719/gh-verify-skills#18). It writes to the tree, so it is dispatched
  by itself in Step 2.5 substep d — after the self-fix commit (substep c,
  #77), never alongside it, and before the Step 3 reviewer
  fan-out, which is entirely comment-only. It is dispatched **edit-only**: the
  prompt forbids `git revert`, `git reset`, `git checkout --`, `git stash`,
  `git commit` and `git push`, and forbids touching any hunk it did not author.
  The orchestrator commits after the agent returns, over a tree that was
  asserted clean before dispatch — which is what makes "the commit contains
  only hunks the agent authored" a property rather than a hope. Four same-day
  incidents forced this, the worst being a subagent that read the concurrent
  orchestrator's edits as an attack and reverted a codex BLOCKER fix. Full
  history, the ordering trade-off, and the verbatim dispatch prompt:
  `references/simplify-lane.md`.

- **Delay is not a guarantee — inline reply is the deterministic path.**
  Every reviewer lane is a synchronous `gh_pr_review` CLI call: it posts the
  PR comment before returning. Because Step 3's fan-out waits for every lane, the
  comments exist by the time Step 5 runs, so an **inline** `gh-pr:reply` sees
  them with deterministic ordering — no fixed delay needed. `--defer-reply` is
  a convenience for the issue-flow path (short turns), not a correctness
  requirement; the read-after-write is same-auth and effectively immediate.

- **`session:schedule` is minutes-only.** It has no sub-minute resolution, so a
  "500 seconds" intent maps to `--defer-reply 8` (≈480 s). When precise
  ordering matters, prefer the inline reply — it is exact, not approximate.

- **approve / request-changes is out of scope.** This skill collects reviews
  and replies to comments; it never submits a `gh pr review` decision. That is
  `gh-pr:approve`'s job.

- **Built-in `/simplify` ignores the PR# argument** and operates on the
  current working tree / branch diff. This is why Step 2 checks out the PR
  head branch first when running standalone — without it, `/simplify` would
  edit whatever tree happens to be checked out. On the issue-flow delegation
  path the branch is already correct, so the checkout is a no-op skip.

- **The auto-fix commit + push (Step 2.5) run synchronously before return.**
  On the issue-flow delegation path this guarantees no dirty tree is left for
  the later rebase steps — a dirty working tree breaks `git rebase`. Step 4
  re-asserts the clean tree rather than pushing anything, since the push
  already happened before the reviewers were dispatched. A non-empty
  `git status --porcelain` there means a comment-only lane wrote to the tree,
  which is a defect in that lane: print exactly
  `[WARN] working tree dirty after review lanes` and leave the changes in
  place. Committing hunks of unknown authorship is worse than the dirty tree.

- No emojis anywhere. POSIX-compatible shell snippets (`[ ]`, `>/dev/null 2>&1`).

- **`gh-pr:reply` now takes a `[remote]` positional** (issue dEitY719/dotfiles#1165) — Step 5
  threads the same `<remote>` this skill parsed as `gh-pr:reply`'s second
  positional arg (`Skill(gh-pr:reply, "<pr> <remote>")`). `gh-pr:reply` then
  resolves `TARGET_REPO` by parsing that remote's URL (SSOT helper
  `_gh_pr_review_resolve_target_repo`), not from `gh`'s default-repo
  heuristic. This closes the former local multi-remote ambiguity (e.g. both
  `origin` and `upstream` on GitHub): the reply now lands on the intended
  repo regardless of which remote gh would have guessed. The Step 2
  `gh pr checkout <pr> -R <TARGET_REPO>` is still load-bearing for
  `/simplify` (working-tree diff), but no longer the only thing keeping the
  reply pass on the right repo.

- **A returned lane is not a finished lane — sweep, WARN, never kill
  (dEitY719/gh-verify-skills#42).** In `dEitY719/brokerdesk` PR #78 the
  `/simplify` lane returned and committed while a nested sub-agent's bare
  `python` REPL kept running in the PR worktree for over an hour; review-all
  reported `simplify:committed` and nobody noticed. Step 3.4 now lists
  processes with cwd in the worktree started since `LANES_START_TS` and
  `[WARN]`s them into the Step 6 line as `orphans:<n>`. It never kills: a dev
  server or watcher the user started in the same worktree looks identical to a
  leak. A per-lane timeout was rejected (the Agent tool has none, and a large
  `/simplify` is legitimately slow), and so was relying on the upstream
  bare-interpreter hook alone (`dEitY719/dotfiles#1815`) — it fixes one cause
  of leaked work, not the class. Window, exclusions, and the runnable block:
  `references/orphan-sweep.md`.
