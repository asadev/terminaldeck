const { app, BrowserWindow, session } = require('electron')
const http = require('node:http')
const { writeFileSync, existsSync, readFileSync } = require('node:fs')
const { join } = require('node:path')
const TINY_WEBM = require('./tiny-webm.cjs')

/**
 * The probe app. `../measure-extension.mjs` spawns this; that file holds the
 * argument for why any of it exists.
 *
 * Everything here answers one question: **what does this extension actually do
 * inside the Electron this app ships?** Not what its manifest asks for — that
 * is `browser-extension-support.ts`, and it cannot see the two things that
 * matter most, `storage.sync` throwing and static rulesets never being switched
 * on. So a real page is served, real requests go out of it, and the server
 * counts which ones arrived.
 *
 * The three hosts on the page are the measurement:
 *
 *  - `ads.doubleclick.net` — what a blocker exists to stop.
 *  - `cmp.actiview.de` — a consent-manager script matching a rule in *I still
 *    don't care about cookies*.
 *  - `control.invalid` — an innocent third host, so that *blocked* is never
 *    confused with *the network broke*.
 *
 * All three are pointed at this server with `--host-resolver-rules`, and
 * nothing else is: the rest of the internet stays real, so an extension that
 * fetches its filter lists at start-up can. Getting that wrong once made
 * AdGuard's first run look like a failure it was not.
 */

const EXT_DIR = process.env.EXT_DIR
const OUT = process.env.OUT_JSON
const PORT = Number(process.env.PORT || '8731')
const EXT_ID = process.env.EXT_ID || 'x'

const hits = []
const server = http.createServer((req, res) => {
  const host = String(req.headers.host || '').split(':')[0]
  hits.push(`${host}${req.url}`)
  if (req.url.startsWith('/page')) {
    res.writeHead(200, { 'content-type': 'text/html' })
    res.end(`<!doctype html><html><head><title>probe</title></head><body style="background:#ffffff;color:#000">
<h1>probe page</h1>
<video id="v" muted loop playsinline controls width="320" height="180" src="http://probe.test/tiny.webm"></video>
<script>window.__probe = { ad: false, consent: false, control: false }</script>
<script src="http://ads.doubleclick.net/ad.js"></script>
<script src="http://cmp.actiview.de/app.js"></script>
<script src="http://control.invalid/control.js"></script>
<script>
;(async () => {
  try {
    const v = document.getElementById('v')
    await new Promise((r) => { if (v.readyState >= 1) r(); else v.addEventListener('loadedmetadata', r, { once: true }); setTimeout(r, 3000) })
    await v.play().catch(() => {})
    window.__videoReady = v.readyState >= 1
  } catch (e) { window.__videoError = String(e) }
})()
</script>
</body></html>`)
    return
  }
  if (req.url.startsWith('/tiny.webm')) {
    res.writeHead(200, { 'content-type': 'video/webm', 'content-length': TINY_WEBM.length })
    res.end(TINY_WEBM)
    return
  }
  res.writeHead(200, { 'content-type': 'application/javascript' })
  if (req.url.includes('ad.js')) res.end('window.__probe && (window.__probe.ad = true);')
  else if (req.url.includes('app.js')) res.end('window.__probe && (window.__probe.consent = true);')
  else res.end('window.__probe && (window.__probe.control = true);')
})

const report = {
  id: EXT_ID,
  loaded: false,
  electronId: '',
  loadError: '',
  swConsole: [],
  bgConsole: [],
  pageConsole: [],
  hits: [],
  probeErrors: [],
  namespaces: null,
  rulesets: null,
  rulesetsError: '',
  bodyBackground: '',
  search: '',
  videoRate: null,
  videoRateAfterKey: null,
  vscController: false,
  darkStyle: false,
  extensionPage: '',
}

function push(list, raw) {
  try {
    const message = typeof raw === 'string' ? raw : raw && raw.message ? raw.message : JSON.stringify(raw)
    const level = raw && raw.level !== undefined ? raw.level : ''
    const source = raw && raw.sourceId ? ` @${raw.sourceId}:${raw.lineNumber}` : ''
    list.push(`[${level}] ${message}${source}`)
  } catch (e) {
    list.push('(unreadable console message)')
  }
}

const wait = (ms) => new Promise((r) => setTimeout(r, ms))

app.commandLine.appendSwitch(
  'host-resolver-rules',
  ['probe.test', 'ads.doubleclick.net', 'cmp.actiview.de', 'control.invalid']
    .map((host) => `MAP ${host} 127.0.0.1:${PORT}`)
    .join(', '),
)
app.commandLine.appendSwitch('disable-features', 'DialMediaRouteProvider')

app.on('web-contents-created', (_event, wc) => {
  const type = wc.getType()
  if (type === 'backgroundPage' || type === 'remote') {
    wc.on('console-message', (...args) => {
      const first = args[0]
      if (first && typeof first === 'object' && 'message' in first) push(report.bgConsole, first)
      else push(report.bgConsole, { level: args[0], message: args[1], sourceId: args[3], lineNumber: args[2] })
    })
  }
})

async function main() {
  await new Promise((resolve) => server.listen(PORT, '127.0.0.1', resolve))
  await app.whenReady()
  if (process.platform === 'darwin' && app.dock) app.dock.hide()
  const ses = session.fromPartition('persist:probe')
  ses.serviceWorkers.on('console-message', (...args) => {
    const details = args.length > 1 ? args[1] : args[0]
    push(report.swConsole, details)
  })

  let manifest = {}
  try { manifest = JSON.parse(readFileSync(join(EXT_DIR, 'manifest.json'), 'utf8')) } catch (e) { report.loadError = 'no manifest: ' + e.message }

  try {
    const loadedExt = await ses.extensions.loadExtension(EXT_DIR)
    report.loaded = true
    report.electronId = loadedExt.id
  } catch (error) {
    report.loadError = String(error && error.message ? error.message : error)
  }

  await wait(3500)

  const win = new BrowserWindow({ show: false, width: 1000, height: 700, webPreferences: { session: ses, sandbox: true, contextIsolation: true } })
  win.webContents.on('console-message', (...args) => {
    const first = args[0]
    if (first && typeof first === 'object' && 'message' in first) push(report.pageConsole, first)
    else push(report.pageConsole, { level: args[0], message: args[1] })
  })
  try {
    await win.loadURL(`http://probe.test/page?utm_source=newsletter&utm_medium=email&fbclid=abc123&id=7`)
  } catch (error) {
    report.probeErrors.push('page: ' + String(error))
  }
  await wait(4000)

  try {
    const seen = await win.webContents.executeJavaScript(`(() => ({
      probe: window.__probe || null,
      bg: getComputedStyle(document.body).backgroundColor,
      search: location.search,
      videoReady: !!window.__videoReady,
      videoError: window.__videoError || '',
      rate: document.getElementById('v') ? document.getElementById('v').playbackRate : null,
      vsc: !!document.querySelector('.vsc-controller, vsc-controller, [class*="vsc-"]'),
      dark: !!document.querySelector('style.darkreader, style[class*="darkreader"]'),
    }))()`)
    report.bodyBackground = seen.bg
    report.search = seen.search
    report.videoRate = seen.rate
    report.vscController = seen.vsc
    report.darkStyle = seen.dark
    report.videoReady = seen.videoReady
    report.videoError = seen.videoError
    report.pageProbe = seen.probe
  } catch (error) {
    report.probeErrors.push('read: ' + String(error))
  }

  // A key press, for the extensions whose whole job is a key press.
  try {
    win.webContents.focus()
    await win.webContents.executeJavaScript(`document.getElementById('v') && document.getElementById('v').focus(), document.body.click(), true`)
    for (const key of ['d', 'd']) {
      win.webContents.sendInputEvent({ type: 'keyDown', keyCode: key })
      win.webContents.sendInputEvent({ type: 'char', keyCode: key })
      win.webContents.sendInputEvent({ type: 'keyUp', keyCode: key })
      await wait(300)
    }
    await wait(700)
    report.videoRateAfterKey = await win.webContents.executeJavaScript(
      `document.getElementById('v') ? document.getElementById('v').playbackRate : null`,
    )
  } catch (error) {
    report.probeErrors.push('key: ' + String(error))
  }

  // The extension's own page, where `chrome.*` is real, for the namespace probe.
  const pageRel = (() => {
    const action = manifest.action || manifest.browser_action || {}
    const opts = manifest.options_page || (manifest.options_ui && manifest.options_ui.page) || ''
    const candidates = [action.default_popup, opts].filter((x) => typeof x === 'string' && x !== '')
    for (const c of candidates) {
      const clean = String(c).replace(/^\/+/, '').split('#')[0].split('?')[0]
      if (existsSync(join(EXT_DIR, clean))) return clean
    }
    return ''
  })()
  if (report.loaded && pageRel !== '') {
    report.extensionPage = pageRel
    const extWin = new BrowserWindow({ show: false, width: 500, height: 700, webPreferences: { session: ses, sandbox: true, contextIsolation: true } })
    extWin.webContents.on('console-message', (...args) => {
      const first = args[0]
      if (first && typeof first === 'object' && 'message' in first) push(report.pageConsole, { ...first, message: 'ext-page: ' + first.message })
      else push(report.pageConsole, { level: args[0], message: 'ext-page: ' + args[1] })
    })
    try {
      await extWin.loadURL(`chrome-extension://${report.electronId}/${pageRel}`)
      await wait(2500)
      const names = ['action','alarms','bookmarks','browserAction','browsingData','commands','contextMenus','cookies','declarativeNetRequest','downloads','extension','history','i18n','idle','identity','management','notifications','offscreen','permissions','power','privacy','proxy','runtime','scripting','sidePanel','storage','tabs','topSites','userScripts','webNavigation','webRequest','windows']
      const out = await extWin.webContents.executeJavaScript(`(async () => {
        const want = ${JSON.stringify(names)}
        const present = {}
        for (const n of want) present[n] = typeof chrome[n] !== 'undefined' && chrome[n] !== null
        let sync = 'absent'
        try { if (chrome.storage && chrome.storage.sync) { await chrome.storage.sync.set({ __t: 1 }); const g = await chrome.storage.sync.get('__t'); sync = g && g.__t === 1 ? 'works' : 'odd' } } catch (e) { sync = 'throws: ' + String(e && e.message || e) }
        let rulesets = null, rulesetsError = ''
        try { if (chrome.declarativeNetRequest && chrome.declarativeNetRequest.getEnabledRulesets) rulesets = await chrome.declarativeNetRequest.getEnabledRulesets() } catch (e) { rulesetsError = String(e && e.message || e) }
        const keys = {}
        for (const n of ['tabs', 'action', 'runtime', 'storage', 'scripting', 'webRequest', 'declarativeNetRequest', 'i18n', 'management', 'extension', 'alarms', 'offscreen']) {
          try { keys[n] = chrome[n] ? Object.keys(chrome[n]).sort() : null } catch (e) { keys[n] = 'threw' }
        }
        let activeTab = 'n/a', allTabs = 'n/a', localKeys = 'n/a'
        try { activeTab = JSON.stringify(await chrome.tabs.query({ active: true, currentWindow: true })) } catch (e) { activeTab = 'threw: ' + String(e && e.message || e) }
        try { allTabs = JSON.stringify((await chrome.tabs.query({})).map((t) => t.url)) } catch (e) { allTabs = 'threw: ' + String(e && e.message || e) }
        try { localKeys = JSON.stringify(Object.keys(await chrome.storage.local.get(null)).slice(0, 20)) } catch (e) { localKeys = 'threw: ' + String(e && e.message || e) }
        return { present, sync, rulesets, rulesetsError, keys, activeTab, allTabs, localKeys }
      })()`)
      report.namespaces = out.present
      report.storageSync = out.sync
      report.rulesets = out.rulesets
      report.rulesetsError = out.rulesetsError
      report.keys = out.keys
      report.activeTab = out.activeTab
      report.allTabs = out.allTabs
      report.localKeys = out.localKeys
      if (process.env.PROBE_EVAL) {
        try { report.extra = await extWin.webContents.executeJavaScript(process.env.PROBE_EVAL) }
        catch (error) { report.extra = 'threw: ' + String(error) }
      }
    } catch (error) {
      report.probeErrors.push('extpage: ' + String(error))
    }
    try { extWin.destroy() } catch {}
  }

  report.hits = hits.slice()
  try { win.destroy() } catch {}
  writeFileSync(OUT, JSON.stringify(report, null, 2))
  server.close()
  app.exit(0)
}

main().catch((error) => {
  report.probeErrors.push('fatal: ' + String(error && error.stack ? error.stack : error))
  try { writeFileSync(OUT, JSON.stringify(report, null, 2)) } catch {}
  app.exit(1)
})
