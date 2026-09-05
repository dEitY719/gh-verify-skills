# gh-verify:review-all — Review verdict → merge-gate label

SSOT for how a reviewer lane's closing verdict line becomes a machine-readable
PR label. Implementation: `shell-common/functions/devx_pr_review_all.sh`;
regression suite: `tests/bats/functions/devx_pr_review_all_verdict.bats`.

Why it exists: every `gh-pr:review` preset mandates a closing verdict line, and
until dEitY719/dotfiles#1527 nothing in the repo read it. PR dEitY719/dotfiles#1518 collected two independent
blocking verdicts and merged 32 minutes later, because the merge train's only
real gate was CI.

**Wiring status — fully wired as of dEitY719/dotfiles#1564; label ownership split in dEitY719/dotfiles#1636.**

| side | where | since |
|---|---|---|
| marker (`<!-- ai-review:<ai>:<sha> -->`) | `_gh_pr_review_build_comment_body` in `gh_pr_review.sh` | dEitY719/dotfiles#1564 |
| producer of `review-blocked` (parse → aggregate → label) | `gh-verify:review-all` **Step 3.5**, via `devx_pr_review_all_apply_label` | dEitY719/dotfiles#1564 |
| producer of `review-passed` (own judgment, no re-review) | `gh-pr:reply` **Step 6**, via `_gh_pr_reply_apply_review_passed`, dotfiles `claude/skills/gh-pr-reply/references/review-passed-gate.md` | dEitY719/dotfiles#1636 |
| shared write primitive (drop-opposite → safe-add → marker) | `devx_pr_review_all_write_label` | dEitY719/dotfiles#1636 |
| invalidation (drop a stale verdict) | `_gh_pr_drop_label`, called by every head-advancing skill | dEitY719/dotfiles#1563 |
| cleanup after merge (drop `review-passed`) | `gh-pr:merge` **Step 4**, dotfiles `claude/skills/gh-pr-merge/references/review-passed-cleanup.sh.md` | dEitY719/dotfiles#1636 |
| consumer (hard merge gate) | `gh-pr:merge-train` **Step 3.5**, `references/review-verdict-gate.md` | dEitY719/dotfiles#1564 |
| provisioning (the labels exist in the repo) | `gh-setup:label-bootstrap` pipeline feed | dEitY719/dotfiles#1564 |
| freshness (sha marker for `review-passed`) | `devx_pr_review_all_write_label`'s 5th arg; read by `_gh_pr_merge_train_review_passed_stale` | dEitY719/dotfiles#1601 |

The consumer side is untouched by the dEitY719/dotfiles#1636 split: `gh-pr:merge-train` reads
whichever labels exist and does not care who wrote them. What changed is
authorship, not meaning — `review-passed` still means "safe to merge this
head".

dEitY719/dotfiles#1563's label-lifecycle invalidation rules are the piece that makes the rest
safe: every skill that advances a PR's head (`gh-pr:reply`,
`gh-resolve:conflict`, `gh-resolve:outdated`) drops the stale verdict
through the shared `_gh_pr_drop_label` helper, whose header comment in
`shell-common/functions/gh_pr_edit_safe.sh` is the SSOT for the asymmetry rule
(`review-passed` always; `review-blocked` never by drop — it is cleared only
as the side effect of a new non-blocking decision written through
`devx_pr_review_all_write_label`).

## Who applies `review-passed` (dEitY719/dotfiles#1636), and the NF-2 relaxation

Until dEitY719/dotfiles#1636 this skill applied both labels, and `gh-pr:reply` could only reach
`review-passed` by paying for an independent `gh-pr:review` re-call (dEitY719/dotfiles#1616's
targeted lane). That re-call was the **only** way to re-earn the label after a
fix, and its cost, latency and failure rate is what repeatedly jammed
`gh-pr:merge-train` (dEitY719/dotfiles#1627).

So the responsibility moved:

- **`gh-verify:review-all` never writes `review-passed`.** An all-non-blocking
  aggregate now clears any stale `review-blocked` (mutual exclusion is
  unchanged) and leaves the PR **unlabelled** — which has always read
  downstream as "not verified", never as a pass.
- **`gh-pr:reply` writes it**, after replying to every review comment, when no
  BLOCKER-severity item is left unresolved — **from its own judgment, with no
  external AI CLI in the loop**.

That is a deliberate relaxation of NF-2 ("never self-certify", established in
dEitY719/dotfiles#1527 / dEitY719/dotfiles#1563 and re-affirmed by dEitY719/dotfiles#1616), scoped to this one path, and it is
documented loudly here and in `gh-pr-reply/references/constraints.md` rather
than buried, because it is a safety-principle change:

- **Why** — the user weighed one extra verification hop against pipeline
  reliability and cost, and chose reliability. Explicit decision, recorded in
  dEitY719/dotfiles#1636's "확정 사항", not a drift.
- **What still verifies** — the findings remain external. This skill still
  fans out every reviewer on every PR, still posts their findings, and still
  owns `review-blocked`. The division of labour is "an outside AI **finds**;
  `gh-pr:reply` confirms it **fixed** what was found".
- **What did not change** — the fail-closed half. One unresolved
  BLOCKER-severity item (DECLINE or QUESTION) means no `review-passed`, ever.
  A failed write leaves the PR unlabelled. `review-blocked` is still issued
  only by an external reviewer's verdict, and `gh-pr:reply` can never write it.

## The labels

| label | meaning | written by |
|---|---|---|
| `review-blocked` | at least one reviewer lane returned a blocking verdict | `gh-verify:review-all` Step 3.5 |
| `review-passed` | every review comment was answered and no BLOCKER-severity item is unresolved | `gh-pr:reply` Step 6 (dEitY719/dotfiles#1636) |

Neither belongs to the 10-label SSOT (`gh-label-bootstrap/references/gh-labels.md`).
Like `CI fail` and `conflict` they are **pipeline-state** labels, not
issue-classification ones, and that document explicitly scopes such labels out.
They are provisioned from that file's **separate `pipeline|` feed** instead
(dEitY719/dotfiles#1564), which `--prune` preserves alongside the base 10.

**Absence is the third state, and it means "not verified".** A PR carrying
neither label has not been shown to pass review. That is what makes a time
backstop unnecessary here: a stuck PR is one label away from moving, and a
human can add or remove it at any time.

## The five helpers

```
devx_pr_review_all_lane_block <ai> [<head-sha>] <expected-login>
                                                  # RAW comments JSON on stdin
  -> that lane's raw block as written BY <expected-login>, or nothing
devx_pr_review_all_verdict                        # one lane's raw text on stdin
  -> blocking | concerns | lgtm | unknown
devx_pr_review_all_aggregate                      # verdict tokens on stdin,
                                                  #   one per line, one per lane
  -> label=review-blocked | label=review-passed | label=    (+ lanes=N)
devx_pr_review_all_apply_label <pr> <repo> [host] [head-sha]  # tokens on stdin
  -> aggregates; writes `review-blocked`, or clears it on a non-blocking
     round. Never writes `review-passed` (dEitY719/dotfiles#1636). One report line.
devx_pr_review_all_write_label <label> <pr> <repo> [host] [head-sha]
  -> the verdict-free write: removes the opposite label, adds <label> via
     `_gh_pr_edit_safe_label`, stamps the dEitY719/dotfiles#1601 marker for `review-passed`.
     Machine tokens on stdout: `add=ok|rc3|failed|no-helper`,
     `marker=posted|failed|none`.
```

The first three are pure: stdin in, stdout out, no network, no shell state.
The last two touch GitHub, and both are soft-fail by construction — see
"Applying the label" below.

`devx_pr_review_all_write_label` is the split dEitY719/dotfiles#1636 made so the second
producer could exist honestly. It takes a **label**, not a verdict, so
`gh-pr:reply` can write `review-passed` from its own judgment without
synthesizing a fake `lgtm` token to push through the aggregator — a fake
token would have recorded that skill's judgment as a reviewer CLI's opinion
in the label-application code, which is the one thing dEitY719/dotfiles#1636 rules out.

## Reading a lane's verdict

Each reviewer lane (`agy`, `codex`, `opencode`, `hermes`) ends its output with
a mandatory verdict line — `판정: [LGTM|우려있음|블로킹]` or
`Verdict: [LGTM|CONCERNS|BLOCKING]` (`gh-pr-review/references/review-presets.md`,
rendered at runtime by `_gh_pr_review_common_prefix` in `gh_pr_review.sh`).

**Do not try to read that line out of the lane's return value.** `gh-pr:review`
guarantees exactly one line back — `[OK] PR #<N> reviewed by <ai> … — comment:
<URL>` — and each lane runs as a subagent, which returns a *summary* of what it
did. Neither carries the verdict. A gate built on that would have every lane
parse as `unknown`, never write a label, and skip every PR forever.

Read it from the artifact the lane already wrote instead. `gh-pr:review` Step 6
posts the reviewer's raw output to the PR wrapped in
`<!-- ai-review:<ai>:<head-sha> -->` markers, synchronously, before it returns —
a durable machine-readable record rather than a summary. Fetch the comments
**once**, then per lane:

```sh
_SC="${SHELL_COMMON:-$HOME/dotfiles/shell-common}"
[ -f "$_SC/functions/devx_pr_review_all.sh" ] || { _SC="${CLAUDE_PLUGIN_ROOT:-}/lib/vendor/shell-common"; export SHELL_COMMON="$_SC"; }
. "$_SC/functions/devx_pr_review_all.sh"

head_sha=$(GH_HOST="$TARGET_HOST" gh pr view "$pr" --repo "$TARGET_REPO" \
    --json headRefOid --jq .headRefOid)

# RAW JSON — no `--jq '.[].body'`. `.user.login` is what the author check
# below reads, and pre-extracting `.body` throws it away (dEitY719/dotfiles#1639).
BODIES=$(GH_HOST="$TARGET_HOST" gh api --paginate \
    "repos/$TARGET_REPO/issues/$pr/comments")

# The one identity this pipeline authenticates as — the same login whose
# `gh-pr:review` Step 6 run posted the marker. Resolved once per run.
# DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN overrides it for setups where the reviewer
# and this aggregator authenticate as different accounts (see "Marker
# authorship" below).
ME="${DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN:-${ME:-$(GH_HOST="$TARGET_HOST" gh api user -q .login)}}"

verdict=$(printf '%s\n' "$BODIES" |
    devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME" |
    devx_pr_review_all_verdict)
# -> blocking | concerns | lgtm | unknown
```

`devx_pr_review_all_lane_block` takes the **last complete** block for that lane,
so a re-review supersedes an earlier verdict, and it ignores an unterminated
block — half a review is not a verdict.

### Marker authorship (dEitY719/dotfiles#1639)

A `<!-- ai-review:<ai>:<sha> -->` block is plain text in an ordinary PR
comment, and on most repos anyone who can see the PR can post one. Until
dEitY719/dotfiles#1639 this harvester was handed pre-extracted body text (`--jq '.[].body'`)
with the author already discarded, so a hand-forged block from **any**
commenter decided a lane's verdict — and through the aggregator, the
`review-blocked` merge gate. Commenting is a far lower bar than the
label-write access needed to attach that label directly.

`devx_pr_review_all_lane_block` therefore takes a required `<expected-login>`
and counts a block only from that exact GitHub login. Forging a lane verdict
now costs the same access as forging the label directly — the pre-existing,
already-accepted trust boundary this gate has always rested on. A
missing/invalid login harvests **nothing** (→ `unknown` → no label,
fail-closed), never a fallback to trusting every author.

This is the same fix, validator, and reasoning PR dEitY719/dotfiles#1608 applied to
`_gh_pr_merge_train_review_passed_marker_sha`; see
dotfiles `claude/skills/gh-pr-merge-train/references/review-verdict-gate.md` →
"Marker authorship" for the full argument. The two follow-on points carry
over unchanged:

- **Bot logins.** GitHub gives an App identity a login shaped `<name>[bot]`
  (`github-actions[bot]`, `dependabot[bot]`). The validator strips one literal
  trailing `[bot]` and then applies `[A-Za-z0-9-]+` to what is left, so a
  bot-authenticated pipeline can validate its own markers while an injection
  attempt (which will not end in exactly `[bot]`) still cannot.
- **Single-identity assumption + escape hatch.** The scheme assumes one
  account runs both `gh-pr:review` (which posts the marker) and this skill
  (which reads it) — true for this repo's single-account pipeline, but not
  every deployment. `DEVX_PR_REVIEW_ALL_TRUSTED_LOGIN` overrides the
  auto-detected identity when the producer login differs from
  `gh api user -q .login`'s answer here. It is deliberately **separate** from
  `GH_PR_MERGE_TRAIN_TRUSTED_LOGIN` and `GH_PR_REPLY_TRUSTED_LOGIN`: in
  practice one account runs all three, but a deployment that splits the
  review, reply, and merge roles across accounts must be able to set each
  independently.

Note the filter is a local `jq` pass over the comment dump the caller already
fetched — **not** a `gh api` call of its own. This function is invoked once per
reviewer lane against the same `$BODIES`, so a network-aware author check would
multiply that single fetch by the lane count on every run.

### Freshness: the head-sha argument

The second argument is optional to the *function*, not to a caller that gates a
merge. Without it the helper cannot tell a block this run just posted from one
left by an earlier round. A run that posted nothing —
`GH_DISABLE_AI_METRICS=1`, `--no-post-comment`, or a post that failed — would
then silently reuse a stale verdict, and a stale verdict can authorize a merge
of code it never saw.

With a sha given, only `<!-- ai-review:<ai>:<head-sha> -->` … `<!-- /ai-review:<ai>:<head-sha> -->`
blocks match, both markers must carry the same sha, and a lane with no block for
that exact ai+sha pair yields nothing — which reads downstream as `unknown`,
so no label, so no merge. Fail-closed.

`gh-pr:review`'s marker writer (`_gh_pr_review_build_comment_body` in
`shell-common/functions/gh_pr_review.sh`) emits the sha-tagged form since
dEitY719/dotfiles#1564; the sha comes from the `headRefOid` field of the one consolidated
`gh pr view` that function's caller already makes, so freshness costs no extra
round-trip. **Always pass the sha.** Omitting it is not a safer default — it
is the stale-verdict hole this argument exists to close.

> **Comments posted before dEitY719/dotfiles#1564** carry the unsuffixed marker and read as
> `unknown` under the sha-aware path — no label, no merge. That is the
> documented fail-closed direction: the PR is re-reviewed, and the fresh
> comment carries the tag. Do **not** add a compatibility path that accepts an
> untagged block when a sha was requested; it would resurrect exactly the reuse
> this closes.

**Read the sha before any push of this run.** The lanes reviewed the PR's
current *remote* head. `gh-verify:review-all`'s own `/simplify` lane may have
committed locally by the time the verdicts are collected, but Step 4 has not
pushed yet — so `gh pr view --json headRefOid` still answers the sha the lanes
actually reviewed. Reading it after the push answers the *new* sha, every lane
misses, and the gate is silently dead. That is why Step 3.5 sits before Step 4.

### What the verdict parser accepts

- Case-insensitive, both `판정:` and `Verdict:`, fullwidth `：` normalized.
- Surrounding markdown emphasis and a leading list dash are stripped.
- Only lines that *start* with the verdict key count; a finding line such as
  `[BLOCKER] a.sh:1 — …` is never mistaken for the verdict.
- The last verdict line in the input wins — the presets put it last.
- The **unanswered template** is rejected: a value that opens with `[` *and*
  carries a `|` inside the brackets (`[LGTM|CONCERNS|BLOCKING]`) is a lane
  echoing its own instructions back, and yields `unknown`.
- A genuine answer that merely contains a pipe or a bracket elsewhere still
  parses: `Verdict: BLOCKING | 5 findings` → `blocking`, `Verdict: [BLOCKING]`
  → `blocking`, `판정: 블로킹 [BLOCKER 4건]` → `blocking`. Rejecting any line
  containing `|` was dEitY719/dotfiles#1527's bug; it left real blocking verdicts unlabelled.
- Anything else — no verdict line, an unrecognized value — is `unknown`.

## Aggregating the lanes

`devx_pr_review_all_aggregate` reads **newline-delimited verdict tokens from
stdin**, one line per lane that ran. It does *not* take positional arguments,
and that is load-bearing rather than stylistic: the obvious call site
`devx_pr_review_all_aggregate $VERDICTS` depends on the shell word-splitting an
unquoted expansion, which zsh does not do without `SH_WORD_SPLIT`. In zsh the
whole string arrived as one argument, so a two-lane PR reported `lanes=1` and
dropped the blocking verdict outright — and zsh is this repo's default
interactive shell. A newline-delimited stream behaves identically in bash, zsh
and dash.

Build the stream with `printf` inside the lane loop and pipe it straight in.
Never stage the verdicts in a variable and re-expand it:

```sh
AGG=$(
    for ai in agy codex opencode hermes; do
        lane_ran "$ai" || continue          # a skipped lane contributes NOTHING
        v=$(printf '%s\n' "$BODIES" |
            devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME" |
            devx_pr_review_all_verdict)
        printf '%s\n' "$v"
    done | devx_pr_review_all_aggregate
)
label=$(printf '%s\n' "$AGG" | sed -n 's/^label=//p')
lanes=$(printf '%s\n' "$AGG" | sed -n 's/^lanes=//p')
```

Read the two `key=value` lines with `sed`, not `eval` — the values are
controlled, but a parser that cannot execute anything is the right default for
something that gates a merge.

In practice the call site pipes the same stream straight into
`devx_pr_review_all_apply_label` (next section), which does this aggregation
and the two `sed` reads internally. Reach for `devx_pr_review_all_aggregate`
directly only when you want the verdict *without* writing a label.

| lanes that ran | outcome | `label` |
|---|---|---|
| any lane `blocking` | blocked | `review-blocked` |
| ≥1 lane, all `lgtm`/`concerns` | passed | `review-passed` |
| ≥1 lane, any `unknown` | verdict not established | *(empty)* |
| zero | nothing was checked | *(empty)* |

`우려있음`/`CONCERNS` is a **pass** — a non-blocking opinion, which `gh-pr:reply`
still answers. `unknown` is not, because a lane whose output stopped parsing is
indistinguishable from a lane that never reached a verdict.

**A lane that did not run contributes no line at all.** `command -v` empty, a
non-internal PC, a non-zero exit — every `[SKIP]`/`[WARN]` row of the report —
is absent from the stream, not an `unknown`. "Not checked" and "checked and
passed" must never collapse into the same state. The `/simplify` lane never
contributes; it produces no verdict. Blank lines are ignored, so a stray one
cannot inflate `lanes=` into a false "verified".

## Applying the label

`devx_pr_review_all_apply_label` (`shell-common/functions/devx_pr_review_all.sh`)
owns this. Build the verdict stream and pipe it in — do **not** stage the
verdicts in a variable and re-expand it (same zsh rule as the section above):

```sh
for ai in agy codex opencode hermes; do
    lane_ran "$ai" || continue          # a skipped lane contributes NOTHING
    printf '%s\n' "$BODIES" |
        devx_pr_review_all_lane_block "$ai" "$head_sha" "$ME" |
        devx_pr_review_all_verdict
done | devx_pr_review_all_apply_label "$pr" "$TARGET_REPO" "$TARGET_HOST" "$head_sha"
```

**Keep passing `$head_sha` as the 4th argument** (dEitY719/dotfiles#1601) — the same sha
already read at the top of this section, before any push. On this skill's own
paths it is now inert (nothing here stamps a marker any more), but the
argument is what carries the sha on the shared write path and dropping it from
the call site would silently break the day another producer routes through
here. See "Freshness marker for `review-passed`" below.

What it does, and why each part is the way it is:

- **A non-blocking aggregate writes no label (dEitY719/dotfiles#1636).** It removes any stale
  `review-blocked` — mutual exclusion is unchanged — and reports the handoff.
  `review-passed` is `gh-pr:reply`'s to apply.
- Adds through `_gh_pr_edit_safe_label` (`shell-common/functions/gh_pr_edit_safe.sh`),
  never bare `gh pr edit --add-label` — that silently exits 1 on repos with
  classic Projects attached (#326). The opposite label is removed through the
  REST endpoint, for the same reason.
- **The opposite label is removed first, and unconditionally.** A re-review
  that flips `review-blocked` to non-blocking has to clear the old one, or a
  consumer sees both. (`gh-pr:merge-train`'s gate resolves that case
  deterministically — `review-blocked` wins — but a consumer should never have
  to.)
- `GH_HOST` is pinned per call inside a subshell, so a dual-host login cannot
  write the label to the wrong server (dEitY719/dotfiles#1403 / dEitY719/dotfiles#1407) and the caller's own
  `GH_HOST` survives.
- **Soft-fail throughout**: rc is 0 for every labelling outcome, because an
  unlabelled PR already reads as "not verified" downstream. Only a usage error
  (missing `<pr>`/`<repo>`) returns 2.

It prints one primary line:

| stream | line |
|---|---|
| a `blocking` lane | `[OK] PR #<n> labelled \`review-blocked\` (<k> lane(s))` |
| ≥1 lane, all non-blocking | `[OK] PR #<n>: every lane non-blocking (<k> lane(s)) — \`review-blocked\` cleared; \`review-passed\` is gh-pr:reply's to apply (dEitY719/dotfiles#1636)` |
| empty `label` (no lane, or an `unknown`) | `[WARN] no reviewer lane produced a verdict — PR #<n> left unlabelled` |
| `_gh_pr_edit_safe_label` rc 3 | `[WARN] label \`<l>\` missing in <repo> — provision it first (gh-setup:label-bootstrap)` |
| the add helper is unavailable | `[WARN] _gh_pr_edit_safe_label unavailable — PR #<n> left unlabelled` |
| any other non-zero rc | `[WARN] labelling PR #<n> failed — treat the PR as unverified` |

A second `[WARN]` line is possible only on the marker path in "Freshness
marker for `review-passed`" below, which since dEitY719/dotfiles#1636 this function can no
longer reach — `gh-pr:reply`'s writer prints it instead. Every outcome above
is exactly one line.

`_gh_pr_edit_safe_label` returns 3 when the label does not exist in the repo and
**refuses to auto-create it** (`feedback_gh_label_no_autocreate.md`, #326) —
hence the `gh-setup:label-bootstrap` pointer in that line. Its `pipeline|` feed
(`gh-label-bootstrap/references/gh-labels.md`) is where the two labels are
provisioned, and `--prune` preserves them.

## Freshness marker for `review-passed` (dEitY719/dotfiles#1601)

The label alone only proves "some head was reviewed" — its invalidation
depends on every skill that advances a PR's head remembering to drop it
(`gh_pr_edit_safe.sh` → "Verdict-label invalidation"). That list can never be
complete: a manual `git push --force-with-lease`, a GitHub web-UI commit, or
a future tool all advance the head with no hook this repo controls, leaving
a stale `review-passed` that `gh-pr:merge-train`'s gate would trust.

`devx_pr_review_all_write_label`'s 5th argument closes that gap from the
*read* side instead of chasing more write-side call sites. When the label
being written is `review-passed` and a head-sha is given, it posts one plain
issue comment:

```
<!-- review-verdict:review-passed:<head-sha> -->
```

`gh-pr:merge-train`'s gate (`_gh_pr_merge_train_review_passed_stale` in
`shell-common/functions/gh_pr_merge_train.sh`) reads the last such marker back
and compares its sha against the PR's *current* `headRefOid` before trusting
the label — full detail:
`gh-pr-merge-train/references/review-verdict-gate.md` → "Freshness check".

This is a different thing from the "not a comment parser" rule two sections
up: that rule forbids re-deriving a reviewer's LGTM/BLOCKING verdict from
free-form CLI output, where a reformat could silently unlock the gate. This
marker is a fixed, machine-only stamp only this function ever writes, read by
a fixed regex — no reviewer output touches it either way.

Never posted for `review-blocked`: a stale block is already the safe
direction (it over-skips, never over-merges), so it needs no freshness proof.
The post is soft-fail — it never changes the writer's `add=` token or its
rc 0 — but a failed post is reported as `marker=failed`, and the producer
that asked for the write turns that into a second `[WARN]` line naming the
PR (PR dEitY719/dotfiles#1608 review, agy + codex BLOCKER: silently losing the marker meant a
"successfully labelled" PR could later read as stale on the merge train with
no trace of why). Since dEitY719/dotfiles#1636 that producer is `gh-pr:reply`
(`_gh_pr_reply_apply_review_passed`), which prints the same wording.

## Why this lives in the producer

The alternative — having the merge train grep review comment bodies — couples
the merge gate to every reviewer CLI's output format. A reviewer reformatting
its verdict line would then silently *unlock* the gate. Parsing here means the
same reformat produces `unknown`, no label, and a skipped PR: the failure
direction is the safe one.

The decisive reason, though, is that **only the producer knows which lanes
ran**. A consumer reading comment bodies cannot tell "lane skipped" from "lane
ran and posted nothing" — and that distinction *is* the absence-is-not-a-pass
invariant. It is not recoverable downstream at any level of parsing care.
