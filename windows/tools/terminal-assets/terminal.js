import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { WebLinksAddon } from '@xterm/addon-web-links'
import { WebglAddon } from '@xterm/addon-webgl'
import '@xterm/xterm/css/xterm.css'
import './terminal.css'

// Bundled so Windows 10 (no Cascadia installed) gets the same face as Windows 11.
// The variable font carries real intermediate weights, so 'a little heavier'
// is a true Medium instead of a synthesized or ignored weight.
const fontFamily = "'Deck Cascadia Mono', 'Cascadia Mono', Consolas, monospace"
const fontWeight = 500
const fontWeightBold = 700

const palettes = {
  dark: ['#191919', '#ededed', '#3b8fee', '#3b8fee29', '#2e3436', '#cc0000', '#4e9a06', '#c4a000', '#3465a4', '#75507b', '#06989a', '#d3d7cf', '#555753', '#ef2929', '#8ae234', '#fce94f', '#729fcf', '#ad7fa8', '#34e2e2', '#eeeeec'],
  light: ['#e8e8e8', '#141414', '#1a66c4', '#1a66c41a', '#2e3436', '#cc0000', '#3b7405', '#7c6500', '#3465a4', '#75507b', '#057375', '#d3d7cf', '#555753', '#951a1a', '#335413', '#534d1a', '#384e65', '#5d445b', '#135454', '#eeeeec']
}
const names = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white', 'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite']
function setTheme(mode, surface = {}) {
  const p = palettes[mode] || palettes.dark
  const theme = { background: p[0], foreground: p[1], cursor: p[2], cursorAccent: p[0], selectionBackground: p[3] }
  names.forEach((name, i) => { theme[name] = p[i + 4] })
  for (const key of ['background', 'foreground']) {
    if (typeof surface[key] === 'string' && /^#[0-9a-f]{6}$/i.test(surface[key])) theme[key] = surface[key]
  }
  theme.cursorAccent = theme.background
  term.options.theme = theme
  document.body.style.backgroundColor = theme.background
  document.documentElement.style.colorScheme = mode

  document.documentElement.style.setProperty('--terminal-background', theme.background)
}
function send(message) { window.chrome?.webview?.postMessage(message) }
const term = new Terminal({ fontFamily, fontWeight, fontWeightBold, fontSize: 13, scrollback: 10000, allowProposedApi: true })
const fit = new FitAddon()
const search = new SearchAddon()
term.loadAddon(fit)
term.loadAddon(search)
term.loadAddon(new WebLinksAddon((_event, uri) => send({ type: 'link', uri })))
// xterm's fit reads its parent's height without subtracting the parent's own
// padding, so the padded card must not be that parent: #screen is the exact
// content box and every fitted row is fully visible.
const screen = document.getElementById('screen')
term.open(screen)
// Mac-style overlay scroll bar: invisible until the terminal scrolls, then a thin
// rounded thumb that fades out again (no permanent Windows bar).
{
  const viewport = screen.querySelector('.xterm-viewport')
  let hide = 0
  const show = () => { viewport?.classList.add('td-scrolling'); clearTimeout(hide); hide = setTimeout(() => viewport?.classList.remove('td-scrolling'), 900) }
  viewport?.addEventListener('scroll', show, { passive: true })
}
setTheme('dark')
// Losing the GPU context (screen sleep, lock, idle GPU power saving) used to
// drop the terminal onto the DOM renderer for good. That renderer measures
// cells differently at 125/150% scaling, so the cursor drew a cell away from
// where typing landed. Reattach WebGL instead and redraw at the same cell size.
let webgl = null
function attachWebgl() {
  if (webgl) return
  try {
    const addon = new WebglAddon()
    addon.onContextLoss(() => { addon.dispose(); if (webgl === addon) webgl = null; setTimeout(recoverRenderer, 250) })
    term.loadAddon(addon)
    webgl = addon
  } catch (_) { webgl = null /* The DOM renderer is a supported fallback when WebGL is unavailable. */ }
}
function recoverRenderer() {
  attachWebgl()
  scheduleFit()
  term.refresh(0, term.rows - 1)
}
attachWebgl()
// xterm caches the cell size from the first measure. Once the bundled face has
// loaded, change to an equivalent family string so it measures the real face.
document.fonts.load(`${fontWeight} 13px 'Deck Cascadia Mono'`).then(() => {
  term.options.fontFamily = `${fontFamily}, monospace`
  scheduleFit()
}, () => { })
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') recoverRenderer() })
term.onData(data => send({ type: 'input', data }))
term.onResize(({ cols, rows }) => send({ type: 'resize', cols, rows }))
term.onTitleChange(title => send({ type: 'title', title }))
term.onBell(() => send({ type: 'bell' }))
term.attachCustomKeyEventHandler(event => {
  if (event.type === 'keydown' && event.ctrlKey && event.shiftKey && event.code === 'KeyC' && term.hasSelection()) {
    event.preventDefault()
    send({ type: 'copy', text: term.getSelection() })
    return false
  }
  if (event.type === 'keydown' && event.ctrlKey && event.code === 'KeyV') { event.preventDefault(); send({ type: 'pasteRequest' }); return false }
  if (event.type === 'keydown' && event.ctrlKey && event.code === 'KeyF') { event.preventDefault(); send({ type: 'findRequest' }); return false }
  if (event.type === 'keydown' && event.ctrlKey && event.code === 'KeyG') { event.preventDefault(); send({ type: 'findNext', previous: event.shiftKey }); return false }
  return true
})
let copyOnSelect = false
term.element.addEventListener('pointerup', () => {
  if (copyOnSelect && term.hasSelection()) send({ type: 'copy', text: term.getSelection() })
})
term.element.addEventListener('contextmenu', event => { event.preventDefault(); send({ type: 'contextMenu' }) })
search.onDidChangeResults(result => send({ type: 'findResult', index: result.resultIndex, count: result.resultCount }))
let frame = 0
function scheduleFit() {
  cancelAnimationFrame(frame)
  frame = requestAnimationFrame(() => { if (screen.clientWidth && screen.clientHeight) fit.fit() })
}
new ResizeObserver(scheduleFit).observe(screen)
// A DPI change (moving between 100/125/150% displays) can keep the CSS size
// while changing the cell size; refit so rows still fit the visible area.
function watchScale() {
  const query = matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`)
  query.addEventListener('change', () => { scheduleFit(); watchScale() }, { once: true })
}
watchScale()
window.chrome?.webview?.addEventListener('message', event => {
  let message = event.data
  if (typeof message === 'string') { try { message = JSON.parse(message) } catch (_) { return } }
  if (!message || typeof message !== 'object') return
  switch (message.type) {
    case 'data': if (typeof message.data === 'string') term.write(message.data); break
    // A full replay rebuilds the screen from recorded output, which cannot
    // reproduce every cursor move exactly. Ask the host for a repaint from the
    // program itself once it is written, so typing lands where the cursor shows.
    case 'replay':
      if (typeof message.data === 'string') { term.reset(); term.write(message.data, () => send({ type: 'repaint', cols: term.cols, rows: term.rows })) }
      break
    case 'resize': scheduleFit(); break
    case 'theme': if (message.theme === 'dark' || message.theme === 'light') setTheme(message.theme, message); break
    case 'font':
      if (typeof message.family === 'string' && message.family.trim()) term.options.fontFamily = message.family
      if (Number.isFinite(message.size)) term.options.fontSize = Math.max(9, Math.min(24, message.size))
      scheduleFit(); break
    case 'clear': term.clear(); break
    case 'paste': if (typeof message.text === 'string') term.paste(message.text); break
    case 'copy': if (term.hasSelection()) send({ type: 'copy', text: term.getSelection() }); break
    case 'copyOnSelect': copyOnSelect = message.enabled === true; break
    case 'focus': term.focus(); break
    case 'find':
      if (typeof message.query === 'string') {
        if (!message.query) search.clearDecorations()
        else if (message.direction === 'previous') search.findPrevious(message.query, { decorations: {} })
        else search.findNext(message.query, { decorations: {} })
      }
      break
  }
})
scheduleFit()
send({ type: 'ready' })
