import { BrowserWindow, type Session, type WebContents } from 'electron'
import { isNavigationAllowed, shortLabel } from './browser-url'

/**
 * Sign-in pop-ups: the window `window.open()` has to actually return.
 *
 * ## The bug this file is the fix for
 *
 * From the recorded review of 2026-08-17, of the in-app browser: a QR *"appeared
 * and then stopped"*, the flow *"pushed him out to an external browser"*, and —
 * the one he said twice — **the verification link gets stuck**.
 *
 * They are one bug. Until now every `window.open` from a guest page was answered
 * `{ action: 'deny' }` and the destination was opened as a separate tab in the
 * workspace strip instead. That is a good answer for a link and a broken one for
 * a sign-in, because of what `deny` does to the *calling* page. Measured on
 * Electron 41.10.5 on 2026-08-18:
 *
 *     handler answer   window.open() returned   child window created
 *     deny             null                     no
 *     allow            a Window                 yes
 *
 * Every OAuth and magic-link flow on the web is written against the first
 * column being a window. The library opens the pop-up, keeps the handle, and
 * then either polls `popup.closed` or waits for `postMessage` from it — and the
 * handle it is given is `null`, so it waits for a message that can never arrive
 * from a window it does not have. The tab in the strip does complete the
 * sign-in; it simply has no way to tell the page that opened it. **That is
 * "the verification link gets stuck", exactly.**
 *
 * ## Which requests become a window, and why not all of them
 *
 * Dispositions, also measured on the same build:
 *
 *     window.open(url, 'oauth', 'width=500,height=600')  new-window     frameName 'oauth'
 *     window.open(url, 'oauth2')                         foreground-tab frameName 'oauth2'
 *     window.open(url)                                   foreground-tab frameName ''
 *     window.open(url, '_blank')                         foreground-tab frameName ''
 *     <a target="_blank"> clicked                        foreground-tab frameName ''
 *
 * So a real pop-up — sized, or named so the opener can find it again — is
 * exactly `new-window`, or a non-empty frame name. Everything else is a link,
 * and links keep the behaviour that already works: a tab in the strip, with this
 * app's chrome and this app's navigation guards. `_blank` normalises to an empty
 * name, so an ordinary link cannot slip through this test.
 *
 * ## The security property that was right, kept
 *
 * `browser-tab.ts` refuses to hand a guest a bare Electron window, and the
 * reason it gave is still true: a window with no guards is one a page can open
 * and then walk anywhere. So this does not hand over a bare window. The child
 * gets the **same session** as its opener, the same sandbox and context
 * isolation, the same `will-navigate` / `will-frame-navigate` / `will-redirect`
 * refusals, the same treatment of its own pop-ups, and — because a person is
 * about to type a password into it — its address in the title bar, rewritten on
 * every navigation.
 *
 * What it deliberately does not have is a preload. The guest preload fills
 * saved logins and reports elements while inspecting; neither is wanted in a
 * transient sign-in window, and the smaller the surface a third party's
 * authorisation page is given, the better.
 */

/** A pop-up smaller than this is unusable; larger than this is a browser window. */
const MIN = { width: 320, height: 360 }
const MAX = { width: 1280, height: 1024 }
const FALLBACK = { width: 520, height: 680 }

export interface WindowOpenAsk {
  url: string
  frameName: string
  disposition: string
  features: string
}

/**
 * Is this ask a sign-in pop-up rather than a link?
 *
 * Pure, so the routing rule is a test rather than something only a live OAuth
 * flow can prove. See the table above for where each value came from.
 */
export function wantsPopupWindow(ask: WindowOpenAsk): boolean {
  if (!isNavigationAllowed(ask.url) && ask.url !== 'about:blank') return false
  if (ask.disposition === 'new-window') return true
  // A *string* with something in it. Real Electron always sends one, but the
  // default for a missing field is the one that matters: `undefined !== ''` is
  // true, so a looser test would turn every ordinary link into a window the
  // moment anything upstream handed over a partial object. Failing closed here
  // costs a pop-up somebody can reopen; failing open costs the tab strip.
  return typeof ask.frameName === 'string' && ask.frameName !== ''
}

/**
 * The size the page asked for, clamped to something a person can use.
 *
 * A features string is written by whoever wrote the page, and pages get it
 * wrong: `width=1` is a real value on real sites, used when a pop-up is a
 * transport rather than a screen. Clamping rather than obeying means such a
 * window is visible and closable instead of a one-pixel artefact in the corner
 * of the display.
 */
export function popupSize(features: string): { width: number; height: number } {
  const read = (name: string): number | null => {
    const match = new RegExp(`\\b${name}\\s*=\\s*(\\d+)`).exec(features)
    return match ? Number.parseInt(match[1], 10) : null
  }
  const clamp = (value: number | null, min: number, max: number, fallback: number): number => {
    if (value === null || !Number.isFinite(value)) return fallback
    return Math.min(max, Math.max(min, value))
  }
  return {
    width: clamp(read('width') ?? read('innerWidth'), MIN.width, MAX.width, FALLBACK.width),
    height: clamp(read('height') ?? read('innerHeight'), MIN.height, MAX.height, FALLBACK.height),
  }
}

/**
 * What a sign-in window is called, so the address is visible while a password is
 * being typed into it.
 *
 * The origin leads, because that is the security-relevant half and a page can
 * write anything it likes into its own `<title>`. The document's title follows
 * it when it has one worth showing.
 */
export function popupTitle(url: string, documentTitle: string): string {
  const origin = ((): string => {
    try {
      return new URL(url).host
    } catch {
      return shortLabel(url)
    }
  })()
  const tidy = documentTitle.trim()
  if (origin === '') return tidy
  return tidy === '' || tidy === origin ? origin : `${origin} — ${tidy}`
}

/**
 * The options handed back with `{ action: 'allow' }`.
 *
 * `session` is passed explicitly rather than inherited. It is inherited in
 * practice, but a sign-in window landing on the wrong cookie jar would sign
 * somebody into the wrong profile — the one failure in this file that would be
 * silent and permanent — so it is stated where it can be read.
 */
export function popupWindowOptions(
  ask: WindowOpenAsk,
  guest: Session,
): Electron.BrowserWindowConstructorOptions {
  const size = popupSize(ask.features)
  return {
    width: size.width,
    height: size.height,
    // A real title bar, because the title is where the address is shown. A
    // frameless sign-in window would be a password prompt with no way to see
    // whose page it is, which is worse than no pop-up at all.
    frame: true,
    // Sign-in windows are transient and belong on top of the work they
    // interrupted, but not on top of every other application.
    alwaysOnTop: false,
    autoHideMenuBar: true,
    webPreferences: {
      session: guest,
      contextIsolation: true,
      nodeIntegration: false,
      nodeIntegrationInSubFrames: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      webviewTag: false,
      // Deliberately no preload — see the note at the top of this file.
    },
  }
}

/**
 * Wire the guards onto a pop-up Electron has just created.
 *
 * Called from `did-create-window`. Everything here mirrors `wireGuestEvents` in
 * `browser-tab.ts`; it is written out rather than shared because that function
 * also does progress, backdrops, titles, inspection and failure pages for a view
 * that lives inside the app's own layout, none of which a transient window has
 * or wants.
 */
export function wirePopupWindow(popup: BrowserWindow, guest: Session): void {
  const wc = popup.webContents

  const refuse = (event: { preventDefault(): void }, url: string): void => {
    if (isNavigationAllowed(url)) return
    event.preventDefault()
  }
  wc.on('will-navigate', (event, url) => refuse(event, url))
  wc.on('will-frame-navigate', (details) => refuse(details, details.url))
  wc.on('will-redirect', (event, url) => refuse(event, url))

  // Chained pop-ups are real: a provider's consent page opening its own
  // identity chooser is two windows, and refusing the second one strands the
  // first. Same rule, one level down.
  wc.setWindowOpenHandler((details) => {
    const ask: WindowOpenAsk = {
      url: details.url,
      frameName: details.frameName,
      disposition: details.disposition,
      features: details.features,
    }
    if (!wantsPopupWindow(ask)) return { action: 'deny' }
    return { action: 'allow', overrideBrowserWindowOptions: popupWindowOptions(ask, guest) }
  })

  wc.on('did-create-window', (child) => wirePopupWindow(child, guest))

  const retitle = (): void => {
    if (popup.isDestroyed() || wc.isDestroyed()) return
    popup.setTitle(popupTitle(wc.getURL(), wc.getTitle()))
  }
  // `preventDefault` stops Chromium putting the document's own title up on its
  // own; without it the origin is overwritten a frame later by whatever the
  // page calls itself.
  wc.on('page-title-updated', (event) => {
    event.preventDefault()
    retitle()
  })
  wc.on('did-navigate', retitle)
  wc.on('did-navigate-in-page', retitle)
  retitle()
}

/**
 * Track pop-ups belonging to a guest, so they close with it.
 *
 * A sign-in window whose opener has gone is a window with no way back into the
 * app and no explanation of what it is. Electron's `outlivesOpener` is false by
 * default for the contents, but the *window* stays; this closes it.
 */
export function closePopupsWith(opener: WebContents, popups: Set<BrowserWindow>): void {
  opener.once('destroyed', () => {
    for (const popup of popups) {
      if (!popup.isDestroyed()) popup.close()
    }
    popups.clear()
  })
}
