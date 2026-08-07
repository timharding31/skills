# skills

My personal [Claude Code](https://claude.com/claude-code) setup: custom skills and scripts, plus my global `CLAUDE.md`.

## Contents

- `skills/` — custom Claude Code skills
- `scripts/` — supporting scripts used by skills or hooks
- `CLAUDE.md` — global instructions loaded into every session

Only these paths are tracked; everything else in `~/.claude` (sessions, caches, local settings, credentials, etc.) is intentionally excluded.

## Core workflow: `/grill-me` → `/to-spec` → `/to-issues` → `loop.sh`

This is the backbone of how I take an idea to shipped, agent-implemented code.

1. **[`/grill-me`](skills/grill-me)** — Interview me relentlessly about a plan or design until we reach shared understanding. Walks each branch of the decision tree one question at a time, proposing a recommended answer, and explores the codebase instead of asking when the answer is discoverable there. Use this to stress-test an idea before any spec gets written.

2. **[`/to-spec`](skills/to-spec)** — Turns the resulting conversation (or a rough request, or a pile of research) into a structured `spec.json`: the durable context for one effort. Captures `summary`, `invariants`, `out_of_scope`, and `verification` — the fields re-injected into every future iteration — plus free-form `context` for everything else. Deliberately stops short of writing issues.

3. **[`/to-issues`](skills/to-issues)** — Decomposes that `spec.json` into an ordered, dependency-aware `issues` array, each a thin vertical slice ("tracer bullet") with its own prose body under `issues/<id>.md`. Ordering encodes both dependency and risk — the issue that proves the riskiest assumption goes first.

4. **[`scripts/loop.sh`](scripts/loop.sh)** — Executes the effort one issue per iteration, each in a **fresh context window** containing only the spec's invariants/summary/out-of-scope, the growing `ledger`, and that one issue's details. The script — not the model — picks the next issue: the first whose `blocked_by` are all satisfied.

```
/grill-me  →  shared understanding of the plan
/to-spec   →  <dir>/<slug>/spec.json        (summary, invariants, verification)
/to-issues →  <dir>/<slug>/issues/*.md      (ordered, dependency-aware slices)
loop.sh    →  implements one issue per fresh-context iteration
```

The design principle underneath all four steps: later stages, and later loop iterations, only see what's explicitly carried forward (spec fields, ledger, one issue). Nothing relies on conversational memory that won't be there.
