# merged — why the description stays over the 250-char WARN band

`skill:check` check 16 puts a 250-character WARN band on `description:`. This
skill's is 391 characters and stays there **because it was measured, not
because it is preferred**.

## What was measured

dEitY719/dotfiles#1411 shrank this description and dropped two distinct things:

1. the **positive discriminator** — "no running app", "dirty worktree";
2. the **boundary** — `Sister skill of gh-verify:live`.

dEitY719/dotfiles#1417's trigger eval measured each half separately, on this
skill's own eval set:

| description | score | recall | reject |
|---|---|---|---|
| before (pre-dotfiles#1411) | 90% | 8/10 | 10/10 |
| after (dotfiles#1411, 244 chars) | 75% | 7/10 | 8/10 — FAIL |
| boundary restored only | 75% | 5/10 | 10/10 — FAIL |
| both restored (388 chars) | 90% | 8/10 | 10/10 — PASS |

The boundary sentence restores **rejection**; the positive discriminator
restores **recall**. Both are load-bearing, which is why neither can be dropped
to get under 250.

## What that means for edits

The description stays over 250 until a shorter wording is **measured** to hold
90%. Do not trim it on sight.

The shipped 391 characters = that 388-character wording plus the
`/gh-verify:merged` alias, minus `/devx-pr-verify-merged` and "post-merge"
(leaving those in gives 426, which fails the band outright).

Procedure: dotfiles `claude/skills/skill-check/references/trigger-eval-procedure.md`.
