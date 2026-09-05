# gh-verify:review-all — Duplicate-review guard

SSOT for how Step 3 avoids re-running a reviewer lane that already reviewed the
PR's current head. Implementation: `devx_pr_review_all_already_reviewed` in
`shell-common/functions/devx_pr_review_all.sh`; regression suite:
`tests/bats/functions/devx_pr_review_all_dedupe.bats`. Issue: dEitY719/dotfiles#1613.

Why it exists: nothing gated the fan-out on "has this already been reviewed?".
On PR dEitY719/dotfiles#1608 two sessions reviewed the same head sha `2d7bbdca` 36 minutes
apart, so agy and codex each ran twice and posted duplicate review comments —
wasted reviewer budget, and a comment thread where a reader cannot tell a
re-review from a second opinion.

## The algorithm

Once, before any lane is dispatched:

```sh
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/devx_pr_review_all.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }
. "$_SC/functions/devx_pr_review_all.sh"

head_sha=$(GH_HOST="$TARGET_HOST" gh pr view "$pr" --repo "$TARGET_REPO" \
    --json headRefOid --jq .headRefOid)

# RAW JSON — deliberately no `--jq` body extraction. Since dEitY719/dotfiles#1639 the guard
# filters comments by `.user.login`, and pre-extracting the body would throw
# the author away before the guard ever sees it.
BODIES=$(GH_HOST="$TARGET_HOST" gh api --paginate \
    "repos/$TARGET_REPO/issues/$pr/comments")

# The one identity this pipeline authenticates as — the login whose
# `gh-pr:review` run posted the marker. DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN is the
# escape hatch when the reviewer and this skill authenticate as different
# accounts (see "Marker authorship" in references/review-verdict-label.md).
ME="${DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN:-${ME:-$(GH_HOST="$TARGET_HOST" gh api user -q .login)}}"
```

Then per lane, before dispatching its Agent:

```sh
if [ "$force_review" != "1" ] &&
    printf '%s\n' "$BODIES" | devx_pr_review_all_already_reviewed "$ai" "$head_sha" "$ME"; then
    echo "[SKIP] $ai already reviewed head $head_sha — pass --force-review to re-run"
    continue
fi
```

`devx_pr_review_all_already_reviewed` is a thin wrapper over
`devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME"`: rc 0 when that lane has a
complete `<!-- ai-review:<ai>:<head-sha> -->` block, rc 1 otherwise. One parser
for the marker grammar, so the guard and Step 3.5's verdict harvester can never
disagree about what "already reviewed" means. The `<head-sha>` is mandatory
here — without it an older, untagged block would match and every re-review
would be skipped forever.

A guard-skipped lane reports `[SKIP]`, but — unlike a lane skipped for a
missing CLI — it still **must** contribute a verdict line to Step 3.5 (agy +
codex, PR dEitY719/dotfiles#1623 BLOCKER): its earlier verdict is still on the PR under the
same head sha, and Step 3.5's aggregator has no other way to see it. Dropping
a guard-skipped lane from the aggregation stream would let a partial re-run —
say, only one lane force-re-reviewed while the rest sit guard-skipped — silently
overwrite an existing `review-blocked` verdict with `review-passed`, because
the aggregator only ever sees the lanes actually fed to it. Since
`devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME"` reads whatever marker
already exists in `$BODIES` from that login, regardless of which run posted it,
feeding a guard-skipped
lane through the same harvester the fresh lanes use costs nothing extra — the
guard already proved the marker exists by skipping it. See `SKILL.md` → Step
3.5 for the corrected aggregation loop.

## Why here, not inside `gh-pr:review`

`gh-pr:review` is single-shot per invocation: one AI, one PR, one comment. It
has no concept of "another session already ran this lane", and adding one would
put a network read in front of every direct `/gh-pr:review` call — including
the deliberate re-reviews that skill exists to serve. The fan-out orchestrator
is the only layer that knows it is issuing a *batch* and can amortize one
shared `head_sha`/`BODIES` fetch across all of it.

## Why it fails open

A `gh pr view` / `gh api` error here must not abort the review: treat every
lane as not-yet-reviewed and dispatch normally. The worst case is the duplicate
comment this guard merely optimizes away, whereas failing closed would skip a
real review and leave the PR unverified. Same NF-1 soft-fail posture as the
3.3b duplicate-open-PR guard in `gh-issue:implement`, which this parallels —
and the opposite of Step 3.5's fail-**closed** freshness rule
(`review-verdict-label.md`), correctly so: that gate authorizes a merge, this
one only decides whether to spend a reviewer.

## Known limitation: this is a check, not a lock (codex, PR dEitY719/dotfiles#1623 BLOCKER)

The guard is a **read-before-write (TOCTOU) check**: it reads `BODIES`, decides
"not yet reviewed", and only then dispatches. Two sessions can both read the
same pre-review `BODIES` snapshot within the same race window and both
conclude "not yet reviewed" — the guard does not serialize concurrent runs, so
the exact scenario it targets (PR dEitY719/dotfiles#1608's two overlapping sessions) can still
slip through if both sessions start close enough together.

This is accepted, not overlooked. Issue dEitY719/dotfiles#1613 weighed two designs — this
pre-dispatch check (Option 1) versus a file-based lock mirroring
`gh-pr:merge-train`'s NF-1 flock (Option 2) — and chose Option 1 as the
priority: a lock file is awkward to place consistently across the multiple
worktrees/accounts this repo's sessions run from, while the check reuses
`devx_pr_review_all_lane_block`, a helper that already existed for Step 3.5.
The check does not need to close the race to be worth shipping — it converts
"two sessions racing 36 minutes apart" (PR dEitY719/dotfiles#1608's actual reproduction) from a
certainty into a narrow same-instant coincidence, at zero added infrastructure.
A lock-based Option 2 remains available as a follow-up if the residual race
proves to matter in practice.
