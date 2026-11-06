'use strict'
;(async () => {
  const config = JSON.parse(document.getElementById('payload').textContent)
  const root = document.getElementById('body')
  const frames = new Map()
  const send = value => window.chrome.webview.postMessage({ token: config.token, ...value })
  const decode = text => new TextDecoder().decode(Uint8Array.from(atob(text), c => c.charCodeAt(0)))
  function theme(value) {
    const changed = config.theme.dark !== value.dark
    config.theme = value
    for (const [key, color] of Object.entries(value.colors)) document.documentElement.style.setProperty('--' + key, color)
    document.body.classList.toggle('dark', value.dark)
    document.documentElement.style.colorScheme = value.dark ? 'dark' : 'light'
    document.getElementById('code-theme').href = 'https://rich-chat.deck.invalid/cdn-assets/styles/github' + (value.dark ? '-dark' : '') + '.min.css'
    if (changed && root.childNodes.length && !config.app) { for (const host of root.querySelectorAll('[data-kind=mermaid] .drawing')) host.replaceChildren(); void renderMessage() }
    for (const [frame, state] of frames) if (!state.app || state.ready) frame.contentWindow.postMessage({ jsonrpc: '2.0', method: 'ui/notifications/host-context-changed', params: { theme: value.dark ? 'dark' : 'light', styles: { variables: { ...Object.fromEntries(Object.entries(value.colors).map(([k,v]) => ['--' + k, v])), ...value.variables } } } }, '*')
  }
  document.documentElement.style.setProperty('--max-visual-height', config.maxVisualHeight + 'px')
  theme(config.theme)
  const resize = () => send({ type: 'size', height: Math.ceil(root.getBoundingClientRect().height) })
  new ResizeObserver(resize).observe(root)
  window.chrome.webview.addEventListener('message', event => {
    const value = event.data
    if (value.type === 'theme') theme(value.theme)
    if (value.type === 'content') { config.html = value.html; void renderMessage() }
    if (value.type === 'rpc') for (const [frame, state] of frames) if (state.id === value.frame) frame.contentWindow.postMessage(value.reply, '*')
  })
  window.addEventListener('message', event => {
    const entry = Array.from(frames).find(([frame]) => frame.contentWindow === event.source)
    if (event.origin !== 'null' || !entry || !event.data || typeof event.data !== 'object') return
    const [frame, state] = entry
    if (event.data.deckSize !== undefined) { frame.style.height = Math.max(64, Math.min(config.maxVisualHeight, Number(event.data.deckSize) || 64)) + 'px'; resize(); return }
    if (!state.app || event.data.jsonrpc !== '2.0') return
    if (event.data.method === 'ui/notifications/initialized') state.ready = true
    if (event.data.method === 'ui/notifications/size-changed') { frame.style.height = Math.max(64, Math.min(config.maxVisualHeight, Number(event.data.params?.height) || 64)) + 'px'; resize(); return }
    // Only the native host can authorize a call; the app never chooses its server.
    send({ type: 'app-rpc', frame: state.id, request: event.data })
  })
  const bootstrap = `<script>new ResizeObserver(()=>parent.postMessage({deckSize:document.documentElement.scrollHeight},'*')).observe(document.documentElement);document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();parent.postMessage({jsonrpc:'2.0',id:'link-'+Date.now(),method:'ui/open-link',params:{url:a.href}},'*')}});addEventListener('message',e=>{if(e.source!==parent)return;const p=e.data;if(p.method==='ui/notifications/host-context-changed'){for(const [k,v]of Object.entries(p.params.styles.variables))document.documentElement.style.setProperty(k.startsWith('--')?k:'--'+k,v);document.documentElement.style.colorScheme=p.params.theme}});</script>`
  function drawing(host, source, app = null) {
    const id = crypto.randomUUID()
    const frame = document.createElement('iframe')
    frame.setAttribute('sandbox', 'allow-scripts')
    frame.setAttribute('referrerpolicy', 'no-referrer')
    frame.setAttribute('allow', "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'")
    frame.title = app ? 'MCP App' : 'Visual'
    // Apps may request fewer origins. They cannot expand the visual allowlist.
    const requested = app?.resource?._meta?.ui?.csp?.resourceDomains || []
    const cdns = app ? ['https://cdnjs.cloudflare.com', 'https://cdn.jsdelivr.net'].filter(url => requested.includes(url)).join(' ') : 'https://cdnjs.cloudflare.com https://cdn.jsdelivr.net'
    const csp = `default-src 'none'; script-src 'unsafe-inline' ${cdns}; style-src 'unsafe-inline' ${cdns}; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`
    const colors = Object.entries(config.theme.colors).map(([k,v]) => '--' + k + ':' + v).join(';')
    frame.srcdoc = `<!doctype html><meta http-equiv="Content-Security-Policy" content="${csp}"><meta name="referrer" content="no-referrer"><style>:root{${colors};color-scheme:${config.theme.dark ? 'dark' : 'light'};color:var(--ink);background:transparent}body{margin:0}img,svg{max-width:100%}</style>${bootstrap}${source}`
    frames.set(frame, { id, app })
    if (app) send({ type: 'app-frame', frame: id })
    host.append(frame)
  }
  async function renderMessage() {
    const oldBlocks = Array.from(root.querySelectorAll('.rich-block'))
    const next = document.createElement('main')
    next.innerHTML = DOMPurify.sanitize(config.html, { ADD_ATTR: ['data-kind', 'data-source'], FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form'], FORBID_ATTR: ['style'] })
    function sync(parent, fresh) {
      const desired = Array.from(fresh.childNodes)
      for (let index = 0; index < desired.length; index++) {
        const node = desired[index]
        const current = parent.childNodes[index]
        const retained = node.nodeType === 1 && node.classList.contains('rich-block') && oldBlocks.find(old => old.dataset.kind === node.dataset.kind && old.dataset.source === node.dataset.source)
        if (retained) {
          oldBlocks.splice(oldBlocks.indexOf(retained), 1)
          if (current !== retained) parent.insertBefore(retained, current || null)
        } else if (current && node.nodeType === 1 && current.nodeType === 1 && node.tagName === current.tagName && node.querySelector('.rich-block')) sync(current, node)
        else if (current) parent.replaceChild(node, current)
        else parent.append(node)
      }
      while (parent.childNodes.length > desired.length) parent.lastChild.remove()
    }
    sync(root, next)
    for (const frame of frames.keys()) if (!root.contains(frame)) frames.delete(frame)
    for (const table of root.querySelectorAll('table')) { if (table.parentElement.classList.contains('table-scroll')) continue; const wrap = document.createElement('div'); wrap.className = 'table-scroll'; table.replaceWith(wrap); wrap.append(table) }
    for (const code of root.querySelectorAll('pre code')) {
      if (code.parentElement.previousElementSibling?.classList.contains('copy-code')) continue
      if (code.textContent.length < 200000) try { hljs.highlightElement(code) } catch { /* plain code stays selectable */ }
      const copy = document.createElement('button'); copy.textContent = 'Copy code'; copy.className = 'copy-code'
      copy.onclick = () => send({ type: 'copy', text: code.textContent })
      code.parentElement.before(copy)
    }
    for (const math of root.querySelectorAll('.math')) {
      let expression = math.textContent.trim()
      const displayMode = math.tagName !== 'SPAN' || expression.startsWith('$$')
      if ((expression.startsWith('\\(') && expression.endsWith('\\)')) || (expression.startsWith('\\[') && expression.endsWith('\\]'))) expression = expression.slice(2, -2)
      else expression = expression.replace(/^\${1,2}|\${1,2}$/g, '')
      try { katex.render(expression, math, { displayMode, throwOnError: false, trust: false, strict: 'warn' }) } catch { /* source remains readable */ }
    }
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', flowchart: { htmlLabels: false }, theme: config.theme.dark ? 'dark' : 'default', suppressErrorRendering: true })
    for (const block of root.querySelectorAll('.rich-block')) {
      const source = decode(block.dataset.source)
      const host = block.querySelector('.drawing')
      if (host.childNodes.length) continue
      if (block.dataset.kind === 'visual') drawing(host, source)
      else if (block.dataset.kind === 'svg') {
        const clean = DOMPurify.sanitize(source, { USE_PROFILES: { svg: true, svgFilters: true }, FORBID_TAGS: ['foreignObject', 'script'], FORBID_ATTR: ['href', 'xlink:href'] })
        const img = document.createElement('img'); img.alt = 'SVG drawing'; img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(clean); host.append(img)
      } else {
        try { const result = await mermaid.render('diagram-' + crypto.randomUUID(), source); host.innerHTML = DOMPurify.sanitize(result.svg, { USE_PROFILES: { svg: true, svgFilters: true } }) }
        catch { const error = document.createElement('p'); error.className = 'error'; error.textContent = 'This diagram could not be drawn. Its source is under Code.'; host.append(error) }
      }
    }
    resize()
  }
  if (config.app) drawing(root, config.app.html, config.app)
  else await renderMessage()
  root.addEventListener('click', event => {
      const link = event.target.closest('a')
      if (!link) return
      const target = link.getAttribute('href') || ''
      if (target.startsWith('#')) return
      event.preventDefault(); send({ type: 'link', url: target })
    })
  resize()
})().catch(() => {
  document.getElementById('body').textContent = 'This message could not be drawn. Use Copy to read its source.'
})
