# 환경 발견과 서빙 체크아웃 검증

SKILL.md Step 2 — base URL·백엔드 origin 발견과 "검증 전 단언 3종" 중 첫 번째(**서빙 체크아웃이 대상 커밋을 포함하는가**)를 뒷받침한다.

## 1. base URL 발견

전제: 서버는 **이미 사용자가 띄워 둔 상태**다. 기본 동작은 "띄운다"가 아니라 "찾는다".

| 순위 | 절차 | 실패 시 |
|---|---|---|
| 1 | `--url` 인자 | — (발견 단계 전체를 건너뛴다) |
| 2 | LISTEN 소켓 수집 | 하나도 없으면 `[FAIL] 기동 중인 서버 없음` |
| 3 | 알려진 dev 포트로 후보 정렬 | 정렬만 한다 — 후보를 지우지 않는다 |
| 4 | 프런트/백엔드 후보 필터 (아래 1-2) | 후보 0개면 `AskUserQuestion` |
| 5 | 그래도 여럿이면 `AskUserQuestion` | **추측 금지** |

```sh
# Linux
ss -ltnp
# macOS
lsof -nP -iTCP -sTCP:LISTEN
```

알려진 dev 포트 우선순위: `5173`(Vite) · `3000`(Next/CRA/Remix) · `4200`(Angular) ·
`8080` · `5000`(Flask) · `8000`(Django/FastAPI/uvicorn).

### 1-1. 후보 필터는 프런트와 백엔드를 나눠 건다

프런트와 백엔드는 **동시에 LISTEN 한다**. 실측: 세 런 모두 `:5173`(Vite)과
`:8000`(FastAPI)이 함께 떠 있었다.

| 후보 | 판정 | 근거 |
|---|---|---|
| 프런트 | `GET /` 응답이 HTML(`<!doctype html>`) | `:8000` 은 `/` 가 HTML 이 아니라 자연히 걸러졌다 |
| 백엔드 | `GET /openapi.json` · `/docs` 가 JSON/HTML 문서로 응답 | HTML 필터만 쓰면 API 포트가 후보에서 통째로 빠진다 |

**`/health` 류 추측 경로를 프로빙하지 않는다** — 실측에서 그 앱은 `/health` 가 404 였다.
`/` HTML 판정이 맞고, 백엔드는 `/openapi.json`·`/docs` 처럼 프레임워크가 규정한 경로만 본다.

프로브는 **반드시 타임아웃을 걸고 후보 전체를 한 번에 펼친다**. 필터링된 docker-published
포트 하나가 curl 기본 connect timeout(~2분) 을 다 쓰면 Step 3 에 들어가기도 전에 멎는다.
후보 4개 x 경로 3개를 순차로 돌리면 12회 왕복이지만, 아래는 ~2초에 끝난다.

```sh
for p in $PORTS; do
  for path in / /openapi.json /docs; do
    curl -s -o /dev/null -m 2 -w "$p $path %{http_code} %{content_type}\n" \
      "http://127.0.0.1:$p$path" &
  done
done
wait
```

### 1-2. 백엔드 origin 은 브라우저가 알려 준다

포트 우선순위로 백엔드를 고르는 것은 **병렬 스택 환경에서 통하지 않는다**. 실측:

```
127.0.0.1:5173  users:(("MainThread",pid=3982320,fd=32))   <- Vite, PID 있음
0.0.0.0:8000    (PID 없음)   agent-toolbox-api-1
0.0.0.0:8010    (PID 없음)   agent-toolbox-e1-api-1
0.0.0.0:8020    (PID 없음)   atb-t2-api-1
```

세 개가 전부 "알려진 dev 포트"다. 그 런에서 `:8000` 대신 `:8010`/`:8020` 을 골랐으면
**다른 스택의 시드를 보고 엉뚱한 결론**을 냈을 것이다.

확실한 방법은 **프런트가 실제로 쓰는 origin 을 브라우저 컨텍스트에서 읽는 것**이다.

```python
seen = set()
page.on("request", lambda r: seen.add(urlparse(r.url).netloc))
page.goto(BASE_URL, wait_until="domcontentloaded")
# seen 에서 BASE_URL 호스트가 아닌 origin = 실제 API origin
```

- `--api-url <origin>` 으로 명시할 수 있다. 명시하면 이 단계를 건너뛴다.
- 확정한 origin 은 리포트 `API:` 행에 적는다.
- 용도는 가로채기만이 아니다 — **화면을 보기 전에 API 를 직접 찔러 기대값을 먼저 만든다.**
  실측: 시드에 어떤 팀·아이템이 있고 payload 에 `team_name_kr`/`_en` 이 실제로 실려 오는지를
  `/api/v1/items/discovery` 로 먼저 확인해야 "화면 문자열이 맞다/틀리다"를 판정할 수 있었다.

## 2. 서빙 체크아웃 검증 — 이 스킬의 존재 이유

멀티 워크트리 환경에서 dev 서버가 **다른 디렉터리**에서 돌고 있으면, 브라우저로 아무리
확인해도 **내 PR 이 아닌 코드를 검증**하게 된다. 화면은 멀쩡히 뜨므로 조용히 통과한다.

**세 런(#2475 · #2480 · #2471)에서 독립 재현됐고, 사람이 직접 해도 매번 빼먹었다** — 이 절이
하드 정지인 이유다. 실측 한 건: dev 서버는 `~/para/project/agent-toolbox`(main), 작업
워크트리는 `~/para/project/agent-toolbox-issue-2480-1`. 또 갈렸다.

### 2-1. 절차

1. LISTEN 소켓에서 PID 추출 — `ss -ltnp` 의 `users:(("...",pid=N,...))`
2. cwd 를 읽는다

   ```sh
   # Linux
   readlink /proc/"$PID"/cwd
   # macOS
   lsof -a -p "$PID" -d cwd -Fn
   ```

3. cwd 가 **하위 디렉터리**여도 상관없다 — `git -C "$CWD" rev-parse --show-toplevel` 이
   레포 루트로 정확히 해소된다. 실측: `readlink /proc/3982320/cwd` →
   `.../agent-toolbox/apps/web` (**Vite 는 `apps/web` 에서 뜬다**).
4. ancestry 검사는 **`mergeCommit.oid`** 로 한다.

   ```sh
   # PR 메타는 여기서 한 번만 받아 Step 4(targets.md §1)까지 재사용한다 — 왕복 3회 → 1회.
   PR_JSON=$(gh pr view "$PR" -R "$TARGET_REPO" \
     --json title,body,files,mergeCommit,headRefOid,closingIssuesReferences)
   TARGET_SHA=$(printf '%s' "$PR_JSON" | jq -r '.mergeCommit.oid // .headRefOid')
   git -C "$SERVING_ROOT" merge-base --is-ancestor "$TARGET_SHA" HEAD
   ```

   `headRefOid` 를 쓰면 rebase/squash merge 레포에서 **100% 오정지**한다. 실측 sha 대조:

   | PR | headRefOid | mergeCommit | `--is-ancestor headRefOid` |
   |---|---|---|---|
   | #2483 | `6f2daea26…` | `19ae738f7…` | 실패 (정상 상태인데 정지) |
   | #2484 | `8be3480d8…` | `4c053740f…` | 실패 (정상 상태인데 정지) |
   | #2476 | `8f537623b…` | `ec61107b5…` | 실패 (정상 상태인데 정지) |

   머지 방식(merge/rebase/squash)을 스킬이 알 필요는 없다 — `mergeCommit` 하나로 세 경우가
   다 덮인다. `mergeCommit` 이 `null`(미머지 PR 검증)일 때만 `headRefOid` 로 떨어진다.

5. 정지 메시지에 **몇 커밋 뒤처졌는지**를 실어 사용자가 rebase 만 하면 되는지 판단하게 한다.

   ```sh
   git -C "$SERVING_ROOT" rev-list --count "$TARGET_SHA"..HEAD
   ```

### 2-2. dirty 워킹 트리는 경고, 정지 아님

Vite 는 HEAD 가 아니라 **워킹 트리**를 서빙한다(HMR). rebase 후 재기동을 안 했거나
uncommitted 변경이 있으면 HEAD 는 맞는데 화면은 낡을 수 있다.

```sh
git -C "$SERVING_ROOT" status --porcelain
```

더러우면 **정지하지 않고** 리포트에 명시한다 — 사용자가 의도적으로 뭔가 얹어 놨을 수 있다.
실측 런은 `dirty: 0 files` 로 깨끗했고, 그래서 이 구분이 필요하다는 것만 확인됐다.

### 2-3. 레이어별 프로세스로 확장

절차가 "HTML 을 서빙하는 프로세스 하나"를 가정하면, PR 이 백엔드를 건드렸을 때 **이 절이 막으려던
바로 그 실패 모드가 재현된다** — API 서버가 구버전을 물고 있어도 화면은 멀쩡히 뜨고 통과 도장이
찍힌다.

1. PR 변경 파일을 레이어로 분류 — `apps/web/**` → 프런트 / `apps/server/**` → 백엔드 /
   공용 패키지 → 양쪽
2. 각 레이어를 서빙하는 LISTEN 프로세스를 찾는다 (1-1 의 프런트/백엔드 필터)
3. **해당하는 모든 프로세스**에 cwd → HEAD → ancestry 를 돌린다. 단 여러 프로세스가 같은
   `SERVING_ROOT` 로 해소되면(모노레포에서 흔하다 — Vite 는 `apps/web` 에서 떠도 §2-1 의 3번이
   레포 루트로 되돌린다) **git 검사는 루트당 한 번만** 돌린다. cwd 프로브 자체는 §2-5 대로
   프로세스마다 매번 읽는다 — PID 는 바뀐다.
4. 하나라도 불일치면 정지

프런트 전용 PR 이면 프런트 프로세스만 확인하면 된다 — 실측 런이 그랬고, Vite 쪽만 맞으면 됐다.

### 2-4. 컨테이너 백엔드 검증 (fallback ladder)

docker-published 포트는 `ss -ltnp` 에 PID 가 안 잡힌다(docker-proxy). 이 경우, `devx_pr_verify_live_backend_identity.sh` 헬퍼를 통해 identity를 기계적으로 검증한다.
입력: `--repo-root`, `--target-repo`, `--target-sha`, `--base-url`, `--backend-ports`, `--container-name`

헬퍼는 다른 여섯 개와 **같은 폴백 사다리**(dotfiles -> vendored -> 정지)로 소스한다 — 플러그인만 설치된 머신에는 `$HOME/dotfiles` 가 없고,
그때 `SHELL_COMMON` 을 vendor 루트로 export 해야 헬퍼가 자기 `.py` 형제(`$SHELL_COMMON/functions/`)도 찾는다.

```sh
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/devx_pr_verify_live_backend_identity.sh" ] || _SC="${CLAUDE_PLUGIN_ROOT:-$PWD}/lib/vendor/shell-common"
[ -f "$_SC/functions/devx_pr_verify_live_backend_identity.sh" ] || {
    printf '[gh-verify:live] shell-common not found under %s. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' \
        "$_SC" >&2
    return 1 2>/dev/null || exit 1
}
export SHELL_COMMON="$_SC"
. "$_SC/functions/devx_pr_verify_live_backend_identity.sh"
devx_pr_verify_live_backend_identity --repo-root "$REPO_ROOT" --target-repo "$TARGET_REPO" \
  --target-sha "$TARGET_SHA" --base-url "$BASE_URL" [--backend-ports "$PORTS"] [--container-name "$NAME"]
```

폴백 블록 없이 이름만 부르면 플러그인 설치본에서는 호출할 파일 자체가 없다 — 사다리가 아예 돌지 않는다.

1. **A. host PID/cwd ancestry**: 호스트의 ss/lsof를 확인해 docker-proxy가 아닌 API 서버 프로세스가 존재하면 검증을 시도한다.
2. **B. docker exec git ancestry**: docker ps로 포트에 매핑되는 컨테이너를 찾고, 컨테이너 내부에 마운트된 git 저장소의 merge-base ancestry를 검증한다.
3. **C. 컨테이너 내부 파일/라우트 존재 검증**: git이 없는 컨테이너의 경우, PR 변경 사항에 해당하는 백엔드 파일들의 존재 여부와 추가된 라우트/코드 일부(grep)가 컨테이너 내부에 포함되어 있는지 검증한다. 성공 시 unverified 상태이지만 근거(evidence)를 함께 제시한다.
4. **D. build SHA/version endpoint 대조**: API 서버가 제공하는 `/version` 등 endpoint에서 SHA 값을 응답받아 target SHA와 대조한다.

**판정 결과 처리**:
- `verified`: 검증 성공, live-verify 진행.
- `mismatch`: 대상 커밋이 서빙 중이 아님이 증명됨 -> 검증 전 단언 실패로 **하드 정지**.
- `unverified`: 컨테이너 또는 git 환경 문제로 증명 불가 -> 정지하지 않고 구체적인 미검증 사유(reason)와 근거(evidence)를 리포트에 남기고 계속 진행.


### 2-5. cwd 프로브 결과를 캐시하지 않는다

dev 서버 PID 는 재기동으로 세션 중에 바뀐다. 실측: 같은 런 안에서 Vite PID 가
`3208206` → `3982320` 으로 바뀌었다. **검증 시점에 매번 읽는다.**

## 3. 대상 레포 확정과 PR 번호

레포 확정과 PR 번호 해소는 **레포 SSOT 헬퍼를 그대로 쓴다** — `gh repo view` 기본 레포
휴리스틱을 다시 짜지 않는다(`origin`/`upstream` 이 함께 있으면 엉뚱한 쪽으로 붙는다).

```sh
# DOTFILES_FORCE_INIT=1 은 load-bearing 이다: 이 파일의 인터랙티브 가드가
# 비대화형 셸에서 조기 return 하면 헬퍼가 아예 정의되지 않는다.
export DOTFILES_FORCE_INIT=1
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/gh_pr_review.sh" ] || _SC="${CLAUDE_PLUGIN_ROOT:-$PWD}/lib/vendor/shell-common"
[ -f "$_SC/functions/gh_pr_review.sh" ] || {
    printf '[gh-verify:live] shell-common not found under %s. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' \
        "$_SC" >&2
    return 1 2>/dev/null || exit 1
}
export SHELL_COMMON="$_SC"
. "$_SC/functions/gh_pr_review.sh"
TARGET_REPO=$(_gh_pr_review_resolve_target_repo "${remote:-origin}") || {
  echo "Cannot resolve remote '${remote:-origin}' to a repo" >&2; exit 1; }
PR=$(_gh_pr_review_resolve_pr_number "$pr")   # 인자 우선, 없으면 현재 브랜치
```

이후 **모든** `gh` 호출에 `-R "$TARGET_REPO"` 를 넘긴다.

### 3-1. 브랜치가 `[gone]` 이면 커밋으로 역추적

`_gh_pr_review_resolve_pr_number` 가 실패하는 경우가 하나 있다 — rebase merge + 로컬 main
rebase 후에는 작업 브랜치가 `[gone]` 이라 브랜치 기준 조회가 안 된다(실측 런이 정확히 그
상태였다). 그때만 커밋 → PR 역참조로 떨어진다.

```sh
PR=$(gh api "/repos/$TARGET_REPO/commits/$(git rev-parse HEAD)/pulls" -q '.[].number')
```

## 4. 기동 명령 발견 (`--start` 를 쓸 때만)

| 순위 | 소스 | 찾는 것 |
|---|---|---|
| 1 | `CLAUDE.md` · `AGENTS.md` · `DEVELOPMENT.md` | dev 서버 실행을 안내하는 코드블록 grep |
| 2 | `package.json` scripts | `dev:frontend` → `dev` → `start` → `serve` 순 |
| 3 | `Makefile` 타겟 | `dev` / `run` / `serve` |
| 4 | Python | `manage.py runserver` · `uvicorn` · `flask run` |
| 5 | `docker-compose*.yml` | dev 프로필 |
| 6 | 못 찾음 | `AskUserQuestion` — 추측 금지 |

**반드시 레포 루트에서 실행하고 스킬 종료 시 정리한다.** 그리고 **기본은 기동하지 않는다** —
사용자가 이미 띄웠고, 남의 서버를 죽이면 안 된다. `--start` 로 스킬이 직접 띄운 프로세스만
스킬이 정리한다.
