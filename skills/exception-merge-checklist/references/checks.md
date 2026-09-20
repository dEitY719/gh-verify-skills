# gh-verify:exception-merge-checklist — 10 Checks

Each check below is the SSOT for **what one row means**. Format:

- **Pass condition** — the exact predicate
- **Recovery hint** — the bullet emitted in the Recovery Actions
  section when the row is WARN or FAIL
- **Rationale** — the historical regression (from the 2026-05-16
  AgentToolbox PR #727 retrospective) that motivates this check

**The commands live in `lib/run-checks.sh`, not here**
(dEitY719/gh-verify-skills#35). This file used to carry a
**Command** block per check — ten fragments of runnable shell the
model re-derived from prose on every run, and a fourth place the
check catalogue could drift from. The script is now the single
executable statement of each predicate; these pages state what the
predicate *means* and what to do when it fails, which is the part
that genuinely needs prose. Read a check's implementation in the
script; read what it is for here.

Run order, degradation and aggregation belong to the script too:
C1–C5 and C7–C10 run in parallel, C6 walks every commit and is
serial, no check fail-fasts, and a check whose tooling is absent
degrades to `N/A` with the reason rather than to `FAIL`. Those are
properties of a program now, not instructions to follow — see
`references/run-checks.sh.md` for the call and the contract.

---

## Gating Checks (C1–C5)

### C1 — linked SSOT issue

**Pass when** PR body contains `Closes #<N>` (or `Resolves #<N>` /
`Fixes #<N>`) AND issue `<N>` exists and is `OPEN`. `Refs #<N>` is
WARN-not-FAIL because the relation exists but the merge will not
auto-close the issue.

**Recovery hint** — `PR body 에 \`Closes #<SSOT-issue>\` 추가`

**Rationale** — Exception-track PRs often start as a hand-merge
hotfix and skip the issue-first rule. Without `Closes`, the SSOT
issue stays OPEN after merge and the parent-issue / milestone
rollup breaks. Detected manually in PR #727.

### C2 — parent issue

**Pass when** the SSOT issue from C1 has a parent in either form:
(a) body line matching `Parent: #<M>` or `Parent issue: #<M>`,
(b) GitHub-native sub-issue relation present (queryable via
`issues/<N>/sub_issues`). N/A when C1 itself is FAIL.

**Recovery hint** — `SSOT issue #<N> body 에 \`Parent: #<M>\` 추가
하거나 GitHub UI 에서 sub-issue 로 연결`

**Rationale** — Exception-track PRs frequently lack the epic /
parent link, breaking the project-board hierarchy rollup. This
check makes the missing link visible at merge time instead of at
sprint review.

### C3 — mergeable

**Pass when** `gh pr view --json mergeable` returns exactly
`MERGEABLE`. `UNKNOWN` is WARN (GitHub is still computing — retry
once after 5 s). `CONFLICTING` is FAIL.

**Recovery hint** — `/gh-resolve:conflict <PR#>`

**Rationale** — Standard mergeability check; lumped in here so the
single audit pass covers everything that would block the merge.

### C4 — all CI green

**Pass when** every entry in `statusCheckRollup` has
`conclusion == SUCCESS`. Any `FAILURE`, `CANCELLED`, `TIMED_OUT`,
or `ACTION_REQUIRED` → FAIL. `PENDING` / `IN_PROGRESS` / `QUEUED`
→ WARN (CI still running).

**Recovery hint** — print each failing job's name and:
`gh run rerun --failed --job <id>` (or PR re-push for required
re-runs).

**Rationale** — Exception track means "CI green but hand-merge",
so this should normally pass. When it does not, the audit catches
a regression that would otherwise be missed in the rush to merge.

### C5 — review APPROVED

**Pass when** `reviewDecision == APPROVED`. Empty string on a repo
with no branch protection on `baseRefName` → WARN (mirrors
`gh-pr:merge`'s solo-repo logic). `REVIEW_REQUIRED` /
`CHANGES_REQUESTED` → FAIL.

**Recovery hint** — name the missing reviewer(s) and suggest
`/gh-pr:approve <PR#>` for an automated approve flow.

**Rationale** — Same gate `gh-pr:merge` uses; surfaced here so the
single audit shows all blockers in one pass.

---

## Regression Detectors (C6–C10)

These are the value-add. Each one catches a specific regression
that escaped ordinary CI in the 2026-05-16 PR #727 incident
(referenced as RX in the rationale lines).

### C6 — bisect-safe (per-commit build)

**Pass when** `git rebase --exec '<build-cmd>' <base>..HEAD`
exits 0 at every commit. `N/A` when `--skip-bisect` is set (the
report shows `N/A (--skip-bisect)`). Default `<build-cmd>` is
`bun run build`; override with `--build-cmd`.

**Recovery hint** — print the failing commit SHA and:
```
git rebase -i <base>..HEAD
# mark the bad commit `edit`, fix the source, then
git rebase --continue
```

**Rationale (R1)** — PR #727 had commit `104f802` with a conflict
marker still embedded in source. HEAD built cleanly because a
later commit overwrote the file, but `git bisect` would step into
the broken commit and falsely accuse it of a different bug.
`--skip-bisect` is allowed only when the merge target is configured
for squash-merge — squashing destroys intermediate commits, so
their build state never reaches `main`.

### C7 — openapi.yaml parses

**Pass when** a Prism mock server boots within 30 s on the PR's
`openapi.yaml`. N/A when the repo does not contain `openapi.yaml`
or a `*.openapi.yaml` glob.

**Recovery hint** — print the first 5 non-empty lines of
`.audit-prism.log` (includes the line number Prism rejected) and:
`open openapi.yaml:<line>` to fix the indent / schema error.

**Rationale (R3)** — PR #727 introduced a YAML indent bug at
`openapi.yaml:1437`. The CI contract-test job timed out (because
Prism never reached "listening") and the failure mode looked like
test flake. Catching it here as a parse failure pinpoints the
exact line.

### C8 — `.openapi-lock` matches

**Pass when** `sha256sum -c .openapi-lock` exits 0. N/A when the
repo does not have `.openapi-lock` (not an openapi-bound project).

**Recovery hint** — `bash scripts/update-openapi-lock.sh` (or
`make openapi-lock`) and commit the regenerated `.openapi-lock`.
`--auto-fix` automates the regenerate + `git add` (no commit).

**Rationale (R2)** — PR #727 had `build:spec` overwrite a
placeholder OpenAPI doc and never regenerate `.openapi-lock`, so
production deploys would fetch a spec whose sha did not match the
lockfile. Fixed in commit `2452e07` amend after the fact.

### C9 — prettier scope clean

**Pass when** `prettier --check` succeeds on the changed
`*.md` / `*.json` / `*.yml` / `*.yaml` files in the PR diff. Source
code (`*.ts` / `*.tsx` / `*.js`) is intentionally excluded — the
regression here is over-formatting docs, not code.

**Recovery hint** — list the offending files and:
`bunx prettier --write <files>`. `--auto-fix` automates the rewrite
+ `git add` (no commit).

**Rationale (R5)** — PR #727 ran `bunx prettier --write '**/*'`,
which touched 45 files outside the PR's actual scope. Reviewers
had to manually revert 38 of them. Scoping the check to changed
files only catches the over-write before it ships.

### C10 — test mocks complete

**Pass when** every NEW `cookies()`, `headers()`, or
`new NextRequest(` call introduced in the PR diff (under
`apps/**/*.ts` and `apps/**/*.tsx`) has a matching mock in a test
file in the same PR diff. The heuristic is: for each prod-file
match, expect a corresponding `vi.mock('next/headers'`,
`vi.mocked(cookies)`, or `new NextRequest(` in a `*.test.ts(x)` /
`*.spec.ts(x)` file within the same PR.

**Recovery hint** — list the prod-side files whose new call has no
matching test mock and emit a copy-paste template:

```ts
import { vi } from 'vitest';
vi.mock('next/headers', () => ({
  cookies: vi.fn(() => ({ get: vi.fn() })),
  headers: vi.fn(() => new Headers()),
}));
```

**Rationale (R6)** — PR #727 added 5 production-path `cookies()`
calls without updating `page.redirect.test.ts`'s mocks. The
failing tests looked like flake until commit `d019963` added the
missing mocks. The heuristic is intentionally false-positive-prone
— a WARN here is much cheaper than missing the regression.

---

## Result aggregation

After all 10 checks run, classify the overall outcome:

| FAIL count | Verdict line |
|------------|---------------|
| 0 | `safe to merge` (exit 0) |
| ≥ 1 | `N FAIL, M WARN — NOT safe to merge` (exit 1) |

WARN alone never blocks. The user decides whether to treat WARNs
as merge-blocking on a case-by-case basis.

`lib/run-checks.sh` computes this and emits it as the last two
rows — `SCORE` and `VERDICT`, with the exit code above in
`VERDICT`'s second field — so Step 3 renders the table rather than
re-counting it. `lib/run-checks.selfcheck.sh` pins the arithmetic,
including that a board of nothing but WARN still reads `safe to
merge`.
