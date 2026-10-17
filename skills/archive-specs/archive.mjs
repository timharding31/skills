#!/usr/bin/env node
// Plans and performs spec archiving for the archive-specs skill.
//   archive.mjs plan [--age N] [--specs DIR]
//   archive.mjs move [--specs DIR] <slug>...
// `plan` prints JSON and touches nothing. `move` marks any unfinished issue
// done, moves specs/<slug> to specs/archive/<slug>, and rewrites
// `specs/<slug>` paths in specs/README.md.
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const argv = process.argv.slice(2)
const cmd = argv.shift()
const flag = (name, fallback) => {
  const i = argv.indexOf(name)
  if (i === -1) return fallback
  return argv.splice(i, 2)[1]
}
const age = Number(flag('--age', '1'))
const specsDir = path.resolve(flag('--specs', 'specs'))
const DAY = 86_400_000
const WRAP_UP = new Set(['quality-review', 'deslop', 'ship-pr'])

const die = (msg) => { console.error(msg); process.exit(1) }
if (!Number.isFinite(age) || age < 0) die(`--age must be a number of days, got ${age}`)
if (!fs.existsSync(specsDir)) die(`no such directory: ${specsDir}`)

const readSpec = (slug) => {
  const file = path.join(specsDir, slug, 'spec.json')
  return { file, spec: JSON.parse(fs.readFileSync(file, 'utf8')) }
}

function runningSlugs () {
  let ps = ''
  try { ps = execFileSync('ps', ['-Ao', 'args='], { encoding: 'utf8' }) } catch { return new Set() }
  const live = new Set()
  for (const line of ps.split('\n')) {
    if (!/loop(-once)?\.sh/.test(line)) continue
    for (const m of line.matchAll(/specs\/([A-Za-z0-9._-]+)/g)) live.add(m[1])
  }
  return live
}

function plan () {
  const now = Date.now()
  const live = runningSlugs()
  const out = { specsDir, age, archive: [], ask: [], skipped: [] }
  for (const slug of fs.readdirSync(specsDir).sort()) {
    if (slug === 'archive' || slug.startsWith('.')) continue
    const dir = path.join(specsDir, slug)
    if (!fs.existsSync(path.join(dir, 'spec.json'))) continue
    let spec, file
    try { ({ spec, file } = readSpec(slug)) } catch { out.skipped.push({ slug, reason: 'spec.json does not parse' }); continue }
    const issues = spec.issues || []
    if (!issues.length) { out.skipped.push({ slug, reason: 'no issues yet, awaiting /to-issues' }); continue }
    if (live.has(slug)) { out.skipped.push({ slug, reason: 'loop.sh is running' }); continue }

    const ledgerTimes = (spec.ledger || []).map((l) => Date.parse(l.at)).filter(Boolean)
    const lastMs = ledgerTimes.length ? Math.max(...ledgerTimes) : fs.statSync(file).mtimeMs
    const ageDays = (now - lastMs) / DAY
    const entry = { slug, title: spec.title || slug, lastActivity: new Date(lastMs).toISOString(), ageDays: Math.round(ageDays * 10) / 10 }
    const open = issues.filter((i) => i.status !== 'done')

    if (ageDays < age) { out.skipped.push({ slug, reason: `last activity ${entry.ageDays} days ago, under --age ${age}` }); continue }
    if (!open.length) { out.archive.push(entry); continue }
    out.ask.push({
      ...entry,
      done: issues.length - open.length,
      total: issues.length,
      open: open.map((i) => ({ id: i.id, status: i.status })),
      onlyWrapUpLeft: open.every((i) => WRAP_UP.has(i.id)),
    })
  }
  return out
}

const isTracked = (dir) => {
  try { execFileSync('git', ['ls-files', '--error-unmatch', dir], { cwd: path.dirname(dir), stdio: 'ignore' }); return true } catch { return false }
}

function move (slugs) {
  if (!slugs.length) die('move needs at least one slug')
  const archiveDir = path.join(specsDir, 'archive')
  fs.mkdirSync(archiveDir, { recursive: true })
  const moved = []
  for (const slug of slugs) {
    const from = path.join(specsDir, slug)
    const to = path.join(archiveDir, slug)
    if (!fs.existsSync(path.join(from, 'spec.json'))) die(`not a spec: ${from}`)
    if (fs.existsSync(to)) die(`already archived: ${to}`)

    const { file, spec } = readSpec(slug)
    let marked = 0
    for (const issue of spec.issues || []) {
      if (issue.status === 'done') continue
      issue.status = 'done'
      delete issue.claim_sha
      marked++
    }
    if (marked) fs.writeFileSync(file, JSON.stringify(spec, null, 2) + '\n')

    if (isTracked(from)) execFileSync('git', ['mv', from, to], { cwd: path.dirname(from) })
    else fs.renameSync(from, to)
    moved.push({ slug, markedDone: marked })
  }
  return { moved, readme: fixReadme(slugs), otherReferences: otherReferences(slugs) }
}

function fixReadme (slugs) {
  const file = path.join(specsDir, 'README.md')
  if (!fs.existsSync(file)) return { rewritten: 0 }
  let text = fs.readFileSync(file, 'utf8')
  let rewritten = 0
  for (const slug of slugs) {
    const re = new RegExp(`(?<![\\w/-])specs/${slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\w-])`, 'g')
    text = text.replace(re, () => { rewritten++; return `specs/archive/${slug}` })
  }
  if (rewritten) fs.writeFileSync(file, text)
  return { rewritten }
}

// Paths elsewhere in the repo that still point at the old location. Reported,
// never edited.
function otherReferences (slugs) {
  const hits = []
  const root = path.dirname(specsDir)
  for (const slug of slugs) {
    let out = ''
    try {
      out = execFileSync('git', ['grep', '-nE', `specs/${slug}([^A-Za-z0-9_-]|$)`, '--', '.', ':!specs/README.md'], { cwd: root, encoding: 'utf8' })
    } catch { continue }
    for (const line of out.split('\n').filter(Boolean)) if (!line.includes(`specs/archive/${slug}`)) hits.push(line)
  }
  return hits
}

if (cmd === 'plan') console.log(JSON.stringify(plan(), null, 2))
else if (cmd === 'move') console.log(JSON.stringify(move(argv), null, 2))
else die('usage: archive.mjs plan [--age N] | move <slug>... [--specs DIR]')
