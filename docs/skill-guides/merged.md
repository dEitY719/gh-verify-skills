# gh-verify:merged

> 한 줄 요약 — 머지 커밋의 신선한 클론 안에서만 PR 의 주장을 다시 돌려, 깨끗한 체크아웃이 주장대로 동작함을 증명하고 살아남은 발견만 신규 이슈로 남긴다.

## 언제 쓰는가

- **띄울 앱이 없는 레포**(shell 스크립트 · CLI · 라이브러리)에서 머지된 PR 을 재검증할 때. 머지 후 점검이
  더러운 worktree 에서 돌아 untracked-artifact 버그를 숨기는 곳이 대상이다.
- 막으려는 실패 클래스는 하나다 — **작업 worktree 에서는 초록인데 다른 모든 클론과 CI 에서는 그 검사가
  존재하지도 않는 상태**.
- 자매 스킬 `gh-verify:live` 와의 경계는 **무엇을 증명하느냐**로 갈린다 —
  **merged = 신선한 클론 신원**(누가 새로 clone 해도 그렇게 동작하는가),
  **live = 서빙 체크아웃 신원**(지금 서빙 중인 프로세스가 대상 커밋을 담고 있는가).
- 이미 떠 있는 앱에 붙어 화면을 확인해야 한다면 `gh-verify:live` 다. 둘은 배타적이지 않다 — 프론트엔드 PR 도
  merged 로 유닛/빌드 재현성을, live 로 화면을 볼 수 있다.
- 머지 **전** 정적 리뷰 게이트는 `gh-verify:review-all` 이다.

## 언제 쓰지 않는가

- **미머지 PR** — `state != MERGED` 면 escape hatch 없이 정지한다(`--allow-unmerged` 같은 플래그는 없다).
  머지 커밋이 없으면 "신선한 클론이 무엇을 담아야 하는지" 자체가 정의되지 않는다. 미머지 PR 브랜치 검증은
  `gh-verify:live` 다.
- **앱을 띄워 화면을 봐야 하는 검증** — 이 스킬은 앱을 띄우지 않는다.
- **코드 수정 목적** — 원인이 보여도 고치지 않는다. 읽기 전용 경계다.
- **작업 worktree 에서 테스트를 돌려 "검증했다"고 하는 것** — 이 스킬이 막으려는 실패 그 자체다.

## 호출

```
/gh-verify:merged [pr-number] [remote] [flags]
```

두 positional 은 **첫 글자로 구분**한다 — 숫자로 시작하면 PR#(양의 정수여야 하며 아니면 exit 2), 아니면
remote 다. `/gh-verify:merged upstream` 처럼 PR 자동 감지 + remote 지정이 가능하다.

| # | 이름 | 기본값 | 설명 |
|---|------|--------|------|
| 1 | PR number, 또는 `-h`/`--help`/`help` | 자동 | 생략 시 현재 브랜치 → 실패하면 현재 커밋을 포함하는 PR 을 역추적 |
| 2 | remote name | `origin` | 대상 레포를 해석할 git remote |

### Flags

| Flag | 기본값 | 설명 |
|------|--------|------|
| `--matrix auto\|full` | `auto` | `auto` 는 PATH 정규화 축만 돌고 나머지는 후보로만 보고, `full` 은 유도된 축을 전부 실행 |
| `--env <csv>` | 없음 | 돌릴 환경 축을 직접 고정 (`path,locale,shell,eol`). `--matrix` 보다 우선 |
| `--clone-dir <path>` | `mktemp -d` | 임시 클론 위치 고정. 지정하면 자동 정리하지 않는다 |
| `--no-diff-check` | off | 차등 검증(F-7)을 끈다. 끈 사실이 리포트 `Unproven:` 행에 남는다 |
| `--dry-run` | off | 이슈 본문을 작성해서 출력하되 등록하지 않는다 |
| `--no-issue` | off | 초안조차 쓰지 않고 리포트 행으로만 보고한다 |
| `--no-comment` | off | 리포트를 PR 코멘트로 게시하지 않는다 (기본은 게시) |
| `-h` / `--help` / `help` | — | 도움말 출력 후 정지 |

`--dry-run` 과 `--no-issue` 를 같이 주면 `--no-issue` 가 이긴다. `--no-comment` 는 그 둘과 독립이다.
플래그는 모두 `--env X` 와 `--env=X` 두 형태를 받는다.

### Exit codes

| Code | 원인 |
|------|------|
| 0 | 검증이 끝났다 — 발견이 0건이든 N건이든, 일부 축이 `unverified` 였든 포함 |
| 1 | 검증 전 단언 실패(머지 안 됨 · `mergeCommit.oid` null · 클론 실패 · HEAD 불일치 · 더러운 클론), `gh` 미인증 |
| 2 | 인자 오류: 숫자로 시작하는데 양의 정수가 아닌 PR#, `auto\|full` 아닌 `--matrix`, 알 수 없는 `--env` 축, 값이 빈 플래그, 모르는 플래그, 남는 positional |

## 동작 단계

1. **Step 1 — 인자 파싱.** `pr` `remote` `matrix` `env_axes` `clone_dir` `diff_check` `issue_mode`
   `post_comment` 를 캡처한다.
2. **Step 2 — 대상 해석.** `gh pr view` 로 `state` `mergedAt` `mergeCommit` `baseRefName` `body` `files`
   `closingIssuesReferences` 를 **1회만** fetch 해 재사용하고, `state != MERGED` 이거나
   `.mergeCommit.oid == null` 이면 정지한다.
3. **Step 3 — 검증 전 단언: 신선한 클론과 그 무결성.** `mergeCommit.oid` 를 체크아웃한 클론을 임시 디렉터리에
   만들고(`headRefOid` 금지), 이후 모든 실행은 그 클론 안에서만 한다. 클론 실패 · HEAD 불일치 ·
   `git status --porcelain` 이 비어 있지 않음은 측정하지 않고 정지다. 이어서 클론과 작업 트리에서 실제로
   실행되는 테스트 케이스의 이름·개수를 비교해 한쪽에만 있는 케이스를 발견으로 올린다.
4. **Step 4 — 주장 목록과 검증 명령.** 연결 이슈의 AC → PR `Test plan` 미체크 항목 → 커밋 메시지의 `검증:`
   줄 → 질의 순으로 주장을 모으고, 프로젝트 자체 검증 명령을 사다리(`AGENTS.md`/`CLAUDE.md`/`README` →
   `tox.ini` → `pyproject.toml` → `package.json` `test` → `tests/*.bats` → `.claude/scripts/test-*.sh`)로
   찾는다. 미탐지는 `Unverified:` 한 줄.
5. **Step 5 — 환경 변이 하 재실행.** 기본 축은 PATH 정규화 1개 — 같은 검증을 `PATH=/usr/bin:/bin` 으로 다시
   돌려 사용자 셸의 도구 치환을 배제한다. 결과가 갈리면 그 자체가 발견이다. locale·셸·줄 끝 축은
   `--matrix full`·`--env` 일 때만 실행한다.
6. **Step 6 — 차등 검증.** 주장 1건마다 PR **이전 상태**로 같은 입력을 돌린다. 전·후 결과가 같으면 `unproven`
   — 둘 다 통과하는 검사는 아무것도 증명하지 않는다. 기본 on 이고 `--no-diff-check` 로만 끈다.
7. **Step 7 — 자기 반증 후 이슈화.** 후보마다 반증 가설 4종(하네스 오류 · 환경 특수성 · 의도된 동작 · PR 과
   무관한 기존 결함)을 세워 반증하고, 살아남은 것만 발견 1건 = 이슈 1건으로 `gh:issue-create` 에 넘긴다.
8. **Step 8 — 리포트와 PR 코멘트 게시.** `Clone:` `Claims:` `Matrix:` `Unproven:` `Unverified:` `Rejected:`
   `Findings:` 를 모두 담고 마지막 줄은 항상 `Next:` 다. `[OK]`/`[WARN]` 이고 `post_comment=1` 일 때만 그
   블록을 대상 PR 코멘트로 남기며, `[FAIL]` 은 `--no-comment` 와 무관하게 게시하지 않는다.

## 주의사항

- **검증 전 단언(F-2/F-3) 중 하나라도 실패하면 측정하지 않고 정지한다.** 환경 축 1개 실패는 정지가 아니라 그
  축만 `unverified` 다. 측정하지 않은 통과를 보고하지 않는다.
- **검증은 임시 클론 안에서만** — 사용자의 작업 트리·인덱스·스태시를 읽지도 쓰지도 않는다(F-3 비교용
  읽기 전용 참조만 예외이며, 그 참조조차 파일을 쓰지 않는다).
- **소스는 읽기 전용 — 코드를 고치지 않는다.** 발견은 `gh:issue-create` 로 신규 이슈로만 나가고, 커밋도
  push 도 하지 않는다.
- 클론은 종료 시 정리하되 `[FAIL]` 이면 남기고 경로를 출력한다. `Bash(rm:*)` 같은 deny 규칙에 막히면
  **경로를 출력하고 사용자에게 맡긴다 — 우회 금지.**
- 자기 반증을 통과하지 못한 후보는 이슈로 만들지 않고, 아무것도 안 나오면 이슈를 만들지 않는다.
- 이슈는 dotfiles 가 아니라 **대상 프로젝트 레포**에 만들고, 생성 직전 그 레포를 출력한다.
