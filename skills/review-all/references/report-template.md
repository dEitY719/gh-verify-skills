# Step 6 — the report line and the `Next:` line

SKILL.md Step 6 names the two lines and points here; this file is the format
SSOT. Nothing here is optional: `gh-flow:issue` Step 2.4 and a human reading
the transcript both key off these exact shapes.

## The one status line

Exactly one line, `[OK]` / `[SKIP]` / `[WARN]`:

```
[OK] PR #<pr> reviewed (claude:OK codex:SKIP(402 deactivated_workspace) opencode:OK agy:SKIP(connection reset) hermes:SKIP(hermes: command not found) self:claude:fixed simplify:committed) — reply: inline — verdict: unlabelled
```

- **Lane rows** come from `$LANES`, the record Step 3 printed from
  `devx_pr_review_all_fanout` — one `<ai>:<preset>:ok` or
  `<ai>:<preset>:skip <reason>` per line (dEitY719/gh-verify-skills#56, #77).
  Pipe the variable through `devx_pr_review_all_lane_rows` before rendering:
  it fills `preset=default` into any 2-field row, so this file has exactly one
  row shape to read and does not re-derive the compatibility rule.
- **The rendering is this repo's, not the helper's.** Step 6 upper-cases the
  state and renders a `skip` as `SKIP(<reason>)`, the reason cut to its first
  ~40 characters. Nothing in `shell-common` renders this line.
- **A `default` lane prints `<ai>:<STATE>`; any other preset prints
  `<ai>:<preset>:<STATE>`** (#56). Same asymmetry, same reason, as the
  `<!-- ai-review:<ai>[:<preset>]:<sha> -->` marker grammar one level down
  (`review-verdict-label.md`): omitting `--lanes` must keep this line's shape,
  and `agy:default:OK` is not that. A run with
  `--lanes "opencode:default,opencode:thorough"` therefore reads
  `(opencode:OK opencode:thorough:OK ...)` — the preset field appears exactly
  where it is the only thing telling two lanes apart.
- **A `skip` lane is named `<ai>[:<preset>]:SKIP(<reason>)`** — never omitted.
  It feeds no verdict (#77 D-5), but the reader is still told which reviewer
  was lost and why.
- **`self:<SELF>:<value>`** is `$SELF_FIX` from Step 2.5 — `fixed`,
  `fixed(fallback)`, `clean` or `skip(<reason>)` (`self-fix-pass.md`);
  `self:unknown:skip(unidentified harness)` when Step 2.4 could not bind SELF.
  For `SELF=claude`, add one line after the status line: `self-fix log: <SELF_FIX_LOG>` —
  the kept `.out` (with its `.err` sibling) from the `claude -p` child, so a reader can
  confirm the built-in `/code-review` actually ran.
- **`simplify:<value>`** is `$SIMPLIFY` — `committed`, `clean`, `skip`, or
  `n/a` when `SELF` is not `claude` (`simplify-lane.md`).
- **Lane errors alone never downgrade the line to `[WARN]`** (#77 F-7). A
  run where every lane and the self-fix were skipped is still `[OK] ... —
  verdict: unlabelled`, exit 0. The `[WARN]` causes are only: a dirty tree
  after the lanes (Step 4), orphans, and a labelling write failure (Step 3.5:
  missing label, helper unavailable, non-zero write) — not Step 3.5's `no
  reviewer lane produced a verdict` line, which an all-skip round prints.
- **`ORPHANS` > 0** (Step 3.4) appends `orphans:<n>` after the lane rows and
  downgrades the line to `[WARN]`.
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
