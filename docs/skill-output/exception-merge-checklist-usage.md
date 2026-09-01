# exception-merge-checklist 사용 결과

> **한 줄 요약** — PR 번호를 받아 10항목 읽기 전용 점검표와 판정 리포트를 생성합니다.

```
PR 번호 (#1670)  ──▶  /gh-verify:exception-merge-checklist  ──▶  10항목 점검 리포트
```

## 1. 실행한 명령

```
/gh-verify:exception-merge-checklist [<PR#>] [--skip-bisect] [--auto-fix] [--build-cmd <cmd>]
```

이번 실행 — `/gh-verify:exception-merge-checklist 1670` (`--auto-fix` 없이 순수 읽기 전용).

## 2. 입력

- PR `dEitY719/dotfiles#1670` (8개 파일 +908 -42). 머지 **직전** 감사용 스킬이지만
  이번에는 이미 머지된 PR 에 돌렸고, 그 여파가 아래 C1/C3 에 그대로 나타났다.

## 3. 결과

```
PR #1670 — dEitY719/dotfiles
Gating      C1  FAIL  Closes #1652 있으나 이슈 CLOSED (이 머지가 닫음)
            C2  N/A   C1 FAIL 이라 평가 안 함
            C3  WARN  mergeable = UNKNOWN (이미 머지됨)
            C4  PASS  statusCheckRollup 3건 전부 SUCCESS
            C5  WARN  reviewDecision 빈 값 + main 브랜치 보호 없음 (solo-repo 경로)
Regression  C6  N/A   루트에 package.json 없어 `bun run build` 부재 — 명령을 바꾸지 않음
            C7  N/A   openapi.yaml 없음        C8  N/A  .openapi-lock 없음
            C9  FAIL  prettier --check 위반: claude/AGENTS.md
            C10 N/A   apps/ 트리 없음, 신규 프레임워크 호출 0건
Score:      PASS 1 / WARN 2 / FAIL 2 / N/A 5
Verdict:    FAIL (FAIL 1건 이상 — 종료 코드 1)
```

C9 는 실측 위반이지만 dotfiles 의 문서 포매터는 prettier 가 아니라 `mise run lint-docs` 라,
이 repo 에 한해서는 오탐으로 읽어야 한다. 읽기 전용 실행이므로 `git add` 도 하지 않았다.
