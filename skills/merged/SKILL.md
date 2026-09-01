---
name: merged
# Check 16 WARN-band exception (388 chars, limit 250) — measured, not preferred.
# #1411 shrank this description and dropped two distinct things: the positive
# discriminator ("no running app", "dirty worktree") and the "Sister skill of
# gh-verify:live" boundary. #1417's trigger eval measured each half
# separately on this skill's own eval set:
#   before (pre-#1411)              90%  recall 8/10  reject 10/10
#   after  (#1411, 244 chars)       75%  recall 7/10  reject  8/10   FAIL
#   boundary restored only         75%  recall 5/10  reject 10/10   FAIL
#   both restored (this, 388ch)     90%  recall 8/10  reject 10/10   PASS
# The boundary sentence restores rejection; the positive discriminator restores
# recall. Both are load-bearing, so this stays over 250 until a shorter wording
# is measured to hold 90%. Procedure:
# dotfiles claude/skills/skill-check/references/trigger-eval-procedure.md
description: >-
  Re-verify a merged PR in a fresh clone of its merge commit, proving a clean
  checkout behaves as claimed — for repos with no running app, where post-merge
  checks otherwise run in a dirty worktree. Use for /gh-verify:merged, /devx:pr-verify-merged, /devx-pr-verify-merged,
  "머지된 PR 신선한 클론에서 재검증", "worktree 말고 clone 에서 검증해",
  "verify from a clean clone". Sister skill of gh-verify:live
  (live=serving-checkout, merged=fresh-clone).
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion, Agent
metadata:
  model_recommendation:
    tier: opus
    reason: "differential + environment-matrix reasoning with self-refutation before filing issues in another repo; a false 'proven' verdict is worse than no verification"
    claude: prefer
    non_claude: advisory-only
---

# gh-verify:merged — Verify a merged PR from a fresh clone

## Role

**머지 커밋의 신선한 클론 안에서만 · PR·이슈의 AC 를 · 기계 판독 가능한 단언으로 확인하고 · 자기 반증에서
살아남은 발견만 이슈로 넘긴다** — 사용자의 작업 트리와 **독립적으로** 깨끗한 체크아웃이 주장대로 동작함을 증명한다.
막으려는 실패 클래스는 **작업 worktree 에서는 초록인데 다른 모든 클론과 CI 에서는 그 검사가 존재하지도 않는 상태**
하나다. 대상은 **띄울 앱이 없는 레포**(shell 스크립트 · CLI · 라이브러리) — 머지 후 점검이 더러운 worktree 에서
돌아 untracked-artifact 버그를 숨기는 곳이다. 두 스킬의 6줄 공통 계약은
`../live/references/verify-contract.md` — 이슈 본문·라벨·메트릭은 `gh:issue-create` 가 SSOT.

## Help

If arg #1 is `-h`, `--help`, or `help`, read `references/help.md` and output it
verbatim, then stop. No API calls, no clone.

## Step 1: Parse Args

Positional `[pr-number] [remote]` 는 **첫 글자로 구분**한다 — 숫자면 PR#(양의 정수가 아니면 exit 2),
아니면 remote(기본 `origin`). 플래그는 `--x V`·`--x=V` 둘 다 받고 빈 값·모르는 플래그·남는 positional
은 exit 2 (플래그 표: `references/help.md`). 캡처: `pr` `remote` `matrix` `env_axes` `clone_dir` `diff_check` `issue_mode` `post_comment`.

## Step 2: 대상 해석 (F-1)

`DOTFILES_FORCE_INIT=1` 을 export 한 뒤 `gh_pr_review.sh` 를 source 해 `_gh_pr_review_resolve_target_repo`
· `_gh_pr_review_resolve_pr_number` 를 쓴다 — **그 변수 없이 source 하면 인터랙티브 가드에 막혀 함수가
정의되지 않는다** (복사할 블록: `../live/references/discovery.md` §3). `gh pr view` 로
`state` `mergedAt` `mergeCommit` `baseRefName` `body` `files` `closingIssuesReferences` 를 **1회만**
fetch 해 Step 6 까지 재사용하고, `state != MERGED` 또는 `.mergeCommit.oid == null` 이면 **정지**한다.

## Step 3: 검증 전 단언 — 신선한 클론과 그 무결성 (`references/clone-gate.md`)

`mergeCommit.oid` 를 체크아웃한 클론을 임시 디렉터리에 만들고(**`headRefOid` 금지** — rebase/squash 가
재작성한다), 이후 **모든 실행은 그 클론 안에서만** 한다. 클론 실패 · HEAD 불일치 · `git status
--porcelain` 이 비어 있지 않음은 **측정하지 않고 정지**다. 이어서 클론과 작업 트리에서 **실제로 실행되는
테스트 케이스의 이름·개수를 비교**해 한쪽에만 있는 케이스를 발견으로 올린다 — 이 스킬의 존재 이유다.

## Step 4: 주장 목록과 검증 명령 (F-4 · F-5)

주장 우선순위: 연결된 **이슈의 AC**(체크 무관) → PR `Test plan` 미체크 항목 → 커밋 메시지의 `검증:`
줄 → `AskUserQuestion`. `- [x]` 를 통과로 보지 않고 **diff 에서 주장을 만들지 않는다**. 검증 명령은
`gh:issue-implement` 와 같은 사다리: `AGENTS.md`/`CLAUDE.md`/`README` → `tox.ini` → `pyproject.toml`
→ `package.json` `test` → `tests/*.bats` → `.claude/scripts/test-*.sh`. 미탐지는 `Unverified:` 한 줄.

## Step 5: 환경 변이 하 재실행 (`references/env-matrix.md`)

기본 축은 **PATH 정규화 1개** — 같은 검증을 `PATH=/usr/bin:/bin` 로 다시 돌려 사용자 셸의 도구 치환
(ugrep→grep 등)을 배제한다. 결과가 갈리면 **그 자체가 발견**이다. locale·셸·줄 끝 축은 diff 에서 유도한
**후보**로 리포트에 적고 실행은 `--matrix full`·`--env` 일 때만 — 축 1개 실패는 그 축만 `unverified` 다.

## Step 6: 차등 검증 (`references/differential.md`)

주장 1건마다 **PR 이전 상태**(머지 전략별 좌표 계산은 `differential.md` §1-1 — squash·단일커밋
rebase 는 `~1`, 다중커밋 rebase 는 `~N`)로 같은 입력을 돌린다. 같은 `TEST_CMD` 를 공유하는 주장은 이전
상태 실행을 **1회만** 돌려 결과를 나눠 쓴다. 전·후 결과가 같으면 `unproven` — 둘 다 통과하는 검사는
아무것도 증명하지 않는다. 기본 on, `--no-diff-check` 로만 끄고 껐다는 사실을 리포트에 적는다.

## Step 7: 자기 반증 후 이슈화 (F-8)

후보 1건마다 반증 가설 4종(하네스 오류 · 환경 특수성 · 의도된 동작 · PR 과 무관한 기존 결함)을 먼저 세워
반증하고, 살아남은 것만 발견 1건 = 이슈 1건으로 `Skill(gh:issue-create, "--assignee @me")` 에 넘기되 **생성 직전 대상 레포를
출력**한다. `--dry-run` 은 본문만, `--no-issue` 는 초안도 안 쓰며, 생성 실패는 본문을 stdout 에 남기고 `[WARN]`.

## Step 8: 리포트와 PR 코멘트 게시 (`references/report-template.md`)

`[OK]`/`[WARN]`/`[FAIL]` 한 블록 — `Clone:` `Claims:` `Matrix:` `Unproven:` `Unverified:` `Rejected:`
`Findings:` 가 모두 있어야 하고 마지막 줄은 항상 `Next:` 다. 게시는 live 와 **같은 규칙**: `[OK]`/`[WARN]`
이고 `post_comment=1` 일 때만 그 블록을 그대로 대상 PR 코멘트로 남기고, `[FAIL]` 은 `--no-comment` 와
무관하게 게시하지 않는다. 경로는 `_gh_pr_review_post_comment` 하나 — 절차는
`../live/references/pr-comment.md`.

## Constraints (전체 목록과 근거: `references/constraints.md`)

- F-2/F-3 단언 중 하나라도 실패하면 **측정하지 않고 정지**한다. 환경 축 1개 실패는 정지가 아니다.
- 검증은 임시 클론 안에서만 — 작업 트리·인덱스·스태시를 읽지도 쓰지도 않는다(F-3 비교용 읽기만 예외).
- 클론은 종료 시 정리하되 `[FAIL]` 이면 남기고 경로를 출력한다. deny 규칙(`Bash(rm:*)`)에 막히면 **경로를 출력하고 사용자에게 맡긴다 — 우회 금지**.
- **소스는 읽기 전용 — 코드를 고치지 않는다.** 발견은 `gh:issue-create` 로 신규 이슈로만 나간다. 자기 반증을 통과하지 못한 후보는 이슈로 만들지 않는다.

## Related Skills

자매 스킬 `gh-verify:live` — 같은 머지 후 슬롯, 다른 증명 대상(merged=신선한 클론 신원, live=서빙 체크아웃 신원). 발견 등록은 `gh:issue-create`, 테스트 러너 탐지 사다리는 `gh:issue-implement`, 머지 **전** 정적 게이트는 `gh-verify:review-all`. 전체 표와 플래그: `references/help.md`.
