#!/usr/bin/env bash
# lib/normalize-pr-arg.sh — turn a PR URL in review-all's <pr> slot into the PR
# number plus the git remote that points at that repo (dEitY719/gh-verify-skills#96).
#
# EXECUTE it from the repository under review; the output is meant for eval:
#
#   _na=$(bash "$_NPA" "$@") || exit 2; eval "set -- $_na"
#
# It runs before devx_pr_review_all_parse, which is vendored from dotfiles and
# must not be edited here, so the parser only ever sees `<N> [remote]`.
#
# Input   the review-all args as given. Only the first positional is looked at:
#         `http(s)://<host>/<owner>/<repo>/pull/<N>` with any `/files`,
#         `/commits`, trailing `/`, `?query` or `#fragment` after <N>.
# Output  the args, shell-quoted on one line. A PR URL becomes <N>; when no
#         <remote> positional was given, the remote whose URL names the same
#         host and owner/repo (ssh or https, `.git` optional, case-insensitive)
#         is inserted right after it. Anything else passes through untouched —
#         a non-number non-URL still reaches the parser's own error.
# Exit    0 ok; 2 when no remote matches the URL, when the explicit <remote>
#         does not exist, or when it names a different repo than the URL.
set -u

# _repo_of <git url> -> "host owner/repo"; empty when unparseable.
_repo_of() {
    local u="$1" host path
    case "$u" in
    *://*)
        u="${u#*://}"; u="${u#*@}"
        host="${u%%/*}"; host="${host%%:*}"; path="${u#*/}" ;;
    *@*:*)
        u="${u#*@}"; host="${u%%:*}"; path="${u#*:}" ;;
    *) return 0 ;;
    esac
    path="${path%/}"; path="${path%.git}"
    printf '%s %s\n' "$host" "$path"
}
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; } # not ${x,,}: macOS ships bash 3.2

[ "$#" -gt 0 ] || exit 0

args=("$@")
pr_i=-1 remote_i=-1 i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
    --lanes | --defer-reply) i=$((i + 1)) ;; # the parser's value flags; selfcheck pins this list
    -*) ;;
    *) if [ "$pr_i" -lt 0 ]; then pr_i=$i; elif [ "$remote_i" -lt 0 ]; then remote_i=$i; fi ;;
    esac
    i=$((i + 1))
done

re='^https?://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?$'
if [ "$pr_i" -lt 0 ] || [[ ! "${args[$pr_i]}" =~ $re ]]; then
    printf '%q ' "$@"; echo; exit 0
fi
host="${BASH_REMATCH[1]%%:*}" # _repo_of drops the port too (an ssh port is not the web port)
slug="${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
want=$(_lc "$host $slug")
args[pr_i]="${BASH_REMATCH[4]}"

if [ "$remote_i" -ge 0 ]; then
    r="${args[$remote_i]}"
    url=$(git remote get-url "$r" 2>/dev/null) || {
        printf "[gh-verify:review-all] no git remote named '%s'\n" "$r" >&2; exit 2; }
    got=$(_repo_of "$url")
    if [ "$(_lc "$got")" != "$want" ]; then
        printf "[gh-verify:review-all] remote '%s' is %s, but the PR URL is %s; drop <remote> or pass the matching one\n" \
            "$r" "${got/ //}" "$host/$slug" >&2
        exit 2
    fi
else
    match=""
    for r in $(git remote 2>/dev/null); do # alphabetical: first match wins when several name the repo
        got=$(_repo_of "$(git remote get-url "$r")")
        [ "$(_lc "$got")" = "$want" ] && { match="$r"; break; }
    done
    [ -n "$match" ] || {
        printf '[gh-verify:review-all] no git remote matches %s; pass <remote> explicitly\n' "$slug" >&2; exit 2; }
    args=("${args[@]:0:$((pr_i + 1))}" "$match" "${args[@]:$((pr_i + 1))}")
fi

printf '%q ' "${args[@]}"; echo
