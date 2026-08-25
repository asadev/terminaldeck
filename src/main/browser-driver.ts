import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { BlockWatchDeps } from './browser-block-watch'
import { maskFrame, type RawFrame } from './browser-png'
import { userDataDir } from './platform/paths'
import { screenCommand, screenPersonCommand, type DriveState, type Transport } from './browser-cdp'
import {
  EMPTY_DRIVE_STATUS,
  HANDOVER_WINDOW_MS,
  nextDriveState,
  sanitizeHandoverPrompt,
  type DriveStatus,
  type HandoverOutcome,
} from './browser-drive'
import {
  looksSecret,
  OUTLINE_SCRIPT,
  PROBE_SCRIPT,
  SCROLL_SCRIPT,
  SECRET_RECTS_SCRIPT,
  SELECT_SCRIPT,
  TEXT_SCRIPT,
  withArgs,
} from './browser-drive-script'
import { imageSizeScript } from './browser-capture-script'
import { CaptureStore, type CaptureBounds } from './browser-capture-store'
import { interceptedKinds, type FetchRules } from './browser-fetch-rules'
import { resolveArming } from './browser-scrape-settings'
import { PageNetwork, type NetworkStatus } from './browser-network'
import {
  EXTRACT_SCRIPT,
  type ExtractPlan,
  type ExtractResult,
} from './browser-store-script'
import { copilotPaths } from './copilot-home'
import { blockShotDir } from './browser-scrape-paths'
import { normalizeUrl, shortLabel } from './browser-url'
import { PageCast, type CastFrame, type CastOptions, type CastSeam, type SecretScan } from './browser-watch'
import type { BrowserInputFrame } from './remote/protocol'

/**
 * The engine: one page, driven properly.
 *
 * ## Why this is not Playwright, and what that cost
 *
 * The design document's first recommendation was to run real Playwright inside
 * the main process and reach the app's own tabs through a hand-rolled
 * browser-level CDP endpoint. That was the right thing to *evaluate*, and it
 * was evaluated first, because the whole of §1 turns on it. It is not what
 * shipped, and the reason is worth stating rather than discovering:
 *
 *  - Playwright's public API takes a **CDP endpoint URL**. There is no
 *    message-passing transport in `playwright-core`'s connect options, so
 *    using it at all means standing up a listening socket — and §2.1's whole
 *    argument is that this app must not open one, because loopback is not a
 *    user boundary on a shared machine and every other local surface here is a
 *    0600 token file.
 *  - It is not in this repository's dependencies, and adding it means adding a
 *    third-party runtime to an Electron app that ships signed to strangers,
 *    pinned against Chromium 146, for an engine whose output the agent cannot
 *    tell apart from this one — because the tool schemas are identical either
 *    way. That is the entire reason the design put the seam at the tools.
 *
 * So this is the fallback the design named, built to the standard it set: *one
 * honest actionability loop and a fixed retry budget*. What was given up is
 * real: Playwright's selector engines, frame traversal, and its far more
 * thoroughly exercised waiting. What was kept is the part that was actually
 * broken — see {@link waitForActionable}, which is the reason "it goes back
 * many times" happens and the reason it should stop.
 *
 * ## What a click actually is
 *
 * Not one operation. Asad's complaint — *"this Chromium with Playwright is not
 * that stable, it goes back many times, turns off"* — is mostly this: a driver
 * that resolves a selector and dispatches immediately will click the spinner
 * overlay, or the button one frame before it finishes moving, and report
 * success. So a click here is:
 *
 *   resolve → attached → scrolled into view → visible → box stable across two
 *   animation frames → enabled → hit-test at the point the click will land →
 *   dispatch
 *
 * and the whole chain retries when any step invalidates, until a deadline. The
 * hit test is the one that catches the overlay: the script asks the document
 * what is actually at the centre point, and if that node is neither the target
 * nor inside it, the click is not sent.
 *
 * ## This engine drives a page it never names the shape of
 *
 * Nothing in this file imports Electron any more. Everything it needs from a
 * live page — send a command, read the isolated world, capture a frame, load a
 * URL, hear that the page settled or went — it takes through {@link DrivenPage},
 * an interface with two implementations: `browser-driven-electron.ts` wraps a
 * `WebContents` for the desktop, and `browser-driven-cdp.ts` speaks the pipe to
 * a real headless Chromium for the server. The driver cannot tell them apart,
 * which is the whole of what lets the same actionability loop run in both.
 *
 * Where each operation lands, and why it is shaped the way it is, is recorded on
 * the two implementations. The properties this file keeps are transport-neutral:
 *
 *  - **Reading** goes through one call — {@link DrivenPage.runInIsolatedWorld} —
 *    with scripts from `browser-drive-script.ts`, so `Runtime.evaluate` is not
 *    merely denied at the gate, it is not needed. There is one read door and the
 *    baton is checked in front of it.
 *  - **Navigating** goes through {@link DrivenPage.loadURL} (the copilot's own
 *    tab) or {@link DrivenPage.navigateGuarded} (a window the person can see),
 *    after `normalizeUrl`, and never through a raw `Page.navigate` — which
 *    `browser-cdp.ts` denies because it was measured to bypass the navigation
 *    guard entirely.
 *  - **Screenshots** come back from {@link DrivenPage.capture} as a raw RGBA
 *    frame; the secret rectangles are painted out and the PNG is encoded here,
 *    in `browser-png.ts`, so a password is gone from the pixels before the file
 *    exists whichever transport took the picture.
 */

/* ------------------------------------------------------------- constants -- */

/** Longest an actionability wait runs before the step is refused. */
export const DEFAULT_ACTION_TIMEOUT_MS = 10_000
export const MAX_ACTION_TIMEOUT_MS = 30_000

/** Longest `browser.open` waits for a page to stop loading. */
export const DEFAULT_SETTLE_MS = 15_000

/**
 * How much of a page's rendered text one `browser.read` brings back.
 *
 * Four thousand characters is roughly a thousand tokens, which is the figure
 * `COPILOT-CAPABILITIES.md` §6 arrives at for what a whole-document overview is
 * worth paying — and a read that costs more than the answer is a read a model
 * learns to avoid. It is a *default*, not a ceiling: a caller that needs the
 * long tail of an article passes a larger `textLimit`, and the result says
 * `textTruncated` either way, so the difference between "that is the page" and
 * "that is the top of the page" is never a guess.
 */
export const DEFAULT_OUTLINE_TEXT_CHARS = 4_000
export const MAX_OUTLINE_TEXT_CHARS = 40_000

/** How long the box must hold still. Two frames at 60 Hz, with slack. */
const STABLE_FRAME_MS = 40

/** Longest text one `type` step will enter. A field, not a document. */
export const MAX_TYPE_CHARS = 2_000

/** Above this, typing switches from per-key events to one insert. */
const PER_KEY_LIMIT = 200

/** Longest selector accepted from a tool. */
export const MAX_SELECTOR_CHARS = 400

/** Keys `press` accepts, and what to send for each. */
const PRESS_KEYS: Record<string, { key: string; code: string; vk: number; text?: string }> = {
  Enter: { key: 'Enter', code: 'Enter', vk: 13, text: '\r' },
  Tab: { key: 'Tab', code: 'Tab', vk: 9, text: '\t' },
  Escape: { key: 'Escape', code: 'Escape', vk: 27 },
  Backspace: { key: 'Backspace', code: 'Backspace', vk: 8 },
  Delete: { key: 'Delete', code: 'Delete', vk: 46 },
  ArrowDown: { key: 'ArrowDown', code: 'ArrowDown', vk: 40 },
  ArrowUp: { key: 'ArrowUp', code: 'ArrowUp', vk: 38 },
  ArrowLeft: { key: 'ArrowLeft', code: 'ArrowLeft', vk: 37 },
  ArrowRight: { key: 'ArrowRight', code: 'ArrowRight', vk: 39 },
}

export const PRESSABLE_KEYS = Object.keys(PRESS_KEYS)

/* ------------------------------------------------------------------ types -- */

/** Something a rule refused, as distinct from something that broke. */
export class DriveRefused extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'DriveRefused'
  }
}

export interface OutlineElement {
  kind: 'link' | 'button' | 'field'
  tag: string
  type: string
  label: string
  selector: string
  secret: boolean
  enabled: boolean
  value?: string
}

export interface ProbeResult {
  found: boolean
  count: number
  invalid?: boolean
  tag?: string
  type?: string
  label?: string
  secret?: boolean
  visible?: boolean
  enabled?: boolean
  editable?: boolean
  checked?: boolean
  rect?: { x: number; y: number; width: number; height: number } | null
  hit?: boolean
  hitNode?: string | null
  readyState?: string
}

export type StepVerb = 'click' | 'type' | 'select' | 'check' | 'press' | 'submit'

/**
 * Which page a call is about.
 *
 * Absent everywhere until Asad said the thing this whole type exists for:
 *
 * > *"sessions still dont have full control to the browser windows and they
 * > dont know about the ones attached to them specifically and they can only
 * > open a new browser with whatever the link we ask with then they cant do
 * > anything"*
 *
 * The class header used to argue at length that there is no `tabId` anywhere
 * and that this is load-bearing. Half of that argument survives and half of it
 * was answering a question nobody had asked:
 *
 *  - **Still true.** An agent may not name an arbitrary tab. There is no id
 *    here that a model can invent, guess or enumerate: a target is minted by
 *    the tool layer *from the binding map*, out of a session id the caller
 *    already holds and a slot name that session was given. A window belonging
 *    to another session cannot be named, and neither can a window belonging to
 *    nobody. See `windowNamed` in `browser-binding.ts`, which is the check.
 *  - **No longer true.** That reading a page the agent did not open would have
 *    to be `alter` because it might disclose something. Attaching a window to a
 *    session is a deliberate act, made by hand, in that window's own menu, and
 *    it is *the* act by which a person says which pages an agent may look at.
 *    An attached window that the agent may not read is a control that did
 *    nothing, which is worse than no control.
 *
 * `name` is what a refusal and the banner call it — `B2` — and never the id
 * underneath. That is not decoration: `browser:<epoch>:<seq>` leaking onto a
 * screen was a defect fixed this afternoon and must not come back through here.
 */
export interface DriveTarget {
  /** The slot's key. `own` for the copilot's tab, `bound:<browserTabId>` else. */
  key: string
  /** The main-process view id {@link DriveHost.contentsFor} takes. */
  viewId: string
  /**
   * The renderer's shell tab id, for the two things only the window can do:
   * bring this page to the front, and close it. Empty for the copilot's tab,
   * whose shell id never reaches this process.
   *
   * Never printed. See {@link name}.
   */
  browserTabId: string
  /** What a person and an agent both call it: `B2`. Empty for the copilot's tab. */
  name: string
}

/** The copilot's own tab — the target every call means when it names none. */
export const OWN_TARGET: DriveTarget = Object.freeze({
  key: 'own',
  viewId: '',
  browserTabId: '',
  name: '',
})

/**
 * The slot key an attached window is filed under.
 *
 * One spelling, exported, because there are now two callers with no other
 * connection to each other: the tool layer mints a whole {@link DriveTarget}
 * from the binding map, and `browser-binding-ipc.ts` has only a shell tab id and
 * needs to end that window's drive when it is disconnected. Two copies of
 * `` `bound:${id}` `` is a drive that silently keeps running under a key nobody
 * matched.
 */
export function boundKey(browserTabId: string): string {
  return `bound:${browserTabId}`
}

/* --------------------------------------------------------------- the page -- */

/** A captured page frame — RGBA bytes and their size. See `browser-png.ts`. */
export type { RawFrame }

/**
 * One live page, as everything this engine does to a page and nothing about how.
 *
 * The seam that lets the whole driver stop importing Electron. Under the desktop
 * an implementation wraps a `WebContents` (`browser-driven-electron.ts`); under
 * the headless server another speaks CDP to a real Chromium over a pipe
 * (`browser-driven-cdp.ts`). Each method is one of the operations the driver used
 * to do inline against `wc`, named for what it accomplishes rather than for the
 * call that accomplishes it — so the driver can be read, and tested, without a
 * browser in the room.
 *
 * Two of these are the security doors the rest of the app is built around, and
 * `browser-cdp.test.ts` pins that each implementation has exactly one of each:
 * {@link send} is the only place a debugger command leaves for the page, and the
 * driver screens it first; {@link runInIsolatedWorld} is the only place page
 * script runs, and it runs only strings this repository wrote.
 */
export interface DrivenPage {
  /** The page's current URL, or the empty string if it cannot be read. */
  url(): string
  /** The page's current title. */
  title(): string
  /** Has the underlying page gone? Nothing can be driven once this is true. */
  isGone(): boolean

  /**
   * Point this page at a URL. The plain load the copilot's own tab uses; the
   * URL is already screened by `normalizeUrl` before it arrives here.
   */
  loadURL(url: string): Promise<void>
  /**
   * Navigate a window the person can see, honouring its own `beforeunload`.
   * `'unfinished'` when the page declared it had unsaved work and refused.
   */
  navigateGuarded(url: string): Promise<'navigated' | 'unfinished'>

  /** Take the page's debugger transport. Safe to call when already attached. */
  attach(): Promise<void>
  /** Let the transport go. Safe to call when nothing is attached. */
  detach(): void
  /** Is the transport attached right now? */
  isAttached(): boolean
  /**
   * Send one command down the transport, and answer with its result.
   *
   * The single door. It is called only from the driver's own `send()`, which
   * screens the method through `browser-cdp.ts` first — so this raw primitive
   * carries no policy of its own.
   */
  send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
  /**
   * Subscribe to the transport's events; the returned function unsubscribes.
   * Feeds `PageNetwork`, which is the only caller.
   */
  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void

  /**
   * Run one of this repository's scripts in the drive's isolated world.
   *
   * The single read door. `code` is composed by the driver from a
   * `browser-drive-script.ts` string and JSON arguments; there is no path from a
   * model's text to a page's JavaScript.
   */
  runInIsolatedWorld<T>(code: string): Promise<T>

  /** A raw RGBA frame of the page, for masking and encoding in `browser-png.ts`. */
  capture(): Promise<RawFrame>

  /** Is the page still loading? */
  isLoading(): boolean
  /**
   * Call `handler` the next time the page settles — stops or fails to load. The
   * returned function unsubscribes, which the settle wait uses on timeout.
   */
  onSettled(handler: () => void): () => void

  /** The page's process is gone. The returned function unsubscribes. */
  onGone(handler: () => void): () => void
  /** The transport detached out from under the drive. Returns an unsubscribe. */
  onDetached(handler: () => void): () => void
  /**
   * Run `handler` when this page is destroyed, once per `key`. Keyed and shared
   * so watching one page from many places is one listener — see
   * `web-contents-teardown.ts` for the desktop's registry.
   */
  onDestroyed(key: string, handler: () => void): void

  /** Attach the automatic block-capture watcher to this page's navigations. */
  watchBlocks(deps: BlockWatchDeps): void
}

/* -------------------------------------------------------------- the drive -- */

/**
 * What the drive needs from the rest of the app, and no more.
 *
 * An interface rather than direct imports, for the reason `deck-control`'s
 * `DeckSurface` gives at length: the piece that must be exercisable is the
 * piece that decides whether a dangerous call happens, and that piece cannot be
 * exercisable if it constructs its own Electron objects.
 */
export interface DriveHost {
  /**
   * Which command allow-list the driver screens this host's page against.
   *
   * The one axis `browser-cdp.ts` grew for the server. The desktop's pages are
   * driven over an Electron `WebContents` debugger, whose reads go through
   * `executeJavaScriptInIsolatedWorld` and whose screenshots go through
   * `capturePage()`, so its allow-list denies the CDP verbs a headless target is
   * driven with — `Page.navigate`, `Page.captureScreenshot`, `Target.*`. A host
   * whose pages are real Chromium targets over a pipe declares `'cdp'` so the
   * screen consults `CDP_ALLOWED`; every other host leaves it absent and is
   * screened exactly as before, which is the property this field must keep — see
   * {@link BrowserDrive.send}. It is read per call rather than captured so there
   * is one answer and it is this host's, never a stale one.
   */
  transport?: Transport
  /**
   * Ask the window to open a browser tab for the agent, and tell us its id.
   *
   * Goes to the renderer rather than being done here, and that is a decision
   * rather than an accident. A `WebContentsView` created in the main process
   * would not be in the tab strip, would not be positioned by the workspace's
   * layout, and would therefore be a page that exists, is doing things, and
   * cannot be found — the exact object `catalogue.ts` already refuses for
   * sessions, in its own words *"a tab you did not open and cannot account for
   * is the thing this app must not produce"*.
   *
   * Null when there is no browser workspace open to ask. The tool says so; it
   * does not invent a tab.
   */
  openTab(input: { url: string; isolate: boolean }): Promise<string | null>
  /**
   * Why the last {@link openTab} produced nothing, when the host knows.
   *
   * Optional, and the desktop does not implement it: there, `null` means the
   * window declined, and the sentence below about Settings → Tools is the true
   * one. A **headless host** is the case that needed this. Its `openTab` returns
   * `null` for a completely different family of reason — most of them about a
   * Chromium that could not start on that machine — and the desktop's sentence
   * sends somebody to a Settings pane on a server that has no window, no
   * Settings and no Tools, while the real answer ("it needs these fifteen
   * packages, here is the command") went to a banner the agent never sees.
   *
   * So the host that knows why gets to say so, and the fixed sentence stays the
   * fallback for the host that genuinely does not.
   */
  whyNoTab?(): string | null
  /** The live page of a tab this app opened, or null once it has gone. */
  contentsFor(tabId: string): DrivenPage | null
  /** Tell the window the drive's state changed, so the banner can redraw. */
  publish(status: DriveStatus): void
  /** Epoch ms. Injected so a test can freeze it. */
  now(): number
  /**
   * Open a window that belongs to a **session** rather than to the copilot.
   *
   * The third thing Asad asked for: a page the agent opens can land in the
   * session's own numbered windows, where he can see it, name it and hand it
   * back — instead of in the copilot's single unnamed tab.
   *
   * Deliberately the *same* route the `open` shim takes, handed in rather than
   * called here, so the window an agent opens through a tool and the window it
   * opens by running `open https://…` are the same window with the same number.
   * Two paths to this would be two numbering schemes. See `openForSession` in
   * `browser-binding-ipc.ts`.
   *
   * Absent in a build where the binding wiring is not there, and the tool says
   * so rather than opening something unattached and calling it attached.
   */
  openForSession?(input: {
    url: string
    sessionId: string
    /** Ask for a window of its own rather than the one it already holds. */
    newWindow?: boolean
    /**
     * Which machine that session is on, when the caller knows.
     *
     * Left out by a caller that does not, which is the ordinary case here: a
     * tool is handed a session id by a model and has no way to know where it
     * runs. The wiring in `src/main/index.ts` resolves it — see
     * `BindingIpcDeps.machineOfSession`. It used to be a required field that
     * `browser-tools.ts` filled with the empty string, which is not "unknown"
     * but a claim that the session is on this computer, and it made every
     * window opened for a session on a paired device unreachable by the session
     * it was opened for.
     */
    machineId?: string
  }): Promise<{ line: string; attached: boolean }>
  /**
   * Close a browser window the person can see, by its shell tab id.
   *
   * Through the renderer, not by destroying the view here, for the reason
   * `browser-drive-ipc.ts` gives about opening: a view torn down underneath a
   * strip that still lists it is the ghost-row failure, and a window that
   * cannot be found is exactly what this feature must not produce.
   */
  closeWindow?(browserTabId: string): Promise<boolean>
  /**
   * Bring a browser window to the front of its pane, and say whether it went.
   *
   * ## Why this is not a courtesy
   *
   * Measured on 2026-08-20 against two windows attached to one session, in the
   * running app: reading the background one worked, and every click and
   * keystroke aimed at it was **dropped**. Its `WebContentsView` is laid out by
   * the workspace only while it is the tab on screen, so a hidden one has a
   * 0×0 viewport, its elements sit at negative coordinates, and
   * `capturePage()` answers "no visible surface".
   *
   * `Emulation.setDeviceMetricsOverride` was tried first, because a fake
   * viewport is what a headless driver would use and it needs nothing from the
   * renderer. It fixed the layout exactly as intended — the button landed at
   * (48, 129) and `elementFromPoint` returned it — and the click still did
   * nothing, because input to a non-composited view is dropped whatever the
   * page thinks its size is. It also did not undo cleanly. So the emulation
   * route is not a smaller version of this; it is a dead end, written down so
   * nobody spends the afternoon on it twice.
   *
   * What is left is the honest thing, and it is also the better one: a click
   * the person cannot see is the failure `DRIVING-MODE.md` §8 names, and the
   * banner over the page exists precisely so that a driven page is a page in
   * front of him. So acting on a window brings it forward, exactly as
   * `browser.open` has always done for the copilot's own tab.
   *
   * Reading does **not** call this. A read works on a hidden window and pulling
   * his screen to a page in order to look at it would be the app arguing with
   * him about which tab he is on.
   */
  showWindow?(browserTabId: string): Promise<boolean>
  /**
   * Where this page's captured traffic may be written, for one run.
   *
   * Handed in rather than composed here for the reason every other member of
   * this interface is: the answer depends on which browser *profile* the tab was
   * built in, and that is a fact `browser-tab.ts` stamps at creation and this
   * module has no business looking up. See `browserTabProfile`.
   *
   * Null when there is no such tab, and absent in a build that has no browser
   * wiring — in which case `armNetwork` refuses to capture and says so, rather
   * than arming something that writes nowhere.
   */
  captureFolder?(input: { viewId: string; runId: string }): string | null
  /**
   * Where this page's block screenshots go, and whether it may take any.
   *
   * The same shape and the same argument as {@link DriveHost.captureFolder}
   * directly above: both answers depend on which browser *profile* the tab was
   * built in, `browser-tab.ts` stamps that at creation, and this module has no
   * business looking it up.
   *
   * Null when there is no such tab. Absent in a build with no browser wiring —
   * in which case the watcher falls back to the shared folder with the camera
   * on, which is what this did before there was a switch. It is not a build
   * where the panel offers one either: the switch and this member are wired in
   * the same file, so a build that cannot answer also draws no control.
   */
  blockCapture?(viewId: string): { dir: string; on: boolean } | null
  /**
   * What this page's profile has been told to do when nothing names it.
   *
   * The four scraping engines take their configuration on the call, which is
   * the right shape for an engine and left a person with no way to say *"always
   * fulfil this profile's images"* — see `browser-scraping-ipc.ts`. This is the
   * seam that lets a stored answer be the one that runs: a `browser.network`
   * call that omits `rules` gets the profile's, and one that names them is
   * untouched.
   *
   * Handed in for the same reason {@link captureFolder} is: the answer depends
   * on which browser profile the tab was built in, and this module has no
   * business looking that up. Absent in a build with no browser wiring, in
   * which case nothing falls back and every call is exactly what it says.
   */
  scrapeDefaults?(viewId: string): {
    rules: FetchRules | null
    capture: boolean | null
    bounds: CaptureBounds | null
    /** Whether a page that refuses us is photographed. `null`: nobody said. */
    blockShots: boolean | null
  } | null
  /**
   * The drive took this page's debugger / let it go.
   *
   * Wired to `browser-profile-arm.ts`, which arms pages from the person's own
   * stored scraping settings and must never share one debugger session with a
   * drive: two `PageNetwork`s on one page would both answer the same paused
   * request. `pageHeld` runs inside {@link BrowserDrive.attach} **before** any
   * command is sent, so the person-side run has stood down by the time an
   * agent can act; `pageFreed` runs on detach, after which the person side may
   * reclaim the page. Absent in a build with no browser wiring, where there is
   * no person-side arming to yield.
   */
  pageHeld?(viewId: string): void
  pageFreed?(viewId: string): void
}

/**
 * One page the drive is holding, and everything true of that page and no other.
 *
 * Every field here was a field on {@link BrowserDrive} while the drive had
 * exactly one page. They are grouped rather than multiplied because each of
 * them is a fact about a *document*, and getting that wrong is not a tidiness
 * problem:
 *
 *  - `secretSelectors` is the cache that keeps a password refusal on the right
 *    side of the confirmation gate. Shared between two pages it would refuse to
 *    type into a field on B2 because the copilot's tab had a password box with
 *    the same id — a refusal nobody could explain.
 *  - `grantedOrigin` is the person's answer about *one* site on *one* page.
 *    Shared, a yes given for a click in the copilot's tab would silently cover
 *    a click on the same site in a window he is looking at.
 *  - `state` is the baton. Shared, handing him B2 would shut the copilot out of
 *    its own tab, and his "done, carry on" would resume both.
 */
class Slot {
  state: DriveState = 'idle'
  /** The view id this slot is driving, or null when it holds no page. */
  viewId: string | null = null
  step = ''
  prompt = ''
  /** Resolves the tool call that is currently blocked on the person. */
  waiting: ((outcome: HandoverOutcome) => void) | null = null
  /** The origin the person has already agreed the copilot may drive here. */
  grantedOrigin: string | null = null
  /** Selectors this page has said are password, one-time-code or file fields. */
  secretSelectors = new Set<string>()
  attached = false
  /**
   * Is the page in this slot in a throwaway partition?
   *
   * Held because `isolate` is decided when a view is *constructed* and cannot
   * be applied afterwards — so a second `browser.open` asking for isolation on
   * a slot that already holds an ordinary page has to build a new one or it is
   * answering a question it did not do anything about. See {@link
   * BrowserDrive.open}, which is where that used to go quietly wrong.
   */
  isolated = false
  /** When something last happened here. Decides which slot the banner is about. */
  touchedAt = 0
  /**
   * This page's armed network, or null when nothing has armed one.
   *
   * On the slot rather than on the drive for the same reason `grantedOrigin` and
   * `secretSelectors` are: it is a fact about a *document*. Two windows
   * harvesting at once are two rule sets, two capture folders and two sets of
   * counts, and a shared one would file B2's JSON under B1's run.
   */
  network: PageNetwork | null = null
  constructor(
    readonly key: string,
    /** `B2`, or empty for the copilot's own tab. */
    readonly name: string,
  ) {}
}

/**
 * Who holds the handover on one window, as the host half knows it.
 *
 * The wire's {@link BrowserHandoverStateFrame} minus its one per-recipient
 * field: `mine` is `taker === the connection being written to`, and only
 * `remote/server.ts` knows which connection that is. Everything else about a
 * handover is a fact about the *page* and is the same for everybody looking at
 * it, which is exactly the split the frame's own doc comment argues for.
 */
export interface HandoverHolding {
  /** Is a handover outstanding on this window at all? */
  asking: boolean
  /** The agent's own sentence, already sanitised by {@link BrowserDrive.handover}. */
  prompt: string
  /** The watcher id that answered it, or null when nobody has. */
  taker: string | null
}

export class BrowserDrive {
  /** The copilot's own tab. Always present; never removed; today's behaviour. */
  private readonly own = new Slot('own', '')
  /** A session's attached windows, by slot key, created on first use. */
  private readonly bound = new Map<string, Slot>()
  private watched = new WeakSet<DrivenPage>()
  /**
   * The live screencast of each slot's page, by slot key — wave-3's watch path.
   *
   * One {@link PageCast} per page, holding every connection watching it; made on
   * the first watch and dropped when its last watcher leaves. It never holds a
   * page frame anywhere but in memory, and it drives the page only through this
   * class's own screened {@link send}, so the baton refuses its screencast during
   * a handover exactly as it refuses every other command.
   */
  private readonly casts = new Map<string, PageCast>()

  constructor(private readonly host: DriveHost) {}

  /* ------------------------------------------------------------- the slot -- */

  /**
   * The slot a call is about, made on first use.
   *
   * A target carries its view id every time rather than the slot remembering
   * one, because the id underneath an attached window is re-minted when the
   * isolation switch closes and reopens the view — the same fact
   * `browser-binding.ts` keys its map around. The slot's identity is the
   * window; only the handle for steering it rides on the id.
   */
  private slotFor(target?: DriveTarget | null): Slot {
    if (!target || target.key === OWN_TARGET.key) return this.own
    const found = this.bound.get(target.key)
    if (found) {
      found.viewId = target.viewId
      return found
    }
    const made = new Slot(target.key, target.name)
    made.viewId = target.viewId
    this.bound.set(target.key, made)
    return made
  }

  private slots(): Slot[] {
    return [this.own, ...this.bound.values()]
  }

  /**
   * A slot, addressed as a target again — for the handful of internal callers
   * that already have the slot and have to go back through the public door.
   *
   * `browserTabId` is empty because nothing these callers do needs the window:
   * releasing is bookkeeping, and a page that has just died is not going to be
   * brought to the front.
   */
  private refOf(slot: Slot): DriveTarget {
    return { key: slot.key, viewId: slot.viewId ?? '', browserTabId: '', name: slot.name }
  }

  /**
   * Which slot the one banner is about.
   *
   * There is a single banner per browser panel — `DriveBanner` is drawn above
   * the page area, not per tab — so a status has to name one page even when two
   * are held. A question outranks work, always: `human` means somebody is being
   * asked to type a password, and a banner that disappeared because the agent
   * started reading another window would leave a blocked tool call with nothing
   * on screen to answer it. Between two working slots, the newest.
   */
  private showing(): Slot {
    const all = this.slots()
    const asking = all.find((slot) => slot.state === 'human')
    if (asking) return asking
    let best: Slot | null = null
    for (const slot of all) {
      if (slot.state !== 'agent') continue
      if (best === null || slot.touchedAt > best.touchedAt) best = slot
    }
    return best ?? this.own
  }

  /* ---------------------------------------------------------- what it is -- */

  status(): DriveStatus {
    const slot = this.showing()
    const page = this.contents(slot)
    return {
      state: slot.state,
      tabId: slot.viewId,
      step: slot.step,
      prompt: slot.prompt,
      url: page ? page.url() : '',
    }
  }

  /**
   * The windows this drive is holding, by the names on screen.
   *
   * For a tool that has to say what it is doing without naming an id. Empty
   * when only the copilot's own tab is in play, which is the ordinary state.
   */
  driving(): string[] {
    return [...this.bound.values()]
      .filter((slot) => slot.state !== 'idle' && slot.name !== '')
      .map((slot) => slot.name)
  }

  /**
   * The view the copilot's own tab is holding, or null when it holds none.
   *
   * The one fact {@link status} cannot answer, and it is a safety question
   * rather than a cosmetic one. `status()` describes {@link showing}, which is
   * whichever slot the single banner is about — a page the person has been
   * handed, else the newest one an agent touched — so on a machine with two
   * windows in play it is not necessarily this slot.
   *
   * Wave-3's live view is what needed it. On the desktop the copilot's tab is an
   * ordinary pane in the strip, so a phone listing the machine's windows sees
   * it, and a cast started against it as `bound:<paneId>` would put a **second
   * slot on one page**: two batons, two `grantedOrigin`s, two secret caches.
   * The failure that matters is the curtain — `handover` stops the cast of the
   * slot it was called on, so a handover taken on this slot would leave a cast
   * running through the other one while the person types a password into the
   * same document, with only the secret-rect scan left between it and a wire.
   * One `===` against this closes it: a pane holding this view is cast through
   * `OWN_TARGET` and there is one slot again. See `screencast-host.ts`.
   */
  ownView(): string | null {
    return this.own.viewId
  }

  /**
   * The origin of the page the agent is on, or null.
   *
   * Read from the WebContents rather than from anything the model said, which
   * is what makes the escalation in `browser-tools.ts` sound: the grant lapses
   * the moment the tab's origin changes, *including* by a link click or a
   * server redirect, and that is a main-process fact needing nobody's
   * cooperation.
   */
  origin(target?: DriveTarget | null): string | null {
    const page = this.contents(this.slotFor(target))
    if (!page) return null
    try {
      return new URL(page.url()).origin
    } catch {
      return null
    }
  }

  /**
   * Where a slot's page is right now, and what it calls itself.
   *
   * The live pair, read off the `WebContents` every time — the same read
   * {@link origin} makes and for the same reason: it is a main-process fact that
   * needs nobody's cooperation and cannot be stale.
   *
   * It exists because the phone's tab strip was labelling the drive's own front
   * tab from what `open` answered when the page was *opened*, kept while the
   * origin still matched. Following a link inside one site therefore left the
   * address bar showing the page you started at, and following one to another
   * site degraded to a bare origin with no path. Both are a browser lying about
   * where it is.
   */
  where(target?: DriveTarget | null): { url: string; title: string } | null {
    const page = this.contents(this.slotFor(target))
    if (!page) return null
    return { url: page.url(), title: page.title() }
  }

  /** Has the person already allowed driving on this origin, on this page? */
  originGranted(origin: string, target?: DriveTarget | null): boolean {
    const slot = this.slotFor(target)
    return slot.grantedOrigin !== null && slot.grantedOrigin === origin
  }

  /**
   * Is this selector one the page has already told us is a secret field?
   *
   * Exists for one reason, and it is an ordering reason rather than a
   * performance one. `browser.step` refuses to type into a password field, and
   * that refusal used to live in {@link act} — which runs *after* the
   * confirmation gate. So driving a login form put a dialog on screen reading
   * "Type 21 characters into #wpPassword1", the person clicked Allow, and only
   * then was it refused. Photographed on 2026-08-17, on a real Wikipedia login
   * page.
   *
   * `control.ts` is explicit about why that shape is wrong: *"a rule the person
   * is asked about is not a rule"*. They answer it in the same shape as the
   * harmless ones they approved earlier, and a refusal that arrives after a yes
   * has already trained them to click yes. The same bug was found once before
   * in this codebase, in `settings.write`, and pinned by `control.test.ts`.
   *
   * So the answer has to be available to a **synchronous** `precheck`, and the
   * page cannot be asked synchronously. This is what the last read of the page
   * already knew. It is populated by every `outline` and every `probe`, which
   * between them cover the path any sensible flow takes — the tool descriptions
   * tell the model to read the page before acting on it, and a selector it
   * invented without reading is one it is about to be told does not exist.
   *
   * A miss is not a hole: {@link type} still refuses, by the same sentence, on
   * the far side of the gate. This moves the common case to the right side of
   * it.
   */
  knownSecret(selector: string, target?: DriveTarget | null): boolean {
    return this.slotFor(target).secretSelectors.has(selector.trim())
  }

  private noteSecret(slot: Slot, selector: string, secret: boolean): void {
    const key = selector.trim()
    if (key === '') return
    if (secret) slot.secretSelectors.add(key)
    // Never removed on `false`. A page that re-renders a password box as a text
    // input mid-flow is a page doing something strange, and forgetting is the
    // direction that ends with a password typed into it.
  }

  noteOriginGranted(origin: string, target?: DriveTarget | null): void {
    this.slotFor(target).grantedOrigin = origin
  }

  private contents(slot: Slot): DrivenPage | null {
    if (slot.viewId === null || slot.viewId === '') return null
    const page = this.host.contentsFor(slot.viewId)
    if (!page || page.isGone()) return null
    return page
  }

  private publish(): void {
    this.host.publish(this.status())
  }

  private move(slot: Slot, kind: 'claimed' | 'handover' | 'resumed' | 'released'): void {
    const before = slot.state
    slot.state = nextDriveState(slot.state, { kind })
    slot.touchedAt = this.host.now()
    if (before !== slot.state) this.publish()
  }

  /* -------------------------------------------------------------- the tab -- */

  /**
   * Point a page at a URL: the copilot's own tab by default, an attached window
   * when one is named.
   *
   * With no target this is what it always was — the agent has exactly one tab
   * of its own, the one this gave it, and calling `open` again navigates that
   * same tab. There is still no id a model can name: see {@link DriveTarget},
   * where a target is minted from the binding map rather than from anything the
   * model said.
   *
   * With a target it is a **navigation of a window that already exists**, and
   * it never creates one. That is the difference that matters: a person's
   * attached window is a page he is looking at, so the only thing to do with a
   * dead one is say so.
   */
  async open(
    input: { url: string; isolate: boolean; settleMs?: number },
    target?: DriveTarget | null,
  ): Promise<{
    url: string
    title: string
    settled: boolean
    created: boolean
  }> {
    const slot = this.slotFor(target)
    this.refuseWhileHuman(slot)
    const normalized = normalizeUrl(input.url)
    if (!normalized.ok) throw new DriveRefused(normalized.reason)

    let created = false
    let page = this.contents(slot)
    if (!page && slot !== this.own) {
      throw new DriveRefused(
        `${slot.name} is not open any more. Read the window list again before naming one.`,
      )
    }
    /*
     * A page whose isolation is not the isolation that was asked for is not a
     * page this call may reuse.
     *
     * The partition is fixed when a `WebContentsView` is constructed, so
     * `isolate` on a slot that already holds a page used to do *nothing at
     * all*: `loadURL` ran, the tool answered `settled: true`, and the model was
     * told it had a throwaway session with none of the person's cookies while
     * it sat in the ordinary one. Measured on 2026-08-20 in the running app —
     * `browser.open { isolate: true }` on the copilot's existing tab came back
     * `created: false` and shared every cookie.
     *
     * It matters in both directions and the rule is one line either way: the
     * page is dropped and a new one built. Reusing an *isolated* page for an
     * ordinary open is the same lie backwards — the person's sign-ins are not
     * there, and the model is told nothing about why the site does not know it.
     */
    if (page && slot === this.own && slot.isolated !== input.isolate) {
      slot.network?.abandon('the page was replaced to change its isolation')
      slot.network = null
      this.detach(slot)
      slot.viewId = null
      slot.grantedOrigin = null
      slot.secretSelectors.clear()
      page = null
    }
    if (!page) {
      const id = await this.host.openTab({ url: normalized.url, isolate: input.isolate })
      if (id === null) {
        /*
         * The host was asked to open a browser page and did not produce one.
         *
         * When it knows why — a headless host does, because its browser is a
         * process it started and watched fail — that reason is what the copilot
         * is told, verbatim. It is already a sentence somebody can act on:
         * `browser-chromium-install.ts` and `browser-chromium-launch.ts` build
         * these to name the libraries and print the command.
         */
        const known = this.host.whyNoTab?.() ?? null
        if (known !== null && known !== '') {
          throw new DriveRefused(
            `the browser on that machine could not be started, so there is nothing to drive. ${known} ` +
              'Tell the person that, as it is written here — it is the whole fix.',
          )
        }
        /*
         * The window was asked to install a browser page and still did not
         * produce one — see `browser-drive-ipc.ts`, which does that asking.
         *
         * The old sentence here told the copilot to have the person press the
         * globe, because at the time an app with no browser page open was the
         * ordinary state and this refusal was the ordinary answer. It is not
         * any more: that case now installs a page and drives it. What is left
         * is the one state the app genuinely cannot get out of on the person's
         * behalf — the browser switched off in Features — and telling somebody
         * to press a button they have deliberately removed is the kind of
         * advice that makes an assistant look like it is guessing.
         */
        throw new DriveRefused(
          'this window would not give me a browser page, so there is nothing to drive. The usual reason is ' +
            'that the browser is switched off in Settings → Tools; it cannot be turned back on from here, ' +
            'because that is the person\'s choice about their own app. Say what you would have opened and ' +
            'let them decide.',
        )
      }
      slot.viewId = id
      slot.isolated = input.isolate
      created = true
      page = this.contents(slot)
      if (!page) throw new DriveRefused('the browser tab went away before it could be driven')
    } else if (slot === this.own) {
      // The tab already exists, so this is a navigation rather than an open.
      // Through `loadURL` and not `Page.navigate`: see the class header.
      await page.loadURL(normalized.url)
    } else {
      /*
       * An attached window is *his* window, so it gets the courtesy a browser
       * gives: the page's own `beforeunload` is asked first.
       *
       * The same rule the shim's route already follows — `browser-route.ts`
       * says why at length — reached through {@link DrivenPage.navigateGuarded},
       * so a URL arriving by tool and a URL arriving by `open <url>` cannot treat
       * a half-written form differently. Nothing here reads the URL, the title or
       * how long the page has been open; the page's own declaration is the only
       * signal, because a heuristic would silently navigate over work whose
       * owner could never find out what decided that.
       */
      const outcome = await page.navigateGuarded(normalized.url)
      if (outcome === 'unfinished') {
        throw new DriveRefused(
          `${slot.name} says it has unfinished work on the page, so it was not navigated. Ask the person, ` +
            'or open the URL in a new window instead.',
        )
      }
    }

    this.watch(page, slot)
    this.move(slot, 'claimed')
    await this.attach(page, slot)

    const settled = await this.waitForSettled(page, input.settleMs ?? DEFAULT_SETTLE_MS)
    /*
     * A fresh page is a fresh permission question.
     *
     * The origin grant is cleared on every open rather than compared, because
     * "same origin as last time" is a comparison somebody has to remember to
     * write and this is a line somebody cannot forget. Re-granting costs one
     * dialog on a site he has already allowed; forgetting to clear it costs a
     * confirmation that was answered about a different website.
     */
    const origin = this.origin(target)
    if (origin !== slot.grantedOrigin) slot.grantedOrigin = null
    // Selectors belong to a document. Carrying them across a navigation would
    // mean refusing to type into a field on the new page because the old one
    // had a password box with the same id — which is a refusal nobody could
    // explain.
    if (created || origin !== null) slot.secretSelectors.clear()
    this.setStep(slot, '')
    /*
     * Publish once the page has settled, whatever the step was.
     *
     * `setStep('')` above only publishes when the step actually *changes*, and
     * after an open it usually has not — it was already empty. So the last
     * status anybody outside this class saw was the one `move('claimed')` sent,
     * which was taken before the navigation and therefore carries the previous
     * URL, or none at all.
     *
     * Observed on 2026-08-18: a fresh `browser.open` left the drive reporting
     * `url: ''` while a page was plainly loaded, so both readers of this status
     * — the banner over the page and the panel beside it — said there was no
     * page open. The status is meant to be what is true right now, and this is
     * the moment it becomes true.
     */
    this.publish()
    return { url: page.url(), title: page.title(), settled, created }
  }

  /** The person closed the page, or it died. Ends that drive; never re-arms. */
  release(target?: DriveTarget | null): void {
    const slot = this.slotFor(target)
    /*
     * The books are closed before the debugger goes, and closed *without*
     * sending anything — see `PageNetwork.abandon`. Detaching the debugger is
     * what actually resumes any paused request, which is why this cannot be a
     * disarm: a command sent to a page that has just gone is an unhandled
     * rejection rather than an error anybody sees.
     */
    slot.network?.abandon('the page was released')
    slot.network = null
    // The cast goes with the page: a screencast of a page that is gone has
    // nothing to send, and its watchers are told by the socket rather than by a
    // frame. Dropped from memory, never flushed to disk.
    const cast = this.casts.get(slot.key)
    if (cast) {
      this.casts.delete(slot.key)
      void cast.dispose().catch(() => undefined)
    }
    this.detach(slot)
    slot.viewId = null
    slot.isolated = false
    slot.step = ''
    slot.prompt = ''
    slot.grantedOrigin = null
    slot.secretSelectors.clear()
    const waiting = slot.waiting
    slot.waiting = null
    waiting?.('drive-ended')
    this.move(slot, 'released')
    // A window's slot is the window; with the page gone there is nothing left
    // for it to hold. The copilot's own slot stays, because it is the one thing
    // here that is not a window and `open` re-arms it.
    if (slot !== this.own) this.bound.delete(slot.key)
  }

  /**
   * Let go of one attached window, named by the shell tab id.
   *
   * The other end of Disconnect. He asked for one control that says whether a
   * browser is connected — *"we should be have a button here to disconnect
   * also, or it should only this way"* — and one control means the drive stops
   * when the relation does, not one tool call later when the target can no
   * longer be minted. Mid-drive that is the difference between a page that
   * stops and a banner that carries on saying the copilot is driving it.
   *
   * Silent when nothing here holds that window, which is the ordinary case:
   * disconnecting a window no agent has ever driven has nothing to end.
   */
  releaseWindow(browserTabId: string): void {
    const slot = this.bound.get(boundKey(browserTabId))
    if (!slot) return
    this.release(this.refOf(slot))
  }

  /**
   * Close an attached window, and let go of it.
   *
   * Only ever a window a session holds. The copilot's own tab is not closable
   * from here and that is not a gap: the id App.tsx knows it by never reaches
   * this process — the renderer answers `browser:drive-opened` with the *view*
   * id — so a close would tear down the page and leave the strip listing it.
   * The person's ✕ is what closes that one, and it already ends the drive.
   *
   * The **second** clause is the server's, and it is a different fact wearing
   * the same shape. `HeadlessDriveHost.openTab` passes `browserTabId: ''` on
   * purpose, so nothing is written into `byBrowserTab` and `closeWindow` would
   * answer `false` for that slot forever; refusing here says so before asking,
   * rather than reporting a close that never happened. It is also the line to
   * revisit on the day the own slot becomes window-backed on a server — see
   * `frontTab` in `screencast-host.ts`, which records why that day has not come
   * and which file it arrives in. Until then an empty `browserTabId` is not a
   * closable window on either host, and the two clauses agree by accident of
   * two different causes rather than by one rule.
   */
  async close(target: DriveTarget): Promise<boolean> {
    if (target.key === OWN_TARGET.key || target.browserTabId === '') {
      throw new DriveRefused(
        'your own tab is closed by the person, not by you. Name one of the session’s windows instead.',
      )
    }
    if (!this.host.closeWindow) {
      throw new DriveRefused('this build cannot close a browser window')
    }
    const closed = await this.host.closeWindow(target.browserTabId)
    if (!closed) {
      throw new DriveRefused(`${target.name} could not be closed; it may already have gone`)
    }
    this.release(target)
    return true
  }

  /**
   * Open a window that belongs to a session rather than to the copilot.
   *
   * Q3's second half, and a thin pass-through on purpose: the numbering, the
   * attach and the sentence naming the slot all belong to the route the shim
   * already uses, and a second implementation of them here is how an agent's
   * `B2` and a person's `B2` would come to be different windows.
   */
  async openForSession(input: {
    url: string
    sessionId: string
    newWindow?: boolean
    machineId?: string
  }): Promise<{ line: string; attached: boolean }> {
    if (!this.host.openForSession) {
      throw new DriveRefused('this build cannot open a window for a session')
    }
    const normalized = normalizeUrl(input.url)
    if (!normalized.ok) throw new DriveRefused(normalized.reason)
    return this.host.openForSession({ ...input, url: normalized.url })
  }

  /* ------------------------------------------------------------- the wire -- */

  private async attach(page: DrivenPage, slot: Slot): Promise<void> {
    if (slot.attached && page.isAttached()) return
    /*
     * Before the attach, not after: the person-side arming of
     * `browser-profile-arm.ts` may already hold this page's debugger for the
     * profile's own stored rules, and it must have stood down before this
     * drive can find the session "already attached" and start sharing it.
     * See {@link DriveHost.pageHeld}.
     */
    this.host.pageHeld?.(slot.viewId ?? '')
    try {
      if (!page.isAttached()) await page.attach()
      slot.attached = true
    } catch (error) {
      throw new Error(
        `could not attach to the page: ${error instanceof Error ? error.message : String(error)}`,
      )
    }
    /*
     * `Page.enable` on a WebContentsView that has never held a document hangs
     * and never answers. That is measured, and it cost the first spike written
     * against this: it deadlocked on this exact line with no error anywhere.
     * `browser-tab.ts` loads `about:blank` into every view it creates, so by
     * the time the drive gets here there is always a document — but the
     * `catch` stays, because a hang here would look exactly like a slow site
     * and nobody would ever find it.
     */
    await this.send(page, slot, 'Page.enable').catch(() => undefined)
    await this.send(page, slot, 'Runtime.enable').catch(() => undefined)
  }

  private detach(slot: Slot): void {
    const page = this.contents(slot)
    slot.attached = false
    if (page) {
      try {
        page.detach()
      } catch {
        // Already gone, or never attached. Either way there is nothing holding.
      }
    }
    // After the debugger is gone, so the person side reclaims a page that is
    // genuinely free rather than racing this teardown. Told even when the view
    // has died — the other end drops dead pages on its own.
    this.host.pageFreed?.(slot.viewId ?? '')
  }

  /**
   * The only place the driver hands a command to a page's transport.
   *
   * Screened first, always, by `browser-cdp.ts` — which is a pure function over
   * the method name and the state, so the rule can be read and tested without
   * an app. The one raw transport door lives on the {@link DrivenPage}
   * implementation ({@link DrivenPage.send}); this is the one place that door is
   * reached, and it is reached only after the screen. A caller that wanted to
   * skip it would have to hold a page and call `send` on it directly, which is a
   * thing a reviewer can grep for.
   */
  private async send(
    page: DrivenPage,
    slot: Slot,
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    const verdict = screenCommand({ transport: this.host.transport, state: slot.state, method, params })
    if (!verdict.ok) throw new DriveRefused(verdict.reason)
    return page.send(method, params)
  }

  /**
   * The **other** place the driver hands a command to a page's transport — the
   * one a person's own hands come through.
   *
   * The sibling of {@link send}, and a sibling rather than a parameter on it.
   * `screenCommand` refuses everything while the person holds the page and that
   * refusal is a *mechanism*: a flag that softened it would make it a policy,
   * and its own comment explains why a policy is a sentence a retry loop does
   * not read. So the agent's screen keeps its unconditional refusal, untouched,
   * and this door is screened by `screenPersonCommand` — which refuses
   * everything **unless** the person holds the page, and permits only the four
   * `Input.*` dispatches and the three screencast commands.
   *
   * Two functions, opposite conditions, disjoint use. A caller can only come
   * through here by naming this method, which is a thing a reviewer can grep for
   * exactly as they can grep for a raw `page.send`. Its only caller is the
   * {@link castSeam} below, and its only legitimate origin is the one watcher
   * `PageCast` is holding as the taker of a live handover.
   */
  private async sendAsPerson(
    page: DrivenPage,
    slot: Slot,
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    const verdict = screenPersonCommand({ state: slot.state, method, params })
    if (!verdict.ok) throw new DriveRefused(verdict.reason)
    return page.send(method, params)
  }

  /**
   * Send an input event.
   *
   * A thin wrapper over {@link send} and no longer anything more. It used to
   * announce each event into a `DispatchRing` first, so that the watcher below
   * could tell the driver's own clicks from the person's; nothing watches for a
   * takeover any more, so there is nothing to announce to. See the header of
   * `browser-drive.ts` for why that whole mechanism went.
   */
  private async input(
    page: DrivenPage,
    slot: Slot,
    method: string,
    params: Record<string, unknown>,
  ): Promise<void> {
    await this.send(page, slot, method, params)
  }

  /* ------------------------------------------------------- the page's life -- */

  /**
   * Watch a tab for the page underneath it going away.
   *
   * Registered once per page. The teardown goes through
   * {@link DrivenPage.onDestroyed} — a keyed, shared registration, so eleven
   * modules watching one page are one listener rather than the eleven that once
   * produced a `MaxListenersExceededWarning`. The desktop's registry is in
   * `web-contents-teardown.ts`.
   *
   * ## What this stopped watching for — 2026-08-21
   *
   * An `input-event` listener used to sit here and park the drive on any press
   * or keystroke it could not account for as the driver's own, putting
   * *"You took over this page. The copilot has stopped."* in the banner with two
   * buttons under it. He filmed himself clicking inside a page he had given the
   * copilot and getting exactly that:
   *
   *   > *"if I click inside, nothing should happen actually. It should keep
   *   > giving the access until I click here and I disconnect the browser from
   *   > any of the session."*
   *
   * So clicking, scrolling and typing in a driven page are now what they look
   * like — a person and an agent on one page — and the only thing that ends the
   * agent's access is Disconnect on the browser's toolbar. What remains here is
   * the page's *lifetime*, which is not a preference: a view that has been
   * destroyed cannot be driven by anybody.
   */
  private watch(page: DrivenPage, slot: Slot): void {
    page.onDestroyed(`browser-drive:${slot.key}`, () => {
      if (this.contents(slot) === null) this.release(this.refOf(slot))
    })
    if (this.watched.has(page)) return
    this.watched.add(page)

    /*
     * A reload of the *app* destroys every browser tab — `hostDocumentReplaced`
     * in `browser-tab.ts` is deliberate about it — and that ends any drive
     * instantly. The drive must not try to survive it: it ends, and the agent
     * is told why. A drive that re-armed itself after a reload would be a page
     * that starts moving on its own, which `DRIVING-MODE.md` §8 names as the
     * single behaviour that would make somebody uninstall.
     */
    page.onGone(() => this.release(this.refOf(slot)))
    page.onDetached(() => {
      slot.attached = false
    })

    /*
     * Photograph the pages that refuse us, without being asked.
     *
     * Here, in `watch`, because this is the one function every drivable page
     * passes through exactly once — the copilot's own tab, a window a session
     * attached, a window opened for a session — and a block that was only caught
     * on one of those three routes would be missing from the run that mattered.
     *
     * A tool cannot do this job. By the time an agent has read a page, decided
     * it was refused and called `browser.screenshot`, the challenge has usually
     * rotated and the picture is of something else; and an agent that is looping
     * on retries is not calling anything. `browser-block-watch.ts` has the whole
     * argument, including why it refuses to take a picture while the person
     * holds the baton.
     */
    /*
     * Asked afresh on each event rather than resolved once here. The switch is
     * per profile and somebody can click it while this page is open, and a
     * watcher holding the answer from attach time would go on photographing a
     * profile that had said stop until the tab was closed.
     */
    const shelf = (): { dir: string; on: boolean } =>
      this.host.blockCapture?.(slot.viewId ?? '') ?? {
        dir: blockShotDir(userDataDir()),
        on: true,
      }

    page.watchBlocks({
      state: () => slot.state,
      enabled: () => shelf().on,
      dir: () => shelf().dir,
      // Bounded inside the page by `TEXT_SCRIPT`; a challenge page is a few
      // hundred characters and this is what tells one from an ordinary 200.
      text: async () => {
        const read = await this.run<{ text?: string }>(TEXT_SCRIPT, { limit: 2_000 }, slot)
        return typeof read.text === 'string' ? read.text : null
      },
      shot: async () => {
        try {
          // One attempt. The window has not been revealed and must not be — see
          // `maskedPng`. No picture is a recorded outcome, not a failure.
          return (await this.maskedPng(slot, page, 1)).png
        } catch {
          return null
        }
      },
    })
  }

  /* -------------------------------------------------------------- reading -- */

  /**
   * Run one of this repository's own scripts in the page's isolated world.
   *
   * The only argument a caller may contribute is a JSON value, and the only
   * JSON value any tool contributes is a selector string. There is no path from
   * a model's text to a page's JavaScript — see `browser-drive-script.ts`.
   */
  private async run<T>(script: string, args: unknown, slot: Slot): Promise<T> {
    const page = this.contents(slot)
    if (!page) throw new DriveRefused('the page this was driving has gone')
    /*
     * The baton is checked here as well as in `send`, because reading does not
     * go through the debugger at all. Without this line the whole of §3's
     * password guarantee would have a hole the width of `browser.read`: the
     * protocol channel would be shut during a handover and the isolated world
     * would still answer.
     */
    if (slot.state !== 'agent') {
      throw new DriveRefused(
        slot.state === 'human'
          ? 'the person is using this page right now, so it cannot be read. Wait for them to hand it back.'
          : 'nothing is being driven, so there is no page to read',
      )
    }
    return page.runInIsolatedWorld<T>(withArgs(script, args))
  }

  /**
   * The page: what it says, and what can be acted on.
   *
   * `textLimit` bounds the prose half. It is a separate argument from `limit`
   * because the two answer different questions and a page can be extreme in
   * either direction on its own — a search results page is fifty controls and
   * two sentences, an article is one control and forty thousand characters.
   */
  /**
   * Take hold of the page a call names, claiming an attached window the first
   * time one is used.
   *
   * The claim is the part worth reading. The copilot's own tab becomes drivable
   * by being *opened* — `open` is the only thing that fills that slot, and a
   * verb on an empty one is refused telling the model to open first. An
   * attached window is the opposite case: it already exists, the person put it
   * there, and requiring `browser.open` before reading it would mean navigating
   * the page he attached in order to be allowed to look at it.
   *
   * So the first verb on an attached window claims it — watch, baton, debugger
   * — and every one after that finds it already held. The refusals a bound slot
   * can produce are the two real states: the person has the page, or the window
   * has gone. Neither of them ever says whether some *other* session's window
   * by that name exists; that answer is settled in `windowNamed` before a target
   * is minted at all.
   */
  private async hold(
    target?: DriveTarget | null,
    options: { reveal?: boolean } = {},
  ): Promise<{ slot: Slot; page: DrivenPage }> {
    const slot = this.slotFor(target)
    this.refuseWhileHuman(slot)
    /*
     * Anything that touches the page brings it to the front first. See
     * {@link DriveHost.showWindow} for the measurement that makes this a
     * requirement rather than a manner: a hidden window drops every click.
     *
     * Before the contents are read, because the answer changes what the page
     * is: `waitForActionable` re-probes on a 60ms loop, so the step simply
     * finds the element once the workspace has given the view a rectangle, with
     * no sleep here guessing how long that takes.
     */
    if (options.reveal === true && target && target.browserTabId !== '' && this.host.showWindow) {
      await this.host.showWindow(target.browserTabId).catch(() => false)
    }
    const page = this.contents(slot)
    if (!page) {
      throw new DriveRefused(
        slot === this.own
          ? 'there is no page being driven; call browser.open first'
          : `${slot.name} is not open any more. Read the window list again before naming one.`,
      )
    }
    if (slot.state === 'idle') {
      this.watch(page, slot)
      this.move(slot, 'claimed')
      await this.attach(page, slot)
    }
    return { slot, page }
  }

  async outline(
    limit: number,
    textLimit = DEFAULT_OUTLINE_TEXT_CHARS,
    target?: DriveTarget | null,
  ): Promise<{
    url: string
    title: string
    text: string
    textTruncated: boolean
    elements: OutlineElement[]
    matched: number
    truncated: boolean
  }> {
    const { slot } = await this.hold(target)
    const raw = await this.run<{
      url: string
      title: string
      text?: string
      textTruncated?: boolean
      elements: OutlineElement[]
      matched: number
      truncated: boolean
    }>(OUTLINE_SCRIPT, { limit, textLimit }, slot)
    const elements = (raw.elements ?? []).map((element) =>
      element.secret || looksSecret({ type: element.type })
        ? { ...element, secret: true, value: undefined }
        : element,
    )
    for (const element of elements) this.noteSecret(slot, element.selector, element.secret)
    return {
      url: String(raw.url ?? ''),
      title: String(raw.title ?? ''),
      /*
       * Defaulted rather than required, because the page is what answered.
       * A document with no body — a bare XML response, a PDF viewer — has no
       * `innerText`, and the empty string is the true answer for it rather than
       * a reason for the whole read to throw.
       */
      text: typeof raw.text === 'string' ? raw.text : '',
      textTruncated: raw.textTruncated === true,
      // Belt and braces over the page's own answer. The script never puts a
      // value on a secret field; this drops one if a future edit ever does.
      elements,
      matched: Number(raw.matched ?? 0),
      truncated: raw.truncated === true,
    }
  }

  async probe(selector: string, target?: DriveTarget | null): Promise<ProbeResult> {
    const { slot } = await this.hold(target)
    return this.probeIn(slot, selector)
  }

  /** The same, on a slot already held. Every internal loop uses this one. */
  private async probeIn(slot: Slot, selector: string): Promise<ProbeResult> {
    const result = await this.run<ProbeResult>(PROBE_SCRIPT, { selector }, slot)
    if (result.found) {
      this.noteSecret(slot, selector, result.secret === true || looksSecret({ type: result.type }))
    }
    return result
  }

  /**
   * Block until something appears, or say plainly that it never did.
   *
   * This is what stops a model polling, and polling is not a style problem: the
   * global budget in `control.ts` is 240 calls a minute, and a model asking
   * "is it there yet" in a loop spends that in fifteen seconds — after which
   * the *person's* copilot is rate-limited too. One call that waits costs one
   * slot.
   *
   * Deliberately weaker than the actionability wait: this only asks whether the
   * element exists and is visible, because "wait for the results to appear" is
   * a question about the page arriving and not about a click being safe. The
   * strict version runs inside `act`, where it belongs.
   */
  async waitFor(
    selector: string,
    timeoutMs: number,
    target?: DriveTarget | null,
  ): Promise<ProbeResult> {
    const { slot } = await this.hold(target)
    const deadline = this.host.now() + timeoutMs
    for (;;) {
      const probe = await this.probeIn(slot, selector)
      if (probe.invalid === true) {
        throw new DriveRefused(`that is not a valid CSS selector: ${selector}`)
      }
      if (probe.found && probe.visible) return probe
      if (this.host.now() >= deadline) {
        throw new DriveRefused(
          `waited ${timeoutMs}ms and ${selector} never appeared. Read the page without waitFor to see ` +
            'what is actually there.',
        )
      }
      await sleep(80)
    }
  }

  async textAt(
    selector: string | null,
    limit: number,
    target?: DriveTarget | null,
  ): Promise<{
    found: boolean
    secret: boolean
    text: string
    truncated: boolean
  }> {
    const { slot } = await this.hold(target)
    const raw = await this.run<{
      found: boolean
      secret?: boolean
      text?: string
      truncated?: boolean
    }>(TEXT_SCRIPT, { selector: selector ?? '', limit }, slot)
    return {
      found: raw.found === true,
      secret: raw.secret === true,
      text: raw.secret === true ? '' : String(raw.text ?? ''),
      truncated: raw.truncated === true,
    }
  }

  /**
   * Run one installed store tool's recipe against a page.
   *
   * The recipe is **arguments**, never code: it goes through the same
   * `withArgs` seam every other script here uses, into `EXTRACT_SCRIPT`, which
   * this repository wrote. `browser-store-recipe.ts` holds the whole argument
   * for why the tools store is built this way rather than by downloading
   * programs, and it is the argument this method exists to keep true — there is
   * no second path from a store tool into a page.
   *
   * Everything else is the ordinary read path, unchanged: `hold` takes the
   * baton, `run` refuses while a person has the page, and the isolated world is
   * the same one `browser.read` uses. A store tool therefore cannot reach past
   * `browser.read`; whether it may run on *this* page at all is settled one
   * layer up, in `deck-control/store-tools.ts`, against the recipe's origins.
   */
  async extract(plan: ExtractPlan, target?: DriveTarget | null): Promise<ExtractResult> {
    const { slot } = await this.hold(target)
    const raw = await this.run<Partial<ExtractResult>>(EXTRACT_SCRIPT, plan, slot)
    return {
      url: String(raw.url ?? ''),
      title: String(raw.title ?? ''),
      fields: typeof raw.fields === 'object' && raw.fields !== null ? raw.fields : {},
      rows: Array.isArray(raw.rows) ? raw.rows : [],
      rowsOnPage: Number(raw.rowsOnPage ?? 0),
      rowsReturned: Number(raw.rowsReturned ?? 0),
      counts:
        typeof raw.counts === 'object' && raw.counts !== null
          ? (raw.counts as ExtractResult['counts'])
          : {},
      stated: typeof raw.stated === 'number' && Number.isFinite(raw.stated) ? raw.stated : null,
      next: typeof raw.next === 'string' && raw.next !== '' ? raw.next : null,
    }
  }

  /* ------------------------------------------------------- actionability -- */

  /**
   * Wait until the element is genuinely ready to be acted on, or give up.
   *
   * This is the whole of what a hand-rolled driver usually gets wrong, and the
   * reason `DRIVABLE-BROWSER.md` §1 argued for Playwright. Every clause below
   * is a real failure with a name:
   *
   *  - **not attached yet** — the page is still rendering. Retry; the element
   *    arriving late is the ordinary case, not an error.
   *  - **invalid selector** — never becomes true, so it is refused immediately
   *    rather than retried until the timeout. A typo must not cost ten seconds.
   *  - **not visible** — zero-sized, `display: none`, fully transparent.
   *  - **not stable** — the box moved between two samples. This is the animated
   *    button: click it mid-transition and the event lands where it *was*.
   *  - **not enabled** — `disabled`, `aria-disabled`, or inside a disabled
   *    fieldset.
   *  - **not hit** — something else is painted at the point the click would
   *    land. The cookie banner, the modal backdrop, the loading overlay. This
   *    is the clause that turns "clicked Sign in" from a claim into a fact.
   *
   * It scrolls once, at the start, and then re-probes — so the coordinates
   * returned are read after the movement, not before it.
   */
  private async waitForActionable(
    slot: Slot,
    selector: string,
    timeoutMs: number,
    options: { needsHit: boolean } = { needsHit: true },
  ): Promise<ProbeResult & { rect: { x: number; y: number; width: number; height: number } }> {
    const deadline = this.host.now() + timeoutMs
    let last = 'the element was never found'
    let scrolled = false
    let previous: { x: number; y: number; width: number; height: number } | null = null
    let previousAt = 0

    for (;;) {
      const probe = await this.probeIn(slot, selector)

      if (probe.invalid === true) {
        throw new DriveRefused(
          `that is not a valid CSS selector, so no amount of waiting will find it: ${selector}`,
        )
      }

      if (!probe.found) {
        last = 'no element on the page matched that selector'
      } else {
        if (!scrolled) {
          scrolled = true
          await this.run(SCROLL_SCRIPT, { selector }, slot).catch(() => undefined)
          previous = null
          continue
        }
        const rect = probe.rect ?? null
        if (!probe.visible || rect === null) {
          last = 'the element is on the page but not visible'
        } else if (!probe.enabled) {
          last = 'the element is visible but disabled'
        } else if (
          previous === null ||
          previous.x !== rect.x ||
          previous.y !== rect.y ||
          previous.width !== rect.width ||
          previous.height !== rect.height
        ) {
          /*
           * The box moved, so this sample starts the clock again. Two matching
           * samples at least a frame apart is the cheapest honest definition of
           * "it has stopped moving" — one sample proves nothing, and watching
           * for an animation to end means knowing which animation.
           */
          previous = rect
          previousAt = this.host.now()
          last = 'the element is still moving'
        } else if (this.host.now() - previousAt < STABLE_FRAME_MS) {
          last = 'the element is still moving'
        } else if (options.needsHit && probe.hit !== true) {
          last = `something else is on top of it${probe.hitNode ? ` (${probe.hitNode})` : ''}`
        } else {
          return { ...probe, rect }
        }
      }

      if (this.host.now() >= deadline) {
        throw new DriveRefused(
          `gave up waiting for ${selector} after ${timeoutMs}ms: ${last}. Call browser.read to see ` +
            'what is actually on the page rather than trying the same selector again.',
        )
      }
      await sleep(60)
    }
  }

  /* --------------------------------------------------------------- acting -- */

  /**
   * One interaction with the page.
   *
   * The verb set is `StepKind` from `browser-steps.ts` — the same closed set
   * the flow recorder already emits — rather than a set invented here. That is
   * on purpose: a recorded flow and a driven flow speak one vocabulary with no
   * translation layer between them, which is what makes replaying a recording
   * a small feature later rather than a second driver.
   */
  async act(
    input: {
      verb: StepVerb
      selector: string
      value?: string
      key?: string
      timeoutMs?: number
    },
    target?: DriveTarget | null,
  ): Promise<{ verb: StepVerb; selector: string; label: string; url: string }> {
    const { slot, page } = await this.hold(target, { reveal: true })

    const selector = input.selector.trim()
    if (selector.length === 0) throw new DriveRefused('a step needs a selector')
    if (selector.length > MAX_SELECTOR_CHARS) {
      throw new DriveRefused(`that selector is longer than ${MAX_SELECTOR_CHARS} characters`)
    }
    /*
     * A step with nothing to type is not a step, and it used to be a success.
     *
     * `value ?? ''` is what stood here, and an empty string is a *real*
     * instruction — {@link type} clears the field with it, deliberately, and
     * that is worth keeping. What it must not also mean is "the caller never
     * sent one", because those two cases then produce the same silent success:
     * on 2026-08-20 a call passed `text:` instead of `value:`, nothing rejected
     * the argument it did not know, the field was cleared, and the tool
     * reported that it had typed. An agent believing it typed is worse than an
     * agent told no.
     *
     * So absent is refused and empty is honoured. Checked here as well as in
     * `browser-tools.ts` because the two run on opposite sides of the tool
     * boundary and this one holds for any caller of the drive.
     */
    if ((input.verb === 'type' || input.verb === 'select') && input.value === undefined) {
      throw new DriveRefused(
        input.verb === 'type'
          ? 'a type step needs `value` — the text to type. Send an empty string only to clear the field.'
          : 'a select step needs `value` — the option to choose.',
      )
    }
    if (input.verb === 'select' && input.value === '') {
      throw new DriveRefused('a select step needs an option to choose; `value` is empty')
    }
    const timeoutMs = Math.min(
      Math.max(input.timeoutMs ?? DEFAULT_ACTION_TIMEOUT_MS, 500),
      MAX_ACTION_TIMEOUT_MS,
    )

    // A `select` sets a value through a script and never dispatches a click, so
    // it does not need the point it would have clicked to be reachable.
    const needsHit = input.verb !== 'select'
    const found = await this.waitForActionable(slot, selector, timeoutMs, { needsHit })
    const label = typeof found.label === 'string' ? found.label : ''
    this.setStep(slot, describeStep(input.verb, label, selector))

    try {
      switch (input.verb) {
        case 'click':
          await this.clickAt(page, slot, found.rect)
          break
        case 'check':
          await this.check(page, slot, found, input.value)
          break
        case 'type':
          await this.type(page, slot, found, selector, input.value ?? '')
          break
        case 'select':
          await this.select(slot, selector, input.value ?? '')
          break
        case 'press':
          await this.press(page, slot, found, input.key ?? 'Enter')
          break
        case 'submit':
          await this.clickAt(page, slot, found.rect)
          await this.press(page, slot, found, 'Enter')
          break
      }
    } finally {
      this.setStep(slot, '')
    }

    return { verb: input.verb, selector, label, url: page.url() }
  }

  private async clickAt(
    page: DrivenPage,
    slot: Slot,
    rect: { x: number; y: number; width: number; height: number },
  ): Promise<void> {
    const x = Math.round(rect.x + rect.width / 2)
    const y = Math.round(rect.y + rect.height / 2)
    // A move first, because a page whose button only styles itself on hover
    // will also only bind its handler on hover, and this costs one message.
    await this.input(page, slot, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 })
    await this.input(page, slot, 'Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1, buttons: 1 })
    await this.input(page, slot, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1, buttons: 0 })
  }

  private async check(
    page: DrivenPage,
    slot: Slot,
    target: ProbeResult,
    value: string | undefined,
  ): Promise<void> {
    const wanted = value === undefined || value === '' ? true : value !== 'false'
    if (target.checked === wanted) return
    await this.clickAt(page, slot, target.rect as { x: number; y: number; width: number; height: number })
  }

  /**
   * Type into a field — and refuse, always, to type into a secret one.
   *
   * Not "should not": refused, by name, with the handover named as the way. The
   * agent therefore cannot type a credential even in the case where it somehow
   * has one, which makes {@link handover} the *only* path a password can take
   * — which is exactly the arrangement Asad described.
   *
   * The check is on the *probe's* answer, which came from
   * `browser-drive-script.ts`'s predicate, and then again on the shape of the
   * field here. Two implementations of one rule, deliberately, because they run
   * on opposite sides of a trust boundary.
   */
  private async type(
    page: DrivenPage,
    slot: Slot,
    target: ProbeResult,
    selector: string,
    value: string,
  ): Promise<void> {
    if (target.secret === true || looksSecret({ type: target.type })) {
      throw new DriveRefused(
        `${selector} is a password, one-time-code or file field. Nothing will be typed into it. Call ` +
          'browser.handover with a sentence saying what the person should fill in, and they will do it ' +
          'themselves — you will not see what they type, and neither will the log.',
      )
    }
    if (target.editable !== true) {
      throw new DriveRefused(`${selector} is not a field that can be typed into`)
    }
    if (value.length > MAX_TYPE_CHARS) {
      throw new DriveRefused(`that is longer than the ${MAX_TYPE_CHARS} characters a step will type`)
    }

    /*
     * Focus it, and clear whatever is in it.
     *
     * Select-all then type replaces, which is what a person does and what a form
     * expects; appending to a pre-filled field is the commonest way a driven
     * login ends up with the email address typed twice.
     *
     * ## `commands`, and why the modifier alone was not enough
     *
     * This used to send ⌘A (or ⌃A) as an ordinary modified key event and trust
     * the editor to interpret it. It does not. Chromium turns a keystroke into
     * an *editing command* through the platform's key-binding layer, which a
     * synthesised protocol event does not go through — so the field kept its
     * value and the new text was appended to it.
     *
     * Caught on 2026-08-20 by driving one page twice: `#out` came back reading
     * `clicked: B1 by nameback to B1`, which is two typed values in one field,
     * from a step that reported success both times. Exactly the failure the
     * paragraph above was written about, sitting in the code that was meant to
     * prevent it.
     *
     * `commands: ['selectAll']` is the documented way to ask for the editing
     * command itself, and it rides *with* the key event rather than replacing
     * it — so a page listening for `keydown` still sees ⌘A, which is what a
     * person pressing it would produce.
     */
    await this.clickAt(page, slot, target.rect as { x: number; y: number; width: number; height: number })
    const selectAll = process.platform === 'darwin' ? 4 : 2
    await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'rawKeyDown', modifiers: selectAll, key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65, commands: ['selectAll'] })
    await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', modifiers: selectAll, key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65 })

    if (value.length === 0) {
      await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
      await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
      return
    }

    /*
     * Per-character key events for anything short, one insert for anything
     * long, and the split is not an optimisation.
     *
     * `Input.insertText` goes through the editing pipeline and fires `input`,
     * which is enough for React's controlled inputs and for most forms. It does
     * *not* fire `keydown`, and a search box that opens its suggestion list on
     * `keydown` will sit there looking broken. Per-character events fire the
     * whole sequence, at the cost of three protocol messages per character —
     * which is fine for a password-length string and not fine for a paragraph.
     */
    if (value.length <= PER_KEY_LIMIT) {
      for (const char of value) {
        await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'keyDown', text: char, unmodifiedText: char, key: char })
        await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', key: char })
      }
      return
    }
    await this.input(page, slot, 'Input.insertText', { text: value })
  }

  private async select(slot: Slot, selector: string, value: string): Promise<void> {
    const result = await this.run<{ ok: boolean; reason?: string; value?: string }>(
      SELECT_SCRIPT,
      { selector, value },
      slot,
    )
    if (result.ok !== true) {
      throw new DriveRefused(result.reason ?? 'that option could not be chosen')
    }
  }

  private async press(
    page: DrivenPage,
    slot: Slot,
    target: ProbeResult,
    key: string,
  ): Promise<void> {
    const spec = PRESS_KEYS[key]
    if (!spec) {
      throw new DriveRefused(
        `${key} is not a key this can press. The ones it can are: ${PRESSABLE_KEYS.join(', ')}.`,
      )
    }
    // Aim the key at the element by focusing it first, unless the caller is
    // pressing into whatever already has focus after a `type`.
    if (target.rect && target.editable !== true) {
      await this.clickAt(page, slot, target.rect)
    }
    const base = {
      key: spec.key,
      code: spec.code,
      windowsVirtualKeyCode: spec.vk,
      nativeVirtualKeyCode: spec.vk,
    }
    await this.input(page, slot, 'Input.dispatchKeyEvent', { ...base, type: 'rawKeyDown' })
    if (spec.text !== undefined) {
      await this.input(page, slot, 'Input.dispatchKeyEvent', { type: 'char', text: spec.text })
    }
    await this.input(page, slot, 'Input.dispatchKeyEvent', { ...base, type: 'keyUp' })
  }

  /* ---------------------------------------------------------- screenshots -- */

  /**
   * A picture of the page, with every secret field painted out before the file
   * exists.
   *
   * The masking happens on the raw frame in this process, between the capture
   * and the PNG encode (`browser-png.ts`), so there is never a moment at which an
   * unmasked PNG is on disk or in a buffer anything else can read. That matters
   * even though the agent is shut out during a handover: a password manager
   * leaves the dots, a one-time-code field shows its digits in clear, and a
   * "show password" toggle shows the password — all three survive the person
   * handing the page back.
   *
   * The path is returned, never the bytes. An image in a tool result is
   * thousands of tokens and this app has a viewer for files.
   */
  async screenshot(
    target?: DriveTarget | null,
  ): Promise<{ path: string; width: number; height: number; masked: number }> {
    const { slot, page } = await this.hold(target, { reveal: true })
    const shot = await this.maskedPng(slot, page, 12)
    const dir = join(copilotPaths(userDataDir()).root, 'screenshots')
    mkdirSync(dir, { recursive: true })
    const path = join(dir, `page-${Date.now()}.png`)
    writeFileSync(path, shot.png)
    return { path, width: shot.width, height: shot.height, masked: shot.painted }
  }

  /**
   * A picture of the page with every secret field painted out, as bytes.
   *
   * Split out of {@link screenshot} so the automatic block capture
   * (`browser-block-watch.ts`) uses the *same* masking rather than a second
   * copy of it. Two spellings of "paint the password fields out" is how one of
   * them comes to be missing a case, and the automatic one is the copy nobody
   * is watching when it runs.
   *
   * `attempts` is the one difference between the two callers and it is
   * deliberate. `screenshot` has just revealed the window and can afford to wait
   * about a second for the compositor. The block watcher has revealed nothing —
   * it must not, it fires off a navigation the person did not ask about — so it
   * takes what is on screen or nothing, and records that there is no picture.
   */
  private async maskedPng(
    slot: Slot,
    page: DrivenPage,
    attempts: number,
  ): Promise<{ png: Buffer; width: number; height: number; painted: number }> {
    const secrets = await this.run<{
      rects: Array<{ x: number; y: number; width: number; height: number }>
      viewport: { width: number; height: number }
    }>(SECRET_RECTS_SCRIPT, {}, slot).catch(() => null)
    if (secrets === null) {
      // The page could not be asked where its password fields are, so there is
      // no way to know whether this picture has one in it. Refusing is the only
      // honest answer: a screenshot that never appears is a bug report, and one
      // that appears with a password in it is not noticed at all.
      throw new Error('the page could not be asked where its password fields are, so no picture was taken')
    }

    /*
     * Captured with a short retry, because a window that was just brought
     * forward has not been composited yet.
     *
     * A capture on a view with no surface either throws or hands back a
     * zero-sized frame, and both were reproduced by photographing a background
     * window. The reveal above fixes it, but not in the same tick — the
     * workspace has to lay the view out and the compositor has to draw a frame
     * — so this waits for that rather than reporting "no visible surface" for a
     * window that is on its way to being visible. A headless target always
     * composites, so the loop simply succeeds on its first pass there.
     */
    let frame: RawFrame | undefined
    let failure = 'it has no visible surface right now'
    for (let attempt = 0; attempt < Math.max(1, attempts); attempt++) {
      if (attempt > 0) await sleep(80)
      try {
        const shot = await page.capture()
        if (shot.width > 0 && shot.height > 0) {
          frame = shot
          break
        }
      } catch (error) {
        failure = error instanceof Error ? error.message : String(error)
      }
    }
    if (!frame) throw new Error(`the page could not be photographed: ${failure}`)
    const masked = maskFrame(frame, secrets.rects ?? [], secrets.viewport)
    return { png: masked.png, width: frame.width, height: frame.height, painted: masked.painted }
  }

  /* -------------------------------------------------------------- the network -- */

  /**
   * The page's network, armed: what it may fetch, and what it fetched.
   *
   * ## Why this lives here and not in a tool
   *
   * *"Don't build a full scraping framework inside a terminal app. The browser
   * should expose these capabilities cleanly; the orchestration can live
   * outside."* So what the drive owns is the arming and the counting; the crawl
   * — the frontier, the pacing, the retries, the resume ledger — belongs to
   * whatever is driving from outside, and none of it is in this repository.
   *
   * ## The two things this had to get right
   *
   *  - **Cheap, not blocked.** Answering an image request with a correctly
   *    sized transparent PNG costs no bandwidth and keeps every lazy-loader
   *    advancing. Blocking it is what lost 16,498 floor plans. See
   *    `browser-placeholder.ts`.
   *  - **Eager, not on demand.** Chromium evicts response bodies, so a capture
   *    that fetches them when somebody asks fetches them too late. See
   *    `browser-network.ts`.
   */

  /** Run ids, so two arms on one page are two folders. */
  private runSeq = 0

  /**
   * The network for a slot, made on first use.
   *
   * The transport is closures over the same `send` and `run` the rest of this
   * class uses, plus the page's own event stream — so every command it issues
   * goes through `screenCommand` and every read through the one isolated-world
   * call. There is no second door, which is the property `browser-cdp.test.ts`
   * asserts by counting call sites.
   */
  private netFor(slot: Slot, page: DrivenPage): PageNetwork {
    if (slot.network !== null) return slot.network
    const made = new PageNetwork({
      send: (method, params = {}) => this.send(page, slot, method, params),
      onEvent: (handler) => page.onEvent(handler),
      sizeOf: (url) => this.run<unknown>(imageSizeScript(url), null, slot),
      now: () => this.host.now(),
    })
    slot.network = made
    return made
  }

  /**
   * Arm this page for harvesting.
   *
   * Arming twice on one page **replaces** the previous run rather than stacking
   * on it: the old one is stopped, its summary is closed and handed back as
   * `previous`, and a new folder is started. Two capture stores writing one
   * manifest would interleave sequence numbers, and two rule sets would be one
   * rule set with the other silently ignored — which is exactly the shape of
   * quiet failure this whole piece of work exists to remove.
   */
  async armNetwork(
    input: {
      rules: FetchRules
      capture: boolean
      /** Which kinds' bodies to keep. Empty means the capture default. */
      bodyKinds: ReadonlySet<string>
      bounds: CaptureBounds
      /**
       * Which of the three the caller actually named.
       *
       * Without it a stored setting could never win: `capture` defaults to true
       * and `bounds` is filled in with the engine's own numbers before this is
       * called, so *"the caller said nothing"* and *"the caller said exactly the
       * default"* arrive here identical. A stored value may only replace the
       * first of those — a call that names a bound must get the bound it named.
       */
      named?: { rules?: boolean; capture?: boolean; bounds?: boolean }
    },
    target?: DriveTarget | null,
  ): Promise<{
    window: string | null
    rules: FetchRules
    /** Whether responses are actually being recorded — the profile may have said. */
    capturing: boolean
    dir: string
    manifest: string
    previous: NetworkStatus | null
  }> {
    const { slot, page } = await this.hold(target)
    /*
     * What this page's profile stored, for the parts of the call that named
     * nothing. A stored answer never overrules one the caller gave, and
     * `armed.rules` on the way out is what actually ran — so a caller that
     * omitted its rules can read which ones it got.
     */
    const { rules, capture, bounds } = resolveArming(
      {
        rules: input.rules,
        capture: input.capture,
        bounds: input.bounds,
        ...(input.named === undefined ? {} : { named: input.named }),
      },
      this.host.scrapeDefaults?.(slot.viewId ?? '') ?? null,
    )

    /*
     * Nothing to arm is refused here rather than performed, and here rather
     * than only at the tool, because this is the first point at which the whole
     * answer is known: the tool sees the call, and the call may deliberately
     * name nothing because the profile has an answer stored. A page armed with
     * no rule and no capture behaves exactly as it already did, so reporting
     * `armed: true` for it would be a control that says it worked and did not.
     *
     * Before the standing run is stopped, and that ordering is the whole of it:
     * a refusal that had already disarmed the previous run would throw away a
     * capture the caller never asked to end.
     */
    if (interceptedKinds(rules).length === 0 && !capture) {
      throw new DriveRefused(
        'that would arm nothing: no rule blocks or fulfills anything and capture is off. Set a rule, ' +
          'leave capture on, or store rules for this profile in the Scraping panel.',
      )
    }

    /*
     * The previous run is stopped and handed back, never left running beside
     * this one. Two stores appending one manifest would interleave sequence
     * numbers; two rule sets would be one rule set with the other silently
     * ignored.
     */
    const standing = slot.network
    slot.network = null
    const previous = standing === null ? null : await standing.disarm('it was armed again')

    let store: CaptureStore | null = null
    let dir = ''
    if (capture) {
      if (!this.host.captureFolder) {
        throw new DriveRefused(
          'this build cannot write captured traffic anywhere, so capture cannot be turned on. Arm the ' +
            'rules on their own, or read the page.',
        )
      }
      this.runSeq += 1
      const folder = this.host.captureFolder({
        viewId: slot.viewId ?? '',
        runId: `run-${this.host.now()}-${this.runSeq}`,
      })
      if (folder === null) {
        throw new DriveRefused('this page has no profile to file captured traffic under')
      }
      store = new CaptureStore(folder, bounds, { now: () => this.host.now() })
      /*
       * The folder is made *now*, while there is a caller to tell.
       *
       * Every later write happens inside a network event, where a throw would
       * leave a request paused and a page hanging. A disk that will not take
       * the directory is a refusal at the tool, not a run that quietly records
       * nothing.
       */
      try {
        store.open()
      } catch (error) {
        throw new DriveRefused(
          `could not make the capture folder: ${error instanceof Error ? error.message : String(error)}`,
        )
      }
      dir = store.dir
    }

    const network = this.netFor(slot, page)
    await network.arm({
      rules,
      capture:
        store === null
          ? null
          : {
              store,
              bodyKinds:
                input.bodyKinds.size === 0 ? new Set(['xhr', 'fetch']) : new Set(input.bodyKinds),
            },
    })
    /*
     * Which page this folder came from, written into its own summary.
     *
     * A folder of JSON with no record of what produced it is most of the way to
     * being useless — the same shape of half-answer as a dataset that never
     * states its own total. Both ends are recorded, because a harvest
     * navigates.
     */
    network.notePage({ url: page.url(), title: page.title(), armed: true })
    slot.touchedAt = this.host.now()
    return {
      window: slot === this.own ? null : slot.name,
      /*
       * What ran, never what was asked for. When the call named no rules and
       * the profile had some, these are the profile's — and a caller reading
       * `intercepting` off this rather than off its own arguments is a caller
       * whose result is true of the page in front of it.
       */
      rules,
      capturing: capture,
      dir,
      manifest: store === null ? '' : store.manifestPath,
      previous,
    }
  }

  /** What this page's network is doing, or null when nothing armed one. */
  networkStatus(target?: DriveTarget | null): NetworkStatus | null {
    const slot = this.slotFor(target)
    return slot.network === null ? null : slot.network.status()
  }

  /**
   * Stop, and answer with everything that happened.
   *
   * Null when nothing was armed — which the tool reports as a refusal rather
   * than as an empty success, because "there was nothing to stop" and "the run
   * captured nothing" are different facts and a caller acts on them
   * differently.
   */
  async disarmNetwork(target?: DriveTarget | null): Promise<NetworkStatus | null> {
    const slot = this.slotFor(target)
    const network = slot.network
    if (network === null) return null
    slot.network = null
    const page = this.contents(slot)
    // Best effort: a page that has gone still gets a summary, with the address
    // it was armed on and nothing where it ended up.
    if (page) network.notePage({ url: page.url(), title: page.title() })
    return network.disarm()
  }

  /* ------------------------------------------------------------- handover -- */

  /**
   * Give the page to the person, and wait.
   *
   * Flips the baton to `human`, at which point **every** command and every read
   * is refused at the mechanism rather than declined by a policy — see
   * `screenCommand` and {@link run}. Then it blocks, for a bounded window, and
   * reports honestly whether the person answered.
   *
   * The state outlives the call on purpose. Signing into an Apple ID with a
   * code on a phone takes longer than any tool timeout worth having, so the
   * banner stays up and the baton stays with him for as long as it takes, while
   * the tool call is a window onto that. `still-waiting` is not a failure and
   * the tool's description says so in those words.
   */
  async handover(
    prompt: string,
    windowMs = HANDOVER_WINDOW_MS,
    target?: DriveTarget | null,
  ): Promise<{
    outcome: HandoverOutcome
    waitedMs: number
    url: string
    title: string
  }> {
    const slot = this.slotFor(target)
    const page = this.contents(slot)
    if (!page) {
      throw new DriveRefused(
        slot === this.own
          ? 'there is no page being driven; call browser.open first'
          : `${slot.name} is not open any more. Read the window list again before naming one.`,
      )
    }
    const startedAt = this.host.now()

    /*
     * One question at a time, across every page.
     *
     * `DriveBanner` is drawn once per browser panel, so a second handover would
     * hide the first — and the person answering the visible one would be
     * answering a question about a page they were not shown. The refusal is
     * here, at the only door that can create the state, rather than a rule in
     * `resume` that has to guess which of two batons a click meant.
     */
    const asking = this.slots().find((entry) => entry.state === 'human' && entry !== slot)
    if (asking) {
      throw new DriveRefused(
        `the person is already being asked about ${asking.name === '' ? 'another page' : asking.name}. ` +
          'Wait for that one before asking about this one.',
      )
    }

    if (slot.state !== 'human') {
      // Claimed first when this is the first thing done to an attached window:
      // the baton can only be handed from `agent`, and a handover on a window
      // nothing has driven yet is a perfectly ordinary opening move.
      if (slot.state === 'idle') {
        this.watch(page, slot)
        this.move(slot, 'claimed')
        await this.attach(page, slot)
      }
      slot.prompt = sanitizeHandoverPrompt(prompt) || 'The copilot needs you to do something on this page.'
      /*
       * Before the baton moves, never after.
       *
       * `screenCommand` refuses every command while the person has the page, so
       * an interception left armed across a handover would pause his images and
       * then be unable to answer them — he would be handed a page that never
       * finishes loading, in order to type a password into it. The disarm has to
       * be sent while this side may still send.
       */
      await slot.network?.suspend('the person was given the page').catch(() => undefined)
      /*
       * And the cast, curtained on the same side of the flip and for the same
       * reason: `Page.stopScreencast` must be sent while this side may still
       * send, so the pixels stop at the source before the baton reaches the
       * person. After this, every watcher of this page sees a lock card and no
       * frame carries data until the page is handed back.
       */
      await this.casts.get(slot.key)?.curtain(slot.prompt).catch(() => undefined)
      this.move(slot, 'handover')
    }

    /*
     * One waiter. A second `browser.handover` while one is already blocked
     * replaces the first — the copilot is a single session, so two calls in
     * flight means the first one's client has already stopped listening, and
     * leaving it attached would resolve a promise nobody reads while the live
     * call waited for a second answer that is never coming.
     */
    slot.waiting?.('still-waiting')

    const outcome = await new Promise<HandoverOutcome>((resolve) => {
      let settled = false
      const finish = (value: HandoverOutcome): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (slot.waiting === finish) slot.waiting = null
        resolve(value)
      }
      const timer = setTimeout(() => finish('still-waiting'), windowMs)
      // Vitest holds the loop open for a pending timer, and this one is 90
      // seconds; the same `unref` `consent.ts` uses, for the same reason.
      timer.unref?.()
      slot.waiting = finish
    })

    const live = this.contents(slot)
    return {
      outcome,
      waitedMs: this.host.now() - startedAt,
      url: live ? live.url() : '',
      title: live ? live.title() : '',
    }
  }

  /**
   * The person answered the banner.
   *
   * `resume(true)` is "done, carry on" and `resume(false)` is "stop, I'll take
   * it from here" — a refusal to the agent, not a resume, which is why the
   * second one ends the drive rather than returning the baton.
   *
   * There is deliberately **no keyboard shortcut** for either.
   * `DRIVING-MODE.md` gives Space to a tour because a tour is passive; a
   * handover is somebody typing a password, and a keystroke is precisely what
   * gets hit by accident in the middle of one.
   */
  resume(carryOn: boolean): void {
    /*
     * The banner carries no id, so this answers whichever page the question was
     * asked about — which is the same slot {@link showing} put on screen,
     * because a `human` slot outranks everything there. One question is
     * outstanding at a time by construction: `handover` on a second page while
     * one is unanswered would put a second banner behind the first, so it is
     * refused there rather than resolved here.
     */
    const slot = this.slots().find((entry) => entry.state === 'human')
    if (!slot) return
    slot.prompt = ''
    if (carryOn) {
      this.move(slot, 'resumed')
      // The rules go back on with the baton. A run that stayed silently off
      // after a handover would be a control that looks armed and is not.
      void slot.network?.resume().catch(() => undefined)
      // And the cast comes back with them: the screencast is restarted and the
      // secret rects re-scanned, so the watchers' lock cards clear to live pixels.
      void this.casts.get(slot.key)?.uncurtain().catch(() => undefined)
      slot.waiting?.('resumed')
      slot.waiting = null
      return
    }
    const waiting = slot.waiting
    slot.waiting = null
    waiting?.('stopped')
    this.release(this.refOf(slot))
  }

  /* --------------------------------------------- the handover, from afar -- */

  /**
   * Who holds the handover on one window, for the frame that says so.
   *
   * The three facts `browser.handover.state` is made of, minus the one that is
   * per-recipient: `mine` is `taker === this connection`, and only the server
   * knows which connection it is about to write to. Answered for any slot,
   * including one nothing is being asked about — `asking: false` is the ordinary
   * case and is what a phone needs to hear to take its button away again.
   */
  handoverHolding(target?: DriveTarget | null): HandoverHolding {
    const slot = this.slotFor(target)
    const asking = slot.state === 'human'
    return {
      asking,
      prompt: asking ? slot.prompt : '',
      taker: asking ? this.casts.get(slot.key)?.takerId ?? null : null,
    }
  }

  /**
   * A watcher says *that person is me*.
   *
   * ## What this is for
   *
   * `browser.handover` is the copilot saying it needs a person — a login wall, a
   * two-factor code, a card number. On the desktop that person is already at the
   * keyboard, so the whole of the answer is a banner with two buttons. Against a
   * server watched from a phone, the person being asked is the one holding the
   * phone, and until this method existed the curtain took the pixels away from
   * them and the baton refused their keyboard. The one surface that could answer
   * was the only one told it may not.
   *
   * ## What it deliberately does not do
   *
   * It does not move the baton. The slot stays `human`, so `screenCommand` goes
   * on refusing the agent every read and every write for as long as this lasts —
   * that refusal is the mechanism the whole handover rests on and nothing here
   * touches it. What changes is scoped to one connection: `PageCast` stops
   * masking that watcher's frames and starts dispatching its taps down
   * `sendAsPerson`, which is a different door with the opposite condition on it.
   *
   * Refused when no handover is outstanding on this slot (there is no question to
   * answer), when this window is not being cast at all, when the connection is
   * not one of its watchers, and when somebody else already holds it. The last is
   * the same argument {@link handover} makes for one outstanding question at a
   * time, one layer further out: two people typing into one password field is not
   * a state worth being able to reach.
   */
  async takeHandover(
    target: DriveTarget | null | undefined,
    watcherId: string,
  ): Promise<{ ok: boolean; reason?: string }> {
    const slot = this.slotFor(target)
    if (slot.state !== 'human') {
      return { ok: false, reason: 'nobody is being asked to do anything on this page' }
    }
    const cast = this.casts.get(slot.key)
    if (!cast) return { ok: false, reason: 'that window is not being watched' }
    return cast.take(watcherId)
  }

  /**
   * The person on the phone answered: *done, carry on* or *stop, I'll take it
   * from here*.
   *
   * Routed into {@link resume} rather than reimplemented, and that is the whole
   * design of this method. `resume(true)` returns the baton, puts the network
   * rules back on, uncurtains the cast for every watcher and resolves the blocked
   * `browser.handover` call `resumed`; `resume(false)` ends the drive instead,
   * because *"stop, I'll take it from here"* is a refusal to the agent rather
   * than a resume. A second copy of that sequence living here is how the two
   * halves come to disagree about what a hand-back means — and the half that
   * would be missing a step is always the one nobody is looking at.
   *
   * The taker is released first, through {@link PageCast.untake}, so the page is
   * curtained again for the instant between the hands letting go and the baton
   * moving. `untake` sends its `Page.stopScreencast` while the slot is still
   * `human`, which is the only moment the person's door will carry it.
   *
   * **A `done` from a connection that is not the taker is refused, not obeyed.**
   * Otherwise a second phone watching the same page could hand it back on behalf
   * of the person halfway through typing a password into it — and the agent would
   * resume driving a form in whatever state it was left.
   */
  async handBackHandover(
    target: DriveTarget | null | undefined,
    watcherId: string,
    carryOn: boolean,
  ): Promise<{ ok: boolean; reason?: string }> {
    const slot = this.slotFor(target)
    if (slot.state !== 'human') {
      return { ok: false, reason: 'nobody is being asked to do anything on this page' }
    }
    const cast = this.casts.get(slot.key)
    if (!cast || !cast.isTaker(watcherId)) {
      return { ok: false, reason: 'this page was handed to somebody else, so it is not yours to hand back' }
    }
    await cast.untake()
    this.resume(carryOn)
    return { ok: true }
  }

  /* ---------------------------------------------------------------- watch -- */

  /**
   * Start (or renegotiate) a live cast of a page to one watcher.
   *
   * The screencast rides this class's own {@link send}, so it is screened by
   * `browser-cdp.ts` and refused the instant the person takes the page — which is
   * why a page with no drive yet is claimed here first (moved to `agent` and
   * attached), the same opening move a handover on an idle window makes. `emit`
   * is called by the cast for each frame; the server rebuilds it per watch so the
   * grant is re-read before every frame it writes to a socket. A page that has
   * gone is refused rather than cast into the void.
   *
   * ## Why a page the person holds is watched rather than refused
   *
   * This used to answer *"the person has this page right now"* whenever the slot
   * was `human`, and on a desktop that reads as sensible: the pixels are stopped,
   * so there is nothing to cast. On a phone it was a defect with two faces, and
   * both of them were found by asking what an ordinary few seconds looks like:
   *
   *  - **A rotation.** A viewer that resizes sends `browser.watch` again, which is
   *    a renegotiation. Refused mid-handover, `server.ts` drops the window from
   *    that connection's `watching` set — so turning the phone sideways while
   *    typing a password threw away the handover the person was holding.
   *  - **A reconnection.** A phone that backgrounds loses its socket and comes
   *    back with a new connection id and an empty watch set. Refused, it could
   *    neither see the question nor answer it, on the one screen the question was
   *    for.
   *
   * Nothing is leaked by allowing it. `PageCast.watch` starts no screencast while
   * the cast is curtained, every frame is masked for every watcher that is not
   * the taker, and the new watcher is drawn the same lock card and the same
   * sentence the ones already there received. What it gets is the question — which
   * is the point.
   */
  async startCast(input: {
    target?: DriveTarget | null
    watcherId: string
    window: string
    options: CastOptions
    emit: (frame: CastFrame) => void
  }): Promise<{ ok: boolean; reason?: string }> {
    const slot = this.slotFor(input.target)
    const page = this.contents(slot)
    if (!page) {
      return {
        ok: false,
        reason:
          slot === this.own
            ? 'there is no page being driven; open one first'
            : `${slot.name} is not open any more`,
      }
    }
    if (slot.state === 'idle') {
      this.watch(page, slot)
      this.move(slot, 'claimed')
      await this.attach(page, slot)
    }
    let cast = this.casts.get(slot.key)
    if (!cast) {
      cast = new PageCast(this.castSeam(page, slot))
      this.casts.set(slot.key, cast)
      /*
       * A cast made while the person already holds the page starts curtained.
       *
       * `handover` curtains `this.casts.get(slot.key)`, so a handover asked on a
       * page nobody was watching curtained nothing — and a cast built afterwards
       * would not know. It would be masked anyway (`maskFor` reads `isHuman()`),
       * but masked is not the same as curtained: the lock card that carries the
       * agent's *sentence* is drawn by `curtain()`, and without this the watcher
       * would get a blank canvas with no explanation on it.
       */
      if (slot.state === 'human') await cast.curtain(slot.prompt)
    }
    await cast.watch(input.watcherId, input.window, input.options, input.emit)
    return { ok: true }
  }

  /** Stop a watcher's cast; the page's cast is dropped when its last watcher leaves. */
  async stopCast(target: DriveTarget | null | undefined, watcherId: string): Promise<void> {
    const slot = this.slotFor(target)
    const cast = this.casts.get(slot.key)
    if (!cast) return
    await cast.unwatch(watcherId)
    if (cast.watcherCount === 0) this.casts.delete(slot.key)
  }

  /** A watcher rendered a frame — release its next one. */
  ackCast(target: DriveTarget | null | undefined, watcherId: string, seq: number): void {
    this.casts.get(this.slotFor(target).key)?.ack(watcherId, seq)
  }

  /** Forward one input event from a watcher to the page it is watching. */
  async castInput(
    target: DriveTarget | null | undefined,
    watcherId: string,
    frame: BrowserInputFrame,
  ): Promise<{ ok: boolean; reason?: string }> {
    const cast = this.casts.get(this.slotFor(target).key)
    if (!cast) return { ok: false, reason: 'that window is not being watched' }
    return cast.input(watcherId, frame)
  }

  /** Drop a watcher from every cast it holds — a socket that closed. */
  async dropWatcher(watcherId: string): Promise<void> {
    for (const [key, cast] of [...this.casts]) {
      await cast.unwatch(watcherId)
      if (cast.watcherCount === 0) this.casts.delete(key)
    }
  }

  /**
   * The seam a {@link PageCast} drives: this class's screened send, the page's
   * event stream, its secret-rects scan, and whether the person holds it.
   *
   * `scanSecrets` reaches the page through the one isolated-world read every
   * other read uses ({@link run}), so it is refused during a handover like
   * everything else — which leaves the previous rects in place, the safe
   * direction. Never a second door and never a file.
   */
  private castSeam(page: DrivenPage, slot: Slot): CastSeam {
    return {
      send: (method, params = {}) => this.send(page, slot, method, params),
      sendAsPerson: (method, params = {}) => this.sendAsPerson(page, slot, method, params),
      onEvent: (handler) => page.onEvent(handler),
      scanSecrets: () =>
        this.run<SecretScan>(SECRET_RECTS_SCRIPT, {}, slot).catch(() => null),
      isHuman: () => slot.state === 'human',
      now: () => this.host.now(),
    }
  }

  /* --------------------------------------------------------------- shared -- */

  private setStep(slot: Slot, step: string): void {
    if (slot.step === step) return
    slot.step = step
    slot.touchedAt = this.host.now()
    this.publish()
  }

  private refuseWhileHuman(slot: Slot): void {
    if (slot.state !== 'human') return
    throw new DriveRefused(
      'the person has this page right now. Wait — call browser.handover again to keep waiting, or say ' +
        'something to them. Do not try another way round.',
    )
  }

  /**
   * Has the page stopped loading?
   *
   * Answered from the page rather than from a sleep, because the app already
   * knows: {@link DrivenPage.onSettled} rides the page's own settle events, so
   * "has this settled" is a fact rather than a guess. A driver that slept
   * instead would be a driver whose timing is a guess, and guessed timing is
   * exactly the flakiness this feature exists to remove.
   *
   * Returns false rather than throwing on a timeout: a page that is still
   * streaming is usually usable, and the tool reports `settled: false` so the
   * model can decide rather than being told the open failed.
   */
  private async waitForSettled(page: DrivenPage, timeoutMs: number): Promise<boolean> {
    if (!page.isLoading()) return true
    return new Promise<boolean>((resolve) => {
      let done = false
      let off = (): void => undefined
      const finish = (value: boolean): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        off()
        resolve(value)
      }
      const timer = setTimeout(() => finish(false), timeoutMs)
      timer.unref?.()
      off = page.onSettled(() => finish(true))
    })
  }
}

/* ---------------------------------------------------------------- helpers -- */

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    timer.unref?.()
  })
}

/**
 * The present-tense sentence in the toolbar chip.
 *
 * The only feedback a driven click has. CDP input does not move the OS pointer
 * and nothing HTML can be drawn over a `WebContentsView`, so there is no cursor
 * to watch — a driven click simply happens, and this is what says it happened.
 * Injecting a synthetic cursor into the page was considered and rejected: an
 * isolated world shares the DOM, so it *could*, but adding an element to a page
 * you are also scraping pollutes the thing you came for.
 */
export function describeStep(verb: StepVerb, label: string, selector: string): string {
  const name = label.trim() === '' ? selector : `“${label.trim().slice(0, 40)}”`
  switch (verb) {
    case 'click':
      return `clicking ${name}`
    case 'type':
      return `typing into ${name}`
    case 'select':
      return `choosing in ${name}`
    case 'check':
      return `ticking ${name}`
    case 'press':
      return `pressing a key in ${name}`
    case 'submit':
      return `submitting ${name}`
  }
}

/** The empty status, re-exported so a caller need not import two modules. */
export { EMPTY_DRIVE_STATUS, shortLabel }
