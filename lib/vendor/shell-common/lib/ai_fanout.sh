#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/ai_fanout.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/ai_fanout.sh
# Parallel lane fan-out core (issue #2381), moved out of
# devx_pr_review_all_fanout (#2069) so the issue review skill can run lanes
# without vendoring the PR code. devx_pr_review_all_fanout stays its caller
# with an unchanged output contract.
#
# Pure function library: no interactive guard — sourced only by
# non-interactive consumers (devx_pr_review_all.sh, skills, bats), same
# rationale as lib/gh_host.sh.
#
# ai_fanout_run <workdir> <timeout-sec> <lanes> <entry-cmd> [<arg>...]
#   Runs `<entry-cmd> [<arg>...] <lane>` for every comma-separated lane at
#   once, each in a subshell whose cwd is <workdir> (empty: the caller's
#   cwd), bounded by _ai_cli_timeout at <timeout-sec> (non-numeric or
#   empty: 540). stdin is /dev/null. Once every lane has exited, prints one
#   line per lane, in <lanes> order:
#     <lane>:ok               rc 0
#     <lane>:skip<TAB><why>   any other rc. <why> is the first non-blank
#                             stderr line, whitespace squeezed; `exit <rc>`
#                             when stderr was empty; `timeout <N>s` when the
#                             cap fired (rc 124).
#   Each lane's stdout / stderr / rc goes to its own file under one private
#   mktemp dir (#1276), removed afterwards; lane stdout never reaches the
#   result lines. Returns 0; 2 on an argument error (a lane outside
#   [A-Za-z0-9_:-], a repeated lane, an empty lane list, a missing entry command, a workdir
#   that is not a directory); 1 when the temp dir cannot be created.
ai_fanout_run() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local workdir="${1-}" sec="${2-}" lanes="${3-}"
    local _dir="" _rest="" _lane="" _f="" _order="" _pids="" _pid="" _rc="" _why=""
    if [ "$#" -lt 4 ] || [ -z "$lanes" ]; then
        echo "usage: ai_fanout_run <workdir> <timeout-sec> <lane>[,<lane>...] <entry-cmd> [<arg>...]" >&2
        return 2
    fi
    shift 3
    # Lane tokens become file names and are word-split below: keep them tame.
    case ",$lanes," in
    *[!A-Za-z0-9_:,-]* | *,,*)
        echo "ai_fanout_run: invalid lane list '$lanes'" >&2
        return 2
        ;;
    esac
    # A repeated lane would share its result files with its twin and race.
    _rest="$lanes"
    while [ -n "$_rest" ]; do
        _lane="${_rest%%,*}"
        case "$_rest" in *,*) _rest="${_rest#*,}" ;; *) _rest="" ;; esac
        case ",$_rest," in *",$_lane,"*)
            echo "ai_fanout_run: lane repeated: '$_lane'" >&2
            return 2
            ;;
        esac
    done
    if [ -n "$workdir" ] && [ ! -d "$workdir" ]; then
        echo "ai_fanout_run: workdir '$workdir' is not a directory" >&2
        return 2
    fi
    case "$sec" in "" | *[!0-9]*) sec=540 ;; esac
    if ! command -v _ai_cli_timeout >/dev/null 2>&1; then
        # shellcheck disable=SC1090,SC1091
        . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/lib/ai_cli_run.sh" || return 1
    fi
    _dir=$(mktemp -d "${TMPDIR:-/tmp}/ai-fanout.XXXXXX") || {
        echo "Could not create fanout run directory under ${TMPDIR:-/tmp}" >&2
        return 1
    }

    _rest="$lanes"
    while [ -n "$_rest" ]; do
        _lane="${_rest%%,*}"
        case "$_rest" in *,*) _rest="${_rest#*,}" ;; *) _rest="" ;; esac
        _order="$_order $_lane"
        _f="$_dir/$(printf '%s' "$_lane" | tr ':' '.')"
        (
            if [ -n "$workdir" ]; then
                CDPATH='' cd -- "$workdir" 2>"$_f.err" || {
                    echo 1 >"$_f.rc"
                    exit 0
                }
            fi
            _ai_cli_timeout "$sec" "$@" "$_lane" </dev/null >"$_f.out" 2>"$_f.err"
            echo "$?" >"$_f.rc"
        ) &
        _pids="$_pids $!"
    done
    # Our own PIDs only — a bare `wait` would also block on the caller's jobs.
    for _pid in $_pids; do
        wait "$_pid"
    done

    # Validated lanes are [A-Za-z0-9_:-] tokens, safe to word-split.
    for _lane in $_order; do
        _f="$_dir/$(printf '%s' "$_lane" | tr ':' '.')"
        _rc=$(cat "$_f.rc" 2>/dev/null)
        if [ "$_rc" = 0 ]; then
            printf '%s:ok\n' "$_lane"
            continue
        fi
        if [ "$_rc" = 124 ]; then
            _why="timeout ${sec}s"
        else
            _why=$(tr '\t\r' '  ' <"$_f.err" 2>/dev/null |
                sed -n '/[^[:space:]]/{s/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//;p;q;}')
            [ -n "$_why" ] || _why="exit ${_rc:-unknown}"
        fi
        printf '%s:skip\t%s\n' "$_lane" "$_why"
    done
    rm -rf "$_dir"
    return 0
}
