# SpectroVision

A hot-reloading web view of the spec directories `scripts/loop.sh` drives, in the
same Tokyo Night palette as ghostty. Zero dependencies — Node 18+ and a browser.

```sh
cd ~/dev/portal      # a repo with ./specs/<slug>/spec.json
sv                                # browses every spec, opens the most recently touched one
sv specs/home-recently-accessed   # opens that one, siblings still listed
sv --port 5000 --no-open
```

Put it on PATH with `ln -s ~/.claude/tools/spectrovision/bin/sv ~/.local/bin/sv`
— the launcher follows symlinks. A bare `spec.json` path works too, and
`SPEC_VIEWER_PORT` sets the default port.

It fails immediately if there is no `./specs/<slug>/spec.json` and no spec dir
was named.

## What it shows

Everything loop.sh leaves on disk, minus the iteration stream itself (that lives
in the terminal):

- `spec.json` — summary, invariants, out-of-scope, open questions, issue board,
  ledger, per-issue criteria/files/verification/attempts
- `issues/*.md` — ticket bodies including the `## Comments` trail
- `context.md`, `NOTES.md`
- `attempts/*.log` — the full verification output behind a failed attempt (the
  prompt only ever sees a three-line tail); bodies load on demand when a fold
  opens, so a hot run isn't re-shipping megabytes every change
- a **next** tag on the frontier issue — first in array order not yet done
  with every blocker done, i.e. exactly what loop.sh will pick up next
  (including a `claimed` leftover from a killed run, which it re-picks)
- commit subjects and name-status file lists for every ledger entry and
  `claim_sha`, read from the surrounding git repo
- whether a `loop.sh` is running for each spec, from the process table

The right dock switches between the **specs** browser (every spec in the repo,
with progress and a live dot) and **details** for the open issue.

## Interaction

| key | |
| --- | --- |
| `⌘K` | palette — jump to an issue, a view, or another spec |
| `j` / `k` | previous / next issue |
| `e` | edit the open issue (when it is editable — see below) |
| `⌘/` | focus the comment box (per-criterion buttons anchor the comment) |
| `⌘⏎` | save whatever is open |
| `esc` | close the editor or palette |
| `g` `o` `n` `c` `l` | graph, overview, NOTES, context, ledger |

Edits write straight to disk:

- **Comments** append under `## Comments` in the ticket body — the section
  loop.sh already replays into the next iteration's prompt, tagged
  `(human)` or `(human, criterion 3)`.
- **Issue fields**, **new issue**, **delete** rewrite `spec.json` in place —
  2-space indent, issue keys normalized to loop.sh's canonical field order —
  so the diff stays readable.
- **Reorder** — ▲/▼ on hover in the issue rail. Array order is priority order
  (the frontier is "first ready issue in array order"), so this is a real
  planning edit, refused while a run is live like any other spec.json write.
- **Spec fields** — title, summary, invariants, out-of-scope, open questions,
  and the effort-wide verification commands — are edited from the overview,
  through the same `/api/spec/meta` write and the same locks as the board.
- **Ticket bodies**, `NOTES.md` and `context.md` are edited as raw markdown.
  Abandoning unsaved keystrokes (esc, navigating away) asks first.

A comment draft survives live reloads: the page re-renders on every disk
change, but the box's text, focus and selection are carried across — you can
type feedback while the loop is writing under you.

## Two locks

Both are enforced in `server.mjs`, not only in the page — the UI hides the
affordance, and the write is refused with HTTP 423 if it is attempted anyway.
There is no override.

**A live run means comments only.** `loop.sh` owns `spec.json`: it snapshots the
file before each iteration and byte-reverts anything that changed mid-iteration,
recording the change as a failed attempt against the agent. Prose files are no
safer — the agent appends to them too, and saving the editor is a whole-file
overwrite that would drop whatever it wrote. So while a run for that spec is
live, `/api/comment` is the only write that lands. Comments are append-only into
the `## Comments` section `loop.sh` already replays, so they survive.

**Claimed and done issues are frozen.** Their fields, their ticket body, and
deleting them are all refused; the edit chip is gone and the body loses its edit
button. Reopening one is an edit like any other, so it is refused too — the
issue is the agent's record, and a comment is how you argue with it. `NOTES.md`
and `context.md` are not owned by any issue and stay editable while idle.

Every `spec.json` write also carries the mtime the page last read and 409s if
the file moved underneath it.

The server also refuses requests whose `Host` isn't localhost and mutations
that aren't `application/json` — a hostile web page can reach 127.0.0.1 via
DNS rebinding or a no-preflight `text/plain` POST, and neither gets through.

Safe habit: comment during a run, restructure the board between runs.

## Killing a run

The ✕ kill button next to the live pill SIGINTs the loop's **process group** —
byte-for-byte the Ctrl-C the terminal would deliver, so the in-flight
`claude -p` dies with the loop instead of finishing and committing behind your
back. The server re-verifies the pid still belongs to a loop before
signalling (pids get reused) and refuses to signal its own group. A
mid-iteration kill can leave uncommitted work in the repo; the next run's
prompt calls out the dirty tree and carries on. Starting a run stays in the
terminal, where the iteration stream lives.

## Layout

```
server.mjs        HTTP + SSE, spec discovery, all disk reads/writes
bin/sv            launcher to put on PATH (`sv`)
public/index.html shell
public/app.js     state, routing, rendering, keys, palette
public/md.js      small markdown renderer (escapes first, then marks up)
public/graph.js   layered DAG → SVG, transitively reduced (implied edges hidden)
public/styles.css Tokyo Night Night
```

Live updates come from a 700ms mtime+size fingerprint of the spec tree pushed
over SSE — `fs.watch --recursive` blows up with EMFILE on a repo-sized tree.
Append `?nosse=1` to the URL to freeze the page (no live channel, no clock).
