# 리포트 양식

SKILL.md Step 8 을 뒷받침한다. 리포트의 설계 목표는 하나다 — **실제로 한 것보다 강해
보이지 않게 하는 것.** 통과 항목만 나열하면 도달 불가 항목·축소한 커버리지·스텁으로 만든
분기가 조용히 사라지고, 독자는 전수 검증한 것으로 읽는다.

## 성공 (`[OK]`)

```
[OK] PR #<N> live-verified — <M>/<T> checks passed, <K> findings filed
  Repo:       <owner/name>            (target repo for any new issue)
  Serving:    <path> @ <sha>          (checkout verified · dirty: <n> files)
  URL:        <base-url>
  API:        <api-origin>
  Driver:     playwright-mcp | playwright-python | playwright-node | degraded(curl)
  Matrix:     locales=ko,en x width=1440   (1/12 cells — diff=i18n/view-model)
  Checks:     <항목별 pass/fail — 원천(AC / Test plan / 추론)을 함께>
  Measured:   <핵심 단언 요약>
  Synthetic:  <합성한 엔드포인트와 치환값>   (또는 none)
  Unverified: <확인 못 한 항목 — 각각 이유>  (또는 none)
  Rejected:   <N> (self-refuted: <한 줄 이유들>)
  Created:    <이번 실행이 앱에 남긴 레코드 · 새로 쓴 파일>  (또는 none)
  Findings:   <새 이슈 URL 목록>       (또는 none)
```

## 행별 규칙

| 행 | 규칙 | 없으면 생기는 일 |
|---|---|---|
| `Repo:` | 이슈 생성 **직전에** 출력한다 | 스킬은 dotfiles 에 살고 실행은 프로젝트 워크트리에서 된다 — 오등록이 나는 구도 |
| `Serving:` | 경로 · sha · dirty 파일 수를 **항상** 적는다 | 어느 체크아웃을 봤는지 사후에 알 수 없다 |
| `API:` | 브라우저가 관측한 실제 origin | 병렬 스택에서 다른 스택의 시드를 본 걸 못 잡는다 |
| `Driver:` | 사다리에서 실제로 고른 단 | degraded 였다는 사실이 묻힌다 |
| `Matrix:` | **돈 셀 / 전체 셀** + 축을 그렇게 고른 근거 | `1440 x ko` 하나만 돌고도 6xN 을 다 돈 것처럼 읽힌다 |
| `Checks:` | 항목마다 원천(AC / Test plan / 추론 / 사용자) 표기 | 무엇을 근거로 그 항목을 골랐는지 재현 불가 |
| `Synthetic:` | 합성 1건이라도 있으면 **필수** | 실데이터 검증과 스텁 검증이 구분되지 않는다 |
| `Unverified:` | 도달 불가 항목과 그 이유(실데이터 없음 / 타 사용자 권한 / 드라이버 부재 / 게이트 닫힘 / 컨테이너 백엔드) | 통과 목록만 보면 전수 검증한 것으로 읽힌다 |
| `Rejected:` | 자기 반증에서 걷힌 건수 | **`0 findings` 와 `안 찾아봤음` 이 구별되지 않는다** |
| `Created:` | 앱에 남긴 레코드(식별 접두사 포함) + 새로 쓴 캐시 파일 | 정리를 사용자에게 맡기더라도 무엇이 남았는지는 알려야 한다 |

`storage_state` 파일 경로는 **어느 행에도 적지 않는다** (세션 쿠키 그 자체다).

## 정지 (`[FAIL]`)

검증 전 단언 3종 중 하나라도 실패하면 측정하지 않고 정지한다. 무엇이 왜 막혔는지와
**사용자가 할 수 있는 다음 행동**을 함께 적는다.

```
[FAIL] PR #<N> not verified — serving checkout does not contain the target commit
  Serving:  <path> @ <sha>  (behind by <n> commits)
  Target:   <mergeCommit.oid>
  Next:     그 디렉터리에서 rebase 후 재기동하거나, --url 로 다른 서버를 지정하세요
```

```
[FAIL] PR #<N> not verified — locale switch is a no-op
  Tried:    cookie NEXT_LOCALE=ko
  Observed: document.documentElement.lang stayed 'en'
  Next:     전환 메커니즘을 프로젝트 i18n 설정에서 확인하고 --locales 또는 캐시를 고치세요
```

## 부분 (`[WARN]`)

측정은 했으나 커버리지가 온전치 않을 때. 축소 사실을 **첫 줄에** 실어야 한다.

```
[WARN] PR #<N> partially verified — 3/7 checks, 4 unverified
```

## 발견 없음

발견이 0건이면 이슈를 만들지 않고 `[OK] … 0 findings filed` 로 끝낸다. **없는 문제를
지어내지 않는다.** 단 `Rejected:` 행이 그 0 이 어떤 0 인지 설명해야 한다.
