import { randomUUID } from 'node:crypto'
import {
  app,
  BrowserWindow,
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
  GUEST_LOGIN_FILL_CHANNEL,
  GUEST_LOGIN_READY_CHANNEL,
  GUEST_LOGIN_SUBMIT_CHANNEL,
  writeGuestPreload,
} from './browser-preload'
import { composeAgentContext, parseCapture, type ElementCapture } from './selector'
import { disposeIsolatedSession, isolatedSession } from './browser-isolation'
import { onWebContentsDestroyed } from './web-contents-teardown'
import { openGuestLink } from './link-open'
import { showGuestContextMenu } from './browser-context-menu'
import { cleanUserAgent } from './browser-user-agent'
import { baseZoom, fitPageToPane, forgetFit, resetFit } from './browser-fit'
import { activeProfile, DEFAULT_PARTITION, sessionForPartition } from './browser-profiles'
import { workerSessionFor } from './browser-workers'
import { rememberVisit } from './browser-history'
import {
  closePopupsWith,
  popupWindowOptions,
  wantsPopupWindow,
  wirePopupWindow,
  type WindowOpenAsk,
} from './browser-popup'
import {
  allLogins,
  isNewLogin,
  loginsFor,
  originOf,
  setPendingOffer,
  type SavedLogin,
} from './browser-passwords'
import { mayAutofill, stampDocument } from './browser-fill-gate'
import { personArmHolds, watchTabForScraping } from './browser-profile-arm'

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
 * ## Who decides a view is on screen, and why it is not the renderer
 *
 * It used to be the renderer, alone. `browser:visible` latched a boolean and
 * `applyLayout` obeyed it, so a view stayed composited until somebody said
 * otherwise — and the only somebody was one React effect inside
 * `BrowserWorkspace.tsx`. An effect reports while it is mounted and says nothing
 * at all when it stops, which meant "the renderer is showing this page" and "the
 * renderer has gone silent" were the same message on the wire: none.
 *
 * That produced the bug this section exists for. Press ⌘R with a page open —
 * `{ role: 'reload' }` is in the app menu — and the renderer's document is
 * replaced. React unmount cleanups do not run for a page unload, so nothing
 * closed the views and nothing hid them; the host WebContents is the same object
 * across a reload, so the `destroyed` teardown below did not fire either. The
 * fresh renderer came back with no browser tab in its strip and no idea any view
 * existed, while the old `WebContentsView` stayed a child of the window at its
 * last rectangle, still composited above the whole renderer. Photographed on
 * 2026-08-17: `example.com` painted over a live Claude Code session, with the
 * agent's own status line visible along the bottom of the window underneath it.
 *
 * So the decision moved here, and it is stated as a rule over facts this process
 * can check for itself at the moment it applies a layout — see
 * {@link shouldComposite}. The renderer's message is now one input among several
 * rather than the whole answer, and every other input is something the renderer
 * cannot lie about and cannot go quiet on:
 *
 *  - **the host's document generation.** Each tab records which renderer
 *    document asked for it. The host's main-frame navigations are counted here,
 *    so a reload, a crash-and-restore or any other document swap makes every tab
 *    that document opened permanently stale — and a stale tab is never
 *    composited, whatever it last reported.
 *  - **the host being alive**, and **its window being alive**. A dead renderer
 *    cannot own a view, and a destroyed window cannot show one.
 *  - **the rectangle having area**, which is the older half of the rule.
 *
 * The same three events that make a tab stale also destroy it, because a view
 * whose renderer is gone has nobody left to position it, close it or read
 * anything out of it. The generation check is not redundant with that: it is the
 * part that holds if a destroy is ever missed, and — unlike a teardown — it is a
 * pure function a test can drive without an Electron window.
 *
 * The rule is deliberately one-directional. Nothing here can tell that a live
 * renderer's *reasons* for showing a page have gone stale — a dialog it forgot
 * to report, a menu it opened over the page — and it does not try. Those fail as
 * a popup hidden behind a website, which is annoying and visible. This fails as
 * somebody's terminal disappearing under a web page, which is neither.
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
  /**
   * The page's zoom factor, 1 unless something has changed it.
   *
   * Sent so the window can draw the truth: this app zooms a page out by itself
   * when its layout will not fit the pane — see `browser-fit.ts` — and the
   * toolbar's zoom chip is both how that is announced and how it is undone.
   */
  zoom: number
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
  /**
   * The last thing the renderer asked for — a request, not a verdict.
   *
   * Renamed from `visible` when the decision moved into the main process, and
   * the name is the point: this field alone used to *be* whether the view was on
   * screen, which is how a renderer that stopped talking left a page over
   * somebody's terminal. {@link shouldComposite} is the verdict now, and this is
   * one of its inputs.
   */
  wanted: boolean
  /**
   * Which renderer document opened this tab.
   *
   * Compared against the host's current generation on every layout. A reload
   * replaces the document, the generation moves on, and every tab the previous
   * document opened is stale for good — so an orphan cannot be composited even
   * in the window between the navigation starting and its teardown running.
   */
  bornInto: number
  /**
   * The in-memory partition this tab was given, when it was opened as Isolated.
   *
   * Held here so it can be thrown away with the view. The renderer used to be
   * the only thing that disposed these, on the same unmount path that used to be
   * the only thing that closed the view — so a reload leaked one cookie jar per
   * isolated tab for the rest of the process's life, invisibly. Disposal is
   * idempotent, so the renderer keeping its own call for tabs whose view never
   * got created costs nothing.
   */
  isolationKey: string | null
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
  /**
   * The browser profile this tab's session belongs to, stamped at creation.
   *
   * Stamped and never updated, for the same reason `bornInto` is: a session is
   * fixed when the view is constructed, so a tab opened in one profile stays in
   * it even after somebody switches. Read when a saved login is looked up, so
   * that switching profile while a sign-in page is open cannot offer the other
   * profile's password to it.
   */
  profileId: string
  /**
   * Was the document currently in this view committed while an agent held it?
   *
   * The whole of the state `browser-fill-gate.ts` needs and cannot read off a
   * live page for itself: whether the debugger is attached is a fact about
   * *now*, and this is a fact about the moment the document landed. Set at
   * `did-navigate`, which is the only place a document changes.
   *
   * Starts false because a view's first document is `about:blank`, loaded by
   * this module before anything could possibly be driving it.
   */
  documentFromAgent: boolean
  /**
   * The sign-in form this document last announced, and what is saved for it.
   *
   * Held so the renderer can offer the login on a press without asking the page
   * again — and so that a page which announced once, was withheld from, and then
   * had its form re-rendered does not lose the offer. Null whenever the current
   * document has not said it has a sign-in form.
   *
   * Usernames only. This is the same {@link SavedLoginSummary} bargain one file
   * over: there is no password in this shape and nowhere to put one.
   */
  signIn: { origin: string; usernames: string[] } | null
  /**
   * The pending re-fit for this tab, so a drag produces one measurement.
   *
   * `browser:bounds` arrives on every frame of a window resize or a divider
   * drag, and fitting runs a script in the page — sixty of those a second for a
   * rectangle still moving is work for an answer that is wrong by the time it
   * lands. Cleared and re-armed on each bounds message, so it fires once the
   * pane has stopped moving. See `browser-fit.ts`.
   */
  fitTimer: ReturnType<typeof setTimeout> | null
  /** The zoom last reported to the window, so an unchanged one costs no message. */
  zoom: number
}

/**
 * Separate from the app's own session so guest cookies, storage and — most
 * importantly — response headers are handled independently of Deck's.
 *
 * This is now the *default profile's* partition rather than the only one. A
 * second profile is a second `persist:` string and a second directory — see
 * `browser-profiles.ts`, which owns the list and is careful never to mint one
 * that could collide with this. The literal stays spelled out here because
 * `browser-session.test.ts` reads this file looking for it, and because the one
 * partition that predates profiles is worth being able to find by eye.
 */
const GUEST_PARTITION = 'persist:terminaldeck-browser'

const tabs = new Map<string, BrowserTab>()

let guestPreloadPath: string | null = null

/**
 * Sign-in windows a guest page opened, so they can be closed with it.
 *
 * Keyed by the host renderer rather than by the tab: a pop-up outlives the tab
 * that opened it often enough — some flows close the opener and finish in the
 * pop-up — and what it must not outlive is the window it belongs to.
 */
const popupsByHost = new Map<number, Set<BrowserWindow>>()

/* ------------------------------------------------------- who owns a view -- */

/**
 * How many documents each renderer has been through.
 *
 * Zero for a renderer that has not navigated since its first tab was opened,
 * which is the ordinary case for the whole life of the app. It only moves when
 * the document the tabs were opened against is replaced — a ⌘R, a
 * `location.reload()`, a renderer that crashed and came back — and the number
 * itself means nothing beyond "not the one that was there before".
 *
 * A `WeakMap` so a closed window's entry goes with it: the key is the renderer's
 * own WebContents, and nothing here should be the reason it stays reachable.
 */
const hostDocuments = new WeakMap<WebContents, number>()

/** Renderers already being watched, so repeat creates do not stack listeners. */
const watchedHosts = new WeakSet<WebContents>()

/** Windows already being watched, for the same reason. */
const watchedWindows = new WeakSet<BrowserWindow>()

function documentOf(host: WebContents): number {
  return hostDocuments.get(host) ?? 0
}

/**
 * Everything this process checks before a native view is painted over the app.
 *
 * Exported and pure because it is the whole of the fix and an effect is the one
 * place a rule cannot be tested — the same reason `pageVisible` was pulled out
 * of the renderer's effect. Every field is a fact the main process reads for
 * itself at the moment of the call, except {@link wanted}, which is the only
 * thing the renderer gets a say in.
 *
 * Ordered as it reads: what was asked for, whether there is room for it, and
 * then the three ways the thing that asked can have ceased to exist.
 */
export interface CompositeCheck {
  /** The last visibility the renderer asked for, over `browser:visible`. */
  wanted: boolean
  width: number
  height: number
  /** The renderer that opened this tab has not been destroyed. */
  hostAlive: boolean
  /** The window this view is a child of has not been destroyed. */
  windowAlive: boolean
  /** Which host document opened the tab. */
  bornInto: number
  /** Which host document the renderer is on now. */
  hostDocument: number
}

/**
 * Should this view be composited right now?
 *
 * A conjunction on purpose: every clause is a hide, and a hide is always the
 * safe answer. The failure this replaced was a *latch* — one boolean, set by a
 * message, cleared only by another message that stopped coming — and the whole
 * change is that no single input can hold a view on screen by itself any more.
 *
 * `bornInto === hostDocument` is the clause that ends the reported bug. A view
 * belongs to the renderer document that asked for it; when that document is
 * replaced, the number moves and this can never be true again for that tab. It
 * costs one integer compare per layout and it does not depend on any teardown
 * having run, which is precisely the property the old arrangement lacked.
 *
 * A zero-sized view is still treated as hidden, which is the older half of this
 * rule and is not tidiness: `setVisible(true)` on a 0x0 view paints a white
 * sliver at its origin.
 */
export function shouldComposite(check: CompositeCheck): boolean {
  return (
    check.wanted &&
    check.width > 0 &&
    check.height > 0 &&
    check.hostAlive &&
    check.windowAlive &&
    check.bornInto === check.hostDocument
  )
}

/* -------------------------------------------------------------- plumbing -- */

/** Written once per launch; a file left by an older version would run stale code. */
function preloadPath(): string {
  if (guestPreloadPath === null) guestPreloadPath = writeGuestPreload(app.getPath('userData'))
  return guestPreloadPath
}

/**
 * The session a new tab joins: whichever profile is switched on.
 *
 * The hardening — no camera, no clipboard, no notifications — moved into
 * `browser-profiles.ts` so that every profile gets it rather than only the first
 * one, and so there is one copy of the list instead of two that can drift.
 * Downloads were on that list and are not any more: `browser-downloads.ts` takes
 * `will-download` there, for the reason written on `harden()` itself.
 * `sessionForPartition` is idempotent per partition.
 *
 * The user agent is set here, on the session, and it is not cosmetic: with
 * Electron's own token in the string Google routes every sign-in down its
 * restricted path. `browser-user-agent.ts` carries the measurement.
 */
function hardenedGuestSession(): Session {
  const profile = activeProfile(app.getPath('userData'))
  const ses = sessionForPartition(profile.partition)
  ses.setUserAgent(cleanUserAgent(app.userAgentFallback))
  return ses
}

/**
 * The session for a **worker** profile, or null for anything else.
 *
 * The `profileId` on a `browser:create` arrives from the renderer, and
 * `fromPartition` will make a directory for any string it is handed — so the
 * decision of whether this id may name a jar is not taken here. It is taken in
 * `browser-workers.ts`, which answers null unless the id is in its own
 * registry, and the registry can only be added to from the Workers panel.
 *
 * The user agent is set for the same reason `hardenedGuestSession` sets it: a
 * worker whose UA still carried Electron's token would be routed down Google's
 * restricted sign-in path, which is precisely the thing a worker is for.
 */
function workerSession(profileId: unknown): Session | null {
  const ses = workerSessionFor(app.getPath('userData'), profileId)
  if (ses === null) return null
  ses.setUserAgent(cleanUserAgent(app.userAgentFallback))
  return ses
}

/**
 * The partition constant above and the profiles module have to agree.
 *
 * A compile-time assertion rather than a comment, because the failure it
 * prevents is silent: two spellings of the default partition would give the
 * cookie panel one cookie jar and the tabs another, and everything would look
 * like it worked until somebody signed in and the login was not there.
 */
const _partitionsAgree: typeof DEFAULT_PARTITION = GUEST_PARTITION
void _partitionsAgree

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

/**
 * Is an agent holding this page right now?
 *
 * Answered by asking Chromium whether the CDP debugger is attached, rather than
 * by consulting a map this module keeps in step with the drive. That is not
 * shorthand: `browser-driver.ts:attach` holds the attachment for the whole of
 * a drive rather than per command, and `detach` releases it. A second copy of
 * that fact is a second thing to get wrong, and getting it wrong in the
 * optimistic direction means a password typed into a page an agent chose.
 *
 * There are exactly two callers of `wc.debugger.attach` in this repository:
 * the drive, and `browser-profile-arm.ts`, which arms a page from the
 * *person's own* stored scraping settings with no agent anywhere near it. The
 * second one is subtracted here through {@link personArmHolds}, which answers
 * true only while its own attachment is the sole reason the debugger is on —
 * the drive's `attach()` tells it to stand down before any agent command can
 * be sent, so the subtraction can never cover a page an agent could act on.
 * Without the subtraction, storing a fulfil rule for a profile would silently
 * switch off password autofill on every page of that profile — a control
 * with a side effect nobody asked for, on the panel built to remove those.
 *
 * `browser-fill-gate.ts` carries the argument for why this is the right breadth
 * — in particular why it stays true while a drive is parked in `human` waiting
 * for the person, which is exactly when a credential is wanted and exactly when
 * the press has to be theirs.
 */
function agentHolds(tab: BrowserTab): boolean {
  const wc = liveContents(tab)
  if (!wc) return false
  try {
    return wc.debugger.isAttached() && !personArmHolds(wc)
  } catch {
    // A view mid-teardown. Nothing is going to be filled into it either way,
    // and the answer that withholds is the one to give when unsure.
    return true
  }
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
    /*
     * What the page is actually zoomed to.
     *
     * On the state rather than left to the renderer's own copy, because the
     * renderer is no longer the only thing that sets it: `browser-fit.ts` zooms
     * a page out when its layout is wider than the pane, and a window still
     * showing the number *it* last asked for would put "100%" on a page at 92%
     * — which is the toolbar chip lying about the one fact it exists to state.
     */
    zoom: tab.zoom,
  }
}

function push(tab: BrowserTab): void {
  if (tab.host.isDestroyed()) return
  tab.host.send('browser:state-changed', stateOf(tab))
}

/**
 * Tell the app's own window that this page has a sign-in form and a login for
 * it — and, when the fill was withheld, why.
 *
 * ## What crosses, and what does not
 *
 * The origin, the usernames, whether a fill happened and one sentence. **No
 * password**, in the shape or anywhere near it, which is the rule
 * `browser-passwords.ts` states at length and the reason its renderer-facing
 * type has no field to forget to strip.
 *
 * ## Why usernames are on it at all
 *
 * Because the alternative is a button that says "Fill saved login" over a site
 * somebody has two accounts on, which fills one of them and gives no way to
 * say which. That is the shape of complaint this store already had — it filled
 * the newest and the manager was the only place to change it, which is a
 * different window, in a different pane, behind a different control. A list of
 * names on the page is the answer, and a username is not a secret: it is on the
 * screen the person is looking at, typed into the form.
 */
function tellHostAboutSignIn(tab: BrowserTab, message: string, filled: boolean): void {
  if (tab.host.isDestroyed() || tab.signIn === null) return
  tab.host.send(
    'browser:login-available',
    tab.id,
    tab.signIn.origin,
    tab.signIn.usernames,
    filled,
    message,
  )
}

/**
 * Write this page into the profile's browsing history.
 *
 * The URL and the title are read from the *view* rather than taken from the
 * event wherever they can be, for the reason the login handlers above give: what
 * Chromium committed is the fact, and an argument is what something claimed. The
 * two parameters are for the events that carry a value the view has not caught
 * up with yet — `page-title-updated` fires with the new title before
 * `getTitle()` returns it, and `did-navigate` with the new URL.
 *
 * Everything about *which* pages are remembered lives in `browser-history.ts`,
 * including the rule that an Isolated tab (`profileId === ''`) records nothing.
 * This function knows only where to read the two strings.
 */
function recordVisit(tab: BrowserTab, title?: string, url?: string): void {
  const wc = liveContents(tab)
  if (!wc && url === undefined) return
  const where = url ?? (wc ? wc.getURL() : '')
  // Chromium's error document is a page with an address and a title of its own,
  // and it titles itself a moment after it commits — so without this the
  // `did-navigate` guard below would be undone by the `page-title-updated` that
  // follows it, and a page that never loaded would be in the history under
  // Chromium's own wording.
  if (tab.failedUrl !== null && where === tab.failedUrl) return
  rememberVisit(app.getPath('userData'), {
    profileId: tab.profileId,
    url: where,
    title: title ?? (wc ? wc.getTitle() : ''),
  })
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

/** The tab's own answer to {@link shouldComposite}, read off the live objects. */
function compositeCheck(tab: BrowserTab): CompositeCheck {
  return {
    wanted: tab.wanted,
    width: tab.bounds.width,
    height: tab.bounds.height,
    hostAlive: !tab.host.isDestroyed(),
    windowAlive: !tab.window.isDestroyed(),
    bornInto: tab.bornInto,
    hostDocument: documentOf(tab.host),
  }
}

function applyLayout(tab: BrowserTab): void {
  if (!liveContents(tab)) return
  // A destroyed window's `contentView` is gone, so positioning a child of it is
  // a throw rather than a no-op. The visibility rule refuses it too, but the
  // bounds call happens first and has to be guarded on its own.
  if (tab.window.isDestroyed()) return
  tab.view.setBounds(tab.bounds)
  tab.view.setVisible(shouldComposite(compositeCheck(tab)))
}

/* ------------------------------------------------------------- fitting -- */

/** How long the pane has to hold still before the page is measured against it. */
const FIT_SETTLE_MS = 180

/**
 * Measure this page against its pane once things have stopped moving.
 *
 * Armed from the two places the answer can change — the pane's rectangle and a
 * new document — and never from anywhere else, because every other route into
 * this ends up running a script in somebody's page for no reason.
 *
 * The timer is cleared on teardown with the rest of the tab. A fit that lands
 * after the view has gone is a no-op inside `fitPageToPane`, which checks the
 * page again on the far side of its own round trip.
 */
function scheduleFit(tab: BrowserTab, delay = FIT_SETTLE_MS): void {
  if (tab.fitTimer !== null) clearTimeout(tab.fitTimer)
  tab.fitTimer = setTimeout(() => {
    tab.fitTimer = null
    const page = liveContents(tab)
    if (!page) return
    void fitPageToPane(tab.id, page)
      .then((zoom) => {
        if (zoom === null || zoom === tab.zoom) return
        tab.zoom = zoom
        push(tab)
      })
      .catch(() => undefined)
  }, delay)
}

/**
 * A new document is on its way in: put the zoom back before it arrives.
 *
 * Without this the next page inherits the last one's fit. Chromium keeps zoom
 * *per origin* inside a partition, so leaving 92% on `chromewebstore.google.com`
 * would also be writing it into the person's stored preference for that site —
 * a number this app chose for a window shape, remembered for every future visit
 * in every window. Restoring first keeps what is persisted equal to what they
 * actually chose.
 */
function unfit(tab: BrowserTab): void {
  if (tab.fitTimer !== null) {
    clearTimeout(tab.fitTimer)
    tab.fitTimer = null
  }
  const page = liveContents(tab)
  const base = baseZoom(tab.id)
  if (page && base !== null && page.getZoomFactor() !== base) {
    try {
      page.setZoomFactor(base)
    } catch {
      // The view is going away mid-navigation; there is no zoom left to restore.
    }
  }
  resetFit(tab.id)
  tab.zoom = base ?? 1
}

function tellGuest(tab: BrowserTab): void {
  liveContents(tab)?.send(GUEST_INSPECT_CHANNEL, tab.inspecting)
}

function destroyTab(tab: BrowserTab): void {
  tabs.delete(tab.id)
  /*
   * Hand the zoom back before the page goes, and cancel any fit still pending.
   *
   * The pending timer would run a script in a view on its way out, which is the
   * cheap half. The zoom is the half that outlives the process: Chromium keeps
   * it **per origin inside the partition**, on disk, so a tab closed — or an app
   * quit, which comes through here for every tab — while a page sat at 91%
   * would write 91% into that person's stored preference for that site, for
   * every future visit in every window. This app is allowed to fit a page to a
   * pane for as long as the pane is on screen; it is not allowed to leave that
   * decision behind as if they had made it.
   */
  unfit(tab)
  forgetFit(tab.id)
  /*
   * Off the screen first, by the same lever that put it there.
   *
   * Removing the child view is what actually un-composites it, and that is
   * exactly why this line is above it: `removeChildView` is skipped outright
   * when the window is already destroyed and is wrapped in a `try` because it
   * throws when the window is mid-teardown, so it is the one step here that is
   * allowed not to happen. Hiding first means "destroyed" and "not painted over
   * somebody's work" stop being two separate hopes.
   *
   * In a `try` for the same reason as the line below it: this also runs from a
   * window's own `closed`, where the view is a child of something that has
   * already gone, and a throw here would abandon every remaining tab in the loop
   * that called this.
   */
  try {
    if (liveContents(tab)) tab.view.setVisible(false)
  } catch {
    // Its window went first; it is not composited over anything either way.
  }
  if (!tab.window.isDestroyed()) {
    try {
      tab.window.contentView.removeChildView(tab.view)
    } catch {
      // The window may already be tearing its own view tree down.
    }
  }
  liveContents(tab)?.close()
  // An isolated tab's partition is held in memory for the life of the process
  // unless somebody lets go of it, and "somebody" used to be the renderer alone
  // — so every teardown the renderer does not run leaked one. Fire and forget:
  // this is on the teardown path, the storage was never on disk, and a rejected
  // clear must not stop the rest of the tabs being destroyed.
  if (tab.isolationKey) void disposeIsolatedSession(tab.isolationKey).catch(() => undefined)
}

/** Called from `before-quit`, and whenever a host window goes away. */
export function destroyAllBrowserTabs(): void {
  for (const tab of [...tabs.values()]) destroyTab(tab)
}

/**
 * The live contents of one tab, by the id `browser:create` handed back.
 *
 * The one way anything outside this module reaches a guest `WebContents`, and
 * it is deliberately the *only* way — `browser-driver.ts` takes a
 * `contentsFor(tabId)` function rather than an Electron object precisely so
 * that the set of pages a drive can ever touch is "tabs this module opened",
 * structurally, rather than "tabs somebody remembered to filter for".
 *
 * The app's own renderer is not in this map and cannot be put in it: entries
 * are only ever created by `browser:create`, which builds a fresh
 * `WebContentsView` in the guest partition. There is no code path from a
 * renderer's `WebContents` to a value in `tabs`, and adding one would mean
 * writing a function whose only purpose is to do that. `browser-cdp.test.ts`
 * pins the absence of the two calls — `getAllWebContents` and
 * `fromWebContents` — that would make one possible.
 *
 * Null covers three cases that are the same to a caller: no such id, a tab
 * whose view is gone, and a tab whose renderer took it down with a reload.
 */
export function browserTabContents(id: unknown): WebContents | null {
  const tab = typeof id === 'string' ? tabs.get(id) : undefined
  return tab ? liveContents(tab) : null
}

/**
 * Which browser profile a tab's page belongs to.
 *
 * `''` for a tab opened as Isolated, whose partition is in memory and belongs
 * to nothing that outlives the process — the same spelling {@link
 * BrowserTabState.profileId} already uses, so there are not two ways of saying
 * it. `null` when there is no such tab.
 *
 * Read by the drive, through `DriveHost.captureFolder`, so that a page's
 * captured traffic is filed under the cookie jar it was fetched with. A profile
 * is a separate person's logins; two profiles' captures sharing one folder
 * would put one sign-in's private JSON in with another's.
 */
export function browserTabProfile(id: unknown): string | null {
  const tab = typeof id === 'string' ? tabs.get(id) : undefined
  return tab ? tab.profileId : null
}

/**
 * Send one open view to an address — the body behind `browser:navigate`.
 *
 * Exported for a caller with no bridge to invoke on: a phone drives this
 * machine's browser through `machine-browser-desktop.ts`, which lives in this
 * process. It is this function rather than `contents.loadURL` for a reason worth
 * naming, because `loadURL` looks like it would do: {@link navigate} normalizes
 * the address, clears a standing failure and repaints the backdrop before the
 * document commits, and a caller that skipped it would leave the pane's error
 * banner over a page that had just loaded.
 */
export function navigateBrowserTab(id: unknown, url: unknown): BrowserTabState {
  return navigate(requireTab(id), url)
}

/**
 * Back, forward or reload on one open view — the bodies behind those three
 * channels, in one call because a caller that has a direction has one of three.
 *
 * The asymmetry between them is deliberate and is the desktop's, not this
 * function's: reload clears a failure unconditionally, because *"try that same
 * address again"* is the one control whose whole purpose is to make the same URL
 * succeed, and `did-navigate` refuses to clear on a URL match. Back and forward
 * clear only when the history actually moves, because clearing on a `canGoBack()`
 * of false would wipe the message while leaving the error page it describes.
 */
export function steerBrowserTab(id: unknown, move: 'back' | 'forward' | 'reload'): BrowserTabState {
  const tab = requireTab(id)
  const wc = liveContents(tab)
  if (move === 'reload') {
    clearFailure(tab)
    wc?.reload()
    return stateOf(tab)
  }
  const history = wc?.navigationHistory
  if (move === 'back' ? history?.canGoBack() : history?.canGoForward()) {
    clearFailure(tab)
    if (move === 'back') history?.goBack()
    else history?.goForward()
  }
  return stateOf(tab)
}

function destroyTabsFor(host: WebContents): void {
  for (const tab of [...tabs.values()]) {
    if (tab.host === host) destroyTab(tab)
  }
}

function destroyTabsIn(window: BrowserWindow): void {
  for (const tab of [...tabs.values()]) {
    if (tab.window === window) destroyTab(tab)
  }
}

/**
 * The renderer that owns these views has stopped being the renderer that owns
 * them: it is navigating away, or its process died.
 *
 * Two things, and the order matters. The generation moves *first*, so that from
 * this instant every one of that document's tabs fails
 * {@link shouldComposite} — nothing can paint one again even if something below
 * calls `applyLayout` on the way out. Then they are destroyed, because a view
 * whose renderer is gone has nobody to move it, resize it, close it or read
 * anything out of it; leaving it alive would be a Chromium process and a cookie
 * jar with no owner, which is the same leak wearing a tidier face.
 *
 * Destroying on the *start* of the navigation rather than at the end of it is
 * deliberate. The whole failure was a page still on screen after the document
 * that put it there had gone, so the correct moment is the earliest one — before
 * the new document has anything on screen to be covered. The cost is the case
 * where the navigation is then cancelled: the old document keeps running with
 * tab ids that no longer resolve, and its panel goes blank until it is reopened.
 * That is a degraded browser panel in a case that does not arise for a `file://`
 * bundle, weighed against a website permanently over somebody's work.
 */
function hostDocumentReplaced(host: WebContents): void {
  hostDocuments.set(host, documentOf(host) + 1)
  destroyTabsFor(host)
}

/**
 * Watch the renderer that just asked for a tab, once.
 *
 * Three ways a renderer stops being able to own a native view, and the first two
 * are the ones nobody was listening for:
 *
 *  - it **navigates its own main frame**, which is what ⌘R is. The WebContents
 *    survives a reload — same object, same id — so the `destroyed` registration
 *    below never fires for it, and that is exactly why the reported bug looked
 *    like nothing had happened at all.
 *  - its **process dies**. A crashed renderer is replaced in place, so again the
 *    WebContents is not destroyed and again nothing else notices.
 *  - it is **destroyed**, with its window. Already handled, and kept here so all
 *    three live in one place.
 *
 * A same-document navigation swaps no document, so it swaps no ownership;
 * subframes never owned anything to begin with. Both are ignored rather than
 * merely harmless — this app's renderer has no subframes and never assigns
 * `location`, which was checked before relying on it, so anything reaching the
 * first branch really is the document being replaced.
 */
function watchHost(host: WebContents): void {
  // Keyed rather than counted, so calling this on every create keeps exactly one
  // registration. See `web-contents-teardown.ts`, which exists because eleven
  // modules each being individually careful still produced a
  // `MaxListenersExceededWarning`.
  onWebContentsDestroyed(host, 'browser-tabs', () => destroyTabsFor(host))

  // The two below are plain `on`s on the WebContents itself — there is no keyed
  // registry for those — so this is the guard that keeps them at one apiece.
  // Without it, opening ten tabs would attach ten copies of each and Node would
  // report the same leak warning that registry was written to remove.
  if (watchedHosts.has(host)) return
  watchedHosts.add(host)

  host.on(
    'did-start-navigation',
    (details: { isMainFrame: boolean; isSameDocument: boolean }) => {
      if (!details.isMainFrame || details.isSameDocument) return
      hostDocumentReplaced(host)
    },
  )
  host.on('render-process-gone', () => hostDocumentReplaced(host))
}

/**
 * Watch the window these views are children of, once.
 *
 * Belt and braces rather than a second mechanism: closing a window destroys its
 * WebContents, so {@link watchHost}'s teardown already fires. This catches the
 * shape of that story where it does not — a window torn down without its
 * renderer going with it — and it costs one listener per window. `closed` rather
 * than `close` on purpose: `close` can be prevented, and destroying somebody's
 * open pages for a quit they then cancelled would be a worse bug than the one
 * this file is about.
 */
function watchWindow(window: BrowserWindow): void {
  if (watchedWindows.has(window)) return
  watchedWindows.add(window)
  window.once('closed', () => destroyTabsIn(window))
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

  /*
   * `target="_blank"` and `window.open`: a tab of ours, not a window of
   * Chromium's.
   *
   * The deny stays and is not the part that was wrong. A guest view must never
   * be handed a bare Electron window — it would have no toolbar, no address
   * bar, and none of the `will-navigate` / `will-frame-navigate` /
   * `will-redirect` guards above, so a page could open one and then walk it
   * anywhere. What was wrong was stopping there: the answer used to be
   * *"Blocked a pop-up to X."* written over the page, which is a browser
   * refusing to follow an ordinary link.
   *
   * So the destination becomes a **tab in the workspace strip** instead — a
   * window of the app's, created the same way the globe creates one, with the
   * same chrome and the same gate. `openGuestLink` pushes it at the renderer
   * that owns this view; `App.tsx` opens it and keeps it in the strip.
   *
   * Anything that is not http(s) is still refused outright, and is deliberately
   * NOT handed to `shell.openExternal` the way the app shell's own links are.
   * A website that could say `window.open('file:///Users/…')` and have the main
   * process give it to Launch Services would step over all three navigation
   * guards at once — see the asymmetry note in `link-open.ts`.
   */
  /*
   * ...and the exception that turned out to be most of what he hit.
   *
   * A **sign-in pop-up is not a link**, and answering it `deny` is what broke
   * every sign-in in the recorded review. `deny` makes the page's own
   * `window.open()` return `null` — measured on Electron 41.10.5 — so the
   * library that opened it waits forever for a `postMessage` from a window it
   * was never given. The destination did open, as a tab in the strip, and
   * finished the sign-in perfectly; it simply had no way to say so to the page
   * that asked. That is *"the verification link gets stuck"*, and the QR that
   * *"appeared and then stopped"*, and it is one bug.
   *
   * So a genuine pop-up — sized, or named, per the dispositions measured in
   * `browser-popup.ts` — is allowed and becomes a real child window with a real
   * opener, on this tab's own session, carrying the same navigation refusals
   * and its address in its title bar. Everything else is still a link and still
   * becomes a tab here, because that behaviour is right and he did not complain
   * about it.
   */
  wc.setWindowOpenHandler((details) => {
    const ask: WindowOpenAsk = {
      url: details.url,
      frameName: details.frameName,
      disposition: details.disposition,
      features: details.features,
    }
    if (wantsPopupWindow(ask)) {
      const guest = liveContents(tab)
      return {
        action: 'allow',
        overrideBrowserWindowOptions: popupWindowOptions(
          ask,
          guest ? guest.session : hardenedGuestSession(),
        ),
      }
    }
    if (openGuestLink(tab.host, details.url) === 'refused') {
      fail(
        tab,
        `Blocked a pop-up to ${shortLabel(details.url) || 'another scheme'} — only http and https open here.`,
      )
    }
    return { action: 'deny' }
  })

  /*
   * The window Electron just made, given the guards the handler promised.
   *
   * It has to happen here rather than inside the handler: the handler runs
   * *before* the window exists and may only return options. A pop-up wired
   * nowhere would be the bare Electron window this module has always refused to
   * hand a guest — no navigation checks, no address on screen.
   */
  wc.on('did-create-window', (popup) => {
    const guest = liveContents(tab)
    wirePopupWindow(popup, guest ? guest.session : hardenedGuestSession())
    const hostId = tab.host.id
    let owned = popupsByHost.get(hostId)
    if (!owned) {
      owned = new Set<BrowserWindow>()
      popupsByHost.set(hostId, owned)
      closePopupsWith(tab.host, owned)
      tab.host.once('destroyed', () => popupsByHost.delete(hostId))
    }
    owned.add(popup)
    popup.once('closed', () => owned?.delete(popup))
  })

  /*
   * The right-click menu, built from what was actually under the pointer.
   *
   * This used to be `showLinkMenu` — the app shell's two-item link menu, which
   * offers the system browser and a copied address and nothing else. Pointed at
   * a whole web page it answered the wrong question, and that is the defect
   * Asad recorded: *"only these two: copy link, not even select text."* The
   * browser's own menu lives in `browser-context-menu.ts`, which composes Copy,
   * Cut, Paste, Select All, the link and image items, Back/Forward/Reload and
   * Inspect out of `params` — and draws none of them unless `params.editFlags`
   * says the command can act.
   *
   * `tab.host` goes with it because "Open Link in New Tab" is a renderer object:
   * it travels the same `LINK_TAB_CHANNEL` a denied `window.open` does.
   */
  wc.on('context-menu', (_event, params) => {
    const page = liveContents(tab)
    if (!page) return
    showGuestContextMenu({ page, host: tab.host, window: tab.window }, params)
  })

  // The backdrop follows the destination, one event before it paints. A
  // same-document navigation swaps no document, so it swaps no colour either.
  wc.on('did-start-navigation', (details: { url: string; isMainFrame: boolean; isSameDocument: boolean }) => {
    if (!details.isMainFrame || details.isSameDocument) return
    paintBackdrop(tab, details.url)
    // The fit belonged to the document being replaced. See `unfit`.
    unfit(tab)
  })

  wc.on('did-start-loading', () => push(tab))
  wc.on('did-stop-loading', () => {
    push(tab)
    // The layout is only settled once the load is. A store measured at
    // `did-navigate` answers with the shell's width, not the page's.
    scheduleFit(tab)
  })
  /*
   * The title arrives after the navigation that carries it, so it is recorded
   * here as well as below.
   *
   * `did-navigate` fires the instant Chromium commits the document, which is
   * before the parser has reached `<title>` — so a history recorded only there
   * would be a column of bare URLs. `noteVisit` in `browser-history.ts` counts
   * the second write as the same row rather than a second visit, and never
   * blanks a title it already has.
   */
  wc.on('page-title-updated', (_event: unknown, title: string) => {
    recordVisit(tab, title)
    push(tab)
  })
  wc.on('did-navigate', (_event: unknown, url: string) => {
    /*
     * Who put this document here — the one fact `browser-fill-gate.ts` cannot
     * read off a live page later, because by then the drive may have let go.
     *
     * Before the early return below, deliberately: the error document Chromium
     * commits after a failed load is still a document, and one an agent's
     * navigation produced is still an agent's.
     */
    tab.documentFromAgent = stampDocument(agentHolds(tab))
    // A new document has announced nothing yet. Left standing, the previous
    // page's sign-in offer would sit in the panel over a page that has no form
    // on it, and pressing it would fill nothing.
    tab.signIn = null
    // Only a navigation that landed somewhere ELSE clears the failure. The
    // error page Chromium commits after a failed load is itself a navigation,
    // and it arrives carrying the URL that just failed — so `tab.error = null`
    // here used to wipe the message a heartbeat after `did-fail-load` wrote it,
    // leaving the raw Chromium page on screen with nothing explaining it. See
    // `BrowserTab.failedUrl`.
    if (tab.failedUrl !== null && url === tab.failedUrl) {
      // And nothing is written down either: this "navigation" is the error
      // document, and a history row for a page that never loaded is a row that
      // fails again when it is clicked.
      push(tab)
      return
    }
    // Where this browser has been, per profile — `browser-history.ts` says why
    // an Isolated tab is not in it. A committed navigation only, which is the
    // address a person can actually be sent back to.
    recordVisit(tab, undefined, url)
    clearFailure(tab)
    push(tab)
  })
  wc.on('did-navigate-in-page', (_event, url: string, isMainFrame: boolean) => {
    if (!isMainFrame) return
    // A route change an agent caused makes this an agent's page too, and this is
    // the only signal there is for it: the document did not change, so
    // `did-navigate` never fires. One-directional — a person's route change on
    // a page an agent already navigated does not hand it back, because the
    // agent chose the document underneath it.
    if (agentHolds(tab)) tab.documentFromAgent = true
    // A single-page app changes the address without changing the document, and
    // the place somebody wants back is the route they were on rather than the
    // shell it was served from. Chrome records these for the same reason.
    recordVisit(tab, undefined, url)
    push(tab)
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
 * - `browser:create`   (invoke, {url?, bounds?, visible?, isolationKey?, profileId?, background?}) → {@link BrowserTabState}
 * - `browser:navigate` (invoke, id, url)                   → {@link BrowserTabState}
 * - `browser:back` / `browser:forward` / `browser:reload` / `browser:stop`
 * - `browser:inspect`  (invoke, id, enabled)               → {@link BrowserTabState}
 * - `browser:state`    (invoke, id)                        → {@link BrowserTabState} | null
 * - `browser:close`    (invoke, id)
 * - `browser:bounds`   (send, id, {x,y,width,height})
 * - `browser:visible`  (send, id, boolean) — a *request*, see {@link shouldComposite}
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

    /*
     * A tab opened in a **worker profile**, rather than in the one switched on.
     *
     * `workerSession` answers null for every id that is not a registered worker
     * — including a perfectly real profile of his own — so this argument cannot
     * be used to open a page in the jar holding his bank login. The whole of
     * that refusal is in `browser-workers.ts`; the reason it has to exist is
     * that a session is fixed when a `WebContentsView` is constructed, so the
     * only way to put a page in a chosen jar is to choose here.
     *
     * Without it, worker profiles would be cookie jars nothing could browse in:
     * a session lifted into eight of them, and no way to open a page in any.
     */
    const worker = workerSession(opts.profileId)

    const view = new WebContentsView({
      webPreferences: {
        // An `isolationKey` means this tab was opened as Isolated and gets its
        // own in-memory partition — see `browser-isolation.ts`. A session is
        // fixed at construction and cannot be swapped afterwards, which is why
        // the choice has to be made here rather than bolted on later.
        preload: preloadPath(),
        session: isolatedSession(opts.isolationKey) ?? worker ?? hardenedGuestSession(),
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
      wanted: opts.visible !== false,
      // Stamped at creation and never touched again. A tab belongs to the
      // renderer document that asked for it; the moment that document is
      // replaced this number stops matching and the view can never be
      // composited again. See `shouldComposite`.
      bornInto: documentOf(event.sender),
      // Only a key this module recognises — `isolatedSession` above has already
      // refused anything else, and holding a string it would refuse would mean
      // teardown trying to dispose a partition that was never minted.
      isolationKey: isolatedSession(opts.isolationKey) ? (opts.isolationKey as string) : null,
      inspecting: false,
      error: null,
      failedUrl: null,
      emptyBackground,
      // An isolated tab is nobody's profile: its partition is in memory and dies
      // with the process, so a saved login must never be offered to it. The
      // empty string matches no profile id, which is exactly the behaviour
      // wanted and is why it is not defaulted to 'default'.
      profileId:
        isolatedSession(opts.isolationKey) !== null
          ? ''
          : worker !== null
            ? (opts.profileId as string)
            : activeProfile(app.getPath('userData')).id,
      documentFromAgent: false,
      signIn: null,
      fitTimer: null,
      zoom: 1,
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
    /*
     * The person's own scraping settings, armed on this tab's navigations —
     * see `browser-profile-arm.ts`. Watching costs two listeners until the
     * profile actually stores something; a profile with all-default settings
     * never gets a debugger attached. An Isolated tab has no profile and no
     * stored settings, so there is nothing to watch for one.
     */
    if (tab.profileId !== '') {
      watchTabForScraping({ tabId: tab.id, profileId: tab.profileId, contents: view.webContents })
    }
    // Everything that can take ownership of this view away, watched from the
    // side that survives it. Both are idempotent per host and per window.
    watchHost(event.sender)
    watchWindow(window)

    if (typeof opts.url === 'string' && opts.url.trim() !== '') return navigate(tab, opts.url)
    // An unhandled rejection here takes the main process down with it, and this
    // load rejects routinely: React StrictMode mounts the panel twice, so the
    // first view is closed while its about:blank load is still in flight.
    view.webContents.loadURL(BLANK_URL).catch(() => undefined)
    return stateOf(tab)
  })

  ipcMain.handle('browser:navigate', (_event, id: unknown, url: unknown) =>
    navigateBrowserTab(id, url),
  )

  ipcMain.handle('browser:reload', (_event, id: unknown) => steerBrowserTab(id, 'reload'))

  ipcMain.handle('browser:stop', (_event, id: unknown) => {
    const tab = requireTab(id)
    liveContents(tab)?.stop()
    return stateOf(tab)
  })

  ipcMain.handle('browser:back', (_event, id: unknown) => steerBrowserTab(id, 'back'))

  ipcMain.handle('browser:forward', (_event, id: unknown) => steerBrowserTab(id, 'forward'))

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
    const before = tab.bounds.width
    tab.bounds = sanitizeBounds(bounds)
    applyLayout(tab)
    // Only when the pane's *width* moved. Height has no bearing on whether a
    // layout fits, and the strip wrapping or a panel opening below sends a
    // stream of bounds that differ in nothing this cares about.
    if (tab.bounds.width !== before && tab.bounds.width > 0) scheduleFit(tab)
  })

  ipcMain.on('browser:visible', (_event, id: unknown, visible: unknown) => {
    const tab = typeof id === 'string' ? tabs.get(id) : undefined
    if (!tab) return
    // A request, recorded. Whether it is honoured is `shouldComposite`'s answer,
    // not this line's — which is the difference between this file today and the
    // one that let a reloaded window keep somebody's page over their terminal.
    tab.wanted = visible === true
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

  /*
   * A page saying it has a sign-in form, answered with a login if there is one.
   *
   * The origin is taken from *our* view and not from the message, exactly as the
   * element capture above does and for a sharper version of the same reason: a
   * page that could forge this message would otherwise name the origin whose
   * password it wants. `wc.getURL()` is what Chromium committed, so the worst a
   * hostile page can do by forging this is ask for the password it is already
   * entitled to be filled with.
   *
   * A tab that was opened Isolated has no profile and is skipped — an in-memory
   * partition thrown away at quit is not somewhere a saved credential belongs.
   */
  ipcMain.on(GUEST_LOGIN_READY_CHANNEL, (event: IpcMainEvent) => {
    const tab = tabForSender(event)
    if (!tab || tab.profileId === '') return
    const wc = liveContents(tab)
    if (!wc) return
    const origin = originOf(wc.getURL())
    if (origin === null) return
    const matches = loginsFor(allLogins(app.getPath('userData')), tab.profileId, origin)
    if (matches.length === 0) return

    /*
     * Newest first, so the head of this list is the account last used here —
     * the right guess, and the one Chrome makes. The rest are behind the picker
     * in the panel, which is the answer to "it filled the wrong account", a
     * complaint this store could not previously answer at all.
     */
    const ranked = [...matches].sort((a, b) => b.updatedAt - a.updatedAt)
    tab.signIn = { origin, usernames: ranked.map((item) => item.username) }

    /*
     * The gate. See `browser-fill-gate.ts` for the whole argument; the short
     * form is that a page an agent navigated to is never filled by itself,
     * because filling it is how an agent signs in as the person without ever
     * seeing a password.
     */
    const verdict = mayAutofill({
      agentHolding: agentHolds(tab),
      documentFromAgent: tab.documentFromAgent,
      isolated: false,
    })
    if (verdict.fill) {
      wc.send(GUEST_LOGIN_FILL_CHANNEL, ranked[0].username, ranked[0].password)
    }
    /*
     * Say something when there is something to say, and not otherwise.
     *
     * Two cases, and one silence:
     *
     *  - **Withheld.** Always said. A fill that did not happen with nothing on
     *    screen explaining it is the dead control this round is about, and the
     *    press that replaces it has to be somewhere.
     *  - **Filled, and there is more than one account here.** Said, because the
     *    fill picks the most recently saved and that is a *guess* — this bar is
     *    the only place on the page where a wrong guess is visible and
     *    switchable.
     *  - **Filled, and there is exactly one account.** Silent. Nothing was
     *    decided, nothing can be corrected, and a strip that shrinks the page on
     *    every sign-in form somebody has ever saved is friction bought with
     *    nothing.
     */
    if (!verdict.fill || ranked.length > 1) {
      tellHostAboutSignIn(tab, verdict.fill ? '' : verdict.message, verdict.fill)
    }
  })

  /*
   * A sign-in that was just submitted, held for the person to approve.
   *
   * It goes into a single pending slot in `browser-passwords.ts` and the
   * *renderer* is told only that an offer exists, with the origin and the
   * username. The password never crosses that bridge — see the note at the top
   * of that module. Nothing is stored until somebody presses Save.
   */
  ipcMain.on(
    GUEST_LOGIN_SUBMIT_CHANNEL,
    (event: IpcMainEvent, _url: unknown, username: unknown, password: unknown) => {
      const tab = tabForSender(event)
      if (!tab || tab.profileId === '') return
      const wc = liveContents(tab)
      if (!wc) return
      const origin = originOf(wc.getURL())
      if (origin === null) return
      if (typeof password !== 'string' || password === '') return
      const entry: SavedLogin = {
        profileId: tab.profileId,
        origin,
        username: typeof username === 'string' ? username : '',
        password,
        updatedAt: Date.now(),
      }
      // A form that submits the credentials it was just filled with is not a new
      // login, and prompting there would put a dialog in front of somebody every
      // single time they sign in to anything.
      if (!isNewLogin(allLogins(app.getPath('userData')), entry)) return
      setPendingOffer(entry)
      if (!tab.host.isDestroyed()) tab.host.send('browser:password-offer', tab.id, origin, entry.username)
    },
  )

  /*
   * Fill it because a person pressed something.
   *
   * ## Why this channel exists
   *
   * `browser-fill-gate.ts` withholds the automatic fill on any page an agent
   * navigated to or is holding. Withholding on its own would be resistance
   * dressed up as security: the person is looking at their own sign-in form,
   * their password is in this app, and the app declines to say so. This is the
   * other half — the panel says a saved login exists and this is what the press
   * calls.
   *
   * It is also the answer to a complaint the automatic fill could never
   * answer, on pages no agent has ever touched: **two accounts on one site**.
   * The fill picks the newest and, until now, the only way to use the other one
   * was Settings → Browser → Saved passwords → Copy → click the field → paste.
   * A name in a list on the page it belongs to is one press instead of six.
   *
   * ## Why an agent cannot reach it
   *
   * Two independent reasons, and the second is the one that holds if the first
   * is ever weakened:
   *
   *  - It is an `ipcMain.handle` channel. The tool surface is an MCP endpoint
   *    (`deck-control/server.ts`) with a written-out allow-list, and there is no
   *    bridge from it to `ipcMain` — the same door `browser-workers-ipc.ts`
   *    puts session-lifting behind, for the same reason, argued in
   *    `session-tools.ts`.
   *  - The sender is checked against the tab's own host renderer below. A guest
   *    page cannot invoke it anyway (the guest preload is sandboxed, exposes
   *    nothing through `contextBridge` and holds no `invoke`), and a page driven
   *    by CDP is a guest page — `browser-cdp.ts` denies `Runtime.evaluate`
   *    outright, so there is not even a script to try it from.
   *
   * ## What it answers
   *
   * Whether a fill was sent, and nothing else — the same bargain
   * `browser-password:copy` strikes one file over. There is no shape here that
   * carries a password back, so there is no future edit that forgets to strip
   * one.
   */
  ipcMain.handle(
    'browser-password:fill',
    (event: IpcMainInvokeEvent, id: unknown, username: unknown) => {
      const tab = typeof id === 'string' ? tabs.get(id) : undefined
      // The window that owns the tab, and no other renderer. Cheap, and it
      // means a second browser panel cannot fill a page it is not showing.
      if (!tab || tab.host !== event.sender) return false
      if (tab.profileId === '' || tab.signIn === null) return false
      const wc = liveContents(tab)
      if (!wc) return false
      /*
       * The origin comes from the *view*, not from the tab's remembered
       * announcement, for the reason the two handlers above give: what Chromium
       * committed is the fact. A page that announced a sign-in form and then
       * navigated between the announcement and the press would otherwise be
       * filled with the previous site's password.
       */
      const origin = originOf(wc.getURL())
      if (origin === null || origin !== tab.signIn.origin) return false
      const matches = loginsFor(allLogins(app.getPath('userData')), tab.profileId, origin)
      if (matches.length === 0) return false
      const wanted = typeof username === 'string' ? username : ''
      const chosen =
        matches.find((item) => item.username === wanted) ??
        matches.reduce((a, b) => (b.updatedAt > a.updatedAt ? b : a))
      // `true`: write over whatever is in the field. A person pressing this on
      // a form the browser already filled with the other account is the ordinary
      // case, and a press that silently declines is a dead control.
      wc.send(GUEST_LOGIN_FILL_CHANNEL, chosen.username, chosen.password, true)
      return true
    },
  )
}
