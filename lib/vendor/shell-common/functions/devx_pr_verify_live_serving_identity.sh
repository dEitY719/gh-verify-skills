#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/devx_pr_verify_live_serving_identity.sh
# Synced 2026-10-05T02:45Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
case $- in *i*) ;; *) [ -n "${DOTFILES_FORCE_INIT-}" ] || return 0 ;; esac
# shell-common/functions/devx_pr_verify_live_serving_identity.sh
# gh-verify:live assertion 1: is the PR's target commit in the serving checkout?
# Ported from dEitY719/gh-verify-skills skills/live/lib/serving-identity.sh (#1859).
#
# User-facing command: devx-pr-verify-live-serving-identity (dash-form)
# Internal function:   devx_pr_verify_live_serving_identity() (snake_case)
#
#   gh pr view N --json state,mergeCommit,headRefOid | \
#       devx_pr_verify_live_serving_identity [<serving-root> \
#           [--content-url <url> --symbol <s> [--symbol <s>]]]
#
# stdin   `gh pr view --json state,mergeCommit,headRefOid` output. The target is
#         ALWAYS `mergeCommit.oid // headRefOid` from that JSON, never a SHA the
#         caller remembers: a rebase merge rewrites the head SHA.
# stdout  line 1  TARGET_SHA=<sha> (source=mergeCommit|headRefOid, state=<state>)
#         with a serving root, evidence lines then a last line
#         SERVING_IDENTITY=verified|mismatch|unverified
#           verified    target is an ancestor of the serving HEAD
#           mismatch    it is not, and no content evidence says otherwise
#           unverified  SHA not proven but every --symbol was found in the served
#                       source ("[WARN] SHA 불일치, 내용 일치"), or the root is
#                       not a git checkout
# return  0 for every verdict (a verdict is data); 2 on bad input.

devx_pr_verify_live_serving_identity() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local line sha src state root url syms top head n behind body found missing s

    line=$(jq -r '
        (if (.mergeCommit.oid // "") != "" then "mergeCommit" else "headRefOid" end) as $src
        | (.mergeCommit.oid // .headRefOid // "") as $sha
        | if $sha == "" then empty
          else "\($sha)\t\($src)\t\(.state // "UNKNOWN")" end') || line=''
    [ -n "$line" ] || { echo '[FATAL] stdin carries neither mergeCommit.oid nor headRefOid' >&2; return 2; }
    IFS='	' read -r sha src state <<EOF
$line
EOF
    printf '%s\n' "TARGET_SHA=$sha (source=$src, state=$state)"
    [ $# -gt 0 ] || return 0

    root=$1; shift
    url=''; syms=''
    while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || { echo "[FATAL] $1 needs a value" >&2; return 2; }
        case "$1" in
            --content-url) url=$2; shift 2 ;;
            --symbol) syms="$syms${syms:+
}$2"; shift 2 ;;
            *) echo "[FATAL] unknown argument: $1" >&2; return 2 ;;
        esac
    done

    top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || {
        echo "reason     $root is not a git checkout — ancestry cannot be checked"
        echo 'SERVING_IDENTITY=unverified'
        return 0
    }
    head=$(git -C "$top" rev-parse HEAD)
    if git -C "$top" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        echo "serving    $top @ $head"
        echo 'SERVING_IDENTITY=verified'
        return 0
    fi

    # Uncountable when the target object is not in that clone at all.
    if n=$(git -C "$top" rev-list --count "HEAD..$sha" 2>/dev/null); then
        behind="behind by $n commits"
    else
        behind="target commit not in this checkout — fetch, then retry"
    fi
    printf '%s\n' "serving    $top @ $head ($behind)"

    # One independent look at the served source before stopping.
    if [ -z "$url" ] || [ -z "$syms" ]; then
        echo 'content    not checked (no --content-url/--symbol) — do not claim the feature is absent'
        echo 'SERVING_IDENTITY=mismatch'
        return 0
    fi
    body=$(curl -fsS -m 5 "$url" 2>/dev/null) || {
        echo "content    not checked ($url unreachable) — do not claim the feature is absent"
        echo 'SERVING_IDENTITY=mismatch'
        return 0
    }
    found=''; missing=''
    # read loop, not `for s in $syms`: zsh does not word-split unquoted vars.
    while IFS= read -r s; do
        case "$body" in
            *"$s"*) found="$found${found:+, }$s" ;;
            *) missing="$missing${missing:+, }$s" ;;
        esac
    done <<EOF
$syms
EOF
    if [ -z "$missing" ]; then
        echo "[WARN] SHA 불일치, 내용 일치 — found $found in $url"
        echo 'SERVING_IDENTITY=unverified'
    else
        echo "content    absent from $url: $missing"
        echo 'SERVING_IDENTITY=mismatch'
    fi
    return 0
}

alias devx-pr-verify-live-serving-identity='devx_pr_verify_live_serving_identity'
if [ -n "${BASH_VERSION-}" ]; then
    export -f devx_pr_verify_live_serving_identity
fi
