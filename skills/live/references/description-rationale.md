# live — why the description stays over the 250-char WARN band

`skill:check` check 16 puts a 250-character WARN band on `description:`. This
skill's is 391 characters and stays there **because it was measured, not
because it is preferred**.

## What was measured

dEitY719/dotfiles#1411 shrank this description and, in doing so, dropped its
`Sister skill of gh-verify:merged` boundary sentence. dEitY719/dotfiles#1417's
trigger eval measured what that cost:

| description | reject (merged's queries) | score |
|---|---|---|
| after dotfiles#1411, boundary dropped | 5/10 | 65% |
| boundary restored | 10/10 | 90% |

Rejection of `gh-verify:merged`'s queries fell 9/10 -> 5/10 and the score fell
85% -> 65%, breaking the `after >= before - 5%p` contract. Restoring the
negative trigger returned it to 10/10 / 90%.

## What that means for edits

The boundary sentence is load-bearing for discrimination against the sister
skill, so the description stays over 250 until a shorter wording is **measured**
to hold the same rejection rate. Do not trim it on sight.

The 391 above re-measures the shipped text: the eval itself ran against 379
characters, before the `/gh-verify:live` alias was added.

Procedure: dotfiles `claude/skills/skill-check/references/trigger-eval-procedure.md`.
