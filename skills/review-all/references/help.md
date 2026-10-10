# gh-verify:review-all — Help

Harness-agnostic (dEitY719/gh-verify-skills#77): the harness running the skill
first reviews the PR itself and fixes what it finds (claude: `/code-review high
--fix` + `/simplify`; codex / opencode / agy / hermes: an in-session `thorough`
review), then fans out **every reviewer** in parallel — `claude` ∥ `codex` ∥
`opencode` ∥ `agy` ∥ `hermes` second opinions, or any `<ai>:<preset>` set
`--lanes` names — then runs a reply pass over the resulting review comments. A
composition skill: it orchestrates several reviewers plus a reply, unlike
`gh-pr:review` (a single external AI, one aggregate comment). It submits **no
decision** (approve / request-changes) — that is `gh-pr:approve`.

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
| `--lanes L` / `--lanes=L` | `claude:default,codex:default,opencode:default,agy:default,hermes:default` | Comma-separated `<ai>:<preset>` lanes, all run in parallel by one `devx_pr_review_all_fanout` call. The same AI may appear under several presets — `opencode:default,opencode:thorough` is two independent lanes, each with its own marker, its own dedup entry and its own verdict (dEitY719/gh-verify-skills#56). Each side is one `[A-Za-z0-9_-]` token; validation is shape-only, so the authoritative AI and preset lists stay in `gh-pr:review`'s `--ai` / `--review`. A Korean preset alias (`꼼꼼`) is rejected — `--review` would normalize it to `thorough` and post a marker this skill could never find again. An empty, colon-less or repeated entry exits 2. |
| `--force-review` | off | Bypass the duplicate-review guard and re-run every `--lanes` lane even if the current head sha was already reviewed. Does not affect the Step 2.5 self-fix pass, which runs first regardless of this flag (a dirty tree gives `self:<SELF>:skip(dirty)` and `simplify:skip`). |
| `-h` / `--help` / `help` | — | Print this help and stop. |

`--defer-reply` and `--no-reply` together → `--no-reply` wins (reply skipped).

## Usage

- `/gh-verify:review-all 99` — review PR #99 with all available reviewers, reply inline
- `/gh-verify:review-all 99 upstream` — same, targeting the `upstream` repo
- `/gh-verify:review-all 99 --defer-reply 8` — review now, schedule the reply 8 min later
- `/gh-verify:review-all 99 --no-reply` — review only; skip the reply pass
- `/gh-verify:review-all 99 --force-review` — force every lane to re-run even if this head was already reviewed
- `/gh-verify:review-all 99 --lanes "opencode:default,opencode:thorough,hermes:default,hermes:performance"` — two
  presets each for two CLIs; four independent lanes, four comments, four verdicts
- `/gh-verify:review-all -h` / `--help` / `help` — print this help

## What the skill does

1. Parse args via `devx_pr_review_all_parse`; record `START_TS` and the resolved `lanes` list.
2. Pre-flight: PR must be `OPEN` and non-draft, `gh auth` must be live, and
   check out the PR head branch if not already on it (so the self-fix pass
   acts on the right tree). Then bind `SELF` — the model declares which
   harness it runs in (`claude|codex|opencode|agy|hermes`, else `unknown`).
3. Self-fix pass — the writers run **first, one at a time**, on a tree asserted
   clean (dEitY719/gh-verify-skills#18, #77). `SELF=claude`: a
   `claude -p "/code-review high --fix <base>"` child process fixes the
   findings, then one edit-only `/simplify` Agent cleans up. Any other `SELF`:
   the session reviews `gh pr diff` against the `thorough` preset and fixes
   the valid findings itself, edit-only (`simplify:n/a`). The orchestrator
   commits each step separately (`fix(<scope>): apply self-review findings
   (<SELF>)`, `refactor(<scope>): simplify per /simplify`) and pushes once,
   then drops any now-stale `review-passed`. **If that push fails, the run
   stops here** — no reviewer lane is dispatched, since one would review a
   tree that no longer matches the remote head. Spec:
   `references/self-fix-pass.md`, `references/simplify-lane.md`.
4. Reviewer fan-out — one lane per `<ai>:<preset>` in `--lanes`. First skip any
   lane that already posted a review for the PR's current head sha **under that
   preset** (the duplicate-review guard, dEitY719/dotfiles#1613;
   `--force-review` bypasses it), then run every remaining lane **in parallel**
   with one `devx_pr_review_all_fanout` call — each `gh-pr:review --ai <ai>
   --review <preset>`, comment-only, capped at 540s. No harness subagents and
   no internal-PC gate: every lane is tried, and one that errors for any
   reason (missing CLI, 402, network reset, timeout) ends `SKIP(<reason>)`.
5. Aggregate the `OK` lanes' closing verdict lines into one merge-gate label —
   `review-blocked` if any lane blocked, no label at all otherwise. A `SKIP`
   lane contributes nothing (#77 D-5). Nothing pushes after the lanes ran, so
   the head sha still matches what they reviewed. Soft-fail: a labelling
   failure never blocks the reply pass.
   Spec: `references/review-verdict-label.md`.
6. Reply — inline `gh-pr:reply <pr> <remote>` (default), or deferred via
   `session:schedule` (`--defer-reply M`), or skipped (`--no-reply`). The
   `<remote>` is threaded so the reply pass resolves the same target repo.
7. Print one `[OK]`/`[SKIP]`/`[WARN]` report line, naming every lane's outcome,
   the self-fix and simplify outcomes, and ending with the verdict clause, e.g.
   `(claude:OK codex:SKIP(402 deactivated_workspace) … self:claude:fixed
   simplify:clean) — reply: inline — verdict: unlabelled`, followed by exactly
   one `Next:` line, first match wins: re-run with `--force-review` after fixing
   blockers; a deferred reply is already scheduled, so it only reports the
   delay and the `reply-pending` label; any other `unlabelled` PR gets
   `/gh-pr:reply <pr> <remote>`.

## What the skill will NOT do

- Submit `gh pr review --approve` / `--request-changes` — that is `gh-pr:approve`.
  The verdict label it writes is a **merge-train gate**, not an approval: it
  never touches `reviewDecision`.
- Merge anything. `gh-pr:merge-train` reads the label; this skill only writes it.
- Invoke `/code-review` through `Skill()` or as a fan-out lane — it is
  user-invocation-only since Claude Code v2.1.215. It runs only as the claude
  self-fix, a separate `claude -p` process (`references/constraints.md`).
- Hard-fail because a reviewer CLI is missing or errors — each lane is soft-fail.
- **Hide** a lane that errored. It is named in the report as
  `<ai>[:<preset>]:SKIP(<reason>)`; it just no longer blocks the verdict or
  downgrades the line to `[WARN]` (#77 D-5, reversing #14).
- Run a bare `git commit` — an editor prompt would hang the non-interactive shell.
- Schedule sub-minute delays — `session:schedule` is minutes-only; for tight
  ordering use the deterministic inline reply.

## Exit codes

| Code | Cause |
|------|-------|
| 0 | Review gate ran and the reply step completed / was scheduled / was skipped. |
| 1 | PR not `OPEN`/non-draft, or `gh` not authenticated. |
| 2 | Argument error: missing `<PR#>`, non-integer `<PR#>`, unknown flag, bad `--defer-reply` value, or a `--lanes` list that is empty, has an empty/colon-less/multi-colon entry, carries a non-`[A-Za-z0-9_-]` token, or repeats a lane. |

## Good vs. bad invocation

- **Good**: `/gh-verify:review-all 99` — all reviewers + inline reply on PR #99.
- **Good**: `/gh-verify:review-all 99 --defer-reply 8` — issue-flow-style deferred reply.
- **Bad**: `/gh-verify:review-all` — exits 2 (missing `<PR#>`).
- **Bad**: `/gh-verify:review-all abc` — exits 2 (PR# must be a positive integer).
- **Bad**: `/gh-verify:review-all 99 --lanes "opencode:default,opencode:default"` — exits 2 (repeated lane; the
  second copy would only be skipped by the duplicate-review guard, silently dispatching fewer lanes than asked).
- **Bad**: `/gh-verify:review-all 99 --lanes "opencode"` — exits 2 (an entry must be `<ai>:<preset>`).
