# merged 사용 결과

> **한 줄 요약** — 머지된 PR 번호를 받아 그 머지 커밋의 신선한 클론에서 재검증한 판정 리포트를 생성합니다.

```
머지된 PR (#1670)  ──▶  /gh-verify:merged  ──▶  [OK]/[WARN]/[FAIL] 리포트
```

## 1. 실행한 명령

```
/gh-verify:merged <PR#> [remote] [--matrix full] [--no-diff-check] [--no-issue] [--no-comment]
```

이번 실행 — `/gh-verify:merged 1670` (대상 `dEitY719/dotfiles`, 이슈 생성·PR 코멘트 없이 read-only).

## 2. 입력

- PR `dEitY719/dotfiles#1670` — MERGED 2026-09-01T07:46:06Z, 8개 파일 +908 -42
- 머지 커밋 `8e223e5207f316a2874d7581183a07841886bb03`, 연결 이슈 `Closes #1652`

## 3. 결과

```
[WARN] gh-verify:merged — dEitY719/dotfiles#1670
Clone:      8e223e52 체크아웃, HEAD 일치, git status 비어 있음 (F-2/F-3 통과)
Claims:     클론 안 bats 3파일 — setup_skills_ssot 35 ok/1 not ok (36)
            claude_compose_workspace_skills 13/0 (13), claude_compose_skills_dir 5/0 (5)
Matrix:     PATH=/usr/bin:/bin 재실행 결과 동일 — 축 분기 없음
Unproven:   check_codex_skills_budget 는 PR 이전(09d54351)에서도 동일 실패.
            같은 파일이 20건 -> 36건, PR 이 +16 케이스 추가(주장 일치)
Unverified: Test plan 미체크 1건 — 워크스페이스 repo 가 없는 PC 에서의 ./setup.sh 실기 확인
Rejected:   3 — (1) 신선한 클론에 bats 러너 부재: setup.sh 가 submodule 초기화(의도된 동작)
            (2) 본문 "11 케이스" vs 실측 13: 리뷰 수정 2건이 추가된 뒤 본문 미갱신
            (3) check_codex_skills_budget: PR 과 무관한 기존 결함, 본문에 이미 공개됨
Findings:   0 (신규 이슈 없음)
Next:       미체크 Test plan 항목은 워크스페이스가 빈 PC 에서 별도 확인 필요
```

차등 검증 좌표는 3-커밋 rebase 이므로 `8e223e52~3` = `09d54351` 이다.
