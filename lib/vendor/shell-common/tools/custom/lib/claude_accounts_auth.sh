#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/tools/custom/lib/claude_accounts_auth.sh
# Synced 2026-10-17T01:50Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/tools/custom/lib/claude_accounts_auth.sh
# Claude Code account resolution + auth checks (moved out of
# tools/integrations/claude.sh, #2146).
#
# Source-only, no interactive guard: tools/integrations/claude.sh sources it at
# shell init (claude_yolo needs these), and claude/setup.sh,
# tools/custom/claude_accounts.sh, herdr_pane.sh and gh_pr_review.sh reach the
# same functions non-interactively. Pure function definitions, no output.

# _dotfiles_setup_mode — read ~/.dotfiles-setup-mode and canonicalise.
# Moved to shell-common/util/setup_mode_read.sh (#1810) so the 16 callsites
# that used to re-parse the file share one implementation.
#
# Used by claude_yolo (F-2) to bypass multi-account resolution and by
# claude_accounts_rollback (F-3) to confirm the rollback target.
_ic_setup_mode_read_lib="${SHELL_COMMON:-${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common}/util/setup_mode_read.sh"
if [ -r "$_ic_setup_mode_read_lib" ]; then
    # shellcheck disable=SC1091
    . "$_ic_setup_mode_read_lib"
fi

# _claude_resolve_account — 계정 매핑 SSOT (convention-based, issue #568).
# Usage:
#   _claude_resolve_account <name>     → echo "$HOME/.claude-<name>" when
#                                        <name> is in CLAUDE_ENABLED_ACCOUNTS
#                                        and passes the safe-identifier
#                                        regex. return 1 otherwise.
#   _claude_resolve_account --list     → echo ENABLED accounts (one per line)
#                                        that pass the safe-identifier regex.
#   _claude_resolve_account --list-all → deprecated; same as --list. Kept
#                                        for back-compat with external
#                                        scripts that may still call it.
#
# 새 계정 추가 = claude.local.sh 의 CLAUDE_ENABLED_ACCOUNTS 에 단어 추가
# 만으로 끝. 코드 수정 불필요. 디렉터리는 자동으로 ~/.claude-<name>.
#
# Safe-identifier regex: ^[a-z][a-z0-9_-]*$
# - 첫 글자 소문자, 뒤로 소문자·숫자·하이픈·언더스코어.
# - alias 명·env-var 접미사·디렉터리명 셋 다 안전하게 쓰일 식별자.
_claude_resolve_account() {
    # zsh disables word-splitting by default; emulate sh inside this function
    # so `for x in $LIST` behaves identically to bash/dash. (See MEMORY.md
    # "Zsh-Specific Tracing Behavior" for the same pattern in gcp_scan.sh.)
    if [ -n "${ZSH_VERSION:-}" ]; then
        emulate -L sh
    fi

    case "$1" in
        --list|--list-all)
            # --list-all 은 issue #568 에서 --list 로 통합. 외부 사용자
            # 보호용 호환 alias — 향후 메이저 버전에서 제거 가능.
            # 검증을 인라인으로 — 재귀 호출 시 ENABLED 가 "--list" 같은
            # 플래그 토큰을 포함하면 무한 재귀에 빠질 수 있고, 재귀는
            # O(N²) 비용을 만든다 (gemini review on PR #569).
            # ${VAR:-} 로 set -u 환경에서 unbound 회피.
            # shellcheck disable=SC2086  # intentional word-split for POSIX list iteration
            for _cra_acct in ${CLAUDE_ENABLED_ACCOUNTS:-}; do
                case "$_cra_acct" in
                    [a-z]*) ;;
                    *) continue ;;
                esac
                case "$_cra_acct" in
                    *[!a-z0-9_-]*) continue ;;
                esac
                echo "$_cra_acct"
            done
            return 0
            ;;
    esac

    # name validation: must start with lowercase letter, rest [a-z0-9_-]
    case "$1" in
        [a-z]*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!a-z0-9_-]*) return 1 ;;
    esac

    # ENABLED whitelist check — unknown names fail even if regex-valid.
    # Preserves the "Unknown account: xyz" path in claude_yolo for typos.
    # shellcheck disable=SC2086  # intentional word-split for POSIX list iteration
    for _cra_acct in ${CLAUDE_ENABLED_ACCOUNTS:-}; do
        if [ "$_cra_acct" = "$1" ]; then
            echo "$HOME/.claude-$1"
            return 0
        fi
    done
    return 1
}

# _claude_account_logged_in <config-dir> — "이 계정 디렉터리가 로그인 상태인가".
# 0 = logged in, 1 = not. 출력 없음, 네트워크 호출 없음.
#
# 디렉터리 존재는 로그인이 아니다 (issue #1561): `claude-accounts setup` 이
# 디렉터리를 만들고, 채우는 것은 로그인이다. 로그아웃된 계정으로 열린 팬은
# `Not logged in · Run /login` 화면에서 모든 키 입력을 흘리므로, 무인
# 디스패처는 이를 `agent_prompt_stalled` 로 오인해 보고한다.
#
# 존재·비어있지 않음·JSON 으로 파싱됨까지만 본다. 토큰을 파싱하면 이 코드가
# Claude Code 의 비공개 credential 포맷에 묶이고, API 로 확인하면 매 cron tick
# 에 네트워크 왕복이 생긴다 — #1561 에서 둘 다 기각됐다. 구문 검사는 그 둘 중
# 어느 것도 아니다: 키 이름 하나 알지 못한 채, 잘리거나 깨진 파일만 걸러낸다.
# 이 갈래는 실재한다 — 로그인 중 죽은 프로세스나 절반만 쓰인 파일은 `-s` 를
# 통과하고, 팬은 다시 `Not logged in` 으로 열려 이 검사가 막으려던 바로 그
# stall 로 돌아간다 (PR #1566 codex review).
#
# `jq` 는 이 규칙을 쓰는 두 디스패처 모두의 hard dependency 다 (aicron 의
# ensure_jq). 그래도 없는 환경에서 계정 전체를 로그아웃으로 판정하지는 않는다
# — 구문 검사는 보강이지 게이트가 아니므로, jq 가 없으면 그 갈래만 건너뛴다.
#
# 규칙이 여기 사는 이유: "무슨 파일이 로그인을 뜻하는가" 는 이 파일이 이미
# 세 군데(claude_accounts_status, claude_accounts_rollback)에서 손으로 쓰고
# 있던 계약이다. #1530 이 남긴 교훈대로, 복사된 규칙은 복사된 만큼 어긋난다.
#
# internal PC (#2116) 는 OAuth 가 아니라 사내 gateway `apiKeyHelper` 로 인증하므로
# `.credentials.json` 이 애초에 생기지 않는다. 그 모드에서만 판정을 넓힌다 —
# external 은 OAuth 구독 로그인이 유일한 증거라 규칙을 그대로 둔다.
# 판정은 `_claude_account_auth_kind` 한 곳에 두고 이 함수는 그 결과만 본다.
_claude_account_logged_in() {
    [ "$(_claude_account_auth_kind "${1:-}")" != "none" ]
}

# _claude_account_auth_kind <config-dir> — prints the auth method in use:
#   oauth | apiKeyHelper | apikey | none      (always exits 0)
# apiKeyHelper / apikey 는 internal 모드에서만 인정한다 (위 주석 참조).
_claude_account_auth_kind() {
    _caak_dir="${1:-}"
    [ -n "$_caak_dir" ] || { echo none; return 0; }
    if [ -r "$_caak_dir/.credentials.json" ] && [ -s "$_caak_dir/.credentials.json" ]; then
        if ! command -v jq >/dev/null 2>&1 || jq -e . "$_caak_dir/.credentials.json" >/dev/null 2>&1; then
            echo oauth
            return 0
        fi
    fi
    if _dotfiles_setup_mode_is internal; then
        # shortcut: grep, not jq — only "non-empty string value" matters; upgrade if settings ever nest it.
        if grep -qs '"apiKeyHelper"[[:space:]]*:[[:space:]]*"[^"]' \
            "$_caak_dir/settings.json" "$_caak_dir/settings.local.json"; then
            echo apiKeyHelper
            return 0
        fi
        if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
            echo apikey
            return 0
        fi
    fi
    echo none
}

# _claude_expected_email <account-name> — expected oauth email lookup.
# Reads CLAUDE_ACCOUNT_EMAIL_<account> if defined, else echoes nothing.
# Opt-in mapping convention from issue #300, items B and C — kept in a
# helper so claude_yolo and claude_accounts_status share the same source
# of truth.
#
# Uses eval (not ${!var}) for POSIX sh portability — the input is always
# an account name vetted by _claude_resolve_account, so injection is not
# a concern.
_claude_expected_email() {
    _ceeem_acct="$1"
    [ -n "$_ceeem_acct" ] || return 0
    eval "echo \"\${CLAUDE_ACCOUNT_EMAIL_${_ceeem_acct}:-}\""
}

# _claude_validate_login — expected ↔ actual oauth email check (issue #300-B).
#
# Catches the "wrong Google account on browser" trap: a leftover personal
# Google session bleeds into the OAuth flow for `claude-yolo --user work`,
# leaving the work CLAUDE_CONFIG_DIR populated with personal credentials.
# The code in this repo can't influence the browser, but it CAN cross-check
# the resulting .claude.json against an expected email and warn loudly so
# the user can recover before the misbinding becomes load-bearing.
#
# Opt-in: caller defines `CLAUDE_ACCOUNT_EMAIL_<account>` (e.g.
# `CLAUDE_ACCOUNT_EMAIL_work=alice@corp.com`) in claude.local.sh. Without
# the mapping the function silently returns — zero-config / zero-regression
# for everyone who doesn't opt in.
_claude_validate_login() {
    _cvl_dir="$1"
    _cvl_acct="$2"

    _cvl_expected=$(_claude_expected_email "$_cvl_acct")
    [ -n "$_cvl_expected" ] || return 0

    _cvl_json="$_cvl_dir/.claude.json"
    [ -f "$_cvl_json" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    _cvl_actual=$(jq -r '.oauthAccount?.emailAddress? // empty' "$_cvl_json" 2>/dev/null)
    [ -n "$_cvl_actual" ] || return 0
    [ "$_cvl_expected" = "$_cvl_actual" ] && return 0

    ux_warning "Account mismatch on '$_cvl_acct':"
    ux_warning "  expected: $_cvl_expected (CLAUDE_ACCOUNT_EMAIL_${_cvl_acct})"
    ux_warning "  actual:   $_cvl_actual (.claude.json oauthAccount)"
    ux_info    "  → 다른 Google 계정으로 잘못 로그인된 자격증명일 수 있습니다."
    ux_info    "  → 복구: rm '$_cvl_dir/.credentials.json' '$_cvl_json' && claude-yolo --user $_cvl_acct"
}
