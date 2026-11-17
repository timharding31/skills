---
name: narrow-react-prop-types
description: Use when adding, editing, or reviewing React component props, or when a component has optional props, `?.()` callbacks, or `?? []` fallbacks.
---

Adapted from HumanLayer's narrow-react-prop-types (https://github.com/humanlayer/skills/blob/main/plugins/narrow-react-prop-types/skills/narrow-react-prop-types/SKILL.md).

# Narrow React prop types

Component props get widened for stories, mocks, tests, and demos until they allow states the live app never enters. Make the prop types describe what live code paths pass, then make stories, tests, and mocks satisfy that contract.

## Rules

- Live call sites decide the prop contract. Find them before changing a type.
- Do not keep a prop optional because a story, test, or mock omits it.
- Keep a prop optional only when a live call site omits it and that omission is a real runtime state.
- The type should not allow states that no live call site produces. Every optional prop is a branch the component must handle and test.
- Derive types from live values and APIs instead of restating them by hand.

## Scope

- **Invoked during another task.** Narrow only the components the current change already touches, plus their internal children. List other suspects in the final report and leave them unchanged.
- **Invoked as a cleanup pass.** Pick targets with the signals in step 1. Keep one change to a few related components so the diff stays reviewable.

## Published packages

In a library repo (portal-components, design-system, viz, cds-ui), stories are often the only in-repo call sites. The live call sites are in consumer repos.

1. Find consumers: `grep -l '"<package-name>"' ~/dev/*/package.json`.
2. Search each consumer's `src/` for the component and its exported prop type.
3. If a consumer is not checked out, stop and say which one is missing. Do not narrow an exported prop without seeing every consumer.
4. Narrowing an exported prop is a breaking change for consumers. Say so in the report, and say which consumer call sites must change.

Internal components that the package does not export follow the normal workflow.

## Workflow

### 1. Identify suspect components

Signals:

- A props interface with many optional fields.
- Optional callback calls such as `onSelect?.(...)`.
- Fallbacks such as `items ?? []`, `count ?? 0`, or `handler && ...` on values live code always supplies.
- An affordance that always renders while its callback is optional.
- Demo-shaped props: `defaultFoo`, alternate handler shapes, or display toggles that live code never sets.

A story or test alone is not a reason to pick a target. Use them only as supporting evidence that a type has been widened.

### 2. Find every live usage

Search for every import and usage of the component, its exported prop type, and shared child primitives. Classify each call site:

- **Live:** routes, wired components, providers, hooks, package exports, and shared components those paths use.
- **Support:** stories, tests, fixtures, mocks and mock-mode code (e.g. code behind `VITE_ENABLE_MOCKS`), and demo harnesses.

Only live call sites decide what the component supports.

### 3. Classify each prop

- **Required:** every live call site passes it.
- **Optional:** at least one live call site omits it, and the omission is a real runtime state.
- **Removed:** no live call site uses it.

Optional and nullable are different. If live code always passes a value that can be empty, use a required nullable prop (`focusedItem: FocusedItem | null`), not `focusedItem?: FocusedItem | null`.

### 4. Tighten the prop type

Change the prop type to allow only the states found in step 3. If the component always renders an interactive control, require its handler. A visible menu item that calls `onRename?.(...)` can do nothing when clicked.

### 5. Derive types where possible

- `Parameters<typeof fn>[0]` for an argument type.
- `ReturnType<typeof fn>` for a return type.
- `Extract<Union, Shape>` to narrow a union to the variant live code uses.
- `React.Dispatch<React.SetStateAction<T>>` for a state setter, not `(value: T) => void`.

Give `useState` an explicit type parameter when inference would widen the state, for example to a broad nullable object or a widened string literal:

```ts
const [dialogState, setDialogState] = useState<DialogState>({ id: null, isOpen: false })
```

### 6. Tighten internal child props

If a parent passed optional handlers to rows, menus, or buttons only because its own props were optional, make the child props required too. `onRename?.(id, name)` becomes `onRename(id, name)`.

### 7. Remove fallbacks for states that no longer exist

```ts
new Set(expandedIds ?? defaultExpandedIds ?? [])  // becomes: new Set(expandedIds)
items && items.length > 0                          // becomes: items.length > 0
```

### 8. Update variants that share the prop type

When several components share the prop type, change them together so they all follow the same contract.

### 9. Fix stories, tests, and mocks

When a story, test, or mock breaks, give it realistic handlers and state. Do not make a prop optional again to shorten test setup. If setup gets long, add a fixture or helper in support code.

### 10. Validate

Run the repo's typecheck script (`tsbuild`, `typecheck`, or `tsc --noEmit`, from `package.json`) in the changed package and in every consumer you changed. If the repo has `knip`, run it too, because removed props can leave unused exports and types.

### 11. Report

Write a short report:

- One table row per changed prop: component, file, change (required, removed, nullable), and the live call sites that justify it.
- The stories, tests, and mocks you updated.
- For published packages, the breaking changes and the consumer call sites they affect.
- The validation commands and their results.
- Suspects found but left unchanged (when invoked during another task).

## Anti-patterns

- A callback made optional so stories can omit it.
- A rendered menu item or button that calls `onAction?.(...)`.
- `default*` props added for Storybook when live code controls the value.
- `?? []` or `?? 0` hiding required state that is missing.
- More than one accepted API shape when live code uses only one.
