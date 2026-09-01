# gh-verify-skills

Five skills that stand between a pull request and a trusted merge — the
parallel reviewer fan-out, the two verifiers that prove a claim instead of
repeating it, the pre-merge audit, and the post-merge dispatcher. Packaged as a
single plugin named `gh-verify`, installable on six coding-agent harnesses.

The thread running through all of them: **never report a pass you did not
measure.** Each one names what it could not reach rather than quietly leaving it
out.

## Skills

| Skill | Invoke | What it does |
|-------|--------|--------------|
| `review-all` | `/gh-verify:review-all <PR#> [remote] [--defer-reply M] [--no-reply] [--force-review]` | Dispatches agy, codex, opencode, hermes and a `/simplify` auto-fix pass over one PR **in a single turn**, aggregates their verdicts into the `review-blocked` merge-gate label, pushes the auto-fix commit, then replies inline or on a delay. Never approves. |
| `live` | `/gh-verify:live [<PR#>] [remote] [--url U] [--matrix full] [--dry-run]` | Attaches to the app you already have running, proves the process really is serving the PR's merge commit, then drives the PR's claims through the browser with machine-readable assertions. Findings that survive self-refutation become issues. |
| `merged` | `/gh-verify:merged [<PR#>] [remote] [--matrix full] [--no-diff-check]` | For repos with nothing to serve: clones the merge commit into a temp dir and re-runs the checks there, so a dirty worktree cannot fake a pass. Compares which test cases actually exist in the clone versus your tree. |
| `exception-merge-checklist` | `/gh-verify:exception-merge-checklist [<PR#>] [--skip-bisect] [--auto-fix]` | Ten read-only checks right before an exception-track hand-merge — broken rebase intermediates, lock drift, YAML damage, over-broad formatter writes, missing test mocks. `--auto-fix` stages, never commits. |
| `post-merge-verify` | `/gh-verify:post-merge-verify <PR#> [remote]` | Dispatch only: closes the tab that implemented the PR, rebases main, and opens a fresh session running `live` or `merged` per the watched-repos registry. Verifies nothing itself. |

### Picking between them

The discriminator is **where in the PR's life you are standing**:

| Before the merge | At the merge | After the merge |
|---|---|---|
| `review-all` — fan out the reviewers, set the gate label | `post-merge-verify` — dispatch the verification session | `live` — an app is serving the code |
| `exception-merge-checklist` — the hand-merge audit | | `merged` — nothing to serve, use a fresh clone |

`live` and `merged` are sister skills covering the same post-merge slot with
different proofs: `live` proves the **serving checkout's** identity, `merged`
proves a **fresh clone's**. Both also run on an unmerged PR branch.

`review-all` is the only skill here that writes to your branch, and only the
`/simplify` auto-fix commit it runs. Nothing here approves or merges a PR.

## Install

### Claude Code

```
/plugin marketplace add dEitY719/gh-verify-skills
/plugin install gh-verify@gh-verify-skills
```

### Codex

```
codex plugin install dEitY719/gh-verify-skills
```

### Kimi CLI

```
kimi plugin install dEitY719/gh-verify-skills
```

### Hermes Agent

```
hermes plugins install dEitY719/gh-verify-skills
```

### OpenCode

See [`.opencode/INSTALL.md`](.opencode/INSTALL.md).

### Gemini CLI / Antigravity

```
gemini extensions install https://github.com/dEitY719/gh-verify-skills
```

Antigravity (`agy`) shares `~/.gemini`, so it inherits the install.

## Harness support

These skills are written in Claude Code's vocabulary. The per-harness tool
mappings and capability gaps are documented once, in
[`dEitY719/harness-skills/references/`](https://github.com/dEitY719/harness-skills/tree/main/references)
(#1410 F-5); read the one file for the harness you are on.

| Skill | Claude Code | Codex | Kimi | Gemini / Antigravity | Hermes | OpenCode |
|-------|:-----------:|:-----:|:----:|:--------------------:|:------:|:--------:|
| `review-all` | full | partial | partial | partial | partial | partial |
| `live` | full | partial | partial | partial | partial | partial |
| `merged` | full | full | full | full | full | full |
| `exception-merge-checklist` | full | full | full | full | full | full |
| `post-merge-verify` | full | full | full | full | full | full |

What "partial" means:

- **`review-all`** needs a parallel subagent primitive. Its Step 3 dispatches
  five lanes in one turn; a harness without that runs them sequentially, which
  is slower but still correct. What is *not* acceptable is dropping lanes — the
  verdict Step 3.5 records must reflect every lane that actually ran.
- **`live`** needs a browser driver. Its `references/driver.md` defines a
  ladder down to a degraded check set, and the report has to declare which rung
  it reached.
- **`post-merge-verify`** needs the `herdr` CLI. Without it the skill is a
  silent no-op by design, on every harness including Claude Code.

Two more constraints apply everywhere: `gh` must be authenticated for the host
the remote points at, and several skills source shell helpers from the upstream
dotfiles checkout (`${SHELL_COMMON}/functions/*.sh`) that are not vendored here.

## Layout

Manifests live at the repo root and all point at one flat `skills/` directory:

```
.
├── skills/{review-all,live,merged,exception-merge-checklist,post-merge-verify}/
│   ├── SKILL.md
│   ├── references/
│   └── evals/                                (live, merged)
├── .claude-plugin/{marketplace,plugin}.json     Claude Code
├── .codex-plugin/plugin.json                    Codex
├── .kimi-plugin/plugin.json                     Kimi CLI
├── .hermes-plugin/{plugin.yaml,__init__.py}     Hermes Agent
├── .opencode/plugins/gh-verify.js + INSTALL.md  OpenCode
├── .agents/plugins/marketplace.json             Antigravity
├── gemini-extension.json + GEMINI.md            Gemini CLI
├── package.json
├── CLAUDE.md · AGENTS.md -> CLAUDE.md
└── LICENSE
```

Only Claude Code understands a nested `plugins/<name>/skills/` layout. The other
five harnesses resolve manifests at the repo root and a skills tree at
`./skills/`, so this repo keeps everything flat. See [`CLAUDE.md`](CLAUDE.md) for
the full rationale and contribution rules.

The `.kimi-plugin/` manifest is pre-provisioned: Kimi CLI is not installed on the
maintainer's machines yet, and shipping the manifest now costs nothing and saves
a migration later.

## CI

[`.github/workflows/validate.yml`](.github/workflows/validate.yml) calls the
reusable workflow owned by
[`dEitY719/harness-skills`](https://github.com/dEitY719/harness-skills/blob/main/.github/workflows/skill-check.yml)
(#1410 D-10) — manifest parsing, required files, skill frontmatter,
progressive-disclosure line limits, the Codex description budget, version
agreement, shellcheck, and an emoji gate.

There are no checks defined in this repo. To change what is validated here, open
a PR against `harness-skills`; a merge to its `main` ships to all fifteen repos
at once.

Two inputs are tuned for this repo, both documented inline in `validate.yml`:
`max-skill-lines: 215` (migration debt — four SKILL.md files arrived over the
100-line limit and Phase 2 forbids editing them down; see
[`CLAUDE.md`](CLAUDE.md) -> "Migration debt") and `allow-emoji-paths` for the
one reference file that specifies the dotfiles ai-metrics footer.

## Provenance

These skills were extracted from
[`dEitY719/dotfiles`](https://github.com/dEitY719/dotfiles) as a content
snapshot — no history rewriting. The source commit SHA is recorded in this
repo's first commit message.

| dotfiles `claude/skills/` | here |
|---|---|
| `devx-pr-review-all` | `review-all` |
| `devx-pr-verify-live` | `live` |
| `devx-pr-verify-merged` | `merged` |
| `devx-exception-merge-checklist` | `exception-merge-checklist` |
| `gh-pr-post-merge-verify` | `post-merge-verify` |

The `devx-pr-` / `gh-pr-` prefixes are dropped because the plugin namespace
(`gh-verify:`) now supplies them. Every description still lists its old trigger
forms, so `/devx-pr-verify-live` and friends keep working; the dotfiles
originals also stay put until #1410 Phase 4 removes them.

This is part of Phase 2 of the dotfiles #1410 migration; `packaging-skills` was
Phase 0, and `harness-skills` / `notes-skills` are its Phase 1 siblings.

## License

MIT. See [LICENSE](LICENSE).
