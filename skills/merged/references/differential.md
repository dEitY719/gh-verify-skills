# 차등 검증 — before/after (F-7)

SKILL.md **Step 6** 을 뒷받침한다. 규칙 하나로 요약된다: **전·후 모두 통과하는 검사는
아무것도 증명하지 않는다.** 이 규칙이 없으면 "테스트가 초록이다" 가 "수정이 동작한다" 로
잘못 승격된다.

## 1. "이전" 의 정의 — 머지 전략에 따라 다르다

목표는 항상 같다: **그 PR 이 올라타기 직전의 base 상태**. 다만 그 상태를 가리키는
좌표는 머지 전략마다 다르다 — 셋 다 `~1`이라고 뭉뚱그리면 rebase merge 에서 틀린다.

| 전략 | 부모 수 | "이전" 좌표 | 이유 |
|---|---|---|---|
| 진짜 merge 커밋 | 2 | `<merge>~1` (첫 부모) | 첫 부모가 항상 병합 직전 base 다 |
| squash | 1 | `<merge>~1` | 커밋 개수와 무관하게 새 커밋은 항상 정확히 1개 |
| rebase, PR 커밋 1개 | 1 | `<merge>~1` | 재생된 커밋이 1개뿐이라 squash 와 결과가 같다 |
| rebase, PR 커밋 N>1개 | 1 | `<merge>~N` | `~1`은 재생된 마지막 직전 커밋일 뿐 — 여전히 PR 내부다 |

**`~1`을 무조건 쓰면 안 되는 이유**: rebase merge 는 PR 의 커밋을 하나씩 base 위에
재생해 선형 히스토리를 만든다. 커밋이 N개면 `<merge>~1`은 "재생된 N번째 커밋 직전" —
즉 PR 이 만든 (N-1)개 커밋이 여전히 포함된 상태다. 진짜 base 는 `<merge>~N`이다.

### 1-1. 좌표 계산

```sh
PARENTS=$(git -C "$CLONE" cat-file -p "$MERGE_SHA" | grep -c '^parent ')
if [ "$PARENTS" -ge 2 ]; then
    BEFORE_REF="${MERGE_SHA}~1"                      # 진짜 merge 커밋 — 모호함 없음
else
    # squash 와 rebase 는 둘 다 부모가 1개라 부모 수만으로 못 가른다.
    # PR 의 원본 커밋 개수 N 을 gh 에서 얻는다 — squash 는 N 과 무관하게 항상 ~1,
    # rebase 는 ~N 이 정확한 base 다. 판별은 트리 비교로 한다: ~1 과 ~N 의 트리가 같으면
    # (squash, 또는 N=1 rebase) ~1 을 쓰고, 다르면(다중 커밋 rebase) ~N 을 쓴다.
    N=$(gh pr view "$pr" --repo "$TARGET_REPO" --json commits -q '.commits | length' 2>/dev/null)
    if [ -z "$N" ] || [ "$N" -le 1 ]; then
        BEFORE_REF="${MERGE_SHA}~1"
    else
        TREE_1=$(git -C "$CLONE" rev-parse "${MERGE_SHA}~1^{tree}" 2>/dev/null)
        TREE_N=$(git -C "$CLONE" rev-parse "${MERGE_SHA}~${N}^{tree}" 2>/dev/null)
        if [ -n "$TREE_N" ] && [ "$TREE_1" != "$TREE_N" ]; then
            BEFORE_REF="${MERGE_SHA}~${N}"            # 다중 커밋 rebase merge
        else
            BEFORE_REF="${MERGE_SHA}~1"               # squash, 또는 N=1 rebase
        fi
    fi
fi
```

`~N`까지 조상이 부족하거나(`git rev-parse` 실패) `gh pr view`가 커밋 수를 못 주면(호스트가
GitHub 이 아니거나 PR 메타데이터 소실) 판별 자체가 불가능하다 — 그때는 **추측하지 않는다**:
`BEFORE_REF="${MERGE_SHA}~1"` 로 진행하되, 그 사실을 리포트에 남긴다 — 아래 4절의
`differential: n/a` 처리를 본다.

- **`<merge>^2` 를 쓰지 않는다** — 진짜 merge 커밋에서만 존재하고(PR head 쪽), squash/rebase
  에는 없다.
- **merge-base 를 쓰지 않는다** — PR 브랜치가 오래됐으면 merge-base 는 몇 주 전 상태라
  "이 머지가 무엇을 바꿨는가" 대신 "그 사이 base 가 무엇을 바꿨는가" 까지 섞인다.
- 이하 이 문서에서 `<merge>~1` 이라 쓴 곳은 모두 위에서 계산한 `$BEFORE_REF` 를 뜻한다.

## 2. 이전 상태를 만드는 법

```sh
# (a) 파일 단위 — 단일 파일 검사에 충분하다
git -C "$CLONE" show "${BEFORE_REF}:path/to/file" > "$BEFORE_DIR/file"

# (b) 트리 단위 — 러너를 돌려야 하면 클론 안에 워크트리를 하나 더 만든다 (격리 유지)
git -C "$CLONE" worktree add --detach --quiet "$CLONE/.before" "$BEFORE_REF"
```

`.before` 는 **클론 내부**에 만든다. 사용자 레포에 워크트리를 추가하지 않는다(NF-1).
정리는 `git -C "$CLONE" worktree remove` 로 하고, 클론 전체 정리 규칙(NF-2/NF-4)을 따른다.

여러 주장이 같은 `TEST_CMD` 를 쓰면 `.before` 실행은 **1회만** 하고 그 결과(exit code · 케이스별
pass/fail)를 모든 주장에 나눠 쓴다 — 같은 명령을 주장 개수만큼 반복 실행하지 않는다. 주장이 서로
다른 입력·명령을 요구할 때만 별도로 다시 돈다.

## 3. 주장 유형별 절차

### 3-1. PR 이 **기존** 검사의 동작을 바꿨다

같은 입력으로 `.before` 와 클론에서 각각 돌리고 (exit code, 통과/실패 케이스 집합, 핵심
출력)을 비교한다. 같으면 `unproven`.

### 3-2. PR 이 **새 테스트**를 추가했다 (가장 흔하다)

"이전 상태에는 그 테스트가 없다" 는 `unproven` 의 면제 사유가 아니다. 올바른 차등은
**새 테스트 × 옛 코드** 다 — 새 검사가 옛 코드에서 실제로 **실패**해야 그 검사가 무언가를
잡는다는 증거가 된다.

```sh
# $NEW_TEST_PATHS 는 이 주장의 diff 에서 실제로 바뀐 테스트 파일/디렉터리 경로다
# (프로젝트마다 tests/ · test/ · spec/ · __tests__/ 등 규약이 다르므로 고정하지 않는다) —
# F-5 러너 탐지가 이미 그 경로를 알고 있다.
git -C "$CLONE/.before" checkout "$MERGE_SHA" -- "$NEW_TEST_PATHS"  # 검사만 after 에서 가져온다
( cd "$CLONE/.before" && eval "$TEST_CMD" )                        # 옛 코드에서 돌린다 -> 실패해야 정상
```

- 옛 코드에서 **실패** → 그 주장은 `proven`.
- 옛 코드에서도 **통과** → `unproven`. 그 테스트는 회귀를 잡지 못한다. 이건 그 자체로 발견
  후보다(제목 예: `추가된 테스트가 수정 이전 코드에서도 통과한다 — 회귀를 잡지 못함`).
- 새 테스트가 옛 코드에서 **수집조차 안 되는 경우**(import 실패 등)는 `unproven` 이 아니라
  `differential: n/a (test cannot load on pre-PR tree)` 로 적고 이유를 남긴다.

### 3-3. 테스트가 아닌 주장 (CLI 동작 · lint 규칙 · 출력 형식)

같은 명령을 `.before` 와 클론에서 돌려 출력 차이를 보인다. 비교는 정규화 후 — 경로와
타임스탬프는 제거한다. 차이가 없으면 `unproven`.

## 4. 판정과 리포트

| 판정 | 조건 | 리포트 |
|---|---|---|
| `proven` | before ≠ after 이고 after 가 주장대로다 | `Claims:` 의 pass 로 계산 |
| `unproven` | before == after | `Unproven:` 행에 주장과 근거 한 줄 |
| `n/a` | 이전 상태에서 검사를 물리적으로 돌릴 수 없다, 또는 1-1 에서 `$BEFORE_REF` 판별이 불가해 `~1` 로 추정 실행했다 | `Unproven:` 행에 `n/a` 로 사유와 함께 |

`unproven` 은 **실패가 아니다** — 검증이 그 주장을 증명하지 못했다는 사실의 기록이다. 다만
`[OK]` 라도 `Unproven:` 이 비어 있지 않으면 리포트 첫 줄에 그 개수를 실어야 한다.

## 5. `--no-diff-check`

끄면 차등을 돌지 않는다. 그때도 `Unproven:` 행은 남기고 `disabled (--no-diff-check)` 라고
적는다 — **행 자체를 지우지 않는다.** 지우면 "차등을 돌았는데 전부 proven" 과 "안 돌았다" 가
구별되지 않는다.
