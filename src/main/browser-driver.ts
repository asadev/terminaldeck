import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { app, nativeImage, type WebContents } from 'electron'
import { screenCommand, type DriveState } from './browser-cdp'
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
import { copilotPaths } from './copilot-home'
import { navigatePage, type SteerablePage } from './browser-route'
import { normalizeUrl, shortLabel } from './browser-url'
import { onWebContentsDestroyed } from './web-contents-teardown'

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
 * ## Where the protocol is used, and where it is not
 *
 * Only for **input**, and the reason is a single measured API difference:
 * `webContents.sendInputEvent()` requires the window to be focused
 * (`electron.d.ts:18068`) and CDP `Input.*` does not. Verified here with the
 * window explicitly blurred — `win.isFocused() === false` — after which
 * `Input.insertText` filled a field and two `Input.dispatchMouseEvent`s ran a
 * button's click handler. That is what makes "watch it work, then go and do
 * something else" possible, and it is why the driver is CDP-shaped at all.
 *
 * Everything else deliberately avoids the protocol:
 *
 *  - **Reading** goes through `executeJavaScriptInIsolatedWorld` with scripts
 *    from `browser-drive-script.ts`, so `Runtime.evaluate` is not merely denied
 *    at the gate — it is not needed, which is a stronger statement.
 *  - **Navigating** goes through `webContents.loadURL` after `normalizeUrl`,
 *    because `Page.navigate` bypasses the `will-navigate` guard entirely. That
 *    was measured, not assumed: a CDP navigate to `file:///etc/passwd` landed,
 *    with a `preventDefault()`-ing `will-navigate` handler installed. See the
 *    header of `browser-cdp.ts`.
 *  - **Screenshots** go through `webContents.capturePage()`, because
 *    `Page.captureScreenshot` was measured to *never resolve* on a view that is
 *    not composited, where `capturePage()` returned a correct image in the same
 *    state. A call that hangs forever is the worst possible shape for a feature
 *    whose complaint is instability.
 */

/* ------------------------------------------------------------- constants -- */

/**
 * The isolated world the drive's scripts run in.
 *
 * A fixed, arbitrary, high number so it cannot collide with world 0 (the page)
 * or with world 1, which is where a preload script's isolated context lives.
 * The guest preload in `browser-preload.ts` runs in that one; sharing a world
 * with it would mean the drive's helpers and the inspector's could see each
 * other's variables, and a name collision would be a bug nobody could
 * reproduce.
 */
const DRIVE_WORLD = 31_017

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
  /** The live contents of a tab this app opened, or null once it has gone. */
  contentsFor(tabId: string): WebContents | null
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
    machineId: string
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
  constructor(
    readonly key: string,
    /** `B2`, or empty for the copilot's own tab. */
    readonly name: string,
  ) {}
}

export class BrowserDrive {
  /** The copilot's own tab. Always present; never removed; today's behaviour. */
  private readonly own = new Slot('own', '')
  /** A session's attached windows, by slot key, created on first use. */
  private readonly bound = new Map<string, Slot>()
  private watched = new WeakSet<WebContents>()

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
    const wc = this.contents(slot)
    return {
      state: slot.state,
      tabId: slot.viewId,
      step: slot.step,
      prompt: slot.prompt,
      url: wc ? wc.getURL() : '',
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
   * The origin of the page the agent is on, or null.
   *
   * Read from the WebContents rather than from anything the model said, which
   * is what makes the escalation in `browser-tools.ts` sound: the grant lapses
   * the moment the tab's origin changes, *including* by a link click or a
   * server redirect, and that is a main-process fact needing nobody's
   * cooperation.
   */
  origin(target?: DriveTarget | null): string | null {
    const wc = this.contents(this.slotFor(target))
    if (!wc) return null
    try {
      return new URL(wc.getURL()).origin
    } catch {
      return null
    }
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

  private contents(slot: Slot): WebContents | null {
    if (slot.viewId === null || slot.viewId === '') return null
    const wc = this.host.contentsFor(slot.viewId)
    if (!wc || wc.isDestroyed()) return null
    return wc
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
    let wc = this.contents(slot)
    if (!wc && slot !== this.own) {
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
    if (wc && slot === this.own && slot.isolated !== input.isolate) {
      this.detach(slot)
      slot.viewId = null
      slot.grantedOrigin = null
      slot.secretSelectors.clear()
      wc = null
    }
    if (!wc) {
      const id = await this.host.openTab({ url: normalized.url, isolate: input.isolate })
      if (id === null) {
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
      wc = this.contents(slot)
      if (!wc) throw new DriveRefused('the browser tab went away before it could be driven')
    } else if (slot === this.own) {
      // The tab already exists, so this is a navigation rather than an open.
      // Through `loadURL` and not `Page.navigate`: see the class header.
      await wc.loadURL(normalized.url).catch(() => undefined)
    } else {
      /*
       * An attached window is *his* window, so it gets the courtesy a browser
       * gives: the page's own `beforeunload` is asked first.
       *
       * The same rule the shim's route already follows — `browser-route.ts`
       * says why at length — and reached through the same function, so a URL
       * arriving by tool and a URL arriving by `open <url>` cannot treat a
       * half-written form differently. Nothing here reads the URL, the title or
       * how long the page has been open; the page's own declaration is the only
       * signal, because a heuristic would silently navigate over work whose
       * owner could never find out what decided that.
       */
      const outcome = await navigatePage(wc as unknown as SteerablePage, normalized.url)
      if (outcome === 'unfinished') {
        throw new DriveRefused(
          `${slot.name} says it has unfinished work on the page, so it was not navigated. Ask the person, ` +
            'or open the URL in a new window instead.',
        )
      }
    }

    this.watch(wc, slot)
    this.move(slot, 'claimed')
    await this.attach(wc, slot)

    const settled = await this.waitForSettled(wc, input.settleMs ?? DEFAULT_SETTLE_MS)
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
    return { url: wc.getURL(), title: wc.getTitle(), settled, created }
  }

  /** The person closed the page, or it died. Ends that drive; never re-arms. */
  release(target?: DriveTarget | null): void {
    const slot = this.slotFor(target)
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
    machineId: string
  }): Promise<{ line: string; attached: boolean }> {
    if (!this.host.openForSession) {
      throw new DriveRefused('this build cannot open a window for a session')
    }
    const normalized = normalizeUrl(input.url)
    if (!normalized.ok) throw new DriveRefused(normalized.reason)
    return this.host.openForSession({ ...input, url: normalized.url })
  }

  /* ------------------------------------------------------------- the wire -- */

  private async attach(wc: WebContents, slot: Slot): Promise<void> {
    if (slot.attached && wc.debugger.isAttached()) return
    try {
      if (!wc.debugger.isAttached()) wc.debugger.attach('1.3')
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
    await this.send(wc, slot, 'Page.enable').catch(() => undefined)
    await this.send(wc, slot, 'Runtime.enable').catch(() => undefined)
  }

  private detach(slot: Slot): void {
    const wc = this.contents(slot)
    slot.attached = false
    if (!wc) return
    try {
      if (wc.debugger.isAttached()) wc.debugger.detach()
    } catch {
      // Already gone, or never attached. Either way there is nothing holding.
    }
  }

  /**
   * The only place a debugger command is sent.
   *
   * Screened first, always, by `browser-cdp.ts` — which is a pure function over
   * the method name and the state, so the rule can be read and tested without
   * an app. A caller that wanted to skip it would have to write a second
   * `sendCommand` call, which is a thing a reviewer can grep for.
   */
  private async send(
    wc: WebContents,
    slot: Slot,
    method: string,
    params: Record<string, unknown> = {},
  ): Promise<Record<string, unknown>> {
    const verdict = screenCommand({ state: slot.state, method, params })
    if (!verdict.ok) throw new DriveRefused(verdict.reason)
    const result = (await wc.debugger.sendCommand(method, params)) as unknown
    return typeof result === 'object' && result !== null ? (result as Record<string, unknown>) : {}
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
    wc: WebContents,
    slot: Slot,
    method: string,
    params: Record<string, unknown>,
  ): Promise<void> {
    await this.send(wc, slot, method, params)
  }

  /* ------------------------------------------------------- the page's life -- */

  /**
   * Watch a tab for the page underneath it going away.
   *
   * Registered once per WebContents. The teardown goes through
   * `web-contents-teardown.ts` for the reason that module exists: eleven
   * modules each being individually careful still produced a
   * `MaxListenersExceededWarning`, and a twelfth being careful would not have
   * helped.
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
  private watch(wc: WebContents, slot: Slot): void {
    onWebContentsDestroyed(wc, `browser-drive:${slot.key}`, () => {
      if (this.contents(slot) === null) this.release(this.refOf(slot))
    })
    if (this.watched.has(wc)) return
    this.watched.add(wc)

    /*
     * A reload of the *app* destroys every browser tab — `hostDocumentReplaced`
     * in `browser-tab.ts` is deliberate about it — and that ends any drive
     * instantly. The drive must not try to survive it: it ends, and the agent
     * is told why. A drive that re-armed itself after a reload would be a page
     * that starts moving on its own, which `DRIVING-MODE.md` §8 names as the
     * single behaviour that would make somebody uninstall.
     */
    wc.on('render-process-gone', () =>
      this.release(this.refOf(slot)),
    )
    wc.debugger.on('detach', () => {
      slot.attached = false
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
    const wc = this.contents(slot)
    if (!wc) throw new DriveRefused('the page this was driving has gone')
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
    return (await wc.executeJavaScriptInIsolatedWorld(DRIVE_WORLD, [
      { code: withArgs(script, args) },
    ])) as T
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
  ): Promise<{ slot: Slot; wc: WebContents }> {
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
    const wc = this.contents(slot)
    if (!wc) {
      throw new DriveRefused(
        slot === this.own
          ? 'there is no page being driven; call browser.open first'
          : `${slot.name} is not open any more. Read the window list again before naming one.`,
      )
    }
    if (slot.state === 'idle') {
      this.watch(wc, slot)
      this.move(slot, 'claimed')
      await this.attach(wc, slot)
    }
    return { slot, wc }
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
    const { slot, wc } = await this.hold(target, { reveal: true })

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
          await this.clickAt(wc, slot, found.rect)
          break
        case 'check':
          await this.check(wc, slot, found, input.value)
          break
        case 'type':
          await this.type(wc, slot, found, selector, input.value ?? '')
          break
        case 'select':
          await this.select(slot, selector, input.value ?? '')
          break
        case 'press':
          await this.press(wc, slot, found, input.key ?? 'Enter')
          break
        case 'submit':
          await this.clickAt(wc, slot, found.rect)
          await this.press(wc, slot, found, 'Enter')
          break
      }
    } finally {
      this.setStep(slot, '')
    }

    return { verb: input.verb, selector, label, url: wc.getURL() }
  }

  private async clickAt(
    wc: WebContents,
    slot: Slot,
    rect: { x: number; y: number; width: number; height: number },
  ): Promise<void> {
    const x = Math.round(rect.x + rect.width / 2)
    const y = Math.round(rect.y + rect.height / 2)
    // A move first, because a page whose button only styles itself on hover
    // will also only bind its handler on hover, and this costs one message.
    await this.input(wc, slot, 'Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 })
    await this.input(wc, slot, 'Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1, buttons: 1 })
    await this.input(wc, slot, 'Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1, buttons: 0 })
  }

  private async check(
    wc: WebContents,
    slot: Slot,
    target: ProbeResult,
    value: string | undefined,
  ): Promise<void> {
    const wanted = value === undefined || value === '' ? true : value !== 'false'
    if (target.checked === wanted) return
    await this.clickAt(wc, slot, target.rect as { x: number; y: number; width: number; height: number })
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
    wc: WebContents,
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
    await this.clickAt(wc, slot, target.rect as { x: number; y: number; width: number; height: number })
    const selectAll = process.platform === 'darwin' ? 4 : 2
    await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'rawKeyDown', modifiers: selectAll, key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65, commands: ['selectAll'] })
    await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', modifiers: selectAll, key: 'a', code: 'KeyA', windowsVirtualKeyCode: 65, nativeVirtualKeyCode: 65 })

    if (value.length === 0) {
      await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'rawKeyDown', key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
      await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', key: 'Delete', code: 'Delete', windowsVirtualKeyCode: 46, nativeVirtualKeyCode: 46 })
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
        await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'keyDown', text: char, unmodifiedText: char, key: char })
        await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'keyUp', key: char })
      }
      return
    }
    await this.input(wc, slot, 'Input.insertText', { text: value })
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
    wc: WebContents,
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
      await this.clickAt(wc, slot, target.rect)
    }
    const base = {
      key: spec.key,
      code: spec.code,
      windowsVirtualKeyCode: spec.vk,
      nativeVirtualKeyCode: spec.vk,
    }
    await this.input(wc, slot, 'Input.dispatchKeyEvent', { ...base, type: 'rawKeyDown' })
    if (spec.text !== undefined) {
      await this.input(wc, slot, 'Input.dispatchKeyEvent', { type: 'char', text: spec.text })
    }
    await this.input(wc, slot, 'Input.dispatchKeyEvent', { ...base, type: 'keyUp' })
  }

  /* ---------------------------------------------------------- screenshots -- */

  /**
   * A picture of the page, with every secret field painted out before the file
   * exists.
   *
   * The masking happens on the raw bitmap in this process, between
   * `capturePage()` and `toPNG()`, so there is never a moment at which an
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
    const { slot, wc } = await this.hold(target, { reveal: true })

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
     * `capturePage()` on a view with no surface either throws or hands back a
     * zero-sized image, and both were reproduced by photographing a background
     * window. The reveal above fixes it, but not in the same tick — the
     * workspace has to lay the view out and the compositor has to draw a frame
     * — so this waits for that rather than reporting "no visible surface" for a
     * window that is on its way to being visible.
     */
    let image
    let failure = 'it has no visible surface right now'
    for (let attempt = 0; attempt < 12; attempt++) {
      if (attempt > 0) await sleep(80)
      try {
        const shot = await wc.capturePage()
        const shotSize = shot.getSize()
        if (shotSize.width > 0 && shotSize.height > 0) {
          image = shot
          break
        }
      } catch (error) {
        failure = error instanceof Error ? error.message : String(error)
      }
    }
    if (!image) throw new Error(`the page could not be photographed: ${failure}`)
    const size = image.getSize()

    const masked = maskRects(image, secrets.rects ?? [], secrets.viewport)
    const dir = join(copilotPaths(app.getPath('userData')).root, 'screenshots')
    mkdirSync(dir, { recursive: true })
    const path = join(dir, `page-${Date.now()}.png`)
    writeFileSync(path, masked.png)
    return { path, width: size.width, height: size.height, masked: masked.painted }
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
    const wc = this.contents(slot)
    if (!wc) {
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
        this.watch(wc, slot)
        this.move(slot, 'claimed')
        await this.attach(wc, slot)
      }
      slot.prompt = sanitizeHandoverPrompt(prompt) || 'The copilot needs you to do something on this page.'
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
      url: live ? live.getURL() : '',
      title: live ? live.getTitle() : '',
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
      slot.waiting?.('resumed')
      slot.waiting = null
      return
    }
    const waiting = slot.waiting
    slot.waiting = null
    waiting?.('stopped')
    this.release(this.refOf(slot))
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
   * Answered from the WebContents rather than from a sleep, because the app
   * already knows: `wireGuestEvents` wires `did-stop-loading` and
   * `did-fail-load` per tab, so "has this settled" is a main-process fact. A
   * driver that slept instead would be a driver whose timing is a guess, and
   * guessed timing is exactly the flakiness this feature exists to remove.
   *
   * Returns false rather than throwing on a timeout: a page that is still
   * streaming is usually usable, and the tool reports `settled: false` so the
   * model can decide rather than being told the open failed.
   */
  private async waitForSettled(wc: WebContents, timeoutMs: number): Promise<boolean> {
    if (!wc.isLoading()) return true
    return new Promise<boolean>((resolve) => {
      let done = false
      const finish = (value: boolean): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        wc.off('did-stop-loading', onStop)
        wc.off('did-fail-load', onStop)
        resolve(value)
      }
      const onStop = (): void => finish(true)
      const timer = setTimeout(() => finish(false), timeoutMs)
      timer.unref?.()
      wc.on('did-stop-loading', onStop)
      wc.on('did-fail-load', onStop)
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

/**
 * Paint solid rectangles over a captured image, in place, on its raw bitmap.
 *
 * On the bitmap rather than by re-encoding through a drawing library, because
 * this repository has no drawing library in the main process and adding one to
 * hide a password would be a strange trade. `toBitmap()` hands back BGRA at the
 * image's device resolution; the rectangles arrive in CSS pixels, so they are
 * scaled by the ratio the buffer itself implies rather than by a device pixel
 * ratio read from the page — a page can lie about `devicePixelRatio`, and the
 * buffer cannot lie about its own length.
 */
export function maskRects(
  image: Electron.NativeImage,
  rects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
  viewport: { width: number; height: number },
): { png: Buffer; painted: number } {
  if (rects.length === 0) return { png: image.toPNG(), painted: 0 }

  const size = image.getSize()
  const bitmap = image.toBitmap()
  const shape = bitmapShape(size, bitmap.length, viewport)
  if (shape === null) return { png: image.toPNG(), painted: 0 }

  const painted = paintMasks(bitmap, shape, rects)
  const rebuilt = nativeImage.createFromBitmap(bitmap, {
    width: shape.pixelWidth,
    height: shape.pixelHeight,
    scaleFactor: shape.scale,
  })
  return { png: rebuilt.toPNG(), painted }
}

export interface BitmapShape {
  pixelWidth: number
  pixelHeight: number
  /**
   * Device pixels per **CSS** pixel — the number that puts a mask on the
   * password field rather than a hundred pixels above it.
   *
   * This was wrong once, and the picture is what caught it. The first version
   * derived the scale from the buffer's own length against
   * `NativeImage.getSize()`, which is self-consistent and answers a different
   * question: those two are both in device pixels, so the ratio is always 1 and
   * the rectangles — which come from `getBoundingClientRect` and are in CSS
   * pixels — were used unscaled. On a Retina page the mask landed at half the
   * offset and half the size: a grey bar above the form, and a perfectly
   * legible password box below it, in an image that *looked* redacted.
   */
  scale: number
  /** What the image is scaled against. Reported so a caller can log it. */
  viewport: { width: number; height: number }
}

/**
 * How big the raw buffer actually is, in device pixels.
 *
 * Derived from the buffer's own length rather than from a device pixel ratio
 * read out of the page, because the page can lie about `devicePixelRatio` and
 * the buffer cannot lie about how long it is. A mismatch throws rather than
 * falling back: returning the unmasked image is the single outcome this whole
 * path exists to prevent, so refusing the picture is the safe direction.
 *
 * Null when the image is empty, which is a caller's problem rather than a
 * masking failure.
 */
export function bitmapShape(
  size: { width: number; height: number },
  bytes: number,
  viewport: { width: number; height: number },
): BitmapShape | null {
  const pixels = bytes / 4
  if (size.width <= 0 || size.height <= 0 || pixels <= 0) return null

  /*
   * How many bytes the buffer really holds, against the size the image claims.
   *
   * These are both device measurements, so the ratio is normally 1 — but it is
   * checked rather than assumed, because an image whose buffer is not
   * width×height×4 is one this arithmetic cannot index safely, and indexing it
   * wrongly writes grey pixels somewhere other than over the password.
   */
  const buffered = Math.sqrt(pixels / (size.width * size.height))
  if (!Number.isFinite(buffered) || buffered <= 0) return null
  const pixelWidth = Math.round(size.width * buffered)
  const pixelHeight = Math.round(size.height * buffered)
  if (pixelWidth * pixelHeight * 4 !== bytes) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }

  /*
   * And the number that matters: device pixels per CSS pixel.
   *
   * Refused rather than guessed when the page could not report its viewport. A
   * default of 1 would be right on some machines and would silently mis-place
   * every mask on a Retina display, which is the failure this whole function
   * exists to prevent. The clamp catches a viewport that is absurd relative to
   * the image — a page mid-resize, or a lying number — for the same reason.
   */
  if (!Number.isFinite(viewport.width) || viewport.width <= 0) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }
  const scale = pixelWidth / viewport.width
  if (!Number.isFinite(scale) || scale < 0.25 || scale > 8) {
    throw new Error('the screenshot could not be masked, so it was not written')
  }
  return { pixelWidth, pixelHeight, scale, viewport }
}

/**
 * Paint over the rectangles, in place, and say how many landed.
 *
 * Pure over a buffer so it can be driven from a test with a sentinel colour and
 * no Electron — which matters, because "the password was still in the PNG" is
 * not a defect anybody would notice by looking.
 */
export function paintMasks(
  bitmap: Buffer,
  shape: BitmapShape,
  rects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
): number {
  let painted = 0
  for (const rect of rects) {
    const left = Math.max(0, Math.floor(rect.x * shape.scale))
    const top = Math.max(0, Math.floor(rect.y * shape.scale))
    const right = Math.min(shape.pixelWidth, Math.ceil((rect.x + rect.width) * shape.scale))
    const bottom = Math.min(shape.pixelHeight, Math.ceil((rect.y + rect.height) * shape.scale))
    if (right <= left || bottom <= top) continue
    painted++
    for (let y = top; y < bottom; y++) {
      const rowStart = (y * shape.pixelWidth + left) * 4
      const rowEnd = (y * shape.pixelWidth + right) * 4
      // Opaque mid-grey, in BGRA order. Not black: a black rectangle on a dark
      // page is invisible, and the point of the mask is that a person looking
      // at the picture can see that something was hidden there.
      bitmap.fill(0x80, rowStart, rowEnd)
      for (let i = rowStart + 3; i < rowEnd; i += 4) bitmap[i] = 0xff
    }
  }
  return painted
}

/** The empty status, re-exported so a caller need not import two modules. */
export { EMPTY_DRIVE_STATUS, shortLabel }
