# post-merge-verify — Step 1: the watched-repos registry gate (F-1)

This skill acts on **registered repos only**. The gate below is what decides
that, and it runs before anything else — no git call, no herdr call.

## The block

```bash
WATCHED_FILE="${IW_WATCHED_REPOS:-${HOME}/.agent-factory/avatars/issue-watcher/watched-repos.json}"
VERIFY_SKILL=""
if command -v jq >/dev/null 2>&1 && [ -r "$WATCHED_FILE" ]; then
    VERIFY_SKILL=$(jq -r --arg r "$TARGET_REPO" \
        '(if type == "array" then . else (.repos // []) end) | .[] | select(.repo == $r) | .verify_skill // empty' "$WATCHED_FILE" 2>/dev/null)
fi
```

The `if type == "array"` branch accepts both shapes the registry has shipped
with: a bare top-level array, and an object with a `repos` key.

## Outcomes

| Condition | Behaviour |
|---|---|
| Empty `VERIFY_SKILL`, unreadable file, or no `jq` | **do nothing at all**, no output |
| `command -v herdr` missing | silent no-op |
| `jq` non-zero (file exists but is not JSON) | one `[WARN]`, then skip |
| `VERIFY_SKILL` outside the allowlist | one `[WARN]`, stop before any herdr call |

The allowlist is exactly `gh-verify:merged` and `gh-verify:live`.

**Why the allowlist is not free text.** `VERIFY_SKILL` reaches the prompt of an
agent started with `--dangerously-skip-permissions`. An unvalidated value there
is an injection point into a session that will not ask before acting, so the
value is compared against a fixed pair of names rather than pattern-matched.

**Why "do nothing at all" is silent.** An unwatched repo must behave exactly as
it did before dEitY719/dotfiles#1511 added this dispatch — including printing
nothing. A `[SKIP]` line for every unwatched repo would be new output in every
`gh-pr:merge` run in every repo, which is a behaviour change dressed up as
information.

Schema and registration procedure: `references/watched-repos-schema.md`.
