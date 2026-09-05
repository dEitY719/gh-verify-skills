# gh-verify:exception-merge-checklist — Help

## Arguments

| # | Name | Default | Description |
|---|------|---------|-------------|
| 1 | `<PR#>` or `-h`/`--help`/`help` | auto-detect | GitHub PR number. When omitted, the skill resolves the PR attached to the current branch via `gh pr view`. |

## Flags

| Flag | Description |
|------|-------------|
| `--skip-bisect` | Skip C6 (commit-by-commit build). Use when the merge target is squash-merge (intermediate commits are discarded). C6 is reported as `N/A` with a one-line reason. |
| `--auto-fix` | After the report, run deterministic fixes for C8 (`.openapi-lock` regenerate) and C9 (`prettier --write` on changed-only files) and stage them with `git add`. **Never commits.** All other FAILs require human decisions. |
| `--build-cmd <cmd>` | Override the C6 per-commit verification command. Default is `bun run build`. Quote the value if it contains spaces. |

## Usage

- `/gh-verify:exception-merge-checklist 727` — full audit on PR #727
- `/gh-verify:exception-merge-checklist` — auto-detect PR on current branch
- `/gh-verify:exception-merge-checklist 727 --skip-bisect` — skip C6 (squash-merge target)
- `/gh-verify:exception-merge-checklist 727 --auto-fix` — audit, then stage C8/C9 fixes
- `/gh-verify:exception-merge-checklist 727 --build-cmd "npm run build && npm test"` — alt build
- `/gh-verify:exception-merge-checklist -h` / `--help` / `help` — print this help

## What the skill checks

The audit splits into two groups. **Gating checks (C1–C5)** verify PR
metadata and CI state that ordinary review covers — fast,
metadata-only. **Regression detectors (C6–C10)** are the value-add of
this skill: they catch the six specific regressions that bypassed CI
in the 2026-05-16 AgentToolbox PR #727 incident.

### Gating Checks

| # | Name | Pass when |
|---|------|-----------|
| C1 | linked SSOT issue | PR body has `Closes #N` (or `Refs #N`) and that issue exists |
| C2 | parent issue | The SSOT issue's body links a parent (`Parent: #M` or sub-issue relation) |
| C3 | mergeable | `gh pr view --json mergeable` returns `MERGEABLE` |
| C4 | all CI green | Every `statusCheckRollup.conclusion` is `SUCCESS` |
| C5 | review APPROVED | `reviewDecision == APPROVED` |

### Regression Detectors

| # | Name | Pass when |
|---|------|-----------|
| C6 | bisect-safe | `git rebase --exec '<build-cmd>' <base>..HEAD` succeeds at every commit |
| C7 | openapi.yaml parses | Prism mock starts within 30 s on `openapi.yaml` |
| C8 | `.openapi-lock` matches | `sha256sum -c .openapi-lock` exits 0 |
| C9 | prettier scope clean | `prettier --check` passes on the PR's changed md/json/yml/yaml only |
| C10 | test mocks complete | Every new `cookies()` / `headers()` / `new NextRequest(` call in the diff has a corresponding mock in the same PR |

Full criteria, exact commands, recovery hints, and the historical
regression each one catches live in `references/checks.md`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All PASS, or only WARN (no FAIL) — safe to merge |
| 1 | ≥ 1 FAIL — NOT safe to merge; see Recovery Actions |
| 2 | Bad args (unknown flag, missing remote, invalid PR number) |
| 3 | No PR detected for the current branch and no PR# argument given |

## What the skill will NOT do

- Merge, approve, push, or comment beyond the metrics footer.
- Edit PR body, labels, or assignees.
- Run `git commit` even with `--auto-fix` — only `git add`.
- Fall back to a different build command when `--build-cmd` is wrong.
- Skip C7–C10. Those are the regression detectors and must run.
- Fail-fast. All 10 checks complete so the user sees the full report.

## When to use which skill

| Situation | Skill |
|-----------|-------|
| Pre-merge sanity on an exception-track PR (hand-merge with extra scrutiny) | `gh-verify:exception-merge-checklist` |
| Normal PR review and approve flow | `gh-pr:approve` |
| Merge an already-approved PR | `gh-pr:merge` |
| Resolve conflicts before merging | `gh-resolve:conflict` |
| Bypass approval for incident/hotfix with audit | `gh-pr:merge-emergency` |

## Sister skill

`/spec-flow:pr-to-ssot-issue` is the planned entry-track counterpart —
turn a finished PR into an SSOT issue with the same metadata
contract that C1 / C2 check. Tracked separately (not yet
implemented at the time of this skill's introduction).
