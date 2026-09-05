#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/devx_pr_verify_live.sh
# Synced 2026-09-03T08:20Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/functions/devx_pr_verify_live.sh
# Pure arg parser for the devx:pr-verify-live skill. Mirrors the
# devx_pr_review_all_parse contract: one `key=value` line per resolved arg
# on success, errors to stderr. Exit 0 ok/help, exit 2 arg error. Runtime
# checks (PR state, gh auth, dev-server reachability) belong to the skill body.
#
# This file lives under shell-common/functions/, so it is auto-sourced into
# the user's interactive shell. Every variable the parser assigns is `local`
# (house style here — see gh_pr_review.sh) so a call cannot clobber the
# user's `$pr` / `$remote` / `$url`. Callers read the stdout `key=value`
# contract, never the shell variables.

# Advisory only (issue #1454, propagated by #1505): warn once on stderr when
# this file was sourced from a checkout that is a different git repo than
# $HOME/dotfiles. Never blocks, and deliberately NOT wrapped in an
# interactive guard — this is a pure function-defining library that
# non-interactive skill callers rely on; the guard function is itself a
# silent no-op outside the genuine foreign-checkout case.
#
# The self-path branch must stay here at file top level — zsh rebinds $0 to
# the sourced file (FUNCTION_ARGZERO) only for this file's own statements,
# and inside a function $0 is the function's own name. Plain POSIX sh has
# neither $0-rebinding nor $BASH_SOURCE, and would abort on the bash array
# syntax, hence the $BASH_VERSION arm. Everything after it lives once, in
# _dotfiles_root_guard_self.
if [ -n "${ZSH_VERSION-}" ]; then
    _drg_self="$0"
elif [ -n "${BASH_VERSION-}" ]; then
    _drg_self="${BASH_SOURCE[0]-}"
else
    _drg_self=""
fi
_drg_helper="${SHELL_COMMON:-$HOME/dotfiles/shell-common}/functions/dotfiles_root.sh"
if [ -r "$_drg_helper" ]; then
    . "$_drg_helper" || true
fi
if command -v _dotfiles_root_guard_self >/dev/null 2>&1; then
    _dotfiles_root_guard_self "$_drg_self" "devx_pr_verify_live"
else
    printf '[devx_pr_verify_live] %s missing or did not define _dotfiles_root_guard_self — #1454 guard skipped (#724).\n' \
        "$_drg_helper" >&2
fi
unset _drg_self _drg_helper

_devx_pr_verify_live_pos_int() {
    case "$1" in
    "" | *[!0-9]*) return 1 ;;
    *[!0]*) return 0 ;;
    *) return 1 ;;
    esac
}

devx_pr_verify_live_parse() {
    local pr=""
    local remote="origin"
    local url=""
    local api_url=""
    local start_cmd=""
    local matrix="auto"
    local viewports=""
    local locales=""
    local issue_mode="create"
    local allow_remote_host=0
    local post_comment=1
    local _remote_set=0
    local _pos_seen=0
    local _url_set=0
    local _api_url_set=0
    local _start_set=0
    local _matrix_set=0
    local _viewports_set=0
    local _locales_set=0
    local _no_issue=0
    local _rest=""
    local _item=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --url | --api-url | --start | --matrix | --viewports | --locales)
            [ "$#" -lt 2 ] && {
                echo "missing value for $1" >&2
                return 2
            }
            ;;
        esac
        case "$1" in
        --url)
            url="$2"
            _url_set=1
            shift 2
            ;;
        --url=*)
            url="${1#--url=}"
            _url_set=1
            shift
            ;;
        --api-url)
            api_url="$2"
            _api_url_set=1
            shift 2
            ;;
        --api-url=*)
            api_url="${1#--api-url=}"
            _api_url_set=1
            shift
            ;;
        --start)
            start_cmd="$2"
            _start_set=1
            shift 2
            ;;
        --start=*)
            start_cmd="${1#--start=}"
            _start_set=1
            shift
            ;;
        --matrix)
            matrix="$2"
            _matrix_set=1
            shift 2
            ;;
        --matrix=*)
            matrix="${1#--matrix=}"
            _matrix_set=1
            shift
            ;;
        --viewports)
            viewports="$2"
            _viewports_set=1
            shift 2
            ;;
        --viewports=*)
            viewports="${1#--viewports=}"
            _viewports_set=1
            shift
            ;;
        --locales)
            locales="$2"
            _locales_set=1
            shift 2
            ;;
        --locales=*)
            locales="${1#--locales=}"
            _locales_set=1
            shift
            ;;
        --dry-run)
            issue_mode="dry-run"
            shift
            ;;
        --no-issue)
            _no_issue=1
            shift
            ;;
        --no-comment)
            post_comment=0
            shift
            ;;
        --allow-remote-host)
            allow_remote_host=1
            shift
            ;;
        -h | --help | help)
            echo "help_requested=1"
            return 0
            ;;
        -*)
            # Single- and double-dash typos alike are flag errors, not
            # positionals — `-x` must not surface as a PR# complaint.
            echo "Unknown flag: $1" >&2
            return 2
            ;;
        *)
            # `[pr-number] [remote]` with an optional PR#. Discriminator:
            # PR numbers start with a digit, git remote names conventionally
            # do not. A leading digit therefore always means "this is the
            # PR#" — `12a` stays a loud PR# error instead of silently
            # becoming a remote name.
            if [ "$_pos_seen" -eq 0 ]; then
                _pos_seen=1
                case "$1" in
                [0-9]*)
                    pr="$1"
                    ;;
                *)
                    remote="$1"
                    _remote_set=1
                    ;;
                esac
            elif [ "$_remote_set" -eq 0 ]; then
                remote="$1"
                _remote_set=1
            else
                echo "Unexpected positional arg: $1" >&2
                return 2
            fi
            shift
            ;;
        esac
    done

    if [ -n "$pr" ]; then
        if ! _devx_pr_verify_live_pos_int "$pr"; then
            echo "PR# must be a positive integer: '$pr'" >&2
            return 2
        fi
    fi

    # An explicitly passed but empty value is an error for every
    # value-taking flag — silently dropping it would verify a different
    # app than the user asked for.
    if [ "$_url_set" -eq 1 ] && [ -z "$url" ]; then
        echo "--url value must not be empty" >&2
        return 2
    fi

    if [ "$_api_url_set" -eq 1 ] && [ -z "$api_url" ]; then
        echo "--api-url value must not be empty" >&2
        return 2
    fi

    if [ "$_start_set" -eq 1 ] && [ -z "$start_cmd" ]; then
        echo "--start value must not be empty" >&2
        return 2
    fi

    if [ "$_matrix_set" -eq 1 ] && [ -z "$matrix" ]; then
        echo "--matrix value must not be empty" >&2
        return 2
    fi

    if [ "$_viewports_set" -eq 1 ] && [ -z "$viewports" ]; then
        echo "--viewports value must not be empty" >&2
        return 2
    fi

    if [ "$_locales_set" -eq 1 ] && [ -z "$locales" ]; then
        echo "--locales value must not be empty" >&2
        return 2
    fi

    case "$url" in
    "" | http://* | https://*) ;;
    *)
        echo "--url must be an http(s) URL: '$url'" >&2
        return 2
        ;;
    esac

    case "$api_url" in
    "" | http://* | https://*) ;;
    *)
        echo "--api-url must be an http(s) URL: '$api_url'" >&2
        return 2
        ;;
    esac

    case "$matrix" in
    auto | full) ;;
    *)
        echo "--matrix must be auto or full: '$matrix'" >&2
        return 2
        ;;
    esac

    if [ -n "$viewports" ]; then
        _rest="${viewports},"
        while [ -n "$_rest" ]; do
            _item="${_rest%%,*}"
            _rest="${_rest#*,}"
            if ! _devx_pr_verify_live_pos_int "$_item"; then
                echo "--viewports must be a CSV of positive integers: '$viewports'" >&2
                return 2
            fi
        done
    fi

    if [ -n "$locales" ]; then
        _rest="${locales},"
        while [ -n "$_rest" ]; do
            _item="${_rest%%,*}"
            _rest="${_rest#*,}"
            if [ -z "$_item" ]; then
                echo "--locales must be a CSV of non-empty locale tags: '$locales'" >&2
                return 2
            fi
        done
    fi

    if [ "$_no_issue" -eq 1 ]; then
        issue_mode="none"
    fi

    printf '%s\n' "pr=$pr"
    printf '%s\n' "remote=$remote"
    printf '%s\n' "url=$url"
    printf '%s\n' "api_url=$api_url"
    printf '%s\n' "start_cmd=$start_cmd"
    printf '%s\n' "matrix=$matrix"
    printf '%s\n' "viewports=$viewports"
    printf '%s\n' "locales=$locales"
    printf '%s\n' "issue_mode=$issue_mode"
    printf '%s\n' "allow_remote_host=$allow_remote_host"
    printf '%s\n' "post_comment=$post_comment"
    return 0
}
