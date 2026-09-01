# 리포트 양식 (F-9)

SKILL.md **Step 8** 을 뒷받침한다. 설계 목표는 live 와 같다 — **실제로 한 것보다 강해 보이지
않게 하는 것.** 통과 항목만 나열하면 안 돈 축 · 증명되지 않은 주장 · 도달 못 한 검사가 조용히
사라지고, 독자는 전수 검증한 것으로 읽는다.

## 성공 (`[OK]`)

```
[OK] PR #<N> merge-verified — <M>/<T> claims proven, <K> findings filed
  Repo:       <owner/name>                 (target repo for any new issue)
  Clone:      <path> @ <sha>               (= mergeCommit.oid · clean)
  Claims:     <C> from <source>            (issue #<I> AC / PR Test plan / commit 검증: / asked)
  Runner:     <$TEST_CMD>                  (또는 not detected)
  Matrix:     default, path                (candidates not run: locale, eol — use --matrix full)
  Checks:     <주장별 pass/fail — 원천을 함께>
  Unproven:   <차등에서 before == after 인 주장>   (또는 none · disabled (--no-diff-check))
  Unverified: <도달 못 한 것 — 각각 이유>          (또는 none)
  Rejected:   <N> (self-refuted: <한 줄 이유들>)
  Findings:   <생성한 이슈 URL 목록>              (또는 none)
  Next:       <다음 행동 — 클론 경로에서 재현 / --matrix full 재실행 / 생성된 이슈 확인>
```

## 행별 규칙

| 행 | 규칙 | 없으면 생기는 일 |
|---|---|---|
| `Repo:` | 이슈 생성 **직전에** 출력한다 | 스킬은 dotfiles 에 살고 실행은 대상 레포에서 된다 — 오등록이 나는 구도 |
| `Clone:` | 경로 · HEAD sha · 깨끗함 여부를 **항상** 적는다. 성공·실패 무관 | 어느 트리를 봤는지 사후에 알 수 없다 (F-2 의 존재 이유가 사라진다) |
| `Claims:` | 개수와 **도출 출처**를 함께 (AC / Test plan / 커밋 / 질의) | 무엇을 근거로 그 주장을 골랐는지 재현 불가 |
| `Runner:` | 실제로 고른 명령. 미탐지면 `not detected` | 무엇을 돌렸는지 모르는 초록이 된다 |
| `Matrix:` | **실제로 돈 축**만 적고, 안 돈 후보 축은 괄호로 함께 | 축 하나만 돌고도 전부 돈 것처럼 읽힌다 |
| `Unproven:` | 차등에서 전후 동일한 주장. 끈 경우도 행을 남긴다 | 초록 테스트가 "수정이 동작한다" 로 잘못 승격된다 |
| `Unverified:` | 도달 못 한 것과 이유(러너 미탐지 · 로케일 미설치 · collect-only 없음) | 통과 목록만 보면 전수 검증한 것으로 읽힌다 |
| `Rejected:` | 자기 반증에서 걷힌 건수 | **`0 findings` 와 `안 찾아봤음` 이 구별되지 않는다** |
| `Findings:` | **생성한 이슈 URL**. live 의 `Findings:` 행과 이름·뜻이 같다 — live 의 `Created:` (앱에 남긴 레코드)와는 별개다 | 무엇이 어디에 등록됐는지 추적 불가 |
| `Next:` | 항상 마지막 줄. 구체 명령 또는 경로 | 리포트를 읽고 무엇을 할지가 남지 않는다 |

## 정지 (`[FAIL]`)

F-2/F-3 단언이 막으면 **측정하지 않고** 정지한다. 무엇이 왜 막혔는지와 **다음 행동**을 함께
적고, 클론은 지우지 않고 경로를 남긴다(NF-2).

```
[FAIL] PR #<N> not verified — clone HEAD does not match the merge commit
  Clone:   <path> @ <sha>   (kept for post-mortem)
  Target:  <mergeCommit.oid>
  Next:    git -C <path> fetch origin <oid> 후 재실행하거나 --clone-dir 로 기존 클론을 지정하세요
```

```
[FAIL] PR #<N> state=OPEN — 머지된 PR 이 대상이다
  Next:    머지 후 다시 부르거나, 실행 중인 앱이 있으면 /gh-verify:live 를 쓰세요
```

## 부분 (`[WARN]`)

측정은 했으나 커버리지가 온전치 않을 때, 또는 이슈 생성이 실패해 본문만 남겼을 때. 축소
사실을 **첫 줄에** 싣는다.

```
[WARN] PR #<N> partially verified — 3/7 claims proven, 2 unproven, 2 unverified
```

```
[WARN] PR #<N> merge-verified — 1 finding could not be filed (gh:issue-create failed)
  Findings: none — 본문을 아래에 그대로 출력했습니다 (복사해서 수동 등록하세요)
```

## 발견 없음

발견이 0건이면 이슈를 만들지 않고 `[OK] … 0 findings filed` 로 끝낸다. **없는 문제를 지어내지
않는다.** 단 `Rejected:` 와 `Unproven:` 행이 그 0 이 어떤 0 인지 설명해야 한다.

## PR 코멘트

이 블록을 **한 글자도 바꾸지 않고** 대상 PR 코멘트로 옮긴다 (`[OK]`/`[WARN]` 만).
절차는 `../live/references/pr-comment.md` 와 동일하다.
