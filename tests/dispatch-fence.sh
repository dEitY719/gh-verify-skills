#!/usr/bin/env bash
# Contract check for skills/post-merge-verify/references/dispatch.sh.md
# (dEitY719/gh-verify-skills#39).
#
#   bash tests/dispatch-fence.sh
#
# That file ships ~470 lines of bash as a markdown fence, and #39 asked whether
# the fence should become `skills/post-merge-verify/lib/dispatch.sh`. It should
# not: `gh-pr:merge` does not source the file in place. Its
# `lib/post-merge-verify-dispatch.sh` awk-extracts the FIRST bash fence into a
# `mktemp` file and sources that copy in a subshell, so the bytes run from
# /tmp whatever they are stored as. A `.sh` there would still be a pasted-block
# carrier — tiers 1, 2 and 5 only, no self-path — and the vendored fallback
# copy lives under `gh-pr-skills`' own lib/vendor/, where a self-path resolves
# to the WRONG plugin, which is the misresolution #39 opens with.
#
# What moving it would have bought is `sh -n` and shellcheck over real bytes.
# This file buys that without the two-repo change, by extracting the fence with
# the consumer's own awk and asserting the contract the consumer relies on.
#
# No network, no gh, no herdr: nothing below runs the dispatch itself, only its
# plugin-root prologues, at tier 5 where they must stop.
set -u

ROOT=$(cd -- "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" && pwd)
DOC="$ROOT/skills/post-merge-verify/references/dispatch.sh.md"
FAIL=0
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

chk() { # chk <label> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"; FAIL=1; fi
}
has()   { case "$2" in *"$3"*) chk "$1" yes yes ;; *) chk "$1" missing "contains: $3" ;; esac; }
# shellcheck disable=SC2317  # called below; shellcheck cannot see through chk
hasnt() { case "$2" in *"$3"*) chk "$1" "present" "absent: $3" ;; *) chk "$1" yes yes ;; esac; }

# --- 1. Extract exactly as gh-pr:merge does ---------------------------------
# Byte-for-byte the awk in gh-pr-skills' lib/post-merge-verify-dispatch.sh.
# If that program stops finding the block, the gate it feeds goes quiet.
FENCE='```'
awk -v f="$FENCE" '$0 == f "bash" && !b { b = 1; next } $0 == f && b { exit } b' \
    "$DOC" > "$TMP/dispatch.sh"
if [ -s "$TMP/dispatch.sh" ]; then
    chk "the consumer's awk extracts a non-empty first fence" yes yes
else
    chk "the consumer's awk extracts a non-empty first fence" empty non-empty
    exit 1
fi

# The later fences are documentation; the consumer takes only the first, so the
# dispatch must actually be in it.
has "the first fence is the dispatch, not a doc snippet" \
    "$(cat "$TMP/dispatch.sh")" 'F-1 gate'

# --- 2. It must parse, in every shell that might source it ------------------
# `sh -n` is the consumer's own gate: a body that will not parse is the
# "registered repo, broken install" [FAIL] it prints after the merge landed.
for sh in sh bash zsh dash; do
    command -v "$sh" >/dev/null 2>&1 || { printf 'skip  %s not installed\n' "$sh"; continue; }
    if err=$("$sh" -n "$TMP/dispatch.sh" 2>&1); then chk "$sh -n parses the fence" yes yes
    else chk "$sh -n parses the fence" "$err" "clean"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    # The fence is sourced, so its `return` statements are legal: -s sh plus
    # the repo's own .shellcheckrc is what the vendored tree is checked under.
    # -e SC2148: the fence has no shebang by construction. -e SC2317: the
    # SSOT's `return N 2>/dev/null || exit N` is required so one form works
    # both pasted and sourced; shellcheck cannot see that the file is sourced
    # and calls the `exit` arm unreachable. Both predate this PR.
    if out=$(cd "$ROOT" && shellcheck -s sh -e SC2148,SC2317 "$TMP/dispatch.sh" 2>&1); then
        chk "shellcheck -s sh is clean on the fence" yes yes
    else
        chk "shellcheck -s sh is clean on the fence" "$out" "clean"
    fi
else
    printf 'skip  shellcheck not installed\n'
fi

# --- 3. The plugin-root prologues, run at tier 5 ----------------------------
# harness-skills/references/plugin-root.md is the SSOT. Three things it fixed
# after this file was written are asserted here by BEHAVIOUR, not by grep:
#   #36  the proof compares command -v's OUTPUT to the bare name, so an alias
#        or a PATH executable owning the name cannot pass it;
#   #37  export SHELL_COMMON sits before the load AND is undone when the proof
#        fails, so a tree that did not load is never left exported.
# Plus the standing rule that tier 5 stops instead of guessing a root.
# The name-helper prologue is the head of the dispatch fence, up to the first
# function it defines; the Inputs prologue IS the doc's second bash fence.
awk 'index($0, "_SC=\"${DOTFILES_ROOT") == 1 { on = 1 }
     index($0, "pmv_prompt_retryable() {") == 1 { exit }
     on' "$TMP/dispatch.sh" > "$TMP/name-loader.sh"
awk -v f="$FENCE" '$0 == f "bash" { n++; next } n == 2 && $0 == f { exit } n == 2' \
    "$DOC" > "$TMP/inputs.sh"
for b in name-loader inputs; do
    [ -s "$TMP/$b.sh" ] || { printf 'FAIL  %s: extracted nothing\n' "$b"; FAIL=1; }
done
has "the inputs prologue is the target binding" "$(cat "$TMP/inputs.sh")" '_gh_parse_owner_repo_url'

EMPTY_HOME=$(mktemp -d); SANDBOX=$(mktemp -d)

run5() { # run5 <shell> <block> [pre-shell-code]  -> stdout: "<shell-common-after>|<stderr+stdout>"
    ( cd "$SANDBOX" && env -u CLAUDE_PLUGIN_ROOT -u SHELL_COMMON -u DOTFILES_ROOT \
        HOME="$EMPTY_HOME" "$1" -c "${3:-:}
. \"\$1\" >/dev/null 2>&1
printf '%s' \"\${SHELL_COMMON:-unset}\"" _ "$TMP/$2.sh" )
}
aborts() { # aborts <shell> <block> -> 0 if the block exits non-zero
    ( cd "$SANDBOX" && env -u CLAUDE_PLUGIN_ROOT -u SHELL_COMMON -u DOTFILES_ROOT \
        HOME="$EMPTY_HOME" "$1" "$TMP/$2.sh" >/dev/null 2>&1 )
}

for sh in sh bash zsh dash; do
    command -v "$sh" >/dev/null 2>&1 || { printf 'skip  %s not installed\n' "$sh"; continue; }
    for block in name-loader inputs; do
        # #37: a tree that failed to prove out must not stay exported.
        chk "$sh/$block leaves SHELL_COMMON unset at tier 5" "$(run5 "$sh" "$block")" unset
        # This skill's failures are soft (F-6): tier 5 warns and skips, never aborts.
        aborts "$sh" "$block"
        chk "$sh/$block does not abort at tier 5" "$?" 0
        # #36: an ALIAS owning the proved name passes the exit-status form of
        # `command -v` in sh/dash/zsh. It must not pass this one.
        fn=_gh_resolve_host
        [ "$block" = name-loader ] && fn=herdr_agent_name
        chk "$sh/$block rejects an alias owning $fn" \
            "$(run5 "$sh" "$block" "alias $fn='echo impostor'")" unset
        # ... and so does a PATH executable of that name, which passes the
        # exit-status form in all four shells.
        mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\n:\n' > "$TMP/fakebin/$fn"; chmod +x "$TMP/fakebin/$fn"
        chk "$sh/$block rejects a PATH executable named $fn" \
            "$(PATH="$TMP/fakebin:$PATH" run5 "$sh" "$block")" unset
        rm -f "$TMP/fakebin/$fn"
    done
done
rm -rf "$EMPTY_HOME" "$SANDBOX"

# --- 4. Ordering: the export precedes the load it exists for ----------------
# Not observable at tier 5 (nothing loads), so asserted statically. Before
# harness-skills#37 it sat after the proof, which reads safer and silently
# broke every vendored helper's own ${SHELL_COMMON:-...} lookup.
for block in name-loader inputs; do
    exp=$(grep -n '^export SHELL_COMMON=' "$TMP/$block.sh" | head -n 1 | cut -d: -f1)
    load=$(grep -n '^\[ -f .* \] && \. ' "$TMP/$block.sh" | head -n 1 | cut -d: -f1)
    if [ -n "$exp" ] && [ -n "$load" ] && [ "$exp" -lt "$load" ]; then
        chk "$block exports SHELL_COMMON before the load" yes yes
    else
        chk "$block exports SHELL_COMMON before the load" "export@${exp:-none} load@${load:-none}" "export < load"
    fi
done

# --- 5. The banned path splices, over this skill's tree ---------------------
# harness-skills/references/plugin-root.md's gate grep. Scoped to this skill
# because skills/live/ and skills/review-all/ carry the same pre-#36 prologues
# and are owned by other open issues; widening this to `git ls-files` is a
# one-line change once they land.
splices=$(cd "$ROOT" && git ls-files -z -- skills/post-merge-verify \
    | xargs -0 grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:?-(\$PWD|\$\(pwd\)|\.)?\}/' 2>/dev/null)
chk "no empty-default or cwd path splices under post-merge-verify" "$splices" ""

# Every cleared name is cleared both ways (#36's other half).
for fn in herdr_agent_name herdr_agent_tab_for_cwd _gh_resolve_host; do
    body=$(cat "$DOC")
    has "unalias accompanies unset -f for $fn" "$body" "unalias $fn"
done
# ... and no proved name is still tested by exit status alone (#36). The jq /
# herdr availability probes are not proofs of a load and keep that form.
chk "no exit-status-only load proof is left in the doc" \
    "$(grep -cE 'command -v (herdr_agent_name|herdr_agent_tab_for_cwd|_gh_resolve_host) >/dev/null' "$DOC" || true)" "0"

[ "$FAIL" -eq 0 ] && echo "[OK] dispatch.sh.md fence contract" || echo "[FAIL] dispatch.sh.md fence contract"
exit "$FAIL"
