# 드라이버 사다리와 함정 (driver)

SKILL.md 의 **드라이버 선택 단계**를 뒷받침한다 — 어느 단으로 떨어지는지, 그 단에서
어느 검사군이 가능한지, 그리고 route 핸들러에서 실제로 밟은 함정.

---

## 사다리 (soft-fail)

| 단 | 후보 | 존재 확인 |
|---|---|---|
| 1 | playwright MCP 툴이 **세션에 붙어 있으면** 그것 | `ToolSearch` + 아래 "1단도 예외가 아니다" |
| 2 | python `playwright` | `python3 -c "import playwright"` |
| 3 | node `playwright` | `node -e "require.resolve('playwright')"` — **실행할 디렉터리에서** |
| 4 | **degraded** — `curl` | 항상 가능 |

실측 — 두 런 모두 세션에 playwright MCP 툴이 없었고(`ToolSearch` 로 확인),
python `playwright` 1.58.0 + chromium 이 있어 **2단**으로 진행했다. 사다리가 없었으면
거기서 멈췄다.

### 각 단은 패키지가 아니라 **브라우저 바이너리까지** 확인한다

`import playwright` 가 돼도 브라우저가 없으면 `launch()` 에서 죽는다.

```sh
[ -d "$HOME/.cache/ms-playwright" ] || echo "no browser binary"
# 또는: playwright install --dry-run
```

사다리 **각 단**에 이 확인을 넣어 **launch 전에** degraded 로 떨어질지 정한다.
실측: `~/.cache/ms-playwright/chromium-1234` 가 있어서 통과했다 — 없었으면 launch 에서
런타임 실패로 터졌을 것이고, 그건 soft-fail 이 아니다.

#### 1단도 예외가 아니다 — MCP 가 붙어 있다는 것은 브라우저가 있다는 뜻이 아니다

`ToolSearch` 가 playwright MCP 툴을 찾아도 그 서버가 **자기 채널의 브라우저**를 못 찾으면
첫 호출에서 죽는다. 2·3단에 쓴 "패키지 말고 바이너리" 가 1단에 그대로 적용된다는 뜻이고,
1단의 존재 확인을 `ToolSearch` 하나로 끝내면 사다리의 목적이 절반만 선다.

```
Error: async initializeServer: Chromium distribution 'chrome' is not found at
/opt/google/chrome/chrome
Run "npx playwright install chrome"
```

실측(brokerdesk PR #176): MCP 툴은 세션에 **붙어 있었고** `browser_resize` 첫 호출이 위로
죽었다 — 시스템 크롬이 없고 저장소에는 playwright 가 받아 둔 chromium 만 있었다.
이 실패는 **launch 시점 런타임 오류**라 soft-fail 이 아니다: 1단을 통과한 것으로 치고
측정에 들어가면 그 실행은 드라이버 없이 시작된다.

그래서 1단은 **첫 MCP 호출을 존재 확인으로 쓴다** — `browser_navigate`/`browser_resize`
같은 가벼운 것 하나를 먼저 치고, 채널/바이너리 오류가 나면 **그 자리에서 2단으로
내려간다**. MCP 서버의 채널을 고치려 들지 않는다(세션 밖 설정이고, 검증의 목적도 아니다).

### 2단과 3단은 **언어가 다르다**

실측 환경의 playwright 는 **python 패키지**였고
(`~/.local/lib/python3.13/site-packages/playwright`), node 쪽
`require.resolve('playwright')` 는 실패했다. 하나를 다른 하나의 폴백으로 뭉뚱그리면
"있는데 없다" 또는 "없는데 있다" 가 된다. **각각** 확인한다.

### 3단의 확인과 실행은 **같은 디렉터리**에서 해야 한다

node 의 모듈 해석은 **cwd 기준**이다. playwright 가 저장소 루트가 아니라 하위
워크스페이스(`frontend/node_modules`, `apps/web/node_modules`, pnpm 워크스페이스…)에
설치돼 있으면, 루트에서 친 `require.resolve('playwright')` 는 **실패한다** — 설치돼
있는데 "없다" 고 판정하는 경우다.

```sh
# 루트에서: 실패 — 없다고 잘못 판정한다
node -e "require.resolve('playwright')"
# 소유한 디렉터리에서: 성공
(cd frontend && node -e "require.resolve('playwright')")
```

**이 오판의 대가가 크다** — 3단이 거짓으로 비면 4단(degraded)으로 떨어지는데, 바로
아래 문단대로 대상이 SPA 면 degraded 의 실효 가치는 0 에 수렴한다. 즉 "브라우저가
있는데 아무것도 측정하지 못한 실행" 이 된다.

그래서 3단은 **어느 디렉터리가 그 패키지를 소유하는지 먼저 찾고**, 확인·스크립트 실행·
`node` 호출을 전부 거기서 한다:

```sh
# 소유 디렉터리 찾기(가장 얕은 것 하나면 된다)
find . -maxdepth 3 -type d -path '*/node_modules/playwright' -not -path '*/.git/*' | head -1
# → ./frontend/node_modules/playwright  ⇒ 스크립트를 frontend/ 안에 두고 거기서 node 로 실행
```

실측(brokerdesk): playwright 는 `frontend/node_modules` 에만 있어 루트 확인이 실패한다.
스크립트를 저장소 밖에 두고 부르는 것도 같은 이유로 안 된다 — 해석 기준이 스크립트의
위치라서다. 작업 파일은 그 디렉터리에 두고 **끝나면 지운다**(소스 읽기 전용 계약).

---

## degraded 모드는 과대평가돼 있다

대상이 **Vite SPA** 면 `curl /` 는 빈 셸만 돌려준다 — HTML 단언의 실효 가치가 **0에 수렴**한다.

1. 앱 유형(SSR/MPA vs SPA)을 **먼저 판별**한다 (`curl /` 응답에 렌더된 콘텐츠가 있는지).
2. SPA 면 `[SKIP] browser — SPA, curl 로 검증 불가` 로 남기고
   **부분 커버리지를 주장하지 않는다.**
3. SSR/MPA 면 curl + HTML/헤더 단언이 실제로 값을 한다 — 그때만 degraded 결과를 근거로 쓴다.

---

## 드라이버 단계별 가능한 검사군

| 검사군 | MCP / python / node | degraded (curl) |
|---|---|---|
| `getComputedStyle` · `getBoundingClientRect` · `scrollHeight` (`assertions.md` (c)) | 가능 | 불가 |
| 합성 before (`cloneNode`) · 경계 밀어보기 | 가능 | 불가 |
| 형제 비교 (d) | 가능 | 불가 |
| 지시-어포던스 (e) · 셀렉터 규율 (f) | 가능 | 불가 (SPA), 제한적 (SSR) |
| 응답 가로채기 (g) · 선행 조건 합성 (h) | 가능 | **불가 — 통째로 `[SKIP]`** |
| hit-test (i) | 가능 | 불가 |
| HTML/헤더 단언 · API 직접 호출 | 가능 | SSR/MPA 만 |

**드라이버가 결정하는 것은 "되냐 안 되냐" 가 아니라 "어느 검사군이 가능한지" 다.**
가로채기 · hit-test · `getComputedStyle` 은 전부 브라우저 드라이버 전용이다.
degraded 로 떨어진 실행은 그 사실을 리포트 `Driver:` 행과 `[SKIP]` 행에 함께 남긴다.

---

## route interception 함정 부록

`assertions.md` (g)(h) 대로 응답 합성이 상시 도구가 되면 매 실행 route 핸들러를 쓴다.
실제로 밟은 것 둘.

### 1. 핸들러 인자 개수로 시그니처가 바뀐다

Playwright 는 인자 2개짜리 핸들러에 `(route, request)` 를 넘긴다. 기본인자로 값을 캡처하면
**조용히 두 번째 인자가 Request 로 덮인다.**

```python
# 틀린 것 — kr 이 Request 객체가 된다
def handle(route, kr=kr, en=en):
    ...
# 터지는 곳은 저 멀리:
# TypeError: Locator.count: Object of type Request is not JSON serializable
```

```python
# 맞는 것 — 클로저 팩토리로 캡처한다
def make_handler(kr, en):
    def handle(route):
        ...
    return handle

await pg.route("**/api/v1/submissions", make_handler(kr, en))
```

에러가 핸들러가 아니라 **한참 뒤 locator 호출에서** 나서 원인 추적에 시간이 든다.

### 2. 가로챈 상태의 `networkidle` 은 goto 타임아웃을 만든다

`route.fetch()` → `fulfill()` 왕복이 idle 판정과 물려 **30초를 그냥 쓴다.**

```python
# 틀린 것
await pg.goto(url, wait_until="networkidle")
# 맞는 것
await pg.goto(url, wait_until="domcontentloaded")
await pg.wait_for_selector("[data-banner-state]")   # 명시적 대기
```
