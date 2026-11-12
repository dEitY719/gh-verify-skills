#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/lib/gh_pr_review_prompt.sh
# Synced 2026-11-12T00:00Z by dEitY719/harness-skills scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shellcheck shell=bash
# shell-common/lib/gh_pr_review_prompt.sh
# gh-pr-review prompt — common prefix, preset bodies, prompt file builder.
#
# Split out of functions/gh_pr_review.sh by #2382 (no behavior change). Pure
# function library: no interactive guard, sourced only by that file, which
# loads it together with its siblings and defines ux_error first.

# ============================================================================
# Section 3 — Prompt builder
# ============================================================================
# Bodies are copied verbatim from
# claude/skills/gh-pr-review/references/review-presets.md so the shell
# entrypoint and the SKILL agree on the exact prompt every CLI sees.

_gh_pr_review_common_prefix() {
    cat <<'EOF'
You are reviewing a GitHub pull request as a second-opinion reviewer.
You DO NOT submit a decision (no approve / request-changes) — the
human and the primary reviewer handle that. Your job is to surface
specific, actionable findings.

Adopt a critical, skeptical stance. Do not rubber-stamp. Actively
look for weak assumptions, missing edge cases, and alternative
approaches the PR did not consider.

Classification (use these exact labels for every finding):
  - BLOCKER   — would break or regress if merged as-is.
  - FOLLOW-UP — non-blocking quality issue worth tracking.
  - PRAISE    — concrete diff location worth highlighting.

Format (one line per finding):
  [BLOCKER|FOLLOW-UP|PRAISE] <path>:<line> — <one-sentence reason>

Assumption check (mandatory): identify at least one assumption in the
PR that is treated as obviously correct but is actually questionable
(a design choice, a claim in the description, an "obviously safe"
change). State it as one line: "Assumption: <what> — <why it's
questionable>". If you genuinely find none after actively looking,
say so explicitly: "Assumption: none found."

Verdict (mandatory, last line): a single overall call on the PR —
  판정: [LGTM|우려있음|블로킹]        (Korean-dominant diff)
  Verdict: [LGTM|CONCERNS|BLOCKING]  (English-dominant diff)

Reply in the dominant language of the PR diff (Korean if the diff is
Korean-dominant, otherwise English). Be concise; no preamble; do not
restate the diff.
EOF
}

_gh_pr_review_preset_body() {
    case "$1" in
    default)
        cat <<'EOF'
Review across 7 dimensions in balance. Skip categories the diff does
not exercise. Flag concrete file:line items only.

1. Correctness — does the code do what the PR title/body claims?
2. Conventions — naming, file location, error-handling idioms match
   surrounding code (CLAUDE.md / AGENTS.md if present).
3. Security — input validation, shell-injection, hardcoded secrets,
   unsafe eval, missing authn/z.
4. Performance — N+1, unnecessary I/O in hot loops, missing caching.
5. Tests — new paths covered? Absence of tests for new logic is usually
   a BLOCKER.
6. Docs / comments — public API changes without doc updates, stale
   references, lies in comments.
7. Backward compatibility — breaking API/CLI/config changes flagged?
   Migration path documented?
EOF
        ;;
    quick)
        cat <<'EOF'
Quick first-pass scan. ONLY surface BLOCKER findings — items that
would break or regress if merged as-is. Skip PRAISE entirely. Limit
FOLLOW-UP to at most 2 items where the harm is obvious.

Focus on:
- Correctness regressions (logic bugs, off-by-one, wrong condition).
- Security (shell injection, hardcoded secrets, unsafe eval, missing
  input validation).

Do NOT flag style, naming, or doc nits — those belong in a thorough
pass. Target output length: under 200 words.
EOF
        ;;
    thorough)
        cat <<'EOF'
Deep-dive review. Cover the 7 dimensions from the default preset, AND
add:

8. Architecture trade-offs — does the chosen abstraction fit the
   problem? Are there cheaper alternatives that achieve the same goal?
9. Test coverage gaps — which branches/edge cases are not exercised
   even when there ARE tests? Be specific: list the missing scenarios.
10. Adjacent-system impact — what other modules / scripts / docs
    depend on changed surface area? Are those callers updated?
11. Migration / rollout — if behavior changes silently, how would a
    user notice? Is there a feature flag or version gate?

Be exhaustive. PRAISE concrete diff locations worth highlighting.
EOF
        ;;
    security)
        cat <<'EOF'
Security-focused review. Other dimensions are out of scope for THIS
invocation — the caller will run a separate review for correctness,
performance, etc.

Look for:
- Injection (shell, SQL, command, prompt) at any user-controlled input.
- Hardcoded secrets, tokens, credentials in code, tests, or examples.
- Authn/authz — missing checks, broken access control, privilege
  escalation paths.
- Supply chain — new dependencies, pinned versions, install-script
  integrity (signed-by, checksums).
- Data handling — PII logging, unredacted error messages, insecure
  defaults.
- Crypto — homerolled primitives, weak algorithms, missing nonce/IV.
- Race conditions on filesystem (TOCTOU), env var injection, signal
  handling.

Classify each finding as BLOCKER (exploitable) or FOLLOW-UP (defense
in depth). PRAISE specific security-positive patterns when present.
EOF
        ;;
    performance)
        cat <<'EOF'
Performance-focused review. Other dimensions are out of scope for
THIS invocation — the caller will run a separate review for
correctness, security, etc.

Look for:
- N+1 patterns (DB, API, filesystem).
- Unnecessary I/O inside hot loops (fork, exec, network, disk).
- Allocation hotspots — repeated string concatenation, large buffers
  in loops, missing pre-sizing.
- Missing caching on expensive idempotent calls.
- Synchronous calls that should be batched / pipelined.
- Algorithmic complexity worse than necessary (O(n²) where O(n log n)
  fits, etc.).

Quantify when possible: "executes ~N times per request" or "scales
linearly with X". Flag only concrete wins — avoid premature
optimization theatre. Classify each finding as BLOCKER (production
hot path) or FOLLOW-UP (visible only at scale).
EOF
        ;;
    *)
        ux_error "Unknown preset: '$1'"
        return 2
        ;;
    esac
}

# _gh_pr_review_build_prompt — writes `<prefix>\n\n<preset>\n\n<diff>`
# to the given file. Args: $1 = preset, $2 = output file, $3 = pr_number,
# $4 = target_repo, $5 = base_ref, $6 = head_ref, $7 = optional
# space-separated path scope. The diff is fetched with `gh pr diff`; the
# function does not enforce a size gate (the SKILL still controls the
# large-diff delegation path in Step 4).
#
# $7 (issue #1616) is what keeps gh:pr-reply's targeted re-review lane on
# the small-diff inline path no matter how large the whole PR is. Exit 3
# when the scope matches nothing: an empty diff would make the reviewer
# opine on nothing and answer LGTM, and that answer is exactly what the
# lane would read as "the blocker is cleared".
_gh_pr_review_build_prompt() {
    [ -n "${ZSH_VERSION-}" ] && emulate -L sh
    local preset="$1"
    local out="$2"
    local pr="$3"
    local repo="$4"
    local base="${5:-?}"
    local head="${6:-?}"
    local paths="${7-}"
    local _scoped_diff="" _scope_note=""

    if [ -n "$paths" ]; then
        # Word-splitting `$paths` is the contract: it is a space-separated
        # path list, mirroring the `paths=` line gh_pr_review_parse emits.
        # shellcheck disable=SC2086
        _scoped_diff=$(gh pr diff "$pr" --repo "$repo" 2>/dev/null |
            _gh_pr_review_filter_diff_paths $paths)
        if [ -z "$_scoped_diff" ]; then
            ux_error "--paths matched no file in PR #$pr's diff: $paths"
            return 3
        fi
        _scope_note=", scoped to: $paths"
    fi

    {
        _gh_pr_review_common_prefix
        echo ""
        _gh_pr_review_preset_body "$preset" || return $?
        echo ""
        printf -- '--- PR DIFF (PR #%s, repo %s, base %s → head %s%s) ---\n' \
            "$pr" "$repo" "$base" "$head" "$_scope_note"
        if [ -n "$paths" ]; then
            printf '%s\n' "$_scoped_diff"
        else
            gh pr diff "$pr" --repo "$repo" 2>/dev/null || true
        fi
        printf -- '--- END PR DIFF ---\n'
    } >"$out"
}
