# Installing gh-verify for OpenCode

## Prerequisites

- [OpenCode.ai](https://opencode.ai) installed
- The GitHub CLI (`gh`) authenticated for the host your remote points at

## Installation

Add the plugin to the `plugin` array in your `opencode.json` (global or
project-level):

```json
{
  "plugin": ["gh-verify-skills@git+https://github.com/dEitY719/gh-verify-skills.git"]
}
```

Restart OpenCode. The plugin installs through OpenCode's plugin manager and
registers all five skills.

OpenCode uses its own plugin install. If you also use Claude Code, Codex, or
another harness, install this plugin separately for each one.

## Usage

Use OpenCode's native `skill` tool:

```
use skill tool to list skills
use skill tool to load review-all
```

## Tool mapping

The authoritative OpenCode tool mapping for every `dEitY719/*-skills` repo is
owned by the sibling repo
[`dEitY719/harness-skills`](https://github.com/dEitY719/harness-skills/blob/main/references/opencode-tools.md)
(dotfiles #1410 F-5). Read it there when a skill names a tool you do not
recognise; this repo keeps no copy on purpose. Short version:

- "Read a file" -> `read`
- "Create a file" / "edit a file" -> `apply_patch`
- "Run a shell command" -> `bash`
- "Search file contents" / "find files by name" -> `grep`, `glob`
- "Create a todo" -> `todowrite`
- "Invoke a skill" -> OpenCode's native `skill` tool
- "Dispatch a subagent" -> OpenCode has no parallel subagent primitive.
  `review-all` Step 3 wants five reviewer lanes dispatched in one turn; run
  them sequentially and say so in the report. A serialised fan-out is slower
  but still correct — a fan-out silently reduced to one lane is not.
- "Ask the user" -> OpenCode has no dedicated ask tool; stop and ask in your
  reply, then wait. `live` and `merged` both need a real answer when the base
  URL, API origin, or claim list cannot be resolved.

## Capability notes

- Every skill here shells out to `gh` and `git`. Pin the host from the remote
  URL rather than assuming `github.com`.
- `live` needs a browser driver. Without one it degrades to the reduced check
  set its `references/driver.md` describes and must report the degradation.
- `post-merge-verify` drives the `herdr` CLI. With no `herdr` on PATH it is a
  silent no-op; that is the intended behaviour, not a bug to route around.
- Several skills source shell helpers from the upstream dotfiles checkout
  (`${SHELL_COMMON}/functions/*.sh`). Those are not vendored here.

## Troubleshooting

### Plugin not loading

1. Check logs: `opencode run --print-logs "hello" 2>&1 | grep -i gh-verify`
2. Verify the plugin line in your `opencode.json`
3. Make sure you are running a recent version of OpenCode

### Skills not found

1. Use the `skill` tool to list what was discovered
2. Check that the plugin is loading (see above)

## Getting Help

Report issues: https://github.com/dEitY719/gh-verify-skills/issues
