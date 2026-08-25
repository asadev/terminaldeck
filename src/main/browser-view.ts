import { mkdir, writeFile } from 'node:fs/promises'
import { join, resolve, sep } from 'node:path'
import {
  app,
  shell,
  type IpcMain,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
  type WebContents,
} from 'electron'
import { BRAND } from '../shared/brand'
import { guestSession } from './browser-session'
import { isIsolatedGuestSession } from './browser-isolation'
import { isProfileGuestSession } from './browser-profiles'
import { cleanUserAgent } from './browser-user-agent'
import { noteManualZoom } from './browser-fit'
import { GUEST_RECORD_CHANNEL, GUEST_STEP_CHANNEL, safeAccent } from './browser-record-preload'
import { decodePngDataUrl, markedName } from './marked-image'
import {
  appendStep,
  flowLine,
  formatFlow,
  isFull,
  navigateStep,
  parseGuestStep,
  type RecordedStep,
} from './browser-steps'

/**
 * Everything a browser tab can do that `browser-tab.ts` does not already do:
 * find-in-page, zoom, print, devtools, screenshots, load progress and the flow
 * recorder.
 *
 * ## Why this module has to find the view for itself
 *
 * `browser-tab.ts` owns the views and keeps them in a private map. It is not
 * mine to change, and duplicating it would mean two modules creating views into
 * the same window. So the link is made the other way round: every WebContents
 * Electron creates announces itself, the ones belonging to the guest partition
 * are held aside, and the renderer *claims* the one it was just handed an id
 * for. That the guest session is already set when `web-contents-created` fires
 * is not an assumption — it was checked on Electron 41.10.5, along with the
 * `capturePage`, `setZoomFactor` and `openDevTools` this module leans on.
 *
 * The claim is ordered, not guessed: the renderer awaits its `browser:create`
 * before claiming, and creates tabs one at a time, so "the newest guest view
 * nobody has claimed" is the one that call just produced. If that ever stops
 * being true — a second window creating tabs concurrently — the fix is a lookup
 * exported from `browser-tab.ts`; {@link setViewResolver} is the seam for it and
 * costs nothing until it is needed.
 *
 * ## The page is still untrusted here
 *
 * Recorded steps arrive from the same guest scripts the inspector uses and get
 * the same treatment: only the tab's own top frame may speak, only while
 * recording is explicitly on, and the payload goes through `browser-steps.ts`
 * before it can reach the UI or an agent's prompt. The page's idea of what URL
 * it is on is never used — the main process supplies that.
 */

/* ------------------------------------------------------------------ types -- */

export type LoadPhase = 'idle' | 'navigating' | 'loading' | 'done'

export interface LoadProgress {
  phase: LoadPhase
  /** 0 to 1. Milestones, not a byte count — Chromium does not expose one. */
  fraction: number
}

export interface RecordingState {
  recording: boolean
  steps: RecordedStep[]
  /** The numbered list, ready to show or copy. */
  text: string
  /** The same flow on one line, ready to type into an agent's prompt. */
  line: string
  /** Recording hit the step cap and stopped adding. */
  truncated: boolean
}

export interface ScreenshotResult {
  path: string
  width: number
  height: number
  /**
   * The shot itself, as a `data:image/png` URL, small enough to put in an
   * `<img>` without moving megabytes through the bridge on every capture.
   *
   * A screenshot the user cannot see is a filename, and that is exactly what
   * they got: a one-line banner reading *"Saved 3072 x 1496 to …png"* with
   * Reveal and Dismiss beside it. His words on 2026-08-16 — *"maybe it should
   * take a screenshot and give us a pop up to type and send to the agent"* — so
   * the popup needs the picture, and the renderer has no filesystem to read it
   * back with.
   *
   * Empty when the resize or the encode failed. The renderer then shows the path
   * and the send box without a picture, which is what this screen already was.
   */
  preview: string
}

/**
 * How wide the preview is, in device pixels.
 *
 * A full-resolution capture on this machine is 3072 x 1496; as base64 that is
 * several megabytes crossing the bridge for a thumbnail that is drawn inside a
 * popup a few hundred pixels wide. 1200 is comfortably more than the popup can
 * show on a Retina display and roughly a sixth of the bytes.
 */
const PREVIEW_WIDTH = 1200

/**
 * A photograph of a page, handed to the renderer to be drawn on.
 *
 * Distinct from {@link ScreenshotResult} because nothing has been saved: this is
 * the frame draw mode marks up, and until the user presses Send there is no file
 * and no reason for one. Writing a plain capture to Pictures every time somebody
 * opened the draw tool would leave two files per annotation, one of which nobody
 * asked for.
 */
export interface PageFrame {
  /** The page as a lossless `data:image/png` URL — the base of the composite. */
  image: string
  width: number
  height: number
  /** Where the page was, from the main process rather than from the page. */
  url: string
}

/**
 * What was written after the user marked a frame up.
 *
 * A {@link ScreenshotResult} without the `preview`, because the renderer drew
 * these pixels and still has them: sending them back would be the same three
 * megabytes crossing the bridge a second time. The `url` is here and not on a
 * plain screenshot because this is the one that goes to an agent as evidence —
 * *"we can send it to the agent like this"* — and a picture of a bug with no
 * address on it is a picture an agent cannot act on.
 *
 * The width and the height are read out of the PNG's own header, never taken
 * from the renderer: what the popup shows, what the agent is told and what is on
 * disk are then the same three numbers by construction.
 */
export interface MarkedShot {
  path: string
  width: number
  height: number
  url: string
}

/**
 * How wide the frame handed to draw mode is, in device pixels.
 *
 * Larger than {@link PREVIEW_WIDTH}, because this one is not a thumbnail: it is
 * the base of the PNG that gets written to disk and opened by an agent, so text
 * in it has to stay readable. A stage of about a thousand CSS pixels captures at
 * two thousand on a Retina display, so this rarely bites at all — it is a bound
 * on the string crossing the bridge, not a resampling anybody will see.
 *
 * Lossless, unlike the JPEG `browser-tab.ts` uses to freeze the page behind a
 * popup. That one is a backdrop; this one is evidence in a bug report, and JPEG
 * ringing around body text is exactly the kind of artefact that sends an agent
 * looking at the wrong thing.
 */
const FRAME_WIDTH = 2000

interface ViewEntry {
  tabId: string
  wc: WebContents
  /** The renderer that claimed this tab, and the only one told about it. */
  host: WebContents
  recording: boolean
  /**
   * A find session is open on this page.
   *
   * Held here because two decisions depend on it and neither may guess: Esc in
   * the page closes the find bar *only* while one is up — otherwise Esc stays
   * the page's own key — and releasing a tab mid-find must clear Chromium's
   * highlights rather than leave orange marks on a page whose bar is gone.
   */
  finding: boolean
  /**
   * The badge colour last handed over by the renderer.
   *
   * Held rather than passed around because every new document needs it again —
   * see the `dom-ready` re-arm in {@link attach}.
   */
  accent: string
  steps: RecordedStep[]
  /** Listener removals, run when the tab is released or the view dies. */
  detach: Array<() => void>
}

/* --------------------------------------------------------------- channels -- */

/**
 * The two channels this module *pushes* on, and the second half of why the flow
 * recorder recorded nothing.
 *
 * They used to be `browser-view:recording` and `browser-view:progress`, and the
 * preload subscribes to `browser:recording` and `browser:progress`. Nothing ever
 * failed: `webContents.send` on a channel nobody listens to is a no-op, and
 * `ipcRenderer.on` for a channel nobody sends is a no-op, so both sides looked
 * correct in isolation and neither could see the other. The preload even carries
 * a comment explaining that "no main-process emitter exists for these two yet",
 * written while the emitters were sitting in this file.
 *
 * The visible result was a Flow counter frozen at one step across forty clicks
 * on 2026-08-16 — the opening `Go <url>`, which comes back from the *invoke*, and
 * then nothing, because every step after it travelled by push. The load-progress
 * bar was dead for the same reason and nobody had noticed at all.
 *
 * `browser:*` is the right half of the pair to keep: `browser-tab.ts` already
 * pushes `browser:state-changed` and `browser:element`, so every push the
 * browser makes now shares one prefix, and the `browser-view:*` names stay on
 * the invoke channels, which are this module's own.
 *
 * Named constants rather than literals, and exported, because
 * `browser-view.channels.test.ts` reads them against the preload's `ipcRenderer.on`
 * calls. A mismatch across an `unknown` seam is invisible to the type checker;
 * the only thing that can see it is a test that reads both files.
 */
export const RECORDING_CHANNEL = 'browser:recording'
export const PROGRESS_CHANNEL = 'browser:progress'
/** Match counts from Chromium's `found-in-page`, for the find bar to print. */
export const FIND_CHANNEL = 'browser:find'
/**
 * Chords pressed *inside the page*, forwarded to the renderer that owns the
 * find bar and the zoom state.
 *
 * A browser page is its own WebContents: once somebody clicks into it, ⌘F goes
 * to the site and the renderer never hears the key at all — which is how the
 * browser shipped with a find bar reachable only while the address bar happened
 * to have focus, i.e. never. `before-input-event` in {@link attach} is the one
 * place both halves of the app can be heard from, and `preventDefault` there
 * also stops the application menu's accelerators, so ⌘+ steps the *page's*
 * zoom instead of the app chrome's — the two `role: 'zoomIn'` items in
 * `menu.ts` keep the rest of the app exactly as it was.
 */
export const KEY_CHANNEL = 'browser:key'

/* --------------------------------------------------------------- registry -- */

const views = new Map<string, ViewEntry>()
/** Guest views that exist but have not been claimed by a tab id yet. */
const unclaimed: WebContents[] = []
let watchingCreations = false

/**
 * Optional override for how a tab id becomes a WebContents.
 *
 * Unused today. It exists so that if `browser-tab.ts` ever exports a lookup —
 * `export const browserTabContents = (id: string) => tabs.get(id)?.view.webContents ?? null` —
 * wiring it here is one line in `index.ts` and the claim dance below can be
 * deleted rather than reworked.
 */
let resolveView: ((tabId: string) => WebContents | null) | null = null

export function setViewResolver(resolver: (tabId: string) => WebContents | null): void {
  resolveView = resolver
}

/**
 * Is this a page the user browsed to, in one of our browser tabs?
 *
 * The session test alone is not enough, and this was checked rather than
 * assumed. Opening devtools on a guest page creates a *third* WebContents that
 * reports the guest session as its own — so a session-only filter puts the
 * devtools window on the unclaimed pile, and the next new tab claims it instead
 * of its page. What separates them is `getType()`: a `WebContentsView`'s page
 * reports `window`, devtools reports `remote`.
 *
 * The URL check is the second net. It does nothing at creation time, when every
 * URL is still empty, but it catches anything already loaded by the time it is
 * claimed.
 */
function isGuest(wc: WebContents): boolean {
  if (wc.isDestroyed()) return false
  if (wc.getType() !== 'window') return false
  if (wc.getURL().startsWith('devtools://')) return false
  // An isolated tab is on a partition of its own, so a check against the shared
  // session alone would leave it permanently unclaimed — no zoom, no devtools,
  // no screenshots, no load progress and no recording, with nothing on screen
  // to say why.
  // A page opened in a second browser profile is on that profile's own
  // partition, so a check against the active one alone would leave every tab
  // from a profile the person has since switched away from permanently
  // unclaimed — no zoom, no devtools, no screenshots, no load progress and no
  // recording, with nothing on screen to say why. The identical trap the
  // isolated check above exists for.
  return (
    wc.session === guestSession() ||
    isIsolatedGuestSession(wc.session) ||
    isProfileGuestSession(wc.session)
  )
}

function watchCreations(): void {
  if (watchingCreations) return
  watchingCreations = true
  app.on('web-contents-created', (_event, contents) => {
    if (!isGuest(contents)) return
    unclaimed.push(contents)
    contents.once('destroyed', () => {
      const index = unclaimed.indexOf(contents)
      if (index >= 0) unclaimed.splice(index, 1)
    })
  })
}

function claim(): WebContents | null {
  // Prune first: a view closed before it was ever claimed — which StrictMode's
  // double mount produces on every dev reload — would otherwise be handed out,
  // and so would a devtools window that only revealed itself once it had a URL.
  for (let i = unclaimed.length - 1; i >= 0; i--) {
    if (!isGuest(unclaimed[i])) unclaimed.splice(i, 1)
  }
  return unclaimed.pop() ?? null
}

function entryFor(tabId: unknown): ViewEntry {
  const entry = typeof tabId === 'string' ? views.get(tabId) : undefined
  if (!entry || entry.wc.isDestroyed()) {
    throw new Error('browser-view: that tab is not open here')
  }
  return entry
}

function send(entry: ViewEntry, channel: string, payload: unknown): void {
  if (entry.host.isDestroyed()) return
  entry.host.send(channel, entry.tabId, payload)
}

/* -------------------------------------------------------------- recording -- */

function stateOf(entry: ViewEntry): RecordingState {
  return {
    recording: entry.recording,
    steps: entry.steps,
    text: formatFlow(entry.steps),
    line: flowLine(entry.steps),
    truncated: isFull(entry.steps),
  }
}

function pushRecording(entry: ViewEntry): void {
  send(entry, RECORDING_CHANNEL, stateOf(entry))
}

function record(entry: ViewEntry, step: RecordedStep | null): void {
  if (!entry.recording || !step) return
  const next = appendStep(entry.steps, step)
  // appendStep returns the same array when a step folded into the previous one
  // or the cap was hit; re-rendering the panel for that is pure noise.
  if (next === entry.steps) return
  entry.steps = next
  pushRecording(entry)
}

function tellGuestRecording(entry: ViewEntry): void {
  if (entry.wc.isDestroyed()) return
  entry.wc.send(GUEST_RECORD_CHANNEL, { on: entry.recording, accent: entry.accent })
}

/**
 * Only the tab's own top document may report a step.
 *
 * Fail closed, the same way `browser-tab.ts` does for element captures:
 * `senderFrame` is null once the sending frame has navigated away, and older
 * Electron throws rather than returning null, so "no frame" has to mean refuse.
 * Reading it as "must be the main frame, then" lets an embedded frame's message
 * through whenever it manages to die between the send and the receipt.
 */
function isFromMainFrame(event: IpcMainEvent, wc: WebContents): boolean {
  try {
    const frame = event.senderFrame
    return frame !== null && frame === wc.mainFrame
  } catch {
    return false
  }
}

/* ------------------------------------------------------------- attachment -- */

function progress(entry: ViewEntry, phase: LoadPhase, fraction: number): void {
  send(entry, PROGRESS_CHANNEL, { phase, fraction } satisfies LoadProgress)
}

function attach(entry: ViewEntry): void {
  const { wc } = entry

  // `did-start-navigation` carries its details on the *event* object — the
  // positional `url`/`isMainFrame` arguments after it are deprecated. A
  // same-document navigation (pushState, a fragment link) never loads anything,
  // so showing progress for one would leave a bar that never finishes.
  const onStart = (details: { isMainFrame: boolean; isSameDocument: boolean }) => {
    if (!details.isMainFrame || details.isSameDocument) return
    progress(entry, 'navigating', 0.15)
    // The matches belonged to the document that is leaving. Zero the bar rather
    // than let it keep asserting "3/17" about a page nobody can see; the
    // renderer re-runs the query against the new document when the URL lands.
    if (entry.finding) send(entry, FIND_CHANNEL, { ordinal: 0, matches: 0, final: true })
  }
  // Every document gets a fresh copy of the session preload, so recording has to
  // be switched back on after each navigation or it silently stops observing —
  // the same re-arm `browser-tab.ts` does for the inspector, and the same
  // failure without it. This one is worse than a dead inspector: the panel, the
  // tab's dot and the in-page badge would all still say Recording while every
  // click after the first navigation went unrecorded, and a login flow navigates
  // by definition.
  const onDom = () => {
    progress(entry, 'loading', 0.65)
    if (entry.recording) tellGuestRecording(entry)
  }
  const onStop = () => progress(entry, 'done', 1)
  const onNavigate = (_event: unknown, url: string) => {
    record(entry, navigateStep(url, Date.now()))
  }
  /*
   * Match counts, straight from Chromium. The renderer never counts anything —
   * the number beside the find field is this event, forwarded with the tab id,
   * so the bar can only ever describe the page it is actually attached to.
   */
  const onFound = (
    _event: unknown,
    result: { requestId: number; activeMatchOrdinal: number; matches: number; finalUpdate: boolean },
  ) => {
    if (!entry.finding) return
    send(entry, FIND_CHANNEL, {
      ordinal: result.activeMatchOrdinal,
      matches: result.matches,
      final: result.finalUpdate,
    })
  }
  /*
   * The chords the chrome answers for a focused page — see {@link KEY_CHANNEL}.
   * `preventDefault` keeps the key from the site *and* from the application
   * menu's accelerators, which is what stops ⌘+ zooming the app chrome and ⌘P
   * opening Quick Open over a page somebody is trying to print.
   */
  const onInput = (event: { preventDefault: () => void }, input: Parameters<typeof guestChord>[0]) => {
    const chord = guestChord(input, entry.finding)
    if (!chord) return
    event.preventDefault()
    send(entry, KEY_CHANNEL, chord)
  }

  wc.on('did-start-navigation', onStart)
  wc.on('dom-ready', onDom)
  wc.on('did-stop-loading', onStop)
  wc.on('did-navigate', onNavigate)
  wc.on('found-in-page', onFound)
  wc.on('before-input-event', onInput)

  entry.detach.push(() => {
    if (wc.isDestroyed()) return
    wc.off('did-start-navigation', onStart)
    wc.off('dom-ready', onDom)
    wc.off('did-stop-loading', onStop)
    wc.off('did-navigate', onNavigate)
    wc.off('found-in-page', onFound)
    wc.off('before-input-event', onInput)
  })

  // A guest process can die on its own — a crash, or a window taking its child
  // views down. Without this the map keeps a dead view forever and every later
  // call walks it.
  wc.once('destroyed', () => {
    views.delete(entry.tabId)
  })
}

function release(tabId: string): void {
  const entry = views.get(tabId)
  if (!entry) return
  // Releasing usually precedes closing, but not always — the workspace can be
  // unmounted while its pages stay alive. A guest left recording would keep its
  // capture-phase listeners and its badge with nothing on this side listening,
  // which is the surveillance-shaped bug the recorder is built to avoid.
  if (entry.recording) {
    entry.recording = false
    tellGuestRecording(entry)
  }
  // A page released mid-find would keep Chromium's highlights with no bar left
  // to explain them or any key bound to clear them.
  if (entry.finding && !entry.wc.isDestroyed()) {
    entry.finding = false
    entry.wc.stopFindInPage('clearSelection')
  }
  for (const off of entry.detach) off()
  views.delete(tabId)
}

/* ------------------------------------------------------------ screenshots -- */

/** Where captures land. Visible to the user, which a screenshot has to be. */
function screenshotDir(): string {
  return join(app.getPath('pictures'), BRAND.name)
}

/** `2026-08-12-163045` — sorts chronologically in a file listing. */
function stamp(now: Date): string {
  const pad = (value: number): string => String(value).padStart(2, '0')
  return [
    now.getFullYear(),
    pad(now.getMonth() + 1),
    pad(now.getDate()),
    '-',
    pad(now.getHours()),
    pad(now.getMinutes()),
    pad(now.getSeconds()),
  ].join('')
}

/** A filename from the page's own host, with everything a path cares about gone. */
export function screenshotName(url: string, now: Date): string {
  let host = ''
  try {
    host = new URL(url).host
  } catch {
    host = ''
  }
  const safe = host.replace(/[^a-zA-Z0-9.-]/g, '-').replace(/^[.-]+/, '').slice(0, 48)
  return `${safe || 'page'}-${stamp(now)}.png`
}

/* --------------------------------------------------- doors for the phone -- */

/**
 * A photograph of a page, taken by anything in this process rather than only by
 * the renderer's own button.
 *
 * The three exports below exist because a phone drives this machine's browser
 * through `remote/machine-browser-desktop.ts`, which is in the main process and
 * has no bridge to invoke on. Round-tripping through `ipcMain` from inside
 * `ipcMain` is not available and would be the wrong shape if it were, so the
 * handlers below now call these and the phone calls them directly: one body,
 * one screenshots folder, one filename rule, one recorder. The alternative was
 * a second capture path with its own idea of where Pictures is, which is how
 * one product ends up writing screenshots into two folders and telling somebody
 * the wrong one.
 *
 * `preview` is **bytes** here and a `data:` URL on {@link ScreenshotResult},
 * and that split is the reason this does not simply return the latter: the
 * renderer wants a string it can put in an `<img>`, the wire wants the PNG to
 * base64 exactly once inside its own frame. `toDataURL()` is that same PNG with
 * a prefix, so neither side is re-encoding the other's picture.
 */
export interface CapturedView {
  path: string
  width: number
  height: number
  /** Empty when the resize or the encode failed — never a reason to fail a capture. */
  preview: Buffer
}

/**
 * Capture one open view, write the full-resolution PNG, and answer both sizes.
 *
 * Throws when the page is not on screen, and that is a real precondition rather
 * than a transient: verified on Electron 41, `capturePage()` on a view whose
 * window is hidden fails with *"Current display surface not available for
 * capture"*, and `stayHidden` does not rescue it.
 */
export async function captureBrowserView(tabId: unknown): Promise<CapturedView> {
  const entry = entryFor(tabId)
  const image = await entry.wc.capturePage().catch(() => null)
  const size = image?.getSize()
  if (!image || !size || size.width === 0 || size.height === 0) {
    throw new Error('The page has to be on screen to capture it.')
  }

  const dir = screenshotDir()
  await mkdir(dir, { recursive: true })
  const path = join(dir, screenshotName(entry.wc.getURL(), new Date()))
  await writeFile(path, image.toPNG())

  // The file on disk is always the full-resolution shot. This is a second,
  // smaller encode purely so something has a picture to draw; failing to make
  // one must not fail the capture that already succeeded.
  let preview: Buffer
  try {
    const small = size.width > PREVIEW_WIDTH ? image.resize({ width: PREVIEW_WIDTH }) : image
    preview = small.toPNG()
  } catch {
    preview = Buffer.alloc(0)
  }

  return { path, width: size.width, height: size.height, preview }
}

/**
 * What the recorder has collected on one view, without touching it.
 *
 * Synchronous because the answer is in memory: the steps arrive from the guest
 * page as they happen and are already parsed. A caller that has to know whether
 * a window is recording for a *list* asks this once per row, which is why it
 * must not be a promise or a probe.
 */
export function browserViewRecording(tabId: unknown): RecordingState {
  return stateOf(entryFor(tabId))
}

/** Start or stop the recorder on one view. Starting records where the flow begins. */
export function setBrowserViewRecording(tabId: unknown, on: boolean): RecordingState {
  const entry = entryFor(tabId)
  if (on && !entry.recording) {
    entry.recording = true
    // A flow that does not say where it starts cannot be replayed.
    entry.steps = appendStep(entry.steps, navigateStep(entry.wc.getURL(), Date.now()))
  } else {
    entry.recording = on
  }
  tellGuestRecording(entry)
  return stateOf(entry)
}

const ZOOM_MIN = 0.25
const ZOOM_MAX = 3

export function clampZoom(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 1
  return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, value))
}

/* ----------------------------------------------------------------- chords -- */

/**
 * What a keystroke inside the page means to the browser chrome, if anything.
 *
 * The chords a person reaches for in any browser, decided here because the page
 * is the surface that usually has focus and the renderer cannot hear it. Pure
 * and exported for the same reason `terminalChord` in `TerminalView.tsx` is —
 * a routing rule is testable without a window, and this one decides who owns
 * ⌘F per focused surface: a terminal answers it itself and never lets it
 * bubble, the app's own DOM answers through the workspace's `onKeyDown`, and a
 * page answers through here. Nothing global is bound, so nothing is stolen.
 *
 * `alt` excludes, as it does in `terminalChord`: ⌥⌘F is somebody else's chord,
 * and on Windows AltGr arrives as control+alt and must keep typing `=` into
 * the site rather than zooming it.
 *
 * Escape is the one entry that is not a mod chord, and it is gated on
 * `finding`: while the find bar is up, Esc in the page closes it — the same
 * key the bar's own input answers — and the rest of the time Esc belongs to
 * the site.
 */
export type GuestChord =
  | 'find'
  | 'find-close'
  | 'find-next'
  | 'find-prev'
  | 'zoom-in'
  | 'zoom-out'
  | 'zoom-reset'
  | 'print'

export function guestChord(
  input: {
    type: string
    key: string
    meta?: boolean
    control?: boolean
    shift?: boolean
    alt?: boolean
  },
  finding: boolean,
): GuestChord | null {
  if (input.type !== 'keyDown') return null
  if (input.alt) return null
  const key = input.key.toLowerCase()
  const mod = Boolean(input.meta) || Boolean(input.control)
  if (!mod) {
    return key === 'escape' && finding && !input.shift ? 'find-close' : null
  }
  if (key === 'f' && !input.shift) return 'find'
  // ⌘G / ⌘⇧G step the find from inside the page, but only while a find is up —
  // the rest of the time the site keeps its own shortcut.
  if (key === 'g' && finding) return input.shift ? 'find-prev' : 'find-next'
  if (key === '=' || key === '+') return 'zoom-in'
  if (key === '-') return 'zoom-out'
  if (key === '0' && !input.shift) return 'zoom-reset'
  // ⌘P is Quick Open everywhere else in the app and stays that way — the menu
  // accelerator still fires when the renderer has focus. With the *page*
  // focused it prints the page, which is what fingers trained on any browser
  // mean by it.
  if (key === 'p' && !input.shift) return 'print'
  return null
}

/* --------------------------------------------------------------- register -- */

/**
 * Wire the browser workspace's per-view controls. Call once from
 * `registerIpc()`, after `registerBrowserSessionIpc`:
 *
 *     import { registerBrowserViewIpc } from './browser-view'
 *     registerBrowserViewIpc(ipcMain)
 *
 * Channels (all keyed by the tab id `browser:create` returned):
 * - `browser-view:claim`        (invoke, id)              → { ok, reason? }
 * - `browser-view:release`      (invoke, id)              → void
 * - `browser-view:zoom`         (invoke, id, factor)      → number
 * - `browser-view:find`         (invoke, id, query, opts) → void
 * - `browser-view:find-stop`    (invoke, id, keep)        → void
 * - `browser-view:print`        (invoke, id)              → void
 * - `browser-view:devtools`     (invoke, id)              → boolean (now open?)
 * - `browser-view:screenshot`   (invoke, id)              → {@link ScreenshotResult}
 * - `browser-view:frame`        (invoke, id)              → {@link PageFrame}
 * - `browser-view:screenshot-marked` (invoke, id, pngUrl) → {@link MarkedShot}
 * - `browser-view:reveal`       (invoke, path)            → void
 * - `browser-view:user-agent`   (invoke, id, ua | null)   → string
 * - `browser-view:record`       (invoke, id, {on, accent})→ {@link RecordingState}
 * - `browser-view:record-clear` (invoke, id)              → {@link RecordingState}
 *
 * Emits {@link PROGRESS_CHANNEL} (id, {@link LoadProgress}),
 * {@link RECORDING_CHANNEL} (id, {@link RecordingState}), {@link FIND_CHANNEL}
 * (id, match counts) and {@link KEY_CHANNEL} (id, {@link GuestChord}) — all on
 * the `browser:` prefix the preload subscribes to. The first two disagreed with
 * this file for the whole life of the feature; see the comment on the
 * constants, and `browser-view.channels.test.ts` for what now holds all four.
 */
export function registerBrowserViewIpc(ipcMain: IpcMain): void {
  watchCreations()

  ipcMain.handle('browser-view:claim', (event: IpcMainInvokeEvent, tabId: unknown) => {
    if (typeof tabId !== 'string' || tabId === '') return { ok: false, reason: 'no tab id' }
    if (views.has(tabId)) return { ok: true }

    const wc = resolveView ? resolveView(tabId) : claim()
    if (!wc || wc.isDestroyed()) {
      return { ok: false, reason: 'no unclaimed browser view — create the tab first' }
    }

    const entry: ViewEntry = {
      tabId,
      wc,
      host: event.sender,
      recording: false,
      finding: false,
      accent: '',
      steps: [],
      detach: [],
    }
    views.set(tabId, entry)
    attach(entry)
    return { ok: true }
  })

  ipcMain.handle('browser-view:release', (_event, tabId: unknown) => {
    if (typeof tabId === 'string') release(tabId)
  })

  ipcMain.handle('browser-view:zoom', (_event, tabId: unknown, factor: unknown) => {
    const entry = entryFor(tabId)
    // null reads without writing. Chromium remembers zoom per origin inside the
    // partition, so a tab that opens a site the user zoomed last week opens
    // zoomed — and a UI that assumed 100% would both show the wrong number and
    // reset their preference the first time they pressed a button.
    if (factor !== null && factor !== undefined) {
      const chosen = clampZoom(factor)
      entry.wc.setZoomFactor(chosen)
      /*
       * A zoom that came from a person, which is the one kind `browser-fit.ts`
       * must never argue with.
       *
       * It fits a page out when the layout is wider than the pane, and the
       * toolbar chip that appears is *how somebody undoes that* — so a reset to
       * 100% that was silently re-fitted a moment later would be a control that
       * visibly does nothing. Telling the fitter here is what makes the chip
       * mean what it says: their number stands until the tab navigates.
       */
      noteManualZoom(String(tabId), chosen)
    }
    return entry.wc.getZoomFactor()
  })

  ipcMain.handle(
    'browser-view:find',
    (_event, tabId: unknown, query: unknown, options: unknown) => {
      const entry = entryFor(tabId)
      const text = typeof query === 'string' ? query : ''
      if (text === '') {
        // An emptied field is the end of the session, not a search for ''.
        if (entry.finding) {
          entry.finding = false
          entry.wc.stopFindInPage('clearSelection')
        }
        return
      }
      const opts = (typeof options === 'object' && options !== null ? options : {}) as {
        forward?: unknown
        first?: unknown
      }
      entry.finding = true
      // Electron's `findNext` is named backwards: true begins a NEW session.
      // The wire says `first`, which is the fact the renderer actually knows —
      // "the query changed" — and the translation happens in exactly one place.
      entry.wc.findInPage(text, {
        forward: opts.forward !== false,
        findNext: opts.first === true,
      })
    },
  )

  ipcMain.handle('browser-view:find-stop', (_event, tabId: unknown, keep: unknown) => {
    const entry = entryFor(tabId)
    entry.finding = false
    entry.wc.stopFindInPage(keep === 'keep' ? 'keepSelection' : 'clearSelection')
    // The bar had the keyboard; closing it gives the keys back to the page —
    // the same hand-back the terminal's `closeFind` does with `term.focus()`.
    entry.wc.focus()
  })

  ipcMain.handle('browser-view:print', async (_event, tabId: unknown) => {
    const entry = entryFor(tabId)
    // The system dialog, not silent printing: choosing a printer is the user's
    // decision, and the callback is the only way Electron reports that no
    // printer exists — which deserves a sentence, not a resolved promise.
    await new Promise<void>((resolvePrint, reject) => {
      entry.wc.print({}, (ok: boolean, reason: string) => {
        if (ok || reason === 'cancelled' || reason === 'Print job canceled') resolvePrint()
        else reject(new Error(`The page could not be printed: ${reason || 'no printer answered'}.`))
      })
    })
  })

  ipcMain.handle('browser-view:devtools', (_event, tabId: unknown) => {
    const entry = entryFor(tabId)
    if (entry.wc.isDevToolsOpened()) {
      entry.wc.closeDevTools()
      return false
    }
    // Detached: the guest view is a native layer positioned by the renderer, and
    // docked devtools would be laid out inside that rectangle and fight it.
    entry.wc.openDevTools({ mode: 'detach' })
    return true
  })

  ipcMain.handle('browser-view:screenshot', async (_event, tabId: unknown) => {
    const shot = await captureBrowserView(tabId)
    // The renderer has no filesystem to read the file back with, so the picture
    // travels as a `data:` URL — the same PNG {@link CapturedView.preview}
    // carries, with the prefix an `<img>` needs. Empty stays empty: the popup
    // then shows the path and the send box without a picture, which is what
    // that screen already was before it had one.
    return {
      path: shot.path,
      width: shot.width,
      height: shot.height,
      preview:
        shot.preview.length === 0 ? '' : `data:image/png;base64,${shot.preview.toString('base64')}`,
    } satisfies ScreenshotResult
  })

  /*
   * The frame draw mode marks up.
   *
   * Deliberately not `browser-view:screenshot`. That one writes a file, and
   * entering draw mode is not a decision to keep anything — most of the time the
   * user is about to press Escape. So this captures and returns, and the only
   * thing that ever reaches Pictures is the composite the user actually sent.
   *
   * Same precondition as a screenshot and for the same verified reason: on
   * Electron 41 `capturePage` on a view whose window is hidden fails with
   * "Current display surface not available for capture", and `stayHidden` does
   * not rescue it. So the renderer has to take this frame *before* it parks the
   * page to put its canvas over the top, not after.
   */
  ipcMain.handle('browser-view:frame', async (_event, tabId: unknown) => {
    const entry = entryFor(tabId)
    const image = await entry.wc.capturePage().catch(() => null)
    const size = image?.getSize()
    if (!image || !size || size.width === 0 || size.height === 0) {
      throw new Error('The page has to be on screen to capture it.')
    }
    const scaled = size.width > FRAME_WIDTH ? image.resize({ width: FRAME_WIDTH }) : image
    const shrunk = scaled.getSize()
    return {
      image: scaled.toDataURL(),
      width: shrunk.width,
      height: shrunk.height,
      // The main process's idea of the URL, never the page's. A page can lie
      // about its own address and this string goes into an agent's prompt.
      url: entry.wc.getURL(),
    } satisfies PageFrame
  })

  /*
   * The marked frame, saved.
   *
   * The composite is made in the renderer because a canvas is the only thing in
   * this app that can draw a line, so the bytes come back as a string and are
   * checked rather than trusted — see `marked-image.ts`, which is where every
   * one of those rules lives and is tested.
   *
   * Everything downstream of here is the screenshot path, unchanged: the same
   * folder, the same filename rule with `-marked` on it, the same
   * {@link ScreenshotResult} the popup already knows how to show, and therefore
   * the same Reveal, the same session picker and the same one line typed into an
   * agent's prompt. Draw mode adds a picture, not a second way to send one.
   */
  ipcMain.handle('browser-view:screenshot-marked', async (_event, tabId: unknown, png: unknown) => {
    const entry = entryFor(tabId)
    const decoded = decodePngDataUrl(png)
    if (!decoded) throw new Error('That drawing could not be read as an image, so nothing was saved.')

    const dir = screenshotDir()
    await mkdir(dir, { recursive: true })
    const url = entry.wc.getURL()
    const path = join(dir, markedName(screenshotName(url, new Date())))
    await writeFile(path, decoded.bytes)

    // No preview: the renderer composed these pixels and still has them on the
    // canvas it drew them on. Sending three megabytes of base64 back to the
    // process it just came from would be the same picture crossing the bridge
    // twice for no one's benefit.
    return { path, width: decoded.width, height: decoded.height, url } satisfies MarkedShot
  })

  ipcMain.handle('browser-view:reveal', (_event, path: unknown) => {
    if (typeof path !== 'string') return
    // Only our own screenshots. This channel takes a path from the renderer, and
    // a renderer bug that passed something else through should not turn into a
    // "reveal any file on disk" primitive.
    const full = resolve(path)
    if (!full.startsWith(screenshotDir() + sep)) return
    shell.showItemInFolder(full)
  })

  ipcMain.handle('browser-view:user-agent', (_event, tabId: unknown, ua: unknown) => {
    const entry = entryFor(tabId)
    // Empty means "back to Chromium's own", which is what the app was launched
    // with — not the empty string, which would send no User-Agent at all.
    // `cleanUserAgent`, not the raw fallback: turning the phone size off used
    // to put Electron's own token back into the string, and with it back in
    // place Google routes every sign-in down its restricted path. See
    // `browser-user-agent.ts` for the measurement.
    const next =
      typeof ua === 'string' && ua.trim() !== ''
        ? ua.trim()
        : cleanUserAgent(app.userAgentFallback)
    entry.wc.setUserAgent(next)
    return next
  })

  ipcMain.handle('browser-view:record', (_event, tabId: unknown, options: unknown) => {
    const entry = entryFor(tabId)
    const opts = (typeof options === 'object' && options !== null ? options : {}) as Record<
      string,
      unknown
    >
    const on = opts.on === true
    // Kept only when it is actually a colour, so a stop with no accent does not
    // wipe the one every later document is drawn with.
    const accent = safeAccent(opts.accent)
    if (accent !== '') entry.accent = accent

    if (on && !entry.recording) {
      entry.recording = true
      // A flow that does not say where it starts cannot be replayed.
      entry.steps = appendStep(entry.steps, navigateStep(entry.wc.getURL(), Date.now()))
    } else {
      entry.recording = on
    }
    tellGuestRecording(entry)
    return stateOf(entry)
  })

  ipcMain.handle('browser-view:record-clear', (_event, tabId: unknown) => {
    const entry = entryFor(tabId)
    entry.steps = []
    return stateOf(entry)
  })

  /* ---- from the guest page. Hostile until proven otherwise. */

  ipcMain.on(GUEST_STEP_CHANNEL, (event: IpcMainEvent, payload: unknown) => {
    for (const entry of views.values()) {
      if (entry.wc.isDestroyed() || entry.wc.id !== event.sender.id) continue
      if (!entry.recording) return
      if (!isFromMainFrame(event, entry.wc)) return
      // The URL is the main process's, never the payload's: a page that could
      // forge these must not also get to name the site whose flow this is.
      record(entry, parseGuestStep(payload, entry.wc.getURL(), Date.now()))
      return
    }
  })
}

/** Called from `before-quit`, and whenever the app tears the browser down. */
export function releaseAllBrowserViews(): void {
  for (const tabId of [...views.keys()]) release(tabId)
}
