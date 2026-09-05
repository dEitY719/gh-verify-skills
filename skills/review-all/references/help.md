# gh-verify:review-all — Help

Fan out **every available reviewer** on one PR in parallel — `agy` ∥
`codex` ∥ `opencode` ∥ `hermes` second opinions ∥ a `/simplify` auto-fix pass (which commits its own
changes) — then run a reply pass over the resulting review comments. A
composition skill: it
orchestrates several reviewers plus a reply, unlike `gh-pr:review` (a single
external AI, one aggregate comment). It submits **no decision** (approve /
request-changes) — that is `gh-pr:approve`.

## Arguments

| # | Name | Default | Description |
|---|------|---------|-------------|
| 1 | PR number, or `-h`/`--help`/`help` | — (required) | Target PR, e.g. `99` |
| 2 | remote name | `origin` | Git remote for the target repo |

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--defer-reply M` / `--defer-reply=M` | off (inline) | Schedule `/gh-pr:reply` M **minutes** later via `session:schedule` instead of replying inline. |
| `--no-reply` | off | Skip the reply step entirely. |
| `--force-review` | off | Bypass the duplicate-review guard and re-run every reviewer lane (agy/codex/opencode/hermes) even if the current head sha was already reviewed. Does not affect `/simplify`, which always runs regardless of this flag. |
| `-h` / `--help` / `help` | — | Print this help and stop. |

`--defer-reply` and `--no-reply` together → `--no-reply` wins (reply skipped).

## Usage

- `/gh-verify:review-all 99` — review PR #99 with all available reviewers, reply inline
- `/gh-verify:review-all 99 upstream` — same, targeting the `upstream` repo
- `/gh-verify:review-all 99 --defer-reply 8` — review now, schedule the reply 8 min later
- `/gh-verify:review-all 99 --no-reply` — review only; skip the reply pass
- `/gh-verify:review-all 99 --force-review` — force every lane to re-run even if this head was already reviewed
- `/gh-verify:review-all -h` / `--help` / `help` — print this help

## What the skill does

1. Parse args via `devx_pr_review_all_parse`; record `START_TS`.
2. Pre-flight: PR must be `OPEN` and non-draft, `gh auth` must be live, and
   check out the PR head branch if not already on it (so `/simplify` acts on
   the right tree).
3. Review + auto-fix gate — first skip any reviewer lane that already posted a
   review for the PR's current head sha (the duplicate-review guard, dEitY719/dotfiles#1613;
   `--force-review` bypasses it), then dispatch the remaining lanes plus the
   auto-fix pass as
   Agent subagents **in one turn**. agy/codex/opencode/hermes delegate to
   `gh-pr:review --ai <name>` (streams findings + posts a PR comment) and run
   fully in parallel. opencode and hermes run only on internal PCs. `/simplify` mutates the working tree and commits its own
   changes (`refactor(<scope>): simplify per /simplify`). Each lane is
   soft-fail, ending `OK`, `SKIP` (never dispatched) or `FAIL` (dispatched,
   exited non-zero).
4. Aggregate the lanes' closing verdict lines into one merge-gate label —
   `review-blocked` if any lane blocked, no label at all otherwise. A `FAIL`ed
   lane counts as an unestablished verdict, so a PR that lost a reviewer is
   left unlabelled instead of certified off the survivors. Runs
   **before** the push, so the head sha still matches what the lanes
   reviewed. Soft-fail: a labelling failure never blocks the reply pass.
   Spec: `references/review-verdict-label.md`.
5. Push the auto-fix commit (only if the working tree changed), always with
   an explicit `-m` message.
6. Reply — inline `gh-pr:reply <pr> <remote>` (default), or deferred via
   `session:schedule` (`--defer-reply M`), or skipped (`--no-reply`). The
   `<remote>` is threaded so the reply pass resolves the same target repo.
7. Print one `[OK]`/`[SKIP]`/`[WARN]` report line, naming every lane's outcome
   and ending with the verdict clause, e.g.
   `(agy:FAIL(argv limit) codex:OK …) — reply: inline — verdict: unlabelled`.

## What the skill will NOT do

- Submit `gh pr review --approve` / `--request-changes` — that is `gh-pr:approve`.
  The verdict label it writes is a **merge-train gate**, not an approval: it
  never touches `reviewDecision`.
- Merge anything. `gh-pr:merge-train` reads the label; this skill only writes it.
- Run `/code-review --fix` — it is user-invocation-only since Claude Code
  v2.1.215, so no skill can invoke it. Run it yourself when you want it; agy,
  codex, and the closing `gh-pr:reply` pass cover the same ground here.
- Hard-fail because a reviewer CLI is missing or errors — each lane is soft-fail.
- **Hide** a lane that errored. A `FAIL`ed lane is named in the report as
  `<ai>:FAIL(<reason>)` and blocks the verdict from being established
  (dEitY719/gh-verify-skills#14).
- Run a bare `git commit` — an editor prompt would hang the non-interactive shell.
- Schedule sub-minute delays — `session:schedule` is minutes-only; for tight
  ordering use the deterministic inline reply.

## Exit codes

| Code | Cause |
|------|-------|
| 0 | Review gate ran and the reply step completed / was scheduled / was skipped. |
| 1 | PR not `OPEN`/non-draft, or `gh` not authenticated. |
| 2 | Argument error: missing `<PR#>`, non-integer `<PR#>`, unknown flag, or bad `--defer-reply` value. |

## Good vs. bad invocation

- **Good**: `/gh-verify:review-all 99` — all reviewers + inline reply on PR #99.
- **Good**: `/gh-verify:review-all 99 --defer-reply 8` — issue-flow-style deferred reply.
- **Bad**: `/gh-verify:review-all` — exits 2 (missing `<PR#>`).
- **Bad**: `/gh-verify:review-all abc` — exits 2 (PR# must be a positive integer).
