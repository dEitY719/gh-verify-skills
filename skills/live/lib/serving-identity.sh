#!/bin/sh
# lib/serving-identity.sh — gh-verify:live assertion 1, the serving-checkout
# identity check, as one executable instead of commands the model retypes
# from memory (dEitY719/gh-verify-skills#63). EXECUTE it, never source it.
#
#   printf '%s' "$PR_JSON" | sh serving-identity.sh                        # Step 2: target line only
#   printf '%s' "$PR_JSON" | sh serving-identity.sh "$SERVING_ROOT" \
#       [--content-url <module-url> --symbol <s> [--symbol <s>]]           # Step 3: + verdict
#
# stdin   `gh pr view --json state,mergeCommit,headRefOid,...` output. The
#         target is ALWAYS `mergeCommit.oid // headRefOid` read from that
#         JSON — never a SHA the caller remembers: a rebase merge rewrites
#         the head SHA, so the remembered one is absent from main (#63).
# stdout  line 1  TARGET_SHA=<sha> (source=mergeCommit|headRefOid, state=<state>)
#         then, with a serving root, evidence lines and a last line
#         SERVING_IDENTITY=verified|mismatch|unverified — the same three
#         verdicts as references/discovery.md §2-4.
#           verified    target is an ancestor of the serving HEAD
#           mismatch    it is not, and no content evidence says otherwise: stop
#           unverified  SHA not proven, but every --symbol was found in the
#                       served source ("[WARN] SHA 불일치, 내용 일치"), or the
#                       serving root is not a git checkout: continue, report it
# exit    0 for every verdict (a verdict is data); 2 on bad input.
#
# ponytail: devx_pr_verify_live_* helpers live in lib/vendor/shell-common,
# which dotfiles' sync script replaces wholesale, so this one lives here.
# Porting it upstream is a follow-up; move it into the vendor tree then.
#
# Self-check: lib/serving-identity.selfcheck.sh

devx_pr_verify_live_serving_identity() {
    _json=$(cat)
    _line=$(printf '%s' "$_json" | jq -r '
        (if (.mergeCommit.oid // "") != "" then "mergeCommit" else "headRefOid" end) as $src
        | (.mergeCommit.oid // .headRefOid // "") as $sha
        | if $sha == "" then empty
          else "\($sha)\t\($src)\t\(.state // "UNKNOWN")" end') || _line=''
    [ -n "$_line" ] || { echo '[FATAL] stdin carries neither mergeCommit.oid nor headRefOid' >&2; return 2; }
    _sha=$(printf '%s' "$_line" | cut -f1)
    _src=$(printf '%s' "$_line" | cut -f2)
    _state=$(printf '%s' "$_line" | cut -f3)
    echo "TARGET_SHA=$_sha (source=$_src, state=$_state)"
    [ $# -gt 0 ] || return 0

    _root=$1; shift
    _url=''; _syms=''
    while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || { echo "[FATAL] $1 needs a value" >&2; return 2; }
        case "$1" in
            --content-url) _url=$2; shift 2 ;;
            --symbol) _syms="$_syms${_syms:+
}$2"; shift 2 ;;
            *) echo "[FATAL] unknown argument: $1" >&2; return 2 ;;
        esac
    done

    _top=$(git -C "$_root" rev-parse --show-toplevel 2>/dev/null) || {
        echo "reason     $_root is not a git checkout — ancestry cannot be checked"
        echo 'SERVING_IDENTITY=unverified'
        return 0
    }
    _head=$(git -C "$_top" rev-parse HEAD)
    if git -C "$_top" merge-base --is-ancestor "$_sha" HEAD 2>/dev/null; then
        echo "serving    $_top @ $_head"
        echo 'SERVING_IDENTITY=verified'
        return 0
    fi

    # Commits the serving HEAD lacks. Uncountable when the target object is
    # not in that clone at all (not fetched, or a rewritten SHA).
    if _n=$(git -C "$_top" rev-list --count "HEAD..$_sha" 2>/dev/null); then
        _behind="behind by $_n commits"
    else
        _behind="target commit not in this checkout — fetch, then retry"
    fi
    echo "serving    $_top @ $_head ($_behind)"

    # F-3: one independent look at the served source before stopping.
    if [ -z "$_url" ] || [ -z "$_syms" ]; then
        echo 'content    not checked (no --content-url/--symbol) — do not claim the feature is absent'
        echo 'SERVING_IDENTITY=mismatch'
        return 0
    fi
    _body=$(curl -fsS -m 5 "$_url" 2>/dev/null) || {
        echo "content    not checked ($_url unreachable) — do not claim the feature is absent"
        echo 'SERVING_IDENTITY=mismatch'
        return 0
    }
    _found=''; _missing=''
    _ifs=$IFS; IFS='
'
    for _s in $_syms; do
        case "$_body" in
            *"$_s"*) _found="$_found${_found:+, }$_s" ;;
            *) _missing="$_missing${_missing:+, }$_s" ;;
        esac
    done
    IFS=$_ifs
    if [ -z "$_missing" ]; then
        echo "[WARN] SHA 불일치, 내용 일치 — found $_found in $_url"
        echo 'SERVING_IDENTITY=unverified'
    else
        echo "content    absent from $_url: $_missing"
        echo 'SERVING_IDENTITY=mismatch'
    fi
    return 0
}

devx_pr_verify_live_serving_identity "$@"
