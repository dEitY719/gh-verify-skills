---
name: review-all
description: >-
  Fan out every available reviewer on one PR in parallel, then run a reply pass.
  Use for /gh-verify:review-all, /devx:pr-review-all, /devx-pr-review-all, "PR 다중 리뷰어 병렬로",
  "agy codex simplify 한번에 돌려", "PR 99 전체 리뷰". Not a single-reviewer run
  (gh:pr-review); never approves.
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

Orchestrate a single PR through all available reviewers at once — agy, codex, opencode, hermes, plus a `/simplify`
auto-fix pass — record the aggregate verdict as a merge-gate label, commit any auto-fix changes, then reply to
review comments inline or deferred. No
approve/request-changes decision and no manual per-comment authoring. Every reviewer lane is soft-fail.
This skill is the **only** writer of `review-blocked`; since #1636 it never writes
`review-passed` — that label belongs to `gh:pr-reply` Step 6
(`references/review-verdict-label.md`); `gh:pr-merge-train` is their only reader.
Argument/flag table (`<PR#> [remote] [--defer-reply M] [--no-reply] [--force-review]`): `references/help.md`.

## Help

If arg #1 is `-h`, `--help`, or `help`, read `references/help.md` and output
it verbatim, then stop. No API calls.

## Step 1: Parse Args

Source and delegate to `devx_pr_review_all_parse`:
`_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"; [ -f "$_SC/functions/devx_pr_review_all.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }; source "$_SC/functions/devx_pr_review_all.sh"` then
`devx_pr_review_all_parse "$@"`. On help, follow Help; on exit 2, print stderr
and stop. Capture `pr`, `remote`, `reply_mode`, `reply_delay`, `force_review`,
and `START_TS`.

## Step 2: Pre-flight

- Resolve `TARGET_REPO` for `<remote>` and pass `-R <TARGET_REPO>` on every
  `gh pr`/`gh repo` call.
- PR state must be `OPEN` and not draft (`gh pr view <pr> -R <TARGET_REPO>`)
  → else exit 1 `PR #<pr> is <state>; aborting`.
- `gh auth status` returns 0 → else exit 1 with the gh error line.
- **auto-fix branch context**: if not on the PR head branch, run
  `gh pr checkout <pr> -R <TARGET_REPO>`; `/simplify` acts on the working tree.

## Step 3: Review + auto-fix gate (dispatch all lanes in ONE turn)

**Duplicate-review guard first (#1613).** Before dispatching anything, read
`head_sha` once (`gh pr view "$pr" -R "$TARGET_REPO" --json headRefOid --jq
.headRefOid`) and `BODIES` once
(`gh api --paginate "repos/$TARGET_REPO/issues/$pr/comments"` — **raw JSON, no
`--jq '.[].body'`**: `.user.login` must survive, #1639) and the trusted login
once
(`ME="${DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN:-${ME:-$(GH_HOST="$TARGET_HOST" gh api user -q .login)}}"`).
Then, unless `force_review=1`, skip any reviewer lane for which
`devx_pr_review_all_already_reviewed "$ai" "$head_sha" "$ME"` (fed `$BODIES` on
stdin) returns 0 — print
`[SKIP] <ai> already reviewed head <head_sha> — pass --force-review to re-run`
and do **not** dispatch that lane's Agent. Two sessions reviewing the same head
concurrently is what posted duplicate agy/codex comments on PR #1608. Fail
open: if either fetch errors, treat every lane as not-yet-reviewed and dispatch
normally. This is a read-before-write check, not a lock — two sessions can
still both read "not yet reviewed" and both fan out; see
`references/duplicate-review-guard.md` → "Known limitation" for why that race
is accepted rather than closed with a lock file.

The five lanes dispatch together in a single turn. agy/codex/opencode/hermes
are comment-only; `/simplify` may mutate and commit. Each lane is soft-fail.
A lane skipped by the guard because it was **already reviewed** is not the
same as a lane skipped for a **missing CLI** — the former still has a valid
verdict for this exact head and Step 3.5 must harvest it (see Step 3.5's
"guard-skipped lanes" note below); only the latter contributes no verdict line.

- **agy** — if `command -v agy`, an Agent runs
  `Skill(gh:pr-review, "--ai agy <pr> <remote>")`; absent or non-zero exit → SKIP/WARN.
- **codex** — if `command -v codex`, an Agent runs
  `Skill(gh:pr-review, "--ai codex <pr> <remote>")`; absent or non-zero exit → SKIP/WARN.
- **opencode** — if `command -v opencode` and `_dotfiles_setup_mode` is
  `internal`, an Agent runs
  `Skill(gh:pr-review, "--ai opencode <pr> <remote>")`; absent, non-internal,
  or non-zero exit → SKIP/WARN.
- **hermes** — if `command -v hermes` and `_dotfiles_setup_mode` is
  `internal`, an Agent runs
  `Skill(gh:pr-review, "--ai hermes <pr> <remote>")`; absent, non-internal,
  or non-zero exit → SKIP/WARN.
- **auto-fix** — an Agent runs built-in `/simplify`; if `git status --porcelain`
  is non-empty, commit with `git commit -am "refactor(<scope>): simplify per /simplify"`.

Never add `/code-review --fix`; it is user-invocation-only (`references/constraints.md`).

## Step 3.5: Aggregate review verdicts and apply the merge-gate label

Runs **after every Step 3 lane has returned and before Step 4's push.** That
order is load-bearing, not cosmetic: the lanes tagged their comments with the
PR's current **remote** head, and `/simplify` has at most committed *locally*
by now. Reading the head sha after Step 4 pushes would read the new sha, every
lane would miss, and the gate would silently label nothing forever.

Full runnable block, exit codes, and rationale: `references/review-verdict-label.md`.
In short — bind `TARGET_HOST` from the same `<remote>` URL as `TARGET_REPO`
(the block in `references/reply-pending-label.sh.md` step 0), then:

1. `head_sha` — one `gh pr view "$pr" -R "$TARGET_REPO" --json headRefOid --jq
   .headRefOid`.
2. `BODIES` — one `gh api --paginate "repos/$TARGET_REPO/issues/$pr/comments"`,
   **raw JSON with no `--jq '.[].body'`** (#1639): the harvester filters on
   `.user.login`, and pre-extracting `.body` throws the author away.
3. `ME` — the login this pipeline authenticates as:
   `ME="${DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN:-${ME:-$(GH_HOST="$TARGET_HOST" gh api user -q .login)}}"`.
   Only markers written by this login count as a lane's verdict (#1639) — see
   `references/review-verdict-label.md` → "Marker authorship".
4. For **each lane that either ran fresh in Step 3 OR was skipped by the
   duplicate-review guard** (i.e. every lane except one skipped for a
   **missing CLI / non-internal PC** — `/simplify` never contributes either),
   pipe `BODIES` through `devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME"`
   → `devx_pr_review_all_verdict`, and pipe that stream straight into
   `devx_pr_review_all_apply_label "$pr" "$TARGET_REPO" "$TARGET_HOST" "$head_sha"`.
   **Since #1636 that call only ever writes `review-blocked`.** An
   all-non-blocking round clears any stale `review-blocked` and stops there —
   `review-passed` is applied by `gh:pr-reply` Step 6 once every review comment
   has been answered and no BLOCKER is left unresolved, so a PR this step
   leaves unlabelled is "not verified yet", exactly as before. The trailing
   `$head_sha` stays in the call (it is what stamps the #1601 freshness marker
   on the write path `gh:pr-reply` shares) and is inert on this skill's paths.
   **Why a guard-skipped lane must still be included (#1613, agy+codex PR
   #1623 BLOCKER):** the guard skipped it precisely because it already has a
   verdict for `$head_sha` — dropping that lane from the stream would let a
   partial re-run (e.g. only one lane force-re-reviewed) silently overwrite an
   existing `review-blocked` verdict with `review-passed`, because the
   aggregator only sees the lanes fed to it. Since `devx_pr_review_all_lane_block`
   reads whatever marker already exists in `$BODIES` regardless of which
   session or run posted it, including a guard-skipped lane costs nothing extra
   — the same call that decided to skip it already proved the marker exists.
   Never stage the verdicts in a variable and re-expand it — zsh does not
   word-split, and a two-lane PR would silently report one.

Fetch `head_sha` and `BODIES` again here rather than reusing Step 3's
duplicate-guard values (`ME` is stable and may be reused): no
push has happened in between so `head_sha` is unchanged, but the lanes just
posted new comments, and this step needs the **fresh** `BODIES`.

The whole step is **soft-fail**: a labelling failure never blocks Steps 4-6,
and an unlabelled PR reads downstream as "not verified", which
`gh:pr-merge-train` `[SKIPPED]`s rather than merges.

## Step 4: Push the auto-fix commit (only if something changed)

Await all lanes, then:

- `/simplify` committed → `git push`.
- The tree was unchanged → skip.

**If the push happened, drop `review-passed` immediately** (soft-fail, same
`_gh_pr_drop_label` helper Step 3.5's SSOT already documents). Step 3.5 labels
against the pre-push head on purpose — but that means a push here moves the
head *the label just certified* out from under it, without a reviewer having
seen the auto-fix diff (PR #1598 review, agy CONCERNS + codex BLOCKER). Never
drop `review-blocked` here — this step holds no evidence any blocker was
addressed, and the auto-fix commit is unreviewed by construction:

```bash
if [ "$PUSHED" = "1" ]; then
    _SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
    [ -f "$_SC/functions/gh_pr_edit_safe.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }
    . "$_SC/functions/gh_pr_edit_safe.sh"
    if _vl_err=$(_gh_pr_drop_label "$pr" review-passed "$TARGET_REPO" "$TARGET_HOST" 2>&1); then
        echo "[OK] \`review-passed\` 무효화됨 — /simplify 커밋이 push 되어 이전 판정은 만료"
    else
        echo "[WARN] \`review-passed\` 제거 실패 — 리뷰되지 않은 auto-fix 커밋에 판정이 남아 있다: ${_vl_err}"
    fi
fi
```

## Step 5: pr-reply (per reply_mode)

- `inline` (default) → run `Skill(gh:pr-reply, "<pr> <remote>")` immediately.
- `defer` → **first** add the `reply-pending` label per
  `references/reply-pending-label.sh.md` (idempotent `gh label create`, then
  `_gh_pr_edit_safe_label`; soft-fail — a label failure never blocks the
  schedule), **then**
  `Skill(devx:schedule, "--time <reply_delay> \"/gh-pr-reply <pr> <remote>\"")`.
  The label is what makes `gh:pr-merge-train` hard-skip this PR until the
  reply pass finishes (#1524); `gh:pr-reply` Step 6 removes it.
- `none` → skip.

Only `defer` labels: `inline` and `none` defer nothing, so there is no pending
state to mark.

## Step 6: Report

Print exactly one `[OK]`/`[SKIP]`/`[WARN]` line, e.g.
`[OK] PR #<pr> reviewed (agy:OK codex:SKIP opencode:OK hermes:SKIP simplify:committed) — reply: inline — verdict: review-passed`.
The trailing clause is Step 3.5's outcome: `review-passed`, `review-blocked`,
or `unlabelled`.

## Constraints (full rationale: `references/constraints.md`)

- Reviewer lanes are soft-fail; `/simplify` commits its own changes before push.
- Never add `/code-review`; never run bare `git commit`.
- Inline reply is deterministic; `--defer-reply` is minutes-only and not a guarantee.
- No approve / request-changes here — that is `gh:pr-approve`.

## Related Skills

`gh:pr-review` (one reviewer at a time — this skill fans out over it) · `gh:pr-reply` / `devx:schedule` (the reply
pass) · `gh:pr-approve` (the approve/request-changes decision) · `gh:pr-merge-train` (consumes Step 3.5's
verdict label as a hard merge gate) · `gh:label-bootstrap` (provisions the two labels). Reused by
`gh:issue-flow` (Step 2.4) as its post-PR quality gate.
