#!/usr/bin/env bats
# tests/bats/gh_pr_post_merge_verify.bats
# Behaviour of the post-merge verification dispatch — the first bash fence of
# skills/post-merge-verify/references/dispatch.sh.md, extracted and run by
# fixtures/gh_pr_post_merge_verify.sh against stand-ins for herdr and git.
# Moved from dEitY719/dotfiles tests/bats/skills/ (dEitY719/dotfiles#2200),
# where it ran against a hand mirror of the fence.
#
# Cases are dEitY719/dotfiles#1511's acceptance criteria and error cases:
#   A-1  unregistered repo      -> no output, no herdr call
#   A-2  registered repo        -> close, rebase, pr-<N> tab, verify prompt
#   A-3  main rebase conflict   -> WARN only, and NO tab is created
#   A-4  impl tab not found     -> rebase + tab + verify still run
#   A-5  herdr not installed    -> the whole skill is a silent no-op
#   E-1  registry missing       -> silent no-op
#   E-2  registry malformed     -> one WARN, feature skipped
#   E-3  main checkout dirty    -> WARN, abort before tab creation
#   E-4  tab create fails       -> WARN, no agent start
#   E-5  agent start fails      -> WARN, no prompt
#   E-6  agent_name_taken       -> WARN, but the existing session IS prompted
#   E-7  prompt fails           -> WARN, report still prints
# dotfiles PR #1518 review hardening:
#   R-1  main checkout on the wrong branch / detached  -> WARN, no rebase
#   R-2  remote + base branch are threaded, never hardcoded origin/main
#   R-3  the verification skill is allowlisted before any herdr mutation, but only
#        once herdr itself is present (no herdr => silent, AC-5)
#   R-4  MAIN_ROOT must resolve to a git worktree root
#   R-5  a sibling path must not match the tab prefix
#   R-7  "herdr unreachable" and "nothing running" are different lines
#   R-8  no jq -> the feature is unavailable, silently
# Plus #1554 / #1571 / #1577 / #1605 and dEitY719/gh-verify-skills#33 (#1820).
# The prompt retry / landed-probe matrix (#85) is tests/dispatch-prompt-retry.sh.

load 'test_helper'

setup() {
    setup_isolated_home
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/tests/bats/fixtures/gh_pr_post_merge_verify.sh"

    WATCHED="${TEST_TEMP_HOME}/watched-repos.json"
    cat >"$WATCHED" <<'JSON'
[
  { "repo": "acme/dotfiles", "post_merge_verify": true },
  { "repo": "acme/webapp", "post_merge_verify": true, "post_merge_verify_skill": "gh-verify:live" }
]
JSON

    # T_MAIN, not MAIN_ROOT: the fence assigns MAIN_ROOT itself.
    T_MAIN="${TEST_TEMP_HOME}/dotfiles"
    T_IMPL="${TEST_TEMP_HOME}/dotfiles-issue-77-1"

    FAKE_HERDR_LOG="${TEST_TEMP_HOME}/herdr.log"
    FAKE_GIT_LOG="${TEST_TEMP_HOME}/git.log"
    : >"$FAKE_HERDR_LOG"
    : >"$FAKE_GIT_LOG"

    FAKE_WORKTREE_PORCELAIN="worktree ${T_MAIN}
HEAD aaaa
branch refs/heads/main

worktree ${T_IMPL}
HEAD bbbb
branch refs/heads/wt/issue-77/1
"
    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"${T_IMPL}\",\"foreground_cwd\":\"${T_IMPL}\",\"tab_id\":\"wV:t42\",\"pane_id\":\"wV:p42\"}]}}"
    FAKE_HERDR_OUT_WORKTREE_LIST="{\"result\":{\"source\":{\"repo_root\":\"${T_MAIN}\",\"source_workspace_id\":\"wV\"},\"worktrees\":[{\"path\":\"${T_MAIN}\",\"open_workspace_id\":\"wV\"}]}}"
    FAKE_HERDR_OUT_TAB_CREATE='{"result":{"tab":{"tab_id":"wV:t99"},"pane":{"pane_id":"wV:p99"}}}'
    FAKE_HERDR_OUT_AGENT_START='{"result":{"agent":{"agent_status":"idle"}}}'
    FAKE_HERDR_OUT_AGENT_PROMPT='{"result":{"agent":{"agent_status":"idle"}}}'
    unset CLAUDE_CONFIG_DIR PMV_PROMPT_TIMEOUT_MS PMV_SETTLE_SECONDS PMV_PROMPT_ATTEMPT_MAX
}

teardown() {
    teardown_isolated_home
}

dispatch() { pmv_dispatch 77 "${1-acme/dotfiles}" "${2-}" "${3-}"; }

_pmv_log_line() { grep -n -- "$1" "$FAKE_HERDR_LOG" | head -1 | cut -d: -f1; }
_pmv_log_count() { grep -c -- "$1" "$FAKE_HERDR_LOG" || true; }

# --- F-1: the watched-repos.json gate -------------------------------------

@test "gate: post_merge_verify true with no skill key defaults to gh-verify:merged (#93)" {
    run dispatch
    assert_success
    assert_output --partial "verify: /gh-verify:merged 77"
}

@test "gate: per-repo post_merge_verify_skill is honoured, gh-verify:live included (#93)" {
    run dispatch acme/webapp
    assert_success
    assert_output --partial "verify: /gh-verify:live 77"
}

@test "gate: an unregistered repo is silent" {
    run dispatch other/repo
    assert_success
    assert_output ""
}

@test "gate: a missing registry skips silently, it does not warn" {
    WATCHED="${TEST_TEMP_HOME}/nope.json"
    run dispatch
    assert_success
    assert_output ""
}

@test "gate: with IW_WATCHED_REPOS unset the default ~/.avatars registry is read (#91)" {
    mkdir -p "${HOME}/.avatars/issue-watcher"
    mv "$WATCHED" "${HOME}/.avatars/issue-watcher/watched-repos.json"
    WATCHED=""
    run dispatch
    assert_success
    assert_output --partial "verify: /gh-verify:merged 77"
}

@test "gate: malformed JSON warns" {
    printf 'not json at all\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "is not valid JSON"
}

# --- #1820: an unbound registry key is a broken caller, not an opt-out ----
#
# `select(.repo == "")` matches nothing, so without the fence's
# `[ -z "${TARGET_REPO:-}" ]` arm an empty key would read as an unregistered
# repo and disable verification for every repo without a word
# (dEitY719/gh-verify-skills#33).

@test "1820: an unbound repo key warns, distinct from an unregistered repo" {
    run dispatch ""
    assert_success
    assert_output --partial "TARGET_REPO is unbound"
}

@test "1820: the unbound check precedes the jq and readability probes" {
    # A machine without jq, or a missing file, must not turn the broken-caller
    # signal back into a silent skip.
    WATCHED="${TEST_TEMP_HOME}/nope.json"
    FAKE_JQ_PRESENT=0 run dispatch ""
    assert_success
    assert_output --partial "TARGET_REPO is unbound"
}

@test "1820: a whitespace-only repo key is a lookup miss, not an unbound caller" {
    # `[ -z "   " ]` is false, so it reaches the registry, matches nothing and
    # stays silent (agy review, dotfiles PR #1823).
    run dispatch "   "
    assert_success
    assert_output ""
}

@test "1820: an unbound repo warns once and touches nothing" {
    run dispatch ""
    assert_success
    [ "$(grep -c WARN <<<"$output")" -eq 1 ]
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
    run cat "$FAKE_GIT_LOG"
    assert_output ""
}

@test "gate: an entry present but with no post_merge_verify is a silent no-op (#1555, #93)" {
    # issue-watcher may track a repo this skill never verifies.
    printf '[{"repo":"acme/dotfiles","path":"/x","post_merge_verify_skill":"gh-verify:live"}]\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output ""
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "gate: post_merge_verify false (or a non-boolean) opens no tab (#93)" {
    local _v
    for _v in false '"true"' null; do
        printf '[{"repo":"acme/dotfiles","post_merge_verify":%s}]\n' "$_v" >"$WATCHED"
        run dispatch
        assert_success
        assert_output ""
    done
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "gate: an empty post_merge_verify_skill falls back to the default (#93)" {
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"post_merge_verify_skill":""}]\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "verify: /gh-verify:merged 77"
}

# --- #93: the legacy verify_skill key is a fallback with one [WARN] ---------

@test "legacy: verify_skill alone still dispatches, with exactly one migration WARN (#93)" {
    printf '[{"repo":"acme/webapp","verify_skill":"gh-verify:live"}]\n' >"$WATCHED"
    run dispatch acme/webapp
    assert_success
    assert_output --partial "verify: /gh-verify:live 77"
    assert_output --partial "acme/webapp uses the legacy \"verify_skill\" key"
    [ "$(printf '%s\n' "$output" | grep -c 'legacy "verify_skill"')" -eq 1 ]
}

@test "legacy: the new schema prints no migration WARN (#93)" {
    run dispatch acme/webapp
    assert_success
    refute_output --partial "legacy"
}

@test "legacy: post_merge_verify, even false, wins over verify_skill (#93)" {
    printf '[{"repo":"acme/dotfiles","post_merge_verify":false,"verify_skill":"gh-verify:merged"}]\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output ""
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"verify_skill":"gh-verify:live"}]\n' >"$WATCHED"
    run dispatch
    assert_output --partial "verify: /gh-verify:merged 77"
    refute_output --partial "legacy"
}

@test "legacy: with no herdr the fallback stays silent (AC-5, #93)" {
    printf '[{"repo":"acme/dotfiles","verify_skill":"gh-verify:merged"}]\n' >"$WATCHED"
    FAKE_HERDR_PRESENT=0
    run dispatch
    assert_success
    assert_output ""
}

@test "legacy: a verify_skill off the allowlist is still refused (#93)" {
    printf '[{"repo":"acme/dotfiles","verify_skill":"evil:do-something-else"}]\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "verify_skill \"evil:do-something-else\" for acme/dotfiles is not one of"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "gate: the object-wrapped {repos:[...]} shape is read too (agy review, #1555)" {
    printf '{"repos":[{"repo":"acme/dotfiles","post_merge_verify":true}]}\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "verify: /gh-verify:merged 77"
}

@test "main root: the object-wrapped {repos:[...]} shape resolves path too (#1555)" {
    printf '{"repos":[{"repo":"acme/dotfiles","post_merge_verify":true,"path":"~/elsewhere"}]}\n' >"$WATCHED"
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "toplevel ${HOME}/elsewhere"
}

# --- A-1 / A-5 / E-1 / E-2: the no-op paths -------------------------------

@test "A-1: an unregistered repo makes no herdr call at all" {
    run dispatch other/repo
    assert_success
    assert_output ""
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "E-1: a missing registry is a silent no-op" {
    WATCHED="${TEST_TEMP_HOME}/nope.json"
    run dispatch
    assert_success
    assert_output ""
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "E-2: a malformed registry warns once and skips the feature" {
    printf '{ oops\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "is not valid JSON"
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "A-5: herdr not installed -> the whole skill is a silent no-op" {
    FAKE_HERDR_PRESENT=0
    run dispatch
    assert_success
    assert_output ""
    run cat "$FAKE_GIT_LOG"
    assert_output ""
}

# --- A-2: the happy path ---------------------------------------------------

@test "A-2: registered repo closes the impl tab, rebases, opens pr-<N>, verifies" {
    run dispatch
    assert_success
    assert_output --partial "closed implementation tab wV:t42"
    assert_output --partial "[OK] post-merge verification dispatched"
    assert_output --partial "tab:    wV:t99 (label pr-77)"
    assert_output --partial "agent:  mv-dotfiles-pr-77"
    assert_output --partial "attach: herdr agent attach mv-dotfiles-pr-77"

    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "herdr tab close wV:t42"
    # `--cwd` is the PR's own detached worktree, never the shared main checkout
    # (#1577); the 1577 block below pins that in detail.
    assert_output --partial "herdr tab create --workspace wV --cwd ${T_MAIN}/.git/pr-post-merge-verify/pr-77 --label pr-77 --no-focus"
    assert_output --partial "herdr agent start mv-dotfiles-pr-77 --kind claude --pane wV:p99 -- --dangerously-skip-permissions"
    assert_output --partial "herdr agent prompt mv-dotfiles-pr-77 /gh-verify:merged 77 --wait --until idle"
}

@test "A-2: the impl tab is closed BEFORE the verification tab is created" {
    run dispatch
    assert_success
    run bash -c "grep -n 'tab close\|tab create' '$FAKE_HERDR_LOG' | head -2 | cut -d: -f2- | tr '\n' '|'"
    assert_output --partial "herdr tab close wV:t42|herdr tab create"
}

@test "A-2: the main checkout is the rebase target, never the worktree" {
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "fetch ${T_MAIN} origin main"
    assert_output --partial "rebase ${T_MAIN} origin/main"
    refute_output --partial "$T_IMPL"
}

@test "A-2: CLAUDE_CONFIG_DIR is forwarded to the new tab when set" {
    export CLAUDE_CONFIG_DIR="${TEST_TEMP_HOME}/.claude-personal"
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "--env CLAUDE_CONFIG_DIR=${TEST_TEMP_HOME}/.claude-personal"
}

@test "A-2: a -live repo is prompted with its own verify skill" {
    run dispatch acme/webapp
    assert_success
    assert_output --partial "verify: /gh-verify:live 77"
}

# --- A-4 / E-*: the impl-tab step never blocks ----------------------------

@test "A-4: impl tab already closed -> remaining steps still run" {
    FAKE_HERDR_OUT_AGENT_LIST='{"result":{"agents":[]}}'
    run dispatch
    assert_success
    assert_output --partial "no live herdr tab"
    assert_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close"
    assert_output --partial "tab create"
}

@test "A-4: no local worktree for the head branch -> remaining steps still run" {
    FAKE_WORKTREE_PORCELAIN="worktree ${T_MAIN}
HEAD aaaa
branch refs/heads/main
"
    run dispatch
    assert_success
    assert_output --partial "no local worktree for wt/issue-77/1"
    assert_output --partial "post-merge verification dispatched"
}

@test "A-4: a failing herdr tab close warns but does not stop the dispatch" {
    FAKE_HERDR_RC_TAB_CLOSE=1
    run dispatch
    assert_success
    assert_output --partial "herdr tab close wV:t42 failed"
    assert_output --partial "post-merge verification dispatched"
}

# --- A-3 / E-3: the main checkout is a hard stop --------------------------

@test "E-3: a dirty main checkout warns and creates no tab" {
    FAKE_MAIN_DIRTY=1
    run dispatch
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "has uncommitted changes"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "fetch "
}

@test "A-3: a rebase conflict warns, aborts the rebase, and creates no tab" {
    FAKE_SYNC_RC=1
    run dispatch
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "conflict not resolved"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
}

@test "A-3: the conflicted main checkout is restored, never auto-resolved" {
    FAKE_SYNC_RC=1
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "rebase-abort ${T_MAIN}"
}

# --- E-4..E-7: herdr failures are soft ------------------------------------

@test "E-4: herdr tab create failure warns and skips the agent" {
    FAKE_HERDR_RC_TAB_CREATE=1
    run dispatch
    assert_success
    assert_output --partial "herdr tab create failed for label pr-77"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "agent start"
}

@test "E-4: a tab create answer with no pane counts as a failure" {
    FAKE_HERDR_OUT_TAB_CREATE='{"result":{"tab":{"tab_id":"wV:t99"}}}'
    run dispatch
    assert_success
    assert_output --partial "herdr tab create failed"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "agent start"
}

@test "E-4: an unresolvable workspace warns instead of guessing one" {
    FAKE_HERDR_OUT_WORKTREE_LIST='{"result":{"worktrees":[]}}'
    run dispatch
    assert_success
    assert_output --partial "no herdr workspace for ${T_MAIN}"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
}

@test "E-5: herdr agent start failure warns and does not prompt" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"pane_not_ready"}}'
    run dispatch
    assert_success
    assert_output --partial "herdr agent start mv-dotfiles-pr-77 failed"
    assert_output --partial "pane_not_ready"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "agent prompt"
}

@test "E-6: agent_name_taken prompts the existing session instead of failing" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"agent_name_taken"}}'
    run dispatch
    assert_success
    assert_output --partial "already registered — prompting the existing session"
    assert_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "agent prompt mv-dotfiles-pr-77"
}

@test "E-7: a failing prompt warns but the report still prints" {
    FAKE_HERDR_RC_AGENT_PROMPT=1
    FAKE_HERDR_OUT_AGENT_PROMPT='{"error":{"code":"agent_prompt_stalled"}}'
    run dispatch
    assert_success
    assert_output --partial "herdr agent prompt mv-dotfiles-pr-77 failed (agent_prompt_stalled)"
    assert_output --partial "renamed tab wV:t99 to pr-77-STUCK"
    assert_output --partial "notification posted for pr-77 stall"
    assert_output --partial "post-merge verification dispatched, but the prompt failed"
    refute_output --partial "[OK]"
}

@test "E-7: a retryable prompt failure retries twice before escalating" {
    PMV_PROMPT_ATTEMPT_MAX=3
    FAKE_HERDR_RC_AGENT_PROMPT=1
    FAKE_HERDR_OUT_AGENT_PROMPT='{"error":{"code":"timeout"}}'
    run dispatch
    assert_success
    [ "$(_pmv_log_count 'herdr agent prompt mv-dotfiles-pr-77')" -eq 3 ]
    # Two settles around agent start, plus one after every failed send: the
    # fence settles BEFORE probing whether a failed prompt landed anyway (#85).
    [ "$(_pmv_log_count '^sleep 13$')" -eq 5 ]
    assert_output --partial "retrying after 13s settle (1/3)"
    assert_output --partial "retrying after 13s settle (2/3)"
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "herdr tab rename wV:t99 pr-77-STUCK"
    assert_output --partial "herdr notification show post-merge verify stalled --body pr-77 verification prompt failed repeatedly — herdr agent attach mv-dotfiles-pr-77 --sound request"
}

# --- unit pins on the easy-to-break pieces --------------------------------

# The pre-#1530 name was `pmv-<host>-<owner>-<repo>-<N>` — 37 characters and
# carrying a dot, so herdr refused every `agent start`. These pin the shape
# herdr accepts, on the vendored helper the fence sources.
@test "naming: the agent name satisfies herdr's rule" {
    pmv_load_vendored
    run herdr_agent_name mv acme/dotfiles pr-77
    assert_output "mv-dotfiles-pr-77"
    assert_valid_herdr_name "$output"
}

@test "naming: a mixed-case owner and a long repo still fit the 32-char budget" {
    pmv_load_vendored
    run herdr_agent_name mv dEitY719/A-Very-Long-Repository-Name pr-99999
    assert_success
    assert_valid_herdr_name "$output"
    assert_output "mv-a-very-long-repo-pr-99999"
}

# The host is deliberately not in the name — it does not fit in 32 characters
# alongside the repo. The trade-off is documented at herdr_agent_name.
@test "naming: the host is not part of the agent name" {
    T_HOST=ghe.example.com run dispatch
    assert_success
    assert_output --partial "agent:  mv-dotfiles-pr-77"
}

@test "naming: the skill id is typed verbatim as a colon-form slash command (#69)" {
    # Plugin skills register under the colon name only; the dash form
    # (`/gh-verify-merged`) is "Unknown command".
    run dispatch
    assert_success
    assert_output --partial "verify: /gh-verify:merged 77"
    refute_output --partial "/gh-verify-merged"
}

@test "json: pane_id is found under either parent shape" {
    # herdr nests the pane under `.result.pane` (tab create) or
    # `.result.root_pane` (workspace create); the scan keys on the leaf name.
    FAKE_HERDR_OUT_TAB_CREATE='{"result":{"tab":{"tab_id":"wV:t99"},"root_pane":{"pane_id":"wV:p2"}}}'
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "agent start mv-dotfiles-pr-77 --kind claude --pane wV:p2"
}

@test "cwd-match: an empty herdr answer is unknown, never 'nothing running'" {
    pmv_load_vendored
    FAKE_HERDR_OUT_AGENT_LIST=""
    run herdr_agent_tab_for_cwd "$T_IMPL"
    [ "$status" -eq 1 ]
}

@test "cwd-match: foreground_cwd counts too (the session that cd-ed away)" {
    pmv_load_vendored
    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"/elsewhere\",\"foreground_cwd\":\"${T_IMPL}/sub\",\"tab_id\":\"wV:t7\"}]}}"
    run herdr_agent_tab_for_cwd "$T_IMPL"
    assert_success
    assert_output "wV:t7"
}

@test "cwd-match: an empty path matches nothing (startswith guard)" {
    pmv_load_vendored
    run herdr_agent_tab_for_cwd ""
    [ "$status" -eq 3 ]
    assert_output ""
}

@test "main root: git's common dir resolves the original checkout from a worktree" {
    FAKE_CWD_COMMON_DIR="${T_MAIN}/.git"
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "toplevel ${T_MAIN}"
    assert_output --partial "fetch ${T_MAIN} origin main"
}

@test "main root: an explicit path wins and expands a leading ~ (#1555)" {
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"path":"~/elsewhere"}]\n' >"$WATCHED"
    FAKE_CWD_COMMON_DIR="/not/this/.git"
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "toplevel ${HOME}/elsewhere"
    refute_output --partial "/not/this"
}

@test "main root: an entry with no path falls back to git's common dir (#1555)" {
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true}]\n' >"$WATCHED"
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "toplevel ${T_MAIN}"
}

@test "timeout: the prompt cap defaults to 900000ms when the env var is unset" {
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "--wait --until idle --timeout 900000"
}

@test "timeout: PMV_PROMPT_TIMEOUT_MS overrides the default prompt cap" {
    export PMV_PROMPT_TIMEOUT_MS=1234
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "--wait --until idle --timeout 1234"
    refute_output --partial "--timeout 900000"
}

@test "worktree lookup: the branch decides the path, not the directory name" {
    run dispatch
    assert_output --partial "closed implementation tab wV:t42 (${T_IMPL})"
    T_HEAD=main run dispatch
    assert_output --partial "no live herdr tab on ${T_MAIN} — nothing to close"
    T_HEAD=wt/issue-99/1 run dispatch
    assert_output --partial "no local worktree for wt/issue-99/1"
}

# --- dotfiles PR #1518 review: the rebase preconditions --------------------

@test "R-1: a main checkout parked on another branch is never rebased" {
    FAKE_MAIN_BRANCH=feature/unrelated
    run dispatch acme/dotfiles origin main
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "is on feature/unrelated, not the base branch main"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "fetch "
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
}

@test "R-1: a detached HEAD stops the run instead of rebasing it" {
    FAKE_MAIN_BRANCH=HEAD
    run dispatch
    assert_success
    assert_output --partial "is on (detached HEAD), not the base branch (unknown)"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "fetch "
}

@test "R-1: a detached HEAD stops even when the caller passed a base branch" {
    FAKE_MAIN_BRANCH=HEAD
    run dispatch acme/dotfiles origin main
    assert_success
    assert_output --partial "is on (detached HEAD), not the base branch main"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "fetch "
}

@test "R-2: the remote positional and the PR's base branch are what get fetched" {
    FAKE_MAIN_BRANCH=develop
    run dispatch acme/dotfiles upstream develop
    assert_success
    assert_output --partial "post-merge verification dispatched"
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "fetch ${T_MAIN} upstream develop"
    refute_output --partial "origin"
    refute_output --partial " main"
}

@test "R-2: an empty base branch falls back to the checkout's own branch" {
    # Never a literal `main`: a watched repo may default to master/develop.
    FAKE_MAIN_BRANCH=master
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "fetch ${T_MAIN} origin master"
}

@test "R-2: an empty remote falls back to origin, never to an empty word" {
    run dispatch acme/dotfiles "" main
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "fetch ${T_MAIN} origin main"
}

# --- dotfiles PR #1518 review: the post_merge_verify_skill allowlist -------

@test "R-3: both shipped verification skills are accepted" {
    run dispatch acme/dotfiles
    assert_output --partial "[OK] post-merge verification dispatched"
    run dispatch acme/webapp
    assert_output --partial "[OK] post-merge verification dispatched"
}

@test "R-3: with no herdr, even a bad registry value stays silent (AC-5)" {
    # The allowlist sits AFTER the herdr probe on purpose: a machine that
    # cannot run the feature at all must print nothing.
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"post_merge_verify_skill":"evil:do-something-else"}]\n' >"$WATCHED"
    FAKE_HERDR_PRESENT=0
    run dispatch
    assert_success
    assert_output ""
}

@test "R-3: anything else is refused, the dotfiles-era ids included" {
    local _id
    for _id in gh-verify:anything devx:pr-verify-merged devx:pr-verify-live; do
        printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"post_merge_verify_skill":"%s"}]\n' "$_id" >"$WATCHED"
        run dispatch
        assert_output --partial "post_merge_verify_skill \"${_id}\" for acme/dotfiles is not one of gh-verify:merged, gh-verify:live"
    done
}

@test "R-3: a registry value off the allowlist warns before any herdr call" {
    # It is typed into a --dangerously-skip-permissions agent's prompt, so a
    # bad registry must not even get as far as closing a tab.
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"post_merge_verify_skill":"evil:do-something-else"}]\n' >"$WATCHED"
    run dispatch
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "post_merge_verify_skill \"evil:do-something-else\" for acme/dotfiles is not one of"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
    run cat "$FAKE_GIT_LOG"
    assert_output ""
}

# --- dotfiles PR #1518 review: MAIN_ROOT must be a git worktree root -------

@test "R-4: an empty main checkout is refused before anything is touched" {
    FAKE_CWD_COMMON_DIR=""
    run dispatch
    assert_success
    assert_output --partial "main checkout \"\" is not a git worktree root"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
}

@test "R-4: a path that is not a git worktree root is refused" {
    FAKE_MAIN_TOPLEVEL=""
    run dispatch
    assert_success
    assert_output --partial "main checkout \"${T_MAIN}\" is not a git worktree root"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close"
    refute_output --partial "tab create"
}

@test "R-4: a path INSIDE the checkout is not its root" {
    printf '[{"repo":"acme/dotfiles","post_merge_verify":true,"path":"%s/git"}]\n' "$T_MAIN" >"$WATCHED"
    FAKE_MAIN_TOPLEVEL="$T_MAIN"
    run dispatch
    assert_success
    assert_output --partial "is not a git worktree root"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "fetch "
}

# --- dotfiles PR #1518 review: the prefix needs a path boundary ------------

@test "R-5: a sibling checkout sharing a prefix is not matched" {
    # /work/repo-11 must not answer for /work/repo-1.
    pmv_load_vendored
    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"${T_IMPL}1\",\"foreground_cwd\":\"${T_IMPL}1\",\"tab_id\":\"wV:tSIB\"}]}}"
    run herdr_agent_tab_for_cwd "$T_IMPL"
    [ "$status" -eq 3 ]
    assert_output ""
}

@test "R-5: the path itself and its subdirectories still match" {
    pmv_load_vendored
    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"${T_IMPL}\",\"tab_id\":\"wV:tSELF\"}]}}"
    run herdr_agent_tab_for_cwd "$T_IMPL"
    assert_success
    assert_output "wV:tSELF"

    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"${T_IMPL}/sub/deep\",\"tab_id\":\"wV:tSUB\"}]}}"
    run herdr_agent_tab_for_cwd "$T_IMPL"
    assert_success
    assert_output "wV:tSUB"
}

@test "R-5: a sibling worktree's tab is not closed by the dispatch" {
    FAKE_HERDR_OUT_AGENT_LIST="{\"result\":{\"agents\":[{\"cwd\":\"${T_IMPL}1\",\"tab_id\":\"wV:tSIB\"}]}}"
    run dispatch
    assert_success
    assert_output --partial "no live herdr tab on ${T_IMPL}"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close"
}

# --- dotfiles PR #1518 review: FOLLOW-UP-7/8 -------------------------------

@test "R-7: an unreachable herdr WARNs, it does not claim 'nothing to close'" {
    FAKE_HERDR_OUT_AGENT_LIST=""
    run dispatch
    assert_success
    assert_output --partial "[WARN]"
    assert_output --partial "herdr could not be queried — implementation tab on ${T_IMPL} left alone"
    refute_output --partial "nothing to close"
    assert_output --partial "post-merge verification dispatched"
}

@test "R-7: an answered-but-empty herdr is an INFO 'nothing to close'" {
    FAKE_HERDR_OUT_AGENT_LIST='{"result":{"agents":[]}}'
    run dispatch
    assert_success
    assert_output --partial "[INFO] gh-verify:post-merge-verify: no live herdr tab on ${T_IMPL} — nothing to close."
    refute_output --partial "could not be queried"
}

@test "R-8: no jq -> the feature is unavailable, silently" {
    FAKE_JQ_PRESENT=0
    run dispatch
    assert_success
    assert_output ""
    run cat "$FAKE_HERDR_LOG"
    assert_output ""
    run cat "$FAKE_GIT_LOG"
    assert_output ""
}

# --- #1571: the herdr settle waits ----------------------------------------
#
# `tab create` returns a pane whose shell is not interactive yet (`agent start`
# on it is refused with `agent_pane_busy`), and `agent start` returns idle for a
# claude TUI whose key-input loop is not attached yet. ~5s fails, ~13s lands, so
# 13 is the standard at both points. Observed by the recorded `sleep` calls,
# never by wall clock.

@test "1571: a fresh dispatch settles before agent start AND before the prompt" {
    run dispatch
    assert_success
    [ "$(_pmv_log_count '^sleep 13$')" -eq 2 ]
    local _tab _s1 _start _s2 _prompt
    _tab=$(_pmv_log_line 'herdr tab create')
    _start=$(_pmv_log_line 'herdr agent start')
    _prompt=$(_pmv_log_line 'herdr agent prompt')
    _s1=$(grep -n '^sleep 13$' "$FAKE_HERDR_LOG" | sed -n '1p' | cut -d: -f1)
    _s2=$(grep -n '^sleep 13$' "$FAKE_HERDR_LOG" | sed -n '2p' | cut -d: -f1)
    # tab create < settle < agent start < settle < agent prompt
    [ "$_tab" -lt "$_s1" ]
    [ "$_s1" -lt "$_start" ]
    [ "$_start" -lt "$_s2" ]
    [ "$_s2" -lt "$_prompt" ]
}

@test "1571: the agent_name_taken fallback settles the pane but not the prompt" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"agent_name_taken"}}'
    run dispatch
    assert_success
    assert_output --partial "already registered — prompting the existing session"
    [ "$(_pmv_log_count '^sleep 13$')" -eq 1 ]
    local _s _start _prompt
    _s=$(_pmv_log_line '^sleep 13$')
    _start=$(_pmv_log_line 'herdr agent start')
    _prompt=$(_pmv_log_line 'herdr agent prompt')
    [ "$_s" -lt "$_start" ]
    [ "$_prompt" -gt "$_start" ]
}

@test "1571: a failed agent start never reaches the prompt settle" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"pane_not_ready"}}'
    run dispatch
    assert_success
    assert_output --partial "herdr agent start mv-dotfiles-pr-77 failed"
    [ "$(_pmv_log_count '^sleep 13$')" -eq 1 ]
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "agent prompt"
}

@test "1571: a failed tab create never settles at all" {
    FAKE_HERDR_RC_TAB_CREATE=1
    run dispatch
    assert_success
    assert_output --partial "herdr tab create failed for label pr-77"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "sleep"
}

@test "1571: a repo with no derivable agent name settles neither wait" {
    cat >"$WATCHED" <<'JSON'
[ { "repo": "acme/...", "post_merge_verify": true } ]
JSON
    run dispatch 'acme/...'
    assert_success
    assert_output --partial "cannot derive an agent name"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "sleep"
}

@test "1571: PMV_SETTLE_SECONDS=0 removes both waits" {
    export PMV_SETTLE_SECONDS=0
    run dispatch
    assert_success
    assert_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "agent start mv-dotfiles-pr-77"
    assert_output --partial "agent prompt mv-dotfiles-pr-77"
    refute_output --partial "sleep"
}

@test "1571: PMV_SETTLE_SECONDS overrides the duration at both points" {
    export PMV_SETTLE_SECONDS=7
    run dispatch
    assert_success
    [ "$(_pmv_log_count '^sleep 7$')" -eq 2 ]
    [ "$(_pmv_log_count '^sleep 13$')" -eq 0 ]
}

# --- #1554: don't leak the just-created verification tab on agent-start failure

@test "1554: an agent start failure closes the just-created verification tab" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"pane_not_ready"}}'
    run dispatch
    assert_success
    assert_output --partial "closed the empty verification tab wV:t99"
    assert_output --partial "herdr agent start mv-dotfiles-pr-77 failed"
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "tab close wV:t99"
}

@test "1554: a failing tab close warns but does not stop the dispatch" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"pane_not_ready"}}'
    FAKE_HERDR_RC_TAB_CLOSE=1
    run dispatch
    assert_success
    assert_output --partial "could not close tab wV:t99 — close it by hand"
    assert_output --partial "herdr agent start mv-dotfiles-pr-77 failed"
}

@test "1554: agent_name_taken reuses the tab instead of closing it" {
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"agent_name_taken"}}'
    run dispatch
    assert_success
    refute_output --partial "closed the empty verification tab"
    refute_output --partial "could not close tab"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close wV:t99"
}

@test "1554: a failing agent prompt leaves the live verification tab alone" {
    FAKE_HERDR_RC_AGENT_PROMPT=1
    FAKE_HERDR_OUT_AGENT_PROMPT='{"error":{"code":"agent_prompt_stalled"}}'
    run dispatch
    assert_success
    refute_output --partial "closed the empty verification tab"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close wV:t99"
}

@test "1554: an unreadable tab id is never guessed at for cleanup" {
    FAKE_HERDR_OUT_TAB_CREATE='{"result":{"pane":{"pane_id":"wV:p99"}}}'
    FAKE_HERDR_RC_AGENT_START=1
    FAKE_HERDR_OUT_AGENT_START='{"error":{"code":"pane_not_ready"}}'
    run dispatch
    assert_success
    refute_output --partial "closed the empty verification tab"
    refute_output --partial "could not close tab"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab close -"
}

# --- #1577: the verification session lives in its own detached worktree ----
#
# Each PR gets `<git-common-dir>/pr-post-merge-verify/pr-<N>`, created detached
# off the ref step 3 already fetched, reused when it is a registered worktree,
# and never torn down here (its lifetime is the tab's).

_pmv_scratch_for() { printf '%s/.git/pr-post-merge-verify/pr-%s' "$T_MAIN" "$1"; }

# Make the scratch directory exist; with "registered", list it as a worktree.
_pmv_make_scratch() {
    mkdir -p "$(_pmv_scratch_for 77)"
    : >"$(_pmv_scratch_for 77)/leftover"
    if [ "${1-}" = registered ]; then
        FAKE_WORKTREE_PORCELAIN="${FAKE_WORKTREE_PORCELAIN}
worktree $(cd -P "$(_pmv_scratch_for 77)" && pwd -P)
HEAD cccc
detached
"
    fi
}

@test "1577: the verification tab opens in the PR's own worktree, not the main checkout" {
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "herdr tab create --workspace wV --cwd $(_pmv_scratch_for 77) --label pr-77 --no-focus"
    refute_output --partial "--cwd ${T_MAIN} --label pr-77"
}

@test "1577: the report names the worktree the session lives in" {
    run dispatch
    assert_success
    assert_output --partial "cwd:    $(_pmv_scratch_for 77)"
}

@test "1577: an absent worktree is created detached at the merged base" {
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "worktree-add ${T_MAIN} $(_pmv_scratch_for 77) origin/main"
    assert_output --partial "mkdir-p ${T_MAIN}/.git/pr-post-merge-verify"
}

@test "1577: the remote and base branch reach the worktree, never a hardcoded origin/main" {
    FAKE_MAIN_BRANCH=develop
    run dispatch acme/dotfiles upstream develop
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "worktree-add ${T_MAIN} $(_pmv_scratch_for 77) upstream/develop"
}

@test "1577: an empty base branch reaches the worktree as step 3's own fallback" {
    # `origin/` with nothing after it would detach at whatever that resolves to.
    FAKE_MAIN_BRANCH=master
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "worktree-add ${T_MAIN} $(_pmv_scratch_for 77) origin/master"
    refute_output --partial "origin/ "
}

@test "1577: an existing worktree is reused, never added a second time" {
    _pmv_make_scratch registered
    run dispatch
    assert_success
    assert_output --partial "reusing verification worktree $(_pmv_scratch_for 77)"
    assert_output --partial "post-merge verification dispatched"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "worktree-add"
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "--cwd $(_pmv_scratch_for 77) --label pr-77"
}

@test "1605 review: a directory that exists but is not a registered worktree is wiped and recreated" {
    _pmv_make_scratch
    run dispatch
    assert_success
    refute_output --partial "reusing verification worktree"
    [ ! -e "$(_pmv_scratch_for 77)/leftover" ]
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "rm-rf $(_pmv_scratch_for 77)"
    assert_output --partial "worktree-add ${T_MAIN} $(_pmv_scratch_for 77) origin/main"
}

@test "1605 review: the stale directory is removed before worktree-add runs, not after" {
    _pmv_make_scratch
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    _rm_line=$(printf '%s\n' "$output" | grep -n "^rm-rf " | head -1 | cut -d: -f1)
    _add_line=$(printf '%s\n' "$output" | grep -n "^worktree-add " | head -1 | cut -d: -f1)
    [ -n "$_rm_line" ]
    [ -n "$_add_line" ]
    [ "$_rm_line" -lt "$_add_line" ]
}

@test "1605 review: a registered worktree is reused without ever being removed" {
    _pmv_make_scratch registered
    run dispatch
    assert_success
    assert_output --partial "reusing verification worktree $(_pmv_scratch_for 77)"
    [ -e "$(_pmv_scratch_for 77)/leftover" ]
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "rm-rf"
    refute_output --partial "worktree-add"
}

@test "1577: two PRs get two different worktrees" {
    run pmv_dispatch 77 acme/dotfiles
    assert_success
    T_HEAD=wt/issue-88/1 run pmv_dispatch 88 acme/dotfiles
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "--cwd $(_pmv_scratch_for 77) --label pr-77"
    assert_output --partial "--cwd $(_pmv_scratch_for 88) --label pr-88"
    [ "$(_pmv_scratch_for 77)" != "$(_pmv_scratch_for 88)" ]
}

@test "1577: step 3 still rebases the main checkout, never the scratch worktree" {
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    assert_output --partial "fetch ${T_MAIN} origin main"
    refute_output --partial "fetch $(_pmv_scratch_for 77)"
    refute_output --partial "rebase $(_pmv_scratch_for 77)"
}

@test "1577: the workspace lookup still asks about the main checkout" {
    # WS_ID only groups the tab; a worktree created seconds ago has no herdr
    # workspace of its own on a first dispatch.
    run dispatch
    assert_success
    run cat "$FAKE_HERDR_LOG"
    assert_output --partial "herdr worktree list --cwd ${T_MAIN} --json"
}

@test "1577: a worktree that cannot be created stops before the tab" {
    FAKE_WORKTREE_ADD_RC=1
    run dispatch
    assert_success
    assert_output --partial "could not create the verification worktree $(_pmv_scratch_for 77)"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
}

@test "1577: an unresolvable git common dir never falls back to the main checkout" {
    FAKE_GIT_COMMON_DIR=""
    run dispatch
    assert_success
    assert_output --partial "cannot resolve the git common dir of ${T_MAIN}"
    refute_output --partial "post-merge verification dispatched"
    run cat "$FAKE_HERDR_LOG"
    refute_output --partial "tab create"
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "worktree-add"
}

@test "1577: nothing here tears the worktree down" {
    run dispatch
    assert_success
    run cat "$FAKE_GIT_LOG"
    refute_output --partial "worktree-remove"
    refute_output --partial "unexpected git"
}
