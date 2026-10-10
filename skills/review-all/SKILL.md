---
name: review-all
# Description is 270 chars, over check 16's 250-char WARN band, on purpose — the two dotfiles-era aliases are
# protected by CLAUDE.md "Rules for changing skills", so the overage is cheaper than dropping a live trigger.
description: >-
  Fan out every available reviewer on one PR in parallel, then run a reply pass. Use for /gh-verify:review-all,
  /devx:pr-review-all, /devx-pr-review-all, "PR 다중 리뷰어 병렬로", "agy codex simplify 한번에 돌려", "PR 99 전체 리뷰". Not a
  single-reviewer run (gh-pr:review); never approves.
license: MIT
allowed-tools: Bash, Read, Grep, Agent
metadata:
  model_recommendation:
    tier: sonnet
    reason: "parallel review fan-out orchestration; soft-fail gate + inline/deferred reply"
    claude: prefer
    non_claude: advisory-only
---

# gh-verify:review-all — Multi-reviewer PR gate + reply

## Role

Harness-agnostic (#77): the running harness self-reviews and fixes the PR, then all reviewers at once — claude, codex,
opencode, agy, hermes — record a merge-gate verdict label, then a reply pass. Never approves; an erroring lane is
SKIPped. Sole writer of `review-blocked`, never of `review-passed`.

## Help

Arg #1 `-h` / `--help` / `help` → output `references/help.md` verbatim and stop; it is also the flag reference.

## Step 1: Parse Args

Paste `references/shell-common-source.md`'s loader block, then `devx_pr_review_all_parse "$@"`. On help follow Help;
on exit 2 print stderr and stop. Capture `pr`, `remote`, `reply_mode`, `reply_delay`, `force_review`, `lanes`,
`START_TS`.

## Step 2: Pre-flight

- Resolve `TARGET_REPO` for `<remote>`; pass `-R <TARGET_REPO>` on every `gh pr`/`gh repo` call.
- PR must be `OPEN` and not draft (`gh pr view <pr> -R <TARGET_REPO>`) → else exit 1 `PR #<pr> is <state>; aborting`;
  `gh auth status` must return 0 → else exit 1 with its error line.
- **auto-fix branch context**: not on the PR head branch → `gh pr checkout <pr> -R <TARGET_REPO>`.
- **Step 2.4 — bind SELF**: declare your harness, `SELF` = `claude|codex|opencode|agy|hermes`, else `unknown`
  (self-fix skips, fan-out runs). Self-declared, never env-sniffed (`references/self-fix-pass.md`).

## Step 2.5: Self-fix pass — writers run FIRST, one at a time (#77, #18)

**Read `references/self-fix-pass.md` before starting**; it owns substeps a-e. a: clean-tree gate (dirty → skip all,
go to Step 3). b: `LANES_START_TS`. c: `SELF=claude` → `claude -p "/code-review high --fix <base>"` child; other SELF →
in-session `thorough` review, edit-only; orchestrator commits `fix(<scope>): apply self-review findings (<SELF>)`.
d: `SELF=claude` only — exactly one edit-only `/simplify` Agent (`references/simplify-lane.md`), orchestrator commits;
else `simplify:n/a`. e: **one** push; **a failed `git push` stops the run** (only hard-fail); drop `review-passed`.

## Step 3: Reviewer fan-out (every lane in parallel, ONE shell call)

Run `references/duplicate-review-guard.md`'s block (dEitY719/dotfiles#1613): it skips already-reviewed lanes, then
makes **one** `devx_pr_review_all_fanout` call (Bash timeout 600000) running every other `<ai>:<preset>` lane at once,
540s cap each; two presets of one AI are two lanes (#56). All comment-only, no writer here (#18). Default `--lanes`:
`claude`, `codex`, `opencode`, `agy`, `hermes` `:default`, no internal-PC gate — a missing CLI just skips that lane.
It prints `$LANES`, one `<ai>:<preset>:ok|skip <reason>` per **line**; carry it as a literal.

## Step 3.4: Orphan sweep (after every lane returns; soft-fail, WARN only)

A returned lane can leave children running (dEitY719/gh-verify-skills#42). Run `references/orphan-sweep.md`'s block
with `LANES_START_TS`; its `[WARN]` line carries to Step 6 as `ORPHANS`. Never `kill`.

## Step 3.5: Aggregate review verdicts and apply the merge-gate label

Only `ok` lanes feed the harvest; a `skip` lane adds no line (#77 D-5). **Soft-fail.** Bind `TARGET_HOST` from the
`<remote>` URL (step 0 of `references/reply-pending-label.sh.md`), then follow `references/review-verdict-label.md`.

## Step 4: Clean-tree assertion (nothing to push here)

Step 2.5 already pushed, so this step only asserts: `git status --porcelain` must be empty. If not, print
`references/constraints.md`'s `[WARN]` line and leave the changes — never commit hunks of unknown authorship.

## Step 5: pr-reply (per reply_mode)

- `inline` (default) → run `Skill(gh-pr:reply, "<pr> <remote>")` immediately.
- `defer` → **first** add the `reply-pending` label per `references/reply-pending-label.sh.md` (soft-fail), **then**
  `Skill(session:schedule, "--time <reply_delay> \"/gh-pr:reply <pr> <remote>\"")`.
- `none` → skip. Only `defer` labels — the other two defer nothing.

## Step 6: Report

Print the status line and the `Next:` line exactly as `references/report-template.md` specifies — lane rows,
`<ai>:SKIP(<reason>)`, `self:<SELF>:<v>`, `simplify:<v>`, `orphans:<n>`, the `[WARN]` downgrades, the verdict clause.

## Constraints (full rationale: `references/constraints.md`)

- Reviewer lanes are soft-fail and comment-only; the self-fix writers run one at a time in Step 2.5, before them.
- `/code-review` only as Step 2.5c's `claude -p` child, never `Skill()` or a lane; never a bare `git commit`.
- Inline reply is deterministic; `--defer-reply` is minutes-only and not a guarantee.

## Related Skills

`gh-pr:review` (one reviewer at a time — this fans out over it) · `gh-pr:reply` / `session:schedule` (the reply pass)
· `gh-pr:approve` (the approve decision) · `gh-pr:merge-train` (the only reader of the verdict label, as a hard merge
gate) · `gh-setup:label-bootstrap` (both labels). Reused by `gh-flow:issue` Step 2.4.
