# 환경 변이 하 재실행 (F-6)

SKILL.md **Step 5** 를 뒷받침한다. 같은 검증을 **최소 2개 환경**에서 돌려 결과가 갈리는지
본다. 갈리면 그 자체가 발견이다 — "내 기계에서는 통과" 가 정확히 그 갈림이기 때문이다.

## 1. 기본 축은 PATH 정규화 하나다

**항상 도는 축**: 같은 검증을 `PATH=/usr/bin:/bin` 로 다시 돌린다. 목적은 사용자 셸이 심어 둔
**도구 치환을 배제**하는 것이다.

**실측 사례**: 어떤 레포의 `PATH` 위 `grep` 은 GNU grep 이 아니라 **ugrep 7.5.0** 이었다.
ugrep 은 CR 을 흡수해 통과시키고 `/usr/bin/grep`(GNU grep 3.11)은 빗나가므로, **같은 vault 가
기계마다 다른 lint 결과**를 냈다. 기본 `PATH` 로만 돌리면 영원히 안 보인다.

```sh
run_axis_default() { ( cd "$CLONE" && eval "$TEST_CMD" ); }
run_axis_path()    { ( cd "$CLONE" && PATH=/usr/bin:/bin eval "$TEST_CMD" ); }
```

축을 돌기 전에 **그 환경에서 실제로 어떤 도구가 잡히는지 기록**한다. 이것이 없으면 결과가
갈렸을 때 원인을 사후에 못 짚는다.

```sh
for tool in grep sed awk sort date; do
    printf '%s: %s (%s)\n' "$tool" "$(command -v "$tool")" \
        "$("$tool" --version 2>/dev/null | head -1)"
done
```

기록한 도구 목록은 리포트 `Matrix:` 행의 근거로 쓰고, 결과가 갈린 축의 이슈 본문에 그대로
싣는다.

**주의**: 정규화된 PATH 에서는 `uv` · `node` · `bats` 같은 러너 자체가 사라질 수 있다. 그때는
그 축을 실패로 보지 않는다 — `Unverified: path axis (runner not on /usr/bin:/bin)` 로 적고,
러너에 의존하지 않는 검사(grep/sed 기반 lint, CLI 진입점 직접 호출)만 그 축에서 돌린다.

## 2. 후보 축은 diff 에서 유도한다 (기본은 실행하지 않는다)

`--matrix auto`(기본)는 **PATH 축만 실행**한다. 나머지는 diff 에서 유도해 **후보로 리포트에
적기만** 하고, 실행은 `--matrix full` 이거나 `--env` 로 지목했을 때만 한다.

이렇게 나눈 이유: 지금 실측으로 확실한 축은 PATH 하나뿐이다. 나머지를 기본으로 돌리면 비용은
확실하고 이득은 추정이다. 대신 **후보를 숨기지 않고 리포트에 남겨** 다음 사람이 `--matrix
full` 로 한 번 더 돌릴지 판단하게 한다.

| 축 | diff 신호 | 변이 | 실패 유형 |
|---|---|---|---|
| `path` | 항상 | `PATH=/usr/bin:/bin` | 도구 치환(ugrep/busybox/gnu vs bsd) |
| `locale` | 비ASCII 문자열 · `sort`/`tr`/`date` · 정규식 문자클래스 | `LC_ALL=C` vs `LC_ALL=ko_KR.UTF-8` | 정렬 순서 · 대소문자 · 자모 매칭 |
| `shell` | `#!/bin/sh` 스크립트 변경 · bash 전용 문법 추가 | `bash <script>` vs `sh <script>`(dash) | bashism 이 dash 에서 깨짐 |
| `eol` | CR/CRLF 처리 · 픽스처 텍스트 파일 · `.gitattributes` | 픽스처 사본을 CRLF 로 변환해 재실행 | CR 흡수/누락 |

`--env <csv>` 는 `--matrix` 보다 우선한다 — `--env path,eol` 이면 그 둘만 돈다.

축 사이에 의존성은 없다 — 각자 같은 클론을 읽기 전용으로 쓰거나(`path`/`locale`/`shell`) 자기
사본에서 돈다(`eol`). `--matrix full` 이나 `--env` 로 축이 둘 이상 선택되면 **병렬로 실행**한다 —
순차 실행은 축 수만큼 시간이 늘어난다.

```sh
# locale 축은 로케일이 실제로 설치돼 있을 때만 의미가 있다
locale -a 2>/dev/null | grep -qi '^ko_KR\.utf-\?8$' || axis_unverified locale "ko_KR.UTF-8 not installed"
# eol 축은 클론을 건드리지 않고 사본에서 돈다
cp -r "$CLONE" "$CLONE.eol" && find "$CLONE.eol" -name '*.md' -exec sed -i 's/$/\r/' {} +
```

## 3. 결과 비교는 정규화해서 한다

원시 stdout 을 그대로 비교하면 경로·타임스탬프·소요시간 때문에 항상 다르다. 비교 대상은
**(exit code, 통과/실패 케이스 이름 집합, 케이스 개수)** 세 가지다.

- 세 값이 모두 같으면 그 축은 `agree`.
- 하나라도 다르면 **발견 후보**다 — Step 7 의 자기 반증(특히 "환경 특수성" 가설)을 통과해야
  이슈가 된다. 통과하면 이슈 제목은 `<검사>가 환경에 따라 결과가 갈린다 (<축>)` 형태로 쓰고,
  본문에 두 환경의 도구 버전 목록을 함께 싣는다.

## 4. 소프트 실패 경계 (NF-3)

**환경 축 1개가 실패해도 전체를 정지시키지 않는다.** 로케일 미설치 · 러너 부재 · dash 없음은
그 축만 `unverified` 로 적고 나머지 축과 다음 단계를 계속한다. 하드 정지는 F-2/F-3 단언
뿐이다.

리포트에는 **실제로 돈 축만** `Matrix:` 에 적고, 돌지 못한 축은 이유와 함께 `Unverified:` 로
간다. 후보였지만 기본값이라 안 돈 축은 `Matrix:` 행 끝에 `(candidates not run: locale, eol —
use --matrix full)` 로 남긴다. 축을 줄인 사실을 숨기면 리포트가 실제보다 강해 보인다.
