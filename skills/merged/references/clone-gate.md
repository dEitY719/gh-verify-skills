# 신선한 클론과 무결성 단언 (F-2 · F-3)

SKILL.md **Step 3** 을 뒷받침한다. 이 절의 두 단언은 **하드 정지**다 — 하나라도 실패하면
아무것도 측정하지 않는다(NF-3). 이유는 live 스킬의 "검증 전 단언" 과 같다: 잘못된 대상을
검증하느니 멈추는 게 낫다.

## 1. F-2 — 머지 커밋의 신선한 클론

### 1-1. 클론 소스와 체크아웃 대상

- **체크아웃은 반드시 `mergeCommit.oid`** 다. `headRefOid` 를 쓰지 않는다 — rebase/squash
  머지는 head sha 를 base 에 남기지 않으므로 **정상 머지된 PR 에서 100% 오정지**한다
  (실측 대조표: `../live/references/discovery.md` §2-1).
- 클론 소스는 **로컬 레포 루트여도 된다** (`git clone <repo-root>`) — 빠르고 네트워크가 없어도
  된다. 다만 로컬이 그 커밋을 아직 모를 수 있으므로, 없으면 **클론 안에서** 원격을 붙여
  fetch 한다. **사용자 레포로 fetch 하지 않는다** (NF-1 — 남의 refs/objects 를 늘리지 않는다).
- `--depth` 를 쓰지 않는다. F-7 이 `<merge>~1` 을 필요로 한다.

```sh
SRC=$(git -C "$PWD" rev-parse --show-toplevel)        # 사용자 레포 (읽기 전용으로만 쓴다)
CLONE=${clone_dir:-$(mktemp -d "${TMPDIR:-/tmp}/pr-verify-merged-${pr}-XXXXXX")}
git clone --no-hardlinks --no-checkout --quiet "$SRC" "$CLONE" || stop "clone failed"
git -C "$CLONE" cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null || {
    git -C "$CLONE" remote set-url origin "$(git -C "$SRC" remote get-url "${remote:-origin}")"
    # 서버가 임의 SHA want 를 막아 두면(uploadpack.allowTipSHA1InWant=false, 흔히 자체 호스팅
    # GHES/GitLab) 원시 SHA fetch 가 거부된다. 병합 커밋은 이미 base 브랜치 히스토리의
    # 일부이므로, base ref 를 fetch 하면 부수적으로 함께 따라온다 — 이 경로가 항상 동작한다.
    git -C "$CLONE" fetch --quiet origin "$MERGE_SHA" 2>/dev/null \
        || git -C "$CLONE" fetch --quiet origin "$BASE" 2>/dev/null
    git -C "$CLONE" cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null || stop "merge commit not fetchable"
}
git -C "$CLONE" checkout --quiet --detach "$MERGE_SHA" || stop "checkout failed"
```

`--no-hardlinks` 는 격리를 위한 것이다 — 기본 로컬 클론은 오브젝트를 하드링크하므로 클론 쪽
정리/GC 가 사용자 레포와 같은 inode 를 건드린다. 비용은 디스크뿐이다.

### 1-2. HEAD 단언

```sh
HEAD_SHA=$(git -C "$CLONE" rev-parse HEAD)
[ "$HEAD_SHA" = "$MERGE_SHA" ] || stop "clone HEAD $HEAD_SHA != mergeCommit $MERGE_SHA"
```

불일치는 **측정 없이 정지**하고, 리포트 `Clone:` 행에 경로와 두 sha 를 모두 적는다.
클론 경로는 성공/실패 무관하게 리포트에 **항상** 출력한다 — 사후에 무엇을 봤는지 재현하려면
이것밖에 없다.

## 2. F-3 — 클론 무결성

### 2-1. 클론이 깨끗해야 한다

```sh
[ -z "$(git -C "$CLONE" status --porcelain)" ] || stop "clone worktree is dirty"
```

방금 만든 클론이 더럽다는 것은 checkout 이 반쯤 실패했거나 hook/filter 가 파일을 건드렸다는
뜻이다. 그 상태의 측정은 오염이다 — 정지한다. (live 는 dirty 를 경고로 다루지만 그건 **사용자가
쓰던 체크아웃**이라서다. 여기서는 우리가 방금 만든 것이므로 변명의 여지가 없다.)

### 2-2. 추적되지 않는 생성물 의존 검출 — 이 스킬의 핵심

**실측 사례(`dEitY719/obsidian-para` PR #16, 머지 커밋 `b534f99`)**:

```
작업 worktree        : passed: 9  failed: 0
머지 커밋 신선한 클론 : passed: 8  failed: 0    <- anchors/crlf 케이스가 조용히 사라짐
```

원인은 그 PR 이 추가한 픽스처의 유일한 vault 파일이 `.gitignore` 대상이었고, git 은 빈
디렉터리를 추적하지 않으므로 클론에는 케이스 디렉터리 자체가 없었다. 러너는
`[ -d "$case_dir/vault" ] || continue` 로 **조용히** 건너뛰었다. PR 은 초록으로 머지됐고
리뷰어 2명도 통과시켰다. worktree 에서 검증하는 한 영원히 안 잡힌다.

그래서 이 검사는 선택이 아니다. 순서대로 한다.

**의존성 설치 — 러너를 돌리기 전에 한 번.** 클론은 `git clone` 산출물이라 `node_modules` /
`.venv` / 잠금파일 기반 설치 상태를 담지 않는다. 클론 안에서 감지된 검증 명령(F-5 사다리)을
그대로 실행하기 전에, 프로젝트가 선언한 표준 설치 스텝을 **클론 안에서 1회** 돈다 —
`package.json`→`npm ci`(lockfile 있으면) 아니면 `npm install`, `pyproject.toml`(uv 관리)→
`uv sync`, `requirements.txt`→`pip install -r requirements.txt`, `Gemfile`→`bundle install`.
AGENTS.md/README 에 명시된 설치 명령이 있으면 그쪽을 우선한다. 설치 자체가 실패하면(오프라인 ·
사설 레지스트리 인증 없음) 정지가 아니라 `Unverified: dependency install failed (<원인>)` 로
적고 의존성 없이도 돌아가는 검사(grep/sed 기반 lint, CLI 진입점 직접 호출)만 계속한다.

**(a) 케이스 집합 비교 — 실행된 것을 센다.**

러너별로 "실행/수집된 케이스 이름" 을 뽑아 **정렬된 집합**으로 비교한다. 가능하면 실행이
아니라 **수집(collect-only)** 을 쓴다 — 사용자 작업 트리에서 부작용을 만들지 않기 위해서다.

| 러너 | 클론에서 | 작업 트리에서(읽기 전용 선호) |
|---|---|---|
| pytest | `pytest --collect-only -q` | 같은 명령 |
| bats | `bats --count <dir>` + 파일별 `@test` 이름 grep | 같은 명령 |
| npm/jest | `npx jest --listTests` | 같은 명령 |
| 프로젝트 고유 스크립트 | 러너 출력의 케이스 이름 줄 파싱 | 같은 명령 |

수집 모드가 없어 **실행**해야만 이름이 나오는 러너라면, 작업 트리 쪽 실행이 파일을 쓰는지
먼저 본다. 쓴다면 그 비교는 하지 않고 `Unverified: worktree case set (runner has no
collect-only mode)` 로 적는다 — NF-1 이 케이스 비교보다 우선이다.

```sh
diff <(printf '%s\n' "$CLONE_CASES" | sort) <(printf '%s\n' "$WORKTREE_CASES" | sort)
```

한쪽에만 있는 케이스가 있으면 **발견 후보**다. 개수만 같고 이름이 다른 경우도 있으므로
**개수와 이름을 둘 다** 비교한다.

**(b) 왜 사라졌는지 확정 — git 이 그 경로를 아는가.**

케이스 디렉터리 경로마다 클론이 실제로 그것을 담고 있는지 묻는다. 이 검사는 러너 실행
없이도 돌고, 작업 트리에 아무 부작용이 없다.

```sh
git -C "$CLONE" ls-files --error-unmatch "$case_path" >/dev/null 2>&1 \
  || echo "MISSING IN CLONE: $case_path"
git -C "$SRC" check-ignore -v "$case_path"     # 왜 추적되지 않는지(어느 .gitignore 규칙인지)
```

`git -C "$SRC" status --porcelain --ignored=matching -- <test-root>` 로 **테스트 루트 아래의
ignored 파일 목록**을 뽑아 두면, 픽스처가 로컬 생성물에 의존하는 자리가 한 번에 보인다.

**(c) 발견으로 올린다.** 제목 형태: `테스트 케이스 <name> 이 신선한 클론에서 실행되지
않는다 (untracked fixture)`. 본문에는 (i) worktree/clone 케이스 수, (ii) 빠진 경로,
(iii) `check-ignore` 가 지목한 규칙, (iv) 러너가 조용히 건너뛴 코드 줄을 담는다. 이 발견은
**러너가 조용히 skip 한다는 사실 자체**도 함께 지적한다 — 없는 픽스처는 skip 이 아니라 error
여야 한다.

## 3. 정지 메시지

정지할 때는 **무엇이 왜 막혔는지 + 사용자가 할 수 있는 다음 행동**을 함께 적는다. 필드 형식의
정본은 `references/report-template.md` 의 `[FAIL]` 절 — 아래는 실측값을 채운 예시다.

```
[FAIL] PR #16 not verified — clone HEAD does not match the merge commit
  Clone:   /tmp/pr-verify-merged-16-Ab3d9x @ 1c2f9ae
  Target:  b534f99...
  Next:    git -C /tmp/pr-verify-merged-16-Ab3d9x fetch origin b534f99 후 재실행하거나 --clone-dir 로 기존 클론을 지정하세요
```
