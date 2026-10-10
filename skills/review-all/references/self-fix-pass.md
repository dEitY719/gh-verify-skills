# Step 2.4 / 2.5 — bind SELF, then the self-fix pass (dEitY719/gh-verify-skills#77)

The harness running this skill reviews the PR itself and fixes what it finds,
**before** the Step 3 fan-out, so every reviewer lane reads the fixed head.
It is a writer step, so it inherits the #18 serialisation contract whole: a
clean tree, one writer at a time, edit-only writers, the orchestrator commits,
one push, push failure is the only hard-fail (`simplify-lane.md`).

## Step 2.4 — bind SELF

The model declares which harness it is running in, exactly as
`gh-issue:issue-create` Step 3.5 binds `HARNESS`:

```
SELF=claude | codex | opencode | agy | hermes | unknown
```

Declare it from what you know about yourself. **Never** derive it from env
variables (`CLAUDECODE`, ...): their names change between harness versions
(`session-skills` `worktree-spawn/references/agent-detection.md`). Not sure →
`SELF=unknown`, which skips only the self-fix pass (`self:unknown:skip(unidentified
harness)`); `/simplify` is still `n/a` and the fan-out runs as normal (#77 F-1).

## Step 2.5 — the substeps, in order

| # | Substep | Writer | Commit message |
|---|---|---|---|
| a | clean-tree gate | — | — |
| b | `LANES_START_TS=$(date +%s)` (carry as a literal into Step 3.4) | — | — |
| c | self review + fix (per `SELF`, below) | `claude -p` child, or the session itself | `fix(<scope>): apply self-review findings (<SELF>)` |
| d | `/simplify` — `SELF=claude` only, else `SIMPLIFY=n/a` | one edit-only Agent | `refactor(<scope>): simplify per /simplify` |
| e | one push if any commit was made, then drop stale `review-passed` | — | — |

**a — the clean-tree gate.** `git status --porcelain` must be empty. Non-empty
→ `SELF_FIX='skip(dirty)'`, `SIMPLIFY=skip`, print `[SKIP] self-fix: working tree
dirty`, and go straight to Step 3 (record `LANES_START_TS` there instead). This
gate is what makes each later `git add -A` stage only the step's own work.

**c and d run one after the other, never together.** c's commit lands before d
starts, so d's own gate (`simplify-lane.md` substep 1) sees a clean tree again
and its commit holds only `/simplify`'s hunks. Each step gets its own commit so
a bad one reverts alone. `<scope>` is derived exactly as in `simplify-lane.md`
(top-level dirs of the staged paths, joined with `+`).

**e — the push** is `simplify-lane.md`'s "The commit, the push, and the stale
label" block, run **once** after c and d. A failed push exits 1 before any
reviewer lane is dispatched (#77 AC-7); the commits stay local.

## c, SELF=claude — `/code-review high --fix` as a child CLI

`Skill(code-review, ...)` is refused (`disable-model-invocation`, see
`constraints.md`), so the built-in runs in a **separate** `claude -p` process,
where a slash command in the prompt takes the user-input path. AC-1 spike
(#77 comment): `claude -p "/code-review high --fix main" --permission-mode
acceptEdits` ran the review, printed 4 findings, edited the tree for 3, did not
commit, rc 0, inside `timeout 580` — D-3 path 1 adopted.

Run it in one Bash call with a 600000 ms tool timeout:

```sh
_base=$(GH_HOST="$TARGET_HOST" gh pr view "$pr" -R "$TARGET_REPO" --json baseRefName -q .baseRefName)
# Outside the worktree: in the spike, out.txt/err.txt in cwd were swept into `git add -A`.
_out=$(mktemp "${TMPDIR:-/tmp}/review-all-selffix.$pr.out.XXXXXX")
_err=$(mktemp "${TMPDIR:-/tmp}/review-all-selffix.$pr.err.XXXXXX")
_rc=0
if ! command -v claude >/dev/null 2>&1; then
    _rc=127; echo "claude CLI not found" >"$_err"
elif command -v timeout >/dev/null 2>&1; then
    timeout 580 claude -p "/code-review high --fix ${_base:-main}" --permission-mode acceptEdits \
        </dev/null >"$_out" 2>"$_err" || _rc=$?
else    # stock macOS has no timeout: run unbounded, same as _gh_pr_review_timeout
    claude -p "/code-review high --fix ${_base:-main}" --permission-mode acceptEdits \
        </dev/null >"$_out" 2>"$_err" || _rc=$?
fi
if [ -n "$(git status --porcelain)" ]; then
    _scope=$(git status --porcelain | awk '{print $2}' | cut -d/ -f1 | sort -u | paste -sd+ -)
    git add -A && git commit -m "fix(${_scope:-review-all}): apply self-review findings (claude)" || exit 1
    SELF_FIX=fixed
else
    SELF_FIX=clean
fi
if [ "$_rc" -ne 0 ]; then
    [ "$_rc" -eq 124 ] && _why="timeout 580s" ||
        _why=$(sed -n '/[^[:space:]]/{s/[[:space:]][[:space:]]*/ /g;p;q;}' "$_err" | cut -c1-80)
    SELF_FIX="skip(${_why:-exit $_rc})"
fi
echo "SELF_FIX=$SELF_FIX"; tail -n 40 "$_out"; rm -f "$_out" "$_err"
```

- **Abnormal exit or timeout** → `self:claude:skip(<reason>)`. Edits it already
  made are **kept and committed** — the child was the only writer, so they have
  one known author (#77 Error Cases).
- **Runtime fallbacks (D-3).** If the child reports findings but edits nothing,
  apply them with one edit-only
  Agent under the `simplify-lane.md` scope contract (path 2). If the slash
  command itself is rejected, run the in-session path below as claude and
  report `self:claude:fixed(fallback)` (path 3). Neither is the default.
- The child inherits the calling shell's `CLAUDE_CONFIG_DIR`, so it bills the
  same account; it is a separate process, so there is no recursion into this
  session.

## c, SELF ∈ {codex, opencode, agy, hermes} — in-session review

No Agent, no child CLI: the running harness does the review itself (D-7).

1. Read `gh pr diff <pr> -R <TARGET_REPO>`.
2. Review it against `gh-pr:review`'s `references/review-presets.md`: the
   common prefix plus the `thorough` preset body (the runtime copy is
   `_gh_pr_review_common_prefix` in `shell-common/functions/gh_pr_review.sh`).
3. Fix only the findings you judge valid, **edit-only** — the scope contract
   blockquote in `simplify-lane.md` applies to you verbatim: no `git commit`,
   `revert`, `reset`, `checkout --`, `restore`, `stash`, `push`, `rebase`,
   `cherry-pick`.
4. The orchestrator then runs the commit half of the block above with
   `(<SELF>)` in the message. Edits → `SELF_FIX=fixed`; none → `SELF_FIX=clean`.

`/simplify` is a Claude Code built-in, so d is `SIMPLIFY=n/a` here (D-9).

## Outcomes

| `$SELF_FIX` | Meaning |
|---|---|
| `fixed` | findings fixed, commit made (pushed in e) |
| `fixed(fallback)` | `SELF=claude` took D-3 path 3 |
| `clean` | review ran, nothing to change |
| `skip(<reason>)` | dirty tree, unidentified harness, missing CLI, timeout, non-zero exit |

Step 6 prints it as `self:<SELF>:<value>`. A self-fix skip is soft: the fan-out
still runs and it never downgrades the report to `[WARN]` on its own.
