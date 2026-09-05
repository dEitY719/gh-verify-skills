# gh-verify:live — Help

**실행 중인 앱에 직접 붙어 PR 이 실제로 동작하는지 확인하고, 발견한 것을 신규 이슈로
등록한다.** 머지 직후가 주 용도지만 머지 전 PR 브랜치에서도 동작한다.

유닛 테스트가 아니다 — 이 레포에서 `test` 는 bats/pytest 스위트를 뜻하고, 이 스킬은
**기동 중인 서버에 브라우저로 붙는 실물 확인**이다. GitHub 접촉은 PR 조회와 이슈 생성뿐이라
`gh:*` 가 아니라 `devx:*` 계열이다.

## Arguments

| # | Name | Default | Description |
|---|------|---------|-------------|
| 1 | PR number, or `-h`/`--help`/`help` | 자동 | 생략 시 현재 브랜치 → 실패하면 현재 커밋을 포함하는 PR 을 역추적 |
| 2 | remote name | `origin` | 대상 레포를 해석할 git remote |

두 positional 은 **첫 글자로 구분**한다 — 숫자로 시작하면 PR#(양의 정수여야 하며 아니면
exit 2), 아니면 remote 다. 그래서 `/gh-verify:live upstream` 처럼 **PR 은 자동 감지하고
remote 만 지정**하는 호출이 가능하다. 반대로 `12a` 는 숫자로 시작하므로 remote 로 조용히
넘어가지 않고 PR# 오류가 난다 — 오타를 삼키지 않기 위한 규칙이다.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--url <base-url>` | 자동 발견 | 앱 base URL. 주면 프런트 발견 단계를 건너뛴다 |
| `--api-url <origin>` | 자동 발견 | 백엔드 origin. 병렬 스택에서 엉뚱한 API 를 찌르는 것을 막는다 |
| `--start <cmd>` | 없음 | 서버 기동 명령. **기본은 기동하지 않는다** — 사용자가 이미 띄웠다고 전제한다 |
| `--matrix auto\|full` | `auto` | `auto` 는 diff 에서 축을 유도하고, `full` 은 전체 곱을 훑는다 |
| `--viewports <csv>` | 유도 | 명시하면 그 폭만. 고정 기본값 없음 — 축은 변경 유형이 정한다 |
| `--locales <csv>` | 유도 | 명시하면 그 로케일만 |
| `--dry-run` | off | 이슈 본문을 **작성해서 출력**하되 등록하지 않는다 |
| `--no-issue` | off | 초안조차 쓰지 않고 리포트 행으로만 보고한다 |
| `--no-comment` | off | 리포트를 PR 코멘트로 **게시하지 않는다**. 기본은 게시 — `[OK]`/`[WARN]` 이면 리포트 블록이 대상 PR 에 코멘트로 남는다(`[FAIL]` 은 원래 게시하지 않는다) |
| `--allow-remote-host` | off | 로컬이 아닌 호스트 대상 허용. 이 스킬은 앱 데이터에 쓰기를 한다. 로컬 판정: `localhost` · `127.0.0.0/8` · `::1` · `[::1]` · `0.0.0.0` · `[::]` |
| `-h` / `--help` / `help` | — | 이 도움말을 출력하고 정지 |

`--dry-run` 과 `--no-issue` 를 같이 주면 `--no-issue` 가 이긴다(초안조차 쓰지 않음).
`--no-comment` 는 그 둘과 **독립**이다 — 이슈 생성과 코멘트 게시는 서로를 게이트하지 않는다.
플래그는 모두 `--url X` 와 `--url=X` 두 형태를 받는다.

## Usage

- `/gh-verify:live` — 현재 커밋이 속한 PR 을 자동 역추적해 검증
- `/gh-verify:live 2483` — PR #2483 을 검증하고 발견을 대상 레포 이슈로 등록
- `/gh-verify:live 2483 --url http://127.0.0.1:5173/` — 발견 단계를 건너뛴다
- `/gh-verify:live 2483 --matrix full` — 축을 줄이지 않고 전체 곱을 훑는다
- `/gh-verify:live 2483 --locales ko,en --viewports 1440` — 축을 직접 고정
- `/gh-verify:live 2483 --dry-run` — 이슈 본문만 출력하고 등록하지 않는다
- `/gh-verify:live 2483 --no-issue` — 리포트만
- `/gh-verify:live 2483 --no-comment` — 검증은 그대로 하되 PR 에 리포트 코멘트를 남기지 않는다
- `/gh-verify:live -h` / `--help` / `help` — 이 도움말

## What the skill does

1. 인자를 파싱한다 (`devx_pr_verify_live_parse`).
2. 대상 레포와 PR 을 해석하고, LISTEN 소켓에서 base URL 과 API origin 을 **발견**한다.
   후보가 여럿이면 묻는다 — 추측하지 않는다.
3. **서빙 중인 체크아웃이 대상 커밋을 포함하는지** 확인한다. 변경된 코드를 서빙하는 모든
   프로세스에 대해 확인하고, 불일치면 정지한다.
4. 검증 항목을 뽑는다 — 연결된 이슈의 AC → PR `Test plan` 미체크 항목 → 라우트 추론 →
   질의. 각 분기에 도달할 데이터 상태와 feature flag 게이트도 함께 확인한다.
5. 드라이버 사다리를 브라우저 바이너리까지 확인해 고르고, 로그인 · 오버레이 해제 ·
   로케일 전환 레시피를 캐시에서 읽거나 발견한다. 전환이 실제로 적용됐는지 단언한다.
6. diff 가 정한 축으로 각 항목을 **기계 판독 가능한 단언**으로 확인한다 — 측정값 ·
   형제 비교 · 지시-어포던스 · 응답 가로채기 · 선행 조건 합성 · hit-test.
7. 후보 발견마다 **자기 반증 3가설**을 세워 반증하고, 게이트를 통과한 것만 발견 1건 =
   이슈 1건으로 `gh-issue:create` 에 넘긴다.
8. 돈 셀 · 미검증 · 합성 · 기각 · 생성 레코드를 모두 담은 리포트를 출력한다.
9. 결과가 `[OK]` 또는 `[WARN]` 이면 그 리포트를 대상 PR 에 코멘트로 게시한다 —
   매번 새 코멘트로 덧붙이며, `--no-comment` 로 끌 수 있다. `[FAIL]` 은 게시하지 않는다.

## What the skill will NOT do

- **코드를 고치지 않는다** — 원인이 보여도 이슈로 넘긴다. 읽기 전용 경계다.
- 사용자가 띄운 서버를 죽이지 않는다 — `--start` 로 스킬이 띄운 것만 정리한다.
- 근거 없는 발견, 자기 반증을 통과하지 못한 후보를 이슈로 만들지 않는다.
- 아무것도 안 나오면 이슈를 만들지 않는다 — 없는 문제를 지어내지 않는다.
- dotfiles 에 이슈를 만들지 않는다 — 등록 대상은 **대상 프로젝트 레포**이고, 생성 직전
  리포트에 그 레포를 출력한다.
- 로컬이 아닌 호스트에 `--allow-remote-host` 없이 붙지 않는다 — 앱 데이터에 쓰기를 한다.
- 자격증명을 로그 · 이슈 본문 · 레시피 캐시에 남기지 않는다.
- 커밋하거나 push 하지 않는다.

## Exit codes

| Code | Cause |
|------|-------|
| 0 | 검증이 끝났다 — 발견이 0건이든 N건이든, degraded 모드였든 포함 |
| 1 | 검증 전 단언 실패(서빙 체크아웃 불일치 · 전환 no-op · 대상 가려짐), 서버 미발견, `gh` 미인증, 로컬 아닌 호스트에 `--allow-remote-host` 없음 |
| 2 | 인자 오류: 숫자로 시작하는데 양의 정수가 아닌 PR#, http(s) 아닌 `--url`/`--api-url`, `auto\|full` 아닌 `--matrix`, 잘못된 CSV, **명시했는데 값이 빈 플래그**(`--url=` 등), 모르는 플래그(`-x` 포함), 남는 positional |

## Good vs. bad invocation

- **Good**: `/gh-verify:live 2483` — 머지 직후, 서버는 이미 떠 있는 상태.
- **Good**: `/gh-verify:live 2483 --api-url http://127.0.0.1:8000` — 같은 호스트에
  병렬 스택이 여럿일 때 대상을 못 박는다.
- **Bad**: `/gh-verify:live 2483` 를 서버가 다른 워크트리를 서빙 중인 상태로 —
  스킬이 정지시킨다. 그 디렉터리에서 rebase 후 재기동하는 것이 맞다.
- **Good**: `/gh-verify:live upstream` — PR 은 자동 감지, remote 만 `upstream` 으로.
- **Bad**: `/gh-verify:live 12a` — exit 2 (숫자로 시작하면 PR# 이고, 양의 정수여야 한다).
- **Bad**: `/gh-verify:live 2483 --url=` — exit 2. 명시한 override 를 조용히 무시하지 않는다.
- **Bad**: staging URL 을 `--url` 로 주는 것 — 이 스킬은 앱 데이터에 쓰기를 하므로
  dev/fake 스택 전용이다.

## 관련 스킬

| 스킬 | 관계 |
|---|---|
| `gh-verify:merged` | **sister skill**. 같은 머지 후 슬롯, 다른 증명 대상(신선한 클론 동일성) — 띄울 앱이 없는 레포(shell · CLI · lib)용. 공통 계약은 `references/verify-contract.md` |
| `gh-issue:create` | 발견 1건마다 호출. 본문 골격 · 라벨 · ai-metrics 의 SSOT |
| `gh-verify:review-all` | 머지 **전** 정적 리뷰 게이트. 이쪽은 머지 **후** 실물 검증 |
| `gh-flow:issue` | 이슈 → PR 을 잇는 상위 흐름. 이 스킬은 그 뒤에 사람이 부른다 |
