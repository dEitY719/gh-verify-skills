# Constraints (rationale) — for gh-verify:review-all

The SKILL.md body lists these as terse rules; the full rationale lives here.

- **Every reviewer lane is soft-fail — never hard-fail.** A missing `agy`,
  `codex`, `opencode`, or `hermes` CLI (`command -v` empty), a rate-limit, or any non-zero exit from
  `gh-pr:review` marks only that lane `[SKIP]`/`[WARN]`; the other lanes and
  the rest of the flow continue. `opencode` and `hermes` also skip softly unless
  `_dotfiles_setup_mode` is `internal`. If all reviewer CLIs are unavailable,
  `/simplify` still runs. `gh-pr:review` already does its own
  `command -v`/OPEN/draft pre-flight, so do **not** duplicate those as
  hard-fails here — always wrap the lane softly.

- **Never run a bare `git commit`.** In a non-interactive AI shell a bare
  commit opens an editor for the message and hangs. Always pass `-m` with a
  conventional-commit message. `/simplify` edits files without staging them,
  so a plain `-m` finds nothing staged and fails with `no changes added to
  commit` — use `-am` so the commit picks up the unstaged edits too, e.g.
  `git commit -am "refactor(<scope>): simplify per /simplify"`.

- **`/code-review --fix` is NOT a lane here, and must not be re-added.**
  Claude Code v2.1.215 made `/code-review` (and `/verify`) user-invocation-only:
  the docs mark it `disable-model-invocation`, so a skill calling
  `Skill(code-review, ...)` is rejected outright. Two reasons Anthropic gives,
  both sound: the review fans out a fleet of agents (the managed cloud variant
  bills $15-25 per run), and `--fix` writes to the working tree from a
  background subagent **outside the session's checkpoints** — `/rewind` cannot
  undo those edits, only git can. A model firing that autonomously is exactly
  the failure mode the restriction prevents.

  Before this was understood, the lane sat here silently soft-failing on every
  single run. Two workarounds were considered and rejected: shadowing the
  bundled skill with a same-named override (it would mask a maintained,
  more capable tool — working-diff scoping, `--fix`, `--comment`, `ultra`,
  effort tuning — with a frozen fork), and prompting the user mid-flow (breaks
  the unattended issue-flow contract). Removal is the honest fix.

  **Nothing meaningful is lost.** Bug-hunting is covered by the agy, codex,
  opencode, and hermes
  lanes, which post real PR comments; cleanup is covered by `/simplify`; and
  the apply-fixes-and-commit behaviour still happens at the end of the flow,
  where `gh-pr:reply` evaluates each review comment and commits the valid
  fixes. Users who want the bundled reviewer can type `/code-review --fix`
  themselves at any point — it runs in the background and does not block.

- **The auto-fix commit is its own commit.** `refactor(<scope>): simplify per
  /simplify` lands separately from any fix commits `gh-pr:reply` makes later,
  keeping `git blame`/revert granular — a bad cleanup can be reverted without
  touching a review-driven correctness fix. A single `git push` at Step 4
  sends up whatever exists.

- **Delay is not a guarantee — inline reply is the deterministic path.**
  agy/codex/opencode/hermes reviews are synchronous `gh-pr:review` CLI calls: they post the
  PR comment before returning. Because Step 3 awaits all five Agents, the
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

- **The auto-fix commit + push (Step 4) run synchronously before return.**
  On the issue-flow delegation path this guarantees no dirty tree is left for
  the later rebase steps — a dirty working tree breaks `git rebase`.

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
