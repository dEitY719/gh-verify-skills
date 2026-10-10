# gh-verify:review-all

> 한 줄 요약 — PR 하나에 가용한 모든 리뷰어를 병렬로 붙여 집계 판정을 머지 게이트 라벨로 남기고, 이어서 리뷰 코멘트 답변 패스까지 돌린다.

## 언제 쓰는가

- 머지 **전** 정적 리뷰 게이트가 필요할 때. 실행 중인 하네스가 먼저 PR 을 스스로 리뷰해 고치고(self-fix
  패스), 그 head 위로 `claude` · `codex` · `opencode` · `agy` · `hermes` 2차 의견을 **한 번에** 받고 싶을 때
  쓴다. 하네스 무관(gh-verify-skills#77) — Claude Code 가 아니어도 돈다.
- 리뷰어를 하나만 돌리려면 이 스킬이 아니라 `gh-pr:review` 다. 이 스킬은 그 위에 얹힌 조합(composition)
  스킬로, 여러 리뷰어 + 답변 패스를 오케스트레이션한다.
- 승인/변경요청 결정이 필요하면 `gh-pr:approve` 다. 이 스킬은 판정 라벨만 쓰고 `reviewDecision` 은
  건드리지 않는다.
- 머지 **후** 실물 검증은 `gh-verify:live` / `gh-verify:merged` 의 몫이다.
- `gh-flow:issue` 의 Step 2.4 가 PR 이후 품질 게이트로 이 스킬을 재사용한다.

## 언제 쓰지 않는가

- **단일 리뷰어 실행** — `Not a single-reviewer run (gh-pr:review)`. 리뷰어 하나면 그쪽을 직접 부른다.
- **승인 목적** — `never approves`. `gh pr review --approve` / `--request-changes` 를 제출하지 않는다.
- **머지 목적** — 머지는 하지 않는다. `gh-pr:merge-train` 이 이 스킬이 쓴 라벨을 읽을 뿐이다.
- **`/code-review --fix` 를 단독으로 돌리는 용도** — Claude Code v2.1.215 이후 사용자 직접 호출 전용이라
  `Skill()` 로는 부를 수 없다. 이 스킬은 Step 2.5 self-fix 에서만 별도 `claude -p` 자식 프로세스로 돌린다.
- **초 단위 지연 예약** — `session:schedule` 은 분 단위만 지원한다.

## 호출

```
/gh-verify:review-all <PR#> [remote] [--defer-reply M] [--no-reply] [--force-review] [--lanes L]
```

### Positional

| # | 이름 | 기본값 | 설명 |
|---|------|--------|------|
| 1 | PR number, 또는 `-h`/`--help`/`help` | 없음 (필수) | 대상 PR, 예 `99` |
| 2 | remote name | `origin` | 대상 레포를 해석할 git remote |

### Flags

| Flag | 기본값 | 설명 |
|------|--------|------|
| `--defer-reply M` / `--defer-reply=M` | off (inline) | 인라인 답변 대신 `session:schedule` 로 `/gh-pr:reply` 를 M **분** 뒤에 예약 |
| `--no-reply` | off | 답변 단계를 통째로 건너뛴다 |
| `--lanes L` / `--lanes=L` | `claude:default,codex:default,opencode:default,agy:default,hermes:default` | 쉼표로 구분한 `<ai>:<preset>` 레인. 전부 한 번의 `devx_pr_review_all_fanout` 호출로 병렬 실행된다. 같은 AI 의 두 preset 은 독립 레인 둘이다(gh-verify-skills#56) |
| `--force-review` | off | 중복 리뷰 가드를 우회해 `--lanes` 의 모든 레인을 현재 head sha 가 이미 리뷰됐어도 재실행. Step 2.5 self-fix 패스는 이 플래그와 무관하게 항상 먼저 돈다(트리가 더러우면 `self:<SELF>:skip(dirty)`, `simplify:skip`) |
| `-h` / `--help` / `help` | — | 도움말 출력 후 정지 |

`--defer-reply` 와 `--no-reply` 를 같이 주면 `--no-reply` 가 이긴다(답변 생략).

### Exit codes

| Code | 원인 |
|------|------|
| 0 | 리뷰 게이트가 돌고 답변 단계가 완료/예약/생략됨 |
| 1 | PR 이 `OPEN`/non-draft 가 아니거나 `gh` 미인증 |
| 1 | Step 2.5 self-fix 커밋의 `git push` 실패 — 리뷰어 레인을 하나도 디스패치하지 않고 멈춘다 |
| 2 | 인자 오류: `<PR#>` 누락, 정수 아님, 모르는 플래그, 잘못된 `--defer-reply` 값, 잘못된 `--lanes` 목록 |

## 동작 단계

1. **Step 1 — 인자 파싱.** `devx_pr_review_all_parse` 에 위임해 `pr` `remote` `reply_mode` `reply_delay`
   `force_review` `lanes` `START_TS` 를 캡처한다.
2. **Step 2 — Pre-flight.** `TARGET_REPO` 해석, PR 이 `OPEN` 이고 draft 아님을 확인, `gh auth status` 확인,
   PR head 브랜치가 아니면 `gh pr checkout` 한다(self-fix 패스가 올바른 트리에서 돌게).
3. **Step 2.4 — SELF 바인딩.** 모델이 자기 하네스를 선언한다 — `SELF` = `claude|codex|opencode|agy|hermes`,
   모르면 `unknown`. 환경변수로 추측하지 않는다. `unknown` 이면 self-fix 만 건너뛰고
   (`self:unknown:skip(unidentified harness)`) 팬아웃은 그대로 돈다.
4. **Step 2.5 — self-fix 패스 (쓰기 단계, 리뷰보다 먼저, 한 번에 하나씩).** 워킹 트리를 쓰는 단계는 이것뿐이라
   리뷰어 팬아웃보다 **먼저 혼자** 돈다(dEitY719/gh-verify-skills#18, #77). 트리가 clean 이 아니면 패스 전체를
   건너뛴다. `SELF=claude` 면 `claude -p "/code-review high --fix <base>"` 자식 프로세스가 찾은 문제를 고치고,
   이어서 edit-only `/simplify` Agent 하나가 정리한다. 다른 하네스는 세션이 직접 `gh pr diff` 를 `thorough`
   preset 기준으로 리뷰해 유효한 문제만 **파일 편집으로** 고친다(`/simplify` 는 Claude Code 내장이라
   `simplify:n/a`). 쓰기 주체는 `git revert`/`reset`/`commit`/`push` 를 하지 않고, 자기가 만들지 않은 hunk 는
   손대지 않는다. 커밋은 단계마다 오케스트레이터가 따로 한다(`fix(<scope>): apply self-review findings
   (<SELF>)`, `refactor(<scope>): simplify per /simplify`; `git add -A && git commit -m`). 단계 뒤 트리가
   더러우면 `[WARN]` 을 찍고 커밋하지 않은 채 둔다. push 는 마지막에 **한 번**이고(upstream 이 없으면
   `git push -u <remote> HEAD`), push 했으면 묵은 `review-passed` 를 떼어낸다. **push 가 실패하면 리뷰어를 하나도
   디스패치하지 않고 exit 1** — 이 스킬의 유일한 hard-fail 이다. 리뷰어가 낡은 remote head 를 읽게 되기 때문이다.
5. **Step 3 — 리뷰어 팬아웃.** 먼저 중복 리뷰 가드로 현재 head sha 를 이미 리뷰한 레인을 건너뛴 뒤, 남은
   `<ai>:<preset>` 레인을 **한 번의 셸 호출**(`devx_pr_review_all_fanout`)로 동시에 돌린다. 기본 레인은
   claude · codex · opencode · agy · hermes 다섯이고, 모두 `gh-pr:review --ai <ai> --review <preset>` 에
   위임하는 **코멘트 전용**이라 워킹 트리를 건드리지 않는다(레인당 540초 상한). PC 구분은 없다 — 모든 레인을
   시도하고, 어떤 이유로든(CLI 없음, 402, 네트워크, 타임아웃) 에러가 난 레인은 `skip` 으로 끝난다.
6. **Step 3.4 — orphan 정리.** 레인이 남긴 자식 프로세스를 찾아 `[WARN]` 으로 보고만 하고 죽이지 않는다.
7. **Step 3.5 — 판정 집계와 머지 게이트 라벨.** **모든 레인이 복귀한 뒤** 돈다. 이 뒤로는 push 가 없으므로
   여기서 읽는 head sha 는 레인들이 리뷰한 sha 그대로다. `ok` 레인의 마감 판정 줄만 모으고, `skip` 레인은
   판정에 아무것도 넣지 않는다(#77 D-5). #1636 이후 이 스킬이 쓰는 라벨은 `review-blocked` 뿐이다. 전 레인
   비차단이면 묵은 `review-blocked` 만 지우고 멈춘다. soft-fail — 라벨 실패가 이후 단계를 막지 않는다.
8. **Step 4 — 트리 clean 확인.** push 는 Step 2.5 에서 이미 끝났다. 여기서는 `git status --porcelain` 이
   비어 있는지만 확인하고, 더러우면 `[WARN]` 만 남기고 커밋하지 않는다(작성자를 알 수 없는 hunk 이므로).
9. **Step 5 — 답변 패스.** `inline`(기본)은 `gh-pr:reply` 즉시 실행, `defer` 는 `reply-pending` 라벨을 먼저
   붙이고 `session:schedule` 로 예약, `none` 은 생략.
10. **Step 6 — 보고.** `[OK]`/`[SKIP]`/`[WARN]` 한 줄에 레인별 결과(`<ai>:OK` / `<ai>:SKIP(<reason>)`),
    `self:<SELF>:<결과>`, `simplify:<결과>` 를 싣고, 끝에 Step 3.5 의 결과(`review-blocked` / `unlabelled`)를
    붙인다. 예: `(claude:OK codex:SKIP(402 deactivated_workspace) … self:claude:fixed simplify:clean)`.
    레인 에러만으로는 `[WARN]` 이 되지 않는다 — `[WARN]` 원인은 Step 4 의 dirty tree, orphan, 라벨 쓰기
    실패뿐이다.

## 주의사항

- **승인하지 않는다.** approve / request-changes 결정은 이 스킬 밖(`gh-pr:approve`)이다. 판정 라벨은
  머지 트레인 게이트일 뿐 승인이 아니다.
- **Step 3 의 병렬성과 self-fix 쓰기 단계의 단독 선행은 동작 계약이다.** 리뷰어 레인 다섯은 한 번의 셸
  호출로 함께 돌고, `/code-review` self-fix 와 `/simplify` 는 그보다 앞서 Step 2.5 에서 하나씩 돈다. 쓰기
  단계를 리뷰어와 같은 시점에 되돌려 넣으면 워킹 트리를 두 프로세스가 동시에 쓰게 되어, 리뷰 수정본이 되돌려지는 사고가 다시 열린다
  (dEitY719/gh-verify-skills#18).
- 리뷰어 레인은 전부 soft-fail — CLI 가 없거나 에러가 나도 hard-fail 하지 않는다. 에러 난 레인은 보고
  줄에 `<ai>:SKIP(<reason>)` 로 이름이 남지만 판정에서는 제외된다(#77 D-5, #14 를 뒤집음). 판정은 `ok`
  레인만으로 정해진다.
- `/code-review` 는 Step 2.5 의 `claude -p` 자식으로만 돈다 — `Skill()` 이나 팬아웃 레인으로 부르지 않는다.
  bare `git commit` 을 돌리지 않는다(비인터랙티브 셸이 에디터에서 멈춘다).
- `--defer-reply` 는 분 단위이며 보장이 아니다. 타이밍이 중요하면 결정적인 inline 답변을 쓴다.
- 이 스킬은 `review-blocked` 의 **유일한** 기록자이고 `review-passed` 는 쓰지 않는다 — 그 라벨은
  `gh-pr:reply` Step 6 의 몫이고, 둘 다 `gh-pr:merge-train` 만 읽는다.
