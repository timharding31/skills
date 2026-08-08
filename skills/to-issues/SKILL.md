---
name: to-issues
description: Decompose a spec.json into an ordered, dependency-aware list of issues plus one prose body file each. Use when the user wants to break a spec into tickets, plan implementation slices, or says "to-issues". Run after /to-spec.
---

# To Issues

Take a `spec.json` written by [`/to-spec`](../to-spec/SKILL.md) and fill in its `issues` array, writing one prose body per issue at `<spec-dir>/issues/<id>.md`.

Schema: [`../to-spec/resources/spec.schema.json`](../to-spec/resources/spec.schema.json). Read it before writing.

## What consumes this

[`~/.claude/scripts/loop.sh`](../../scripts/loop.sh) implements the effort one issue per iteration. Each iteration gets a **fresh context window** containing the spec's summary/invariants/out-of-scope/ledger, the tail of `<spec-dir>/NOTES.md`, a pointer to `<spec-dir>/context.md` (read on demand, when present), plus **exactly one** issue — its title, its `criteria`, its `files`, and its body file. The only thing it sees of any other issue is the `## Comments` section of its **direct blockers**.

Three consequences that shape everything below:

1. **The script picks, not the model.** It takes the first issue in array order whose `blocked_by` are all done. **Array order is priority order** — put them in the order you want them built.
2. **An issue must be implementable from its own body plus the spec's invariants.** No "as discussed in the previous ticket", no cross-references to siblings. What a later issue needs from an earlier one arrives through the `ledger` and through its blockers' `## Comments`, both of which the loop carries automatically — you never author either.
3. **Criteria must be provable from the diff, not from intent.** After verification passes, a clean-context reviewer — a fresh model sharing no context with the implementer — judges the iteration's git diff against that issue's `criteria` and can reject the DONE if the diff doesn't satisfy them. A criterion the diff can't evidence will fail review even when it's true. The stronger move is to not leave a criterion to the reviewer at all: an issue's own `verification` commands are executed by the loop under the same gate as the effort-level ones, so a criterion backed by a named test is checked deterministically.

## Where each thing lives

Metadata is in JSON, prose is in markdown, and they never duplicate each other.

| Goes in `spec.json` | Goes in `issues/<id>.md` |
| --- | --- |
| `id`, `title`, `status`, `blocked_by` | Why this slice exists |
| `criteria` — the definition of done | What the shape of the solution is, and what it must not be |
| `verification` — the commands that prove the criteria | Constraints and gotchas specific to this issue |
| `files` — where to start | |
| | A trailing `## Comments` heading |

The body file carries **no** status line, **no** blocked-by line, and **no** checkbox list. Those were the fragile parts of the old markdown format; they are structured fields now. Duplicating criteria into the body guarantees the two drift.

## Process

### 1. Read the spec whole

Including `context`, and `<spec-dir>/context.md` when present — both exist for this moment. Note the `invariants`: they're injected into every issue's prompt, so never restate them in a body.

### 2. Ground the slices in the code

Use the Agent tool with `subagent_type=Explore` to check where each slice would actually land. An issue whose `files` are wrong costs the implementing agent a discovery phase you were supposed to save it.

### 3. Slice

Each issue should be a **tracer bullet**: a thin vertical slice that leaves the repo working, tested, and committable on its own. Not a layer ("add the types"), not a phase ("do the backend").

Sizing: one issue ≈ one focused agent session. If you can't state its done-ness in 2–5 observable criteria, it's too big — split it. If it can't be verified without its neighbour, it's too small — merge it.

Ordering: dependency order first, then risk. Put the issue that proves the risky assumption early, so a wrong assumption surfaces on iteration 1 rather than iteration 6.

### 4. Write the bodies

`<spec-dir>/issues/<id>.md`, where `<id>` is the issue's kebab-case id — the filename and the id must match.

```markdown
# <title>

<Why this slice exists and what it unlocks — a short paragraph.>

<The shape the solution should take: the seam it creates or consumes, the
approach to prefer, the approach to avoid and why. Enough that an agent with
no other context makes the same call you would.>

## Comments
```

Keep it to what changes the implementation. Leave `## Comments` empty — the implementing agent writes its own notes there as work completes, and the loop feeds that section to whichever issues list this one in their `blocked_by`. That is the channel for seam-level detail the ledger's one-liner can't carry ("takes a `LeagueSettings`, not a `leagueId`"), so the heading must be present even when there's nothing under it yet.

Use `"body": null` when the criteria genuinely say everything and there's no rationale to give. Don't write a body that only restates the title.

### 5. Write the issues array

- `id` — kebab-case, stable, unique. It appears in `blocked_by`, in the ledger, and in the agent's completion promise.
- `status` — `"ready"` for everything. The loop owns this field from here on.
- `attempts` — **never write this.** Like `status` and `ledger`, it belongs to `loop.sh`, which records each failed iteration there and replays the most recent ones into the next attempt's prompt. The one exception is replanning a stuck issue — see [Replanning a stuck issue](#replanning-a-stuck-issue---replan) below.
- `blocked_by` — ids only, and only *hard* blockers: this issue cannot be correctly built until that one exists. Do not encode mere preference; a false blocker serialises work that could have been done in any order.
- `criteria` — observable conditions, each checkable by running something or reading the resulting code. "Replacement level shifts with superflex" is checkable. "Code is clean" is not. Criteria are also what the post-verification diff review judges against, so write each one to be checkable by reading the diff and running the verification commands — not by trusting the implementer's stated intent.
- `verification` — shell commands specific to this issue, executed by the loop after the effort-level `verification` under the same gate. Whenever a criterion says tests exist or behavior holds, name the command that proves it (`npm test -- src/vorp.spec.ts`) — a deterministic check beats a model reading a diff. Commands must be real and runnable from the repo root; when the criteria name a test file the issue itself creates, the command must still exit non-zero before that file exists (most runners fail on a missing named file, which is what you want). Omit the field when the effort-level commands already cover the issue.
- `files` — the paths to start from.
- `model` — **omit unless the user asks for per-issue models.** `"haiku"`, `"sonnet"`, `"opus"`, or `"fable"`; it overrides the model `loop.sh` was launched with, for that iteration only. When they do ask, assign it from the work: mechanical, well-specified edits can take `haiku`; issues carrying the design risk you ordered early take `opus`. Leave it off everywhere you have no reason to differ from the run's default.

### 6. Append the final quality-review issue

Unless the user opts out, or the effort has only one issue, the **last** issue in the array is a code-quality review of the whole run:

```json
{
  "id": "quality-review",
  "title": "Post-run code quality review of this effort",
  "status": "ready",
  "blocked_by": ["<every other issue id>"],
  "body": "issues/quality-review.md",
  "model": "opus",
  "criteria": [
    "Every change in the diff is a restructuring: no new features, and no behavior change that an existing test asserts",
    "No test assertions were weakened, skipped, or deleted"
  ]
}
```

- `blocked_by` lists **every other id** — this is the one issue where a total edge set is correct, so it runs exactly once, after everything.
- `model: "opus"` is the default and the exception to "omit `model`": ambitious restructuring is the one ticket that earns a stronger model than the run's default. Honor a user's different choice.
- Keep the criteria falsifiable, as above — "code quality improved" is exactly the unfalsifiable criterion this skill bans, and the loop's judge would have nothing to check.
- Criteria must also be *visible to the judge*, which sees one flattened diff: commit boundaries, commit messages, and anything under gitignored `specs/` (including `## Comments`) never appear in it. Conventions like one-commit-per-restructuring or recording skipped findings belong in the body's instructions, not in `criteria`.

Body (`issues/quality-review.md`): instruct the implementer to review the effort's *whole* diff — the ledger in its prompt lists each completed issue's short commit SHA; the range is from the parent of the first ledger commit to HEAD. If the `thermo-nuclear-code-quality-review` skill is available, invoke it and adapt it to that local diff (skip its GitLab MR-fetching steps; the review standards apply unchanged). Otherwise carry its core stance inline in the body: be ambitious about structural simplification, hunt for "code judo" moves that make whole branches or layers disappear, preserve behavior exactly, and treat any file crossing 1k lines as a smell.

The body must also instruct three closing duties the criteria can't carry (see the judge-visibility bullet above): keep each restructuring in its own commit whose message references quality-review; record findings judged not worth a code change under this issue's `## Comments`; and read `<spec-dir>/NOTES.md`, promoting every bullet that is true of the repo beyond this effort (build quirks, required env vars, conventions to follow) into the repo's CLAUDE.md — or AGENTS.md, if that is the repo's convention. NOTES.md lives in a gitignored directory and dies with the spec; anything left unpromoted is relearned at full price by the next effort. End with the standard `## Comments` heading.

### 7. Validate

```bash
~/.claude/scripts/loop.sh <spec-dir> --check
```

This checks ids are unique, blockers resolve, criteria exist, statuses are legal, every `body` file is on disk, and the graph is acyclic — then prints the board with the blocked chain drawn. A cycle fails validation outright and names the issues that can never become workable.

### 8. Report

Show the user the board, name the starting frontier (everything with no blockers), and tell them to run:

```bash
~/.claude/scripts/loop.sh <spec-dir>
```

## Re-running on a spec that's already in flight

Never touch `status` on issues that are `done` or `claimed`, and never touch `ledger` — that's execution state and rewriting it loses the record of what was built. Add new issues to the array in the position their priority warrants, and only edit the `criteria` or `body` of issues still `ready`. The one sanctioned exception, for an issue that's stuck rather than merely in flight, is the replan flow below.

**Maintain the quality-review issue's total edge set.** Any issue you add — including issues created by splitting one under `--replan` — must also be appended to `quality-review`'s `blocked_by`, or the review runs before the effort is actually finished.

## Replanning a stuck issue (--replan)

Invoked as `/to-issues <spec-dir> --replan <issue-id>` when `loop.sh` has circuit-broken on an issue at its `ISSUE_ATTEMPT_LIMIT` and told the user to run this.

1. Read the issue: its body, its full `attempts` array, and the logs under `<spec-dir>/attempts/` for it.
2. Diagnose why it's stuck: the criteria are wrong, the slice is too big, or a real blocker was missed.
3. Fix it — one of:
   - Rewrite the `criteria` and/or `body` in place.
   - Split it into smaller issues, inserted at its position in the array.
   - Add a `blocked_by` edge for a blocker that was genuinely missing.
4. On any issue you rewrite or replace: reset its `status` to `"ready"` and clear its `attempts` array. This is the **one** sanctioned exception to "never write `attempts`" and "never touch status on issues that are done or claimed" — it applies only to the issue(s) being replanned, never to `done` issues or to `ledger`.
5. Re-run `loop.sh <spec-dir> --check` to confirm the graph is still valid before handing it back.

## Anti-patterns

- **Layer slices.** "Add types", then "add the service", then "wire the UI" — nothing is shippable until the last one, and the first two can't be verified.
- **Cross-referencing siblings.** "Reuse the helper from `vorp-seam`." The implementer can't see that issue's ticket. If it's a direct blocker, its `## Comments` will arrive — but only what the implementing agent chose to write there, which you can't know in advance. Anything the slice genuinely depends on goes in the criteria.
- **Restating invariants in bodies.** They're already in every prompt. Repetition just crowds the part that's specific to this issue.
- **Blocking on preference.** Every false edge in `blocked_by` narrows the frontier and lengthens the run.
- **Unfalsifiable criteria.** If nothing observable distinguishes done from not-done, the loop can't tell either.
