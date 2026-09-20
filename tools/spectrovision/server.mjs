#!/usr/bin/env node
// SpectroVision (sv) — a hot-reloading web view of the spec directories loop.sh drives.
//
// Run it from a repo root with no arguments and it browses every spec under
// ./specs; point it at one spec dir and it opens there with its siblings still
// listed. Everything it shows comes off disk: spec.json, issues/*.md,
// context.md, NOTES.md, attempts/*.log.

import { createServer } from 'node:http'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const exec = promisify(execFile)
const HERE = path.dirname(fileURLToPath(import.meta.url))
const PUBLIC = path.join(HERE, 'public')

const usage = `Usage: sv [dir|spec-dir|spec.json] [--port N] [--no-open]

With no argument, browses every spec under ./specs in the current directory.
Point it at a single spec dir to open there; its siblings stay browsable.

Options:
  --port N     port to listen on (default 4319, +1 until one is free)
  --no-open    do not open a browser
`

const argv = process.argv.slice(2)
let target = null
let port = Number(process.env.SPEC_VIEWER_PORT || 4319)
let openBrowser = true

for (let i = 0; i < argv.length; i++) {
  const a = argv[i]
  if (a === '--help' || a === '-h') { process.stdout.write(usage); process.exit(0) }
  else if (a === '--port' || a === '-p') port = Number(argv[++i])
  else if (a.startsWith('--port=')) port = Number(a.slice(7))
  else if (a === '--no-open') openBrowser = false
  else if (a.startsWith('-')) die(`unknown option ${a}\n\n${usage}`)
  else if (target === null) target = a
  else die(`unexpected argument ${a}\n\n${usage}`)
}

function die (msg) {
  process.stderr.write(`sv: ${msg}\n`)
  process.exit(1)
}

// ------------------------------------------------------------ discovery

const resolved = path.resolve(target || process.cwd())
let stat
try { stat = fs.statSync(resolved) } catch { die(`no such path: ${resolved}`) }

// SPECS_DIR holds one directory per spec; INITIAL is the slug to open first.
let SPECS_DIR = null
let INITIAL = null

const isSpecDir = (p) => fs.existsSync(path.join(p, 'spec.json'))

if (stat.isFile()) {
  const dir = path.dirname(resolved)
  SPECS_DIR = path.dirname(dir)
  INITIAL = path.basename(dir)
} else if (isSpecDir(resolved)) {
  SPECS_DIR = path.dirname(resolved)
  INITIAL = path.basename(resolved)
} else if (fs.existsSync(path.join(resolved, 'specs'))) {
  SPECS_DIR = path.join(resolved, 'specs')
} else {
  die(`no specs here — expected ${path.join(resolved, 'specs')}/<slug>/spec.json, or point me at a spec dir`)
}

function listSlugs () {
  let names = []
  try { names = fs.readdirSync(SPECS_DIR) } catch { return [] }
  return names.filter((n) => !n.startsWith('.') && isSpecDir(path.join(SPECS_DIR, n))).sort()
}

if (!listSlugs().length) die(`no spec.json under ${SPECS_DIR}/*/ — nothing to view`)
// With no argument, open whichever spec was touched last — during a run that
// is the one loop.sh is working.
if (!INITIAL) {
  INITIAL = listSlugs()
    .map((slug) => {
      let m = 0
      try { m = fs.statSync(path.join(SPECS_DIR, slug, 'spec.json')).mtimeMs } catch { /* keep 0 */ }
      return { slug, m }
    })
    .sort((a, b) => b.m - a.m)[0].slug
}

const dirFor = (slug) => {
  if (!slug || !listSlugs().includes(slug)) throw Object.assign(new Error(`unknown spec ${slug}`), { status: 404 })
  return path.join(SPECS_DIR, slug)
}

// ---------------------------------------------------------------- payload

const MAX_LOG_BYTES = 400_000

async function readIf (p) {
  try { return await fsp.readFile(p, 'utf8') } catch { return null }
}

async function mtimeIf (p) {
  try { return (await fsp.stat(p)).mtimeMs } catch { return null }
}

async function readIssueBodies (dir) {
  const sub = path.join(dir, 'issues')
  const out = {}
  let names = []
  try { names = await fsp.readdir(sub) } catch { return out }
  for (const n of names.sort()) {
    if (!n.endsWith('.md')) continue
    out[`issues/${n}`] = await readIf(path.join(sub, n))
  }
  return out
}

// Metadata only — bodies can be 400KB each and the payload refetches on every
// change, so the page pulls a log's body on demand via /api/attempt.
async function readAttempts (dir) {
  const sub = path.join(dir, 'attempts')
  const out = []
  let names = []
  try { names = await fsp.readdir(sub) } catch { return out }
  for (const n of names.sort()) {
    const full = path.join(sub, n)
    let st
    try { st = await fsp.stat(full) } catch { continue }
    if (!st.isFile()) continue
    const m = /^(.*)-(\d+)\.log$/.exec(n)
    out.push({
      name: n,
      issueId: m ? m[1] : null,
      attempt: m ? Number(m[2]) : null,
      bytes: st.size,
      mtime: st.mtimeMs,
    })
  }
  return out
}

async function readAttemptBody (dir, name) {
  if (!/^[^/\\]+\.log$/.test(name)) throw Object.assign(new Error('bad attempt name'), { status: 400 })
  const full = path.join(dir, 'attempts', name)
  let body = await readIf(full)
  if (body == null) throw Object.assign(new Error(`no attempt log ${name}`), { status: 404 })
  let truncated = false
  if (body.length > MAX_LOG_BYTES) { body = body.slice(-MAX_LOG_BYTES); truncated = true }
  return { name, truncated, body }
}

const repoRoots = new Map()
async function findRepoRoot (dir) {
  if (repoRoots.has(dir)) return repoRoots.get(dir)
  let root = ''
  try {
    const { stdout } = await exec('git', ['-C', dir, 'rev-parse', '--show-toplevel'])
    root = stdout.trim()
  } catch { root = '' }
  repoRoots.set(dir, root)
  return root
}

const commitCache = new Map()
async function commitInfo (dir, sha) {
  if (!sha) return null
  if (commitCache.has(sha)) return commitCache.get(sha)
  const root = await findRepoRoot(dir)
  if (!root) return null
  let info
  try {
    const { stdout } = await exec('git', ['-C', root, 'show', '-s', '--format=%s%n%an%n%aI', sha])
    const [subject, author, date] = stdout.split('\n')
    const { stdout: stat } = await exec('git', ['-C', root, 'show', '--name-status', '--format=', sha])
    const files = stat.trim().split('\n').filter(Boolean).slice(0, 80).map((l) => {
      const [status, ...rest] = l.split('\t')
      return { status, path: rest.join(' → ') }
    })
    info = { sha, subject, author, date, files }
  } catch {
    info = { sha, subject: null, author: null, date: null, files: [] }
  }
  commitCache.set(sha, info)
  return info
}

// A loop.sh run shows up in the process table with the spec dir (or its slug)
// in argv. One `ps` sweep answers for every spec at once.
let psCache = { at: 0, lines: [] }
async function psLines () {
  if (Date.now() - psCache.at < 1500) return psCache.lines
  let lines = []
  try {
    const { stdout } = await exec('ps', ['-Ao', 'pid=,etime=,args='], { maxBuffer: 8 << 20 })
    lines = stdout.split('\n').filter((l) => /loop(-once)?\.sh/.test(l))
  } catch { lines = [] }
  psCache = { at: Date.now(), lines }
  return lines
}

async function runningState (dir) {
  // Match the absolute spec dir, or the relative form loop.sh is invoked with
  // (`loop.sh specs/<slug>`), so a same-named spec in another repo — or any
  // process whose argv merely mentions the slug — doesn't read as a live run.
  const slug = path.basename(dir)
  const relative = new RegExp(`(^|[\\s='"/])specs/${slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(/|['"\\s]|$)`)
  for (const line of await psLines()) {
    if (!(line.includes(dir) || relative.test(line))) continue
    const m = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line)
    if (!m) continue
    // loop.sh must be the command being run (`/path/loop.sh …` or
    // `bash /path/loop.sh …`), not merely a substring somewhere in argv — a
    // `zsh -c` wrapper or an editor whose arguments mention the script is not
    // a live run, and /api/run/kill must never signal one.
    const tokens = m[3].split(/\s+/)
    if (!tokens.slice(0, 3).some((t) => /(^|\/)loop(-once)?\.sh$/.test(t))) continue
    return { running: true, pid: Number(m[1]), elapsed: m[2], command: m[3] }
  }
  return { running: false }
}

async function specSummaries () {
  const out = []
  for (const slug of listSlugs()) {
    const dir = path.join(SPECS_DIR, slug)
    const raw = await readIf(path.join(dir, 'spec.json'))
    let spec = null
    try { spec = JSON.parse(raw) } catch { /* a half-written spec still lists */ }
    const list = (spec && spec.issues) || []
    out.push({
      slug,
      dir,
      title: (spec && spec.title) || slug,
      broken: !spec,
      total: list.length,
      done: list.filter((i) => i.status === 'done').length,
      claimed: list.filter((i) => i.status === 'claimed').length,
      mtime: await mtimeIf(path.join(dir, 'spec.json')),
      run: await runningState(dir),
    })
  }
  return out
}

async function buildPayload (slug) {
  const dir = dirFor(slug)
  const specPath = path.join(dir, 'spec.json')
  const raw = await readIf(specPath)
  let spec = null
  let parseError = null
  try { spec = JSON.parse(raw) } catch (e) { parseError = String(e.message || e) }

  const commits = {}
  for (const entry of (spec && spec.ledger) || []) {
    const info = await commitInfo(dir, entry.commit)
    if (info) commits[entry.commit] = info
  }
  for (const issue of (spec && spec.issues) || []) {
    if (issue.claim_sha && !commits[issue.claim_sha]) {
      const info = await commitInfo(dir, issue.claim_sha)
      if (info) commits[issue.claim_sha] = info
    }
  }

  return {
    slug,
    dir,
    specsDir: SPECS_DIR,
    specPath,
    repo: await findRepoRoot(dir),
    generatedAt: Date.now(),
    specMtime: await mtimeIf(specPath),
    parseError,
    spec,
    context: await readIf(path.join(dir, 'context.md')),
    contextMtime: await mtimeIf(path.join(dir, 'context.md')),
    notes: await readIf(path.join(dir, 'NOTES.md')),
    notesMtime: await mtimeIf(path.join(dir, 'NOTES.md')),
    bodies: await readIssueBodies(dir),
    attempts: await readAttempts(dir),
    commits,
    run: await runningState(dir),
    specs: await specSummaries(),
  }
}

// ------------------------------------------------------------------ watch

const clients = new Set()

function broadcast (event, data) {
  const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
  for (const res of clients) {
    try { res.write(frame) } catch { /* client gone; the close handler cleans up */ }
  }
}

// A spec dir is a handful of small files, so an mtime+size fingerprint polled
// under a second beats fs.watch: a recursive watch blows up with EMFILE on a
// repo-sized tree, and a poll cannot miss an atomic rename either.
async function fingerprint () {
  const parts = []
  const stat = async (p) => {
    try { const s = await fsp.stat(p); parts.push(`${p}:${s.mtimeMs}:${s.size}`) } catch { parts.push(`${p}:-`) }
  }
  for (const slug of listSlugs()) {
    const dir = path.join(SPECS_DIR, slug)
    await stat(path.join(dir, 'spec.json'))
    await stat(path.join(dir, 'context.md'))
    await stat(path.join(dir, 'NOTES.md'))
    for (const sub of ['issues', 'attempts']) {
      const d = path.join(dir, sub)
      let names = []
      try { names = await fsp.readdir(d) } catch { continue }
      for (const n of names.sort()) await stat(path.join(d, n))
    }
  }
  return parts.join('|')
}

// Re-arm after each sweep completes rather than setInterval — a slow sweep on
// a big spec tree must not overlap the next one and race lastPrint.
let lastPrint = null
async function watchTick () {
  try {
    const now = await fingerprint()
    if (lastPrint !== null && now !== lastPrint) broadcast('change', { at: Date.now() })
    lastPrint = now
  } catch { /* transient rename race — the next tick catches up */ }
  setTimeout(watchTick, 700)
}
watchTick()

setInterval(() => broadcast('ping', { at: Date.now() }), 25_000).unref()

// -------------------------------------------------------------- mutations
//
// Two rules, both enforced here rather than only in the UI:
//
// 1. While a run is live, a comment is the only thing a human may write. loop.sh
//    owns spec.json — it snapshots the file before each iteration and byte-reverts
//    any change made in flight, recording it as a failed attempt against the agent
//    — and the agent appends to the prose files itself. Comments are append-only
//    into the section loop.sh already replays, so they are safe mid-iteration.
// 2. A claimed or done issue is the agent's record, not a draft. Its fields and
//    its ticket body are frozen; comment on it instead.
//
// Every spec.json write also carries the mtime the caller last read.
// (/api/run/start and /api/run/kill are not writes — they are the launch and
// the Ctrl-C the terminal would deliver, so both are exempt from the locks.)

const ISSUE_KEY_ORDER = ['id', 'title', 'status', 'blocked_by', 'body', 'model', 'files', 'verification', 'criteria', 'attempts', 'claim_sha']

const FROZEN = new Set(['claimed', 'done'])

function readBody (req) {
  return new Promise((resolve, reject) => {
    let buf = ''
    req.on('data', (c) => { buf += c; if (buf.length > 4 << 20) reject(new Error('body too large')) })
    req.on('end', () => { try { resolve(buf ? JSON.parse(buf) : {}) } catch (e) { reject(e) } })
    req.on('error', reject)
  })
}

async function readSpec (dir) {
  return JSON.parse(await fsp.readFile(path.join(dir, 'spec.json'), 'utf8'))
}

async function writeSpec (dir, spec) {
  const target = path.join(dir, 'spec.json')
  const tmp = `${target}.viewer.tmp`
  await fsp.writeFile(tmp, JSON.stringify(spec, null, 2) + '\n')
  await fsp.rename(tmp, target)
}

// Reserialize an issue in loop.sh's field order so UI edits produce diffs a
// human can read rather than a reshuffled object.
function orderIssue (issue) {
  const out = {}
  for (const k of ISSUE_KEY_ORDER) if (issue[k] !== undefined) out[k] = issue[k]
  for (const k of Object.keys(issue)) if (out[k] === undefined) out[k] = issue[k]
  return out
}

function locked (msg) { return Object.assign(new Error(msg), { status: 423 }) }

// Refuse any write that is not a comment while that spec's loop is live.
async function guardRun (dir) {
  const run = await runningState(dir)
  if (run.running) {
    throw locked(`loop.sh is running (pid ${run.pid}) — comments are the only edit allowed until it stops`)
  }
}

async function guardSpecWrite (body) {
  const dir = dirFor(body.slug)
  await guardRun(dir)
  const mtime = await mtimeIf(path.join(dir, 'spec.json'))
  if (body.specMtime && mtime && Math.abs(mtime - body.specMtime) > 1) {
    throw Object.assign(new Error('spec.json changed on disk since you loaded it — reload and retry'), { status: 409 })
  }
  return dir
}

function guardFrozen (issue, what) {
  if (FROZEN.has(issue.status)) {
    throw locked(`${issue.id} is ${issue.status} — ${what}. Comment on it instead.`)
  }
}

function safeSpecFile (dir, rel) {
  const full = path.resolve(dir, rel || '')
  if (!full.startsWith(dir + path.sep)) throw Object.assign(new Error('path escapes the spec dir'), { status: 400 })
  if (!/\.(md|txt)$/.test(full)) throw Object.assign(new Error('only .md files are editable here'), { status: 400 })
  return full
}

const MUTATIONS = {
  async '/api/issue' (body) {
    const dir = await guardSpecWrite(body)
    const spec = await readSpec(dir)
    const issue = (spec.issues || []).find((i) => i.id === body.id)
    if (!issue) throw Object.assign(new Error(`no issue ${body.id}`), { status: 404 })
    guardFrozen(issue, 'its fields are frozen')
    for (const [k, v] of Object.entries(body.patch || {})) {
      if (v === null) delete issue[k]
      else issue[k] = v
    }
    // An id rename has to follow through into every blocked_by, the ledger,
    // and the body file when it still carries the old id.
    if (body.patch && body.patch.id && body.patch.id !== body.id) {
      for (const other of spec.issues) {
        if (!other.blocked_by) continue
        other.blocked_by = other.blocked_by.map((b) => (b === body.id ? body.patch.id : b))
      }
      for (const l of spec.ledger || []) if (l.id === body.id) l.id = body.patch.id
      if (issue.body === `issues/${body.id}.md`) {
        const next = `issues/${body.patch.id}.md`
        try {
          await fsp.rename(path.join(dir, issue.body), path.join(dir, next))
          issue.body = next
        } catch { /* no file to move — leave the pointer as the caller set it */ }
      }
    }
    spec.issues = spec.issues.map(orderIssue)
    await writeSpec(dir, spec)
    return { ok: true }
  },

  async '/api/issue/new' (body) {
    const dir = await guardSpecWrite(body)
    const id = String(body.id || '').trim()
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw Object.assign(new Error('id must be kebab-case word characters'), { status: 400 })
    const spec = await readSpec(dir)
    spec.issues = spec.issues || []
    if (spec.issues.some((i) => i.id === id)) throw Object.assign(new Error('id already exists'), { status: 400 })
    const bodyFile = `issues/${id}.md`
    spec.issues.push(orderIssue({
      id,
      title: body.title || id,
      status: 'ready',
      blocked_by: [],
      body: bodyFile,
      criteria: [],
    }))
    await writeSpec(dir, spec)
    const full = path.join(dir, bodyFile)
    await fsp.mkdir(path.dirname(full), { recursive: true })
    try { await fsp.access(full) } catch {
      await fsp.writeFile(full, `# ${body.title || id}\n\nWhy this slice exists and how to build it.\n\n## Comments\n`)
    }
    return { ok: true }
  },

  async '/api/issue/delete' (body) {
    const dir = await guardSpecWrite(body)
    const spec = await readSpec(dir)
    const doomed = (spec.issues || []).find((i) => i.id === body.id)
    if (doomed) guardFrozen(doomed, 'it cannot be deleted')
    spec.issues = (spec.issues || []).filter((i) => i.id !== body.id)
    for (const other of spec.issues) {
      if (!other.blocked_by) continue
      other.blocked_by = other.blocked_by.filter((b) => b !== body.id)
    }
    await writeSpec(dir, spec)
    return { ok: true }
  },

  async '/api/issue/reorder' (body) {
    const dir = await guardSpecWrite(body)
    const spec = await readSpec(dir)
    const byId = new Map((spec.issues || []).map((i) => [i.id, i]))
    const next = body.order.map((id) => byId.get(id)).filter(Boolean)
    for (const i of spec.issues) if (!body.order.includes(i.id)) next.push(i)
    spec.issues = next
    await writeSpec(dir, spec)
    return { ok: true }
  },

  async '/api/spec/meta' (body) {
    const dir = await guardSpecWrite(body)
    const spec = await readSpec(dir)
    for (const [k, v] of Object.entries(body.patch || {})) {
      if (v === null) delete spec[k]
      else spec[k] = v
    }
    await writeSpec(dir, spec)
    return { ok: true }
  },

  // Prose: NOTES.md, context.md, ticket bodies. Rewriting one is a whole-file
  // overwrite, so it loses whatever the agent appended mid-iteration — hence the
  // run guard — and a claimed or done ticket body is frozen with its issue.
  async '/api/file' (body) {
    const dir = dirFor(body.slug)
    await guardRun(dir)
    const full = safeSpecFile(dir, body.path)
    const rel = path.relative(dir, full)
    let spec = null
    try { spec = await readSpec(dir) } catch { /* unparsed spec.json freezes nothing */ }
    const owner = (spec && spec.issues || []).find((i) => i.body === rel)
    if (owner) guardFrozen(owner, 'its ticket body is frozen')
    await fsp.mkdir(path.dirname(full), { recursive: true })
    await fsp.writeFile(full, body.content == null ? '' : String(body.content))
    return { ok: true }
  },

  // Kill the spec's live run — the Ctrl-C the terminal would deliver, sent to
  // the loop's process group so the in-flight `claude -p` dies with it instead
  // of orphaning the iteration (which would finish, verify, and commit anyway).
  async '/api/run/kill' (body) {
    const dir = dirFor(body.slug)
    const run = await runningState(dir)
    if (!run.running) throw Object.assign(new Error('no loop.sh is running for this spec'), { status: 409 })
    // Re-verify the pid is still that loop before signalling — pids get reused.
    let pgid, self
    try {
      const { stdout } = await exec('ps', ['-o', 'pgid=,args=', '-p', String(run.pid)])
      if (!/loop(-once)?\.sh/.test(stdout)) throw new Error('gone')
      pgid = Number(/^\s*(\d+)/.exec(stdout)[1])
      const { stdout: me } = await exec('ps', ['-o', 'pgid=', '-p', String(process.pid)])
      self = Number(me.trim())
    } catch {
      throw Object.assign(new Error('the run ended before the kill landed'), { status: 409 })
    }
    if (!pgid || pgid <= 1 || pgid === self) {
      throw Object.assign(new Error(`refusing to signal process group ${pgid}`), { status: 500 })
    }
    process.kill(-pgid, 'SIGINT')
    psCache = { at: 0, lines: [] } // the next runningState re-sweeps immediately
    return { ok: true, pid: run.pid, pgid }
  },

  // The one write with no guard on it. A comment is append-only and lands where
  // loop.sh already replays ticket prose from — the "## Comments" section of the
  // issue body — so it is safe mid-iteration and on a frozen ticket alike.
  async '/api/comment' (body) {
    const full = safeSpecFile(dirFor(body.slug), body.path)
    const text = String(body.text || '').trim()
    if (!text) throw Object.assign(new Error('empty comment'), { status: 400 })
    let src = ''
    try { src = await fsp.readFile(full, 'utf8') } catch { src = '' }
    if (!/^##\s+Comments\s*$/m.test(src)) src = `${src.replace(/\s*$/, '')}\n\n## Comments\n`
    const day = new Date().toISOString().slice(0, 10)
    const who = body.anchor ? `human, ${body.anchor}` : 'human'
    const lines = text.split('\n')
    const bullet = `- ${day} (${who}): ${lines[0]}\n` + lines.slice(1).map((l) => `  ${l}`).join('\n')
    await fsp.writeFile(full, `${src.replace(/\s*$/, '')}\n${bullet.replace(/\s*$/, '')}\n`)
    return { ok: true }
  },
}

// ----------------------------------------------------------------- server

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const json = (code, obj) => {
    res.writeHead(code, { 'content-type': MIME['.json'], 'cache-control': 'no-store' })
    res.end(JSON.stringify(obj))
  }

  // The server listens on loopback, but that alone doesn't stop a hostile web
  // page: DNS rebinding defeats the address check, and a text/plain POST needs
  // no CORS preflight. So refuse foreign Host headers outright, and require
  // application/json on every mutation — that forces a preflight no cross-origin
  // page can pass, since we never answer OPTIONS.
  const host = String(req.headers.host || '').replace(/:\d+$/, '')
  if (!['localhost', '127.0.0.1', '[::1]'].includes(host)) {
    return json(403, { error: `refusing host ${host} — this server only answers as localhost` })
  }

  if (url.pathname === '/api/spec') {
    try {
      json(200, await buildPayload(url.searchParams.get('slug') || INITIAL))
    } catch (e) {
      json(e.status || 500, { error: String(e.message || e) })
    }
    return
  }

  if (url.pathname === '/api/specs') {
    try { json(200, { specsDir: SPECS_DIR, initial: INITIAL, specs: await specSummaries() }) }
    catch (e) { json(500, { error: String(e.message || e) }) }
    return
  }

  if (url.pathname === '/api/attempt') {
    try {
      const dir = dirFor(url.searchParams.get('slug'))
      json(200, await readAttemptBody(dir, url.searchParams.get('name') || ''))
    } catch (e) {
      json(e.status || 500, { error: String(e.message || e) })
    }
    return
  }

  if (req.method === 'POST' && MUTATIONS[url.pathname]) {
    try {
      if (!/^application\/json\b/.test(String(req.headers['content-type'] || ''))) {
        throw Object.assign(new Error('mutations require content-type: application/json'), { status: 415 })
      }
      json(200, await MUTATIONS[url.pathname](await readBody(req)))
    } catch (e) {
      json(e.status || 500, { error: String(e.message || e), status: e.status || 500 })
    }
    return
  }

  if (url.pathname === '/api/events') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-store',
      connection: 'keep-alive',
    })
    res.write('retry: 1000\n\n')
    clients.add(res)
    req.on('close', () => clients.delete(res))
    return
  }

  // Static assets, path-traversal guarded.
  const rel = url.pathname === '/' ? 'index.html' : decodeURIComponent(url.pathname).replace(/^\/+/, '')
  const file = path.join(PUBLIC, rel)
  if (!file.startsWith(PUBLIC + path.sep)) { res.writeHead(403); res.end('forbidden'); return }
  try {
    const body = await fsp.readFile(file)
    res.writeHead(200, {
      'content-type': MIME[path.extname(file)] || 'application/octet-stream',
      'cache-control': 'no-store',
    })
    res.end(body)
  } catch {
    res.writeHead(404, { 'content-type': 'text/plain' })
    res.end('not found')
  }
})

function listen (p, attemptsLeft = 20) {
  server.once('error', (e) => {
    if (e.code === 'EADDRINUSE' && attemptsLeft > 0) listen(p + 1, attemptsLeft - 1)
    else die(e.message)
  })
  server.listen(p, '127.0.0.1', () => {
    const url = `http://localhost:${server.address().port}`
    process.stdout.write(`SpectroVision  ${SPECS_DIR}  (${listSlugs().length} spec${listSlugs().length === 1 ? '' : 's'})\n               ${url}\n`)
    if (openBrowser && process.platform === 'darwin') execFile('open', [url], () => {})
    else if (openBrowser && process.platform === 'linux') execFile('xdg-open', [url], () => {})
  })
}

listen(port)
