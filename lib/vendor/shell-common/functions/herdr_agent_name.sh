#!/bin/sh
# VENDORED — do not edit here.
# SSOT: dEitY719/dotfiles shell-common/functions/herdr_agent_name.sh
# Synced 2026-09-05T02:31Z by scripts/sync-shell-common-vendor.sh — re-run that script to update.
# shell-common/functions/herdr_agent_name.sh
# SSOT for the herdr agent names the unattended pipelines derive (issue #1530).
#
# herdr validates every agent name against
#
#     ^[a-z][a-z0-9_-]{0,31}$
#
# and refuses `agent start` outright when it does not match. Three call sites
# — pr_merge_train_cron.sh, issue_watcher_cron.sh and gh:pr-post-merge-verify's
# dispatch block — each carried their own copy of a slug helper built on
# `tr -c 'A-Za-z0-9._-' '-'`. That set *keeps* uppercase and dots (tr -c only
# replaces what is outside the set), so on `dEitY719/dotfiles` @ `github.com`
# every name they produced violated the rule and the entire unattended
# pipeline never started a single session: 76 recorded attempts, 0 successes.
# One helper, three callers — a fix that lands in one place stays landed.
#
# Name shapes, and their widths against the 32-character budget:
#
#   merge-train         mt-<repo>                3 + 16          = 19
#   issue-watcher       iw-<repo>-issue-<N>      3 + 16 + 7 + 5  = 31
#   post-merge-verify   mv-<repo>-pr-<N>         3 + 16 + 4 + 5  = 28
#
# These are NOT worst-case widths (#1553) — the `+ 5` / `+ 4` terms assume a
# 5-digit issue/PR number, an assumption with no headroom check anywhere. The
# repo segment is capped at 16 by `herdr_agent_repo_slug`, but the number is
# not capped at all: the real budget for issue-watcher's <N> is
# `32 - 3 - len(repo) - 7` digits, which SHRINKS as the watched repo's name
# grows:
#
#   repo length   issue-watcher digit budget
#   8  (dotfiles) 14
#   12            10
#   16 (max)      6
#
# A 16-char repo with a 7-digit issue number (33 chars) overruns this and
# `herdr_agent_name` returns 1 — fail-closed by design (truncating instead
# would let two different issues collide on one name). Not reachable today,
# since this repo's own slug (`dotfiles`, 8 chars) leaves 14 digits of
# headroom — pinned by `tests/bats/functions/herdr_agent_name.bats` T18b so
# it fails loudly, not silently, once a repo nearer the cap joins the list.
#
# The host and the owner are deliberately NOT part of the name. That is a
# concession, not an oversight, and it costs uniqueness on BOTH axes (PR #1532
# review, codex):
#
#   host   a github.com checkout and a GHES checkout sharing a repo name
#          collide — the pinning #1403/#1407 established everywhere else.
#   owner  `acme/dotfiles` and `other/dotfiles` collide too, and this one is
#          reachable from a single host: issue_watcher_cron.sh watches a *list*
#          of repos, so two same-basename entries would share `iw-dotfiles-
#          issue-<N>` and herdr would route the second dispatch's prompt at the
#          first one's pane (the failure PR #1447's review guarded against).
#
# What it buys is the 16 characters the repo needs: a host- and owner-qualified
# name does not fit in 32 at all, which is exactly how post-merge-verify ended
# up at 37 and was refused on every merge. A name that identifies nothing
# because herdr rejects it is worse than one that identifies a repo.
#
# Reachability today: `${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}`
# — the single watched-repos registry shared by issue_watcher_cron.sh and
# gh:pr-post-merge-verify's dispatch (#1555 unified what used to be two
# separate lists, one of them a tracked `docs/.ssot/` copy — see #1552) —
# holds exactly one entry (`dEitY719/dotfiles` on github.com), so neither
# collision can occur. The guard is that fact, not the code — #1530's 확정
# 사항 fixed the 16-char repo-only shape as a user decision and deferred the
# fix to a follow-up. Because the list is untracked and user-editable, no PR
# review or lint stands between a second same-basename entry and this
# collision, so issue_watcher_cron.sh also carries a runtime advisory: at
# watch-list load it warns (never blocks) when two entries share a basename
# (#1552). When a second host OR a second owner joins the watch list, append
# a short digest of `<host>/<owner>` here (e.g. `iw-dotfiles-a3f-issue-1530`,
# 26 chars — it fits). `tests/bats/functions/herdr_agent_name.bats` T20 pins
# the limitation so it fails visibly rather than silently when that day comes.
#
# No interactive guard, for the same reason gh_host.sh has none: the body is
# pure definitions and produces no output at file scope, and every real caller
# is a non-interactive cron tick or hook that sources this file directly.

# herdr_agent_repo_slug <identifier> [max-length] — print the normalized repo
# segment of <identifier> on stdout.
#
# <identifier> may be `repo`, `owner/repo` or `host/owner/repo`; everything up
# to the last `/` is dropped, so all three reduce to the repository name.
#
# Normalization, in order: fold case, replace every character outside herdr's
# safe set with `-`, collapse runs of `-`, strip leading `-`, truncate to
# [max-length] (default 16), then strip any trailing `-` — whether it was
# already there or the cut exposed it. The first character needs no special
# handling — callers prefix the result, and every prefix starts with a
# lowercase letter.
#
# Returns 1 with no output when the identifier normalizes to nothing (`...`,
# an empty string). A caller must never build a name out of that: an empty
# slug turns `iw-<repo>-issue-11` into `iw--issue-11`, which herdr accepts —
# a *wrong* name that starts sessions is worse than one it refuses.
herdr_agent_repo_slug() {
    _han_raw="${1-}"
    _han_max="${2:-16}"

    # host/ and owner/ prefixes: keep only what follows the last slash.
    _han_raw="${_han_raw##*/}"

    # One pipeline, one trailing-dash strip — placed *after* the cut. Stripping
    # before it as well would be dead work: truncation only removes characters
    # from the end, so it can expose a trailing dash but never hide one.
    _han_slug=$(
        printf '%s' "${_han_raw}" |
            tr '[:upper:]' '[:lower:]' |
            tr -c 'a-z0-9_-' '-' |
            sed -e 's/--*/-/g' -e 's/^-*//' |
            cut -c "1-${_han_max}" |
            sed -e 's/-*$//'
    )

    if [ -z "${_han_slug}" ]; then
        unset _han_raw _han_max _han_slug
        return 1
    fi
    printf '%s' "${_han_slug}"
    unset _han_raw _han_max _han_slug
}

# herdr_agent_name <prefix> <identifier> [suffix] — print a valid herdr agent
# name on stdout: `<prefix>-<slug>` or `<prefix>-<slug>-<suffix>`.
#
# <prefix> is the pipeline tag (`mt`, `iw`, `mv`) and must start with a
# lowercase letter — that is what satisfies herdr's first-character rule.
# [suffix] is the per-unit discriminator, already formatted by the caller
# (`issue-1495`, `pr-1528`).
#
# merge-train passes NO suffix, on purpose: that name is itself the NF-1
# singleton lock (`_pmt_train_state` asks herdr whether an agent by this exact
# name is still working). A number in it would make every tick compute a
# different name, find no running train, and start a second one merging onto
# the same base.
#
# Returns 1 with no output when <identifier> is unusable (see
# herdr_agent_repo_slug), or when the composed name would not satisfy herdr's
# rule. Only the repo segment is normalized; the prefix and the suffix arrive
# already formatted from the caller, so the finished name is checked here
# rather than trusted. That check is the whole point of this file: #1530 was
# invisible for 76 attempts precisely because nothing verified the name before
# `herdr agent start` was handed one it would refuse. An over-long prefix, or
# a suffix built from an issue number that arrived empty (`issue-`, giving
# `iw-dotfiles-issue-`), fails closed here instead — and every call site
# already treats a non-zero return as "skip this dispatch".
herdr_agent_name() {
    _han_prefix="${1-}"
    _han_suffix="${3-}"

    _han_name_slug=$(herdr_agent_repo_slug "${2-}") || {
        unset _han_prefix _han_suffix _han_name_slug
        return 1
    }

    if [ -n "${_han_suffix}" ]; then
        _han_name="${_han_prefix}-${_han_name_slug}-${_han_suffix}"
    else
        _han_name="${_han_prefix}-${_han_name_slug}"
    fi

    # `^[a-z][a-z0-9_-]{0,31}$`, as a POSIX glob. The trailing-dash case is
    # stricter than herdr itself: such a name would be *accepted*, which is the
    # worse failure the repo-slug comment above describes.
    case "${_han_name}" in
    [!a-z]* | *[!a-z0-9_-]* | *-)
        unset _han_prefix _han_suffix _han_name_slug _han_name
        return 1
        ;;
    esac
    if [ "${#_han_name}" -gt 32 ]; then
        unset _han_prefix _han_suffix _han_name_slug _han_name
        return 1
    fi

    printf '%s' "${_han_name}"
    unset _han_prefix _han_suffix _han_name_slug _han_name
}
