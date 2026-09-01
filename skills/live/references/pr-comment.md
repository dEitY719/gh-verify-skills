# 리포트 → PR 코멘트 (pr-comment)

SKILL.md **Step 9** 를 뒷받침한다 — Step 8 이 만든 리포트 블록을 대상 PR 에 코멘트로 남긴다.
목적은 하나다: **검증 결과가 실행한 터미널에서만 사라지지 않게 하는 것.** 리포트가 stdout 에만
남으면 며칠 뒤 "이 PR 을 라이브로 확인했나" 를 PR 화면에서 되짚을 방법이 없다.

## 1. 트리거 조건

| 조건 | 게시 |
|---|---|
| Step 8 결과가 `[OK]` 이고 `post_comment=1` | **한다** |
| Step 8 결과가 `[WARN]` 이고 `post_comment=1` | **한다** — 축소된 커버리지도 기록 가치가 있다 |
| Step 8 결과가 `[FAIL]` | **하지 않는다** (플래그와 무관) |
| `post_comment=0` (`--no-comment`) | **하지 않는다** |

`[FAIL]` 은 검증 전 단언(Step 3 · Step 5)이 막아 **측정을 시작조차 못 한** 상태다. 그건 대상
PR 의 결함이 아니라 **이쪽 환경의 문제**(잘못된 체크아웃 · 전환 no-op · 대상 가림)라, PR 에
남기면 리뷰어에게 PR 이 깨진 것처럼 읽힌다. 로컬 출력으로만 끝낸다.

## 2. `--dry-run` · `--no-issue` 와 독립이다

`issue_mode`(`--dry-run` / `--no-issue`)는 **Step 7 의 이슈 생성만** 게이트한다. 이 단계에는
영향이 없다 — `--no-issue` 로 돌려도 `post_comment=1` 이면 리포트 코멘트는 게시된다.
반대로 `--no-comment` 는 Step 7 을 건드리지 않는다: 이슈는 그대로 생성된다.

두 축을 섞지 않는 이유는 뜻이 다르기 때문이다 — `--no-issue` 는 "대상 레포에 이슈를 만들지
마라", `--no-comment` 는 "PR 타임라인을 어지럽히지 마라" 다. 하나로 묶으면 "이슈는 싫지만
결과 기록은 남기고 싶다" 를 표현할 수 없다.

## 3. append-only — 이전 코멘트를 갱신하지 않는다

**중복 제거도, 기존 코멘트 수정도 하지 않는다.** 조건을 만족한 실행은 매번 **새 코멘트**를
남긴다. 같은 PR 을 여러 번 검증하면 코멘트가 여러 개 쌓이고, 그게 의도다 — 실행 시점마다
서빙 체크아웃 · 드라이버 · 매트릭스가 달랐으므로 **각각이 독립된 관측 기록**이다. 마지막
것으로 덮어쓰면 "처음엔 3/7 이었다가 재검증에서 7/7 이 됐다" 는 이력이 사라진다.

## 4. 게시 블록

본문은 **Step 8 이 만든 리포트 문자열을 그대로 body-file 로 옮겨 쓴다** — Step 8 은 리포트를
stdout 에 출력할 뿐 파일로 만들지 않으므로, 여기서 같은 문자열을 `$REPORT_BODY_FILE` 에
인라인으로 기록한다. 리포트를 여기서 다시 요약하거나 편집하지 않는다: stdout 에 보인 것과
PR 에 남는 것이 **한 글자도 다르면 안 된다.**

게시는 `gh_pr_review.sh` 의 `_gh_pr_review_post_comment` 를 **재사용**한다. 레포 표준
폴백 블록(#644 NF-1 + #724)으로 감싸 부른다 — 맨 호출로 쓰면 헬퍼가 없는 환경에서
`command not found` 로 스킬이 통째로 죽는다.

```bash
REPORT_BODY_FILE=$(mktemp) && trap 'rm -f "$REPORT_BODY_FILE"' EXIT
# ... Step 8 이 stdout 에 출력한 리포트 블록을 한 글자도 바꾸지 않고 "$REPORT_BODY_FILE" 에 그대로 옮겨 쓴다 ...

_HELPER="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/gh_pr_review.sh"
if [ -r "$_HELPER" ]; then
    . "$_HELPER"
    if ! command -v _gh_pr_review_post_comment >/dev/null 2>&1; then
        printf '[pr-verify-live] %s sourced but _gh_pr_review_post_comment undefined (#724).\n' \
            "$_HELPER" >&2
    else
        _gh_pr_review_post_comment "$PR" "$TARGET_REPO" "$REPORT_BODY_FILE" "$post_comment" || true
    fi
fi
```

`$PR` 는 Step 2 (`discovery.md`) 가 해소한 그 변수다 — 이 스킬 안에 `PR_NUMBER` 라는 변수는
없다. 4 번째 인자는 `1` 을 하드코딩하지 않고 Step 1 이 캡처한 `$post_comment` 를 그대로
넘긴다 — 트리거 조건(§1)이 프로즈에만 있고 실행 코드에는 없으면, 이 블록만 따로 복사해
쓰는 자리에서 `--no-comment` 가 조용히 무시된다.

`export DOTFILES_FORCE_INIT=1` 이 여기서도 load-bearing 이다 — Step 2 가 이미
`discovery.md` §3 에서 export 했다면 그대로 유효하다. 없으면 인터랙티브 가드에 막혀
`gh_pr_review.sh` 가 조기 return 하고, 위 `command -v` 분기가 경고를 찍는다.

`$TARGET_REPO` 는 Step 2 에서 확정된 값을 쓴다 — 여기서 다시 해소하지 않는다. 헬퍼가
`--repo "$TARGET_REPO"` 로 넘기므로, dotfiles 가 아니라 **대상 프로젝트 레포의 PR** 에
코멘트가 붙는다.

## 5. 실패는 치명적이지 않다

`_gh_pr_review_post_comment` 는 **soft-fail 계약**이다 — `gh pr comment` 가 실패하면
`[WARN] PR comment post failed — output retained on stdout` 을 stderr 로 찍고 **0 을
반환**한다. 게시 실패로 스킬 전체를 실패 처리하지 않는다: 리포트는 이미 stdout 에 있고,
검증 자체는 끝났다. 종료 코드는 Step 8 의 판정(`[OK]`/`[WARN]` → 0)을 그대로 따른다.

## 6. 금지

- **`gh_pr_review.sh` 를 수정하지 않는다.** 헬퍼는 `gh:pr-review` 의 SSOT 다.
- **`gh pr comment` 를 직접 부르는 코드를 어디에도 새로 쓰지 않는다.** 게시 경로는
  `_gh_pr_review_post_comment` 하나뿐이다 — 두 개가 되면 soft-fail 계약과 skip 경로
  (`GH_DISABLE_AI_METRICS=1`)가 한쪽에서만 지켜진다.
- 자격증명 · `storage_state` 경로를 코멘트 본문에 넣지 않는다 (`report-template.md` 와
  같은 규칙 — 코멘트는 리포트보다 오래, 더 넓게 남는다).
