# gh-verify-skills — Contributor Guidelines

This file is the AI context document for this repo. `AGENTS.md` is a symlink to
it, so Claude Code, Codex, Gemini CLI, and every other harness read the same
text. Edit `CLAUDE.md`; never replace the symlink with a second copy.

## What this repo is

A single-plugin skill marketplace. The plugin is named `gh-verify` and it
bundles the five skills that stand between a pull request and a trusted merge:

| Skill | Role |
|-------|------|
| `review-all` | Fans every available reviewer out over one PR in parallel, aggregates the verdicts into a merge-gate label, then runs the reply pass. |
| `live` | Proves the already-running app is serving the target commit, then drives the PR's claims through the browser. |
| `merged` | The same job for repos with nothing to serve: re-runs the checks inside a fresh clone of the merge commit. |
| `exception-merge-checklist` | A ten-point read-only audit run immediately before an exception-track hand-merge. |
| `post-merge-verify` | Dispatch only: closes the implementation tab, rebases main, opens the session that runs `live` or `merged`. |

The skills were extracted from `dEitY719/dotfiles`
(`claude/skills/{devx-pr-review-all,devx-pr-verify-live,devx-pr-verify-merged,devx-exception-merge-checklist,gh-pr-post-merge-verify}`)
as a snapshot — see the first commit for the source SHA. The dotfiles copies
remain in place for now; they are removed in a later phase of that repo's
migration plan (dEitY719/dotfiles#1410 Phase 4).

## Layout: root manifests, one flat `skills/`

This repo deliberately does **not** use the nested `plugins/<name>/skills/`
"mono" layout. Every harness manifest sits at the repo root and points at a
single flat `./skills/` directory:

```
.claude-plugin/{marketplace,plugin}.json   Claude Code
.codex-plugin/plugin.json                  Codex
.kimi-plugin/plugin.json                   Kimi CLI
.hermes-plugin/{plugin.yaml,__init__.py}   Hermes Agent
.opencode/plugins/gh-verify.js             OpenCode
.agents/plugins/marketplace.json           Antigravity
gemini-extension.json + GEMINI.md          Gemini CLI
skills/<name>/SKILL.md                     the skills themselves
```

Only Claude Code understands the nested mono layout. The other five harnesses
resolve manifests at the repo root and a skills tree at `./skills/`, so nesting
would silently cut this plugin down to Claude-Code-only. **Do not move the
manifests under a `plugins/` directory.**

## Shared assets live in `harness-skills` — link, never copy

Two things this repo depends on are owned by `dEitY719/harness-skills`
(dotfiles #1410 F-5 / D-10):

1. **Per-harness tool mappings** — `references/{codex,kimi,gemini,antigravity,hermes,opencode}-tools.md`.
   This repo carries no `references/` tree of its own; `GEMINI.md`,
   `.opencode/INSTALL.md`, and `.kimi-plugin/plugin.json` link there instead.
   If you are about to paste one in, stop and add a link — one tool rename must
   stay one edit, not fifteen (NF-2).
2. **The CI workflow** — `.github/workflows/skill-check.yml`. This repo's
   `validate.yml` calls it with `plugin-name: gh-verify`. Do not re-inline the
   checks here; to change what is checked, open a PR against `harness-skills`.

## Rules for changing skills

- **Skill directory name is the identity.** `skills/<name>/` must match the
  `name:` field in that skill's `SKILL.md` frontmatter, and that field is the
  **bare** name (`review-all`), never namespaced (`gh-verify:review-all`). The
  harness supplies the `gh-verify:` prefix at invocation time.
- **Invocation form in prose is namespaced.** Body text referring to a skill as
  a command writes `/gh-verify:review-all`.
- **The pre-rename trigger phrases stay in the descriptions.** Every
  description still lists its dotfiles-era forms (`/devx:pr-verify-live`,
  `/gh-pr-post-merge-verify`, ...) alongside the new one, because muscle memory
  outlives a migration. Removing them is a regression, not a cleanup.
- **Progressive disclosure.** `SKILL.md` should stay under 100 lines and name
  which `references/` file to read and when. Detail lives in that skill's own
  `references/`. Do not inline a reference file back into `SKILL.md`. See
  "Migration debt" below for why CI's limit is currently higher than 100.
- **Description budget.** CI sums every skill description and fails past 5,440
  characters — Codex's context budget. Keep new descriptions tight.
- **`review-all`'s parallel fan-out is behaviour, not formatting.** Step 3
  dispatches five lanes — agy, codex, opencode, hermes, and a `/simplify`
  auto-fix pass — **in one turn**, and Step 3.5 aggregates their verdicts only
  after every lane has returned and before Step 4 pushes. Both the parallelism
  and that ordering are load-bearing (dEitY719/dotfiles#1613,
  dEitY719/dotfiles#1636, PR dEitY719/dotfiles#1598); a rewrite that serialises
  the lanes or reorders those steps changes what the merge gate certifies.
- **Honour each skill's safety contract.** `live` and `merged` are read-only on
  source: findings leave as new issues via `gh-issue:create`, never as edits.
  `exception-merge-checklist` mutates only as far as `git add` under
  `--auto-fix` and never commits. `post-merge-verify` never writes to GitHub.
  `review-all` never approves.
- **Never report a pass you did not measure.** Both verifiers stop before
  measuring when a pre-verification assertion fails, and both surface what they
  could not reach. A step that lets a skill fabricate coverage instead of
  failing is a bug, not a convenience.

## References to skills that live elsewhere

These five skills name skills that are **not** in this repo — `gh-pr:reply`,
`gh-pr:merge`, `gh-pr:merge-train`, `gh-issue:create`, `gh-flow:issue`,
`gh-pr:review`, `gh-setup:label-bootstrap`, `/simplify`, `/code-review`. All
sixteen sibling repos exist, so **write each one in its own repo's namespace**
— the spelling above, taken from that repo's `.claude-plugin/plugin.json`
`name` plus its `skills/<dir>/`. There is no grace path: the siblings kept no
dotfiles-era aliases of their own, so a stale `gh:`/`devx:` name resolves to
nothing and simply fails. The exception is this repo's own pre-rename trigger
phrases inside a `description:` — see "Rules for changing skills" above.

Paths under `claude/skills/`, `shell-common/functions/`, and
`tests/bats/` — those point into `dEitY719/dotfiles` and are labelled as such.
Only paths **inside** this repo were rewritten by the migration.

## Migration debt: the SKILL.md line limit

CI's `max-skill-lines` is set to **215** in `validate.yml`, not the standard
100. Four of the five skills arrived from dotfiles already over the limit —
`review-all` 213, `merged` 112, `live` 111, `post-merge-verify` 111
(`exception-merge-checklist` is at 100). Phase 2 of dEitY719/dotfiles#1410 is a
placement-and-naming migration and its NF-4 forbids changing skill behaviour on
the way across, so the content was copied verbatim and the limit raised rather
than the files being cut down.

This is debt, not a new standard, and it is tracked as #1: refactor each
`SKILL.md` into its own `references/` and bring the limit back to 100. Until
then: do not raise 215 any further, and do not add lines to a `SKILL.md` that is
already over 100.

## Emojis

Not in prose, manifests, or workflow files — token efficiency, same rule as the
upstream dotfiles repo. **One exception:**
`skills/exception-merge-checklist/references/metrics-footer.md` contains the
emoji glyphs of the dotfiles ai-metrics PR footer. That footer is the single
SSOT-approved emoji exception upstream (#317 F-2, PR #320, #367), and a
reference file that specifies the footer's exact output has to show the real
glyphs. `lib/vendor/` is exempt for the same reason one level down:
`shell-common/functions/gh_pr_review.sh` prints that footer, so its verbatim
upstream copy carries the glyphs too, and that tree is replaced wholesale by
dotfiles' own `scripts/sync-shell-common-vendor.sh` — which lives upstream, not
in this repo — rather than edited here. `.shellcheckrc` exists for the same
reason: upstream is shellcheck-clean because the dotfiles repo root carries
one, and a vendored copy inherits the code but not the config. CI's emoji gate is passed both
prefixes in `allow-emoji-paths` for exactly those reasons. Do not widen the
allowlist further; do not add emoji anywhere else.

## Version bumps

The version appears in seven manifests: `.claude-plugin/marketplace.json`,
`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`,
`.kimi-plugin/plugin.json`, `.hermes-plugin/plugin.yaml`,
`gemini-extension.json`, and `package.json`. CI checks that they agree — bump
all of them together. Versioning is independent per repo (dEitY719/dotfiles#1410 D-9); this repo
does not move in lockstep with its siblings.
