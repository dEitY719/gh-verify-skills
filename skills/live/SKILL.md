---
name: live
# Check 16 WARN-band exception (379 chars, limit 250) — measured, not preferred.
# #1411 shrank this description and dropped its "Sister skill of
# gh-verify:merged" boundary. #1417's trigger eval measured the cost:
# rejection of gh-verify:merged's queries fell 9/10 -> 5/10 and the score
# fell 85% -> 65%, breaking the `after >= before - 5%p` contract. Restoring the
# negative trigger below returned it to 10/10 / 90%. The sentence is load-bearing
# for discrimination, so it stays over 250 until a shorter wording is measured to
# hold the same rejection rate. Procedure:
# dotfiles claude/skills/skill-check/references/trigger-eval-procedure.md
description: >-
  Verify a PR against the already-running dev app, proving the serving checkout
  really is the target commit. Use for /gh-verify:live, /devx:pr-verify-live, /devx-pr-verify-live,
  "머지된 PR 라이브 검증", "실행 중인 앱에서 내 PR 직접 확인해",
  "live-verify this PR". Do NOT use when there is no app to run and the proof must
  come from a fresh clone of the merge commit — that is gh-verify:merged.
  Read-only on source.
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion, Agent
metadata:
  model_recommendation:
    tier: opus
    reason: "live browser verification with adversarial self-refutation; a false positive files a wrong issue in someone else's repo"
    claude: prefer
    non_claude: advisory-only
---

# gh-verify:live — Verify a PR against the running app

## Role

**올바른 체크아웃을 서빙 중인 앱에 붙어 · PR/이슈가 지정한 화면을 몰아 보며 · 기계 판독 가능한 단언으로 확인하고
· 자기 반증에서 살아남은 발견만 대상 레포의 신규 이슈로 넘긴다.** 막으려는 실패 클래스는 **화면은 멀쩡히 뜨는데
검증이 무효인 상태**(잘못된 체크아웃 · no-op 전환 · 오버레이에 가린 대상 · 일부 분기만 보고 전부 봤다는 착각) 하나다.
머지 직후가 주 용도지만 **미머지 PR 브랜치에도 쓴다**. 이슈 본문·라벨·메트릭은 `gh:issue-create` 가 SSOT — 이 스킬은
**게이트만** 책임진다. 실측 출처: `references/provenance.md`. 6줄 공통 계약(유일한 사본): `references/verify-contract.md`.

## Help

If arg #1 is `-h`, `--help`, or `help`, read `references/help.md` and output it
verbatim, then stop. No API calls, no browser.

## Step 1: Parse Args

`_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"; [ -f "$_SC/functions/devx_pr_verify_live.sh" ] || _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; source "$_SC/functions/devx_pr_verify_live.sh"` then `devx_pr_verify_live_parse "$@"` — 플래그 표는
`references/help.md`. On `help_requested=1` follow Help; on exit 2 print the stderr line and stop. Capture `pr`
`remote` `url` `api_url` `start_cmd` `matrix` `viewports` `locales` `issue_mode` `allow_remote_host`
`post_comment`. Record `START_TS=$(date +%s)`.

## Step 2: Resolve target + discover the environment (`references/discovery.md`)

- `discovery.md` §3 의 소스 블록(`DOTFILES_FORCE_INIT=1` 필수)으로 `_gh_pr_review_resolve_target_repo` ·
  `_gh_pr_review_resolve_pr_number` 를 쓴다; 브랜치가 `[gone]` 이면 커밋 → PR 역추적.
- base URL / API origin 발견 (`--url`·`--api-url` 이 있으면 건너뛴다). 후보가 여럿이면 `AskUserQuestion` — **추측 금지**.
- **호스트 가드**: 대상이 로컬(`localhost` · `127.0.0.0/8` · `::1` · `0.0.0.0`)이 아니면 `--allow-remote-host` 없이
  정지 (Step 6 은 앱 데이터에 쓰기를 한다). `--start` 를 준 경우에만 레포 루트에서 기동하고 종료 시 정리한다.

## Step 3: Pre-verification assertion 1 — serving checkout

**변경된 코드를 서빙하는 모든 프로세스**에 대해 cwd → repo root → ancestry 를 돌린다. 비교 대상은 PR 메타 1회
fetch(`$PR_JSON`, Step 4 까지 재사용)의 `.mergeCommit.oid` — `headRefOid` 는 rebase/squash merge 로 재작성되므로 쓰지
않는다(미머지 PR 일 때만 폴백). 불일치면 몇 커밋 뒤처졌는지와 함께 **정지**한다. dirty 워킹 트리는 경고이다. 컨테이너
백엔드는 `devx_pr_verify_live_backend_identity.sh` 헬퍼를 통해 검증하며, verified면 계속 진행, mismatch면 즉시 정지,
unverified면 사유/근거를 리포트에 명시하고 계속 진행한다.

## Step 4: Decide what to verify (`references/targets.md`)

우선순위: 연결된 **이슈의 AC**(체크 무관) → PR `Test plan` 미체크 항목(최종 diff 와 대조) → 라우트 추론(진입점까지) →
`AskUserQuestion`. `- [x]` 를 통과로 취급하지 않는다. 이어서 **각 분기에 도달할 데이터 상태**(계정·레코드)를 API 로 찾고
**feature flag 게이트**가 열려 있는지 확인한다 — 닫혀 있으면 결함이 아니라 미검증이며 켤지 말지를 묻는다. 도달 불가
분기는 `unverified[]`.

## Step 5: Driver + session (pre-verification assertions 2·3)

`references/driver.md` 의 사다리(playwright MCP → python → node → degraded)를 **브라우저 바이너리까지** 확인해 고르고,
그 드라이버가 가능케 하는 검사군을 확정한다. 그다음 `references/recipe-cache.md` 로 로그인·오버레이 해제·로케일 전환
레시피를 캐시에서 읽거나 발견한다. 여기서 **단언 2·3** 이 걸린다 — 전환이 실제로 적용됐는가, 대상이 가려지지 않았는가.
실패면 **측정하지 않고 정지**한다.

## Step 6: Measure (`references/assertions.md`)

먼저 diff 로 **축을 고르고**(`--matrix full` 은 opt-in), 변경 유형이 정하는 근거 형태로 각 항목을 단언한다: 측정값 ·
형제 비교 · 지시-어포던스 · 셀렉터 규율 · 응답 가로채기 · 선행 조건 합성 · hit-test. 합성한 엔드포인트는 전부 기록한다.

## Step 7: Findings → issues (`references/findings.md`)

후보 1건마다 **자기 반증 3가설**(하네스 오류 · 데이터 상태 · 의도된 동작)을 먼저 세워 반증하고, 그다음 게이트 5개를
건다. 통과한 것만 발견 1건 = 이슈 1건으로 `Skill(gh:issue-create, "--assignee @me")` 에 넘기되 생성 직전 **대상 레포를 출력**한다. 회귀와
기존 결함을 갈라 적고, PR 의 근거가 반증됐으면 그 정정도 수정안에 포함한다. `issue_mode` 가 `dry-run` 이면 본문만
출력, `none` 이면 초안조차 쓰지 않는다.

## Step 8: Report (`references/report-template.md`)

그 양식으로 한 블록을 출력한다. `Checks:` 만 적지 않는다 — `Matrix:` `Unverified:` `Synthetic:` `Rejected:` `Created:` 가 빠지면 실제보다 강해 보인다.

## Step 9: 리포트를 PR 코멘트로 게시 (`references/pr-comment.md`)

Step 8 이 `[OK]`/`[WARN]` 이고 `post_comment=1` 일 때만 그 리포트 블록을 **그대로** 대상 PR 코멘트로 남긴다 —
`gh_pr_review.sh` 의 `_gh_pr_review_post_comment` 를 폴백 블록으로 감싸 재사용하고, 게시 실패는 경고일 뿐 정지가
아니다. `[FAIL]` 은 (`--no-comment` 여부와 무관하게) 게시하지 않으며, `--dry-run`·`--no-issue` 는 이 단계를 게이트하지 않는다.

## Constraints (전체 목록과 근거: `references/constraints.md`)

- 검증 전 단언 3종(체크아웃 · 전환 적용 · 비가림) 중 하나라도 실패면 측정하지 않고 정지한다.
- **소스 코드는 읽기 전용 — 수정은 `gh:issue-create` 로 신규 이슈로만 나간다.** 앱 **데이터에는 쓰기를 한다** — dev/fake 스택 전용이고, 사용자가 띄운 서버는 죽이지 않는다(`--start` 로 띄운 것만 정리).
- 근거 없는 발견, 자기 반증을 통과하지 못한 후보는 이슈로 만들지 않는다.
- 못 찾은 값을 추측하지 않고, 축소한 커버리지를 숨기지 않고, 자격증명을 어디에도 남기지 않는다.

## Related Skills

자매 스킬 `gh-verify:merged` — 같은 머지 후 슬롯, 다른 증명 대상(live=서빙 체크아웃 신원, merged=신선한 클론 신원). 발견 등록은 `gh:issue-create`, 머지 **전** 정적 게이트는 `gh-verify:review-all`. 전체 표: `references/help.md`.
