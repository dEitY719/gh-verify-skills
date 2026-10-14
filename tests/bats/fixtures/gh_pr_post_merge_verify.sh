# shellcheck shell=bash
# The stubs are called, and the bindings read, by the fence sourced below,
# which shellcheck cannot see into.
# shellcheck disable=SC2034,SC2317
# tests/bats/fixtures/gh_pr_post_merge_verify.sh
#
# Runs the REAL dispatch: the first bash fence of
#   skills/post-merge-verify/references/dispatch.sh.md
# extracted with the consumer's own awk (the same program tests/dispatch-fence.sh
# and gh-pr:merge's lib/post-merge-verify-dispatch.sh use) and sourced against
# stand-ins for herdr, git, sleep, rm and mkdir. Nothing here re-implements the
# dispatch: until dEitY719/dotfiles#2200 this file was a hand mirror of the
# fence living in dotfiles, and it had drifted on the allowlisted skill ids, the
# prompt form (#69), the message prefix, the [OK] line and the landed-prompt
# probe (#85) without any test noticing. Now the shipped bytes are what runs.
#
# The herdr helpers the fence sources resolve through CLAUDE_PLUGIN_ROOT (tier
# 2) to this repo's lib/vendor/shell-common, so the vendored
# herdr_agent_name.sh / herdr_agent_lookup.sh are what the suite exercises.
#
# Knobs the stand-ins read (all optional):
#   FAKE_HERDR_LOG / FAKE_GIT_LOG       call logs, one line per call
#   FAKE_HERDR_OUT_<SUB_CMD>            stdout of `herdr <sub> <cmd>`
#   FAKE_HERDR_RC_<SUB_CMD>             its exit status (default 0)
#   FAKE_HERDR_PRESENT=0                no herdr on PATH
#   FAKE_JQ_PRESENT=0                   no jq on PATH
#   FAKE_WORKTREE_PORCELAIN             `git [-C x] worktree list --porcelain`
#   FAKE_CWD_COMMON_DIR                 `git rev-parse --git-common-dir` (no -C)
#   FAKE_GIT_COMMON_DIR                 the same with -C <root> (default <root>/.git)
#   FAKE_MAIN_TOPLEVEL                  `git -C <root> rev-parse --show-toplevel`
#   FAKE_MAIN_BRANCH                    `git -C <root> rev-parse --abbrev-ref HEAD`
#   FAKE_MAIN_DIRTY=1                   `git -C <root> status --porcelain` non-empty
#   FAKE_SYNC_RC                        `git -C <root> fetch ...` exit status
#   FAKE_WORKTREE_ADD_RC                `git -C <root> worktree add ...` exit status

PMV_DOC="${REPO_ROOT}/skills/post-merge-verify/references/dispatch.sh.md"

# pmv_extract_fence <out>: the consumer's awk, byte for byte.
pmv_extract_fence() {
    local f='```'
    awk -v f="$f" '$0 == f "bash" && !b { b = 1; next } $0 == f && b { exit } b' \
        "$PMV_DOC" >"$1"
    [ -s "$1" ]
}

# Stand-in for the `herdr` CLI. Records argv into $FAKE_HERDR_LOG, echoes
# $FAKE_HERDR_OUT_<SUB_CMD> and returns $FAKE_HERDR_RC_<SUB_CMD>.
herdr() {
    local _key _out _rc
    [ -z "${FAKE_HERDR_LOG-}" ] || printf 'herdr %s\n' "$*" >>"$FAKE_HERDR_LOG"
    _key=$(printf '%s_%s' "$1" "$2" | tr 'a-z-' 'A-Z_')
    _out="FAKE_HERDR_OUT_${_key}"
    _rc="FAKE_HERDR_RC_${_key}"
    printf '%s' "${!_out-}"
    return "${!_rc:-0}"
}

# $PATH without every directory that holds an executable <name>.
_pmv_path_without() {
    local _d _out="" IFS=:
    for _d in $PATH; do
        [ -x "$_d/$1" ] || _out="${_out:+$_out:}$_d"
    done
    printf '%s' "${_out:-/nonexistent}"
}

_pmv_glog() { [ -z "${FAKE_GIT_LOG-}" ] || printf '%s\n' "$*" >>"$FAKE_GIT_LOG"; }

# Stand-ins installed only inside pmv_dispatch's caller subshell (`run`), so
# bats' own teardown keeps the real rm.
_pmv_install_stubs() {
    git() {
        local _root=""
        if [ "$1" = -C ]; then
            _root="$2"
            shift 2
        fi
        case "$*" in
        "rev-parse --path-format=absolute --git-common-dir")
            if [ -n "$_root" ]; then
                _pmv_glog "common-dir $_root"
                printf '%s\n' "${FAKE_GIT_COMMON_DIR-$_root/.git}"
            else
                printf '%s\n' "${FAKE_CWD_COMMON_DIR-${T_MAIN}/.git}"
            fi
            ;;
        "rev-parse --show-toplevel")
            _pmv_glog "toplevel $_root"
            printf '%s\n' "${FAKE_MAIN_TOPLEVEL-$_root}"
            ;;
        "rev-parse --abbrev-ref HEAD")
            _pmv_glog "branch $_root"
            printf '%s\n' "${FAKE_MAIN_BRANCH-main}"
            ;;
        "status --porcelain")
            _pmv_glog "status $_root"
            if [ "${FAKE_MAIN_DIRTY:-0}" = 1 ]; then printf ' M file\n'; fi
            ;;
        "worktree list --porcelain")
            printf '%s' "${FAKE_WORKTREE_PORCELAIN-}"
            return "${FAKE_WORKTREE_RC:-0}"
            ;;
        "fetch "*)
            _pmv_glog "fetch $_root $2 $3"
            return "${FAKE_SYNC_RC:-0}"
            ;;
        "rebase --abort") _pmv_glog "rebase-abort $_root" ;;
        "rebase "*) _pmv_glog "rebase $_root $2" ;;
        "worktree prune") _pmv_glog "worktree-prune $_root" ;;
        "worktree add --detach "*)
            _pmv_glog "worktree-add $_root $4 $5"
            return "${FAKE_WORKTREE_ADD_RC:-0}"
            ;;
        *)
            _pmv_glog "unexpected git $*"
            return 1
            ;;
        esac
    }
    # The settle waits (#1571) are recorded instead of paid, in the herdr log so
    # their order against the herdr calls they sit between is assertable.
    sleep() { [ -z "${FAKE_HERDR_LOG-}" ] || printf 'sleep %s\n' "$1" >>"$FAKE_HERDR_LOG"; }
    rm() { _pmv_glog "rm-rf ${*: -1}"; command rm "$@"; }
    mkdir() { _pmv_glog "mkdir-p ${*: -1}"; command mkdir "$@"; }
}

# pmv_dispatch <pr> <owner/repo> [remote] [base_branch]
# Binds what Step 1 and the caller bind, then sources the extracted fence.
# Env: T_HEAD (head branch), T_HOST, WATCHED, plus the FAKE_* knobs above.
pmv_dispatch() {
    local _fence="${BATS_TEST_TMPDIR}/dispatch.sh"
    pmv_extract_fence "$_fence" || {
        printf 'could not extract the dispatch fence from %s\n' "$PMV_DOC"
        return 1
    }
    _pmv_install_stubs
    if [ "${FAKE_HERDR_PRESENT:-1}" != 1 ]; then
        unset -f herdr
        PATH=$(_pmv_path_without herdr)
    fi
    [ "${FAKE_JQ_PRESENT:-1}" = 1 ] || PATH=$(_pmv_path_without jq)
    PR_NUMBER="$1" TARGET_REPO="$2" TARGET_HOST="${T_HOST:-github.com}"
    REMOTE="${3-}" BASE_BRANCH="${4-}" HEAD_BRANCH="${T_HEAD:-wt/issue-77/1}"
    IW_WATCHED_REPOS="$WATCHED"
    DOTFILES_ROOT="${BATS_TEST_TMPDIR}/no-dotfiles" CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    # shellcheck source=/dev/null
    . "$_fence"
}

# The vendored helpers the fence sources, for the unit-level pins.
pmv_load_vendored() {
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/lib/vendor/shell-common/functions/herdr_agent_name.sh"
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/lib/vendor/shell-common/functions/herdr_agent_lookup.sh"
}
