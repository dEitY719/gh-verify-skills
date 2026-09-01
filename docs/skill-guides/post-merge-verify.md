# gh-verify:post-merge-verify

> 한 줄 요약 — 등록된 레포에 한해 구현 탭을 닫고 main 체크아웃을 최신화한 뒤, 검증 전용 워크트리에 새 herdr 세션을 열어 그 레포의 verify 스킬을 프롬프트로 밀어 넣는다.

## 언제 쓰는가

- 머지 직후의 수작업 루틴(구현 탭 닫기 → main 최신화 → 검증 세션 열기)을 자동화할 때. 대상은
  **watched-repos 레지스트리에 등록된 레포뿐**이다.
- 보통은 직접 타이핑하지 않는다 — `gh:pr-merge` 가 Step 5 끝에서 `references/dispatch.sh.md` 를 인라인으로
  실행한다. 손으로 부르는 경우는 두 가지다: `gh:pr-merge` 밖에서 머지가 일어났을 때, 그리고 디스패치가
  soft-fail 해서 재시도할 때.
- 형제 스킬과의 경계는 **디스패치 대 검증**이다 — 이 스킬은 아무것도 검증하지 않는다. 실제 검증은 열린 세션
  안에서 도는 `gh-verify:merged` 또는 `gh-verify:live` 가 하고, 둘 중 무엇을 돌릴지는 레지스트리의
  `verify_skill` 값이 고른다(그 두 값만 허용된다).
- 검증 자체를 지금 이 세션에서 돌리고 싶다면 `gh-verify:merged` / `gh-verify:live` 를 직접 부른다.

## 언제 쓰지 않는가

- **검증 도구로** — `Dispatch only`. 스스로는 아무것도 검증하지 않는다.
- **레지스트리에 없는 레포에서** — 등록되지 않은 레포는 출력도 herdr 호출도 git 호출도 없다. 그 opt-in 이
  이 스킬의 전부다.
- **GitHub 에 무언가 쓰려고** — 머지·리포트는 `gh:pr-merge` 가 이미 끝냈다. 이 스킬은 GitHub 에 쓰지 않는다.
- **여러 PR 배치 처리 / 실패 재시도 자동화** — PR 당 세션은 하나뿐이고, 배치도 재시도도 하지 않는다.
- **무인 cron 경로(`pr_merge_train_cron.sh`)에서** — 명시적 non-goal 이다.

## 호출

```
/gh-verify:post-merge-verify <pr-number> [remote]
```

| # | 이름 | 기본값 | 설명 |
|---|------|--------|------|
| 1 | `<pr-number>` 또는 `-h`/`--help`/`help` | — | 방금 머지된 PR (help 가 아니면 필수) |
| 2 | remote-name | `origin` | PR 이 속한 레포의 git remote. 레포 슬러그와 호스트를 바인딩하며, fetch/rebase 도 이 remote 에서 한다 |

플래그는 없다.

### 사용 예

- `/gh-verify:post-merge-verify 51` — `origin` 레포의 PR #51 검증을 디스패치
- `/gh-verify:post-merge-verify 51 upstream` — 같은 동작, `upstream` remote 대상
- `/gh-verify:post-merge-verify -h` / `--help` / `help` — 도움말 출력

### Exit behavior

항상 0 이다. 실패 채널은 stdout 의 `[WARN]` 한 줄이며, 호출자가 반응해야 하는 실패는 없다.

## 동작 단계

1. **Step 1 — watched-repos 레지스트리 게이트.**
   `${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}` 에서 대상 레포의
   `verify_skill` 을 읽는다. 값이 비었거나 파일을 못 읽거나 `jq` 가 없으면 **아무것도 하지 않는다**(출력 없음).
   `jq` 가 non-zero(파일은 있는데 JSON 이 아님)면 `[WARN]` 하나 뒤 건너뛴다. `verify_skill` 이 허용 목록
   (`gh-verify:merged`, `gh-verify:live`) 밖이면 herdr 호출 전에 `[WARN]` 을 내고 멈춘다 —
   `--dangerously-skip-permissions` 에이전트의 프롬프트에 들어가는 값이라 자유 텍스트일 수 없다.
   `herdr` 이 없으면 조용한 no-op.
2. **Step 2 — 대상 레포와 호스트 해석.** `gh:pr-merge` 와 같은 바인딩으로 하나의 remote URL 에서 레포와
   호스트를 함께 얻는다. API 호출은 없다 — 슬러그는 레지스트리 키이자 에이전트 이름의 일부다. 여기서
   `HEAD_BRANCH` `BASE_BRANCH` `REMOTE` 도 바인딩한다(`gh:pr-merge` 가 넘겨주거나, 단독 실행 시 호스트 고정
   `gh pr view` 로 복구).
3. **Step 3 — 디스패치 실행.** `references/dispatch.sh.md` 를 그대로 붙여 다음 순서로 돈다.
   1. `git worktree list --porcelain` → 머지된 head 브랜치의 로컬 워크트리 경로.
   2. `herdr agent list` → 그 경로에 있는 `tab_id` → `herdr tab close <tab_id>`. 못 찾으면 기록만 하고 계속.
   3. `MAIN_ROOT` 가 git 워크트리 루트이고 HEAD 가 `BASE_BRANCH` 일 때만
      `git fetch <remote> <base>` + `git rebase <remote>/<base>`. 더러운 트리 · 다른/detached 브랜치 ·
      컨플릭트면 `[WARN]` 후 `rebase --abort` 하고 **정지**한다.
   4. `<git-common-dir>/pr-post-merge-verify/pr-<N>` 에 `git worktree add --detach` 로 검증 전용 디렉터리를
      만들고(없으면 생성, 있으면 재사용), `herdr tab create` + `herdr agent start mv-<repo>-pr-<N>` 로 세션을
      연다. 세션은 `MAIN_ROOT` 에 살지 않는다 — 그 체크아웃은 공유되고 3번이 rebase 하기 때문이다.
   5. `herdr agent prompt <agent> "/<verify-skill> <N>" --wait --until idle` 후 새 `tab_id`, 에이전트 이름,
      `attach` 힌트를 보고한다.

## 주의사항

- **모든 실패는 soft — `[WARN]` 한 줄과 exit 0** 이다. 호출자의 리포트가 어느 쪽이든 출력돼야 하기 때문이다
  (F-6). **유일한 예외는 낡은 main 체크아웃** — 낡은 코드를 검증하는 것은 아무것도 증명하지 않으므로 그때만
  실행을 멈춘다.
- **GitHub 에 쓰지 않는다.** head/base ref 읽기가 유일한 API 호출이다. PR · 보드 · 라벨 쓰기가 없다.
- rebase 컨플릭트를 해소하지 않고, 무엇에도 `--force` 를 쓰지 않는다.
- PR 당 세션은 하나 — 배치도 재시도도 없다.
- watched-repos 레지스트리에 없는 레포에는 아무 동작도 하지 않는다.
- 자신이 만든 검증 워크트리를 지우지 않는다. 그 수명은 탭의 수명이고, 탭은 결과를 읽은 운영자가 닫는다 —
  여기서 정리하면 살아 있는 세션이 서 있는 디렉터리를 지우게 된다.
- 무인 `pr_merge_train_cron.sh` 경로는 건드리지 않는다.
- `gh:pr-merge` 는 이 스킬을 `Skill(...)` 로 부르지 않고 `references/dispatch.sh.md` 를 인라인 실행한다.
  이 스킬은 그 블록의 SSOT 이자 수동 진입점으로 남는다.
