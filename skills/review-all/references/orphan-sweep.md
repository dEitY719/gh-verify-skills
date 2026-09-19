# Step 3.4: orphan sweep — a lane that returned is not a lane that finished (dEitY719/gh-verify-skills#42)

An Agent lane returning only proves the Agent itself returned. Its own
children — a nested sub-agent, a backgrounded shell command — can still be
running, and nothing downstream waits on them. Step 3.4 looks for them once,
after every lane is back and before Step 3.5, and **reports** what it finds.

## The incident

`dEitY719/brokerdesk` PR #78, `gh-flow:issue 77` → Step 2.4
`gh-verify:review-all 78 origin --defer-reply 4`. The `/simplify` lane fanned
out its own review sub-agents; one ran a benchmark whose first command was a
**bare** `.venv/bin/python` — no script, no `-c`, no stdin redirect. Python
opened an interactive REPL and blocked on the stdin the Bash tool leaves open.
The lane still returned and committed its cleanup, and review-all went on to
report `simplify:committed`. The orphan (cwd = the PR worktree) ran for
**1 h 04 min**; the nested sub-agent's completion notice arrived 65 min late
with exit 144. The user found it by hand. The hang's own root cause is fixed
upstream by a PreToolUse hook (`dEitY719/dotfiles#1815`); this sweep exists
because any lane can leak work, and the orchestrator is the only place that
knows when the lanes were supposed to be done.

## Window

- **`LANES_START_TS`** — `date +%s`, recorded immediately before Step 2.5
  substep 2 dispatches the `/simplify` Agent. The incident's leaker was the
  simplify lane, which since #18 runs before Step 3, so a timestamp taken at
  Step 3 would miss the exact case this sweep exists for. Shell state does not
  survive between Bash calls: print the value and carry it as a literal, the
  same as `pr` and `START_TS`. If Step 2.5 skipped at its clean-tree gate,
  record it before the Step 3 dispatch instead.
- **Match** — a process whose cwd is the PR worktree (or below it) **and**
  that started at or after `LANES_START_TS`. That was the narrowest filter
  that caught the incident process without also catching a dev server the user
  started earlier. Both sides are compared as physical paths (`pwd -P` against
  the kernel-resolved `/proc/<pid>/cwd`), so a symlinked worktree still matches.
- **Excluded** — the sweep's own shell, its ancestors (the harness wrappers
  that spawned it) and its descendants (the `ps`/`awk`/`readlink` it runs).

## WARN, never kill (NF-2)

The worktree may legitimately host something the user started after the lanes
began — a dev server (`python3 -m web` from `run-web.sh`), a watcher. The sweep
cannot tell that from a leak, so it names the processes and stops there. The
user decides.

## Soft-fail (NF-1)

No `/proc` (macOS), no `etimes` column, a `ps` or permission error, a process
that exits mid-sweep: each skips silently. The sweep never blocks Steps 3.5-6
and, on a clean run, prints nothing — output is identical to a run without it.

## Runnable block

Substitute the literal `LANES_START_TS` recorded above; run from the PR worktree.

```bash
LANES_START_TS=<literal>
ORPHANS=0
if [ -d /proc/self ] && _wt=$(cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null && pwd -P); then
    _win=$(( $(date +%s) - LANES_START_TS ))
    # One ps snapshot. awk drops this shell, its ancestors and its descendants,
    # and keeps what started inside the window (etimes <= seconds since start).
    _hits=$(ps -eo pid=,ppid=,etimes= 2>/dev/null | awk -v self="$$" -v win="$_win" '
        { pp[$1] = $2; et[$1] = $3 }
        END {
            for (p = self; (p in pp) && p > 1; p = pp[p]) skip[p] = 1
            for (q in pp) {
                if ((q in skip) || et[q] > win) continue
                for (a = pp[q]; (a in pp) && a > 1 && a != self; a = pp[a]) ;
                if (a != self) print q
            }
        }' | while read -r _pid; do
            _cwd=$(readlink "/proc/$_pid/cwd" 2>/dev/null) || continue
            case "$_cwd/" in "$_wt"/*) printf '%s\n' "$_pid" ;; esac
        done)
    ORPHANS=$(printf '%s' "$_hits" | grep -c .)
    if [ "$ORPHANS" -gt 0 ]; then
        _list=$(ps -o pid=,etime=,args= -p "$(printf '%s\n' "$_hits" | head -3 | paste -sd, -)" 2>/dev/null \
            | sed 's/^ *//; s/  */ /g' | cut -c1-80 | paste -sd';' - | sed 's/;/; /g')
        printf '[WARN] lane left %s process(es) running: %s\n' "$ORPHANS" "$_list"
    fi
fi
```

Carry `ORPHANS` to Step 6 — it is the `<n>` in the `[WARN]` line, or 0 when the block printed nothing. When it is above zero, Step 6 appends
`orphans:<n>` after the lane rows and the line is `[WARN]`; at zero, Step 6 is
unchanged.
