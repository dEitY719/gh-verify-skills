# Step 5 `defer` — `reply-pending` 라벨 부착 (soft-fail)

Applies **only on the `defer` branch**. `inline` never defers anything and
`none` never replies, so neither has a pending state to mark.

## 왜 라벨인가 (dEitY719/dotfiles#1524)

`gh-pr:merge-train` 의 D-6 조용한 기간(11분)은 "지연된 리뷰 답변 패스가 끝났는가"
를 **시간으로 대신 물어본 것**이다. 답변 패스가 11분을 넘기면 창이 먼저 닫히고,
train 은 답변·`/simplify` 수정이 아직 날아오는 중인 PR 을 머지한다 (PR dEitY719/dotfiles#1522).

이 라벨이 그 질문의 **진짜 신호**다. 라벨이 붙어 있는 동안 train 은 경과 시간과
무관하게 그 PR 을 건너뛴다 (`_gh_pr_merge_train_filter_targets`). 조용한 기간은
라벨이 없는 PR(수동 생성, 다른 도구 생성)과 라벨을 떼기 전에 죽은 세션을 위한
**백스톱**으로만 남는다.

떼는 쪽은 `gh-pr:reply` Step 6 — 지연 예약이든 인라인이든 무조건 제거한다.

## 순서: label create → label add

`_gh_pr_edit_safe_label` 은 repo 에 없는 라벨을 만나면 **REST fallback 을 거부하고
rc 3** 을 돌려준다 (자동 생성 금지, #326). 그러니 붙이기 전에 라벨이 존재하도록
멱등 생성부터 한다 — 이미 있으면 `gh label create` 가 에러를 내지만 무시한다.

`Skill(session:schedule, ...)` 예약은 이 블록의 성공 여부와 무관하게 **반드시**
실행한다. 라벨은 안전망이고, 답변 패스 자체가 본체다.

`TARGET_REPO` 는 Step 2 가 이미 잡아 둔 값이다. `TARGET_HOST` 는 이 스킬이 따로
export 하지 않으므로, 같은 `<remote>` URL 에서 여기서 한 번 뽑는다 — repo 와 host
가 **같은 URL 한 개**에서 나와야 서로 어긋나지 않는다 (dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407).

```bash
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/gh_pr_edit_safe.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }
source "$_SC/functions/gh_pr_edit_safe.sh"
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/gh_host.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }
source "$_SC/functions/gh_host.sh"

# 0) host 고정 — repo 와 같은 remote URL 에서, 실패하면 setup-mode 기본값
TARGET_HOST="${TARGET_HOST:-$(_gh_host_from_url "$(git remote get-url "$remote")" 2>/dev/null)}"
[ -n "$TARGET_HOST" ] || TARGET_HOST=$(_gh_resolve_host)

# 1) 라벨 보장 (멱등 — 이미 있으면 "already exists" 로 실패하고, 무시한다)
GH_HOST="$TARGET_HOST" gh label create "reply-pending" --repo "$TARGET_REPO" \
    --color "fbca04" \
    --description "지연된 리뷰 답변 패스가 아직 남아 있는 PR — merge-train 이 건너뛴다 (dEitY719/dotfiles#1524)" \
    >/dev/null 2>&1 || true

# 2) 부착 (soft-fail — 실패해도 예약은 그대로 진행)
if _gh_pr_edit_safe_label "$pr" "reply-pending" --repo "$TARGET_REPO"; then
    echo "[OK] \`reply-pending\` 라벨 부착 — merge-train 이 이 PR 을 건너뛴다"
else
    echo "[WARN] \`reply-pending\` 라벨 부착 실패 — D-6 조용한 기간이 백스톱으로 남는다"
fi
```

`GH_HOST="$TARGET_HOST"` + `--repo "$TARGET_REPO"` 는 생략 불가다: 두 호스트에
로그인된 상태에서 맨 `gh` 는 `gh repo set-default` 가 고른 **엉뚱한 서버**에
라벨을 만든다 (dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407).
