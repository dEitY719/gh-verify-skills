# Post-merge verification dispatch — the verbatim block

Step 3 pastes this. It expects `PR_NUMBER`, `TARGET_REPO` and `TARGET_HOST`
already bound (Step 2), and it is a no-op for any repo missing from
`${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}`
— the same untracked registry `issue_watcher_cron.sh` reads (issue dEitY719/dotfiles#1555).

`gh-pr:merge` Step 5 does not paste a copy: it extracts the **first** `bash`
fence below and sources it, so this file stays the single source (dEitY719/dotfiles#1565). Keep
the dispatch in that first fence — the later snippets are documentation.

Executable mirror + regression suite:
dotfiles' `tests/bats/skills/_fixtures/gh_pr_post_merge_verify.sh` and
`tests/bats/skills/gh_pr_post_merge_verify.bats`. Change one, change both.

```bash
# --- 0. F-1 gate. Unregistered repo => do nothing at all, no output. -------
WATCHED_FILE="${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}" # untracked, array-schema, shared with issue_watcher_cron.sh (dEitY719/dotfiles#1555)
VERIFY_SKILL=""
# No jq → the registry cannot be read, so the feature is simply unavailable.
# Silent, never a WARN: an absent tool is not a broken SSOT, and gh-pr:merge's
# gate (which carries the same condition) must print nothing either way.
if command -v jq >/dev/null 2>&1 && [ -r "$WATCHED_FILE" ]; then
    if ! VERIFY_SKILL=$(jq -r --arg r "$TARGET_REPO" \
        '(if type == "array" then . else (.repos // []) end) | .[] | select(.repo == $r) | .verify_skill // empty' "$WATCHED_FILE" 2>/dev/null); then
        # The file exists but is not JSON: a broken SSOT, not an opt-out.
        printf '[WARN] gh-verify:post-merge-verify: %s is not valid JSON — post-merge verification skipped.\n' \
            "$WATCHED_FILE"
        VERIFY_SKILL=""
    fi
fi
[ -n "$VERIFY_SKILL" ] || return 0 2>/dev/null || exit 0
command -v herdr >/dev/null 2>&1 || return 0 2>/dev/null || exit 0
# The registry value is typed into a session started with
# `--dangerously-skip-permissions`, so it is an input to a prompt, not a label.
# Allowlist it here — after the herdr probe (a machine that cannot run the
# feature stays silent, AC-5) but before a tab is closed or anything else is
# touched, so a registry someone else can edit cannot steer an unattended agent.
case "$VERIFY_SKILL" in
gh-verify:merged | gh-verify:live) ;;
*)
    printf '[WARN] gh-verify:post-merge-verify: verify_skill "%s" for %s is not one of gh-verify:merged, gh-verify:live — verification skipped.\n' \
        "$VERIFY_SKILL" "$TARGET_REPO"
    return 0 2>/dev/null || exit 0
    ;;
esac

# --- helpers --------------------------------------------------------------
# First string value of a flat key anywhere in the document. `herdr tab create`
# answers `.result.pane.pane_id` and `herdr workspace create` answers
# `.result.root_pane.pane_id`; keying on the leaf name survives both, and any
# third shape the CLI adds. The key travels as a jq *argument*, never as
# interpolated program text. (Same helper as _pmt_json_first.)
pmv_json_first() {
    jq -r --arg k "$1" \
        '[.. | objects | .[$k]? // empty] | map(select(type == "string")) | first // empty' \
        2>/dev/null || return 0
}
# `.error.code` off a failed herdr answer, or empty. Fixed filter, so nothing
# is ever interpolated into the jq program text.
pmv_error_code() { jq -r '.error.code // empty' 2>/dev/null || return 0; }

# Settle wait after a herdr call that brings something up (dEitY719/dotfiles#1571). One value
# for both of this repo's herdr races, because they are the same race seen
# twice and splitting them is how a fix keeps missing a third site:
#   `tab create` -> `agent start`  the pane answers before its shell is
#       interactive, so the start is refused with `agent_pane_busy`
#       (issue_watcher_cron.sh's _IW_START_RETRY_SLEEP comment documents it).
#   `agent start` -> `agent prompt`  herdr answers `"agent_status":"idle"`
#       straight away, but a freshly drawn claude TUI is idle while its
#       key-input loop is still unattached, so the prompt is swallowed (dEitY719/dotfiles#1560).
# Measured on herdr 0.7.5: ~5s fails every time, ~13s lands. 13 is the repo
# standard — the twins are _IW_SETTLE_SECONDS / _IW_START_RETRY_SLEEP in
# shell-common/tools/custom/issue_watcher_cron.sh and _PMT_SETTLE_SECONDS /
# _PMT_START_RETRY_SLEEP in shell-common/tools/custom/pr_merge_train_cron.sh.
# Change one, change all five: dEitY719/dotfiles#1530 / dEitY719/dotfiles#1549 and dEitY719/dotfiles#1560 / dEitY719/dotfiles#1571 are both the same
# defect recurring because two of three dispatchers were fixed. The *number*
# is what those five still share — since dEitY719/dotfiles#1570 the two `_IW/_PMT_SETTLE_SECONDS`
# spend it as a poll cap (each reads its pane's text via `herdr agent read` and
# can leave early once it looks ready) while `pmv_settle` here stays a flat
# sleep: this dispatcher opens a pane too ($NEW_PANE below), but nothing here
# reads it back yet (codex, PR dEitY719/dotfiles#1611 review). Whoever adds that read should
# convert `pmv_settle` the same way; until then it is deliberately the odd one
# out, not a missed follow-up.
#
# The other two dispatchers also *retry* `agent start` on `agent_pane_busy`;
# this one deliberately does not (dEitY719/dotfiles#1571 D-3). A wait shrinks the race, a retry
# survives it — the retry belongs here too, but as part of dEitY719/dotfiles#1569's shared
# helper, not as a fourth hand-rolled copy that unification would undo.
#
# Overridable, and `0` disables it outright, so the bats suite never sleeps for
# real (same convention as _IW_IDLE_POLL_SLEEP).
PMV_SETTLE_SECONDS="${PMV_SETTLE_SECONDS:-13}"
pmv_settle() { [ "$PMV_SETTLE_SECONDS" = "0" ] || sleep "$PMV_SETTLE_SECONDS"; }
PMV_PROMPT_ATTEMPT_MAX="${PMV_PROMPT_ATTEMPT_MAX:-3}"
# herdr agent names come from one SSOT, sourced — never re-implemented here.
# Three call sites each carrying their own `tr -c 'A-Za-z0-9._-' '-'` copy is
# what produced dEitY719/dotfiles#1530: that set keeps uppercase and dots, both of which herdr's
# `^[a-z][a-z0-9_-]{0,31}$` refuses, so this dispatch never once started a
# verification session. A missing helper skips the feature rather than
# guessing a name.
# `_SC` fallback ladder, same as every other helper this plugin sources: with only
# the plugin installed there is no $HOME/dotfiles, so fall back to the vendored copy
# and export SHELL_COMMON so anything sourced after this resolves from the same root.
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/herdr_agent_name.sh" ] || _SC="${CLAUDE_PLUGIN_ROOT:-$PWD}/lib/vendor/shell-common"
PMV_NAME_LIB="$_SC/functions/herdr_agent_name.sh"
if [ ! -r "$PMV_NAME_LIB" ]; then
    printf '[WARN] gh-verify:post-merge-verify: %s not readable — verification skipped.\n' "$PMV_NAME_LIB"
    return 0 2>/dev/null || exit 0
fi
export SHELL_COMMON="$_SC"
# shellcheck source=/dev/null
. "$PMV_NAME_LIB"

pmv_prompt_retryable() {
    case "$1" in
    timeout | agent_prompt_stalled) return 0 ;;
    esac
    return 1
}

pmv_escalate_prompt_stall() {
    _pmv_tab="$1"
    _pmv_agent="$2"
    _pmv_label="pr-${PR_NUMBER}-STUCK"
    _pmv_body="pr-${PR_NUMBER} verification prompt failed repeatedly — herdr agent attach ${_pmv_agent}"

    if [ -n "$_pmv_tab" ] && herdr tab rename "$_pmv_tab" "$_pmv_label" >/dev/null 2>&1; then
        printf '[WARN] gh-verify:post-merge-verify: renamed tab %s to %s after repeated prompt failure.\n' \
            "$_pmv_tab" "$_pmv_label"
    elif [ -n "$_pmv_tab" ]; then
        printf '[WARN] gh-verify:post-merge-verify: could not rename tab %s after repeated prompt failure.\n' \
            "$_pmv_tab"
    fi

    if herdr notification show "post-merge verify stalled" \
        --body "$_pmv_body" --sound request >/dev/null 2>&1; then
        printf '[WARN] gh-verify:post-merge-verify: notification posted for pr-%s stall.\n' "$PR_NUMBER"
    else
        printf '[WARN] gh-verify:post-merge-verify: notification failed for pr-%s stall.\n' "$PR_NUMBER"
    fi
}

# "Is a herdr agent sitting on this path?" comes from one SSOT too (dEitY719/dotfiles#1569), for
# the same reason and with the same history: this block's `pmv_tab_for_cwd` and
# `pmv_physical_path` were two of four hand-copied answers, and the fourth copy
# had already drifted to a plain `.cwd` string equality that missed both a
# session that `cd`-ed inside its worktree and a worktree reached through a
# symlink. `herdr_agent_tab_for_cwd` keeps this block's own rc convention
# verbatim — 0 matched, 1 herdr could not be asked, 3 herdr answered and
# nothing is on that path — because an empty answer from herdr is "unknown",
# never "nothing running", and the caller below branches on that difference.
PMV_LOOKUP_LIB="$_SC/functions/herdr_agent_lookup.sh"
if [ ! -r "$PMV_LOOKUP_LIB" ]; then
    printf '[WARN] gh-verify:post-merge-verify: %s not readable — verification skipped.\n' "$PMV_LOOKUP_LIB"
    return 0 2>/dev/null || exit 0
fi
# shellcheck source=/dev/null
. "$PMV_LOOKUP_LIB"

# --- the main checkout (never a worktree) ---------------------------------
# `path` from the registry when set; otherwise git's common dir,
# which answers `<main-checkout>/.git` even from inside a linked worktree.
MAIN_ROOT=$(jq -r --arg r "$TARGET_REPO" \
    '(if type == "array" then . else (.repos // []) end) | .[] | select(.repo == $r) | .path // empty' "$WATCHED_FILE" 2>/dev/null)
case "$MAIN_ROOT" in
'~'/*) MAIN_ROOT="${HOME}/${MAIN_ROOT#'~'/}" ;;
'') MAIN_ROOT=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    MAIN_ROOT="${MAIN_ROOT%/.git}" ;;
esac
# An empty or bogus MAIN_ROOT is the quietly dangerous case: `git -C "" status`
# fails, which the dirty check below reads as "clean", and the later
# `git -C "$MAIN_ROOT" rebase --abort` then fires wherever the shell stands. So
# it must resolve to a git worktree root BEFORE the first side effect (the
# impl-tab close) — a broken MAIN_ROOT makes the whole dispatch unusable.
MAIN_TOP=""
[ -z "$MAIN_ROOT" ] || MAIN_TOP=$(git -C "$MAIN_ROOT" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$MAIN_ROOT" ] || [ -z "$MAIN_TOP" ] ||
    [ "$(herdr_agent_physical_path "$MAIN_TOP")" != "$(herdr_agent_physical_path "$MAIN_ROOT")" ]; then
    printf '[WARN] gh-verify:post-merge-verify: main checkout "%s" is not a git worktree root — verification skipped.\n' \
        "$MAIN_ROOT"
    return 0 2>/dev/null || exit 0
fi

# --- 1/2. F-2: close the implementation tab (best-effort, never blocking) --
IMPL_WT=$(git worktree list --porcelain 2>/dev/null |
    awk -v b="refs/heads/${HEAD_BRANCH}" '
        /^worktree / { p = substr($0, 10) }
        $0 == ("branch " b) { print p; exit }
    ')
if [ -z "$IMPL_WT" ]; then
    printf '[INFO] gh-verify:post-merge-verify: no local worktree for %s — nothing to close.\n' "$HEAD_BRANCH"
else
    IMPL_TAB=$(herdr_agent_tab_for_cwd "$(herdr_agent_physical_path "$IMPL_WT")")
    IMPL_RC=$?
    if [ "$IMPL_RC" -eq 0 ]; then
        if herdr tab close "$IMPL_TAB" >/dev/null 2>&1; then
            printf '[INFO] gh-verify:post-merge-verify: closed implementation tab %s (%s).\n' "$IMPL_TAB" "$IMPL_WT"
        else
            printf '[WARN] gh-verify:post-merge-verify: herdr tab close %s failed — continuing.\n' "$IMPL_TAB"
        fi
    elif [ "$IMPL_RC" -eq 1 ]; then
        # rc 1 is "herdr could not be asked", NOT "nothing is running there" —
        # reporting the two the same way is the conflation rationale.md forbids.
        printf '[WARN] gh-verify:post-merge-verify: herdr could not be queried — implementation tab on %s left alone.\n' "$IMPL_WT"
    else
        printf '[INFO] gh-verify:post-merge-verify: no live herdr tab on %s — nothing to close.\n' "$IMPL_WT"
    fi
fi

# --- 3. F-3: clean, on the base branch, and rebased — or we stop -----------
if [ -n "$(git -C "$MAIN_ROOT" status --porcelain 2>/dev/null)" ]; then
    printf '[WARN] gh-verify:post-merge-verify: %s has uncommitted changes — not rebasing, verification skipped.\n' "$MAIN_ROOT"
    return 0 2>/dev/null || exit 0
fi
# Rebasing without checking what HEAD is on would rewrite the history of
# whatever feature branch the main checkout happens to be parked on. A detached
# HEAD stops here too: it has no branch to compare, so it can never match.
REMOTE="${REMOTE:-origin}"
MAIN_BRANCH=$(git -C "$MAIN_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$MAIN_BRANCH" != "HEAD" ] || MAIN_BRANCH=""
[ -n "${BASE_BRANCH-}" ] || BASE_BRANCH="$MAIN_BRANCH"
if [ -z "$BASE_BRANCH" ] || [ "$MAIN_BRANCH" != "$BASE_BRANCH" ]; then
    printf '[WARN] gh-verify:post-merge-verify: %s is on %s, not the base branch %s — not rebasing, verification skipped.\n' \
        "$MAIN_ROOT" "${MAIN_BRANCH:-(detached HEAD)}" "${BASE_BRANCH:-(unknown)}"
    return 0 2>/dev/null || exit 0
fi
if ! (git -C "$MAIN_ROOT" fetch "$REMOTE" "$BASE_BRANCH" &&
    git -C "$MAIN_ROOT" rebase "${REMOTE}/${BASE_BRANCH}") >/dev/null 2>&1; then
    # Restore, never resolve: picking sides is the human's call, but leaving
    # the user's main checkout parked mid-rebase is a worse failure.
    git -C "$MAIN_ROOT" rebase --abort >/dev/null 2>&1 || true
    printf '[WARN] gh-verify:post-merge-verify: fetch/rebase failed in %s (rebase aborted, conflict not resolved) — verification skipped.\n' "$MAIN_ROOT"
    return 0 2>/dev/null || exit 0
fi

# --- 4. F-4: the verification tab -----------------------------------------
# The workspace is still looked up from $MAIN_ROOT, deliberately, even though
# the tab below opens somewhere else: `herdr worktree list --cwd P --json`
# answers the workspace *P's repository* is open in, and WS_ID only says which
# herdr workspace the new tab is grouped under. The scratch worktree created a
# few lines down is seconds old and has no workspace of its own on a first
# dispatch, so asking about it would answer nothing at all. Grouping is the
# main checkout's; the tab's own directory is `--cwd`, and those are separate.
WS_JSON=$(herdr worktree list --cwd "$MAIN_ROOT" --json 2>/dev/null) || WS_JSON=""
WS_ID=$(printf '%s' "$WS_JSON" | jq -r --arg p "$MAIN_ROOT" '
    [ (.result.source.source_workspace_id? // empty),
      (.result.worktrees[]? | select(.path == $p) | .open_workspace_id? // empty) ]
    | map(select(type == "string" and . != "")) | first // empty
' 2>/dev/null) || WS_ID=""
[ -n "$WS_ID" ] || WS_ID=$(printf '%s' "$WS_JSON" | pmv_json_first source_workspace_id)
if [ -z "$WS_ID" ]; then
    printf '[WARN] gh-verify:post-merge-verify: no herdr workspace for %s — verification tab not created.\n' "$MAIN_ROOT"
    return 0 2>/dev/null || exit 0
fi

# The verification session gets its OWN detached worktree (dEitY719/dotfiles#1577). It used to
# open in $MAIN_ROOT, and that checkout is shared: humans and other AI sessions
# check branches out in it, and step 3 right above *rebases* it — so on
# back-to-back merges the N+1th dispatch moved the ground under the Nth
# session. Tab `pr-1567` disappeared exactly that way. This is the isolation
# `iw-*` tabs already have, in the shape gh-pr:merge-train's scratch worktree
# uses (`references/train-loop.md` → "Detached scratch worktree").
PMV_COMMON_DIR=$(git -C "$MAIN_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -z "$PMV_COMMON_DIR" ]; then
    # Never fall back to $MAIN_ROOT: that fallback IS the defect being fixed.
    printf '[WARN] gh-verify:post-merge-verify: cannot resolve the git common dir of %s — verification skipped.\n' "$MAIN_ROOT"
    return 0 2>/dev/null || exit 0
fi
# One directory per PR, so two verifications running at once never share one.
PMV_SCRATCH="${PMV_COMMON_DIR}/pr-post-merge-verify/pr-${PR_NUMBER}"
# Existence alone is not proof of a live worktree (agy/codex, PR dEitY719/dotfiles#1605 review):
# a directory git's own bookkeeping has forgotten — pruned, or hand-removed and
# recreated as a plain folder — passes `-d` but is not a checkout `herdr tab
# create` can safely open. Cross-check it against `worktree list` instead.
PMV_SCRATCH_REGISTERED=""
if [ -d "$PMV_SCRATCH" ]; then
    PMV_SCRATCH_REGISTERED=$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null |
        awk -v p="$(herdr_agent_physical_path "$PMV_SCRATCH")" '$0 == "worktree " p { print "1"; exit }')
fi
if [ -n "$PMV_SCRATCH_REGISTERED" ]; then
    # Create if absent, reuse if present: a second dispatch for the same PR (a
    # manual re-run over a tab that is still open) must be idempotent, not a
    # duplicate and not an error. There is deliberately NO teardown here — the
    # worktree's lifetime is the tab's, and who removes it when is left to a
    # later tab-close rule rather than guessed at now (dEitY719/dotfiles#1577).
    printf '[INFO] gh-verify:post-merge-verify: reusing verification worktree %s.\n' "$PMV_SCRATCH"
else
    # An unregistered directory at this path cannot be reused (git refuses to
    # `worktree add` over an existing, non-empty target) and cannot be trusted
    # as a checkout either — clear it before recreating, same as the
    # stale-leftover guard in gh-pr:merge-train's own scratch worktree
    # (`references/train-loop.md` → "Detached scratch worktree").
    [ -d "$PMV_SCRATCH" ] && rm -rf "$PMV_SCRATCH"
    mkdir -p "$(dirname "$PMV_SCRATCH")"
    # Pruning drops only entries git already considers gone, so it cannot
    # touch a live worktree — safe to run unconditionally before every add.
    git -C "$MAIN_ROOT" worktree prune >/dev/null 2>&1 || true
    # `--detach` is what makes this collide-free: it holds a commit, not the
    # branch *name*, so it never contests the base branch $MAIN_ROOT has
    # checked out. No fetch here — step 3 just fetched "$REMOTE/$BASE_BRANCH"
    # and rebased $MAIN_ROOT onto it, so that ref is current by construction.
    if ! git -C "$MAIN_ROOT" worktree add --detach "$PMV_SCRATCH" "${REMOTE}/${BASE_BRANCH}" >/dev/null 2>&1; then
        printf '[WARN] gh-verify:post-merge-verify: could not create the verification worktree %s — verification skipped.\n' "$PMV_SCRATCH"
        return 0 2>/dev/null || exit 0
    fi
fi

# Spelled out twice rather than accumulated with `set --`: this block is pasted
# at the top level of the caller's shell, where `set --` would destroy the
# caller's own "$1", "$2", … POSIX sh has no arrays, so an if/else over the
# full command line is the only form that is both safe and portable.
if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
    TAB_JSON=$(herdr tab create --workspace "$WS_ID" --cwd "$PMV_SCRATCH" \
        --label "pr-${PR_NUMBER}" --no-focus \
        --env "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}" 2>/dev/null) || TAB_JSON=""
else
    TAB_JSON=$(herdr tab create --workspace "$WS_ID" --cwd "$PMV_SCRATCH" \
        --label "pr-${PR_NUMBER}" --no-focus 2>/dev/null) || TAB_JSON=""
fi
NEW_PANE=$(printf '%s' "$TAB_JSON" | pmv_json_first pane_id)
NEW_TAB=$(printf '%s' "$TAB_JSON" | pmv_json_first tab_id)
if [ -z "$NEW_PANE" ]; then
    printf '[WARN] gh-verify:post-merge-verify: herdr tab create failed for label pr-%s — verification skipped.\n' "$PR_NUMBER"
    return 0 2>/dev/null || exit 0
fi

# --- 5. F-4: the agent ----------------------------------------------------
# `mv-<repo>-pr-<N>`, at most 28 characters. Neither `$TARGET_HOST` nor the
# owner is in the name: a host-qualified one does not fit herdr's 32-character
# budget (the pre-dEitY719/dotfiles#1530 form reached 37 and was refused on every merge). That
# concession to dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407, and the condition that would end it, is
# documented at herdr_agent_name.
if ! PMV_AGENT=$(herdr_agent_name mv "$TARGET_REPO" "pr-${PR_NUMBER}"); then
    printf '[WARN] gh-verify:post-merge-verify: cannot derive an agent name for %s — verification skipped.\n' "$TARGET_REPO"
    return 0 2>/dev/null || exit 0
fi
# The pane from step 4 is seconds old and its shell may not be interactive yet;
# starting an agent on it now is what `agent_pane_busy` is. Waited for here
# rather than right after `tab create` so a repo whose name cannot be derived
# skips out without paying 13s first.
pmv_settle
# `--dangerously-skip-permissions` is required, not a convenience: nobody is at
# the keyboard of this pane, so one permission prompt would park the
# verification forever instead of failing it (same reason as dEitY719/dotfiles#1393).
if ! START_JSON=$(herdr agent start "$PMV_AGENT" --kind claude --pane "$NEW_PANE" \
    -- --dangerously-skip-permissions 2>/dev/null); then
    # Race backstop: the name can be claimed between the probe and the start,
    # and its holder is by definition a usable agent — prompt it rather than
    # failing the dispatch (same backstop as _pmt_launch_fresh).
    START_CODE=$(printf '%s' "$START_JSON" | pmv_error_code)
    if [ "$START_CODE" != "agent_name_taken" ]; then
        # The tab from step 4 is agent-less at this point — nothing lost by
        # closing it. Only this run's own tab, and only when its id is known
        # (dEitY719/dotfiles#1554): guessing which tab to close from a failed read would risk
        # closing someone else's.
        if [ -n "$NEW_TAB" ]; then
            if herdr tab close "$NEW_TAB" >/dev/null 2>&1; then
                printf '[INFO] gh-verify:post-merge-verify: closed the empty verification tab %s.\n' "$NEW_TAB"
            else
                printf '[WARN] gh-verify:post-merge-verify: could not close tab %s — close it by hand.\n' "$NEW_TAB"
            fi
        fi
        printf '[WARN] gh-verify:post-merge-verify: herdr agent start %s failed on pane %s (%s) — verification skipped.\n' \
            "$PMV_AGENT" "$NEW_PANE" "${START_CODE:-unknown}"
        return 0 2>/dev/null || exit 0
    fi
    # This session was already registered, so it has been up for a while and
    # takes the prompt at once — no need to pay the settle wait below.
    printf '[WARN] gh-verify:post-merge-verify: agent %s already registered — prompting the existing session.\n' "$PMV_AGENT"
else
    # A just-started claude is idle but not yet listening (dEitY719/dotfiles#1571) — this
    # settle wait is what lets it start listening before the prompt lands.
    pmv_settle
fi

# --- 6. F-5: hand the verification over -----------------------------------
# The registry stores the skill id (`gh-verify:merged`); a pane is typed
# the dash form, which is what a Claude session accepts as a slash command.
VERIFY_PROMPT="/$(printf '%s' "$VERIFY_SKILL" | tr ':' '-') ${PR_NUMBER}"
PROMPT_TRY=1
while :; do
    PROMPT_JSON=$(herdr agent prompt "$PMV_AGENT" "$VERIFY_PROMPT" \
        --wait --until idle --timeout "${PMV_PROMPT_TIMEOUT_MS:-900000}" 2>&1)
    PROMPT_RC=$?
    [ "$PROMPT_RC" -eq 0 ] && break
    PROMPT_CODE=$(printf '%s' "$PROMPT_JSON" | pmv_error_code)
    if pmv_prompt_retryable "$PROMPT_CODE" &&
        [ "$PROMPT_TRY" -lt "$PMV_PROMPT_ATTEMPT_MAX" ]; then
        printf '[WARN] gh-verify:post-merge-verify: herdr agent prompt %s failed (%s) — retrying after %ss settle (%s/%s).\n' \
            "$PMV_AGENT" "${PROMPT_CODE:-unknown}" "$PMV_SETTLE_SECONDS" "$PROMPT_TRY" "$PMV_PROMPT_ATTEMPT_MAX"
        PROMPT_TRY=$((PROMPT_TRY + 1))
        pmv_settle
        continue
    fi
    break
done
if [ "${PROMPT_RC:-0}" -ne 0 ]; then
    PROMPT_CODE=$(printf '%s' "$PROMPT_JSON" | pmv_error_code)
    if pmv_prompt_retryable "$PROMPT_CODE"; then
        pmv_escalate_prompt_stall "$NEW_TAB" "$PMV_AGENT"
    fi
    printf '[WARN] gh-verify:post-merge-verify: herdr agent prompt %s failed (%s) — attach and run it by hand.\n' \
        "$PMV_AGENT" "${PROMPT_CODE:-unknown}"
fi

# --- 7. report ------------------------------------------------------------
printf 'post-merge verification dispatched\n'
printf '  tab:    %s (label pr-%s)\n' "${NEW_TAB:--}" "$PR_NUMBER"
# Reported because nothing removes it: the operator who closes the tab is the
# one who can also drop this directory (dEitY719/dotfiles#1577 leaves teardown unautomated).
printf '  cwd:    %s\n' "$PMV_SCRATCH"
printf '  agent:  %s\n' "$PMV_AGENT"
printf '  verify: %s\n' "$VERIFY_PROMPT"
printf '  attach: herdr agent attach %s\n' "$PMV_AGENT"
```

## Inputs

| Variable | Bound by | Notes |
|---|---|---|
| `PR_NUMBER` | Step 1 | The merged PR |
| `TARGET_REPO` / `TARGET_HOST` | Step 2 | One remote URL, dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407 |
| `HEAD_BRANCH` | caller | The merged PR's head branch, used to find the impl worktree |
| `BASE_BRANCH` | caller | The merged PR's base branch (`baseRefName`). Empty → the main checkout's current branch, and a detached HEAD stops the run |
| `REMOTE` | Step 1, optional | The `[remote]` positional; default `origin`. `fetch`/`rebase` use it, never a hardcoded `origin` |
| `PMV_PROMPT_TIMEOUT_MS` | env, optional | `herdr agent prompt --wait` cap, default 900000 (15 min) |
| `PMV_PROMPT_ATTEMPT_MAX` | env, optional | Retry budget for `agent_prompt_stalled` / `timeout`, default 3 |
| `PMV_SETTLE_SECONDS` | env, optional | Wait after each herdr call that brings something up, default 13; `0` disables both waits (dEitY719/dotfiles#1571) |

`--wait --until idle` waits for the dispatched session to settle, so the
timeout is generous. Hitting it is a `[WARN]`, not a failure: the prompt has
already landed, and the attach hint is still printed.

`gh-pr:merge` already read both refs in its own Step 2 pre-flight and passes
them down. Standalone, recover them from the same PR — host-pinned and
repo-scoped, the only GitHub call this skill makes and a read:

```bash
GH_HOST="$TARGET_HOST" gh pr view "$PR_NUMBER" --repo "$TARGET_REPO" \
    --json headRefName,baseRefName -q '.headRefName + " " + .baseRefName'
```

`REMOTE`/`BASE_BRANCH` are never hardcoded to `origin`/`main`: a watched repo
may default to `master` or `develop`, and a registered repo may be reached
through `upstream`. The fallbacks keep the block from ever expanding to
`git fetch "" ""` — `REMOTE` defaults to `origin`, and an empty `BASE_BRANCH`
becomes the main checkout's own current branch, never a detached HEAD.

## herdr JSON shapes this relies on (verified against herdr 0.7.5)

| Call | Field read |
|---|---|
| `herdr agent list` | `.result.agents[].cwd`, `.foreground_cwd`, `.tab_id` (no `--json` flag; it answers JSON on stdout already) |
| `herdr worktree list --cwd P --json` | `.result.source.source_workspace_id`, `.result.worktrees[].path`, `.open_workspace_id` |
| `herdr tab create` | `pane_id` / `tab_id`, read by leaf name |
| `herdr agent start` / `prompt` | `.error.code` on failure |
