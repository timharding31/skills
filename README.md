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

2. **[`/to-spec`](skills/to-spec)** — Turns the resulting conversation (or a rough request, or a pile of research) into a structured `spec.json`: the durable context for one effort. Captures `summary`, `invariants`, `out_of_scope`, and `verification` — the fields re-injected into every future iteration — and writes long-form background (research, provenance, rejected alternatives) to a sibling `context.md` that a loop iteration can read on demand instead of carrying in full. Deliberately stops short of writing issues.

3. **[`/to-issues`](skills/to-issues)** — Decomposes that `spec.json` into an ordered, dependency-aware `issues` array, each a thin vertical slice ("tracer bullet") with its own prose body under `issues/<id>.md`. Ordering encodes both dependency and risk — the issue that proves the riskiest assumption goes first.

4. **[`scripts/loop.sh`](scripts/loop.sh)** — Executes the effort one issue per iteration, each in a **fresh context window** containing only the spec's invariants/summary/out-of-scope, the growing `ledger`, the tail of an effort-wide `NOTES.md`, and that one issue's details, plus pointers to `context.md` and any earlier attempt logs to read only if needed. The script — not the model — picks the next issue: the first whose `blocked_by` are all satisfied.

```
/grill-me  →  shared understanding of the plan
/to-spec   →  <dir>/<slug>/spec.json        (summary, invariants, verification)
/to-issues →  <dir>/<slug>/issues/*.md      (ordered, dependency-aware slices + a final quality review)
loop.sh    →  implements one issue per fresh-context iteration
```

The design principle underneath all four steps: context is split three ways. Injected into every iteration: `summary`, `invariants`, `out_of_scope`, `verification`, the `ledger`, and the tail of `NOTES.md`. Available on demand, read only if an iteration needs it: `context.md`'s background and the `attempts/*.log` files. Read once, by humans and by `/to-issues`: `open_questions`. Nothing relies on conversational memory that won't be there.

`NOTES.md` and an issue's `## Comments` carry different scopes of note. `NOTES.md` is effort-wide and append-only — any iteration can leave a one-line discovery (a build quirk, a required env var, a pattern to follow) and its tail is injected into every iteration after. `## Comments` stays seam-level, written by the issue that finished and read only by that issue's direct blockers.

### What the loop enforces

The agent implements. Everything else is the script's job, so a confused or crashed iteration can't corrupt the plan:

- **`spec.json` is off-limits to the agent.** Status, the ledger, and the attempt record are written by `loop.sh` alone.
- **A DONE promise is a claim, not a completion — and it has to clear three gates.** After the agent reports done, the loop runs the spec's `verification` commands itself; they must all exit 0. Then the iteration must have committed something: an unchanged HEAD is a failed attempt, not a warning, since there is no diff to review and nothing traceable for the ledger. Then a clean-context criteria review — a second, independent `claude` call (`JUDGE_MODEL`, default haiku; set it to empty to disable) that never saw the implementation — judges the iteration's git diff against the issue's `criteria` and the effort's `invariants`, and can still reject the DONE. A promise made over failing tests, or a diff that doesn't evidence its own criteria, marks nothing.
- **Failures are remembered across the context reset, with the receipts to back them up.** A failed verification run saves its full output to `<spec-dir>/attempts/<issue-id>-<n>.log`; the next attempt's prompt is pointed at those logs rather than repeating them, and if the working tree is already dirty it says so — most likely the previous failed attempt's leftovers — instead of leaving the agent to guess. These recorded failures don't count against the run's stall guard, which exists only to catch iterations that produce nothing actionable at all; a specific issue failing repeatedly is instead governed by `ISSUE_ATTEMPT_LIMIT`. Once an issue hits that limit the loop circuit-breaks and points at the fix: `/to-issues <spec-dir> --replan <issue-id>`, which rewrites or splits the stuck issue from its attempt record and clears its attempts.
- **Iterations are traceable.** Each completed issue records the commit it produced. When a run stops early, the loop reports what actually landed and prints the `git reset` needed to undo it — it never reverts anything itself.

### Why one issue at a time

`loop.sh` computes the full frontier of unblocked issues and then deliberately works only the first. Running the rest concurrently would be easy — the dependency graph is right there — and it isn't done on purpose.

Agents working in parallel each make implicit decisions the others can't see: what to name things, where to put the seam, how errors surface, which of two plausible shapes an interface takes. Those choices never appear in any ticket, so nothing catches them until the branches meet. The cheap version of that failure is a merge conflict. The expensive version is two halves that both work alone and disagree about the thing they share.

Serial execution plus the ledger means every issue is built against what actually exists rather than against a sibling's guess about it. Wall-clock time is the thing being traded away, and it's the cheapest thing in the pipeline.
