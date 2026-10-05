import {
  BrowserWindow,
  Menu,
  nativeTheme,
  screen,
  type IpcMain,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
  type MenuItemConstructorOptions,
} from 'electron'
import { BRAND } from '../shared/brand'
import {
  clampExpanded,
  islandCentre,
  islandWindow,
  placeIsland,
  type IslandGeometry,
  type IslandNotch,
  type Rect,
} from '../shared/hoot-island'
import {
  CLOSE_DELAY_MS,
  MOMENT_MS,
  MomentTracker,
  OPEN_DELAY_MS,
  pillLabel,
  readSnapshot,
  type HootMoment,
} from '../shared/hoot-panel-model'
import { notchOf, readScreens, type ScreenReport } from './hoot-notch'
import type { CopilotChatMessage } from './remote/protocol'

/**
 * Hoot's island: one black shape at the top centre of the screen, inside the
 * menu bar, that grows into a panel when the pointer rests on it.
 *
 * Asad, 2026-10-03: *"can we give a notch bar to hoot to live where we hover
 * and it comes down a little to talk, kind of dropdown"*. Then, 2026-10-04,
 * having seen it as a pill among the status items with a glass panel under it:
 * *"I want it to be like in center of the menu… not like next to the other
 * ones… should not be a separate drop down, should be part of it… dark black…
 * attached, one single piece"* — and, for a MacBook, *"should not be hiding
 * behind the notch… it will be in left and right of notch… when we hover there
 * then it comes outside."* His reference was a notch app grown out of a
 * MacBook's notch: a wide, short black panel whose top corners curve out into
 * the menu bar.
 *
 * ## One island, on the main display
 *
 * Exactly one, however many displays there are — on the main display, the one
 * macOS puts the menu bar on first (`screen.getPrimaryDisplay()`), and moved
 * there again when the displays change. With a menu bar on every display an
 * island on each was possible, but one is the only way two of them can never
 * say different things: there is one controller, one snapshot, one window.
 *
 * ## One window that never moves, one shape inside it
 *
 * The island is a single frameless, transparent window whose top edge is the
 * top edge of the screen, centred on the display's middle — or on the notch
 * where there is one — and as big as the grown panel and its shadow. It is
 * placed once, and again only when a display changes; never while anything
 * animates. His second recording caught the first version resizing the window
 * for each state, and for one frame the pill was drawn 315 points left of
 * centre, because the page and the window server cannot be made to change on
 * the same frame. Now the page (`renderer/hoot-panel/`) draws the shape — the
 * small pill at rest, the panel when grown — and morphs it inside the window
 * that stays put; the shape itself is `shared/hoot-island.ts`.
 *
 * The window is an NSPanel with the non-activating mask (`type: 'panel'`), one
 * level above the menu bar and below other apps' open menus, on every Space and
 * over full-screen apps, so hovering it never brings this app forward. It lets
 * every click through (`setIgnoreMouseEvents`) except while the pointer is on
 * the shape itself, which the page works out from where the shape is drawn.
 *
 * ## The catcher, because macOS stops telling a window about a pointer it ignores
 *
 * A window that lets clicks through hears about the pointer only while this app
 * is the one in front — `forward` in Electron is `acceptsMouseMovedEvents`, and
 * macOS sends those to the active app. The island is hovered while somebody is
 * working in another app, which is exactly when that is not true. So a second,
 * invisible window sits over the resting pill and nothing else: the pointer
 * arriving on it is what wakes the island (`hoot-panel:catch`). It is sized to
 * the pill, moves only when the pill's words change width, and draws nothing,
 * so moving it can never show.
 *
 * ## When it grows
 *
 * The pointer resting on the pill for a short intent delay, or a click on it —
 * which also hands it the keyboard, pinned open, the way a click means "I want
 * to type". It settles back a moment after the pointer has left the shape, on a
 * click elsewhere, or on Escape — never while its box has text or the keyboard,
 * or while he is dragging one of its corners. A session that finishes or starts
 * waiting widens the pill for a few seconds to say so ("Session 2 needs you"),
 * then it settles back to its counts.
 *
 * ## His size
 *
 * The grown panel is his to resize by its bottom corners. The page says the
 * size he let go at (`hoot-panel:resize`); it is kept in two settings
 * ({@link SIZE_KEYS}) and the panel opens at it from then on. The window was
 * made for the largest size a drag can reach, so a drag never moves it either.
 *
 * Showing or hiding the island is a setting — Settings → Hoot — and nothing on
 * the island itself; its right-click menu is the three things a background app
 * needs: open the app, its settings, quit.
 *
 * ## Talking to Hoot is the phone's machinery, aimed at the Hoot that runs
 *
 * Nothing here starts a second Hoot. A message goes into the Hoot pinned in the
 * sidebar through `typeAndSubmit` — the two-write submit the phone's path
 * learned the hard way (`remote/copilot-say.ts`) — and the replies are read off
 * that Hoot's own transcript with `watchRunChat`, the phone's reader, pointed
 * at the desk Hoot. If Hoot is not running the island says so in one line and
 * offers to start *it* (`ensureCopilot`).
 *
 * ## No polling
 *
 * Every change arrives as an event the app already sends: `send()` in
 * `index.ts` hands each push to {@link HootMenuBar.forward}, the transcript is
 * watched, the notch is read again only when a display changes. The only timers
 * are the intent delays and the moment's few seconds — none of them asks
 * anything.
 */

/* ----------------------------------------------------------------- settings -- */

/** Under `copilot.*` like every setting of Hoot's (`BRAND.assistant` says why). */
export const MENUBAR_KEY = 'copilot.menuBar'

/** Absent is on: Hoot is at the top of the screen unless somebody turned it off. */
export function readMenuBarEnabled(read: (key: string) => unknown): boolean {
  return read(MENUBAR_KEY) !== false
}

/** The grown panel's size, as he last left it. Two numbers, because a stored setting is one value. */
export const SIZE_KEYS = { width: 'copilot.islandWidth', height: 'copilot.islandHeight' } as const

/** The remembered size, or null when there is none (or it is not a size). */
export function readIslandSize(read: (key: string) => unknown): { width: number; height: number } | null {
  const width = read(SIZE_KEYS.width)
  const height = read(SIZE_KEYS.height)
  if (typeof width !== 'number' || typeof height !== 'number') return null
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return null
  return { width, height }
}

/* ----------------------------------------------------------------- snapshot -- */

export interface HootMenuBarSnapshot {
  assistant: string
  /** The app's theme, which the island wears: light or dark, like every other surface of the app. */
  appearance: 'light' | 'dark'
  hoot: { status: 'running' | 'starting' | 'stopped'; problem: string | null }
  sessions: Array<{ id: string; label: string; status: string }>
  messages: CopilotChatMessage[]
  /** What the resting pill says: the moment while it lasts, else the counts. */
  label: { text: string; attention: boolean }
  /** Grown into the panel, or resting as the pill. */
  expanded: boolean
  /** The display it is drawn on: the menu bar's height, its width, and its notch. */
  geometry: { barHeight: number; displayWidth: number; notch: IslandNotch | null }
  /** The size he last dragged the grown panel to, held to what this display allows; null for the default. */
  size: { width: number; height: number } | null
}

/** How many messages the island keeps. It is a glance, not the conversation. */
export const PANEL_MESSAGES = 12

/** Merge a transcript update into the kept messages: replace by id, append the rest. */
export function mergeMessages(
  kept: readonly CopilotChatMessage[],
  update: { messages: readonly CopilotChatMessage[]; reset: boolean },
): CopilotChatMessage[] {
  const base = update.reset ? [] : [...kept]
  for (const message of update.messages) {
    const at = base.findIndex((m) => m.id === message.id)
    if (at >= 0) base[at] = message
    else base.push(message)
  }
  return base.slice(-PANEL_MESSAGES)
}

/* --------------------------------------------------------------- controller -- */

/** The island's window, as much of `BrowserWindow` as this module touches. */
export interface IslandHandle {
  readonly webContents: { readonly id: number; send(channel: string, ...args: unknown[]): void; isDestroyed(): boolean }
  isDestroyed(): boolean
  isVisible(): boolean
  setBounds(bounds: Rect): void
  getBounds(): Rect
  showInactive(): void
  /** Whether it is the key window now. Absent: assume not. */
  isFocused?(): boolean
  focus(): void
  /** Give the keyboard back to whatever had it. */
  blur(): void
  destroy(): void
  /** True: clicks go through to what is under the window (the pointer is off the shape). */
  setIgnoreMouseEvents(ignore: boolean): void
  popUpMenu(items: MenuItemConstructorOptions[]): void
  on(event: 'blur' | 'focus' | 'closed', listener: () => void): void
}

/** The invisible window over the resting pill. */
export interface CatcherHandle {
  readonly webContents: { readonly id: number }
  isDestroyed(): boolean
  setBounds(bounds: Rect): void
  showInactive(): void
  /** True: it lets the pointer through (the island is awake and listening itself). */
  setIgnoreMouseEvents(ignore: boolean): void
  destroy(): void
}

/** Where the island is drawn. */
export interface IslandPlace {
  display: Rect
  barHeight: number
  notch: IslandNotch | null
}

export interface HootMenuBarDeps {
  makeIsland(): IslandHandle
  makeCatcher(): CatcherHandle
  /** The display the island lives on — the one with the menu bar — and its notch. */
  place(): IslandPlace
  read(key: string): unknown
  write(patch: Record<string, unknown>): void
  hoot(): HootMenuBarSnapshot['hoot'] & { sessionId: string | null; cwd: string; agentSessionId: string | null }
  /** `ensureCopilot`. Starts *the* Hoot, never a second one. */
  startHoot(): Promise<{ problem: string | null }>
  /** `typeAndSubmit` into a session. */
  say(sessionId: string, text: string): void
  /** `watchRunChat`, aimed at the desk Hoot's transcript. Returns the unsubscribe. */
  watchChat(
    cwd: string,
    agentSessionId: string | null,
    onUpdate: (update: { messages: CopilotChatMessage[]; reset: boolean }) => void,
  ): () => void
  /** Every session on this computer; Hoot's own is left out here, by its id. */
  sessions(): Array<{ id: string; title: string; status: string }>
  /**
   * Whether this session is Hoot's own — `isCopilotSession`, asked fresh each
   * time rather than read off a copy of Hoot's state. A copy taken while Hoot
   * was still starting has no session id yet, and a session counted from it
   * showed up as a chip that opened "another Hoot" and as one more in the
   * counts (Asad, 2026-10-04, on his second display).
   */
  isHoot?(sessionId: string): boolean
  /** Bring the main window forward with this session in front. */
  showSession(id: string): void
  /** Bring the main window forward, on a page when one is named. */
  openApp(page?: 'hoot-settings'): void
  /**
   * End the app and every session in it — the background menu's own quit
   * (`quitAll` in `resident.ts`). While the island is up it is the app's one
   * presence at the top of the screen, so its right-click menu has to be a way
   * out too. Absent: no quit in the menu.
   */
  quit?(): void
  /** The island appeared or went, so whoever keeps the app visible can count icons again. */
  onShownChanged?(): void
  /** The app's theme right now (the preference, resolved against the system's). */
  appearance(): 'light' | 'dark'
  /** False where there is no menu bar to live in: the island is a Mac thing. */
  supported?: boolean
  /** Timers. Injected so a test can run them by hand. */
  schedule(run: () => void, ms: number): { cancel(): void }
  now?(): number
  log?(message: string, detail?: Record<string, unknown>): void
}

export interface HootMenuBar {
  /** Read the setting and make the screen match: the island there, or gone. */
  apply(): void
  /**
   * Grow the island as a click on it would — pinned, with the keyboard. The way
   * in from the palette and from a tool, for anybody who cannot hover: a
   * keyboard user, or an assistant.
   */
  openPanel(): { ok: boolean; message: string }
  /** Copy one of `send()`'s pushes in, and notice the ones that change what it shows. */
  forward(channel: string, args: readonly unknown[]): void
  setLabels(labels: Readonly<Record<string, string>>): void
  /** A display was added, removed or changed — or its notch was read: place it again. */
  displaysChanged(): void
  /** The app's theme changed: the island changes with it. */
  themeChanged(): void
  snapshot(): HootMenuBarSnapshot
  say(text: string): Promise<{ ok: boolean; message: string }>
  startHoot(): Promise<{ ok: boolean; message: string }>
  showSession(id: string): { ok: boolean }
  /** The page: the pointer is over the shape, or not. */
  pointer(contentsId: number, inside: boolean): void
  /** The page: the box has text or the keyboard, so it must stay. */
  held(contentsId: number, held: boolean): void
  /** The page: a press — on the pill, which grows it pinned, or in the box. Either asks for the keyboard. */
  focus(contentsId: number): void
  /** Escape, from the page. */
  close(contentsId: number): void
  /** The page: the size of the resting pill, shoulders included — where the catcher goes. */
  size(contentsId: number, box: { width: number; height: number }): void
  /** The page: he let go of a corner, and the grown panel is this size now. */
  resize(contentsId: number, size: { width: number; height: number }): void
  /** The catcher: the pointer arrived on the resting pill, left it, or pressed it. */
  catch(contentsId: number, kind: 'enter' | 'leave' | 'press'): void
  /** A right-click on the island. */
  menu(contentsId: number): void
  config(): { enabled: boolean }
  configure(patch: { enabled?: boolean }): { enabled: boolean }
  /** Whether the island is up, grown, what its pill says, and where its window is. */
  isShowing(): { island: boolean; expanded: boolean; label: string; bounds: Rect | null }
  dispose(): void
}

const PASSED_THROUGH = new Set(['prefs:changed', 'settings:changed'])
const CHANGES_SESSIONS = new Set([
  'session:status',
  'session:renamed',
  'session:exit',
  'session:removed',
  'session:created',
])
/**
 * The pushes after which Hoot's own state is read again. A status change is one:
 * Hoot finishing its start changes no session's existence, only statuses — and
 * a state read while it was starting would otherwise say "starting" until
 * something else happened.
 */
const CHANGES_HOOT = new Set(['session:created', 'session:exit', 'session:removed', 'session:switched', 'session:status'])

/** A burst of status pushes gathered into one update. */
const SETTLE_MS = 60

/** The catcher's size before the page has said how big the pill is: about a short pill. */
const FIRST_PILL = { width: 96, height: 24 }

/**
 * A blur this soon after a click asked for the keyboard is that request being
 * taken away — the app coming forward and its own window taking the keyboard —
 * not a click somewhere else. The island stays open, as if hovered, and settles
 * when the pointer leaves, instead of shutting the instant it opened.
 */
export const FOCUS_GRACE_MS = 500

export function createHootMenuBar(deps: HootMenuBarDeps): HootMenuBar {
  let island: IslandHandle | null = null
  let catcher: CatcherHandle | null = null
  let shown = false
  let placed: Rect | null = null
  let pill: { width: number; height: number } = FIRST_PILL
  let labels: Record<string, string> = {}
  let messages: CopilotChatMessage[] = []
  let hootCache: ReturnType<HootMenuBarDeps['hoot']> | null = null
  let watching: { sessionId: string; stop: () => void } | null = null
  let tracker = new MomentTracker()
  let moment: HootMoment | null = null

  // Grown or resting, and why.
  let expanded = false
  let pinned = false
  /** The pointer is on the shape (the page's hit test, or the catcher). */
  let over = false
  let holding = false
  let keyed = false
  /**
   * Settled on purpose — Escape, a click elsewhere, a session opened — with the
   * pointer possibly still on the pill. It does not grow again until the
   * pointer has left and come back.
   */
  let quiet = false
  /** When the keyboard was last asked for, for {@link FOCUS_GRACE_MS}. */
  let focusAskedAt = Number.NEGATIVE_INFINITY

  const timers = {
    open: null as { cancel(): void } | null,
    close: null as { cancel(): void } | null,
    moment: null as { cancel(): void } | null,
    settle: null as { cancel(): void } | null,
  }
  const cancel = (name: keyof typeof timers): void => {
    timers[name]?.cancel()
    timers[name] = null
  }
  const now = (): number => (deps.now ? deps.now() : Date.now())
  const live = (): IslandHandle | null => (island !== null && !island.isDestroyed() ? island : null)
  const liveCatcher = (): CatcherHandle | null => (catcher !== null && !catcher.isDestroyed() ? catcher : null)

  const hoot = (): ReturnType<HootMenuBarDeps['hoot']> => {
    if (hootCache === null) hootCache = deps.hoot()
    return hootCache
  }

  /** Every session but Hoot's own: never a chip, never in the counts, never offered as "another Hoot". */
  function theirs(): Array<{ id: string; title: string; status: string }> {
    const own = hoot().sessionId
    return deps.sessions().filter((session) => session.id !== own && deps.isHoot?.(session.id) !== true)
  }

  function sessionsView(): HootMenuBarSnapshot['sessions'] {
    return theirs().map((session) => ({
      id: session.id,
      label: labels[session.id] ?? session.title,
      status: session.status,
    }))
  }

  function label(): { text: string; attention: boolean } {
    return pillLabel(moment, readSnapshot({ sessions: sessionsView() }).sessions, BRAND.assistant)
  }

  function geometryOf(where: IslandPlace): IslandGeometry {
    return { barHeight: where.barHeight, displayWidth: where.display.width, notch: where.notch }
  }

  function snapshot(): HootMenuBarSnapshot {
    const state = hoot()
    const where = deps.place()
    const kept = readIslandSize(deps.read)
    return {
      assistant: BRAND.assistant,
      appearance: deps.appearance(),
      hoot: { status: state.status, problem: state.problem },
      sessions: sessionsView(),
      messages,
      label: label(),
      expanded,
      geometry: geometryOf(where),
      size: kept === null ? null : clampExpanded(geometryOf(where), kept),
    }
  }

  function push(): void {
    const target = live()
    if (target === null || target.webContents.isDestroyed()) return
    target.webContents.send('hoot-panel:snapshot', snapshot())
  }

  /* -- the window, which does not move while anything animates -- */

  function placeWindow(reason: string): void {
    const target = live()
    if (target === null) return
    const where = deps.place()
    const bounds = placeIsland(where.display, islandCentre(where.display, where.notch), islandWindow(geometryOf(where)))
    const same =
      placed !== null &&
      placed.x === bounds.x &&
      placed.y === bounds.y &&
      placed.width === bounds.width &&
      placed.height === bounds.height
    if (!same) {
      target.setBounds(bounds)
      placed = bounds
      // Every placing is written down, with why. Nothing outside can read the
      // window back, and "the island's window never moved while it grew" is a
      // claim this log is what proves.
      deps.log?.('island: placed', { reason, bounds: target.getBounds(), wanted: bounds, notch: where.notch })
    }
    if (!shown) {
      shown = true
      target.setIgnoreMouseEvents(true)
      target.showInactive()
    }
    placeCatcher()
  }

  function placeCatcher(): void {
    const target = liveCatcher()
    if (target === null) return
    const where = deps.place()
    target.setBounds(placeIsland(where.display, islandCentre(where.display, where.notch), pill))
    target.showInactive()
  }

  /** At rest: clicks go through the island, and the catcher waits on the pill. */
  function listenAtRest(): void {
    live()?.setIgnoreMouseEvents(true)
    liveCatcher()?.setIgnoreMouseEvents(false)
  }

  /** The pointer is on the shape: the island takes it, and the catcher stands aside. */
  function listenOnShape(): void {
    live()?.setIgnoreMouseEvents(false)
    liveCatcher()?.setIgnoreMouseEvents(true)
  }

  /* -- growing and settling -- */

  function follow(): void {
    const state = hoot()
    const wanted = expanded && state.status === 'running' && state.sessionId !== null ? state.sessionId : null
    if (watching !== null && watching.sessionId === wanted) return
    watching?.stop()
    watching = null
    if (wanted === null) return
    messages = []
    try {
      const stop = deps.watchChat(state.cwd, state.agentSessionId, (update) => {
        messages = mergeMessages(messages, update)
        push()
      })
      watching = { sessionId: wanted, stop }
    } catch (error) {
      deps.log?.('island: could not follow Hoot’s transcript', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  function expand(withKeyboard: boolean): void {
    const target = live()
    if (target === null) return
    cancel('open')
    cancel('close')
    quiet = false
    listenOnShape()
    if (!expanded) {
      expanded = true
      hootCache = null
      follow()
      push()
    }
    if (withKeyboard) {
      focusAskedAt = now()
      // A press on the island itself has already made it the key window;
      // asking again brings the whole app forward for nothing.
      if (target.isFocused?.() !== true) target.focus()
    }
  }

  /** Settle. `onPurpose`: a close somebody asked for, so it waits for the pointer to leave before growing again. */
  function collapse(onPurpose: boolean): void {
    cancel('open')
    cancel('close')
    const was = expanded
    expanded = false
    pinned = false
    holding = false
    if (onPurpose && over) quiet = true
    over = false
    listenAtRest()
    if (keyed) live()?.blur()
    follow()
    if (was) push()
  }

  /** Settle a beat after the pointer has left the shape — unless something holds it open. */
  function closeSoon(): void {
    cancel('close')
    if (!expanded) return
    timers.close = deps.schedule(() => {
      timers.close = null
      if (!over && !holding && !pinned) collapse(false)
    }, CLOSE_DELAY_MS)
  }

  /** The pointer arrived on the resting pill: grow after a short intent delay, unless it is just passing. */
  function arrive(): void {
    over = true
    cancel('close')
    listenOnShape()
    if (expanded || quiet || timers.open !== null) return
    timers.open = deps.schedule(() => {
      timers.open = null
      if (over && !quiet) expand(false)
    }, OPEN_DELAY_MS)
  }

  function depart(): void {
    over = false
    quiet = false
    cancel('open')
    if (expanded) {
      // Off the shape but still inside the window — the shadow's margin. With
      // the keyboard, this app is in front and the page keeps hearing the
      // pointer, so the margin lets clicks through at once; without it, the
      // margin keeps listening until the island settles, so coming straight
      // back onto the panel is still seen.
      if (keyed) live()?.setIgnoreMouseEvents(true)
      closeSoon()
      return
    }
    listenAtRest()
  }

  function noticeSessions(): void {
    const found = tracker.next(readSnapshot({ sessions: sessionsView() }).sessions, now())
    if (found === null) return
    moment = found
    cancel('moment')
    timers.moment = deps.schedule(() => {
      timers.moment = null
      moment = null
      push()
    }, MOMENT_MS)
  }

  /** Open the app, its settings (where the island is shown or hidden), quit. Nothing else. */
  function contextMenu(): MenuItemConstructorOptions[] {
    const items: MenuItemConstructorOptions[] = [
      { label: `Open ${BRAND.name}`, click: () => deps.openApp() },
      { label: 'Settings…', click: () => deps.openApp('hoot-settings') },
    ]
    const quit = deps.quit
    if (quit) items.push({ type: 'separator' }, { label: 'Quit and Stop All Sessions', click: () => quit() })
    return items
  }

  function addIsland(): void {
    const made = deps.makeIsland()
    island = made
    shown = false
    placed = null
    pill = FIRST_PILL
    expanded = false
    keyed = false
    over = false
    quiet = false
    made.on('focus', () => {
      keyed = true
    })
    // A click anywhere else, once it has the keyboard, is a click outside.
    made.on('blur', () => {
      keyed = false
      if (!expanded || holding) return
      if (now() - focusAskedAt < FOCUS_GRACE_MS) {
        // The keyboard it was just given went straight to another window: stay
        // open like a hover, unpinned, and settle once the pointer has gone.
        pinned = false
        if (!over) closeSoon()
        return
      }
      collapse(true)
    })
    made.on('closed', () => {
      if (island === made) {
        island = null
        expanded = false
        deps.onShownChanged?.()
      }
    })
    catcher = deps.makeCatcher()
    tracker = new MomentTracker()
    tracker.next(readSnapshot({ sessions: sessionsView() }).sessions, now())
    placeWindow('shown')
    listenAtRest()
    deps.onShownChanged?.()
  }

  function removeIsland(): void {
    collapse(false)
    for (const name of Object.keys(timers) as Array<keyof typeof timers>) cancel(name)
    watching?.stop()
    watching = null
    const had = island !== null
    const target = live()
    const gate = liveCatcher()
    island = null
    catcher = null
    target?.destroy()
    gate?.destroy()
    moment = null
    if (had) deps.onShownChanged?.()
  }

  function apply(): void {
    const enabled = deps.supported !== false && readMenuBarEnabled(deps.read)
    if (!enabled) {
      if (island !== null) removeIsland()
      return
    }
    if (island === null) addIsland()
  }

  function configure(patch: { enabled?: boolean }): { enabled: boolean } {
    if (typeof patch.enabled === 'boolean') deps.write({ [MENUBAR_KEY]: patch.enabled })
    apply()
    return { enabled: readMenuBarEnabled(deps.read) }
  }

  function forward(channel: string, args: readonly unknown[]): void {
    if (island === null) return
    if (PASSED_THROUGH.has(channel)) {
      const target = live()
      if (target !== null && !target.webContents.isDestroyed()) target.webContents.send(channel, ...args)
      // A preference may be the theme: the island wears it, so it hears it at once.
      push()
      return
    }
    if (CHANGES_HOOT.has(channel)) {
      hootCache = null
      follow()
    }
    if (CHANGES_SESSIONS.has(channel) || CHANGES_HOOT.has(channel)) {
      cancel('settle')
      timers.settle = deps.schedule(() => {
        timers.settle = null
        noticeSessions()
        push()
      }, SETTLE_MS)
    }
  }

  function ours(contentsId: number): boolean {
    const target = live()
    return target !== null && target.webContents.id === contentsId
  }

  function theCatcher(contentsId: number): boolean {
    const target = liveCatcher()
    return target !== null && target.webContents.id === contentsId
  }

  return {
    apply,
    openPanel: () => {
      if (live() === null) {
        return { ok: false, message: `${BRAND.assistant} is not at the top of the screen; turn it on in Settings.` }
      }
      pinned = true
      expand(true)
      return { ok: true, message: '' }
    },
    forward,
    setLabels: (next) => {
      const clean: Record<string, string> = {}
      for (const [id, text] of Object.entries(next)) {
        if (typeof text === 'string' && text !== '' && text.length <= 200) clean[id] = text
      }
      if (JSON.stringify(clean) === JSON.stringify(labels)) return
      labels = clean
      push()
    },
    displaysChanged: () => {
      placeWindow('display changed')
      push()
    },
    themeChanged: () => push(),
    snapshot,
    say: async (text) => {
      const message = typeof text === 'string' ? text.trim() : ''
      if (message === '') return { ok: false, message: 'Nothing to send.' }
      hootCache = null
      const state = hoot()
      if (state.status !== 'running' || state.sessionId === null) {
        return { ok: false, message: `${BRAND.assistant} isn’t running.` }
      }
      try {
        deps.say(state.sessionId, message.slice(0, 4000))
        return { ok: true, message: '' }
      } catch {
        return { ok: false, message: `${BRAND.assistant} did not take that message.` }
      }
    },
    startHoot: async () => {
      try {
        const result = await deps.startHoot()
        hootCache = null
        follow()
        push()
        return result.problem === null ? { ok: true, message: '' } : { ok: false, message: result.problem }
      } catch (error) {
        return { ok: false, message: error instanceof Error ? error.message : `${BRAND.assistant} could not start.` }
      }
    },
    showSession: (id) => {
      if (!theirs().some((session) => session.id === id)) return { ok: false }
      collapse(true)
      deps.showSession(id)
      return { ok: true }
    },
    pointer: (contentsId, inside) => {
      if (!ours(contentsId)) return
      if (inside) arrive()
      else depart()
    },
    held: (contentsId, value) => {
      if (!ours(contentsId)) return
      holding = value
      if (!value) closeSoon()
    },
    focus: (contentsId) => {
      if (!ours(contentsId)) return
      if (!expanded) pinned = true
      over = true
      expand(true)
    },
    close: (contentsId) => {
      if (ours(contentsId)) collapse(true)
    },
    size: (contentsId, next) => {
      if (!ours(contentsId)) return
      if (!Number.isFinite(next.width) || !Number.isFinite(next.height) || next.width < 1 || next.height < 1) return
      const box = { width: Math.min(Math.ceil(next.width), 800), height: Math.min(Math.ceil(next.height), 60) }
      if (box.width === pill.width && box.height === pill.height) return
      pill = box
      placeCatcher()
    },
    resize: (contentsId, next) => {
      if (!ours(contentsId)) return
      if (!Number.isFinite(next.width) || !Number.isFinite(next.height)) return
      const held = clampExpanded(geometryOf(deps.place()), next)
      deps.write({ [SIZE_KEYS.width]: held.width, [SIZE_KEYS.height]: held.height })
      push()
    },
    catch: (contentsId, kind) => {
      if (!theCatcher(contentsId) || live() === null) return
      if (kind === 'enter') {
        if (!quiet) arrive()
      } else if (kind === 'leave') {
        if (!expanded) depart()
        quiet = false
      } else {
        quiet = false
        pinned = true
        over = true
        expand(true)
      }
    },
    menu: (contentsId) => {
      const target = live()
      if (!(ours(contentsId) || theCatcher(contentsId)) || target === null) return
      target.popUpMenu(contextMenu())
    },
    config: () => ({ enabled: readMenuBarEnabled(deps.read) }),
    configure,
    isShowing: () => {
      const target = live()
      return { island: target !== null, expanded, label: label().text, bounds: target === null ? null : target.getBounds() }
    },
    dispose: removeIsland,
  }
}

/* ---------------------------------------------------------------------- ipc -- */

/**
 * The island's channels. `wireHootMenuBar` registers them. The wire names are
 * the ones the first, menu bar version used, kept so nothing that already calls
 * them breaks.
 *
 * - `hoot-panel:snapshot`     (invoke)        → {@link HootMenuBarSnapshot}; also pushed on every change
 * - `hoot-panel:say`          (invoke, text)  → `{ ok, message }`
 * - `hoot-panel:start-hoot`   (invoke)        → `{ ok, message }`
 * - `hoot-panel:show-session` (invoke, id)    → `{ ok }`
 * - `hoot-menubar:config`     (invoke)        → `{ enabled }`
 * - `hoot-menubar:configure`  (invoke, patch) → `{ enabled }`
 * - `hoot-menubar:open`       (invoke)        → `{ ok, message }` — grown and pinned, as a click on it
 * - `hoot-panel:pointer` / `hoot-panel:held` / `hoot-panel:focus` / `hoot-panel:close` / `hoot-panel:menu` (send)
 * - `hoot-panel:size`         (send, box)     — the resting pill's size, for the catcher
 * - `hoot-panel:resize`       (send, size)    — the grown panel's size, where he let go of a corner
 * - `hoot-panel:catch`        (send, kind)    — the catcher: 'enter' | 'leave' | 'press'
 * - `session:labels`          (send, labels)  — the main window's names for its sessions
 */
export function registerHootMenuBarIpc(ipcMain: IpcMain, bar: HootMenuBar): void {
  const handles = [
    'hoot-panel:snapshot',
    'hoot-panel:say',
    'hoot-panel:start-hoot',
    'hoot-panel:show-session',
    'hoot-menubar:config',
    'hoot-menubar:configure',
    'hoot-menubar:open',
  ]
  for (const channel of handles) ipcMain.removeHandler(channel)
  const sends = [
    'hoot-panel:pointer',
    'hoot-panel:held',
    'hoot-panel:focus',
    'hoot-panel:close',
    'hoot-panel:size',
    'hoot-panel:menu',
    'hoot-panel:catch',
    'hoot-panel:resize',
    'session:labels',
  ]
  for (const channel of sends) ipcMain.removeAllListeners(channel)

  ipcMain.handle('hoot-panel:snapshot', () => bar.snapshot())
  ipcMain.handle('hoot-panel:say', (_event: IpcMainInvokeEvent, text: unknown) => bar.say(typeof text === 'string' ? text : ''))
  ipcMain.handle('hoot-panel:start-hoot', () => bar.startHoot())
  ipcMain.handle('hoot-panel:show-session', (_event: IpcMainInvokeEvent, id: unknown) =>
    typeof id === 'string' ? bar.showSession(id) : { ok: false },
  )
  ipcMain.handle('hoot-menubar:config', () => bar.config())
  ipcMain.handle('hoot-menubar:open', () => bar.openPanel())
  ipcMain.handle('hoot-menubar:configure', (_event: IpcMainInvokeEvent, patch: unknown) => {
    const raw = (typeof patch === 'object' && patch !== null ? patch : {}) as Record<string, unknown>
    return bar.configure(typeof raw.enabled === 'boolean' ? { enabled: raw.enabled } : {})
  })
  ipcMain.on('hoot-panel:pointer', (event: IpcMainEvent, inside: unknown) => bar.pointer(event.sender.id, inside === true))
  ipcMain.on('hoot-panel:held', (event: IpcMainEvent, held: unknown) => bar.held(event.sender.id, held === true))
  ipcMain.on('hoot-panel:focus', (event: IpcMainEvent) => bar.focus(event.sender.id))
  ipcMain.on('hoot-panel:close', (event: IpcMainEvent) => bar.close(event.sender.id))
  ipcMain.on('hoot-panel:size', (event: IpcMainEvent, raw: unknown) => {
    if (typeof raw !== 'object' || raw === null) return
    const { width, height } = raw as { width?: unknown; height?: unknown }
    if (typeof width === 'number' && typeof height === 'number') bar.size(event.sender.id, { width, height })
  })
  ipcMain.on('hoot-panel:menu', (event: IpcMainEvent) => bar.menu(event.sender.id))
  ipcMain.on('hoot-panel:resize', (event: IpcMainEvent, raw: unknown) => {
    if (typeof raw !== 'object' || raw === null) return
    const { width, height } = raw as { width?: unknown; height?: unknown }
    if (typeof width === 'number' && typeof height === 'number') bar.resize(event.sender.id, { width, height })
  })
  ipcMain.on('hoot-panel:catch', (event: IpcMainEvent, kind: unknown) => {
    if (kind === 'enter' || kind === 'leave' || kind === 'press') bar.catch(event.sender.id, kind)
  })
  ipcMain.on('session:labels', (_event: IpcMainEvent, labels: unknown) => {
    if (typeof labels === 'object' && labels !== null && !Array.isArray(labels)) {
      bar.setLabels(labels as Record<string, string>)
    }
  })
}

/* ----------------------------------------------------------------- electron -- */

export interface WireHootMenuBarOptions
  extends Omit<HootMenuBarDeps, 'makeIsland' | 'makeCatcher' | 'place' | 'schedule' | 'supported'> {
  ipcMain: IpcMain
  preload: string
  rendererUrl?: string
  rendererFile: string
}

/**
 * The display the island lives on: the one with the menu bar.
 *
 * `TERMINALDECK_ISLAND_DISPLAY_X` picks another one, by any x inside it — for a
 * scratch copy run beside somebody's real one, so the test island appears on a
 * side screen and not in the middle of the screen they are working on.
 */
function islandDisplay(): Electron.Display {
  const raw = process.env.TERMINALDECK_ISLAND_DISPLAY_X
  const x = raw === undefined || raw === '' ? Number.NaN : Number(raw)
  if (Number.isFinite(x)) {
    const found = screen.getAllDisplays().find((d) => x >= d.bounds.x && x < d.bounds.x + d.bounds.width)
    if (found !== undefined) return found
  }
  return screen.getPrimaryDisplay()
}

/** The menu bar's height when the work area does not say (a menu bar set to hide itself). */
const FALLBACK_BAR = 24

/** Build the island on real Electron, register its channels, and show it if the setting says so. */
export function wireHootMenuBar(options: WireHootMenuBarOptions): HootMenuBar {
  const mac = process.platform === 'darwin'
  let screens: ScreenReport[] = []

  const place = (): IslandPlace => {
    const display = islandDisplay()
    const notch = notchOf(display.bounds, screens)
    const bar = display.workArea.y - display.bounds.y
    return {
      display: display.bounds,
      barHeight: notch?.height ?? (bar > 0 ? bar : FALLBACK_BAR),
      notch,
    }
  }

  const bar = createHootMenuBar({
    ...options,
    supported: mac,
    place,
    makeIsland: () => {
      const where = place()
      const box = islandWindow({ barHeight: where.barHeight, displayWidth: where.display.width, notch: where.notch })
      const frame = placeIsland(where.display, islandCentre(where.display, where.notch), box)
      const window = new BrowserWindow({
        ...frame,
        // An NSPanel with the non-activating mask: over everything, on every
        // Space and over full-screen apps, and hovering or clicking it does not
        // bring this app forward.
        type: 'panel',
        frame: false,
        transparent: true,
        backgroundColor: '#00000000',
        // The page draws the shape and its shadow; the window is only room.
        hasShadow: false,
        roundedCorners: false,
        // Without this macOS keeps a window's top edge under the menu bar —
        // and the island's whole point is to be in it.
        enableLargerThanScreen: true,
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        acceptFirstMouse: true,
        show: false,
        title: BRAND.assistant,
        webPreferences: {
          preload: options.preload,
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
          // The morph runs on animation frames; a window the system thinks is
          // in the background must not have them slowed.
          backgroundThrottling: false,
        },
      })
      // One step above the menu bar and its icons, below other apps' open menus.
      window.setAlwaysOnTop(true, 'main-menu', 3)
      // `skipTransformProcessType`, or macOS hides this app's Dock icon for the
      // instant it takes to apply `visibleOnFullScreen`.
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true })
      window.setHiddenInMissionControl(true)
      window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
      if (options.rendererUrl) {
        const url = new URL(options.rendererUrl)
        url.searchParams.set('hootpanel', '1')
        void window.loadURL(url.toString())
      } else {
        void window.loadFile(options.rendererFile, { query: { hootpanel: '1' } })
      }
      return {
        webContents: window.webContents,
        isDestroyed: () => window.isDestroyed(),
        isVisible: () => window.isVisible(),
        setBounds: (bounds) => window.setBounds(bounds),
        getBounds: () => window.getBounds(),
        showInactive: () => window.showInactive(),
        isFocused: () => window.isFocused(),
        focus: () => window.focus(),
        blur: () => window.blur(),
        destroy: () => window.destroy(),
        setIgnoreMouseEvents: (ignore) => {
          // `forward` keeps the pointer's moves coming while clicks go through,
          // whenever this app is the one in front — so the page still sees it
          // come back onto the shape. When it is not, the catcher covers it.
          if (ignore) window.setIgnoreMouseEvents(true, { forward: true })
          else window.setIgnoreMouseEvents(false)
        },
        popUpMenu: (items) => Menu.buildFromTemplate(items).popup({ window }),
        on: (event, listener) => {
          window.on(event as 'blur', listener)
        },
      }
    },
    makeCatcher: () => {
      const window = new BrowserWindow({
        width: 96,
        height: 24,
        type: 'panel',
        frame: false,
        transparent: true,
        backgroundColor: '#00000000',
        hasShadow: false,
        roundedCorners: false,
        enableLargerThanScreen: true,
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        focusable: false,
        acceptFirstMouse: true,
        show: false,
        webPreferences: {
          preload: options.preload,
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
        },
      })
      // One above the island, so the pointer meets it first.
      window.setAlwaysOnTop(true, 'main-menu', 4)
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true })
      window.setHiddenInMissionControl(true)
      window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
      // The regular bundled renderer runs under the production script-src 'self'.
      // A data: page with an inline listener is blocked in installed builds.
      if (options.rendererUrl) {
        const url = new URL(options.rendererUrl)
        url.searchParams.set('hootcatcher', '1')
        void window.loadURL(url.toString())
      } else {
        void window.loadFile(options.rendererFile, { query: { hootcatcher: '1' } })
      }
      return {
        webContents: window.webContents,
        isDestroyed: () => window.isDestroyed(),
        setBounds: (bounds) => window.setBounds(bounds),
        showInactive: () => {
          if (!window.isVisible()) window.showInactive()
        },
        setIgnoreMouseEvents: (ignore) => window.setIgnoreMouseEvents(ignore),
        destroy: () => window.destroy(),
      }
    },
    schedule: (run, ms) => {
      const timer = setTimeout(run, ms)
      return { cancel: () => clearTimeout(timer) }
    },
  })
  registerHootMenuBarIpc(options.ipcMain, bar)

  if (mac) {
    // The notch, read once now and again whenever a display changes.
    const reread = (): void => {
      void readScreens().then((next) => {
        screens = next
        bar.displaysChanged()
      })
    }
    reread()
    screen.on('display-added', reread)
    screen.on('display-removed', reread)
    screen.on('display-metrics-changed', reread)
    // The system going light or dark, or the app's own theme setting moving
    // `nativeTheme` with it (`syncNativeAppearance` in `index.ts`).
    nativeTheme.on('updated', () => bar.themeChanged())
  }
  bar.apply()
  return bar
}
