import { md, esc } from './md.js'
import { renderGraph } from './graph.js'

// --------------------------------------------------------------- state

const state = {
  data: null,          // payload for the open spec
  slug: null,
  view: 'overview',
  issueId: null,
  dock: 'specs',       // right dock tab: specs | detail
  editing: null,       // issue id in field-edit mode
  editingBody: false,  // true (issue body) | 'notes' | 'context'
  connected: false,
  saving: false,
  error: null,
  dirty: false,        // an open editor has unsaved keystrokes
  lastFlash: 0,
}

const $ = (sel) => document.querySelector(sel)
const main = () => $('#main')

const STATUS_GLYPH = { done: '✔', claimed: '◐', ready: '○', blocked: '○' }
const STATUSES = ['done', 'claimed', 'ready', 'blocked']

function issues () { return (state.data && state.data.spec && state.data.spec.issues) || [] }
function issueById (id) { return issues().find((i) => i.id === id) || null }

// The board's notion of an issue's real state: spec status, plus "blocked" when
// a dependency is still open.
function effStatus (it) {
  if (it.status === 'done') return 'done'
  if (it.status === 'claimed') return 'claimed'
  const open = (it.blocked_by || []).filter((b) => {
    const d = issueById(b)
    return d && d.status !== 'done'
  })
  return open.length ? 'blocked' : 'ready'
}

// The frontier: exactly the issue loop.sh will pick next — first in array
// order that is not done and whose blockers are all done. A claimed issue
// qualifies: a killed run's leftover is re-picked before anything ready.
function nextUp () {
  const it = issues().find((i) => i.status !== 'done' &&
    (i.blocked_by || []).every((b) => { const d = issueById(b); return d && d.status === 'done' }))
  return it ? it.id : null
}

function ledgerFor (id) {
  return ((state.data.spec && state.data.spec.ledger) || []).filter((l) => l.id === id)
}
function attemptsFor (id) {
  return (state.data.attempts || []).filter((a) => a.issueId === id)
}

function relTime (ms) {
  if (!ms) return ''
  const s = Math.max(0, Math.round((Date.now() - ms) / 1000))
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.round(s / 60)}m ago`
  if (s < 86400) return `${Math.round(s / 3600)}h ago`
  return `${Math.round(s / 86400)}d ago`
}

// ------------------------------------------------------------------ io

async function load () {
  const res = await fetch(`/api/spec${state.slug ? `?slug=${encodeURIComponent(state.slug)}` : ''}`)
  const json = await res.json()
  if (!res.ok) { state.error = json.error; renderStamp(); return }
  state.data = json
  state.slug = json.slug
  state.error = null
  render()
}

async function post (url, body) {
  state.saving = true
  renderStamp()
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ slug: state.slug, specMtime: state.data.specMtime, ...body }),
    })
    const json = await res.json()
    if (!res.ok) throw new Error(json.error || `HTTP ${res.status}`)
    state.error = null
    await load()
    return json
  } catch (e) {
    state.error = String(e.message || e)
    render()
    throw e
  } finally {
    state.saving = false
    renderStamp()
  }
}

// The two locks the server enforces, mirrored here so the page never offers an
// edit the write would refuse. Commenting is outside both.
function runLive () {
  const run = state.data && state.data.run
  return !!(run && run.running)
}
function frozen (it) { return !!it && (it.status === 'claimed' || it.status === 'done') }
function editable (it) { return !runLive() && !frozen(it) }

// Why the edit affordances are gone, in the words the server would use.
function lockNote (it) {
  if (runLive()) {
    return `◐ loop.sh is running (pid ${state.data.run.pid}) — a comment is the only edit that lands until it stops.
      Everything else is reverted mid-iteration and recorded as a failed attempt against the agent.`
  }
  if (frozen(it)) {
    return `✔ ${esc(it.id)} is ${it.status} — its fields and ticket body are the agent's record now. Comment on it instead.`
  }
  return ''
}

function connect () {
  const es = new EventSource('/api/events')
  let hadOpened = false
  es.onopen = () => {
    state.connected = true
    renderStamp()
    // A reconnect (sleep, server restart) missed every change event in between.
    if (hadOpened && !state.editing && !state.editingBody) load()
    hadOpened = true
  }
  es.onerror = () => { state.connected = false; renderStamp() }
  es.addEventListener('change', () => {
    // Don't stomp an open editor — the change will still be there afterwards.
    if (state.editing || state.editingBody) { renderStamp(); return }
    load().then(() => {
      // Throttled: a hot run fires changes every fingerprint tick, and a
      // constant strobe reads as noise, not signal.
      if (Date.now() - state.lastFlash < 2500) return
      state.lastFlash = Date.now()
      main().classList.remove('flash')
      void main().offsetWidth
      main().classList.add('flash')
    })
  })
}

// -------------------------------------------------------------- routing

function readHash () {
  const h = decodeURIComponent(location.hash.replace(/^#/, ''))
  const parts = h.split('/').filter(Boolean)
  if (!parts.length) return
  state.slug = parts[0]
  const rest = parts.slice(1)
  if (rest[0] === 'issue' && rest[1]) { state.view = 'issue'; state.issueId = rest.slice(1).join('/'); state.dock = 'detail' }
  else { state.view = rest[0] || 'overview'; state.issueId = null }
}

function href (view, id) {
  const slug = encodeURIComponent(state.slug || '')
  return id ? `#${slug}/issue/${encodeURIComponent(id)}` : `#${slug}/${view}`
}
function go (view, id) { location.hash = href(view, id) }
function goSpec (slug) { location.hash = `#${encodeURIComponent(slug)}/overview` }

let revertingHash = false
window.addEventListener('hashchange', async (e) => {
  if (revertingHash) { revertingHash = false; return }
  if ((state.editing || state.editingBody) && state.dirty && !confirm('Discard unsaved edits?')) {
    revertingHash = true
    location.hash = new URL(e.oldURL).hash
    return
  }
  const before = state.slug
  state.editing = null
  state.editingBody = false
  state.dirty = false
  readHash()
  if (state.view === 'issue') state.dock = 'detail'
  if (state.slug !== before) await load()
  else render()
  // The window scrolls, not #main — the rail and dock are sticky beside it.
  window.scrollTo({ top: 0 })
})

// Any keystroke in the issue form or a body editor arms the discard confirm.
document.addEventListener('input', (e) => {
  if (e.target.closest('section.card.editing, [data-body-editor]')) state.dirty = true
})

// ------------------------------------------------------------- rendering

function render () {
  if (!state.data) return
  const d = state.data
  const spec = d.spec || {}

  $('#slug').textContent = spec.slug || d.slug
  $('#title').textContent = spec.title || (d.parseError ? 'unparsed spec.json' : '')
  $('#specpath').textContent = d.specPath

  const list = issues()
  const done = list.filter((i) => i.status === 'done').length
  const pct = list.length ? Math.round((done / list.length) * 100) : 0
  $('#fill').style.width = `${pct}%`
  $('#pct').textContent = `${pct}%`
  $('#count').textContent = `${done}/${list.length}`

  const badge = $('#attempt-badge')
  badge.textContent = (d.attempts || []).length || ''
  badge.style.display = (d.attempts || []).length ? '' : 'none'

  renderStamp()
  renderRail()
  const cap = captureMain()
  renderMain()
  restoreMain(cap)
  renderDock()
}

// renderMain rebuilds #main wholesale, and SSE changes arrive mid-keystroke
// during a live run — exactly when comments are being written. Carry the
// comment draft (value, focus, selection, anchor) and every open fold across
// the rebuild so a disk change never eats human input.
function captureMain () {
  const cap = { folds: [], comment: null }
  cap.folds = [...main().querySelectorAll('details[data-fold][open]')].map((d) => d.dataset.fold)
  const box = $('#comment-box')
  if (box && (box.value || document.activeElement === box)) {
    cap.comment = {
      issue: box.dataset.for,
      value: box.value,
      anchor: box.dataset.anchor || null,
      placeholder: box.placeholder,
      focused: document.activeElement === box,
      selStart: box.selectionStart,
      selEnd: box.selectionEnd,
    }
  }
  return cap
}

function restoreMain (cap) {
  for (const key of cap.folds) {
    const d = main().querySelector(`details[data-fold="${CSS.escape(key)}"]`)
    if (d) d.open = true
  }
  const box = $('#comment-box')
  if (cap.comment && box && box.dataset.for === cap.comment.issue) {
    box.value = cap.comment.value
    if (cap.comment.anchor) { box.dataset.anchor = cap.comment.anchor; box.placeholder = cap.comment.placeholder }
    if (cap.comment.focused) {
      box.focus()
      box.setSelectionRange(cap.comment.selStart, cap.comment.selEnd)
    }
  }
}

function renderStamp () {
  const d = state.data
  if (!d) return
  const pill = $('#runpill')
  const text = $('#runtext')
  pill.className = 'runpill'
  if (!state.connected) { pill.classList.add('lost'); text.textContent = 'disconnected' }
  else if (d.run && d.run.running) { pill.classList.add('live'); text.textContent = `loop running · ${d.run.elapsed}` }
  else { text.textContent = 'idle' }
  $('#killrun').style.display = state.connected && d.run && d.run.running ? '' : 'none'

  const bits = []
  if (state.saving) bits.push('saving…')
  if (state.error) bits.push(`⚠ ${state.error}`)
  bits.push(`spec.json ${relTime(d.specMtime)}`)
  $('#stamp').textContent = bits.join('  ·  ')
  $('#stamp').style.color = state.error ? 'var(--red)' : ''
}

function renderRail () {
  document.querySelectorAll('.rail-item').forEach((el) => {
    el.classList.toggle('active', el.dataset.view === state.view)
    el.setAttribute('href', href(el.dataset.view))
  })
  const next = nextUp()
  const idle = !runLive()
  const last = issues().length - 1
  $('#issue-list').innerHTML = issues().map((it, i) => {
    const st = effStatus(it)
    const failed = (it.attempts || []).length
    return `<div class="issue-row ${st} ${it.id === state.issueId ? 'active' : ''}" data-issue="${esc(it.id)}">
      <span class="st-${st}">${st === 'claimed' ? '<span class="spin">◐</span>' : STATUS_GLYPH[st]}</span>
      <span class="num">${String(i + 1).padStart(2, '0')}</span>
      <span class="nm" title="${esc(it.title)}">${esc(it.id)}${failed ? ' <span class="st-failed">⚑</span>' : ''}${it.id === next ? ' <span class="next-tag" title="what loop.sh picks next — first issue not done with every blocker done">next</span>' : ''}</span>
      ${idle ? `<span class="reorder">${i > 0 ? `<button data-move="${esc(it.id)}:-1" title="move up — array order is priority order">▲</button>` : ''}${i < last ? `<button data-move="${esc(it.id)}:1" title="move down">▼</button>` : ''}</span>` : ''}
    </div>`
  }).join('') +
    (runLive() ? '' : '<div class="issue-row" data-new="1"><span class="st-ready">＋</span><span class="num"></span><span class="nm">new issue</span></div>')
}

function renderMain () {
  const v = state.view
  if (v === 'issue') return renderIssue()
  if (v === 'graph') return renderGraphView()
  if (v === 'context') return renderDoc('context.md', state.data.context, 'context', state.data.contextMtime)
  if (v === 'notes') return renderDoc('NOTES.md', state.data.notes, 'notes', state.data.notesMtime)
  if (v === 'ledger') return renderLedger()
  if (v === 'attempts') return renderAttempts()
  return renderOverview()
}

// --------------------------------------------------------- the right dock

function renderDock () {
  const d = state.data
  const tabs = `<div class="dock-tabs">
    <button class="dock-tab ${state.dock === 'specs' ? 'on' : ''}" data-dock="specs">specs</button>
    <button class="dock-tab ${state.dock === 'detail' ? 'on' : ''}" data-dock="detail">details</button>
  </div>`
  $('#dock').innerHTML = tabs + (state.dock === 'specs' ? specBrowser() : dockDetail())
}

function specBrowser () {
  const specs = (state.data.specs || [])
  return `<div class="dock-body">
    <div class="dock-head">${esc(state.data.specsDir)}</div>
    ${specs.map((s) => {
      const pct = s.total ? Math.round((s.done / s.total) * 100) : 0
      const live = s.run && s.run.running
      return `<div class="spec-card ${s.slug === state.slug ? 'on' : ''}" data-spec="${esc(s.slug)}">
        <div class="spec-top">
          <span class="spec-name">${esc(s.slug)}</span>
          ${live ? '<span class="live-dot" title="loop.sh running"></span>' : ''}
        </div>
        <div class="spec-title">${esc(s.broken ? 'spec.json will not parse' : s.title)}</div>
        <div class="bar mini"><div class="fill" style="width:${pct}%"></div></div>
        <div class="spec-meta">${s.done}/${s.total} done${s.claimed ? ` · ${s.claimed} claimed` : ''} · ${relTime(s.mtime)}</div>
      </div>`
    }).join('')}
  </div>`
}

function dockDetail () {
  const it = state.view === 'issue' ? issueById(state.issueId) : null
  if (!it) {
    const spec = state.data.spec || {}
    const list = issues()
    const counts = list.reduce((a, x) => { const s = effStatus(x); a[s] = (a[s] || 0) + 1; return a }, {})
    return `<div class="dock-body">
      <section class="card"><h2>this spec</h2>
        <div class="chips">${STATUSES.filter((s) => counts[s])
          .map((s) => `<span class="pill ${s}">${STATUS_GLYPH[s]} ${counts[s]} ${s}</span>`).join('')}</div>
        <div class="dim" style="margin-top:8px">${esc(state.data.dir)}</div>
      </section>
      ${spec.verification && spec.verification.length ? `<section class="card"><h2>verification</h2>
        <ul class="plain verify">${spec.verification.map((v) => `<li><code class="inline">${esc(v)}</code></li>`).join('')}</ul>
      </section>` : ''}
      <section class="card"><h2>keys</h2>
        <div class="keys"><kbd>⌘K</kbd> jump · <kbd>j</kbd>/<kbd>k</kbd> issues · <kbd>e</kbd> edit ·
        <kbd>⌘/</kbd> comment · <kbd>⌘⏎</kbd> save</div>
      </section>
    </div>`
  }

  const led = ledgerFor(it.id)
  const blockers = (it.blocked_by || []).map((b) => {
    const dep = issueById(b)
    return `<span class="chip" data-issue="${esc(b)}"><span class="st-${dep ? effStatus(dep) : 'failed'}">${dep ? STATUS_GLYPH[effStatus(dep)] : '✖'}</span>${esc(b)}</span>`
  }).join('')
  const blocks = issues().filter((x) => (x.blocked_by || []).includes(it.id))
    .map((x) => `<span class="chip" data-issue="${esc(x.id)}"><span class="st-${effStatus(x)}">${STATUS_GLYPH[effStatus(x)]}</span>${esc(x.id)}</span>`).join('')

  return `<div class="dock-body">
    <section class="card"><h2>blocked by</h2><div class="chips">${blockers || '<span class="empty">nothing</span>'}</div></section>
    ${blocks ? `<section class="card"><h2>blocks</h2><div class="chips">${blocks}</div></section>` : ''}
    ${it.files && it.files.length ? `<section class="card"><h2>files in play</h2>
      <ul class="plain files">${it.files.map((f) => `<li>${esc(f)}</li>`).join('')}</ul></section>` : ''}
    ${it.verification && it.verification.length ? `<section class="card"><h2>extra verification</h2>
      <ul class="plain verify">${it.verification.map((v) => `<li><code class="inline">${esc(v)}</code></li>`).join('')}</ul></section>` : ''}
    ${it.claim_sha ? `<section class="card"><h2>claimed from</h2>${commitBlock(it.claim_sha)}</section>` : ''}
    ${led.map((l) => `<section class="card"><h2>delivered</h2>
      <div class="md">${md(l.outcome || '')}</div>
      <div class="when dim">${esc(l.at || '')}</div>
      ${l.commit ? commitBlock(l.commit) : ''}</section>`).join('')}
  </div>`
}

// ------------------------------------------------------------- main views

function bulletCard (title, items) {
  if (!items || !items.length) return ''
  return `<section class="card"><h2>${esc(title)}</h2>
    <ul class="plain">${items.map((x) => `<li>${md(x).replace(/^<p>|<\/p>$/g, '')}</li>`).join('')}</ul>
  </section>`
}

function renderOverview () {
  const d = state.data
  const spec = d.spec || {}
  if (d.parseError) {
    main().innerHTML = `<h1 class="view">spec.json will not parse</h1>
      <pre class="block" style="color:var(--red)">${esc(d.parseError)}</pre>`
    return
  }
  const list = issues()
  const counts = list.reduce((a, it) => { const s = effStatus(it); a[s] = (a[s] || 0) + 1; return a }, {})

  const editing = state.editingBody === 'meta' && !runLive()
  main().innerHTML = `
    <div class="issue-head">
      <div>
        <h1 class="view">${esc(spec.title || spec.slug)}</h1>
        <div class="subhead">${esc(spec.slug || d.slug)} · schema v${esc(spec.schema_version || '?')} · ${list.length} issues${d.repo ? ` · ${esc(d.repo)}` : ''}</div>
      </div>
      <div class="chips">${runLive() ? '' : `<button class="chip" data-act="${editing ? 'cancel-meta' : 'edit-meta'}">${editing ? 'cancel' : 'edit spec fields'}</button>`}</div>
    </div>

    <div class="chips" style="margin-bottom:16px">
      ${STATUSES.filter((s) => counts[s]).map((s) =>
        `<span class="pill ${s}">${STATUS_GLYPH[s]} ${counts[s]} ${s}</span>`).join('')}
      ${d.run && d.run.running ? `<span class="pill claimed">● loop pid ${d.run.pid}</span>` : ''}
      ${nextUp() ? `<span class="pill ready" title="what loop.sh picks next — first issue not done with every blocker done">▸ next: ${esc(nextUp())}</span>` : ''}
    </div>

    ${editing ? metaForm(spec) : `
    <section class="card"><h2>summary</h2><div class="md">${md(spec.summary || '')}</div></section>
    ${bulletCard('invariants', spec.invariants)}
    ${bulletCard('out of scope', spec.out_of_scope)}
    ${bulletCard('open questions', spec.open_questions)}`}
  `
}

// The spec-level fields are the durable context re-injected into every
// iteration — an edit here is a planning edit, same locks as the board.
function metaForm (spec) {
  const lines = (a) => esc((a || []).join('\n'))
  return `<section class="card editing">
    <h2>edit spec fields · writes spec.json</h2>
    <div class="form">
      <label class="wide">title<input data-m="title" value="${esc(spec.title || '')}"></label>
      <label class="wide">summary<textarea data-m="summary" style="height:16vh">${esc(spec.summary || '')}</textarea></label>
      <label class="wide">invariants <span class="dim">— one per line</span>
        <textarea data-m="invariants">${lines(spec.invariants)}</textarea></label>
      <label class="wide">out of scope <span class="dim">— one per line</span>
        <textarea data-m="out_of_scope">${lines(spec.out_of_scope)}</textarea></label>
      <label class="wide">open questions <span class="dim">— one per line</span>
        <textarea data-m="open_questions">${lines(spec.open_questions)}</textarea></label>
      <label class="wide">verification <span class="dim">— one command per line, run after every DONE</span>
        <textarea data-m="verification">${lines(spec.verification)}</textarea></label>
    </div>
    <div class="row-actions">
      <button class="chip" data-act="save-meta">save <kbd>⌘⏎</kbd></button>
      <button class="chip" data-act="cancel-meta">cancel <kbd>esc</kbd></button>
    </div>
  </section>`
}

async function saveMeta () {
  if (runLive()) return
  const val = (f) => main().querySelector(`[data-m="${f}"]`).value
  const arr = (f) => {
    const l = val(f).split('\n').map((s) => s.trim()).filter(Boolean)
    return l.length ? l : null
  }
  await post('/api/spec/meta', {
    patch: {
      title: val('title').trim() || null,
      summary: val('summary').trim(),
      invariants: arr('invariants'),
      out_of_scope: arr('out_of_scope'),
      open_questions: arr('open_questions'),
      verification: arr('verification'),
    },
  })
  state.editingBody = false
  state.dirty = false
  render()
}

function renderIssue () {
  const it = issueById(state.issueId)
  if (!it) { main().innerHTML = '<p class="empty">no such issue</p>'; return }
  const st = effStatus(it)
  const body = it.body ? state.data.bodies[it.body] : null
  const atts = it.attempts || []
  const logs = attemptsFor(it.id)
  const idx = issues().findIndex((x) => x.id === it.id)

  main().innerHTML = `
    <div class="issue-head">
      <div>
        <h1 class="view">${String(idx + 1).padStart(2, '0')} · ${esc(it.title)}</h1>
        <div class="subhead">${esc(it.id)}${it.body ? ` · ${esc(it.body)}` : ''}</div>
      </div>
      <div class="chips">
        <span class="pill ${st}">${STATUS_GLYPH[st]} ${st}</span>
        ${it.model ? `<span class="pill model">◈ ${esc(it.model)}</span>` : ''}
        ${editable(it) ? '<button class="chip" data-act="edit">edit <kbd>e</kbd></button>' : ''}
      </div>
    </div>

    ${editable(it) ? '' : `<div class="warn lock">${lockNote(it)}</div>`}

    ${state.editing === it.id && editable(it) ? editForm(it) : ''}

    <section class="card"><h2>acceptance criteria</h2>
      ${(it.criteria || []).map((c, i) => `<div class="crit ${st === 'done' ? 'pass' : ''}">
        <span class="mark">${st === 'done' ? '✔' : '○'}</span>
        <span>${md(c).replace(/^<p>|<\/p>$/g, '')}
          <button class="crit-comment" data-comment-crit="${i}" title="comment on this criterion">⌘/</button></span>
      </div>`).join('') || '<p class="empty">none</p>'}
    </section>

    ${body != null ? `<section class="card"><h2>ticket body — ${esc(it.body)}
        ${editable(it) ? '<button class="chip" data-act="edit-body" style="float:right;text-transform:none;letter-spacing:0">edit</button>' : ''}</h2>
      ${state.editingBody === true && editable(it)
        ? `<textarea class="editor" data-body-editor style="height:52vh">${esc(body)}</textarea>
           <div class="row-actions"><button class="chip" data-act="save-body">save <kbd>⌘⏎</kbd></button>
           <button class="chip" data-act="cancel-body">cancel</button></div>`
        : `<div class="md">${md(body)}</div>`}
    </section>` : ''}

    <section class="card"><h2>comment · lands in the agent's next context</h2>
      <textarea class="editor" id="comment-box" data-for="${esc(it.id)}" placeholder="Feedback for the next iteration. Appended under ## Comments in ${esc(it.body || 'the ticket body')}, which loop.sh replays into the prompt."></textarea>
      <div class="row-actions"><button class="chip" data-act="comment">append comment <kbd>⌘⏎</kbd></button></div>
    </section>

    ${atts.length ? `<section class="card"><h2>failed attempts — replayed into the next prompt</h2>
      ${atts.map((a, i) => `<details class="fold" data-fold="att-${esc(it.id)}-${i}"><summary>
          <span class="st-failed">✖</span> ${esc(a.reason || 'failed')} <span class="dim">${esc(a.at || '')}</span></summary>
        <div class="fold-body"><div class="md">${md(a.detail || '')}</div>
        ${logs[i] ? `<details class="fold" data-fold="log-${esc(logs[i].name)}" data-log="${esc(logs[i].name)}"><summary>full log · ${esc(logs[i].name)} (${(logs[i].bytes / 1024).toFixed(1)} KB)</summary>
          <div class="fold-body"><pre class="block log">loading…</pre></div></details>` : ''}
        </div></details>`).join('')}
    </section>` : ''}
  `
}

function commitBlock (sha) {
  const c = (state.data.commits || {})[sha]
  if (!c) return `<div class="sha">${esc(sha.slice(0, 10))}</div>`
  return `<div style="margin-top:6px">
    <div class="sha">${esc(sha.slice(0, 10))} <span class="dim">${esc(c.author || '')}</span></div>
    <div>${esc(c.subject || '')}</div>
    ${c.files && c.files.length ? `<div class="fstat">${c.files.map((f) =>
      `<span class="s ${esc((f.status || '')[0] || '')}">${esc(f.status || '')}</span><span class="p">${esc(f.path)}</span>`).join('')}</div>` : ''}
  </div>`
}

function editForm (it) {
  const others = issues().filter((x) => x.id !== it.id)
  return `<section class="card editing">
    <h2>edit issue · writes spec.json</h2>
    <div class="form">
      <label>id<input data-f="id" value="${esc(it.id)}"></label>
      <label>title<input data-f="title" value="${esc(it.title || '')}"></label>
      <label>status<select data-f="status">
        ${['ready', 'claimed', 'done'].map((s) => `<option ${it.status === s ? 'selected' : ''}>${s}</option>`).join('')}
      </select></label>
      <label>model<input data-f="model" value="${esc(it.model || '')}" placeholder="(spec default)"></label>
      <label class="wide">body file<input data-f="body" value="${esc(it.body || '')}" placeholder="issues/&lt;id&gt;.md"></label>
      <label class="wide">blocked_by<div class="chips">${others.map((o) => `<label class="chipbox">
        <input type="checkbox" data-dep="${esc(o.id)}" ${(it.blocked_by || []).includes(o.id) ? 'checked' : ''}> ${esc(o.id)}
      </label>`).join('') || '<span class="empty">no other issues</span>'}</div></label>
      <label class="wide">criteria <span class="dim">— one per line</span>
        <textarea data-f="criteria" style="height:26vh">${esc((it.criteria || []).join('\n'))}</textarea></label>
      <label>files <span class="dim">— one per line</span>
        <textarea data-f="files">${esc((it.files || []).join('\n'))}</textarea></label>
      <label>verification <span class="dim">— one per line</span>
        <textarea data-f="verification">${esc((it.verification || []).join('\n'))}</textarea></label>
    </div>
    <div class="row-actions">
      <button class="chip" data-act="save">save <kbd>⌘⏎</kbd></button>
      <button class="chip" data-act="cancel">cancel <kbd>esc</kbd></button>
      <button class="chip danger" data-act="delete">delete issue</button>
    </div>
  </section>`
}

function renderGraphView () {
  main().innerHTML = `<h1 class="view">Dependency graph</h1>
    <div class="subhead">columns are longest-path depth; edges a longer path already implies are hidden</div>
    <div id="graphwrap">${renderGraph(issues(), effStatus, state.issueId)}</div>
    <div class="legend">${STATUSES.map((s) =>
      `<span class="st-${s}">${STATUS_GLYPH[s]} <b>${s}</b></span>`).join('')}</div>`
}

function renderDoc (name, content, key, mtime) {
  const editing = state.editingBody === key
  main().innerHTML = `<div class="issue-head">
      <div><h1 class="view">${esc(name)}</h1>
      <div class="subhead">${content ? `${content.split('\n').length} lines · ${relTime(mtime)}` : 'missing'}</div></div>
      <div class="chips">
        ${runLive() ? '' : `<button class="chip" data-act="${editing ? 'cancel-doc' : 'edit-doc'}" data-doc="${key}">${editing ? 'cancel' : 'edit'}</button>`}
        ${editing && !runLive() ? `<button class="chip" data-act="save-doc" data-doc="${key}">save <kbd>⌘⏎</kbd></button>` : ''}
      </div>
    </div>
    ${runLive() ? `<div class="warn lock">${lockNote(null)}</div>` : ''}
    <section class="card">${editing && !runLive()
      ? `<textarea class="editor" data-body-editor style="height:70vh">${esc(content || '')}</textarea>`
      : `<div class="md">${md(content || '')}</div>`}</section>`
}

function renderLedger () {
  const led = (state.data.spec && state.data.spec.ledger) || []
  main().innerHTML = `<h1 class="view">Ledger</h1>
    <div class="subhead">what each finished issue promised, and the commit it left behind</div>
    ${led.length ? led.map((l) => `<div class="ledger-item">
      <div><a href="${href('issue', l.id)}">${esc(l.id)}</a> <span class="when">${esc(l.at || '')}</span></div>
      <div class="md">${md(l.outcome || '')}</div>
      ${l.commit ? commitBlock(l.commit) : ''}
    </div>`).join('') : '<p class="empty">nothing delivered yet</p>'}`
}

function renderAttempts () {
  const logs = state.data.attempts || []
  main().innerHTML = `<h1 class="view">Attempt logs</h1>
    <div class="subhead">full verification output for failed attempts — the prompt only ever sees a 3-line tail</div>
    ${logs.length ? logs.map((a) => `<details class="fold" data-fold="log-${esc(a.name)}" data-log="${esc(a.name)}"><summary>
        <span class="st-failed">⚑</span> ${esc(a.name)} <span class="dim">${(a.bytes / 1024).toFixed(1)} KB · ${relTime(a.mtime)}</span></summary>
      <div class="fold-body"><pre class="block log">loading…</pre></div></details>`).join('')
      : '<p class="empty">no failed attempts on disk</p>'}`
}

// ------------------------------------------------------------- actions

function collectEdit () {
  const val = (f) => main().querySelector(`[data-f="${f}"]`).value.trim()
  const lines = (f) => main().querySelector(`[data-f="${f}"]`).value.split('\n').map((s) => s.trim()).filter(Boolean)
  return {
    id: val('id'),
    title: val('title'),
    status: val('status'),
    body: val('body'),
    model: val('model') || null,
    blocked_by: [...main().querySelectorAll('[data-dep]')].filter((c) => c.checked).map((c) => c.dataset.dep),
    criteria: lines('criteria'),
    files: lines('files'),
    verification: lines('verification'),
  }
}

async function saveIssue () {
  const id = state.editing
  const it = issueById(id)
  if (!it || !editable(it)) return
  const patch = collectEdit()
  await post('/api/issue', { id, patch })
  state.editing = null
  state.dirty = false
  if (patch.id !== id) go('issue', patch.id)
  else render()
}

async function saveBody (path) {
  if (runLive()) return
  const ta = main().querySelector('[data-body-editor]')
  if (!ta) return
  await post('/api/file', { path, content: ta.value })
  state.editingBody = false
  state.dirty = false
  render()
}

async function appendComment (anchor) {
  const it = issueById(state.issueId)
  const box = $('#comment-box')
  const text = box.value.trim()
  if (!text || !it) return
  await post('/api/comment', { path: it.body || `issues/${it.id}.md`, text, anchor: anchor || null })
  const fresh = $('#comment-box')
  if (fresh) { fresh.value = ''; delete fresh.dataset.anchor }
}

// Log bodies are fetched when their fold first opens — the payload only
// carries metadata, so a hot run isn't re-shipping megabytes every change.
document.addEventListener('toggle', async (e) => {
  const d = e.target
  if (!d.open || !d.dataset || !d.dataset.log || d.dataset.loaded) return
  d.dataset.loaded = '1'
  const pre = d.querySelector('pre.log')
  try {
    const res = await fetch(`/api/attempt?slug=${encodeURIComponent(state.slug)}&name=${encodeURIComponent(d.dataset.log)}`)
    const json = await res.json()
    if (!res.ok) throw new Error(json.error || `HTTP ${res.status}`)
    pre.textContent = (json.truncated ? '(head truncated — showing the tail)\n\n' : '') + json.body
  } catch (err) {
    pre.textContent = `could not load: ${String(err.message || err)}`
    delete d.dataset.loaded
  }
}, true)

// Array order is priority order — the frontier is "first not-done issue in
// array order with blockers done" — so moving an issue is a real planning edit.
async function moveIssue (id, delta) {
  if (runLive()) return
  const order = issues().map((i) => i.id)
  const at = order.indexOf(id)
  const to = at + delta
  if (at < 0 || to < 0 || to >= order.length) return
  ;[order[at], order[to]] = [order[to], order[at]]
  await post('/api/issue/reorder', { order })
}

function newIssue () {
  if (runLive() || $('#palette')) return
  const wrap = document.createElement('div')
  wrap.id = 'palette'
  wrap.innerHTML = `<div class="pal-box">
    <input id="pal-input" placeholder="new issue id (kebab-case) — ⏎ creates, esc cancels" autocomplete="off" spellcheck="false">
    <div class="pal-help">appends a ready issue to the end of the array and creates issues/&lt;id&gt;.md</div>
  </div>`
  document.body.appendChild(wrap)
  const input = $('#pal-input')
  input.addEventListener('keydown', async (e) => {
    if (e.key !== 'Enter') return
    const id = input.value.trim()
    if (!/^[A-Za-z0-9_-]+$/.test(id)) { input.style.borderBottomColor = 'var(--red)'; return }
    closePalette()
    await post('/api/issue/new', { id })
    location.hash = href('issue', id)
    state.editing = id
    state.dirty = false
    render()
  })
  wrap.addEventListener('click', (e) => { if (e.target === wrap) closePalette() })
  input.focus()
}

document.addEventListener('click', async (e) => {
  const specCard = e.target.closest('[data-spec]')
  if (specCard) { goSpec(specCard.dataset.spec); return }
  const dockTab = e.target.closest('[data-dock]')
  if (dockTab) { state.dock = dockTab.dataset.dock; renderDock(); return }
  const mv = e.target.closest('[data-move]')
  if (mv) {
    const at = mv.dataset.move.lastIndexOf(':')
    await moveIssue(mv.dataset.move.slice(0, at), Number(mv.dataset.move.slice(at + 1)))
    return
  }
  const row = e.target.closest('[data-issue]')
  if (row) { go('issue', row.dataset.issue); return }
  if (e.target.closest('[data-new]')) { await newIssue(); return }

  const critBtn = e.target.closest('[data-comment-crit]')
  if (critBtn) {
    const box = $('#comment-box')
    const n = Number(critBtn.dataset.commentCrit) + 1
    box.dataset.anchor = `criterion ${n}`
    box.placeholder = `Comment on criterion ${n}…`
    box.focus()
    return
  }

  const btn = e.target.closest('[data-act]')
  if (!btn) return
  const act = btn.dataset.act
  const it = issueById(state.issueId)

  if (act === 'edit') { if (editable(it)) { state.editing = state.editing ? null : state.issueId; state.dirty = false; render() } }
  else if (act === 'cancel') { state.editing = null; state.dirty = false; render() }
  else if (act === 'save') await saveIssue()
  else if (act === 'delete') {
    if (editable(it) && confirm(`Delete issue ${state.issueId}? Its body file stays on disk.`)) {
      await post('/api/issue/delete', { id: state.issueId })
      go('overview')
    }
  } else if (act === 'edit-body') { if (editable(it)) { state.editingBody = true; state.dirty = false; render() } }
  else if (act === 'cancel-body') { state.editingBody = false; state.dirty = false; render() }
  else if (act === 'save-body') await saveBody(it.body)
  else if (act === 'edit-meta') { state.editingBody = 'meta'; state.dirty = false; render() }
  else if (act === 'cancel-meta') { state.editingBody = false; state.dirty = false; render() }
  else if (act === 'save-meta') await saveMeta()
  else if (act === 'edit-doc') { state.editingBody = btn.dataset.doc; state.dirty = false; render() }
  else if (act === 'cancel-doc') { state.editingBody = false; state.dirty = false; render() }
  else if (act === 'save-doc') await saveBody(btn.dataset.doc === 'notes' ? 'NOTES.md' : 'context.md')
  else if (act === 'comment') await appendComment($('#comment-box').dataset.anchor)
})

// ------------------------------------------------------ keyboard + palette

document.addEventListener('keydown', async (e) => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName)

  if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
    e.preventDefault()
    if (state.editing) return saveIssue()
    if (state.editingBody === 'meta') return saveMeta()
    if (state.editingBody === 'notes') return saveBody('NOTES.md')
    if (state.editingBody === 'context') return saveBody('context.md')
    if (state.editingBody === true) return saveBody(issueById(state.issueId).body)
    if (e.target.id === 'comment-box') return appendComment(e.target.dataset.anchor)
    return
  }
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); openPalette(); return }
  if ((e.metaKey || e.ctrlKey) && e.key === '/') {
    e.preventDefault()
    const box = $('#comment-box')
    if (box) box.focus()
    return
  }
  if (e.key === 'Escape') {
    if ($('#palette')) closePalette()
    else if (state.editing || state.editingBody) {
      if (state.dirty && !confirm('Discard unsaved edits?')) return
      state.editing = null; state.editingBody = false; state.dirty = false; render()
    } else if (typing) e.target.blur()
    return
  }
  if (typing) return

  const list = issues()
  const at = list.findIndex((i) => i.id === state.issueId)
  if ((e.key === 'j' || e.key === 'ArrowDown') && list.length) { e.preventDefault(); go('issue', list[Math.min(list.length - 1, at + 1)].id) }
  else if ((e.key === 'k' || e.key === 'ArrowUp') && list.length) { e.preventDefault(); go('issue', list[Math.max(0, at - 1)].id) }
  else if (e.key === 'e' && state.view === 'issue' && editable(issueById(state.issueId))) { state.editing = state.issueId; render() }
  else if (e.key === 'g') go('graph')
  else if (e.key === 'o') go('overview')
  else if (e.key === 'n') go('notes')
  else if (e.key === 'c') go('context')
  else if (e.key === 'l') go('ledger')
  else if (e.key === '?') openPalette()
})

function paletteItems () {
  const items = [
    { label: 'Overview', hint: 'o', hash: href('overview') },
    { label: 'Dependency graph', hint: 'g', hash: href('graph') },
    { label: 'context.md', hint: 'c', hash: href('context') },
    { label: 'NOTES.md', hint: 'n', hash: href('notes') },
    { label: 'Ledger', hint: 'l', hash: href('ledger') },
    { label: 'Attempt logs', hint: '', hash: href('attempts') },
  ]
  for (const it of issues()) {
    items.push({ label: `${it.id} — ${it.title}`, hint: effStatus(it), hash: href('issue', it.id) })
  }
  for (const s of state.data.specs || []) {
    if (s.slug === state.slug) continue
    items.push({ label: `spec: ${s.slug}`, hint: `${s.done}/${s.total}`, hash: `#${encodeURIComponent(s.slug)}/overview` })
  }
  return items
}

function openPalette () {
  if ($('#palette')) return
  const wrap = document.createElement('div')
  wrap.id = 'palette'
  wrap.innerHTML = `<div class="pal-box">
    <input id="pal-input" placeholder="Jump to an issue, view, or spec…" autocomplete="off">
    <div id="pal-list"></div>
    <div class="pal-help"><kbd>j</kbd><kbd>k</kbd> issues · <kbd>e</kbd> edit · <kbd>⌘/</kbd> comment · <kbd>⌘⏎</kbd> save · <kbd>esc</kbd> close</div>
  </div>`
  document.body.appendChild(wrap)
  const input = $('#pal-input')
  let sel = 0
  const draw = () => {
    const q = input.value.toLowerCase()
    const hits = paletteItems().filter((i) => i.label.toLowerCase().includes(q))
    sel = Math.min(sel, Math.max(0, hits.length - 1))
    $('#pal-list').innerHTML = hits.map((h, i) =>
      `<div class="pal-item ${i === sel ? 'on' : ''}" data-hash="${esc(h.hash)}">${esc(h.label)}<span class="dim">${esc(h.hint)}</span></div>`).join('')
    wrap._hits = hits
  }
  input.addEventListener('input', () => { sel = 0; draw() })
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown') { sel++; draw(); e.preventDefault() }
    else if (e.key === 'ArrowUp') { sel = Math.max(0, sel - 1); draw(); e.preventDefault() }
    else if (e.key === 'Enter') { const h = wrap._hits[sel]; if (h) location.hash = h.hash; closePalette() }
  })
  wrap.addEventListener('click', (e) => {
    const item = e.target.closest('.pal-item')
    if (item) { location.hash = item.dataset.hash; closePalette() }
    else if (e.target === wrap) closePalette()
  })
  draw()
  input.focus()
}

function closePalette () { const p = $('#palette'); if (p) p.remove() }

// ---------------------------------------------------------------- boot

$('#killrun').addEventListener('click', async () => {
  const d = state.data
  if (!(d && d.run && d.run.running)) return
  if (!confirm(`Kill loop.sh (pid ${d.run.pid})?\n\nThis is Ctrl-C to its process group: the in-flight iteration dies with it and may leave uncommitted work in the repo — the next run's prompt calls that out and carries on.`)) return
  try { await post('/api/run/kill', {}) } catch { /* the stamp already shows why */ }
  // The group takes a beat to die; re-check once the dust settles.
  setTimeout(load, 1500)
})

readHash()

// The rail and dock stick below the header, whose height isn't fixed — long
// titles and paths wrap. Measure it instead of assuming 84px.
const setTopH = () => document.documentElement.style.setProperty('--top-h', `${$('#top').offsetHeight}px`)
new ResizeObserver(setTopH).observe($('#top'))
setTopH()

// ?nosse=1 freezes the page: no live channel, no ticking clock. Useful for
// screenshots and for reading a spec that is being written to underneath you.
if (!location.search.includes('nosse')) {
  setInterval(renderStamp, 5000)
  // The "3m ago" strings elsewhere (rail, spec cards) only refresh on render;
  // give them a slow tick. render() carries drafts and folds across, and the
  // editor guard keeps it out of an open edit.
  setInterval(() => { if (!state.editing && !state.editingBody) render() }, 30_000)
  connect()
}
load()
