# gh-verify:exception-merge-checklist — AI Metrics Footer

The skill posts a soft-fail ai-metrics comment on the audited PR
after Step 4. The footer follows the SSOT format established in
PR #320 and re-used by every `gh:*` and `devx:*` skill that
operates on a PR.

## When NOT to post

Skip the comment entirely (no warning, no log) when either of:

- `GH_DISABLE_AI_METRICS=1` (issue #399 contract — same env var
  honored by `gh:issue-implement`, `gh:commit`, `gh:pr`,
  `gh:pr-merge`, etc.)
- The skill exited with code 2 (bad args) or 3 (no PR detected) —
  there is nothing to attach the comment to.

## Comment body template

```markdown
### gh-verify:exception-merge-checklist 완료

| Group | Result |
|-------|--------|
| Gating (C1–C5) | <P_GATE>/5 PASS, <W_GATE> WARN, <F_GATE> FAIL |
| Regression detectors (C6–C10) | <P_REGR>/5 PASS, <W_REGR> WARN, <F_REGR> FAIL, <N_REGR> N/A |
| **Verdict** | **<VERDICT_LINE>** |

예상 사람 시간: ~<HUMAN_H> h (수동 점검 대비 절약) · 토큰: ~<TOKENS>

---
<details>
<summary>🤖 AI Metrics · 📊 ~<TOKENS> tokens · 👤 ~<HUMAN_H> h · 🤖 ~<ELAPSED> min</summary>

<!-- ai-metrics:gh-verify-exception-merge-checklist -->
📊 ~<TOKENS> tokens · 👤 ~<HUMAN_H> h · 🤖 ~<ELAPSED> min
<!-- /ai-metrics:gh-verify-exception-merge-checklist -->

</details>
```

## Field derivation

| Field | Source |
|-------|--------|
| `ELAPSED` | `$(( ($(date +%s) - START_TS) / 60 ))` — minutes since Step 1 |
| `TOKENS` | character count of all `gh` JSON outputs read in Step 2 (`gh pr view`, `gh issue view`, `gh api` calls) divided by 4, rounded to nearest 500, minimum 1000 |
| `HUMAN_H` | flat 0.75 — the baseline cost of running the 10-check audit by hand (the 2026-05-16 retrospective measured 1.5 h for 6 sequential discoveries; the audit short-circuits that by running all 10 in parallel) |
| `P_GATE`, `W_GATE`, `F_GATE` | PASS / WARN / FAIL counts from C1–C5 |
| `P_REGR`, `W_REGR`, `F_REGR`, `N_REGR` | PASS / WARN / FAIL / N/A counts from C6–C10 |
| `VERDICT_LINE` | `safe to merge` or `N FAIL, M WARN — NOT safe to merge` from Step 3 |

## Post mechanics

Write the rendered body to a temp file, then POST via `gh api`.
Two safety choices in the command below:

- **`{owner}/{repo}` placeholder** in the URL — `gh api` auto-fills
  it from the current working directory's git remote, so the call
  works regardless of whether `TARGET_REPO` was stored as
  `owner/repo` or as a full URL (`gh api` itself does NOT accept a
  `--repo` flag — that flag is for `gh pr` / `gh issue`).
- **`-F body=@FILE`** (capital `F`) reads the file directly. The
  lowercase `-f body=@FILE` is a known regression that posts the
  literal path string instead of the file contents (see dotfiles
  MEMORY "gh:discussion-create body-file 회귀").

```sh
BODY_FILE=$(mktemp) && trap 'rm -f "$BODY_FILE"' EXIT
printf '%s' "$BODY" > "$BODY_FILE"

gh api "/repos/{owner}/{repo}/issues/$PR_NUMBER/comments" \
  -X POST \
  -F body=@"$BODY_FILE" \
  >/dev/null 2>&1 \
  && echo "[OK] ai-metrics comment posted" \
  || echo "[WARN] ai-metrics comment failed — continuing."
```

Soft-fail policy: a failed POST never changes the skill's exit
code. The audit verdict (Step 3) is the user-facing contract; the
metrics comment is observability for the team dashboard.

## Why a comment, not a body edit

`gh:pr` writes the per-step metric block into the PR **body** via
`gh pr edit --body-file`. This skill posts as a **comment** for
three reasons:

1. The audit runs many times on the same PR (every push triggers
   the user to re-run); a comment thread preserves the history of
   each pass, whereas a body edit would overwrite the last result.
2. Body edits go through `_gh_pr_edit_safe_body` to dodge the
   classic-projects silent-fail (issue #326 Bug B). A comment POST
   has no such trap.
3. The PR body already carries multiple `<!-- ai-metrics:* -->`
   blocks from earlier skills (`gh:pr`, `gh:pr-resolve-conflict`,
   etc.); a new block per audit run would either bloat the body
   or require an in-place replace flow that this skill does not
   need.

## Idempotency

The comment is NOT deduplicated. Each invocation posts a fresh
comment. This is deliberate — re-running the audit after a fix is
a separate event, and the team dashboard counts each run as one
data point. If a future need arises to coalesce repeated audits,
add a `--once` flag rather than changing the default.
