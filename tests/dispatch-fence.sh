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
# Section 5 is wider than the fence: it is this repo's plugin-root gate over
# every tracked file, which is where the scoped version of it always said it
# would end up once skills/live/ and skills/review-all/ were converted.
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

# --- 5. The plugin-root conventions, over every tracked file ----------------
# The scoped version of this section covered skills/post-merge-verify/ only,
# because skills/live/ and skills/review-all/ still carried the pre-#36
# prologues. They do not any more, so this is the repo-wide gate now.
#
# `lib/vendor/` is excluded: it is replaced wholesale by dotfiles'
# sync-shell-common-vendor.sh, never edited here. `tests/` is excluded because
# this file names the banned patterns in order to ban them.
# Both halves must run inside $ROOT: git ls-files answers repo-relative paths,
# so a grep in the caller's cwd would silently read some other checkout — which
# is exactly what it did the first time this was written, and it reported the
# pre-conversion text from the clone this worktree hangs off.
tracked_xargs() { # tracked_xargs <command...>  -- run it over every tracked file
    (cd "$ROOT" && git ls-files -z -- . ':!lib/vendor' ':!tests' | xargs -0 "$@" 2>/dev/null)
}

# 5a. harness-skills/references/plugin-root.md's gate grep: no default that can
# expand to the filesystem root, and no cwd tier (harness-skills#22).
# shellcheck disable=SC2016  # the banned pattern is the literal text
splices=$(tracked_xargs grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:?-(\$PWD|\$\(pwd\)|\.)?\}/')
chk "no empty-default or cwd path splices, repo-wide" "$splices" ""

# 5b. #36's other half: a cleared name is cleared both ways. Checked per name
# per file, because a file that clears two helpers must unalias both.
# shellcheck disable=SC2016  # awk program, not a shell expansion
missing=$(tracked_xargs awk '
    /^[[:space:]]*unset -f |; unset -f / {
        line = $0
        sub(/^.*unset -f /, "", line)
        sub(/ 2>\/dev\/null.*$/, "", line)
        n = split(line, names, " ")
        for (i = 1; i <= n; i++) if (names[i] != "") print FILENAME "\t" names[i]
    }' | sort -u | while IFS="$(printf '\t')" read -r f fn; do
        grep -q "unalias $fn" "$ROOT/$f" || printf '%s: unset -f %s has no unalias\n' "$f" "$fn"
    done)
chk "every unset -f has a matching unalias, repo-wide" "$missing" ""

# 5c. #36: a load proof compares command -v's OUTPUT to the bare name. Scoped
# to the shell-common helper namespace — `command -v jq`/`gh`/`bunx` are tool
# probes, not proofs that a load defined something, and keep the older form.
proofs=$(tracked_xargs grep -nE 'command -v (devx_|_gh_|_dotfiles_|herdr_)[A-Za-z0-9_]* >/dev/null')
chk "no exit-status-only load proof, repo-wide" "$proofs" ""

# 5d. #37: export SHELL_COMMON precedes the load it exists for. The two soft
# warn-and-skip blocks are exempt by name: their export sits inside the success
# arm, and the soft form has no canonical export/undo shape yet
# (harness-skills#60). Shrink this list as that issue lands — do not grow it.
SOFT_PENDING_60="skills/live/references/findings.md skills/live/references/pr-comment.md"
# shellcheck disable=SC2016  # python program, not a shell expansion
order=$(cd "$ROOT" && SOFT="$SOFT_PENDING_60" python3 -c '
import os, re, subprocess

soft = set(os.environ["SOFT"].split())
files = subprocess.run(["git", "ls-files", "--", ".", ":!lib/vendor", ":!tests"],
                       capture_output=True, text=True).stdout.split()
load = re.compile(r"\. \"\$(?:_SC/functions/[A-Za-z0-9_./]+|_HELPER)\"")
exp = re.compile(r"export SHELL_COMMON=")
# A prologue starts at its tier-1 assignment, and a fence ends one. Without
# that reset a file with two prologues passes on the first one is export,
# which is exactly how the first version of this check missed a real move.
reset = re.compile(r"_SC=\"\$\{DOTFILES_ROOT|^```")
bad = []
for f in files:
    if f in soft:
        continue
    try:
        lines = open(f, encoding="utf-8").read().splitlines()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    exported = False
    for i, line in enumerate(lines, 1):
        r, e, m = reset.search(line), exp.search(line), load.search(line)
        if r and not (e and e.start() < r.start()):
            exported = False
        if e and (not m or e.start() < m.start()):
            exported = True
        if m and not exported:
            bad.append("%s:%d: sources before exporting SHELL_COMMON" % (f, i))
        if e and m and e.start() > m.start():
            exported = True
print("\n".join(bad))
')
chk "export SHELL_COMMON precedes every load, repo-wide" "$order" ""

[ "$FAIL" -eq 0 ] && echo "[OK] dispatch.sh.md fence contract" || echo "[FAIL] dispatch.sh.md fence contract"
exit "$FAIL"
