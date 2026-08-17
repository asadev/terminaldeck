import {
  BrowserWindow,
  Menu,
  clipboard,
  shell,
  type IpcMain,
  type IpcMainInvokeEvent,
  type MenuItemConstructorOptions,
  type WebContents,
} from 'electron'
import { isNavigationAllowed } from './browser-url'

/**
 * Where a link opens: a tab of this app's own browser, or the system browser.
 *
 * ## What was wrong
 *
 * Asad, 2026-08-17: *"currently it's opening a separate window — I want it to
 * use the same window inside Terminal Deck for browser."*
 *
 * Two unrelated pieces of code produced that one symptom, and they were failing
 * in opposite directions:
 *
 *  - The **app shell** sent every link out. `index.ts` denied every window-open
 *    request and handed the URL to `shell.openExternal`, so pressing a
 *    repository, a pull request or an issue in the GitHub panel launched Chrome
 *    — while the app had a perfectly good browser of its own, in the window the
 *    user was already looking at.
 *  - The **browser panel** let nothing out *or* in. A `target="_blank"` link in
 *    a page hit `setWindowOpenHandler` in `browser-tab.ts`, which answered
 *    `{ action: 'deny' }` and wrote *"Blocked a pop-up to X."* over the page.
 *    Refusing a bare Electron window was right — a `WebContentsView` guest must
 *    never get a window of Chromium's, with no address bar, no tab strip and
 *    none of this app's navigation gate on it. The conclusion was wrong: the
 *    destination should become a tab of **ours**, which is a window of the
 *    app's rather than one of Chromium's.
 *
 * Both now land in the same place — a browser tab in the workspace strip —
 * through the one decision below, so the two halves cannot drift apart again.
 *
 * ## The asymmetry, which is deliberate and is the security posture
 *
 * The app shell and a guest page are *not* the same caller and do not get the
 * same answer for a link this browser cannot render:
 *
 *  - {@link routeAppLink} is for the app's own React tree. Code we wrote asking
 *    for a `mailto:` or a `file://` reveal means it, so anything that is not
 *    http(s) goes to the system, minus the handful of schemes at
 *    {@link NEVER_LEAVES} that are script or in-process URLs rather than
 *    documents.
 *  - {@link routeGuestLink} is for an untrusted website. It can return `'tab'`
 *    or `'refused'` and **never** `'system'`. That is not caution for its own
 *    sake: `browser-tab.ts` refuses `file:` on `will-navigate`,
 *    `will-frame-navigate` and `will-redirect` precisely so a page cannot walk
 *    the view onto the user's disk, and a page that could say
 *    `window.open('file:///Users/...')` and have the main process hand it to
 *    Launch Services would step straight over all three. The gate does not get
 *    weaker because a new door was cut next to it.
 *
 * ## Why the app shell's decision is made here and not at each call site
 *
 * Because there is exactly one door out of the renderer and it is
 * `window.open`. Every link in the app funnels through it into
 * `setWindowOpenHandler`, so routing it here fixes the GitHub panel's six call
 * sites, plus every `<a target="_blank">` anyone writes later, in one place. A
 * per-call-site fix would have been six edits and a seventh bug the first time
 * somebody added a link and reached for the old habit.
 */

/* ------------------------------------------------------------------ routes -- */

/** Where a link should go. */
export type LinkRoute = 'tab' | 'system' | 'refused'

/**
 * Schemes that never reach `shell.openExternal`, whoever asks.
 *
 * These are not documents. `javascript:` and `vbscript:` are code, `data:` and
 * `blob:` are bytes with a MIME type attached, and the rest address something
 * inside a browser process rather than out on the machine. Handing any of them
 * to the OS is either a no-op or a scripting hole, and the URLs the GitHub
 * panel opens come off a network response — a scheme check is cheaper than
 * trusting GitHub's JSON for ever.
 */
const NEVER_LEAVES: ReadonlySet<string> = new Set([
  'javascript:',
  'vbscript:',
  'data:',
  'blob:',
  'about:',
  'chrome:',
  'chrome-extension:',
  'devtools:',
  'filesystem:',
  'view-source:',
])

/** The scheme of a URL, lower-cased and with its colon, or null. */
function schemeOf(url: string): string | null {
  const match = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(url.trim())
  return match ? `${match[1].toLowerCase()}:` : null
}

/**
 * Whether this URL is something the machine could be asked to open.
 *
 * A scheme it has, and not one of the in-process ones. Note that `about:blank`
 * fails here while passing {@link routeAppLink} — an empty tab is a perfectly
 * good thing for this app to open and a meaningless thing to hand to Launch
 * Services — which is why the two questions are asked separately.
 */
export function canOpenOutside(url: unknown): boolean {
  if (typeof url !== 'string' || url.trim() === '') return false
  const scheme = schemeOf(url)
  return scheme !== null && !NEVER_LEAVES.has(scheme)
}

/**
 * Where a link from **this app's own renderer** should open.
 *
 * `isNavigationAllowed` is the test for "can this open inside", reused rather
 * than restated: it is the same predicate `browser-tab.ts` gates every guest
 * navigation with, so a URL that would open in a tab is by construction a URL
 * that tab is allowed to keep. `about:blank` passes it — that is what an empty
 * view holds — and a blank tab is exactly what a browser gives you for
 * `window.open()` with no arguments, so it is left to go the same way.
 */
export function routeAppLink(url: unknown): LinkRoute {
  if (typeof url !== 'string' || url.trim() === '') return 'refused'
  if (isNavigationAllowed(url)) return 'tab'
  const scheme = schemeOf(url)
  // No scheme at all is a relative URL, which means nothing outside a document
  // and certainly nothing to Launch Services.
  if (!scheme || NEVER_LEAVES.has(scheme)) return 'refused'
  return 'system'
}

/**
 * Where a link from **an untrusted guest page** should open.
 *
 * Never `'system'`. See the asymmetry note at the top of this file — this is
 * the half that keeps `file:` out of the user's hands via a website.
 */
export function routeGuestLink(url: unknown): LinkRoute {
  if (typeof url !== 'string' || url.trim() === '') return 'refused'
  return isNavigationAllowed(url) ? 'tab' : 'refused'
}

/* ----------------------------------------------------------------- channels -- */

/**
 * Main → renderer: open this URL as a browser tab in the workspace strip.
 *
 * Pushed rather than answered, because the decision starts in the main process
 * (a window-open request Chromium hands us) and the tab is a renderer object —
 * a `browser:` entry in `App.tsx`'s tab list, which is what the strip draws.
 * The renderer treats it exactly like the globe: a new window, kept at the end
 * of the strip, active. See `keepInStrip` in `renderer/browser/workspace-strip.ts`.
 *
 * `src/main/link-open.channels.test.ts` pins this against the preload's
 * subscription; the two files cannot see each other and have been out of step
 * before — see `browser-view.channels.test.ts` for the shipped version of that
 * bug.
 */
export const LINK_TAB_CHANNEL = 'link:open-tab'

/* ------------------------------------------------------------------ doing it -- */

/**
 * Open a URL on the machine, refusing the schemes that are not documents.
 *
 * Returns whether it was handed over, so the caller can say so — a silent
 * refusal of a link somebody pressed is indistinguishable from a broken button.
 */
export function openSystemUrl(url: unknown): boolean {
  if (!canOpenOutside(url)) return false
  void shell.openExternal(url as string).catch(() => undefined)
  return true
}

/**
 * Route a link the **app shell** asked to open, and say what was done with it.
 *
 * The host is the renderer that asked — the same WebContents the tab will
 * appear in, so a second window would open its own tab rather than pushing one
 * into somebody else's.
 */
export function openAppLink(host: WebContents, url: unknown): LinkRoute {
  const route = routeAppLink(url)
  if (route === 'tab' && !host.isDestroyed()) host.send(LINK_TAB_CHANNEL, url)
  else if (route === 'system') openSystemUrl(url)
  return route
}

/**
 * Route a link a **guest page** asked to open. `'refused'` means the caller
 * should say so on the page — `browser-tab.ts` owns that sentence, because it
 * owns the banner it goes in.
 */
export function openGuestLink(host: WebContents, url: unknown): LinkRoute {
  const route = routeGuestLink(url)
  if (route === 'tab' && !host.isDestroyed()) host.send(LINK_TAB_CHANNEL, url)
  return route
}

/* --------------------------------------------------------------- the way out -- */

/**
 * The escape hatch: right-click anything that opens a link.
 *
 * In-app is now the default, and a default is not a prison. Some links want the
 * browser the person is already signed into — a private repository, a payment
 * page, anything with a passkey on it — and this is how they get there without
 * a setting. It is deliberately *not* a Settings toggle: a preference that
 * flips every link at once answers a question nobody asked, where the real one
 * is always about one particular link.
 *
 * A native menu rather than an HTML one, for three reasons: it is the platform
 * menu on macOS and looks it, it can be popped over a native `WebContentsView`
 * (an HTML menu cannot — the guest composites above the entire renderer, which
 * is the whole subject of `overlay-watch.ts`), and it costs the renderer one
 * `onContextMenu` handler instead of a component.
 */
export function showLinkMenu(window: BrowserWindow | null, url: unknown): boolean {
  if (typeof url !== 'string' || url.trim() === '') return false
  if (!window || window.isDestroyed()) return false

  const items: MenuItemConstructorOptions[] = []
  // Anything the machine could be asked to open. The exclusions are the
  // in-process schemes, where the item would be a button that does nothing —
  // worse than an item that is not there.
  if (canOpenOutside(url)) {
    items.push({
      label: 'Open in System Browser',
      click: () => {
        openSystemUrl(url)
      },
    })
  }
  items.push({
    label: 'Copy Link',
    click: () => clipboard.writeText(url),
  })

  Menu.buildFromTemplate(items).popup({ window })
  return true
}

/* ---------------------------------------------------------------------- ipc -- */

/**
 * Wire the two renderer-facing channels. Call once from `registerIpc()`:
 *
 *     import { registerLinkIpc } from './link-open'
 *     registerLinkIpc(ipcMain)
 *
 * - `link:system` (invoke, url) → boolean — the explicit way out, for a
 *   renderer that has decided a URL belongs in the real browser. Used by the
 *   context menu's own item and by `App.tsx` when the browser feature is not
 *   installed, because a link still has to open then.
 * - `link:menu`   (invoke, url) → boolean — pop {@link showLinkMenu} at the
 *   pointer, over the window that asked.
 *
 * Emits {@link LINK_TAB_CHANNEL}.
 */
export function registerLinkIpc(ipcMain: IpcMain): void {
  ipcMain.handle('link:system', (_event: IpcMainInvokeEvent, url: unknown) => openSystemUrl(url))
  ipcMain.handle('link:menu', (event: IpcMainInvokeEvent, url: unknown) =>
    showLinkMenu(BrowserWindow.fromWebContents(event.sender), url),
  )
}
