# The `/simplify` lane — why it runs first, alone (dEitY719/gh-verify-skills#18)

`/simplify` is the only lane in this skill that writes to the working tree.
Every other lane — agy, codex, opencode, hermes — is comment-only. Until #18
the five were dispatched together in Step 3's single turn, which put a writer
and an orchestrator that also edits files on the same tree at the same time.

## The four incidents that closed the question

All four landed on the same day.

| PR | what `/simplify` did | outcome |
|---|---|---|
| `dEitY719/harness-skills#17` | removed a trailing-slash strip it judged redundant; that strip was what kept a degenerate `/` input from becoming `:(exclude)/`, which kills `git ls-files` and — via `mapfile` — silently disables the gate | caught in review, commit dropped |
| `dEitY719/packaging-skills#12` | rewrote the R4 rule body in both `structure-spec.md` copies and `op-rules.md` — the exact lines a sibling PR had landed an hour earlier and the issue explicitly deferred to it | reverted 3 files, kept the rest |
| `dEitY719/gh-issue-skills#14` | ran against the pre-fix tree; its uncommitted edits undid the `[ -f ]` change both reviewers had just requested | discarded |
| `dEitY719/gh-verify-skills#17` | the subagent saw the concurrent review-all flow editing the same worktree, concluded an attack was underway, **reverted the codex-BLOCKER fix and committed on top**, and filed a false "critical incident" report | orchestrator proved the report false, reset to `origin`; not pushed |

The mechanism is the same each time. The agent starts from whatever the tree
looked like when it was spawned and finishes minutes later. In between the
orchestrator has read reviewer findings and edited files. The agent's own
`git status --porcelain` then reports those edits as *its* work — and it
commits them, or, as in the fourth case, treats them as hostile.

## The ordering, and why first rather than last

Both serialisations kill the race. This skill runs `/simplify` **first** — Step
2.5, after `gh pr checkout`, before any reviewer lane is dispatched.

- **Zero concurrency by construction, and it is checkable.** The tree is clean
  when the lane starts (Step 2.5 substep 1 asserts it) and the lane is the only
  thing running. Every one of the four incidents needs a second writer on the
  tree to happen at all; there is no second writer here.
- **Reviewers see the head that will be merged.** The simplify commit is pushed
  before dispatch, so reviewers review the simplified diff rather than a diff
  that is silently amended after they finished. Under the old ordering Step 4's
  push moved the head *out from under the label Step 3.5 had just applied*, and
  the skill had to drop `review-passed` to compensate. That whole compensation
  disappears: nothing pushes after the verdict is read.
- **The cost is one extra commit before review**, and an occasional missed
  cleanup on a hunk that a later `gh-pr:reply` fix introduces. Running last
  would catch those, at the price of either a second review round on a tree
  reviewers already signed off, or an unreviewed cleanup commit on the merged
  head. A missed cleanup is a smaller defect than a reverted correctness fix.

## The scope contract — quote this in the Agent prompt

The ordering removes the race; this contract removes the blast radius if some
future caller reintroduces one. Both are required (#18 states the constraint as
independent of the ordering choice).

> You are running the built-in `/simplify` pass on this PR's working tree.
> You are the only process editing this tree.
>
> You may edit files. That is all you may do.
>
> You must NOT run any of: `git revert`, `git reset`, `git checkout --`,
> `git restore`, `git stash`, `git commit`, `git push`, `git rebase`,
> `git cherry-pick`. The orchestrator commits your work after you return.
> SKILL.md Step 2.5 substep 2 abbreviates this list; **this blockquote is the
> canonical one** — quote it, do not retype a shorter version.
>
> You must NOT modify, undo, or "clean up" any hunk you did not author in this
> run — including changes that look wrong, redundant, or hostile. If you
> believe existing committed code is broken, say so in your report and leave it
> untouched. Reverting someone else's fix is never in scope for a cleanup pass.
>
> If `git status --porcelain` shows changes you did not make, stop, change
> nothing further, and report it. Do not commit it and do not undo it.

`/simplify` itself is a Claude Code built-in and is out of scope for this repo
(#18, "Not in scope"). Everything above is imposed by the dispatch, not by the
skill being dispatched.

## The commit, the push, and the stale label (Step 2.5 substep 3)

The **orchestrator** commits — never the agent. Because the tree was clean
before dispatch and the agent was the only writer, `git add -A` can only pick up
paths the agent authored, which is what makes #18's second verification
criterion hold.

Two flag choices are load-bearing, both from agy + codex review of PR #28:

- **`git add -A`, never `git commit -am`.** `-a` stages modifications to
  *tracked* files only. `/simplify`'s edit-only contract permits creating a
  file, and a new file is untracked — `-am` would silently leave it behind,
  where it survives as a dirty path that breaks Step 4's clean-tree assertion
  and, worse, gets swept into whatever commit `gh-pr:reply` makes next. `-A`
  is safe here precisely because of the clean-tree gate: with nothing dirty at
  dispatch, "everything" and "the agent's work" are the same set.
- **`-m`, never a bare `git commit`**: it opens an editor and hangs a
  non-interactive shell.

`<scope>` is a placeholder — derive it from the shared top-level path of the
staged files (`skills/review-all`, `docs`, …). Committing the literal string
`refactor(<scope>):` is a defect, not a template.

## The push must succeed, or the round stops (codex, PR #28 BLOCKER)

`git push` is the step that makes "reviewers read the simplified head" true. A
failed push — network, auth, a branch-protection rule — leaves the simplify
commit local while the remote head is still the pre-simplify one. Dispatching
Step 3 then reviews a tree that does not exist any more, and stamps verdict
markers with a sha the merge will never carry: the same class of silent
mis-certification #18 set out to close.

So this is the one hard-fail in an otherwise soft-fail skill. On push failure,
print the git error, leave the commit in place (it is not lost — it is local
and pushable by hand), and **exit without dispatching a single reviewer lane**.
A round that reviews the wrong head is worse than no round: the first produces
a verdict nobody should trust, the second produces none and says so.

```bash
PUSHED=0                                     # never left unset — agy, PR #28
if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -m "refactor(<scope>): simplify per /simplify" || exit 1
    if git push; then
        PUSHED=1
    else
        printf '[FAIL] simplify commit could not be pushed — reviewers would read the stale remote head. Push it by hand and re-run.\n' >&2
        exit 1
    fi
fi

if [ "$PUSHED" = "1" ]; then
    _SC="${DOTFILES_ROOT:-$HOME/dotfiles}/shell-common"; if [ ! -f "$_SC/functions/gh_pr_edit_safe.sh" ]; then [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || { printf '[gh-verify:review-all] no shell-common under %s, and CLAUDE_PLUGIN_ROOT is unset. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; _SC="$CLAUDE_PLUGIN_ROOT/lib/vendor/shell-common"; fi
    unset -f _gh_pr_drop_label 2>/dev/null || :; [ -f "$_SC/functions/gh_pr_edit_safe.sh" ] && . "$_SC/functions/gh_pr_edit_safe.sh"
    command -v _gh_pr_drop_label >/dev/null 2>&1 || { printf '[gh-verify:review-all] %s did not load a usable shell-common. On Claude Code this is a broken install; on any other harness export CLAUDE_PLUGIN_ROOT=<plugin dir> first.\n' "$_SC" >&2; return 1 2>/dev/null || exit 1; }; export SHELL_COMMON="$_SC"
    if _vl_err=$(_gh_pr_drop_label "$pr" review-passed "$TARGET_REPO" "$TARGET_HOST" 2>&1); then
        echo "[OK] \`review-passed\` 무효화됨 — /simplify 커밋이 push 되어 이전 판정은 만료"
    else
        echo "[WARN] \`review-passed\` 제거 실패 — 리뷰되지 않은 auto-fix 커밋에 판정이 남아 있다: ${_vl_err}"
    fi
fi
```

A `review-passed` left over from an earlier round certified a head that no
longer exists, so the push drops it (soft-fail — a label error never blocks the
flow). `review-blocked` is never dropped here: this step has no evidence any
blocker was addressed.

## Lane outcomes

The simplify outcome lives in its own variable, `$SIMPLIFY` — **not** in
`$LANES` (agy, PR #28 FOLLOW-UP). `$LANES` is a stream of
`<ai>:ok|skip|fail` rows that Step 3.5 walks and feeds to the verdict
aggregator; simplify produces no verdict, and a row whose value is outside that
three-token vocabulary would either be mis-parsed or force every consumer to
special-case it. Keeping it out of the stream is what makes "Step 3.5 skips it"
structural rather than a rule someone has to remember.

| `$SIMPLIFY` | Meaning |
|---|---|
| `committed` | ran, tree was dirty, commit pushed |
| `clean` | ran, changed nothing |
| `skip` | the clean-tree gate refused to dispatch, or the Agent could not run |

Step 6 prints it as `simplify:<value>` alongside the lane rows.

Soft-fail throughout: a failed simplify lane warns and Step 3 continues.

## What this ordering does not fix

`gh-pr:reply` (Step 5) still commits review fixes after the verdict label is
applied, so the merged head can differ from the head Step 3.5 certified. That
is by design — `gh-pr:reply` owns `review-passed` and applies it from its own
judgment after answering every comment. The point of #18 is only that no two
processes write the tree **at the same time**; a later, serialised writer is
fine.
