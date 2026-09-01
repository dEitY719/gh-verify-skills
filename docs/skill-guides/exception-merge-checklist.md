# gh-verify:exception-merge-checklist

> 한 줄 요약 — 예외 트랙 손 머지 직전에 10항목 읽기 전용 점검을 돌려 PASS/WARN/FAIL/N/A 표와 Score · Verdict · Recovery Actions 로 된 리포트 한 장을 낸다.

## 언제 쓰는가

- **예외 트랙 PR**(CI 는 초록이지만 추가 검토와 함께 손으로 머지하는 PR)을 머지하기 **직전**의 사전 점검.
- 평범한 CI 게이트가 놓치는 숨은 회귀를 노린다 — rebase 중간 커밋 파손 · OpenAPI lock drift · YAML 들여쓰기
  파손 · 과범위 prettier write · 새 프레임워크 호출(`cookies()` / `headers()` / `new NextRequest(`)에 대한
  테스트 mock 누락.
- 형제 스킬과의 경계:

  | 상황 | 스킬 |
  |------|------|
  | 예외 트랙 PR 의 머지 직전 점검 | `gh-verify:exception-merge-checklist` |
  | 평범한 PR 리뷰·승인 흐름 | `gh:pr-approve` |
  | 이미 승인된 PR 머지 | `gh:pr-merge` |
  | 머지 전 컨플릭트 해소 | `gh:pr-resolve-conflict` |
  | 장애/핫픽스의 승인 우회(감사 동반) | `gh:pr-merge-emergency` |

- `--auto-fix` 가 스테이징한 것을 커밋하는 것은 `gh:commit` 의 몫이다.

## 언제 쓰지 않는가

- **머지·승인 수단으로** — `Never merge, approve, push`. 머지도 승인도 하지 않는다.
- **PR 메타데이터 편집 목적** — PR 본문 · 라벨 · assignee 를 고치지 않는다.
- **커밋 수단으로** — `--auto-fix` 여도 `git commit` 을 돌리지 않는다.
- **일부 검사만 골라 돌리려고** — C7–C10 은 opt-out 불가다(회귀 갭이 다시 열린다). C6 만 `--skip-bisect` 로
  뺄 수 있다.
- **빌드 명령 자동 추측 기대** — `--build-cmd` 없이 `bun run build` 가 없으면 C6 을 `N/A` 로 표시할 뿐
  `npm test` 같은 것으로 갈아타지 않는다.

## 호출

```
/gh-verify:exception-merge-checklist [<PR#>] [--skip-bisect] [--auto-fix] [--build-cmd <cmd>]
```

| # | 이름 | 기본값 | 설명 |
|---|------|--------|------|
| 1 | `<PR#>` 또는 `-h`/`--help`/`help` | auto-detect | GitHub PR 번호. 생략하면 `gh pr view` 로 현재 브랜치에 붙은 PR 을 해석한다 |

### Flags

| Flag | 설명 |
|------|------|
| `--skip-bisect` | C6(커밋별 빌드)을 건너뛴다. squash-merge 대상일 때 쓴다(중간 커밋이 버려지므로). C6 은 사유 한 줄과 함께 `N/A` 로 보고된다 |
| `--auto-fix` | 리포트 뒤에 C8(`.openapi-lock` 재생성)과 C9(변경 파일 한정 `prettier --write`)의 결정적 수정만 실행하고 `git add` 로 스테이징한다. **절대 커밋하지 않는다.** 나머지 FAIL 은 사람 판단이 필요하다 |
| `--build-cmd <cmd>` | C6 의 커밋별 검증 명령을 덮어쓴다. 기본은 `bun run build`. 공백이 있으면 인용한다 |

### 점검 항목

| # | 이름 | 통과 조건 |
|---|------|-----------|
| C1 | linked SSOT issue | PR 본문에 `Closes #N`(또는 `Refs #N`)이 있고 그 이슈가 존재 |
| C2 | parent issue | SSOT 이슈 본문이 부모를 링크(`Parent: #M` 또는 sub-issue 관계) |
| C3 | mergeable | `gh pr view --json mergeable` 이 `MERGEABLE` |
| C4 | all CI green | 모든 `statusCheckRollup.conclusion` 이 `SUCCESS` |
| C5 | review APPROVED | `reviewDecision == APPROVED` |
| C6 | bisect-safe | `git rebase --exec '<build-cmd>' <base>..HEAD` 가 모든 커밋에서 성공 |
| C7 | openapi.yaml parses | `openapi.yaml` 로 Prism mock 이 30초 안에 기동 |
| C8 | `.openapi-lock` matches | `sha256sum -c .openapi-lock` 이 0 으로 종료 |
| C9 | prettier scope clean | PR 이 바꾼 md/json/yml/yaml 만 대상으로 `prettier --check` 통과 |
| C10 | test mocks complete | diff 의 새 `cookies()` / `headers()` / `new NextRequest(` 호출마다 같은 PR 안에 대응 mock 존재 |

C1–C5 는 게이팅 검사(메타데이터·CI 상태), C6–C10 은 2026-05-16 PR #727 회고에서 나온 회귀 탐지기다.

### Exit codes

| Code | 의미 |
|------|------|
| 0 | 전부 PASS 이거나 WARN 만 있음 — 머지해도 안전 |
| 1 | FAIL 1건 이상 — 머지 안전하지 않음, Recovery Actions 참조 |
| 2 | 인자 오류(모르는 플래그, remote 없음, 잘못된 PR 번호) |
| 3 | 현재 브랜치에 PR 이 없고 PR# 인자도 없음 |

## 동작 단계

1. **Step 1 — 인자 파싱 + PR 해석.** `START_TS` 를 즉시 기록하고, PR# 이 없으면 현재 브랜치에서 자동 감지한다
   (없으면 exit 3). `git remote get-url origin` 으로 `TARGET_REPO` 를 해석한다(remote 없으면 exit 2).
2. **Step 2 — 10개 검사 실행.** C1–C5 와 C7–C10 을 병렬로, C6 만 커밋을 순회하므로 직렬로 돌린다.
   **fail-fast 없음** — 한 번에 전체 그림이 나오도록 모든 검사를 끝까지 돌린다.
3. **Step 3 — 리포트 렌더.** PR 헤더, 두 개의 표(Gating C1–C5 / Regression C6–C10), Score 줄, Verdict 줄,
   그리고 WARN·FAIL 마다 한 불릿인 Recovery Actions 로 구성한다. 앞에 군더더기 산문을 붙이지 않는다.
4. **Step 4 — 선택적 auto-fix(`--auto-fix` 일 때만).** C8 또는 C9 에 결정적 FAIL 이 있을 때만 수정하고 손댄
   파일만 `git add` 한 뒤 멈춘다. 스테이징된 파일 목록과 `/gh-commit` 힌트를 출력한다.
5. **Step 5 — AI Metrics Footer.** 푸터를 PR 본문 수정이 아니라 **코멘트**로 남긴다(다른 스킬의 단계별 메트릭
   블록과 충돌하지 않도록). `GH_DISABLE_AI_METRICS=1` 이면 이 단계를 통째로 건너뛴다.

## 주의사항

- **기본은 읽기 전용.** 머지 · 승인 · push 를 하지 않고 PR 본문/라벨도 고치지 않는다. 변경은 `--auto-fix`
  뿐이고 그마저 `git add` 까지다 — **절대 `git commit` 하지 않는다.** 커밋 메시지는 사람이 쓰도록
  `/gh:commit` 을 따로 부른다.
- **fail-fast 하지 않는다.** 10개 검사를 전부 돌려 한 번에 집계하는 것이 이 스킬의 요점이다.
- **C6 만 `--skip-bisect` 로 뺄 수 있다.** C7–C10 은 opt-out 불가 — 빼면 회귀 갭이 다시 열린다.
- **빌드 명령을 조용히 바꾸지 않는다.** `--build-cmd` 가 없고 `bun run build` 도 없으면 C6 을 사유와 함께
  `N/A` 로 표시한다.
- 메트릭 푸터 외의 코멘트를 남기지 않는다.
