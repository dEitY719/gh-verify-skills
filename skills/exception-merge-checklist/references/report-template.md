# gh-verify:exception-merge-checklist — Report Template

Use this exact format when printing the Step 3 audit report.

```
## gh-verify:exception-merge-checklist Report
PR:    #<N> — <title>
URL:   <pr-url>
Base:  <baseRefName> @ <base-sha>
Head:  <headRefName> @ <head-sha>
Build: <build-cmd>   (default | --build-cmd)

### Gating Checks
| #  | Check                       | Result | Notes                            |
|----|-----------------------------|--------|----------------------------------|
| C1 | linked SSOT issue           | PASS   | Closes #<N>                      |
| C2 | parent issue                | WARN   | sub-issue relation missing       |
| C3 | mergeable                   | PASS   | MERGEABLE                        |
| C4 | all CI green                | PASS   | 12/12 checks SUCCESS             |
| C5 | review APPROVED             | PASS   | 1 approval, branch protected     |

### Regression Detectors
| #  | Check                       | Result | Notes                            |
|----|-----------------------------|--------|----------------------------------|
| C6 | bisect-safe                 | FAIL   | broken at 104f802                |
| C7 | openapi.yaml parses         | PASS   | Prism boot 3.2s                  |
| C8 | .openapi-lock matches       | FAIL   | sha mismatch — regenerate        |
| C9 | prettier scope clean        | FAIL   | 45 files outside diff scope      |
|C10 | test mocks complete         | WARN   | 3 cookies() calls, no new mocks  |

Score: 5/10 passed (3 WARN, 3 FAIL, 0 N/A)
Verdict: 3 FAIL, 3 WARN — NOT safe to merge

### Recovery Actions
1. [WARN C2] SSOT issue #N body 에 `Parent: #M` 추가하거나 GitHub UI 에서
   sub-issue 로 연결.
2. [FAIL C6] 깨진 commit: 104f802
     git rebase -i origin/main..HEAD
     # mark 104f802 as `edit`, fix conflict marker, then `git rebase --continue`
3. [FAIL C8] .openapi-lock drift:
     bash scripts/update-openapi-lock.sh
     git add .openapi-lock
   Or run `/gh-verify:exception-merge-checklist <PR#> --auto-fix` to auto-stage.
4. [FAIL C9] 45 files outside the PR's intended scope. Affected:
     apps/web/README.md
     docs/*.md (38 files)
     ...
     bunx prettier --write <listed-files>
5. [WARN C10] New cookies() calls without test mocks in:
     apps/web/app/(auth)/page.tsx:24
     apps/web/app/dashboard/route.ts:11
   Add to a matching .test.ts in the same PR:
     import { vi } from 'vitest';
     vi.mock('next/headers', () => ({
       cookies: vi.fn(() => ({ get: vi.fn() })),
     }));

Re-run `/gh-verify:exception-merge-checklist <PR#>` after fixes.
```

## Verdict computation

- `0 FAIL` → `safe to merge` → exit code 0
- `≥ 1 FAIL` → `<F> FAIL, <W> WARN — NOT safe to merge` → exit code 1

WARN alone is never a merge blocker. The user judges whether a
specific WARN is acceptable for the PR at hand (e.g. C2 missing
parent on a one-off hotfix may be intentional).

## Notes column rules

- ≤ 40 characters — must fit a standard terminal.
- For PASS rows: a one-glance summary of the observed value
  (`MERGEABLE`, `12/12 checks SUCCESS`, `1 approval, branch protected`).
- For WARN / FAIL rows: the dominant symptom (`sha mismatch — regenerate`,
  `broken at <short-sha>`, `45 files outside diff scope`).
- For N/A rows: the reason (`--skip-bisect`, `no openapi.yaml`,
  `no apps/ tree`).

## Recovery Actions rules

- **One bullet per WARN / FAIL.** PASS and N/A produce no bullet.
- Each bullet starts with `[<LEVEL> C<N>]` so the user can map
  back to the table row.
- Each bullet must be **actionable** — paste the exact command or
  code snippet to fix the symptom. Vague guidance ("review the
  CI logs") is worse than no bullet.
- For C6 FAIL: print the failing commit SHA explicitly so the
  user does not have to re-run the audit to find it.
- For C9 FAIL: list the offending files (truncate to 10 with a
  `... (N more)` suffix when longer).
- For C10 WARN: emit a copy-paste mock template (see
  `references/checks.md` C10 recovery hint).
- End the Recovery Actions section with one line:
  `Re-run \`/gh-verify:exception-merge-checklist <PR#>\` after fixes.`

## Output rules

- Tables use exactly the columns shown: `#`, `Check`, `Result`,
  `Notes`. No extra columns.
- Result column values are uppercase: `PASS` / `WARN` / `FAIL` /
  `N/A`.
- Do NOT add filler prose ("the PR looks great!") — the Verdict
  line already classifies overall safety.
- If `Score = 10/10` (no WARN, no FAIL), the Recovery Actions
  section reads exactly:
  `No actions required.`
