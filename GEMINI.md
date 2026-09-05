# gh-verify — skill index

Five skills that gate a pull request before and after it merges. Each lives in
this extension's `skills/` directory. They are task-triggered: load the one that
matches the job by reading its `SKILL.md`, then follow it. Do not load all five.

| Skill | Read | Use when |
|-------|------|----------|
| `review-all` | `@./skills/review-all/SKILL.md` | Running every available reviewer over one PR at once, recording the aggregate verdict as a merge-gate label, and handing off to the reply pass. |
| `live` | `@./skills/live/SKILL.md` | An app is already running and you need to prove the checkout it serves really is the target commit, then drive the PR's claims through the browser. |
| `merged` | `@./skills/merged/SKILL.md` | There is no app to serve and the proof must come from a fresh clone of the merge commit — shell, CLI, and library repos. |
| `exception-merge-checklist` | `@./skills/exception-merge-checklist/SKILL.md` | A ten-point read-only audit immediately before an exception-track hand-merge. |
| `post-merge-verify` | `@./skills/post-merge-verify/SKILL.md` | Closing the implementation tab, rebasing main, and opening the verification session for a repo in the watched-repos registry. |

Each skill's `references/` directory holds the detail it loads on demand;
`SKILL.md` says which file to read and when. Do not read `references/` files up
front.

## Picking between them

The discriminator is **when in the PR's life** you are standing:

- Before the merge: `review-all` (fan out the reviewers), then
  `exception-merge-checklist` when the PR is going in by hand.
- At the merge: `post-merge-verify` is a dispatcher, not a verifier — it opens
  the session that runs one of the two below.
- After the merge: `live` if something is already serving the code, `merged` if
  nothing is. They are sister skills covering the same slot with different
  proofs (live = the serving checkout's identity, merged = a fresh clone's).

`review-all` is the only one that can write to your branch, and only through
the `/simplify` auto-fix pass it runs.

## Tool mapping for Gemini CLI

The skills speak in actions. On Gemini CLI these resolve to:

- "Read a file" -> `read_file` / `read_many_files`
- "Create a file" / "edit a file" -> `write_file`, `replace`
- "Run a shell command" -> `run_shell_command`
- "Search file contents" -> `grep_search`
- "Find files by name" -> `glob`
- "Create a todo" -> `write_todos`
- "Ask the user" -> `ask_user`
- "Dispatch a subagent" -> `invoke_agent` with `agent_name: "generalist"`

The full mapping, including every capability gap and its workaround, is owned by
the sibling repo `dEitY719/harness-skills` at `references/gemini-tools.md`
(dotfiles #1410 F-5) — read it there; this repo keeps no copy. On Antigravity
read that repo's `references/antigravity-tools.md` instead: `agy` shares
`~/.gemini` but not Gemini CLI's tool names.

## Capability gaps on Gemini CLI

- **`review-all`'s parallel fan-out is the load-bearing part.** Step 3
  dispatches five lanes in a single turn: four reviewer lanes plus a
  `/simplify` auto-fix pass. Serialising them is acceptable and slower; quietly
  running fewer lanes than the report claims is not. Step 3.5 then aggregates
  the verdicts, and a lane that contributed nothing must not be counted.
- `review-all` invokes other harnesses by name (`agy`, `codex`, `opencode`,
  `hermes`). Each lane is soft-fail: a missing binary is a `SKIP`, never an
  abort.
- `live` needs a browser driver. Without one it drops to the reduced check set
  in `references/driver.md` and must say so in the report.
- `post-merge-verify` drives the `herdr` CLI. No `herdr` on PATH means a silent
  no-op, which is correct.
- Several skills source shell helpers from the upstream dotfiles checkout
  (`${SHELL_COMMON}/functions/*.sh`). They are not vendored here; on a machine
  without that checkout, follow the prose steps rather than improvising a
  replacement.

## Safety rules

- **Source code is read-only.** `live` and `merged` never fix what they find —
  findings leave as new issues through `gh-issue:create`, one finding per issue.
- **Never report a pass you did not measure.** Both verifiers stop before
  measuring if their pre-verification assertions fail, and both list what they
  could not reach (`Unverified:`, `Unproven:`) rather than omitting it.
- **Self-refutation before filing.** A candidate finding is argued against
  first — harness error, data state, intended behaviour — and only survivors
  become issues.
- **No approve, no merge.** `review-all` labels and replies; it never approves.
  `exception-merge-checklist` is read-only and stops at `git add` even under
  `--auto-fix`.
