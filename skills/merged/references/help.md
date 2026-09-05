# gh-verify:merged — Help

**머지된 PR 을 그 머지 커밋의 신선한 클론에서 다시 검증하고, 발견한 것을 신규 이슈로
등록한다.** 증명 대상은 **소스 동일성** — "내 작업 트리에서 초록" 이 아니라 "누가 새로 clone
해도 그렇게 동작한다" 를 보인다.

앱을 띄우지 않는다. 띄울 앱이 있는 PR 은 `gh-verify:live` 가 맡는다(둘은 배타적이지
않다 — 프론트엔드 PR 도 merged 로 유닛/빌드 재현성을, live 로 화면을 볼 수 있다).

## Arguments

| # | Name | Default | Description |
|---|------|---------|-------------|
| 1 | PR number, or `-h`/`--help`/`help` | 자동 | 생략 시 현재 브랜치 → 실패하면 현재 커밋을 포함하는 PR 을 역추적 |
| 2 | remote name | `origin` | 대상 레포를 해석할 git remote |

두 positional 은 **첫 글자로 구분**한다 — 숫자로 시작하면 PR#(양의 정수여야 하며 아니면
exit 2), 아니면 remote 다. 그래서 `/gh-verify:merged upstream` 처럼 **PR 은 자동 감지하고
remote 만 지정**하는 호출이 가능하다. `12a` 는 숫자로 시작하므로 remote 로 조용히 넘어가지
않고 PR# 오류가 난다 — 오타를 삼키지 않기 위한 규칙이다.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--matrix auto\|full` | `auto` | `auto` 는 PATH 정규화 축만 돌고 나머지는 후보로만 보고, `full` 은 유도된 축을 전부 실행 |
| `--env <csv>` | 없음 | 돌릴 환경 축을 직접 고정 (`path,locale,shell,eol`). `--matrix` 보다 우선 |
| `--clone-dir <path>` | `mktemp -d` | 임시 클론 위치를 고정한다. 지정하면 자동 정리하지 않는다 |
| `--no-diff-check` | off | 차등 검증(F-7)을 끈다. 끈 사실이 리포트 `Unproven:` 행에 남는다 |
| `--dry-run` | off | 이슈 본문을 **작성해서 출력**하되 등록하지 않는다 |
| `--no-issue` | off | 초안조차 쓰지 않고 리포트 행으로만 보고한다 |
| `--no-comment` | off | 리포트를 PR 코멘트로 **게시하지 않는다**. 기본은 게시 — `[OK]`/`[WARN]` 만 게시되고 `[FAIL]` 은 원래 게시하지 않는다 |
| `-h` / `--help` / `help` | — | 이 도움말을 출력하고 정지 |

`--dry-run` 과 `--no-issue` 를 같이 주면 `--no-issue` 가 이긴다(초안조차 쓰지 않음).
`--no-comment` 는 그 둘과 **독립**이다 — 이슈 생성과 코멘트 게시는 서로를 게이트하지 않는다.
플래그는 모두 `--env X` 와 `--env=X` 두 형태를 받는다.

**미머지 PR 은 대상이 아니다.** `state != MERGED` 면 escape hatch 없이 정지한다 — 머지 커밋이
없으면 "신선한 클론이 무엇을 담아야 하는지" 자체가 정의되지 않기 때문이다. 미머지 PR 브랜치
검증이 필요하면 `gh-verify:live` 를 쓴다.

## Usage

- `/gh-verify:merged` — 현재 커밋이 속한 머지된 PR 을 자동 역추적해 검증
- `/gh-verify:merged 16` — PR #16 을 신선한 클론에서 검증하고 발견을 대상 레포 이슈로 등록
- `/gh-verify:merged 16 --matrix full` — 유도된 환경 축을 전부 실행
- `/gh-verify:merged 16 --env path,eol` — PATH 정규화와 줄 끝 축만 실행
- `/gh-verify:merged 16 --clone-dir ~/tmp/verify-16` — 클론 위치 고정(정리는 사용자 몫)
- `/gh-verify:merged 16 --no-diff-check` — 차등 검증을 끄고 클론 재현성만 본다
- `/gh-verify:merged 16 --dry-run` — 이슈 본문만 출력하고 등록하지 않는다
- `/gh-verify:merged 16 --no-issue --no-comment` — 로컬 리포트만
- `/gh-verify:merged upstream` — PR 은 자동 감지, remote 만 `upstream` 으로
- `/gh-verify:merged -h` / `--help` / `help` — 이 도움말

## What the skill does

1. 인자를 파싱한다.
2. 대상 레포와 PR 을 해석하고 `state` `mergedAt` `mergeCommit.oid` `baseRefName` 를 1회
   fetch 한다. 머지된 PR 이 아니면 정지.
3. **머지 커밋을 체크아웃한 신선한 클론**을 만들고 HEAD 가 그 SHA 인지 확인한다. 이후 모든
   실행은 그 클론 안에서만 일어난다.
4. 클론 무결성을 단언한다 — `git status --porcelain` 이 비어 있는가, 그리고 **작업 트리에서만
   실행되는 테스트 케이스가 있는가**(untracked/ignored 생성물 의존 검출).
5. 주장 목록을 뽑는다 — 연결된 이슈의 AC → PR `Test plan` 미체크 항목 → 커밋 `검증:` 줄 → 질의.
6. 프로젝트 자체 검증 명령을 사다리로 찾아 클론에서 실행한다.
7. **환경을 바꿔 다시 돌린다** — 기본은 `PATH=/usr/bin:/bin` 정규화. 결과가 갈리면 발견이다.
8. **차등 검증** — 같은 검사를 PR 이전 상태로 돌려 결과가 실제로 달라지는지 본다.
9. 후보 발견마다 자기 반증을 세워 걸러내고, 살아남은 것만 `gh-issue:create` 로 넘긴다.
10. `Clone:` `Claims:` `Matrix:` `Unproven:` `Unverified:` `Rejected:` `Findings:` 를 담은
    리포트를 출력하고, `[OK]`/`[WARN]` 이면 대상 PR 에 코멘트로 남긴다.

## What the skill will NOT do

- **코드를 고치지 않는다** — 원인이 보여도 이슈로 넘긴다. 읽기 전용 경계다.
- **사용자의 작업 트리·인덱스·스태시를 건드리지 않는다** — F-3 비교를 위한 읽기 전용 참조만
  예외이고, 그 참조조차 파일을 쓰지 않는다.
- 미머지 PR 을 검증하지 않는다 (`--allow-unmerged` 같은 플래그는 없다).
- 근거 없는 발견, 자기 반증을 통과하지 못한 후보를 이슈로 만들지 않는다.
- 아무것도 안 나오면 이슈를 만들지 않는다 — 없는 문제를 지어내지 않는다.
- dotfiles 에 이슈를 만들지 않는다 — 등록 대상은 **대상 프로젝트 레포**이고, 생성 직전
  리포트에 그 레포를 출력한다.
- 프로젝트의 `Bash(rm:*)` 같은 deny 규칙을 우회하지 않는다 — 막히면 클론 경로를 출력하고
  사용자에게 맡긴다.
- 커밋하거나 push 하지 않는다.

## Exit codes

| Code | Cause |
|------|-------|
| 0 | 검증이 끝났다 — 발견이 0건이든 N건이든, 일부 축이 `unverified` 였든 포함 |
| 1 | 검증 전 단언 실패(머지 안 됨 · `mergeCommit.oid` null · 클론 실패 · HEAD 불일치 · 더러운 클론), `gh` 미인증 |
| 2 | 인자 오류: 숫자로 시작하는데 양의 정수가 아닌 PR#, `auto\|full` 아닌 `--matrix`, 알 수 없는 `--env` 축, **명시했는데 값이 빈 플래그**(`--env=` 등), 모르는 플래그(`-x` 포함), 남는 positional |

## Good vs. bad invocation

- **Good**: `/gh-verify:merged 16` — 머지 직후, shell/CLI/라이브러리 레포에서.
- **Good**: `/gh-verify:merged 16 --matrix full` — 줄 끝·로케일이 걸린 PR 이라 축을 다 돈다.
- **Bad**: 작업 worktree 에서 테스트를 직접 돌려 "검증했다" 라고 하는 것 — 이 스킬이 막으려는
  실패 그 자체다(untracked 픽스처가 있으면 클론에서는 그 케이스가 아예 실행되지 않는다).
- **Bad**: `/gh-verify:merged 16 --env=` — exit 2. 명시한 override 를 조용히 무시하지 않는다.
- **Bad**: 미머지 PR 에 이 스킬을 부르는 것 — 정지한다. `gh-verify:live` 를 쓴다.

## 관련 스킬

| 스킬 | 관계 |
|---|---|
| `gh-verify:live` | **sister skill**. 같은 머지 후 슬롯, 다른 증명 대상(서빙 체크아웃 동일성). 공통 계약은 `../live/references/verify-contract.md` 한 파일 |
| `gh-issue:create` | 발견 1건마다 호출. 본문 골격 · 라벨 · ai-metrics 의 SSOT |
| `gh-issue:implement` | 테스트 러너 탐지 사다리의 출처. 여기서 그대로 재사용한다 |
| `gh-verify:review-all` | 머지 **전** 정적 리뷰 게이트. 이쪽은 머지 **후** 재현성 검증 |
