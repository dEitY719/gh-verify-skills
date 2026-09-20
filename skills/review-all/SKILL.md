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

Take one PR through a `/simplify` auto-fix pass, then every available reviewer at once — agy, codex, opencode, hermes
— record the aggregate verdict as a merge-gate label, then reply inline or deferred. No approve decision, no
per-comment authoring, every lane soft-fail. The **only** writer of `review-blocked`, never of `review-passed`.

## Help

Arg #1 `-h` / `--help` / `help` → output `references/help.md` verbatim and stop; it is also the flag reference.

## Step 1: Parse Args

Paste `references/shell-common-source.md`'s loader block, then `devx_pr_review_all_parse "$@"`. On help follow Help;
on exit 2 print stderr and stop. Capture `pr`, `remote`, `reply_mode`, `reply_delay`, `force_review`, `START_TS`.

## Step 2: Pre-flight

- Resolve `TARGET_REPO` for `<remote>`; pass `-R <TARGET_REPO>` on every `gh pr`/`gh repo` call.
- PR must be `OPEN` and not draft (`gh pr view <pr> -R <TARGET_REPO>`) → else exit 1 `PR #<pr> is <state>; aborting`;
  `gh auth status` must return 0 → else exit 1 with its error line.
- **auto-fix branch context**: not on the PR head branch → `gh pr checkout <pr> -R <TARGET_REPO>`.

## Step 2.5: Auto-fix pass — `/simplify` runs FIRST, alone (dEitY719/gh-verify-skills#18)

**Read `references/simplify-lane.md` before dispatching**; it owns all three substeps verbatim. In order: the
clean-tree gate; `LANES_START_TS` plus **exactly one** edit-only `/simplify` Agent, nothing alongside it; then the
orchestrator — never the agent — commits and pushes. **A failed `git push` stops the run** (only hard-fail).

## Step 3: Reviewer fan-out (dispatch all reviewer lanes in ONE turn)

Run `references/duplicate-review-guard.md` first (dEitY719/dotfiles#1613), then dispatch the four lanes **together in
a single turn**; all are comment-only and `/simplify` is never dispatched here (#18). Record `$LANES` as you dispatch
— one `<ai>:ok|skip|fail` per **line**, never space-separated (`references/review-verdict-label.md`).

- **agy**, **codex** — CLI present → an Agent runs `Skill(gh-pr:review, "--ai <agy|codex> <pr> <remote>")`; absent →
  SKIP, non-zero exit → FAIL.
- **opencode**, **hermes** — the same with `--ai opencode` / `--ai hermes`, and each also requires
  `_dotfiles_setup_mode` = `internal` (loader: `references/shell-common-source.md`, pasted **inside the same Bash call
  that gates on it**); absent or non-internal → SKIP, non-zero exit → FAIL.

## Step 3.4: Orphan sweep (after every lane returns; soft-fail, WARN only)

A returned lane can leave children running (dEitY719/gh-verify-skills#42). Run `references/orphan-sweep.md`'s block
with `LANES_START_TS`; its `[WARN]` line carries to Step 6 as `ORPHANS`. Never `kill`.

## Step 3.5: Aggregate review verdicts and apply the merge-gate label

Runs after every Step 3 lane returns, **soft-fail** throughout. Bind `TARGET_HOST` from the same `<remote>` URL as
`TARGET_REPO` (step 0 of `references/reply-pending-label.sh.md`), then follow `references/review-verdict-label.md`.

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
`simplify:<value>`, `<ai>:FAIL(<reason>)` never `SKIP`, `orphans:<n>`, the `[WARN]` downgrades, the verdict clause.

## Constraints (full rationale: `references/constraints.md`)

- Reviewer lanes are soft-fail and comment-only; `/simplify` runs alone in Step 2.5, before them.
- Never add `/code-review` (`--fix` included) or a bare `git commit`; approve/request-changes is `gh-pr:approve`.
- Inline reply is deterministic; `--defer-reply` is minutes-only and not a guarantee.

## Related Skills

`gh-pr:review` (one reviewer at a time — this fans out over it) · `gh-pr:reply` / `session:schedule` (the reply pass)
· `gh-pr:approve` (the approve decision) · `gh-pr:merge-train` (the only reader of the verdict label, as a hard merge
gate) · `gh-setup:label-bootstrap` (both labels). Reused by `gh-flow:issue` Step 2.4.
