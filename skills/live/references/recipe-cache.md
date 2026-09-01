# 프로젝트 레시피와 캐시

SKILL.md Step 5 — 로그인 · 오버레이 해제 · 로케일 전환처럼 **프로젝트마다 다른 진입 절차**를
발견하고 `.claude/pr-verify-live.json` 에 캐시하는 단계를 뒷받침한다. 여기서 발견하는 값은
"검증 전 단언 3종" 중 ②(로케일/뷰포트 전환이 실제로 적용됐는가)와 ③(대상 요소가 오버레이에
가려지지 않았는가)의 입력이다.

## 1. 로그인 레시피

1. 프로젝트 `CLAUDE.md` / `AGENTS.md` 의 **"프런트엔드 검증" 류 섹션**을 먼저 읽는다. 이미 이런
   식으로 적혀 있는 레포가 있다:
   > 로그인 화면에서 로그인 버튼을 클릭하면 mock IdP 선택지가 열린다. 상단 `admin` 버튼은
   > 관리자로 로그인한다.
2. 그런 섹션이 없으면 DOM 을 훑어 후보를 찾고(`a[href*=login]` ·
   `button:has-text(로그인|Sign in)`) **사용자에게 확인받는다**.
3. 성공한 경로를 캐시한다.

**실측 실패 사례** — `get_by_role("button", name="로그인")` 이 **0 matches**. 실제 DOM 은
이랬다.

```html
<a href="/api/v1/auth/login?next=%2F">로그인</a>
```

두 런에서 **독립 재현**됐고(한 런은 `name="Sign in"` 으로 30초 타임아웃), 로그인 계정 선택도
`<button>` 이 아니라 텍스트 매칭으로 잡아야 했다. 한 번 알아내면 프로젝트마다 고정값이라
캐시가 값을 하는 전형적인 항목이다.

## 2. 오버레이 해제는 로그인 단계에서 분리한다

공지 팝업을 "로그인 절차의 일부(1회성)"로 다루면 걸린다. 실제로는 **full page load /
네비게이션마다 다시 뜬다.**

```
[2] 홈 공지 팝업 닫힘: True
[3] 공지 팝업 닫힘: False      <- /items/... 로 goto 하니 다시 떠 있음
```

그리고 **그 팝업이 검증 대상 CTA 를 덮고 있었다.** 프로젝트 `CLAUDE.md` 의 "첫 진입 시 공지
팝업이 뜬다"는 문장은 1회성으로 읽히지만 실제 동작은 그렇지 않았다.

| 규칙 | 내용 |
|---|---|
| 위치 | 로그인 단계에서 분리해 **모든 네비게이션 직후 실행되는 멱등 단계**로 둔다 |
| 단언 | 해제를 **가정하지 말고 단언한다** — 클릭 후 실제로 사라졌는지 재확인한다 |
| 폴백 | 안 사라졌으면 다음 후보로 넘어간다: `Escape` → 백드롭 클릭 → 닫기 아이콘 |

**실측** — `[role=dialog] button` 클릭으로 안 닫히고 **`Escape` 로만 닫힌** 페이지가 있었다.
다른 런에서는 `close_notice` 를 세 번 고쳐 썼다(strict-mode 위반 → 미노출 요소 클릭 → 타임아웃).
`[role=dialog]` 로 아예 못 잡은 페이지도 있었다.

## 3. 로케일 전환도 프로젝트 레시피다

**어려운 건 목록이 아니라 전환 방법이다.** 그리고 전환이 조용히 no-op 되면 **거짓 PASS** 가
나온다 — §2-2(서빙 체크아웃)와 **정확히 같은 실패 클래스**(화면은 멀쩡한데 엉뚱한 것을 검증)이며,
대상이 체크아웃이 아니라 로케일일 뿐이다.

**실측** — `localStorage.setItem('i18nextLng', 'ko')` 는 **아무 효과가 없었다.** 초기 로케일
SSOT 는 쿠키였다.

```ts
// apps/web/src/i18n/index.ts — readInitialLocale()
const match = document.cookie.match(new RegExp(`(?:^|; )${localeCookieName}=([^;]*)`));
// localeCookieName = "NEXT_LOCALE"  (src/i18n/locales.ts)
```

증상이 고약하다. 전환이 실패해도 **스크립트는 정상 종료**하고 두 로케일 런이 같은 영어 화면을 낸다.

```
===== /trends [ko] =====
Connects with the #audit tag you viewed and is used by 5 people in Support.
===== /trends [en] =====
Connects with the #audit tag you viewed and is used by 5 people in Support.
```

여기서 멈췄으면 **"ko/en 동일 문자열"을 검증 결과로 보고할 뻔했다.** 쿠키 방식으로 고치고 단언을
추가한 뒤:

```
[ko] 내가 본 #audit 태그와 맞고 지원팀에서도 5명이 쓰는 도구입니다.
[en] Connects with the #audit tag you viewed and is used by 5 people in Support.
```

### 3-1. 단언 (없으면 정지)

전환 후 `document.documentElement.lang`(또는 **그 로케일에서만 나오는 알려진 문자열**)이 실제로
바뀌었는지 확인하고, **안 바뀌면 정지한다.** 단언 없는 전환은 거짓 PASS 를 만든다.

### 3-2. 적용 순서 제약

쿠키를 **로그인 전에** 심으면 흐름이 깨진다. 실측: IdP 가 다른 origin(`:9900`)이라 컨텍스트
쿠키 주입이 로그인 클릭을 방해했다.

```
로그인 -> 쿠키 주입 -> 재진입
```

이 순서여야 동작했다. **적용 순서도 캐시에 담는다**(`locale.applyOrder`).

## 4. 캐시 파일

경로: `.claude/pr-verify-live.json`

```json
{
  "login": {
    "selector": "a[href^='/api/v1/auth/login']",
    "accountPick": "text=admin"
  },
  "dismiss": {
    "action": ["press:Escape", "click:[role=dialog] button:has-text('확인')", "click:backdrop"],
    "assert": "[role=dialog] 미존재",
    "rerunOn": "navigation"
  },
  "locale": {
    "mechanism": { "type": "cookie", "name": "NEXT_LOCALE" },
    "applyOrder": ["login", "set-cookie", "reload"],
    "assert": "document.documentElement.lang"
  },
  "verifiedAt": "2026-08-06T09:12:00+09:00",
  "verifiedAgainst": "ec61107b5f0c9a3d1b4e7c2a8d5f0913ab6c7d2e"
}
```

| 키 | 담는 것 |
|---|---|
| `login.selector` | 1절에서 성공한 셀렉터 (태그 가정 금지 — `<a>` 였다) |
| `dismiss.action` | 2절 후보 목록. 성공한 것을 앞으로 올린다 |
| `dismiss.rerunOn` | `navigation` — 1회성이 아니다 |
| `locale.mechanism` | 쿠키 이름 / `localStorage` 키 / URL 파라미터 / UI 클릭 경로 중 무엇인지 |
| `locale.applyOrder` | 3-2 의 순서 제약 |
| `verifiedAt` · `verifiedAgainst` | 무효화 판단용 (아래 5절) |

## 5. 무효화

**셀렉터는 썩는다.** 그래서:

- `verifiedAt` + **대상 커밋**(`verifiedAgainst`)을 함께 저장한다.
- **실패 시 캐시를 버리고 재탐색한다 — 캐시 미스로 실패를 끝내지 않는다.** 재탐색이 성공하면
  캐시를 갱신한다.

## 6. 추적 여부

`.claude/pr-verify-live.json` 은 **자격증명이 없는 프로젝트 공용 레시피**다.

- 스킬은 **커밋하지 않는다.**
- `git check-ignore` 로 무시 대상인지 확인한다.

  ```sh
  git check-ignore -q .claude/pr-verify-live.json && echo ignored || echo tracked-candidate
  ```

- 무시 대상이 아니면 리포트 `Created:` 행에 적어 **사용자가 커밋할지 ignore 할지 결정**하게 한다.

레포마다 `.claude/` 추적 정책이 다르다 — 같은 프로젝트 안에서도 `.claude/settings.json` 은 추적,
`.claude/settings.local.json` 은 비추적이다. 스킬이 임의로 정하면 PR 에 잡음이 섞인다.

## 7. 세션 재사용 (`storage_state`)

프로브 5회에 로그인 5회 반복은 낭비다(실측). 그런데 `storage_state` 는 **세션 쿠키 그 자체**라
캐시 파일에 두면 "자격증명을 캐시 파일에 남기지 않는다" 제약과 정면 충돌한다. 확정안:

| 결정 | 내용 |
|---|---|
| 저장 위치 | **런 스코프 임시 파일** (`$TMPDIR` 또는 세션 스크래치패드) |
| 파일 권한 | `umask 077` — mode `0600` 으로 **생성 시점에** 만든다 |
| 경로 규칙 | `pr-verify-live-<PR>-<pid>` 고정 규칙 |
| 캐시 파일 | `.claude/pr-verify-live.json` 에 **절대** 넣지 않는다 |
| 수명 | 스킬 종료 시(정상 · 실패 무관) 삭제 + **시작 시 같은 규칙의 잔여 파일 선청소** |
| 재사용 범위 | 그 실행 안에서만. 다음 실행은 잔여 파일을 재사용하지 않고 새로 로그인한다 |
| 노출 | 리포트 · 로그 · 이슈 본문에 **경로를 남기지 않는다** |

**종료 트랩을 유일한 방어선으로 두지 않는다** — `SIGKILL` · OOM · 전원 차단이면 트랩이 돌지
않아 세션 쿠키가 파일시스템에 무기한 남는다. 그래서 위 표에 두 줄이 더 있다: 생성 시점의
`0600` 이 트랩 부재 시에도 소유자 외 읽기를 막고, **시작 시 선청소**가 지난 실행의 강제
종료를 다음 실행이 회수한다. 재사용의 이득은 한 실행 안의 반복 프로브에서 나오지 실행
간에서 나오지 않으므로, 수명을 실행 단위로 끊어도 잃는 것이 없다.

```sh
# 시작 시 선청소 — 지난 실행이 강제 종료됐어도 여기서 회수된다
rm -f "${TMPDIR:-/tmp}"/pr-verify-live-*-* 2>/dev/null
umask 077   # 이후 생성되는 storage_state 는 0600
```

결과: 자격증명 제약을 유지한 채 로그인 5회 반복이 제거된다.
