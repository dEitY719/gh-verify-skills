#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/herdr_agent_lookup.sh
# Synced 2026-09-05T10:16Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/herdr_agent_lookup.sh
# SSOT for "is a herdr agent sitting on this worktree?" (issue #1569).
#
# Four call sites ask that question and, before this file, each carried its own
# hand-copied answer:
#
#   shell-common/tools/custom/issue_watcher_cron.sh        _iw_live_agents
#   claude/skills/gh-pr-post-merge-verify/references/
#       dispatch.sh.md                                     pmv_tab_for_cwd
#   claude/skills/gh-pr-merge/references/
#       herdr-tab-notify.sh.md                             an inline jq block
#   claude/skills/gh-pr-merge-train/references/
#       train-loop.md                                      an inline jq block
#
# They had already drifted into three different predicates. The newest copy —
# the merge hint — matched `.cwd` by plain string equality, so it missed both
# an agent that had `cd`-ed one directory into its worktree and a worktree
# reached through a symlink; the other three matched `.cwd` OR
# `.foreground_cwd`, on a path boundary, against the physical path. This is the
# #1530 shape exactly (three copies of a slug helper, all wrong, one file to
# fix), which is why the fix is the same shape: one helper, four callers.
#
# What the predicate has to get right, and why each half is load-bearing:
#
#   both columns   `cwd` is where the pane was opened (stable for the session's
#                  whole life); `foreground_cwd` is where its shell stands now.
#                  Taking only `cwd` loses the session that `cd`-ed away, and
#                  losing it makes issue-watcher's collection step read a live
#                  worktree as idle (PR #1456 review). Taking only
#                  `foreground_cwd` loses the pane whose shell never moved.
#   boundary       An agent in `<wt>/docs/.ssot` is still working `<wt>`, so a
#                  bare equality is too narrow — but a bare `startswith` is too
#                  wide: `/work/repo-1` would swallow `/work/repo-11` and close
#                  a sibling checkout's tab (PR #1518 review). The boundary is
#                  `. == $b or startswith($b + "/")`, and an EMPTY $b matches
#                  nothing at all rather than everything.
#   physical path  `git worktree list` answers the path as it was created,
#                  herdr answers where the pane really stands. One symlinked
#                  component makes those two strings differ.
#
# And the part that is not about matching at all: a herdr that answers nothing
# must never be read as "no agent is running". Every caller's comments call
# that out as the one unacceptable mistake — it would lift issue-watcher's
# concurrency cap exactly when herdr is unhealthy, and it would let the
# post-merge dispatch report "nothing to close" for a tab that is very much
# still there. So the lookups split three ways by RETURN CODE, never by an
# empty string:
#
#   0   matched; the answer is on stdout
#   1   herdr could not be asked at all (call failed, or answered nothing)
#   3   herdr answered, and nothing matched this path (and/or status filter)
#
# rc 3 rather than 2 is not arbitrary: `pmv_tab_for_cwd` shipped this exact
# convention in gh:pr-post-merge-verify, and its caller branches on 0 / 1 /
# else. Keeping the numbers means re-pointing that caller at this file, not
# rewriting how it reads the answer.
#
# `first`, then the status filter — never the other way round. Two agents on
# one worktree is abnormal, and every call site's documented rule is
# take-the-first-and-warn-about-nothing. Filtering by status BEFORE picking
# would quietly change that into "find me an idle one", which would close an
# idle tab on a worktree whose other pane is still working.
#
# No interactive guard, for the same reason gh_host.sh and herdr_agent_name.sh
# have none: the body is pure definitions and produces no output at file scope,
# and every real caller is a non-interactive cron tick, hook, or pasted skill
# block that sources this file directly.
#
# `herdr` and `jq` are invoked by name so a caller's test seam (a shell
# function shadowing either) still works — that is how the three bats fixture
# mirrors drive this file without a herdr server.

# herdr_agent_physical_path <path> — print <path> with every symlink resolved,
# or <path> unchanged when it cannot be entered (an already-removed worktree).
#
# The fallback matters more than the resolution: degrading to the literal path
# keeps the comparison narrow, where degrading to an empty string would make
# the boundary match every agent.
#
# Emits a trailing newline, exactly as `pwd -P` does, so both branches have the
# same shape. Every caller reads it through `$( )`, which strips it.
herdr_agent_physical_path() {
    (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

# herdr_agent_path_under <candidate> <base> — the boundary predicate, as a
# shell test rather than a jq one, so a pure-shell caller that already holds a
# `cwd`/`foreground_cwd` pair (e.g. issue_watcher_cron.sh's per-pane join,
# which also needs each pane's `agent_status` and so cannot use the jq-side
# lookups below) can call it directly instead of re-deriving the boundary
# rule in awk or jq.
#
# rc 0 when <candidate> IS <base> or lives under it. An empty <base> matches
# nothing: that is the guard that keeps a failed path lookup from matching
# every agent.
herdr_agent_path_under() {
    [ -n "${2-}" ] || return 1
    case "${1-}" in
    "$2" | "$2"/*) return 0 ;;
    esac
    return 1
}

# herdr_agent_list_json — one `herdr agent list`, on stdout.
#
# rc 1 when herdr could not be asked: a failed call, or a call that answered
# nothing. Both are "unknown", never "nothing running".
herdr_agent_list_json() {
    _hal_json=$(herdr agent list 2>/dev/null) || {
        unset _hal_json
        return 1
    }
    if [ -z "${_hal_json}" ]; then
        unset _hal_json
        return 1
    fi
    printf '%s' "${_hal_json}"
    unset _hal_json
}

# herdr_agent_match_for_cwd <physical-path> [status-filter] — the agent sitting
# on <physical-path>, as `<tab_id><TAB><agent_status><TAB><workspace_id>`.
#
# [status-filter], when non-empty, requires the matched agent's `.agent_status`
# to equal it — `idle`, for the two callers that must never touch a session
# with work in flight. It filters the FIRST match rather than choosing among
# matches; see the `first` note in this file's header.
#
#   0   matched (and passed the filter); the TSV line is on stdout
#   1   herdr could not be asked
#   3   herdr answered; nothing on this path, or the first match's status is
#       not the requested one
#
# An empty <physical-path> is rc 3 without asking herdr: it can only be a
# lookup that already failed, and answering it would mean matching everything.
herdr_agent_match_for_cwd() {
    [ -n "${1-}" ] || return 3

    _hal_json=$(herdr_agent_list_json) || {
        unset _hal_json
        return 1
    }

    _hal_row=$(printf '%s' "${_hal_json}" | jq -r --arg p "$1" --arg s "${2-}" '
        def under($b): . == $b or startswith($b + "/");
        if (.result.agents | type) == "array" then
          [ .result.agents[]?
            | select(((.cwd // "") | under($p)) or ((.foreground_cwd // "") | under($p))) ]
          | first
          | select(. != null)
          | select($s == "" or (.agent_status // "") == $s)
          | [ (.tab_id // ""), (.agent_status // ""), (.workspace_id // "") ]
          | @tsv
        else error("no agent list") end
    ' 2>/dev/null) || {
        unset _hal_json _hal_row
        return 1
    }

    if [ -z "${_hal_row}" ]; then
        unset _hal_json _hal_row
        return 3
    fi
    printf '%s' "${_hal_row}"
    unset _hal_json _hal_row
}

# herdr_agent_tab_for_cwd <physical-path> [status-filter] — the tab_id of the
# agent sitting on <physical-path>. Same three return codes, same filter rule,
# as herdr_agent_match_for_cwd; this is the narrow form for the callers that
# only ever want a tab to close.
#
# A matched agent carrying no tab_id is rc 3, not rc 0 with an empty string:
# asking herdr to shut an empty tab id is not a close, and a caller that got
# rc 0 would report one anyway.
herdr_agent_tab_for_cwd() {
    _hal_match=$(herdr_agent_match_for_cwd "$1" "${2-}")
    _hal_rc=$?
    if [ "${_hal_rc}" -ne 0 ]; then
        unset _hal_match
        return "${_hal_rc}"
    fi

    _hal_tab=$(printf '%s' "${_hal_match}" | cut -f1)
    if [ -z "${_hal_tab}" ]; then
        unset _hal_match _hal_tab
        return 3
    fi
    printf '%s' "${_hal_tab}"
    unset _hal_match _hal_tab
}
