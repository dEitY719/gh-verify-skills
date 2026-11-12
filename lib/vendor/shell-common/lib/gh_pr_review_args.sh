#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_args.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_args.sh
# gh-pr-review stage 1 — the pure argument parser (gh_pr_review_parse).
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

# ============================================================================
# Section 1 — Argument parser (SSOT, mirrors SKILL.md Step 1)
# ============================================================================
# `gh_pr_review_parse` prints one `key=value` line per resolved arg on
# success, writes errors to stderr. Exit codes:
#   0 — parsed ok (or help requested)
#   2 — argument error (missing --ai, unknown --ai/--review, --user with
#       non-claude --ai, missing value, unknown flag)
#
# Runtime failures (unknown claude account on the live whitelist, missing
# CLI on PATH, PR auto-detect failure) belong to the main entrypoint —
# the parser stays pure so the bats fixture can exercise it in isolation.

gh_pr_review_parse() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local ai=""
    local review="default"
    local user=""
    local post_comment=1
    local pr=""
    local remote="origin"
    local paths=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
        --paths)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                ux_error "missing value for --paths"
                return 2
            fi
            paths="${paths:+$paths }$2"
            shift 2
            ;;
        --paths=*)
            if [ -z "${1#--paths=}" ]; then
                ux_error "missing value for --paths"
                return 2
            fi
            paths="${paths:+$paths }${1#--paths=}"
            shift
            ;;
        --ai)
            if [ "$#" -lt 2 ]; then
                ux_error "missing value for --ai"
                return 2
            fi
            ai="$2"
            shift 2
            ;;
        --ai=*)
            ai="${1#--ai=}"
            shift
            ;;
        --review)
            if [ "$#" -lt 2 ]; then
                ux_error "missing value for --review"
                return 2
            fi
            review="$2"
            shift 2
            ;;
        --review=*)
            review="${1#--review=}"
            shift
            ;;
        --user)
            if [ "$#" -lt 2 ]; then
                ux_error "missing value for --user"
                return 2
            fi
            user="$2"
            shift 2
            ;;
        --user=*)
            user="${1#--user=}"
            shift
            ;;
        --no-post-comment)
            post_comment=0
            shift
            ;;
        -h | --help | help)
            echo "help_requested=1"
            return 0
            ;;
        --*)
            ux_error "Unknown flag: $1"
            return 2
            ;;
        *)
            if [ -z "$pr" ]; then
                pr="$1"
            elif [ "$remote" = "origin" ]; then
                remote="$1"
            else
                ux_error "Unexpected positional arg: $1"
                return 2
            fi
            shift
            ;;
        esac
    done

    if [ -z "$ai" ]; then
        ux_error "missing required flag: --ai <codex|agy|claude|opencode|hermes>"
        return 2
    fi

    case "$ai" in
    codex | agy | claude | opencode | hermes) ;;
    *)
        ux_error "Unknown --ai value: '$ai' (allowed: codex, agy, claude, opencode, hermes)"
        return 2
        ;;
    esac

    if [ -n "$user" ] && [ "$ai" != "claude" ]; then
        ux_error "--user is only valid with --ai claude (codex/agy/opencode/hermes have no multi-account routing)"
        return 2
    fi

    case "$review" in
    보통) review="default" ;;
    간단) review="quick" ;;
    꼼꼼 | 꼼꼼하게) review="thorough" ;;
    보안) review="security" ;;
    성능) review="performance" ;;
    esac

    case "$review" in
    default | quick | thorough | security | performance) ;;
    *)
        ux_error "Unknown --review value: '$review'"
        cat >&2 <<EOF
Allowed: default | quick | thorough | security | performance
Korean aliases: 보통 | 간단 | 꼼꼼 (꼼꼼하게) | 보안 | 성능
EOF
        return 2
        ;;
    esac

    printf '%s\n' \
        "ai=$ai" \
        "review=$review" \
        "user=$user" \
        "post_comment=$post_comment" \
        "pr=$pr" \
        "remote=$remote" \
        "paths=$paths"
    return 0
}
