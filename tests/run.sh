#!/bin/bash

set -euo pipefail

# Single entry point for this repo's self-checks. CI runs it automatically:
# harness-skills' reusable skill-check.yml executes `tests/run.sh` when the
# repo tracks one. Shared checks stay there; only rules that are this repo's
# own belong here.

cd -- "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# The shared `max-skill-lines` gate (100) is a proxy for progressive
# disclosure: a SKILL.md a reader can hold in their head. Counting lines alone
# lets a file satisfy the proxy horizontally — `review-all/SKILL.md` passed at
# 99 lines while carrying 421-, 404- and 397-character ones
# (dEitY719/gh-verify-skills#34), which is the same detail the limit exists to
# push into references/, just rotated 90 degrees. A word change also rewrites
# the whole line, so those diffs are unreviewable. Measure the other axis too.
#
# 120 characters, counted as characters and not bytes — four of the five
# SKILL.md files here end on a Korean "Related Skills" line, and in UTF-8 that
# is three bytes per character.
MAX_SKILL_LINE_LENGTH="${MAX_SKILL_LINE_LENGTH:-120}" python3 - <<'PY'
import os
import pathlib
import sys

limit = int(os.environ["MAX_SKILL_LINE_LENGTH"])
fail = 0
for md in sorted(pathlib.Path("skills").glob("*/SKILL.md")):
    lines = md.read_text(encoding="utf-8").splitlines()
    over = [(n, len(text)) for n, text in enumerate(lines, 1) if len(text) > limit]
    for n, width in over:
        print(f"FAIL  {md}:{n}: {width} characters > {limit} — wrap it, or move the detail into references/")
    if over:
        fail = 1
    else:
        widest = max((len(text) for text in lines), default=0)
        print(f"ok    {md} (longest line {widest})")
sys.exit(fail)
PY

# skills/post-merge-verify/references/dispatch.sh.md ships ~470 lines of bash
# as a markdown fence that `gh-pr:merge` extracts and sources. It is checked
# here rather than beside the skill because CI runs this file and nothing else
# once it exists (dEitY719/gh-verify-skills#39).
bash tests/dispatch-fence.sh
