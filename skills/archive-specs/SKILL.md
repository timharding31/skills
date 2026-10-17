---
name: archive-specs
description: Move finished specs older than N days into specs/archive/ so the spec list stays short. Use when the user wants to archive, clean up, or prune old specs, or says "archive-specs".
user_invocable: true
argument-hint: "[--age <days>]"
allowed-tools: Bash,Read,AskUserQuestion
---

# Archive specs

Usage: `/archive-specs [--age <days>]`. `--age` defaults to 1: a spec whose last activity is more than 1 day old is eligible. Fractions work (`--age 0.5`).

Run from the repo that has `./specs/<slug>/spec.json`. SpectroVision lists `specs/archive/*` in a collapsed "archived" section of its specs dock.

## What counts

- **Complete.** Every issue is `done`. Age is the newest `ledger[].at`, or the `spec.json` mtime if the ledger is empty. These move without asking.
- **No issues.** The spec is waiting on `/to-issues`. Never touched.
- **Partial.** Some issue is not `done`. Older than `--age` means it may be abandoned, or finished with its last steps (`quality-review`, `deslop`, `ship-pr`) never cleaned up. Ask the user per spec.
- A spec with a running `loop.sh` is skipped.

## Steps

1. Plan, which changes nothing:

   ```sh
   node ~/.claude/skills/archive-specs/archive.mjs plan --age <n>
   ```

   The JSON has `archive` (complete, will move), `ask` (partial, needs a decision) and `skipped` (with reasons).

2. If `ask` is non-empty, use AskUserQuestion with `multiSelect: true`, one option per spec, 4 options and 4 questions at most per call. Chunk across calls for more. For each option:
   - label: the slug
   - description: `done/total issues, last activity <ageDays>d ago, open: <id (status), ...>`, and "only wrap-up steps left" when `onlyWrapUpLeft` is true

   Put specs with `onlyWrapUpLeft` first and say they are the likeliest to be finished. Nothing is pre-selected. Tell the user that archiving a partial spec marks its open issues `done`.

3. Show the user what will move (the `archive` list plus the selected `ask` specs) in one short list. Then move:

   ```sh
   node ~/.claude/skills/archive-specs/archive.mjs move <slug> <slug> ...
   ```

   `move` marks any open issue `done` (and drops its `claim_sha`), then moves the directory with `git mv` if git tracks it or `mv` if not. It rewrites `specs/<slug>` to `specs/archive/<slug>` in `specs/README.md` only, and nothing else.

4. Report in a few lines: how many moved, which partial specs were marked done, README paths rewritten, and `otherReferences` (paths elsewhere in the repo that still point at the old location, which the skill does not edit). Do not commit.

If the plan is empty, say so and stop.
