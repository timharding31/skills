// A small markdown renderer — enough for spec bodies, context.md and NOTES.md.
// Everything is escaped before any markup is added, so file content is inert.

export function esc (s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function inline (s) {
  let out = esc(s)
  // code spans first — their contents must not be re-parsed
  const codes = []
  out = out.replace(/`([^`]+)`/g, (_m, c) => `\u0000${codes.push(c) - 1}\u0000`)
  out = out
    // Ticket bodies are agent-authored — only linkify schemes that can't
    // execute; anything else (javascript:, data:, …) stays visible as text.
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, label, href) =>
      /^(https?:\/\/|mailto:|#|\.{0,2}\/)/i.test(href)
        ? `<a href="${href}" target="_blank" rel="noreferrer">${label}</a>`
        : m)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/(^|[\s(])_([^_\n]+)_/g, '$1<em>$2</em>')
  out = out.replace(/\u0000(\d+)\u0000/g, (_m, i) => `<code class="inline">${codes[Number(i)]}</code>`)
  return out
}

export function md (src) {
  if (!src || !src.trim()) return '<p class="empty">empty</p>'
  const lines = String(src).replace(/\r\n/g, '\n').split('\n')
  const out = []
  let i = 0
  // Open list stack: entries are {tag, indent}
  let stack = []

  const closeLists = (toIndent = -1) => {
    while (stack.length && stack[stack.length - 1].indent > toIndent) {
      out.push(`</${stack.pop().tag}>`)
    }
  }

  while (i < lines.length) {
    const line = lines[i]

    // fenced code
    const fence = /^\s*```(\w*)\s*$/.exec(line)
    if (fence) {
      closeLists()
      const buf = []
      i++
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) buf.push(lines[i++])
      i++
      out.push(`<pre class="block">${esc(buf.join('\n'))}</pre>`)
      continue
    }

    if (!line.trim()) { closeLists(); i++; continue }

    const h = /^(#{1,6})\s+(.*)$/.exec(line)
    if (h) {
      closeLists()
      const lvl = Math.min(h[1].length, 4)
      out.push(`<h${lvl}>${inline(h[2])}</h${lvl}>`)
      i++
      continue
    }

    if (/^\s*(---|\*\*\*|___)\s*$/.test(line)) { closeLists(); out.push('<hr>'); i++; continue }

    const quote = /^\s*>\s?(.*)$/.exec(line)
    if (quote) {
      closeLists()
      const buf = [quote[1]]
      i++
      while (i < lines.length && /^\s*>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^\s*>\s?/, '')); i++ }
      out.push(`<blockquote>${md(buf.join('\n'))}</blockquote>`)
      continue
    }

    const li = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(line)
    if (li) {
      const indent = li[1].length
      const tag = /^\d/.test(li[2]) ? 'ol' : 'ul'
      closeLists(indent)
      const top = stack[stack.length - 1]
      if (!top || top.indent < indent) { out.push(`<${tag}>`); stack.push({ tag, indent }) }
      // continuation lines of the same bullet
      const buf = [li[3]]
      i++
      while (i < lines.length && lines[i].trim() && !/^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i]) &&
             (lines[i].length - lines[i].trimStart().length) > indent) {
        buf.push(lines[i].trim())
        i++
      }
      out.push(`<li>${inline(buf.join(' '))}</li>`)
      continue
    }

    // table
    if (/\|/.test(line) && i + 1 < lines.length && /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(lines[i + 1])) {
      closeLists()
      const row = (l) => l.replace(/^\s*\|/, '').replace(/\|\s*$/, '').split('|').map((c) => c.trim())
      const head = row(line)
      i += 2
      const body = []
      while (i < lines.length && /\|/.test(lines[i]) && lines[i].trim()) body.push(row(lines[i++]))
      out.push('<table><thead><tr>' + head.map((c) => `<th>${inline(c)}</th>`).join('') + '</tr></thead><tbody>' +
        body.map((r) => '<tr>' + r.map((c) => `<td>${inline(c)}</td>`).join('') + '</tr>').join('') +
        '</tbody></table>')
      continue
    }

    // paragraph
    closeLists()
    const buf = [line]
    i++
    while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|\s*([-*+]|\d+[.)])\s|\s*>|\s*```)/.test(lines[i])) {
      buf.push(lines[i]); i++
    }
    out.push(`<p>${inline(buf.join(' '))}</p>`)
  }
  closeLists()
  return out.join('\n')
}
