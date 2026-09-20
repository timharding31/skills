// Dependency graph: a layered left-to-right DAG built from issue.blocked_by.
// Layer = longest path from a root, which keeps every edge pointing forward.

import { esc } from './md.js'

const COLORS = {
  done: { stroke: '#9ece6a', fill: '#1e2b24', text: '#9ece6a' },
  claimed: { stroke: '#e0af68', fill: '#2b2618', text: '#e0af68' },
  ready: { stroke: '#7aa2f7', fill: '#1b2440', text: '#7aa2f7' },
  blocked: { stroke: '#414868', fill: '#1f2335', text: '#787f9c' },
}

const NODE_W = 240
const NODE_H = 54
const GAP_X = 70
const GAP_Y = 26
const PAD = 16
const CHAR_W = 7.3 // ballpark mono advance at 12px — the labels truncate to fit

export function layout (issues, effectiveStatus) {
  const byId = new Map(issues.map((it) => [it.id, it]))
  const depth = new Map()

  const compute = (id, seen = new Set()) => {
    if (depth.has(id)) return depth.get(id)
    if (seen.has(id)) return 0 // cycle guard: the validator already rejects these
    seen.add(id)
    const it = byId.get(id)
    const deps = (it && it.blocked_by) || []
    const d = deps.length ? Math.max(...deps.map((b) => (byId.has(b) ? compute(b, seen) + 1 : 0))) : 0
    depth.set(id, d)
    return d
  }
  issues.forEach((it) => compute(it.id))

  const cols = []
  issues.forEach((it) => {
    const d = depth.get(it.id) || 0
    ;(cols[d] || (cols[d] = [])).push(it)
  })

  const pos = new Map()
  const colHeights = cols.map((c) => c.length * NODE_H + (c.length - 1) * GAP_Y)
  const tallest = Math.max(...colHeights, NODE_H)
  cols.forEach((col, ci) => {
    const offset = (tallest - colHeights[ci]) / 2
    col.forEach((it, ri) => {
      pos.set(it.id, {
        x: PAD + ci * (NODE_W + GAP_X),
        y: PAD + offset + ri * (NODE_H + GAP_Y),
        issue: it,
        status: effectiveStatus(it),
      })
    })
  })

  return {
    pos,
    width: PAD * 2 + cols.length * NODE_W + Math.max(0, cols.length - 1) * GAP_X,
    height: PAD * 2 + tallest,
  }
}

// An edge that a longer path already implies (01→03 when 01→02→03 exists) is
// visual noise, not information — the transitive reduction is the readable
// graph. Ancestors = every transitive blocker, memoized.
function ancestorsOf (byId) {
  const memo = new Map()
  const walk = (id, seen = new Set()) => {
    if (memo.has(id)) return memo.get(id)
    if (seen.has(id)) return new Set()
    seen.add(id)
    const out = new Set()
    const it = byId.get(id)
    for (const b of (it && it.blocked_by) || []) {
      out.add(b)
      for (const a of walk(b, seen)) out.add(a)
    }
    memo.set(id, out)
    return out
  }
  return walk
}

export function renderGraph (issues, effectiveStatus, selectedId) {
  if (!issues.length) return '<p class="empty">no issues in this spec</p>'
  const { pos, width, height } = layout(issues, effectiveStatus)
  const byId = new Map(issues.map((it) => [it.id, it]))
  const ancestors = ancestorsOf(byId)

  const kept = []
  for (const it of issues) {
    const deps = (it.blocked_by || []).filter((d) => pos.get(d))
    for (const dep of deps) {
      if (deps.some((x) => x !== dep && ancestors(x).has(dep))) continue
      kept.push({ from: dep, to: it.id })
    }
  }

  // Fan the surviving edges across each node's edge instead of stacking them
  // all on the vertical midpoint — a node with three arrows in gets three
  // distinct entry ports.
  const port = (list, id, other, side) => {
    const mine = list.filter((e) => e[side] === id)
    mine.sort((p, q) => pos.get(p[side === 'from' ? 'to' : 'from']).y - pos.get(q[side === 'from' ? 'to' : 'from']).y)
    const i = mine.findIndex((e) => e[side === 'from' ? 'to' : 'from'] === other)
    return pos.get(id).y + (NODE_H * (i + 1)) / (mine.length + 1)
  }

  const edges = kept.map(({ from, to }) => {
    const a = pos.get(from)
    const b = pos.get(to)
    const x1 = a.x + NODE_W
    const y1 = port(kept, from, to, 'from')
    const x2 = b.x
    const y2 = port(kept, to, from, 'to')
    const mid = (x1 + x2) / 2
    const hot = selectedId && (to === selectedId || from === selectedId)
    return `<path d="M${x1} ${y1} C ${mid} ${y1}, ${mid} ${y2}, ${x2 - 2} ${y2}"
      fill="none" stroke="${hot ? '#7aa2f7' : '#3b4261'}" stroke-width="${hot ? 1.8 : 1.2}"
      marker-end="url(#arrow${hot ? '-hot' : ''})" />`
  })

  const fit = (s, px, reserve = 0) => {
    const max = Math.floor((NODE_W - 28) / px) - reserve
    return s.length > max ? s.slice(0, max - 1) + '…' : s
  }

  const nodes = []
  let n = 0
  for (const it of issues) {
    const p = pos.get(it.id)
    if (!p) continue
    n++
    const c = COLORS[p.status] || COLORS.blocked
    const sel = it.id === selectedId
    nodes.push(`<g class="node" data-issue="${esc(it.id)}" style="cursor:pointer">
      <rect x="${p.x}" y="${p.y}" width="${NODE_W}" height="${NODE_H}" rx="6"
        fill="${c.fill}" stroke="${sel ? '#7aa2f7' : '#3b4261'}" stroke-width="${sel ? 1.6 : 1}" />
      <rect x="${p.x}" y="${p.y + 1}" width="3" height="${NODE_H - 2}" rx="1.5" fill="${c.stroke}" />
      <text x="${p.x + 14}" y="${p.y + 21}" fill="${c.text}" font-size="12" font-weight="700">${esc(String(n).padStart(2, '0'))} ${esc(fit(it.id, CHAR_W, 3))}</text>
      <text x="${p.x + 14}" y="${p.y + 39}" fill="#787f9c" font-size="11">${esc(fit(it.title, 6.7))}</text>
    </g>`)
  }

  return `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
    <defs>
      <marker id="arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
        <path d="M0 0 L8 4 L0 8 z" fill="#3b4261" />
      </marker>
      <marker id="arrow-hot" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
        <path d="M0 0 L8 4 L0 8 z" fill="#7aa2f7" />
      </marker>
    </defs>
    ${edges.join('\n')}
    ${nodes.join('\n')}
  </svg>`
}
