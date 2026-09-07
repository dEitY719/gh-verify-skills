---
name: review-all
# Description is 270 chars, over check 16's 250-char WARN band, on purpose —
# the two dotfiles-era aliases are protected by CLAUDE.md "Rules for changing
# skills", so the overage is cheaper than dropping a live trigger.
description: >-
  Fan out every available reviewer on one PR in parallel, then run a reply pass.
  Use for /gh-verify:review-all, /devx:pr-review-all, /devx-pr-review-all, "PR 다중 리뷰어 병렬로",
  "agy codex simplify 한번에 돌려", "PR 99 전체 리뷰". Not a single-reviewer run
  (gh-pr:review); never approves.
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

Take one PR through a `/simplify` auto-fix pass first, then every available reviewer at once — agy, codex, opencode, hermes — record the aggregate verdict as a merge-gate label, then reply to review comments inline or deferred. No approve/request-changes decision, no manual per-comment authoring, and every reviewer lane is soft-fail.
This skill is the **only** writer of `review-blocked`, and since dEitY719/dotfiles#1636 it never writes `review-passed` — that label belongs to `gh-pr:reply` Step 6 (`references/review-verdict-label.md`); `gh-pr:merge-train` is their only reader.
Arguments and flags (`<PR#> [remote] [--defer-reply M] [--no-reply] [--force-review]`): `references/help.md`.

## Help

If arg #1 is `-h`, `--help`, or `help`, read `references/help.md` and output it verbatim, then stop. No API calls.

## Step 1: Parse Args

Paste the Step 1 loader block from `references/shell-common-source.md`, then call `devx_pr_review_all_parse "$@"`. On help, follow Help; on exit 2, print stderr and stop.
Capture `pr`, `remote`, `reply_mode`, `reply_delay`, `force_review`, and `START_TS`.

## Step 2: Pre-flight

- Resolve `TARGET_REPO` for `<remote>`; pass `-R <TARGET_REPO>` on every `gh pr`/`gh repo` call.
- PR must be `OPEN` and not draft (`gh pr view <pr> -R <TARGET_REPO>`) → else exit 1 `PR #<pr> is <state>; aborting`; `gh auth status` must return 0 → else exit 1 with its error line.
- **auto-fix branch context**: if not on the PR head branch, run `gh pr checkout <pr> -R <TARGET_REPO>` — `/simplify` acts on the working tree.

## Step 2.5: Auto-fix pass — `/simplify` runs FIRST, alone (dEitY719/gh-verify-skills#18)

`/simplify` is the only lane that writes to the working tree, so it never runs beside anything else. It runs **here** — after the checkout, **before** the Step 3 fan-out — and is pushed before a single reviewer is dispatched, so reviewers read the simplified head.
**Read `references/simplify-lane.md` before dispatching**: the four incidents, the verbatim dispatch prompt, substep 3's runnable block, and `$SIMPLIFY`'s values. Its three substeps are (1) a **clean-tree gate** — `git status --porcelain` non-empty → record `SIMPLIFY=skip`, print `[SKIP] simplify: working tree dirty`, go to Step 3;
(2) **dispatch exactly one Agent** running built-in `/simplify`, **edit-only**, with that file's scope contract quoted verbatim in its prompt and nothing dispatched alongside it; (3) **the orchestrator commits, never the agent**, then pushes and drops a now-stale `review-passed` (soft-fail) but never `review-blocked`.
**A failed `git push` stops the run** — this skill's only hard-fail: reviewers would otherwise read a remote head that no longer matches the tree.

## Step 3: Reviewer fan-out (dispatch all reviewer lanes in ONE turn)

**Duplicate-review guard first (dEitY719/dotfiles#1613).** Read `head_sha`, `BODIES` and the trusted login `ME` once each, then — unless `force_review=1` — skip any lane `devx_pr_review_all_already_reviewed` reports as already reviewed for this head, printing `[SKIP] <ai> already reviewed head <head_sha> — pass --force-review to re-run`.
The runnable block, the raw-JSON requirement (`.user.login` must survive, dEitY719/dotfiles#1639), the fail-open rule, and why this is a read-before-write check rather than a lock: `references/duplicate-review-guard.md`.

Step 2.5 already pushed, so this `head_sha` is the head the reviewers review — and stays it, since nothing pushes after this. The four lanes dispatch together in a single turn and are **all comment-only: none writes to the working tree**; `/simplify` already ran in Step 2.5 and is never dispatched here (dEitY719/gh-verify-skills#18).
Every lane is soft-fail and **Step 3 is the only place its outcome is known**, so record `$LANES` as you dispatch — one `<ai>:ok|skip|fail` per **line**, never space-separated (Step 3.5 iterates it, and zsh does not word-split). The three outcomes, why a `fail` is never reported as a `skip` (dEitY719/gh-verify-skills#14), and a `fail`'s `<reason>` format: `references/review-verdict-label.md` → "Aggregating the lanes".

- **agy**, **codex** — if the CLI is present, an Agent runs `Skill(gh-pr:review, "--ai <agy|codex> <pr> <remote>")`; absent → SKIP, non-zero exit → FAIL.
- **opencode**, **hermes** — the same with `--ai opencode` / `--ai hermes`, but each also requires `_dotfiles_setup_mode` = `internal` (loader: `references/shell-common-source.md`, pasted **inside the same Bash call that gates on it**); absent or non-internal → SKIP, non-zero exit → FAIL.

Never add `/code-review --fix`; it is user-invocation-only (`references/constraints.md`).

## Step 3.5: Aggregate review verdicts and apply the merge-gate label

Runs **after every Step 3 lane has returned** and is **soft-fail** throughout — a labelling failure never blocks Steps 4-6, and an unlabelled PR reads downstream as "not verified", which `gh-pr:merge-train` `[SKIPPED]`s rather than merges.
Bind `TARGET_HOST` from the same `<remote>` URL as `TARGET_REPO` (step 0 block in `references/reply-pending-label.sh.md`), then follow `references/review-verdict-label.md`: the runnable block, the re-fetch of `head_sha` and `BODIES`, marker authorship, why the call only ever writes `review-blocked`, and why a guard-skipped lane still counts as `ok` while a `fail` lane emits a literal `unknown`.

## Step 4: Clean-tree assertion (nothing to push here)

Step 2.5 already pushed, so this pushes nothing; it asserts the invariant the caller depends on. `git status --porcelain` must be empty — if not, a comment-only lane wrote to the tree: print `[WARN] working tree dirty after review lanes` and leave it rather than commit hunks of unknown authorship (`gh-flow:issue` rebases on return; a dirty tree breaks `git rebase`).

## Step 5: pr-reply (per reply_mode)

- `inline` (default) → run `Skill(gh-pr:reply, "<pr> <remote>")` immediately.
- `defer` → **first** add the `reply-pending` label per `references/reply-pending-label.sh.md` (idempotent `gh label create`, then `_gh_pr_edit_safe_label`; soft-fail — a label failure never blocks the schedule), **then** `Skill(session:schedule, "--time <reply_delay> \"/gh-pr:reply <pr> <remote>\"")`.
  That label is what makes `gh-pr:merge-train` hard-skip this PR until the reply pass finishes (dEitY719/dotfiles#1524); `gh-pr:reply` Step 6 removes it.
- `none` → skip. Only `defer` labels — the other two defer nothing, so there is no pending state to mark.

## Step 6: Report

Print exactly one `[OK]`/`[SKIP]`/`[WARN]` line, e.g. `[WARN] PR #<pr> reviewed (agy:FAIL(argv limit) codex:OK opencode:SKIP hermes:SKIP simplify:committed) — reply: inline — verdict: unlabelled`.
Name a `fail` lane `<ai>:FAIL(<reason>)` — never `SKIP`, never omitted — and downgrade the line to `[WARN]` when any lane failed. The trailing clause is Step 3.5's outcome: `review-blocked` or `unlabelled`.
Then one `Next:` line, keyed to that clause — `unlabelled` reads downstream as "not verified yet", which `[OK]` alone does not convey:
- `review-blocked` → `Next: fix the blockers, then /gh-verify:review-all <pr> --force-review`
- `unlabelled` and the reply was deferred or skipped → `Next: /gh-pr:reply <pr> <remote>` — that pass is what writes `review-passed`
- reply deferred → append `; reply scheduled in <reply_delay>m, PR carries reply-pending until it lands`

## Constraints (full rationale: `references/constraints.md`)

- Reviewer lanes are soft-fail and comment-only; `/simplify` runs alone in Step 2.5, before them, never concurrently with anything that edits the tree.
- Never add `/code-review`; never run bare `git commit`. No approve / request-changes here — that is `gh-pr:approve`.
- Inline reply is deterministic; `--defer-reply` is minutes-only and not a guarantee.

## Related Skills

`gh-pr:review` (one reviewer at a time — this skill fans out over it) · `gh-pr:reply` / `session:schedule` (the reply pass) · `gh-pr:approve` (the approve/request-changes decision) · `gh-pr:merge-train` (consumes Step 3.5's verdict label as a hard merge gate) · `gh-setup:label-bootstrap` (provisions the two labels). Reused by `gh-flow:issue` (Step 2.4) as its post-PR quality gate.
