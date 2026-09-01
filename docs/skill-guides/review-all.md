# gh-verify:review-all

> 한 줄 요약 — PR 하나에 가용한 모든 리뷰어를 병렬로 붙여 집계 판정을 머지 게이트 라벨로 남기고, 이어서 리뷰 코멘트 답변 패스까지 돌린다.

## 언제 쓰는가

- 머지 **전** 정적 리뷰 게이트가 필요할 때. PR 하나에 `agy` · `codex` · `opencode` · `hermes` 2차 의견과
  `/simplify` auto-fix 패스를 **한 번에** 돌리고 싶을 때 쓴다.
- 리뷰어를 하나만 돌리려면 이 스킬이 아니라 `gh:pr-review` 다. 이 스킬은 그 위에 얹힌 조합(composition)
  스킬로, 여러 리뷰어 + 답변 패스를 오케스트레이션한다.
- 승인/변경요청 결정이 필요하면 `gh:pr-approve` 다. 이 스킬은 판정 라벨만 쓰고 `reviewDecision` 은
  건드리지 않는다.
- 머지 **후** 실물 검증은 `gh-verify:live` / `gh-verify:merged` 의 몫이다.
- `gh:issue-flow` 의 Step 2.4 가 PR 이후 품질 게이트로 이 스킬을 재사용한다.

## 언제 쓰지 않는가

- **단일 리뷰어 실행** — `Not a single-reviewer run (gh:pr-review)`. 리뷰어 하나면 그쪽을 직접 부른다.
- **승인 목적** — `never approves`. `gh pr review --approve` / `--request-changes` 를 제출하지 않는다.
- **머지 목적** — 머지는 하지 않는다. `gh:pr-merge-train` 이 이 스킬이 쓴 라벨을 읽을 뿐이다.
- **`/code-review --fix` 를 대신 돌리는 용도** — Claude Code v2.1.215 이후 사용자 직접 호출 전용이라
  어떤 스킬도 부를 수 없다.
- **초 단위 지연 예약** — `devx:schedule` 은 분 단위만 지원한다.

## 호출

```
/gh-verify:review-all <PR#> [remote] [--defer-reply M] [--no-reply] [--force-review]
```

### Positional

| # | 이름 | 기본값 | 설명 |
|---|------|--------|------|
| 1 | PR number, 또는 `-h`/`--help`/`help` | 없음 (필수) | 대상 PR, 예 `99` |
| 2 | remote name | `origin` | 대상 레포를 해석할 git remote |

### Flags

| Flag | 기본값 | 설명 |
|------|--------|------|
| `--defer-reply M` / `--defer-reply=M` | off (inline) | 인라인 답변 대신 `devx:schedule` 로 `/gh-pr-reply` 를 M **분** 뒤에 예약 |
| `--no-reply` | off | 답변 단계를 통째로 건너뛴다 |
| `--force-review` | off | 중복 리뷰 가드를 우회해 모든 리뷰어 레인(agy/codex/opencode/hermes)을 현재 head sha 가 이미 리뷰됐어도 재실행. `/simplify` 는 이 플래그와 무관하게 항상 돈다 |
| `-h` / `--help` / `help` | — | 도움말 출력 후 정지 |

`--defer-reply` 와 `--no-reply` 를 같이 주면 `--no-reply` 가 이긴다(답변 생략).

### Exit codes

| Code | 원인 |
|------|------|
| 0 | 리뷰 게이트가 돌고 답변 단계가 완료/예약/생략됨 |
| 1 | PR 이 `OPEN`/non-draft 가 아니거나 `gh` 미인증 |
| 2 | 인자 오류: `<PR#>` 누락, 정수 아님, 모르는 플래그, 잘못된 `--defer-reply` 값 |

## 동작 단계

1. **Step 1 — 인자 파싱.** `devx_pr_review_all_parse` 에 위임해 `pr` `remote` `reply_mode` `reply_delay`
   `force_review` `START_TS` 를 캡처한다.
2. **Step 2 — Pre-flight.** `TARGET_REPO` 해석, PR 이 `OPEN` 이고 draft 아님을 확인, `gh auth status` 확인,
   PR head 브랜치가 아니면 `gh pr checkout` 한다(`/simplify` 가 올바른 트리에서 돌게).
3. **Step 3 — 리뷰 + auto-fix 게이트.** 먼저 중복 리뷰 가드로 현재 head sha 를 이미 리뷰한 레인을 건너뛴 뒤,
   남은 레인과 auto-fix 패스를 **한 턴에 병렬** 디스패치한다 — agy · codex · opencode · hermes 는
   `gh:pr-review --ai <name>` 에 위임하는 코멘트 전용이고, `/simplify` 는 워킹 트리를 고쳐 스스로 커밋한다.
   각 레인은 soft-fail 이다.
4. **Step 3.5 — 판정 집계와 머지 게이트 라벨.** **모든 레인이 복귀한 뒤, Step 4 의 push 전에** 돈다. 레인들의
   마감 판정 줄을 모아 라벨을 쓰되, #1636 이후 이 스킬이 쓰는 라벨은 `review-blocked` 뿐이다. 전 레인 비차단이면
   묵은 `review-blocked` 만 지우고 멈춘다. soft-fail — 라벨 실패가 이후 단계를 막지 않는다.
5. **Step 4 — auto-fix 커밋 push.** `/simplify` 가 커밋했을 때만 `git push`. push 했다면 `review-passed` 를
   즉시 떼어낸다(리뷰되지 않은 커밋 위에 판정이 남지 않도록). `review-blocked` 는 여기서 절대 떼지 않는다.
6. **Step 5 — 답변 패스.** `inline`(기본)은 `gh:pr-reply` 즉시 실행, `defer` 는 `reply-pending` 라벨을 먼저
   붙이고 `devx:schedule` 로 예약, `none` 은 생략.
7. **Step 6 — 보고.** `[OK]`/`[SKIP]`/`[WARN]` 한 줄을 출력하고, 끝에 Step 3.5 의 결과
   (`review-passed` / `review-blocked` / `unlabelled`)를 붙인다.

## 주의사항

- **승인하지 않는다.** approve / request-changes 결정은 이 스킬 밖(`gh:pr-approve`)이다. 판정 라벨은
  머지 트레인 게이트일 뿐 승인이 아니다.
- **Step 3 의 병렬성과 Step 3.5 의 순서는 동작 계약이다.** 다섯 레인은 한 턴에 함께 디스패치되고, 집계는 모든
  레인 복귀 후·push 전에 돈다. 순서를 바꾸면 라벨이 새 sha 를 읽어 게이트가 조용히 무력화된다.
- 리뷰어 레인은 전부 soft-fail — CLI 가 없거나 에러가 나도 hard-fail 하지 않는다.
- `/code-review` 를 추가하지 않는다. bare `git commit` 을 돌리지 않는다(비인터랙티브 셸이 에디터에서 멈춘다).
- `--defer-reply` 는 분 단위이며 보장이 아니다. 타이밍이 중요하면 결정적인 inline 답변을 쓴다.
- 이 스킬은 `review-blocked` 의 **유일한** 기록자이고 `review-passed` 는 쓰지 않는다 — 그 라벨은
  `gh:pr-reply` Step 6 의 몫이고, 둘 다 `gh:pr-merge-train` 만 읽는다.
