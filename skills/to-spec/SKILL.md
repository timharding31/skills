---
name: to-spec
description: Turn a rough request, a design conversation, or a pile of research into a structured spec.json — the durable context for one effort. Use when the user wants to spec out a feature, write a PRD, capture a plan before building, or says "to-spec". Writes context only; /to-issues decomposes it into work.
---

# To Spec

Produce `<dir>/<slug>/spec.json`: everything a fresh agent needs to know about an effort, and nothing it doesn't.

The output is consumed by [`~/.claude/scripts/loop.sh`](../../scripts/loop.sh), which works through the effort one issue per iteration in a **fresh context window each time**. That single fact drives every decision in this skill.

## The contract

Schema: [resources/spec.schema.json](resources/spec.schema.json). Read it before writing.

Fields split three ways: injected into **every** loop iteration, available **on demand** (pointed at from the prompt, read only if needed), or **read once**, by humans and by `/to-issues`. Getting a field on the wrong side of that line is the main way this skill fails.

| Injected every iteration | Available on demand | Read once |
| --- | --- | --- |
| `title`, `summary` | `<spec-dir>/context.md` | `context` (short background) |
| `invariants` | `<spec-dir>/attempts/*.log` | `open_questions` |
| `out_of_scope` | | |
| `verification` | | |
| `ledger` (grows as work completes) | | |
| tail of `<spec-dir>/NOTES.md` | | |

So: `summary` is 1–3 sentences, not an essay. Long-form background goes to `context.md` instead, where `loop.sh` can point an iteration at it without injecting it. If you find yourself writing background into `summary`, move it.

## Hard rules

- **Do not write `issues`.** This skill produces context only. The user runs `/to-issues` when they're ready to decompose. A spec.json without issues is valid and expected — the loop refuses to run on it and says so.
- **Do not write `ledger`.** `loop.sh` owns it.
- **Slug matches the directory.** `.scratch/lab-modeling-v2/spec.json` must have `"slug": "lab-modeling-v2"`.
- **Default location is `.scratch/<slug>/`** unless the repo documents another convention (check `CLAUDE.md` / `AGENTS.md` for an issue-tracker convention first) or the user names one.

## Process

### 1. Understand the ask

Read what the user gave you — a request, a conversation, a research doc, a pile of links. Do not start writing yet.

### 2. Ground it in the codebase

Use the Agent tool with `subagent_type=Explore` to find what already exists in the area. You are writing constraints that a future agent will treat as absolute, so they had better be true today. Specifically hunt for:

- The seams the work will touch, and what already owns them.
- Facts that constrain the work: canonical keys, existing defaults, what the tests assert.
- Anything that makes a naive implementation wrong.

### 3. Resolve what changes the shape

Ask the user about decisions that would produce materially different work. Do not ask about things you can settle from the code or a sensible default. Anything left genuinely open goes in `open_questions` — but a spec that's mostly open questions isn't ready, so push to close them.

### 4. Write spec.json

Field by field:

**`summary`** — what changes and why, 1–3 sentences. This is repeated into every iteration; every word costs.

**`invariants`** — rules that hold for *every* issue in the effort. This is the highest-leverage field in the file. Write them as absolutes an implementer could violate:

- Good: `"Sleeper player_id is the canonical player PK; never key on name."`
- Good: `"No DB migrations — dev data is disposable and rebuilt by the fetchers."`
- Bad: `"Write good tests."` (unfalsifiable, unactionable, pure noise in every prompt)
- Bad: `"Use the VORP seam from issue 3."` (an issue detail, not an effort-wide rule)

Aim for 3–6. Every invariant is paid for on every iteration, so a weak one is worse than no one.

**`out_of_scope`** — the adjacent work this effort deliberately doesn't do. Cheap to write, and it's the main defence against an agent building ahead.

**`verification`** — the exact shell commands that must pass. Read the repo's scripts; don't guess at `npm test`.

`loop.sh` **executes these itself** after the agent reports done, and refuses to record the issue if any of them fails. That makes this the one field where a mistake stops the whole effort rather than degrading it: a command that can't succeed means no issue ever completes, and the run stalls on the first ticket. Verify each one runs green in the repo *before* you write it here. Prefer the narrowest commands that would actually catch a broken slice — a full end-to-end suite re-run on every iteration is slow and, when it's flaky, indistinguishable from a real failure.

**`context`** — everything else. Research findings, provenance, alternatives rejected and why, links. Write it to `<spec-dir>/context.md`, a sibling file, rather than this field: `loop.sh` can point an iteration at a file to read on demand, but not at a field buried inside spec.json, which also holds the `issues` array that implementers must never see. The JSON `context` field is still fine for a short paragraph. `/to-issues` reads whichever exists when decomposing.

### 5. Validate

```bash
~/.claude/scripts/loop.sh <spec-dir> --check
```

It will report "no issues to work through" — that is the expected, correct result at this stage. Any *other* error is a real problem to fix.

If a JSON Schema validator is available (`check-jsonschema`, `ajv`, `python3 -m jsonschema`), run it against `resources/spec.schema.json` too.

### 6. Report

Tell the user where the spec landed, summarise the invariants and what you put out of scope, surface any `open_questions`, and tell them the next step is `/to-issues <spec-dir>`.

## Anti-patterns

- **Essay in `summary`.** It gets re-injected forever. Move it to `context.md`.
- **Invariants that are really acceptance criteria.** If it applies to one issue, it belongs on that issue, not here.
- **Aspirational constraints.** "Keep it fast", "be careful with types" — an agent can't act on these and they dilute the ones it can.
- **Writing issues.** Not this skill's job. Stop at the context.
