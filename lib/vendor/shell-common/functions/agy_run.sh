#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/agy_run.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
case $- in *i*) ;; *) [ -n "${DOTFILES_FORCE_INIT-}" ] || return 0 ;; esac
# shell-common/functions/agy_run.sh
# SSOT for the agy (Antigravity CLI) non-interactive transport.
#
# Why this exists: the same 15 lines were hand-copied into three call sites
# (gh_pr_review.sh, ai_usage.sh, claude_plugins_docs_ko.sh) and had already
# started to drift — one had a `jq` preflight, the others didn't. The shapes
# below were verified against the real CLI, not just `agy --help`:
#   in   {"event":"user","message":{"content":"<prompt>"}}
#   out  {"event":"init",...}
#        {"event":"step_update",...}   (one per turn / tool step)
#        {"event":"result","result":{"status":"SUCCESS","response":"<text>"}}
#
# Two flag facts that cost two bugs to learn, so they live here now:
#  - `agy --print "$prompt"` puts the whole prompt in one argv value, capped
#    by the kernel at MAX_ARG_STRLEN (131072B). Issue #1761: a 62-file PR
#    (131746B) tripped it and produced no review at all.
#  - `--print` still needs a value even in stream-json mode (Go's flag parser
#    rejects a bare `--print` with "flag needs an argument"). Issue #1767: a
#    bare trailing `--print` meant the prompt piped on stdin was never read.
#    So it is passed empty and the stdin message carries the prompt.

# Run agy with the prompt on stdin; print its response text on stdout.
#
# Args: any extra agy flags (e.g. --dangerously-skip-permissions).
# Stdin: the raw prompt text. Stdout: `.result.response` — byte-identical to
# what plain `agy --print <prompt>` used to write, so callers that tee it into
# a file or a comment body need no other change. Stderr is left alone for the
# caller to redirect. Returns agy's own exit code, or 1 when the stream
# carried no SUCCESS result (the exit code alone is NOT the success signal —
# a non-SUCCESS result that still exited 0 would otherwise look like a pass).
_agy_run_stream() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    # Named here rather than reported as a mysterious `jq: command not found`
    # attributed to agy (PR #1765 codex BLOCKER).
    command -v jq >/dev/null 2>&1 || {
        printf "Required CLI 'jq' not found in PATH (agy needs it for the stream-json transport)\n" >&2
        return 1
    }

    local _msg _stream _ec
    # Fail closed: an unreadable prompt (or a jq failure) must not reach agy
    # as empty stdin and come back looking like a successful empty review.
    _msg=$(jq -Rs '{event: "user", message: {content: .}}') || return 1
    # `printf` is a shell builtin, so the prompt reaches agy through a pipe
    # and never through argv — that is the whole point of #1761.
    _stream=$(printf '%s\n' "$_msg" |
        agy "$@" --print '' --input-format stream-json --output-format stream-json)
    _ec=$?
    # One jq pass over the buffered stream, not two (PR #1765 agy FOLLOW-UP):
    # status, response and error come out of the same program. `halt_error`
    # routes the non-SUCCESS cause — reported in `result.error` on *stdout*,
    # not stderr — to stderr so a caller capturing it has something to show,
    # and `jq -e` turns "no result event at all" into a failure instead of
    # silent empty output. Buffering into `_stream` is what makes agy's own
    # exit code recoverable: POSIX has no PIPESTATUS, so mid-pipeline agy
    # would lose it, and the caller logs/prints that code verbatim.
    # SUCCESS with a blank `response` is a failure too (issue #2084): headless
    # agy auto-denies a tool needing command permission and still exits 0 with
    # SUCCESS, and `jq -e` treats "" as truthy — name the cause here so the
    # caller's summary line points at it instead of "<no stderr>".
    printf '%s\n' "$_stream" |
        jq -er 'select(.event == "result")
                | if .result.status == "SUCCESS" then
                      (.result.response // "")
                      | if type == "string" and test("\\S") then .
                        else "agy returned SUCCESS with an empty or non-string response\n" | halt_error(1)
                        end
                  else "agy result status=\(.result.status // "?"): \(.result.error // "no error reported")\n"
                       | halt_error(1)
                  end' || [ "$_ec" -ne 0 ] || _ec=1
    return $_ec
}
