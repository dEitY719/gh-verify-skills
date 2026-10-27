#!/usr/bin/env bash
# Self-check for lib/normalize-pr-arg.sh (dEitY719/gh-verify-skills#96):
#
#   bash skills/review-all/lib/normalize-pr-arg.selfcheck.sh
#
# No network. The repo whose remotes are matched is a throwaway git tree.
set -u

ROOT=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
TARGET="$ROOT/skills/review-all/lib/normalize-pr-arg.sh"
FAIL=0

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

chk() { # chk <label> <got> <want>
    if [ "$2" = "$3" ]; then printf 'ok    %s\n' "$1"
    else printf 'FAIL  %s: got [%s] want [%s]\n' "$1" "$2" "$3"; FAIL=1; fi
}

# norm <args...> -> "<rc>|<args the parser would receive, space-joined>|<stderr>"
norm() {
    local out err rc
    out=$(cd "$TMP/repo" && bash "$TARGET" "$@" 2>"$TMP/err"); rc=$?
    err=$(cat "$TMP/err")
    if [ "$rc" -eq 0 ]; then eval "set -- $out"; out="$*"; fi
    printf '%s|%s|%s' "$rc" "$out" "$err"
}

git init -q "$TMP/repo"
git -C "$TMP/repo" remote add origin git@github.com:me/fork.git
git -C "$TMP/repo" remote add upstream https://github.com/dEitY719/equinest
git -C "$TMP/repo" remote add ghes ssh://git@ghes.corp.example:2222/team/app.git
git -C "$TMP/repo" remote add other https://github.com/dEitY719/other.git/

U=https://github.com/dEitY719/equinest/pull/898

# Plain numbers and flags pass through unchanged, in order.
chk "number"            "$(norm 898)"                              "0|898|"
chk "number + remote"   "$(norm 898 origin)"                       "0|898 origin|"
chk "number + lanes"    "$(norm 898 --lanes claude:default)"       "0|898 --lanes claude:default|"
chk "help"              "$(norm -h)"                               "0|-h|"
chk "non-url passes"    "$(norm abc)"                              "0|abc|"
chk "empty"             "$(norm)"                                  "0||"
chk "value with space"  "$(norm 898 --lanes 'a b')"                "0|898 --lanes a b|"

# URL -> number + the matching remote.
chk "url"               "$(norm "$U")"                             "0|898 upstream|"
chk "url /files"        "$(norm "$U/files")"                       "0|898 upstream|"
chk "url /commits/"     "$(norm "$U/commits/")"                    "0|898 upstream|"
chk "url trailing /"    "$(norm "$U/")"                            "0|898 upstream|"
chk "url ?query"        "$(norm "$U?x=1")"                         "0|898 upstream|"
chk "url #fragment"     "$(norm "$U#issuecomment-1")"              "0|898 upstream|"
chk "url case-insens."  "$(norm https://github.com/deity719/EQUINEST/pull/898)" "0|898 upstream|"
chk "ssh .git remote"   "$(norm https://github.com/me/fork/pull/7)" "0|7 origin|"
chk "https .git/ rem."  "$(norm https://github.com/dEitY719/other/pull/3)" "0|3 other|"
chk "ghes ssh:// port"  "$(norm https://ghes.corp.example/team/app/pull/5)" "0|5 ghes|"
chk "url host :port"    "$(norm https://ghes.corp.example:8443/team/app/pull/5)" "0|5 ghes|"
chk "flags keep order"  "$(norm --no-reply "$U" --defer-reply 4 --force-review)" \
    "0|--no-reply 898 upstream --defer-reply 4 --force-review|"
chk "flag value != pr"  "$(norm --lanes x:y "$U")"                 "0|--lanes x:y 898 upstream|"
chk "--lanes= form"     "$(norm --lanes=x:y "$U")"                 "0|--lanes=x:y 898 upstream|"

# Explicit remote: kept when it matches, refused when it does not.
chk "explicit match"    "$(norm "$U" upstream --no-reply)"         "0|898 upstream --no-reply|"
chk "explicit mismatch" "$(norm "$U" origin)" \
    "2||[gh-verify:review-all] remote 'origin' is me/fork, but the PR URL is dEitY719/equinest; drop <remote> or pass the matching one"
chk "explicit unknown"  "$(norm "$U" nope)" \
    "2||[gh-verify:review-all] no git remote named 'nope'"

# No remote matches the URL (wrong repo, or right repo on another host).
chk "no match"          "$(norm https://github.com/x/y/pull/1)" \
    "2||[gh-verify:review-all] no git remote matches x/y; pass <remote> explicitly"
chk "host must match"   "$(norm https://ghes.corp.example/dEitY719/equinest/pull/1)" \
    "2||[gh-verify:review-all] no git remote matches dEitY719/equinest; pass <remote> explicitly"

[ "$FAIL" -eq 0 ] && echo "PASS  normalize-pr-arg.selfcheck.sh" || echo "FAIL  normalize-pr-arg.selfcheck.sh"
exit "$FAIL"
