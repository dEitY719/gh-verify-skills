# Step 6 — the report line and the `Next:` line

SKILL.md Step 6 names the two lines and points here; this file is the format
SSOT. Nothing here is optional: `gh-flow:issue` Step 2.4 and a human reading
the transcript both key off these exact shapes.

## The one status line

Exactly one line, `[OK]` / `[SKIP]` / `[WARN]`:

```
[WARN] PR #<pr> reviewed (agy:FAIL(argv limit) codex:OK opencode:SKIP hermes:SKIP simplify:committed) — reply: inline — verdict: unlabelled
```

- **Lane rows** come from `$LANES`, the record Step 3 wrote as it dispatched —
  one `<ai>:ok|skip|fail` per line. `simplify:<value>` is `$SIMPLIFY` from Step
  2.5 (`committed`, `skip`, ...); see `simplify-lane.md`.
- **A `fail` lane is named `<ai>:FAIL(<reason>)`** — never `SKIP`, never
  omitted (dEitY719/gh-verify-skills#14). A lane that failed and a lane that was
  never available are different facts, and collapsing them is how a round
  reports coverage it never had. `review-verdict-label.md` → "Aggregating the
  lanes" has the `<reason>` vocabulary.
- **Any failed lane downgrades the line to `[WARN]`.**
- **`ORPHANS` > 0** (Step 3.4) appends `orphans:<n>` after the lane rows and
  also downgrades the line to `[WARN]`.
- **The trailing clause is Step 3.5's outcome** — `review-blocked` or
  `unlabelled`. This skill never writes `review-passed`
  (`review-verdict-label.md`), so it is never the clause here either.

## The `Next:` line

One line, keyed to that trailing clause. `unlabelled` reads downstream as "not
verified yet", which `[OK]` alone does not convey — that is why the report
always ends with an explicit next action rather than stopping at the status
line. Exactly one bullet fires, first match wins:

| Clause | `Next:` |
|---|---|
| `review-blocked` | `Next: fix the blockers, then /gh-verify:review-all <pr> --force-review` |
| reply deferred (`--defer-reply`) | `Next: reply scheduled in <reply_delay>m; the PR carries reply-pending until it lands` |
| otherwise (`unlabelled`) | `Next: /gh-pr:reply <pr> <remote>` |

The deferred row is a statement, not an instruction: **do not run the reply
pass by hand** while the schedule is pending, or two passes answer the same
comments. The `unlabelled` row is the common one — that pass is what writes
`review-passed`, which this skill cannot (dEitY719/dotfiles#1636).
