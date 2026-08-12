import { randomUUID } from 'node:crypto'
import {
  app,
  BrowserWindow,
  session,
  WebContentsView,
  type IpcMain,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
  type Session,
  type WebContents,
} from 'electron'
import { BLANK_URL, isNavigationAllowed, normalizeUrl, shortLabel } from './browser-url'
import {
  GUEST_CANCEL_CHANNEL,
  GUEST_ELEMENT_CHANNEL,
  GUEST_INSPECT_CHANNEL,
  writeGuestPreload,
} from './browser-preload'
import { composeAgentContext, parseCapture, type ElementCapture } from './selector'
import { isolatedSession } from './browser-isolation'

/**
 * The embedded browser tab: a real Chromium view, hosted inside the app window,
 * that can be pointed at a dev server and clicked to hand an element back to
 * the agent.
 *
 * ## Why a WebContentsView and not an <iframe> or a <webview>
 *
 * A dev server's pages set `X-Frame-Options` / `frame-ancestors` often enough
 * that an iframe is unreliable, and an iframe would also share a process and a
 * session with the app's own renderer. A `WebContentsView` is a separate
 * process with its own session, which is what "untrusted guest" should mean.
 * The cost is that it is a native layer floating over the React tree rather
 * than part of it — so the renderer reports where to put it, and hides it
 * whenever something must appear on top.
 *
 * ## The guest is untrusted, all of it
 *
 * - Its own session partition, so the app's strict CSP header rewrite (applied
 *   to `defaultSession` in index.ts) never lands on guest pages — it would
 *   otherwise force `default-src 'self'` onto every site opened here and break
 *   dev servers outright.
 * - Navigation is allow-listed to http(s). `file:` is refused everywhere it can
 *   be attempted: the URL bar, link clicks, redirects and subframes.
 * - No node integration, sandbox on, context isolation on, popups denied,
 *   dialogs disabled, downloads blocked, every permission request refused.
 * - Anything the page reports about a clicked element is treated as data and
 *   goes through `parseCapture` before it can reach the UI or a terminal.
 */

/* ------------------------------------------------------------------ types -- */

export interface BrowserTabBounds {
  x: number
  y: number
  width: number
  height: number
}

export interface BrowserTabState {
  id: string
  url: string
  /** Host and path only — what the tab strip shows. */
  label: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
  inspecting: boolean
  /**
   * The last thing that went wrong or was refused, in one sentence. Cleared by
   * the next successful navigation.
   */
  error: string | null
}

/** What the renderer receives for a captured element. */
export interface BrowserCapture extends ElementCapture {
  /** The single line to hand the agent, already sanitised. */
  context: string
}

interface BrowserTab {
  id: string
  view: WebContentsView
  host: WebContents
  window: BrowserWindow
  bounds: BrowserTabBounds
  visible: boolean
  inspecting: boolean
  error: string | null
}

/**
 * Separate from the app's own session so guest cookies, storage and — most
 * importantly — response headers are handled independently of Deck's.
 */
const GUEST_PARTITION = 'persist:terminaldeck-browser'

const tabs = new Map<string, BrowserTab>()
const watchedHosts = new WeakSet<WebContents>()

let guestPreloadPath: string | null = null
let guestSession: Session | null = null

/* -------------------------------------------------------------- plumbing -- */

/** Written once per launch; a file left by an older version would run stale code. */
function preloadPath(): string {
  if (guestPreloadPath === null) guestPreloadPath = writeGuestPreload(app.getPath('userData'))
  return guestPreloadPath
}

function hardenedGuestSession(): Session {
  if (guestSession) return guestSession
  const ses = session.fromPartition(GUEST_PARTITION)
  // A page being looked at has no business asking for the camera, the
  // clipboard or a notification, and there is no UI here to ask the user.
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false))
  ses.setPermissionCheckHandler(() => false)
  ses.on('will-download', (event) => event.preventDefault())
  guestSession = ses
  return ses
}

/**
 * The tab's WebContents, or null once it has gone.
 *
 * Not a convenience: after the view is destroyed `view.webContents` is
 * `undefined` rather than a destroyed object, so `webContents.isDestroyed()`
 * throws. Verified in a real Electron run — a load still in flight when the tab
 * closed took the main process's rejection handler out with it.
 */
function liveContents(tab: BrowserTab): WebContents | null {
  const wc = tab.view.webContents as WebContents | undefined
  return wc && !wc.isDestroyed() ? wc : null
}

function stateOf(tab: BrowserTab): BrowserTabState {
  const wc = liveContents(tab)
  const url = wc ? wc.getURL() : ''
  return {
    id: tab.id,
    url: url === BLANK_URL ? '' : url,
    label: shortLabel(url),
    title: wc ? wc.getTitle() : '',
    loading: wc ? wc.isLoading() : false,
    canGoBack: wc ? wc.navigationHistory.canGoBack() : false,
    canGoForward: wc ? wc.navigationHistory.canGoForward() : false,
    inspecting: tab.inspecting,
    error: tab.error,
  }
}

function push(tab: BrowserTab): void {
  if (tab.host.isDestroyed()) return
  tab.host.send('browser:state-changed', stateOf(tab))
}

function fail(tab: BrowserTab, message: string): void {
  tab.error = message
  push(tab)
}

/** Bounds are laid out in CSS pixels by the renderer, which is what setBounds wants. */
function sanitizeBounds(raw: unknown): BrowserTabBounds {
  const r = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  const num = (value: unknown): number =>
    typeof value === 'number' && Number.isFinite(value) ? Math.round(value) : 0
  return {
    x: num(r.x),
    y: num(r.y),
    width: Math.max(0, num(r.width)),
    height: Math.max(0, num(r.height)),
  }
}

function applyLayout(tab: BrowserTab): void {
  if (!liveContents(tab)) return
  tab.view.setBounds(tab.bounds)
  // A zero-sized view still paints a white sliver, so treat "no room" as hidden.
  tab.view.setVisible(tab.visible && tab.bounds.width > 0 && tab.bounds.height > 0)
}

function tellGuest(tab: BrowserTab): void {
  liveContents(tab)?.send(GUEST_INSPECT_CHANNEL, tab.inspecting)
}

function destroyTab(tab: BrowserTab): void {
  tabs.delete(tab.id)
  if (!tab.window.isDestroyed()) {
    try {
      tab.window.contentView.removeChildView(tab.view)
    } catch {
      // The window may already be tearing its own view tree down.
    }
  }
  liveContents(tab)?.close()
}

/** Called from `before-quit`, and whenever a host window goes away. */
export function destroyAllBrowserTabs(): void {
  for (const tab of [...tabs.values()]) destroyTab(tab)
}

function destroyTabsFor(host: WebContents): void {
  for (const tab of [...tabs.values()]) {
    if (tab.host === host) destroyTab(tab)
  }
}

function requireTab(id: unknown): BrowserTab {
  const tab = typeof id === 'string' ? tabs.get(id) : undefined
  if (!tab) throw new Error('browser: no such tab')
  return tab
}

/* ------------------------------------------------------------ navigation -- */

function navigate(tab: BrowserTab, input: unknown): BrowserTabState {
  const result = normalizeUrl(input)
  if (!result.ok) {
    tab.error = result.reason
    return stateOf(tab)
  }
  const wc = liveContents(tab)
  if (!wc) return stateOf(tab)

  tab.error = null
  void wc.loadURL(result.url).catch((error: unknown) => {
    // A load rejection is routine — an aborted navigation rejects too, and so
    // does every load still in flight when the tab closes. Only worth
    // surfacing when the tab is still around with nothing on it.
    const message = error instanceof Error ? error.message : String(error)
    const still = liveContents(tab)
    if (still && still.getURL() === '') fail(tab, `Could not load that page: ${message}`)
  })
  return stateOf(tab)
}

function wireGuestEvents(tab: BrowserTab): void {
  // Called immediately after construction, so the contents are certainly live.
  const wc = tab.view.webContents

  const refuse = (url: string): void => {
    fail(tab, `Blocked a navigation to ${shortLabel(url) || 'another scheme'} — only http and https open here.`)
  }

  wc.on('will-navigate', (event, url) => {
    if (isNavigationAllowed(url)) return
    event.preventDefault()
    refuse(url)
  })

  // Subframes navigate independently, and an <iframe src="file://..."> would
  // otherwise walk straight past the top-level check.
  wc.on('will-frame-navigate', (details) => {
    if (isNavigationAllowed(details.url)) return
    details.preventDefault()
    refuse(details.url)
  })

  wc.on('will-redirect', (event, url) => {
    if (isNavigationAllowed(url)) return
    event.preventDefault()
    refuse(url)
  })

  // target="_blank" and window.open never get a window of their own here.
  wc.setWindowOpenHandler(({ url }) => {
    fail(tab, `Blocked a pop-up to ${shortLabel(url)}.`)
    return { action: 'deny' }
  })

  wc.on('did-start-loading', () => push(tab))
  wc.on('did-stop-loading', () => push(tab))
  wc.on('page-title-updated', () => push(tab))
  wc.on('did-navigate', () => {
    tab.error = null
    push(tab)
  })
  wc.on('did-navigate-in-page', (_event, _url, isMainFrame) => {
    if (isMainFrame) push(tab)
  })

  // Every document gets a fresh copy of the preload, so inspection has to be
  // switched back on after each navigation or it silently stops working.
  wc.on('dom-ready', () => {
    tellGuest(tab)
    push(tab)
  })

  wc.on('did-fail-load', (_event, errorCode, errorDescription, _url, isMainFrame) => {
    // -3 is ABORTED, which is what a normal interrupted navigation reports.
    if (!isMainFrame || errorCode === -3) return
    fail(tab, `${errorDescription || 'The page failed to load'} (${errorCode})`)
  })

  wc.on('render-process-gone', (_event, details) => {
    fail(tab, `The page crashed (${details.reason}).`)
  })

  wc.on('unresponsive', () => fail(tab, 'The page stopped responding.'))

  // A view can also die without anyone asking it to — a crashed guest process,
  // or a window taking its whole child tree down. Without this the entry stays
  // in the map holding a dead view forever, and every guest message afterwards
  // walks it.
  wc.once('destroyed', () => {
    tabs.delete(tab.id)
  })
}

/* ------------------------------------------------------------- captures -- */

/**
 * Only the tab's own top document may speak.
 *
 * Fail closed. `senderFrame` is null once the sending frame has navigated or
 * been destroyed, and older Electron throws instead of returning null — so
 * "no frame" has to mean refuse. Treating it as "must be the main frame, then"
 * lets a subframe's message through whenever the frame goes away between the
 * send and the receipt, which is a race an embedded ad frame can lose on
 * purpose. The cost of being strict is a dropped capture the user can redo.
 */
function isFromMainFrame(event: IpcMainEvent, wc: WebContents): boolean {
  try {
    const frame = event.senderFrame
    return frame !== null && frame === wc.mainFrame
  } catch {
    return false
  }
}

/** Find the tab a guest message came from, or null when it came from anywhere else. */
function tabForSender(event: IpcMainEvent): BrowserTab | null {
  for (const tab of tabs.values()) {
    const wc = liveContents(tab)
    if (!wc || wc.id !== event.sender.id) continue
    return isFromMainFrame(event, wc) ? tab : null
  }
  return null
}

/* -------------------------------------------------------------- register -- */

/**
 * Wire the embedded browser into the app. Call once from `registerIpc()`:
 *
 *     import { registerBrowserIpc } from './browser-tab'
 *     registerBrowserIpc(ipcMain)
 *
 * Channels (all take the tab id returned by `browser:create`):
 * - `browser:create`   (invoke, {url?, bounds?, visible?, isolationKey?}) → {@link BrowserTabState}
 * - `browser:navigate` (invoke, id, url)                   → {@link BrowserTabState}
 * - `browser:back` / `browser:forward` / `browser:reload` / `browser:stop`
 * - `browser:inspect`  (invoke, id, enabled)               → {@link BrowserTabState}
 * - `browser:state`    (invoke, id)                        → {@link BrowserTabState} | null
 * - `browser:close`    (invoke, id)
 * - `browser:bounds`   (send, id, {x,y,width,height})
 * - `browser:visible`  (send, id, boolean)
 *
 * Emits `browser:state-changed` (state) and `browser:element` (id, capture).
 */
export function registerBrowserIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser:create', (event: IpcMainInvokeEvent, options: unknown) => {
    const window = BrowserWindow.fromWebContents(event.sender)
    if (!window) throw new Error('browser: no window to attach to')

    const opts = (typeof options === 'object' && options !== null ? options : {}) as Record<
      string,
      unknown
    >

    const view = new WebContentsView({
      webPreferences: {
        // An `isolationKey` means this tab was opened as Isolated and gets its
        // own in-memory partition — see `browser-isolation.ts`. A session is
        // fixed at construction and cannot be swapped afterwards, which is why
        // the choice has to be made here rather than bolted on later.
        preload: preloadPath(),
        session: isolatedSession(opts.isolationKey) ?? hardenedGuestSession(),
        contextIsolation: true,
        nodeIntegration: false,
        nodeIntegrationInSubFrames: false,
        sandbox: true,
        webSecurity: true,
        allowRunningInsecureContent: false,
        experimentalFeatures: false,
        webviewTag: false,
        spellcheck: false,
        safeDialogs: true,
        // A guest alert() would block the app's own window until dismissed.
        disableDialogs: true,
        autoplayPolicy: 'user-gesture-required',
      },
    })
    // Pages assume an opaque backdrop; without this the app shows through.
    view.setBackgroundColor('#ffffff')

    const tab: BrowserTab = {
      id: randomUUID(),
      view,
      host: event.sender,
      window,
      bounds: sanitizeBounds(opts.bounds),
      visible: opts.visible !== false,
      inspecting: false,
      error: null,
    }
    tabs.set(tab.id, tab)

    window.contentView.addChildView(view)
    applyLayout(tab)
    wireGuestEvents(tab)

    // One listener per host, not per tab, or reopening tabs stacks them up.
    if (!watchedHosts.has(event.sender)) {
      watchedHosts.add(event.sender)
      event.sender.once('destroyed', () => destroyTabsFor(event.sender))
    }

    if (typeof opts.url === 'string' && opts.url.trim() !== '') return navigate(tab, opts.url)
    // An unhandled rejection here takes the main process down with it, and this
    // load rejects routinely: React StrictMode mounts the panel twice, so the
    // first view is closed while its about:blank load is still in flight.
    view.webContents.loadURL(BLANK_URL).catch(() => undefined)
    return stateOf(tab)
  })

  ipcMain.handle('browser:navigate', (_event, id: unknown, url: unknown) =>
    navigate(requireTab(id), url),
  )

  ipcMain.handle('browser:reload', (_event, id: unknown) => {
    const tab = requireTab(id)
    tab.error = null
    liveContents(tab)?.reload()
    return stateOf(tab)
  })

  ipcMain.handle('browser:stop', (_event, id: unknown) => {
    const tab = requireTab(id)
    liveContents(tab)?.stop()
    return stateOf(tab)
  })

  ipcMain.handle('browser:back', (_event, id: unknown) => {
    const tab = requireTab(id)
    const history = liveContents(tab)?.navigationHistory
    if (history?.canGoBack()) history.goBack()
    return stateOf(tab)
  })

  ipcMain.handle('browser:forward', (_event, id: unknown) => {
    const tab = requireTab(id)
    const history = liveContents(tab)?.navigationHistory
    if (history?.canGoForward()) history.goForward()
    return stateOf(tab)
  })

  ipcMain.handle('browser:inspect', (_event, id: unknown, enabled: unknown) => {
    const tab = requireTab(id)
    tab.inspecting = enabled === true
    tellGuest(tab)
    return stateOf(tab)
  })

  ipcMain.handle('browser:state', (_event, id: unknown) => {
    const tab = typeof id === 'string' ? tabs.get(id) : undefined
    return tab ? stateOf(tab) : null
  })

  ipcMain.handle('browser:close', (_event, id: unknown) => {
    const tab = typeof id === 'string' ? tabs.get(id) : undefined
    if (tab) destroyTab(tab)
  })

  ipcMain.on('browser:bounds', (_event, id: unknown, bounds: unknown) => {
    const tab = typeof id === 'string' ? tabs.get(id) : undefined
    if (!tab) return
    tab.bounds = sanitizeBounds(bounds)
    applyLayout(tab)
  })

  ipcMain.on('browser:visible', (_event, id: unknown, visible: unknown) => {
    const tab = typeof id === 'string' ? tabs.get(id) : undefined
    if (!tab) return
    tab.visible = visible === true
    applyLayout(tab)
  })

  /* ---- from the guest page. Everything below here is hostile until proven otherwise. */

  ipcMain.on(GUEST_ELEMENT_CHANNEL, (event: IpcMainEvent, payload: unknown) => {
    const tab = tabForSender(event)
    if (!tab || !tab.inspecting) return

    // The URL comes from our own view, never from the payload: a page that
    // could forge this message must not also get to name the site the agent
    // is told it is editing.
    const wc = liveContents(tab)
    if (!wc) return
    const capture = parseCapture(payload, wc.getURL())
    if (!capture) return

    const message: BrowserCapture = { ...capture, context: composeAgentContext(capture) }
    if (!tab.host.isDestroyed()) tab.host.send('browser:element', tab.id, message)
  })

  ipcMain.on(GUEST_CANCEL_CHANNEL, (event: IpcMainEvent) => {
    const tab = tabForSender(event)
    if (!tab) return
    tab.inspecting = false
    push(tab)
  })
}
