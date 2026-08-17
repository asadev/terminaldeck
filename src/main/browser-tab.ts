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
import { backgroundFor, safeBackground } from './browser-background'
import { isAbortCode, loadFailureSentence } from './browser-error'
import { BLANK_URL, isNavigationAllowed, normalizeUrl, pageTitle, shortLabel } from './browser-url'
import {
  GUEST_CANCEL_CHANNEL,
  GUEST_ELEMENT_CHANNEL,
  GUEST_INSPECT_CHANNEL,
  writeGuestPreload,
} from './browser-preload'
import { composeAgentContext, parseCapture, type ElementCapture } from './selector'
import { isolatedSession } from './browser-isolation'
import { onWebContentsDestroyed } from './web-contents-teardown'

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
  /**
   * True while the *document in the view* is Chromium's own error page.
   *
   * Separate from {@link error}, and the distinction is the whole point. A
   * refused pop-up sets `error` and leaves a perfectly good page on screen; a
   * connection that was refused sets `error` AND replaces the document with a
   * red exclamation mark and `ERR_CONNECTION_REFUSED`. Only the second one must
   * make the renderer hide the native view and put its own written page there
   * instead, and a boolean is the only way it can tell them apart — the error
   * *text* is a sentence in both cases by design.
   */
  failed: boolean
}

/** What the renderer receives for a captured element. */
export interface BrowserCapture extends ElementCapture {
  /** The single line to hand the agent, already sanitised. */
  context: string
  /**
   * The page as it looked at the instant of the click, as a `data:image/jpeg`.
   *
   * ## Why a picture of the page is part of a capture
   *
   * The popup is HTML and the page is a native `WebContentsView` composited
   * above the entire renderer, so the only way to show a popup over a page at
   * all is to hide the page while it is open — `overlay-watch.ts` is the essay
   * on why there is no other lever. Hiding it leaves the app's empty canvas
   * where the website was, and a website that vanishes when you click it reads
   * as a crash, not as a dialog.
   *
   * So the page is captured *before* it is hidden and the renderer paints that
   * capture on the same rectangle. The website appears to freeze under the
   * popup instead of disappearing, which is what actually happens: the
   * WebContents keeps running, it is simply not composited.
   *
   * It is a real photograph of the real page and nothing else — not a
   * reconstruction, not a placeholder. Empty when the capture failed, in which
   * case the renderer shows its own canvas and the popup, as it did before.
   *
   * JPEG rather than PNG: this crosses the bridge as base64 on every click while
   * inspecting, and a full-window PNG is several megabytes where the JPEG is a
   * few hundred kilobytes. It is a backdrop behind a dialog; the file a
   * screenshot writes to disk is still a lossless PNG.
   */
  pageImage: string
  /**
   * Where the element sat inside the view when it was clicked, in CSS pixels.
   *
   * Carried so the renderer can open its capture popup *at* the element rather
   * than in a docked panel at the bottom of the window — his words on
   * 2026-08-16: *"rather than it comes here down, it should open a pop up
   * here"*. Null when the page reported nothing usable, which the renderer
   * treats as "put it somewhere sensible" rather than as a failure.
   *
   * Read off the raw payload rather than through `parseCapture`, because it is
   * geometry rather than a selector: `selector.ts` decides what may reach an
   * agent's prompt, and a rectangle never does. It is still clamped here — the
   * numbers come from an untrusted page and end up in a `style` attribute.
   */
  rect: CaptureRect | null
}

/**
 * How wide the frozen backdrop is, in device pixels, and how hard it is squeezed.
 *
 * It is drawn behind a dialog at whatever size the page's rectangle happens to
 * be — usually around 1000 CSS pixels — so 1600 is generous even on a Retina
 * display. Quality 80 is where JPEG stops showing ringing around body text at
 * this scale, and it is roughly a tenth of the bytes of the equivalent PNG.
 */
const FREEZE_WIDTH = 1600
const FREEZE_QUALITY = 80

/**
 * A photograph of the page right now, as a data URL, or an empty string.
 *
 * Never throws and never rejects. Every caller is on the path between a user's
 * click and the popup that answers it, and a backdrop is the least important
 * thing on that path: if the capture fails, the popup opens over the app's own
 * canvas exactly as it did before this existed.
 */
async function freezeFrame(wc: WebContents): Promise<string> {
  try {
    const image = await wc.capturePage()
    const size = image.getSize()
    if (size.width === 0 || size.height === 0) return ''
    const scaled = size.width > FREEZE_WIDTH ? image.resize({ width: FREEZE_WIDTH }) : image
    return `data:image/jpeg;base64,${scaled.toJPEG(FREEZE_QUALITY).toString('base64')}`
  } catch {
    return ''
  }
}

/** The clicked element's box, in the view's own CSS pixels. */
export interface CaptureRect {
  x: number
  y: number
  width: number
  height: number
}

/**
 * A rectangle from the guest, or null.
 *
 * Every number is finite and clamped to a range a viewport could plausibly
 * hold. That is not paranoia about arithmetic: the value is interpolated into
 * an inline `style` on our own trusted page, and `1e308` there is a layout that
 * never recovers.
 */
export function readCaptureRect(raw: unknown): CaptureRect | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  const numbers = [r.x, r.y, r.width, r.height]
  if (!numbers.every((value) => typeof value === 'number' && Number.isFinite(value))) return null
  const clamp = (value: number, low: number): number => Math.max(low, Math.min(100000, value))
  return {
    x: clamp(r.x as number, -100000),
    y: clamp(r.y as number, -100000),
    width: clamp(r.width as number, 0),
    height: clamp(r.height as number, 0),
  }
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
  /**
   * The address whose load failed, while that failure is still what the view
   * holds. Null the rest of the time.
   *
   * A URL rather than a flag, because of the order Chromium reports things in.
   * A failed main-frame load fires `did-fail-load` and *then* commits its error
   * document — which is a navigation, so `did-navigate` fires too, with the
   * failed URL. A boolean cleared on `did-navigate` would therefore be switched
   * off by the very error page it exists to describe, and the user would be back
   * looking at `ERR_CONNECTION_REFUSED` with no message anywhere. Comparing the
   * URL survives that ordering whichever way round Electron emits the two.
   */
  failedUrl: string | null
  /** The app's own canvas colour, for a view with nothing loaded in it. */
  emptyBackground: string | null
}

/**
 * Separate from the app's own session so guest cookies, storage and — most
 * importantly — response headers are handled independently of Deck's.
 */
const GUEST_PARTITION = 'persist:terminaldeck-browser'

const tabs = new Map<string, BrowserTab>()

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
    // Not `wc.getTitle()` — Chromium substitutes the address for a document
    // with no `<title>`, which is how the start page came to call itself
    // `about:blank`. See `pageTitle`.
    title: pageTitle(wc ? wc.getTitle() : '', url),
    loading: wc ? wc.isLoading() : false,
    canGoBack: wc ? wc.navigationHistory.canGoBack() : false,
    canGoForward: wc ? wc.navigationHistory.canGoForward() : false,
    inspecting: tab.inspecting,
    error: tab.error,
    failed: tab.failedUrl !== null,
  }
}

function push(tab: BrowserTab): void {
  if (tab.host.isDestroyed()) return
  tab.host.send('browser:state-changed', stateOf(tab))
}

/**
 * Something went wrong, but the page in the view is still the user's page.
 *
 * A refused pop-up, a blocked `file:` link, an unresponsive renderer: the
 * message belongs in the banner and the document stays. Contrast {@link crash},
 * which is for the cases where Chromium has replaced the document.
 */
function fail(tab: BrowserTab, message: string): void {
  tab.error = message
  push(tab)
}

/** The document itself is gone — Chromium's error page is what is on screen. */
function crash(tab: BrowserTab, message: string, url: string): void {
  tab.error = message
  tab.failedUrl = url
  push(tab)
}

/** Starting a fresh attempt: whatever was on screen stops being the story. */
function clearFailure(tab: BrowserTab): void {
  tab.error = null
  tab.failedUrl = null
}

/**
 * Keep the view's backdrop matching what is about to be in it.
 *
 * Called on the way *into* a navigation rather than out of one: `did-navigate`
 * arrives after the document has committed, so switching there shows a frame of
 * the previous colour first. See `browser-background.ts` for why this is not
 * simply "always the app's colour".
 */
function paintBackdrop(tab: BrowserTab, url: string): void {
  if (!liveContents(tab)) return
  tab.view.setBackgroundColor(backgroundFor(url, tab.emptyBackground))
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

  clearFailure(tab)
  paintBackdrop(tab, result.url)
  void wc.loadURL(result.url).catch((error: unknown) => {
    // A load rejection is routine — an aborted navigation rejects too, and so
    // does every load still in flight when the tab closes. Only worth
    // surfacing when the tab is still around with nothing on it.
    //
    // `did-fail-load` has usually already written a better sentence by the time
    // this runs, and it also knows the numeric code, so this only speaks when
    // nothing else did. The message is the rejection's, which is Chromium's own
    // `ERR_… (-n)` string — machine text, but the alternative here is silence.
    const message = error instanceof Error ? error.message : String(error)
    const still = liveContents(tab)
    if (still && still.getURL() === '' && tab.failedUrl === null) {
      crash(tab, `Could not open ${shortLabel(result.url)}: ${message}`, result.url)
    }
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

  // The backdrop follows the destination, one event before it paints. A
  // same-document navigation swaps no document, so it swaps no colour either.
  wc.on('did-start-navigation', (details: { url: string; isMainFrame: boolean; isSameDocument: boolean }) => {
    if (!details.isMainFrame || details.isSameDocument) return
    paintBackdrop(tab, details.url)
  })

  wc.on('did-start-loading', () => push(tab))
  wc.on('did-stop-loading', () => push(tab))
  wc.on('page-title-updated', () => push(tab))
  wc.on('did-navigate', (_event: unknown, url: string) => {
    // Only a navigation that landed somewhere ELSE clears the failure. The
    // error page Chromium commits after a failed load is itself a navigation,
    // and it arrives carrying the URL that just failed — so `tab.error = null`
    // here used to wipe the message a heartbeat after `did-fail-load` wrote it,
    // leaving the raw Chromium page on screen with nothing explaining it. See
    // `BrowserTab.failedUrl`.
    if (tab.failedUrl !== null && url === tab.failedUrl) {
      push(tab)
      return
    }
    clearFailure(tab)
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

  wc.on('did-fail-load', (_event, errorCode, errorDescription, url, isMainFrame) => {
    if (!isMainFrame || isAbortCode(errorCode)) return
    // A written sentence, not `ERR_CONNECTION_REFUSED (-102)` — see
    // `browser-error.ts`. `failedUrl` is what makes the renderer put that
    // sentence on screen INSTEAD of Chromium's error document rather than
    // underneath it, which is what the recording caught.
    crash(tab, loadFailureSentence(errorCode, errorDescription, url), url)
  })

  wc.on('render-process-gone', (_event, details) => {
    // The document is gone with the process, so this is a `crash` rather than a
    // `fail`: there is no page left for a banner to sit on top of.
    const wc = liveContents(tab)
    crash(tab, `The page crashed (${details.reason}).`, wc ? wc.getURL() : '')
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
 * - `browser:create`   (invoke, {url?, bounds?, visible?, isolationKey?, background?}) → {@link BrowserTabState}
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
    // The app's content canvas, read out of `tokens.css` by the renderer and
    // sent across — the main process cannot see a stylesheet, and a hex literal
    // here is what made an empty tab a white rectangle in dark mode. Null when
    // the renderer sent nothing usable, which `backgroundFor` handles.
    const emptyBackground = safeBackground(opts.background)

    const tab: BrowserTab = {
      id: randomUUID(),
      view,
      host: event.sender,
      window,
      bounds: sanitizeBounds(opts.bounds),
      visible: opts.visible !== false,
      inspecting: false,
      error: null,
      failedUrl: null,
      emptyBackground,
    }
    tabs.set(tab.id, tab)

    // Pages assume an opaque backdrop; without one the app shows through. Which
    // opaque backdrop depends on what is about to be in the view — see
    // `browser-background.ts`, which explains at length why this is not simply
    // the theme colour in every case.
    view.setBackgroundColor(
      backgroundFor(typeof opts.url === 'string' ? opts.url : '', emptyBackground),
    )

    window.contentView.addChildView(view)
    applyLayout(tab)
    wireGuestEvents(tab)

    // One registration per host, not per tab, or reopening tabs stacks them up
    // — and keyed, so the `watchedHosts` set that used to enforce that is gone.
    // See `web-contents-teardown.ts`.
    onWebContentsDestroyed(event.sender, 'browser-tabs', () => destroyTabsFor(event.sender))

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
    // Both halves, not just the message. Reload is the one control whose entire
    // purpose is "try that same address again", so it is also the one place
    // where the *same* URL succeeding has to be able to clear a failure that
    // `did-navigate` deliberately refuses to clear on a URL match.
    clearFailure(tab)
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
    // Only when it actually moves. Clearing on a `canGoBack()` of false would
    // wipe the failure message while leaving the error page it describes.
    if (history?.canGoBack()) {
      clearFailure(tab)
      history.goBack()
    }
    return stateOf(tab)
  })

  ipcMain.handle('browser:forward', (_event, id: unknown) => {
    const tab = requireTab(id)
    const history = liveContents(tab)?.navigationHistory
    if (history?.canGoForward()) {
      clearFailure(tab)
      history.goForward()
    }
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

    const rect = readCaptureRect(
      typeof payload === 'object' && payload !== null
        ? (payload as Record<string, unknown>).rect
        : null,
    )

    /*
     * Photograph the page, then send.
     *
     * In that order, and awaited rather than sent afterwards as a second
     * message. The renderer hides the native view the moment the popup opens,
     * and `capturePage` on a hidden view fails outright — verified on Electron
     * 41, where it answers "Current display surface not available for capture".
     * Sending the capture first and the picture second would therefore race its
     * own consequence. The cost is the tens of milliseconds between the click
     * and the popup, which reads as the click being answered.
     */
    void freezeFrame(wc).then((pageImage) => {
      const message: BrowserCapture = {
        ...capture,
        context: composeAgentContext(capture),
        pageImage,
        rect,
      }
      if (!tab.host.isDestroyed()) tab.host.send('browser:element', tab.id, message)
    })
  })

  ipcMain.on(GUEST_CANCEL_CHANNEL, (event: IpcMainEvent) => {
    const tab = tabForSender(event)
    if (!tab) return
    tab.inspecting = false
    push(tab)
  })
}
