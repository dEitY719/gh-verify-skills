# 발견 → 이슈 (findings)

SKILL.md 의 **발견 처리 단계**를 뒷받침한다 — 후보를 스스로 반증하고, 게이트를 통과한 것만
`gh:issue-create` 에 넘긴다. 이 스킬은 **게이트만** 책임진다.

## 0. 발견 1건의 처리 순서

```
후보 발견
  -> 1. 자기 반증 3가설            실패 -> rejected: <이유>  (리포트 행, 이슈 없음)
  -> 2. 게이트 5개                 실패 -> [SKIP] 또는 rejected  (리포트 행)
  -> 3. 회귀/기존 결함 판정 + 반증된 근거 정정 포함 여부 결정
  -> 4. 대상 레포 해석 후 출력
  -> 5. Skill(gh:issue-create, "--assignee @me") 호출  -> safe 라벨 -> 보드 카드 동기화
```

순서가 중요하다 — 반증이 게이트보다 **먼저**다. 게이트 4개를 전부 통과한 위양성 4건이
실측으로 나왔기 때문이다(1절).

---

## 1. 자기 반증 (self-refutation) — 게이트 **앞에** 필수

후보 발견 **1건마다** 이슈로 올리기 전에 3개 가설을 명시적으로 세우고 반증한다.

| # | 가설 | 반증 방법 |
|---|---|---|
| 1 | **하네스 오류** — 내가 잡은 셀렉터가 의도한 그 요소가 맞나? | `aria-label` · 부모 다이얼로그 제목 · 태그명을 함께 덤프해 확인 |
| 2 | **데이터 상태** — 시드/현재 상태 때문에 그렇게 보이는 건 아닌가? | 같은 검증을 **다른 픽스처**로 1회 더 |
| 3 | **의도된 동작** — 코드에 그 분기가 명시돼 있지 않나? | 관련 소스 1곳 인용 |

셋 중 하나라도 반증되지 않으면 **이슈로 올리지 않고** 리포트에 `rejected: <이유>` 로 남긴다.

**근거 — 한 런에서 FAIL 로 뜬 4건이 전부 위양성이었고, 원 §8 게이트 4개를 전부 통과했다.**
자동화했으면 그날 이슈 4건을 오등록했다.

| 위양성 | 실제 원인 | 원 게이트 |
|---|---|---|
| "피커 검색창 시드가 빈 문자열" | 스크립트가 `아바타 카드 수정` 다이얼로그를 열어 **다른 입력칸**("역할 검색")을 읽음 | 통과 (재현됨·값 있음) |
| "한글 스킬 자동 스테이징 안 됨" | 그 스킬이 그 업무에 **이미 연결**돼 정상 제외 | 통과 |
| "번들 컴포넌트 4개 중 2개만 노출" | 나머지 2개가 **이미 연결**됨 | 통과 |
| "배너가 안 뜸" | CTA 가 `<button>` 이 아니라 `<a>` 라 **클릭 자체를 못 함** | 통과 |

공통점: **전부 "지루한 설명"(harness 버그 / 데이터 상태 / 의도된 필터)이 진짜 원인**이었다.
인상 비평 필터로는 **하나도** 못 거른다. 3건이 정확히 가설 2("다른 픽스처로 1회 더")에서 걷혔다.

**비용은 실행 1회, 이득은 오등록 3건 방지.**

---

## 2. 게이트 (전부 통과해야 등록)

- **재현 절차가 명확하다.**
- **제3자가 재현·반증할 수 있는 근거가 있다** — 형태는 `assertions.md` (b) 표가 정한다.
  절차 없는 인상 비평은 등록하지 않는다.
  원 문구 "수치 근거가 있다" 는 **폐기**한다 — 실측으로 그 문구가 더 심각한 버그 2건
  (#2495 조사 고정 · #2497 빈 `label_en`)을 차단했다.
- **대상 레포의 열린 이슈와 중복이 아니다** — `gh issue list --search`.
- **없는 게 아니라 꺼진 것은 아닌지 배제한다** — 피처 플래그 · 권한 · 역할 · 공개범위 게이트가
  현재 환경에서 열려 있는지 **먼저** 확인한다. 닫혀 있으면 결함이 아니라 **미검증**이며,
  이슈가 아니라 리포트의 `[SKIP]` 으로 남긴다.
  실측: `[내 아바타에 사용하기]` CTA 가 조직 전역 플래그 `avatar.use_in_my_avatar`
  (서버 기본값 **꺼짐**) 뒤에 있었고, `GET /api/v1/feature-flags` 를 찍고서야 이 스택에선
  켜져 있음을 확인했다. 게이트 중 가장 값싼 것에 비해 방지 효과가 가장 크다.
- **자기 반증 3가설을 통과했다** (1절).

---

## 3. 회귀 / 기존 결함 구분

이번 PR 이 만든 것인지 원래 있던 것인지 **본문에 명시**하고,
**회귀는 대상 PR 을 역참조하고 우선순위 라벨을 다르게 가져간다.**

| 이슈 | 성격 |
|---|---|
| #2490 | 대상 PR 이 만든 **회귀** |
| #2491 | **#2457 부터 있던 기존 결함** (대상 PR 은 관례를 따랐을 뿐) |
| #2496 | 대상 PR 이 만든 것 |
| #2495 | #2457 부터 있던 것에 대상 PR 이 한 줄 더 얹은 것 |

구분이 없으면 두 건이 **한 이슈로 뭉쳐 우선순위가 뭉개진다.** 본문 구분만으로는 부족하다.

---

## 4. 반증된 근거 정정

검증 결과가 **PR 본문 · 커밋 메시지 · 코드 주석**에 적힌 근거와 어긋나면,
이슈 본문에 **"무엇이 왜 틀렸는지"** 를 명시하고 **그 주석·문구 정정도 수정안에 포함**한다.

실측 — #2490 은 단순 스타일 버그가 아니었다. 작성자가 rebase 도중
"`bg-tone-warn/10` 은 `globals.css` 의 손수 정의 목록에 없으니 규칙이 생성되지 않는다" 고
판단해 톤을 바꾸고, **그 틀린 근거를 커밋 메시지와 소스 주석에 그대로 남겼다.**
라이브 측정으로 반증됐다 — `@theme` 에 `--color-tone-warn` 이 등록돼 있어
임의 불투명도 변형이 정상 생성된다.

이슈만 등록하고 끝내면 **틀린 근거가 머지된 커밋 메시지와 코드 주석에 남아
다음 사람을 똑같이 오도한다. 결함 자체보다 잘못된 근거가 더 오래 남는다.**
#2490 의 `## 참고 — 오해의 출처` 절이 그 형식이다.

---

## 5. 등록은 `gh:issue-create` 에 위임한다

발견 1건마다 `Skill(gh:issue-create, "--assignee @me")` 를 호출한다.
본문 골격 · 라벨 SSOT 판정 · ai-metrics 푸터는 **그 스킬이 SSOT** 다.

**여기서 템플릿을 재기술하지 않는다** — 재기술하면 그쪽이 바뀔 때 두 곳이 어긋난다.
원 §8 의 "TL;DR / 증상 / 재현 / 근본 원인 / …" 나열은 `gh:issue-create` 의
`references/templates/fix.md` 를 옮겨 적은 것이었다.

---

## 6. 위임해도 남는 레포측 기계적 함정

| # | 함정 | 대응 |
|---|---|---|
| 1 | **없는 라벨** | 만들지 않고 조용히 건너뛴다. `gh label list` 로 사전 검증. 실측: `refactor`·`test` 가 대상 레포에 없어 `enhancement` 로 낙착 |
| 2 | **classic Projects 레포에서 `gh {issue,pr} edit --add-label` 이 exit 1** | `_gh_pr_edit_safe_label` (REST 폴백, `shell-common/functions/gh_pr_edit_safe.sh`) 경유 |
| 3 | **보드 카드는 별도** | `_gh_project_status_sync issue <N> "Backlog" --repo "$TARGET_REPO"` (`shell-common/functions/gh_project_status.sh`) |

2번 실측: 5회 재시도가 전부 같은 GraphQL 경고
(`Projects (classic) is being deprecated … repository.pullRequest.projectCards`)로 실패했고,
safe 래퍼로 갈아탄 뒤에야 라벨이 붙었다.
3번을 부르지 않으면 **이슈만 생기고 카드가 없다.**

2·3번 헬퍼는 **레포 표준 폴백 블록(#644 NF-1 + #724)으로 감싸 부른다** — 맨 호출로 쓰면
헬퍼가 없는 환경(agent-toolbox 등 크로스 프로젝트 복사본)에서 `command not found` 로
스킬이 통째로 죽는다. `tests/bats/skills/helper_fallback_nf1.bats` 가 이 계약을 지킨다.

```bash
_HELPER="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/gh_project_status.sh"
[ -f "$_HELPER" ] || _HELPER="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common/functions/gh_project_status.sh"
if [ -r "$_HELPER" ]; then
    . "$_HELPER"
    if ! command -v _gh_project_status_sync >/dev/null 2>&1; then
        printf '[pr-verify-live] %s sourced but _gh_project_status_sync undefined (#724).\n' \
            "$_HELPER" >&2
    else
        _gh_project_status_sync issue "$N" "Backlog" --repo "$TARGET_REPO" || true
    fi
fi
```

`--repo "$TARGET_REPO"` 가 load-bearing 이다 (#1405) — 빼먹으면 헬퍼가 `gh repo view`
(= `gh repo set-default` 가 고른 레포, 보통 dotfiles) 보드로 카드를 보낸다. 이 스킬은
`origin` 이 아닐 수도 있는 대상 레포를 일부러 해소해 놓고 쓰므로 특히 위험하다.
(종전의 `GH_REPO="$TARGET_REPO"` 프리픽스 형태도 여전히 동작한다 — 헬퍼가 `GH_REPO` 를
`--repo` 다음 순위로 존중한다. 의도를 코드에 남기려고 명시 플래그로 바꿨다.)

`_gh_pr_edit_safe_label` 도 같은 모양으로
(`gh_pr_edit_safe.sh` / `command -v _gh_pr_edit_safe_label`) 감싼다.

---

## 7. 대상 레포 오등록 가드

스킬은 dotfiles 에 살고 실행은 **프로젝트 워크트리**에서 된다 — 정확히 사고가 나는 구도다.

`TARGET_REPO` 는 Step 2 에서 이미 확정돼 있다 — `discovery.md` §3 의 소스 블록을 쓴다
(`DOTFILES_FORCE_INIT=1` 없이 `gh_pr_review.sh` 를 source 하면 인터랙티브 가드에 막혀
헬퍼가 정의되지 않는다). 여기서 다시 해소하지 않는다.

**생성 직전 리포트에 대상 레포를 출력**한 뒤 만든다.
이슈는 **대상 프로젝트 레포**에 등록한다 — **dotfiles 가 아니다.**

---

## 8. 규칙

- 발견 1건 = 이슈 1건. **묶지 않는다.**
- 아무것도 안 나오면 이슈를 만들지 않고 "검증 통과" 로 끝낸다 —
  **없는 문제를 지어내지 않는다.**
- 다만 리포트에 `Rejected: N (self-refuted)` 를 적어
  **"0 findings" 가 "안 찾아봤음" 과 구별되게** 한다.

| 플래그 | 동작 |
|---|---|
| (없음) | 게이트 통과분을 `gh:issue-create` 로 등록 |
| `--dry-run` | 본문 **초안을 작성해 출력**하되 등록하지 않음 |
| `--no-issue` | **초안조차 쓰지 않고** 리포트 행으로만 보고 |
| 둘 다 | `--no-issue` 승리 |

리포트에 남는 형태:

```
  Findings:  https://github.com/<owner>/<repo>/issues/2490 (regression, PR #2473)
             https://github.com/<owner>/<repo>/issues/2491 (pre-existing, since #2457)
  Rejected:  3 (self-refuted: harness x1 / fixture x2)
  Skipped:   1 (feature flag off) · 1 (실데이터로 도달 불가 — 합성으로 검증)
  Repo:      <owner>/<repo>   (resolved from remote 'origin')
```
