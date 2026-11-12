#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_comment.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_comment.sh
# gh-pr-review comment — PR comment body (ai-review / ai-metrics markers) and post.
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

# ============================================================================
# Section 4 — PR comment body builder + post
# ============================================================================
# Mirrors references/post-comment.md verbatim. The `<details>` wrappers
# and the `<!-- ai-review:<ai>[:<preset>]:<head-sha> -->` /
# `<!-- ai-metrics:gh-pr-review -->` markers are the SSOT for cross-skill
# ai-metrics aggregation. The `:<head-sha>` suffix on the ai-review marker
# is the freshness tag `devx:pr-review-all` gates its verdict label on
# (#1564): without it a verdict left by an earlier round is
# indistinguishable from one posted against the head under review, and a
# stale verdict can authorize a merge of code it never saw. Comments posted
# before #1564 carry the unsuffixed form and read as `unknown` under the
# sha-aware path — fail-closed, by design.

# Per-preset baseline human-review time (hours). Defaults from
# references/post-comment.md § "Human time baseline".
_gh_pr_review_human_h() {
    case "$1" in
    quick) echo "0.3" ;;
    default) echo "1.0" ;;
    thorough) echo "2.5" ;;
    security) echo "1.5" ;;
    performance) echo "1.5" ;;
    *) echo "1.0" ;;
    esac
}

# _ai_cli_estimate_tokens lives in lib/ai_cli_run.sh since #2381.

# Builds the PR comment body to the given output file. Args: $1 = output
# file, $2 = AI name, $3 = preset, $4 = path to AI stdout, $5 = tokens,
# $6 = human_h, $7 = elapsed_min, $8 = head sha (optional). The verbatim
# AI stdout is inlined between `<!-- ai-review:<ai>[:<preset>]:<head-sha> -->`
# markers — the `<preset>` field appears only for a non-`default` preset
# (gh-verify-skills#56), so a `default` review's marker is byte-for-byte what
# it has always been; the metrics footer follows the dotfiles SSOT
# (#317 / PR #320 / #367).
#
# The sha is what makes the marker a claim about ONE commit rather than
# about the PR in general — `devx_pr_review_all_lane_block <ai> <sha>`
# harvests only blocks whose open AND close markers carry that exact sha
# (#1564). An empty 8th arg falls back to the pre-#1564 unsuffixed form
# rather than emitting a dangling `ai:` tag: the caller could not read
# `headRefOid`, and a marker claiming freshness it cannot prove is worse
# than one making no claim at all.
_gh_pr_review_build_comment_body() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local out="$1"
    local ai="$2"
    local preset="$3"
    local ai_out="$4"
    local tokens="$5"
    local human_h="$6"
    local elapsed="$7"
    local head_sha="${8-}"

    # `<ai>` for the default preset (the unchanged, pre-#56 wire format), and
    # `<ai>:<preset>` for any other. Without the preset field two presets of
    # the same AI write the SAME marker on the same head, and whichever lane
    # posts second is read as a duplicate of the first — one verdict silently
    # standing in for two. SSOT for the grammar's reader side:
    # devx_pr_review_all_lane_block (gh-verify-skills#56).
    local tag="$ai"
    [ -n "$preset" ] && [ "$preset" != "default" ] && tag="${ai}:${preset}"
    [ -n "$head_sha" ] && tag="${tag}:${head_sha}"

    {
        printf '<details>\n'
        printf '<summary>🤖 AI Review · %s · --review=%s</summary>\n\n' "$ai" "$preset"
        printf '<!-- ai-review:%s -->\n' "$tag"
        cat "$ai_out"
        printf '\n<!-- /ai-review:%s -->\n\n' "$tag"
        printf '</details>\n\n'
        printf -- '---\n'
        printf '<details>\n'
        printf '<summary>🤖 AI Metrics · 📊 ~%s tokens · 👤 ~%s h · 🤖 ~%s min</summary>\n\n' \
            "$tokens" "$human_h" "$elapsed"
        printf '<!-- ai-metrics:gh-pr-review -->\n'
        printf '📊 ~%s tokens · 👤 ~%s h · 🤖 ~%s min\n' "$tokens" "$human_h" "$elapsed"
        printf '<!-- /ai-metrics:gh-pr-review -->\n\n'
        printf '</details>\n'
    } >"$out"
}

# _gh_pr_review_post_comment — wraps `gh pr comment --body-file`. Honors
# the two skip paths from SKILL.md Step 6: `--no-post-comment` (post=0)
# and `GH_DISABLE_AI_METRICS=1`. On gh failure the function prints the
# canonical `[WARN] PR comment post failed` line and returns 0 so the
# overall flow stays soft-fail.
#
# Args: $1 = pr_number, $2 = target_repo, $3 = body_file, $4 = post_flag
# (1=on, 0=off). Echoes one of: "<url>", "skipped (--no-post-comment)",
# "skipped (GH_DISABLE_AI_METRICS=1)", "[WARN] post failed".
_gh_pr_review_post_comment() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local pr="$1"
    local repo="$2"
    local body_file="$3"
    local post="${4:-1}"

    if [ "$post" = "0" ]; then
        echo "skipped (--no-post-comment)"
        return 0
    fi
    if [ "${GH_DISABLE_AI_METRICS:-0}" = "1" ]; then
        echo "skipped (GH_DISABLE_AI_METRICS=1)"
        return 0
    fi
    local _url
    if _url=$(gh pr comment "$pr" --repo "$repo" --body-file "$body_file" 2>&1); then
        printf '%s\n' "$_url"
        return 0
    fi
    printf '%s\n' "[WARN] PR comment post failed — output retained on stdout" >&2
    printf '%s\n' "[WARN] post failed"
    return 0
}
