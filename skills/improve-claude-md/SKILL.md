---
name: improve-claude-md
description: Rewrite a CLAUDE.md so conditional guidance is scoped and the always-loaded part stays lean.
user_invocable: true
disable-model-invocation: true
---

Adapted from HumanLayer's improve-claude-md (https://github.com/humanlayer/skills/blob/main/plugins/improve-claude-md/skills/improve-claude-md/SKILL.md).

Rewrite the CLAUDE.md the user names, or the project's `CLAUDE.md` when they name none.

## Why

Everything in a CLAUDE.md competes for attention on every task. When most of the file is irrelevant to the current task, the model follows the relevant parts less reliably. The fix is to keep the always-loaded part short and give conditional guidance a clear trigger or a separate load point. HumanLayer reports better adherence from `<important if>` blocks. That claim is theirs and is not measured here.

## Where each piece of guidance goes

Pick the narrowest mechanism that still loads the guidance when it is needed:

| Guidance | Put it in |
|---|---|
| Relevant to almost every task: project identity, project map, stack | Bare markdown at the top of CLAUDE.md |
| Tied to file paths (e.g. API handlers, migrations, tests in `e2e/`) | A rule file in `.claude/rules/` with `paths:` frontmatter. It loads only when Claude reads, writes, or edits a matching file. |
| Tied to one directory that has its own conventions | A CLAUDE.md in that directory. It loads on demand when Claude works there. |
| Tied to a kind of task, not a path (e.g. "when adding a dependency", "when writing a migration plan") | An `<important if="...">` block in CLAUDE.md |
| A multi-step procedure | A skill, with CLAUDE.md naming when to use it |

Path-scoped rule syntax:

```markdown
---
paths:
  - "src/api/**/*.ts"
---
```

Only the `paths:` rules and subdirectory CLAUDE.md files actually skip loading. An `<important if>` block still loads every session, and only signals relevance.

## Principles

1. **Conditions are narrow.** `<important if="you are writing or modifying any code">` matches everything and does nothing. Give each rule its own trigger: `<important if="you are adding or modifying imports">`. Group rules under one block only when they share the trigger.
2. **Cut what tooling enforces.** Formatting, lint rules, and naming conventions a linter checks. Suggest a pre-commit hook for anything that should be enforced and is not.
3. **Cut what the code shows.** Patterns the codebase follows consistently are learned from a few searches.
4. **Cut code snippets.** They go stale. Point to a file that shows the pattern instead.
5. **Cut vague instructions.** "Follow best practices", "leverage the X agent". Keep only instructions a reader could check.
6. **Keep every command.** The commands table stays whole, wrapped in one `<important if>` block.
7. **Prefer inline over sharding.** Split into rule files or imports only when the guidance is path-scoped or long.

## Imports

- `@path` imports are skipped inside backticks and fenced code blocks. Put the import on its own line, bare.
- An import loads the whole file every session. Import only what must always be in context. A procedure belongs in a skill instead.
- Imports nest at most four hops. Relative paths resolve from the importing file.

## Output structure

```markdown
# CLAUDE.md

<one line: what this project is and what it is built with>

## Project map
<directories with a few words each>

<important if="you need to run commands to build, test, lint, or generate code">
<commands table, every command from the original>
</important>

<important if="<narrow trigger>">
<rule or domain section>
</important>
```

Plus any `.claude/rules/*.md` and subdirectory CLAUDE.md files the table above calls for.

## Steps

1. Read the target CLAUDE.md, any files it imports, existing `.claude/rules/`, and subdirectory CLAUDE.md files.
2. Extract the project identity, project map, and stack. Leave them bare at the top.
3. Extract every command into one wrapped block.
4. Sort each remaining rule or section into a row of the table above. Split rule lists so each rule gets the narrowest trigger.
5. Delete tooling-enforced rules, discoverable patterns, code snippets, and vague instructions.
6. Write the files. Then report, in a short list:
   - What moved where (CLAUDE.md block, rule file with its `paths`, subdirectory CLAUDE.md, skill).
   - What was deleted, and the reason for each deletion.
   - Pre-commit hooks worth adding for deleted style rules.

## Global CLAUDE.md

For `~/.claude/CLAUDE.md`, there is no project map or command table. Personal working preferences apply to every task and stay bare. Wrap only guidance tied to a model, tool, or kind of task. Path rules for every project go in `~/.claude/rules/`. The docs do not say whether `paths:` works there, so check with `/context` after a matching file is read before relying on it.
