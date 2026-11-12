#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/ai_cli_run.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/ai_cli_run.sh
# AI CLI runner shared by the PR review engine (functions/gh_pr_review.sh)
# and the issue review engine (functions/gh_issue_review.sh) — issue #2381.
#
# Moved out of gh_pr_review.sh by #2381 under its old `_gh_pr_review_*`
# names; #2382 gave them the neutral `_ai_cli_*` prefix, since neither
# engine owns them. Also owns _ai_cli_check_output, the "exit 0 is not a
# review" gate (#2084, #2248) both engines apply to the CLI's stdout.
#
# Pure function library: no interactive guard, because it is only ever
# sourced by non-interactive consumers (the two engines, the fanout core,
# skills, bats) — same rationale as lib/gh_host.sh. It needs `ux_error`;
# the engines define it (or a plain stand-in) before sourcing this file.

# _ai_cli_require — validates that the requested AI CLI is
# one of the five allowed values AND that its binary is on PATH.
# Exits 1 with `Required CLI '<name>' not found in PATH` if the binary
# is missing (matches references/ai-cli-invocation.md § "PATH pre-flight").
# Exits 2 with `Unknown --ai value: '...'` if the value is unknown.
_ai_cli_require() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local ai="$1"
    case "$ai" in
    codex | agy | claude | opencode | hermes) ;;
    *)
        ux_error "Unknown --ai value: '$ai' (allowed: codex, agy, claude, opencode, hermes)"
        return 2
        ;;
    esac
    # No internal-PC gate for opencode / hermes since #2069: a lane whose
    # provider is unreachable fails at run time and is skipped by the caller.
    case "$ai" in
    agy)
        # Since #1761 the agy lane builds its stdin NDJSON and parses the
        # stream-json reply with `jq`, so jq is as much a hard requirement as
        # the CLI itself. Without this check a jq-less host fails deep inside
        # the lane with `jq: command not found` attributed to agy — name the
        # tool that is actually missing (PR #1765 codex BLOCKER).
        if ! command -v jq >/dev/null 2>&1; then
            ux_error "Required CLI 'jq' not found in PATH (--ai agy needs it for the stream-json transport)"
            return 1
        fi
        ;;
    esac
    if ! command -v "$ai" >/dev/null 2>&1; then
        ux_error "Required CLI '$ai' not found in PATH"
        return 1
    fi
    return 0
}

# _ai_cli_opencode_model — print the opencode review model, or
# nothing when unconfigured (issue #2007). Same lookup as _gh_ghes_host in
# gh_host.sh, copied locally because this file is vendored standalone:
# `$DOTFILES_OPENCODE_REVIEW_MODEL` wins, else the assignment is parsed (never
# sourced) out of the gitignored env/internal.local.sh.
_ai_cli_opencode_model() {
    if [ -n "${DOTFILES_OPENCODE_REVIEW_MODEL-}" ]; then
        printf '%s\n' "$DOTFILES_OPENCODE_REVIEW_MODEL"
        return 0
    fi
    _gpom_file="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/env/internal.local.sh"
    if [ -r "$_gpom_file" ]; then
        sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}DOTFILES_OPENCODE_REVIEW_MODEL=[\"']\{0,1\}\([A-Za-z0-9._/:-]*\).*/\2/p" \
            "$_gpom_file" 2>/dev/null | sed -n '$p'
    fi
    unset _gpom_file
}

# _ai_cli_argv_prompt_or_fail — MAX_ARG_STRLEN guard for AI CLIs that
# take the whole prompt as a value argument instead of --file or stdin. The
# kernel caps a single argv string at MAX_ARG_STRLEN (32 pages = 131072 bytes
# on Linux) — passing an oversized prompt straight through would blow past
# that as a bare "Argument list too long" exec failure, so this guards it
# explicitly up front.
# Sole remaining caller is `hermes -z` (issue #1761 moved agy onto stdin via
# --input-format stream-json; `hermes --help` documents no equivalent — its
# one-shot flag is `-z PROMPT` / `--oneshot PROMPT`, positional only). Revisit
# if hermes grows a stdin path.
# Args: $1 = CLI label for the error message (e.g. "hermes -z"),
#       $2 = prompt_file to read, $3 = file to write an over-limit or
#       read-error message to.
# On success prints the prompt content on stdout and returns 0; on
# failure returns 1 with nothing on stdout.
_ai_cli_argv_prompt_or_fail() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _cli_label="$1"
    local _prompt_file="$2"
    local _err_file="$3"
    local _size
    if ! _size=$(wc -c <"$_prompt_file"); then
        printf '%s: could not determine prompt file size\n' "$_cli_label" >"$_err_file"
        return 1
    fi
    if [ "$_size" -ge 131072 ]; then
        printf '%s: prompt is %s bytes, over the %s-byte argv limit (MAX_ARG_STRLEN) — use --ai codex or --ai claude for this PR instead.\n' \
            "$_cli_label" "$_size" 131072 >"$_err_file"
        return 1
    fi
    cat "$_prompt_file" 2>"$_err_file"
}

# _ai_cli_resolve_claude_account — for --ai claude --user <name>,
# loads `_claude_resolve_account` and returns the resolved CLAUDE_CONFIG_DIR
# on stdout. Exits 1 with the canonical "Unknown claude account" line on
# unknown names. Sources the guard-free tools/custom/lib/claude_accounts_auth.sh
# (#2146), not integrations/claude.sh, whose interactive guard returns early in a
# non-interactive skill run and leaves the function undefined (#2226).
_ai_cli_resolve_claude_account() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local user="$1"
    local _sc="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
    if ! command -v _claude_resolve_account >/dev/null 2>&1; then
        local _helper="$_sc/tools/custom/lib/claude_accounts_auth.sh"
        # shellcheck disable=SC1090
        [ -f "$_helper" ] && . "$_helper"
    fi
    # The whitelist is exported by env/claude.sh at shell init; a non-interactive
    # skill run may not have inherited it, which would reject every --user as
    # "(allowed: )". Same fallback as tools/custom/claude_accounts.sh. Its exports
    # persist in the caller, exactly as if env/claude.sh had run at shell init.
    # [ -f ]: a vendored shell-common (gh-verify-skills) ships no env/ tree.
    local _env="$_sc/env/claude.sh"
    if [ -z "${CLAUDE_ENABLED_ACCOUNTS+x}" ] && [ -f "$_env" ]; then
        # shellcheck disable=SC1090
        . "$_env"
    fi
    if ! command -v _claude_resolve_account >/dev/null 2>&1; then
        ux_error "claude account routing helper not available — load shell-common/tools/custom/lib/claude_accounts_auth.sh"
        return 1
    fi
    local _cfg
    if ! _cfg=$(_claude_resolve_account "$user" 2>/dev/null); then
        local _allowed
        _allowed=$(_claude_resolve_account --list 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
        ux_error "Unknown claude account: '$user' (allowed: $_allowed)"
        return 1
    fi
    printf '%s\n' "$_cfg"
    return 0
}

# _ai_cli_stderr_is_noise — returns 0 (true) when a stderr line is
# known informational/startup output from one of the supported CLIs, not
# an actual failure cause. Keeps the noise list explicit so future CLI
# updates can extend it without rewriting the dispatcher.
_ai_cli_stderr_is_noise() {
    case "$1" in
    "Reading prompt from stdin"*) return 0 ;; # codex exec startup banner
    "Loaded prompt"*) return 0 ;;             # codex exec follow-up banner
    "") return 0 ;;                           # blank line
    esac
    return 1
}

# _ai_cli_mktemp_safe — SSOT for temp-path allocation in this module.
# Args: $1 = mktemp template ending in `XXXXXX` (e.g. /tmp/foo.XXXXXX).
# Prints the allocated path on stdout and returns 0; prints nothing and
# returns 1 when no path could be allocated safely.
#
# Issue #1283: the old call sites fell back to a bare `$$`-suffixed path
# whenever mktemp failed (unwritable /tmp, quota) and later wrote to it
# with a plain `>` redirect. A local attacker who guesses the PID can
# pre-plant a symlink there and have that redirect clobber whatever the
# link points at. The fallback here creates the path under `set -C`
# (noclobber) in a subshell, which opens with O_CREAT|O_EXCL: a
# pre-existing file *or* symlink makes the create fail, and the caller
# aborts instead of writing through it. A genuine PID-reuse collision
# fails the same way, which is the safe outcome.
_ai_cli_mktemp_safe() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local _template="$1"
    # Fallback is derived from the template so the two can never drift:
    # strip the mktemp placeholder, append this shell's PID.
    local _fallback="${_template%XXXXXX}$$"
    local _path
    if _path=$(mktemp "$_template" 2>/dev/null) && [ -n "$_path" ]; then
        printf '%s\n' "$_path"
        return 0
    fi
    if (
        set -C
        # `mktemp` always creates 0600; a plain `>` redirect instead honours
        # the caller's ambient umask, so under the common `022` the prompt /
        # AI-output / comment-body temp files would be world-readable to
        # other local users (codex review, PR #1284). Tighten inside the
        # subshell so the caller's umask is left untouched.
        umask 077
        : >"$_fallback"
    ) 2>/dev/null; then
        printf '%s\n' "$_fallback"
        return 0
    fi
    return 1
}

# _ai_cli_mktemp_prompt — lane-discriminated unique prompt-file path.
# SSOT for PROMPT_FILE naming (issue #1276). Mirrors the `$ai`-discriminated
# mktemp template used for the stderr file in _ai_cli_run: the
# `XXXXXX` suffix avoids the predictable-PID symlink-attack class, and the
# `$ai` + PR discriminators keep parallel lanes apart. devx:pr-review-all
# dispatches agy and codex as separate subagents in the same turn — a shared
# or hardcoded prompt path lets one lane clobber the other's prompt, so both
# CLIs review byte-identical input and the run silently false-passes.
# Args: $1 = ai (codex|agy|claude|opencode), $2 = PR number (for debuggability).
# Prints a path on stdout; returns non-zero and prints nothing when no
# path could be allocated safely (see _ai_cli_mktemp_safe for the
# noclobber fallback), so this stays the single place that knows the
# PROMPT_FILE naming template.
# Both args are sanitized to `[A-Za-z0-9_-]` before touching the path —
# an unvalidated PR token (e.g. containing `/`) could otherwise steer
# the mktemp template outside /tmp (codex review, PR #1282 / issue #1276).
_ai_cli_mktemp_prompt() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local ai pr
    ai=$(printf '%s' "${1:-unknown}" | tr -cd 'A-Za-z0-9_-')
    pr=$(printf '%s' "${2:-0}" | tr -cd 'A-Za-z0-9_-')
    [ -n "$ai" ] || ai="unknown"
    [ -n "$pr" ] || pr="0"
    _ai_cli_mktemp_safe "/tmp/gh-pr-review-prompt.$ai.$pr.XXXXXX"
}

# _ai_cli_timeout — bounded-run wrapper for the slow CLIs (issue
# #1506); devx_pr_review_all_fanout bounds every lane with it (#2069).
# Args: $1 = seconds, $2.. = command + argv.
#
# `timeout` is GNU coreutils and is absent on a stock macOS (Homebrew
# coreutils installs it as `gtimeout`). With neither, #2074 replaced the old
# unbounded degrade with a POSIX fallback: run the command in the background,
# a watcher subshell `sleep`s N then sends TERM (and KILL after a 2s grace)
# to the command's process group, and expiry returns 124 like GNU timeout
# (#2077: group kill, INT/TERM forwarding, race-free 124). If `sleep` itself
# is missing the watcher could never fire, so the command still runs
# (unbounded) rather than hard-failing. Kept local to this file like `_wsl_check_timeout` in
# shell-common/functions/wsl_check.sh (one call site family, no shared
# contract).
#
# Deliberately no `--preserve-status`: the default exit code 124 is what makes
# "we killed it" distinguishable from any exit code the CLI produces itself.
_ai_cli_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$@"
    else
        # Subshell: the helper variables, traps and `set -m` never leak into
        # the caller.
        (
            [ -n "${ZSH_VERSION-}" ] && emulate -L sh
            _gprt_sec="$1"
            shift
            _gprt_pid=""
            _gprt_watch=""
            # No `sleep` → the watcher could never fire: run unbounded.
            if ! command -v sleep >/dev/null 2>&1; then
                "$@"
                exit
            fi
            # Expiry is decided by this flag (written by the watcher BEFORE it
            # kills), never by trap timing, so expiry always returns 124 (#2077).
            _gprt_flag=$(_ai_cli_mktemp_safe "${TMPDIR:-/tmp}/gh-pr-review-timeout.XXXXXX") || _gprt_flag=""
            # Signal the command's whole process group like GNU timeout, so
            # grandchildren (`bash -c` → hermes) die too; plain pid if the
            # group kill fails (no job control, e.g. zsh without a tty).
            _gprt_kill() {
                kill "-$1" -- "-$_gprt_pid" 2>/dev/null || kill "-$1" "$_gprt_pid" 2>/dev/null
            }
            _gprt_cleanup() {
                [ -n "$_gprt_watch" ] && kill -TERM "$_gprt_watch" 2>/dev/null
                [ -n "$_gprt_flag" ] && rm -f "$_gprt_flag"
            }
            # Ctrl-C / TERM reach the command even though its own group is not
            # the terminal's foreground group (#2077).
            trap '[ -n "$_gprt_pid" ] && _gprt_kill TERM; _gprt_cleanup; exit 130' INT
            trap '[ -n "$_gprt_pid" ] && _gprt_kill TERM; _gprt_cleanup; exit 143' TERM
            # Job control puts the command in its own process group; switched
            # back off at once so no "Terminated" job notice is printed. Probed
            # in a subshell first: zsh refuses monitor without a tty, and in sh
            # emulation a failing `set` would exit this shell.
            { (set -m) && set -m; } 2>/dev/null
            # Explicit <&0: an async list would otherwise get /dev/null stdin.
            "$@" <&0 &
            _gprt_pid=$!
            set +m 2>/dev/null
            (
                _gprt_sleep=""
                trap 'kill "$_gprt_sleep" 2>/dev/null; exit 0' TERM
                sleep "$_gprt_sec" &
                _gprt_sleep=$!
                wait "$_gprt_sleep" || exit 0
                [ -n "$_gprt_flag" ] && echo expired >"$_gprt_flag"
                _gprt_kill TERM || exit 0
                sleep 2 &
                _gprt_sleep=$!
                wait "$_gprt_sleep"
                _gprt_kill KILL
                exit 0
            ) </dev/null >/dev/null 2>&1 &
            _gprt_watch=$!
            wait "$_gprt_pid" 2>/dev/null
            _gprt_rc=$?
            # Group still alive after expiry: let the watcher finish its grace
            # and KILL it. Otherwise the watcher has nothing left to do.
            { [ -s "$_gprt_flag" ] && kill -0 -- "-$_gprt_pid" 2>/dev/null; } ||
                kill -TERM "$_gprt_watch" 2>/dev/null
            wait "$_gprt_watch" 2>/dev/null
            [ -s "$_gprt_flag" ] && _gprt_rc=124
            _gprt_watch=""
            _gprt_cleanup
            exit "$_gprt_rc"
        )
    fi
}

# _ai_cli_run — pipes PROMPT_FILE into the chosen AI CLI per
# references/ai-cli-invocation.md. Returns the CLI's exit code. On
# non-zero exit, prints the full captured stderr (indented) to the
# caller's stderr AND keeps the temp stderr file at a predictable path
# so the user can re-inspect it. On zero exit, the stderr file is
# cleaned up automatically.
#
# Issue #694:
#   - Bug B — `head -n 1` of stderr surfaced informational banners
#     (e.g. codex's "Reading prompt from stdin...") as the failure
#     reason. The dispatcher now skips known-noise prefixes when
#     building the one-line summary AND emits the full stderr below it.
#
# Args: $1 = ai (codex|agy|claude|opencode), $2 = PROMPT_FILE, $3 = optional
# CLAUDE_CONFIG_DIR (claude --user routing), $4 = optional pre-allocated
# stderr temp path. Stdout of the CLI streams to the caller's stdout
# (except agy, which must buffer: its failure cause arrives on stdout, so
# the stream has to survive to be re-read — see that lane's comment);
# stderr is captured for the failure summary.
#
# Issue #2381 adds two optional trailing args; omitting both is byte-for-byte
# the old behavior (the PR engine passes neither):
#   $5 = workdir — the CLI runs with this directory as its cwd, so it can read
#        the code there; opencode gets it as `--dir`, with the prompt copied
#        into a dot-file inside it (opencode-guard rejects a --file outside
#        --dir, #1763) and removed afterwards. Empty: caller's cwd, and
#        opencode keeps its private empty mktemp dir.
#   $6 = opencode instruction — the short argv sentence opencode gets next to
#        the attached prompt file. Empty: the PR review sentence.
_ai_cli_run() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local ai="$1"
    local prompt_file="$2"
    local cfg_dir="${3:-}"
    local workdir="${5:-}"
    local _prev_pwd=""
    # Temp path comes from `_ai_cli_mktemp_safe`, this module's SSOT
    # allocator (issue #1283): mktemp first, then a noclobber fallback that
    # refuses a pre-planted symlink or regular file instead of writing
    # through it. Routed through the helper for consistency with the other
    # three call sites (PROMPT_FILE / AI_OUT / BODY_FILE) — issue #1286.
    # The `$ai` discriminator stays in the name so the user can grep for
    # "the agy run" vs "the codex run" when several invocations linger
    # after failures.
    #
    # Issue #1294: when $4 is given the *caller* already allocated the path
    # (same allocator, same template). A self-allocated path is a local of
    # this function, so gh_pr_review's INT/TERM handler cannot see it and a
    # Ctrl-C during the CLI run leaks it into /tmp. Callers that care hand
    # the path down so it sits in the handler's `rm -f` list; the
    # self-allocating branch stays for direct callers (and tests).
    local _stderr_file="${4:-}" _stderr_owned=0
    if [ -z "$_stderr_file" ]; then
        _stderr_owned=1
        _stderr_file=$(_ai_cli_mktemp_safe "/tmp/gh-pr-review-stderr.$ai.XXXXXX") || {
            ux_error "Could not create stderr temp file under /tmp"
            return 1
        }
    fi
    local _rc=0
    local _prompt_content
    local _opencode_workdir
    local _opencode_prompt
    local _opencode_model
    # Issue #1506: opencode / hermes routinely run 8-10 minutes and had no
    # bounded exit path at all. Without this the only bound is whatever
    # ambient timeout the *caller* (a Bash tool call, a CI step) happens to
    # impose — and when that fires it SIGKILLs the whole process tree, so the
    # `_rc -ne 0` gate in gh_pr_review() that skips Step 6 comment-posting
    # never gets to run, leaving a truncated fragment of CLI output looking
    # like a completed review. Bounding it here turns a hang into a clean
    # non-zero exit that gate already handles. 540s = 9 min, deliberately
    # under the >=600000ms Bash-tool timeout SKILL.md Step 5 mandates for
    # these two lanes. Overridable so tests need not wait 9 minutes.
    local _slow_cli_timeout_sec="${GH_PR_REVIEW_SLOW_CLI_TIMEOUT_SEC:-540}"
    # PR #1542 review (codex): an unvalidated override turns a typo'd
    # GH_PR_REVIEW_SLOW_CLI_TIMEOUT_SEC into an immediate `timeout` usage
    # failure instead of "a longer bound". `0` is also rejected — GNU
    # `timeout 0` means "no limit", which would silently defeat #1506.
    case "$_slow_cli_timeout_sec" in
    '' | *[!0-9.]* | 0 | 0.0)
        printf '[WARN] GH_PR_REVIEW_SLOW_CLI_TIMEOUT_SEC=%s is not a valid positive number — using default 540.\n' \
            "$_slow_cli_timeout_sec" >&2
        _slow_cli_timeout_sec=540
        ;;
    esac
    # Used by the opencode case below only: opencode takes a short
    # instruction as argv with the diff attached via --file "$prompt_file".
    # Caller-overridable since #2381; the default is the PR engine's sentence.
    local _ai_file_instruction="${6:-첨부 파일의 지시사항에 따라 위 PR diff를 리뷰해줘.}"
    local _opencode_dir=""
    if [ -n "$workdir" ]; then
        # Relative paths would break once the cwd moves; anchor them first.
        case "$prompt_file" in /*) ;; *) prompt_file="$PWD/$prompt_file" ;; esac
        case "$_stderr_file" in /*) ;; *) _stderr_file="$PWD/$_stderr_file" ;; esac
        _prev_pwd="$PWD"
        CDPATH='' cd -P -- "$workdir" 2>"$_stderr_file" || {
            ux_error "External AI CLI '$ai' failed (exit 1): cannot enter workdir '$workdir'"
            [ "$_stderr_owned" -eq 1 ] && rm -f "$_stderr_file"
            return 1
        }
    fi
    # A workdir is a real tree read by a CLI fed untrusted text (an issue body):
    # codex and claude get an explicit read-only stance there, beyond the
    # prompt's own "read only" line. No workdir (the PR path): argv unchanged.
    # All positional args were read above, so `set --` is free to reuse.
    set --
    case "$ai" in
    codex)
        [ -n "$workdir" ] && set -- --sandbox read-only
        codex exec --color=never "$@" <"$prompt_file" 2>"$_stderr_file" || _rc=$?
        ;;
    agy)
        # Transport (stream-json on stdin, and the reason for every flag)
        # lives in functions/agy_run.sh — issues #1761 and #1767 both came
        # from this being hand-copied per call site. `response` is what plain
        # `agy --print` used to write to stdout, so everything downstream
        # (tee -> AI_OUT -> comment body) sees the same review text, and the
        # helper returns agy's own exit code, which the summary prints
        # verbatim as "exit $_rc".
        #
        # `2>` before `<` is deliberate: redirections apply left to right, so
        # with `<` first an unreadable $prompt_file is reported before stderr
        # is redirected and the summary below gets "<no stderr>" (bash; zsh
        # reports to the original stderr either way). Do not reorder.
        # Auto-sourced with the rest of functions/ in a real shell; the
        # explicit source is for standalone `. gh_pr_review.sh` (skills, bats).
        # shellcheck disable=SC1090
        command -v _agy_run_stream >/dev/null 2>&1 ||
            . "${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/agy_run.sh"
        _agy_run_stream 2>>"$_stderr_file" <"$prompt_file" || _rc=$?
        ;;
    claude)
        [ -n "$workdir" ] && set -- --disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch"
        if [ -n "$cfg_dir" ]; then
            CLAUDE_CONFIG_DIR="$cfg_dir" claude -p "$@" <"$prompt_file" 2>"$_stderr_file" || _rc=$?
        else
            claude -p "$@" <"$prompt_file" 2>"$_stderr_file" || _rc=$?
        fi
        ;;
    hermes)
        # Confirmed against real `hermes --help` output on an internal PC
        # (issue #1452): there is no `exec` subcommand — the one-shot
        # non-interactive flag is `-z` / `--oneshot`, and it takes the prompt
        # as a value argument rather than --file/stdin, guarded by
        # _ai_cli_argv_prompt_or_fail — see that helper's header for why
        # this lane still has an argv ceiling.
        if _prompt_content=$(_ai_cli_argv_prompt_or_fail "hermes -z" "$prompt_file" "$_stderr_file"); then
            _ai_cli_timeout "$_slow_cli_timeout_sec" \
                hermes -z "$_prompt_content" 2>>"$_stderr_file" || _rc=$?
        else
            _rc=1
        fi
        ;;
    opencode)
        if [ -n "$workdir" ]; then
            _opencode_dir="$PWD"
        else
            _opencode_workdir=$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-review-opencode.XXXXXX") || {
                echo "Could not create opencode run directory under ${TMPDIR:-/tmp}" >"$_stderr_file"
                _rc=1
            }
            _opencode_dir="$_opencode_workdir"
        fi
        if [ "$_rc" -eq 0 ]; then
            _opencode_model=$(_ai_cli_opencode_model)
            if [ -z "$_opencode_model" ]; then
                # Unconfigured: skip like any unavailable reviewer rather
                # than silently fall back to opencode's default model.
                echo "[WARN] --ai opencode skipped: DOTFILES_OPENCODE_REVIEW_MODEL is not set (env or shell-common/env/internal.local.sh)" >"$_stderr_file"
                _rc=1
            fi
        fi
        if [ "$_rc" -eq 0 ]; then
            # opencode-guard auto-rejects, in non-interactive mode, any
            # --file path outside --dir (issue #1763) — PROMPT_FILE always
            # lives in a sibling /tmp dir, never under $_opencode_workdir, so
            # copy it in first and point --file at the copy. A caller workdir
            # is the caller's tree: the copy is a private dot-file there,
            # removed below, never a fixed name that could clobber a file.
            if [ -n "$workdir" ]; then
                _opencode_prompt=$(_ai_cli_mktemp_safe "$_opencode_dir/.ai-cli-prompt.XXXXXX") || {
                    echo "Could not create the opencode prompt copy in $_opencode_dir" >"$_stderr_file"
                    _opencode_prompt=""
                    _rc=1
                }
            else
                _opencode_prompt="$_opencode_workdir/prompt.md"
            fi
            if [ "$_rc" -eq 0 ] && ! cp "$prompt_file" "$_opencode_prompt" 2>"$_stderr_file"; then
                _rc=1
            fi
        fi
        if [ "$_rc" -eq 0 ]; then
            _ai_cli_timeout "$_slow_cli_timeout_sec" \
                opencode run "$_ai_file_instruction" \
                --model "$_opencode_model" \
                --dir "$_opencode_dir" \
                --file "$_opencode_prompt" 2>"$_stderr_file" || _rc=$?
        fi
        [ -n "$_opencode_workdir" ] && rm -rf "$_opencode_workdir"
        [ -n "$workdir" ] && [ -n "$_opencode_prompt" ] && rm -f "$_opencode_prompt"
        ;;
    *)
        ux_error "Unknown --ai value: '$ai' (allowed: codex, agy, claude, opencode, hermes)"
        rm -f "$_stderr_file"
        [ -n "$_prev_pwd" ] && { cd -- "$_prev_pwd" || :; }
        return 2
        ;;
    esac
    [ -n "$_prev_pwd" ] && { cd -- "$_prev_pwd" || :; }
    if [ "$_rc" -ne 0 ]; then
        # Find the first stderr line that is NOT a known informational
        # banner. Falls back to the literal first line so an unknown
        # CLI startup message still produces something.
        local _summary="" _line
        # Issue #1506: exit 124 is _ai_cli_timeout's "I killed it"
        # signal, only ever produced by the opencode/hermes branches above
        # (the only callers of _ai_cli_timeout), so no further
        # per-$ai gate is needed here. Whatever the CLI managed to write to
        # stderr before the kill is a fragment, not a cause, so name the
        # timeout outright instead of letting the generic
        # first-non-noise-line summary imply the CLI reported a failure of
        # its own.
        if [ "$_rc" -eq 124 ]; then
            _summary="timed out after ${_slow_cli_timeout_sec}s — killed before completion, no review posted (issue #1506)"
        fi
        if [ -z "$_summary" ]; then
            while IFS= read -r _line; do
                if ! _ai_cli_stderr_is_noise "$_line"; then
                    _summary="$_line"
                    break
                fi
            done <"$_stderr_file"
        fi
        if [ -z "$_summary" ]; then
            _summary=$(head -n 1 "$_stderr_file" 2>/dev/null)
        fi
        ux_error "External AI CLI '$ai' failed (exit $_rc): ${_summary:-<no stderr>}"
        echo "  full stderr saved to: $_stderr_file" >&2
        echo "  --- stderr (last 20 lines) ---" >&2
        tail -n 20 "$_stderr_file" 2>/dev/null | sed 's/^/  /' >&2
        echo "  --- end stderr ---" >&2
        # Intentionally do NOT rm — leave the file for the user.
        return "$_rc"
    fi
    # A caller-supplied path is the caller's to delete (issue #2084): its
    # empty-review guard keeps the file when exit 0 came with no output.
    [ "$_stderr_owned" -eq 1 ] && rm -f "$_stderr_file"
    return 0
}

# _ai_cli_check_output <ai-stdout-file> — the "exit 0 is not a review"
# gate, shared by the PR and issue engines (moved out of _gh_pr_review_main,
# #2381). Prints nothing and returns 0 when the output is a finished review;
# otherwise prints the reject reason on stdout and returns 1.
#
# Issue #2084: a CLI that succeeds with no text (agy's headless permission
# denial did exactly that) would otherwise post a marker-only comment that
# review-all's aggregation and the duplicate-review guard read as "already
# reviewed". Every --ai lane, not just agy — an empty review is never worth
# posting.
# Issue #2248: non-empty is not enough either. Both engines' prompts make the
# `판정:` / `Verdict:` line mandatory; output without one (hermes once exited
# 0 on a single "Let me check ..." sentence, a usage-limit notice does the
# same) is an unfinished run, not a review.
# Deliberately looser than devx_pr_review_all_verdict (key anywhere in a
# line, `—`/`–`/` - ` accepted): this gate drops the whole review, so a
# variant like "Final verdict: LGTM" must pass here and read as `unknown`
# there. A stray "verdict:" in prose passing is the accepted cost.
_ai_cli_check_output() {
    if ! grep -q '[^[:space:]]' "${1-}" 2>/dev/null; then
        printf '%s\n' "returned an empty review"
        return 1
    fi
    if ! sed -e 's/：/:/g' -e 's/[*`_#>]//g' "$1" 2>/dev/null |
        grep -iqE '(판정|verdict)[[:space:]]*(:|—|–|-[[:space:]])'; then
        printf '%s\n' "returned no verdict line (판정:/Verdict:) — unfinished review"
        return 1
    fi
    return 0
}

# 4-bytes-per-token heuristic, rounded to nearest 500, floor 1000.
# Args: $1 = prompt size in bytes (a number, NOT a path).
#
# Issue #1474 — this used to `wc -c` the PROMPT_FILE path itself, in Step 6,
# long after the file could have vanished; the floor rule then dressed the
# resulting 0 up as a plausible "~1000 tokens". The caller now measures the
# file while it still exists and owns reporting a read failure — see the
# measurement right after _gh_pr_review_build_prompt.
_ai_cli_estimate_tokens() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local raw="$1"
    local tokens
    tokens=$((raw / 4))
    tokens=$(((tokens + 250) / 500 * 500))
    [ "$tokens" -lt 1000 ] && tokens=1000
    printf '%s\n' "$tokens"
}
