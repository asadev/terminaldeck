import { mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  BrowserWindow,
  screen,
  type BrowserWindowConstructorOptions,
  type IpcMain,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
} from 'electron'
import { writeFileAtomic } from './atomic-write'
import {
  displayMostlyHolding,
  placementFile,
  placeNew,
  placeRestored,
  POPOUT_MIN_HEIGHT,
  POPOUT_MIN_WIDTH,
  readPlacements,
  type DisplayInfo,
  type PlacementFile,
  type PopoutPlacement,
  type Rect,
} from './popout-placement'

/**
 * A session in a window of its own.
 *
 * Asad, 2026-10-03: *"we should be able to bring any of the window out like
 * separately… session one I'm running right now in my screen one… I have
 * another monitor alongside. Session two I want to move in my another screen."*
 *
 * ## It is the same session, and that is the whole design
 *
 * Nothing here starts anything. A session is a pty in this process, and every
 * window that shows one does it the same way: it asks for the scrollback and
 * listens to `session:data` (see `TerminalView.tsx`). So a session's own window
 * is a second renderer that asks the same two questions about one id — and the
 * main window *stops* asking while it is out, because two terminals attached to
 * one pty would each type into it and each resize it. Moving it back is the
 * reverse: the window closes, the main window mounts the terminal again and
 * redraws it from the same buffer. The process never notices either move.
 *
 * That also means it survives what the main window does. The pushes the window
 * lives on go out of `send()` in `index.ts`, which used to know about exactly
 * one window; {@link PopoutRegistry.forward} is the one line it now calls first,
 * so a session in its own window keeps printing while the main window is
 * minimised, on another Space, or closed altogether.
 *
 * ## Closing it never ends anything
 *
 * The red button on a session's own window puts the session back in the main
 * window. That is not a convention borrowed from somewhere, it is the only safe
 * reading: the ✕ that ends a session asks first and is a deliberate act, and a
 * window's close button is pressed without thinking. Quitting, and the app
 * going to the background, close these windows too — and those are different
 * again, because the person did not ask for the session to move: the window is
 * remembered and comes back where it was. See {@link PopoutRegistry.suspend}.
 *
 * ## What can come out
 *
 * A session running on this computer, except the copilot (it has its own page
 * and its own chrome in the main window). A browser page is a
 * `WebContentsView` composited into the main window and positioned by it, and a
 * session on another machine is a link the main window holds; both would need
 * their owner rebuilt rather than a second window opened, so neither is offered.
 */

/* ------------------------------------------------------------------ types -- */

/** The window, as much of Electron's as this module touches. A fake in the tests. */
export interface PopoutWindowHandle {
  readonly id: number
  readonly webContents: {
    readonly id: number
    send(channel: string, ...args: unknown[]): void
    isDestroyed(): boolean
  }
  getBounds(): Rect
  getNormalBounds(): Rect
  isFullScreen(): boolean
  isMinimized(): boolean
  isFocused(): boolean
  isDestroyed(): boolean
  setTitle(title: string): void
  setFullScreen(on: boolean): void
  restore(): void
  show(): void
  focus(): void
  close(): void
  on(event: PopoutWindowEvent, listener: () => void): void
}

export type PopoutWindowEvent =
  | 'close'
  | 'closed'
  | 'move'
  | 'resize'
  | 'focus'
  | 'blur'
  | 'enter-full-screen'
  | 'leave-full-screen'

/** A live session, as much of it as a window needs. */
export interface PopoutSession {
  id: string
  /** The name a tab keeps across a restart. Absent means nothing to restore into. */
  tabKey?: string
  title: string
  /** The whole `SessionMeta`, passed through to the main window on a replacement. */
  meta: unknown
}

export interface PopoutDeps {
  /** Make the window for one session — the renderer in its single-session mode. */
  makeWindow(input: { sessionId: string; bounds: Rect; title: string }): PopoutWindowHandle
  displays(): { all: DisplayInfo[]; primary: DisplayInfo }
  /** The main window's bounds, or null while it is closed. */
  mainBounds(): Rect | null
  /**
   * Bring the main window forward — making it, if it is closed — and run a
   * command there when one is given. How a key pressed in a session's own window
   * reaches the window that owns that command.
   */
  showMain(command?: string): void
  /** A session running on this computer, or null. */
  session(id: string): PopoutSession | null
  /** Why this session may not have its own window, or null when it may. */
  refusal(id: string): string | null
  /** The status the main process last classified for it. */
  statusOf(id: string): string | null
  /** The placements file, parsed, or null when there is none. */
  readFile(): unknown
  writeFile(file: PlacementFile): void
  /** Tell every window what is out, and what just happened. */
  announce(view: PopoutView, event: PopoutEvent | null): void
  /** Tell the main window a session it knows was replaced by another (an account switch). */
  announceReplaced(previousId: string, meta: unknown): void
  /** Debounce timer. Injected so a test does not wait. */
  schedule?(run: () => void, ms: number): { cancel(): void }
  log?(message: string, detail?: Record<string, unknown>): void
}

/** One window, as the windows and the tools are told about it. */
export interface PopoutWindowView {
  sessionId: string
  windowId: number
  /** What the main window calls the session — the strip's own label, carried over. */
  label: string
  status: string | null
  displayId: number | null
  /** The display's own name, so a tool can say "on the DELL" rather than a number. */
  displayLabel: string
  bounds: Rect
  fullScreen: boolean
  minimized: boolean
  focused: boolean
}

export interface PopoutDisplayView {
  id: number
  label: string
  primary: boolean
  width: number
  height: number
}

export interface PopoutView {
  windows: PopoutWindowView[]
  displays: PopoutDisplayView[]
}

/** Why the list changed, when it was a move a window should react to. */
export type PopoutEvent =
  | { kind: 'opened'; sessionId: string }
  /** `select`: the main window should bring the session to the front — an explicit "move back". */
  | { kind: 'docked'; sessionId: string; select: boolean }
  | { kind: 'replaced'; previousId: string; sessionId: string }

export interface PopoutResult {
  ok: boolean
  /** One plain sentence: what happened, or why nothing did. */
  message: string
  sessionId: string
  windowId?: number
  display?: string
}

export interface OpenOptions {
  /** A screen point to put the window's title bar under — where a dragged tab was let go. */
  at?: { x: number; y: number } | null
  /** A display to centre it on. Ignored when `at` is given. */
  displayId?: number | null
}

export interface PopoutRegistry {
  open(sessionId: string, options?: OpenOptions): PopoutResult
  dock(sessionId: string, options?: { select?: boolean }): PopoutResult
  focus(sessionId: string): PopoutResult
  view(): PopoutView
  isPopped(sessionId: string): boolean
  /** Copy one of `send()`'s pushes to the windows that need it. */
  forward(channel: string, args: readonly unknown[]): void
  /** The main window's names for the sessions that are out. */
  setLabels(labels: Readonly<Record<string, string>>): void
  /** A session ended for good: its window goes and so does its placement. */
  sessionEnded(id: string): void
  /** A session was replaced in place by another (an account switch that restarts the agent). */
  sessionReplaced(previousId: string, nextId: string): void
  /** The replacement, asked for by the window that holds the session. */
  rekey(fromContentsId: number, previousId: string, nextId: string): PopoutResult
  /** Reopen every remembered window whose session is running. Returns the ids reopened. */
  restore(sessions: readonly PopoutSession[]): string[]
  /** Close every window and keep where they were — quitting, or going to the background. */
  suspend(): void
  /** The session in a window, by its renderer. Null for the main window. */
  sessionForContents(contentsId: number): string | null
  windowIdForContents(contentsId: number): number | null
  /** A key the application menu sent while a session's own window had focus. True when handled. */
  routeMenu(command: string): boolean
}

/* -------------------------------------------------------------- constants -- */

/** The file, inside userData. One small JSON document. */
export const POPOUT_FILE = 'popout-windows.json'

/** Channels. One spelling, shared with the preload and the action table. */
export const POPOUT_STATE_CHANNEL = 'popout:state'

/** How long after the last move or resize the placement is written. */
const SAVE_DELAY_MS = 400

/** More than anybody has monitors for, few enough that a stale file stays small. */
const MAX_REMEMBERED = 40

/**
 * Pushes a session's own window has no use for, and that are expensive.
 *
 * Everything else `send()` pushes is copied to every session window. That is the
 * safe default and it was chosen over a list of the channels a window needs: the
 * window's chrome is built from the same components as the main window's, and a
 * list would go stale the first time one of them subscribed to something new —
 * silently, as a chip that never updates in one window only. A push nobody in a
 * window listens to costs one IPC message and nothing else. These are the
 * streams where that one message happens dozens of times a second.
 */
const NOT_FORWARDED = [
  'devices:frame',
  'machines:output',
  'servers:shell:output',
  'browser:progress',
  'debug:ipc-call',
]

/**
 * Commands a session's own window may ask the main window to run.
 *
 * The connectors chip, the account chip's "Manage accounts…" and a new session
 * are pages and dialogs of the main window; a session window has none of them,
 * so it sends the person there. Listed so a renderer cannot ask main to run
 * whatever it likes.
 */
export const MAIN_COMMANDS: ReadonlySet<string> = new Set([
  'view.mcp',
  'app.preferences',
  'session.new',
  'session.newDialog',
])

/* ------------------------------------------------------------ registry -- */

interface Entry {
  sessionId: string
  key: string | null
  window: PopoutWindowHandle
  label: string
  /** Why the window is closing, when this module closed it. Absent: a person did. */
  closing?: 'dock' | 'suspend' | 'ended'
  /** `select` for the dock this close is part of. */
  select?: boolean
}

export function createPopoutRegistry(deps: PopoutDeps): PopoutRegistry {
  const entries = new Map<string, Entry>()
  const placements = new Map<string, PopoutPlacement>()
  for (const placement of readPlacements(safeRead(deps))) placements.set(placement.key, placement)
  const schedule = deps.schedule ?? ((run, ms) => {
    const timer = setTimeout(run, ms)
    return { cancel: () => clearTimeout(timer) }
  })
  let pendingSave: { cancel(): void } | null = null
  let suspended = false

  const log = (message: string, detail?: Record<string, unknown>): void => deps.log?.(message, detail)

  /* -- persistence -- */

  function remember(entry: Entry): void {
    if (entry.key === null || entry.window.isDestroyed()) return
    const bounds = entry.window.isFullScreen() ? entry.window.getNormalBounds() : entry.window.getBounds()
    const display = displayMostlyHolding(bounds, deps.displays().all)
    // Delete then set, so the newest is last and the oldest is what a cap drops.
    placements.delete(entry.key)
    placements.set(entry.key, {
      key: entry.key,
      bounds,
      displayId: display?.id ?? null,
      fullScreen: entry.window.isFullScreen(),
    })
    while (placements.size > MAX_REMEMBERED) {
      const oldest = placements.keys().next().value
      if (oldest === undefined) break
      placements.delete(oldest)
    }
  }

  function write(): void {
    try {
      deps.writeFile(placementFile([...placements.values()]))
    } catch (error) {
      // A placement that could not be written costs where a window opens next
      // launch, and nothing else. Logged, never thrown into a window event.
      log('popout: could not write placements', { error: error instanceof Error ? error.message : String(error) })
    }
  }

  function saveSoon(entry: Entry): void {
    if (suspended) return
    pendingSave?.cancel()
    pendingSave = schedule(() => {
      pendingSave = null
      if (!entry.window.isDestroyed()) remember(entry)
      write()
    }, SAVE_DELAY_MS)
  }

  /* -- the list -- */

  function view(): PopoutView {
    const { all, primary } = deps.displays()
    const windows: PopoutWindowView[] = []
    for (const entry of entries.values()) {
      if (entry.window.isDestroyed()) continue
      const bounds = entry.window.isFullScreen() ? entry.window.getNormalBounds() : entry.window.getBounds()
      const display = displayMostlyHolding(bounds, all)
      windows.push({
        sessionId: entry.sessionId,
        windowId: entry.window.id,
        label: entry.label,
        status: deps.statusOf(entry.sessionId),
        displayId: display?.id ?? null,
        displayLabel: display?.label ?? '',
        bounds,
        fullScreen: entry.window.isFullScreen(),
        minimized: entry.window.isMinimized(),
        focused: entry.window.isFocused(),
      })
    }
    return {
      windows,
      displays: all.map((d) => ({
        id: d.id,
        label: d.label,
        primary: d.id === primary.id,
        width: d.bounds.width,
        height: d.bounds.height,
      })),
    }
  }

  function announce(event: PopoutEvent | null): void {
    deps.announce(view(), event)
  }

  /* -- windows -- */

  function attach(entry: Entry): void {
    const { window } = entry
    window.on('close', () => {
      // Read once: `closed` is about to delete the entry, and a second close
      // event (Electron sends one per attempt) must not run the dock twice.
      if (entries.get(entry.sessionId) !== entry) return
      const why = entry.closing
      entries.delete(entry.sessionId)
      if (why === 'suspend') {
        announce(null)
        return
      }
      // Docked by a person (the red button, ⌘W) or by a command, or ended:
      // either way the placement is forgotten, so a restart does not pull a
      // session back out that somebody put away on purpose.
      if (entry.key !== null) {
        placements.delete(entry.key)
        pendingSave?.cancel()
        pendingSave = null
        write()
      }
      if (why === 'ended') {
        announce(null)
        return
      }
      announce({ kind: 'docked', sessionId: entry.sessionId, select: entry.select === true })
      log('popout: docked', { sessionId: entry.sessionId, by: why ?? 'window' })
    })
    window.on('move', () => saveSoon(entry))
    window.on('resize', () => saveSoon(entry))
    window.on('enter-full-screen', () => {
      saveSoon(entry)
      announce(null)
    })
    window.on('leave-full-screen', () => {
      saveSoon(entry)
      announce(null)
    })
    // Focus moves the "focused" mark in the list, which the tools report and
    // the main window's card reads ("open in its own window").
    window.on('focus', () => announce(null))
    window.on('blur', () => announce(null))
  }

  function displayLabelFor(bounds: Rect): string {
    return displayMostlyHolding(bounds, deps.displays().all)?.label ?? ''
  }

  function make(session: PopoutSession, bounds: Rect, fullScreen: boolean): Entry {
    const window = deps.makeWindow({ sessionId: session.id, bounds, title: session.title })
    const entry: Entry = {
      sessionId: session.id,
      key: session.tabKey ?? null,
      window,
      label: session.title,
    }
    entries.set(session.id, entry)
    attach(entry)
    if (fullScreen) window.setFullScreen(true)
    return entry
  }

  function open(sessionId: string, options: OpenOptions = {}): PopoutResult {
    if (typeof sessionId !== 'string' || sessionId === '') {
      return { ok: false, message: 'Which session? No id was given.', sessionId: '' }
    }
    const existing = entries.get(sessionId)
    if (existing && !existing.window.isDestroyed()) {
      // Asked twice is a request to see it, not a second window.
      if (existing.window.isMinimized()) existing.window.restore()
      existing.window.show()
      existing.window.focus()
      return {
        ok: true,
        message: 'That session already has its own window; it is in front now.',
        sessionId,
        windowId: existing.window.id,
        display: displayLabelFor(existing.window.getBounds()),
      }
    }
    const session = deps.session(sessionId)
    if (session === null) {
      return { ok: false, message: 'No session with that id is running on this computer.', sessionId }
    }
    const refused = deps.refusal(sessionId)
    if (refused !== null) return { ok: false, message: refused, sessionId }

    const { all, primary } = deps.displays()
    let target: DisplayInfo | null = null
    if (options.displayId !== undefined && options.displayId !== null) {
      target = all.find((d) => d.id === options.displayId) ?? null
      if (target === null) {
        return { ok: false, message: 'There is no display with that id now; windows.list names the ones there are.', sessionId }
      }
    }
    const placed = placeNew({
      at: options.at ?? null,
      display: target,
      main: deps.mainBounds(),
      displays: all,
      primary,
      open: entries.size,
    })
    suspended = false
    const entry = make(session, placed.bounds, false)
    remember(entry)
    write()
    announce({ kind: 'opened', sessionId })
    log('popout: opened', { sessionId, display: placed.display.label })
    return {
      ok: true,
      message: `It is in its own window now${placed.display.label ? `, on ${placed.display.label}` : ''}.`,
      sessionId,
      windowId: entry.window.id,
      display: placed.display.label,
    }
  }

  function dock(sessionId: string, options: { select?: boolean } = {}): PopoutResult {
    const entry = entries.get(sessionId)
    if (!entry || entry.window.isDestroyed()) {
      return { ok: false, message: 'That session is not in a window of its own.', sessionId }
    }
    entry.closing = 'dock'
    entry.select = options.select !== false
    entry.window.close()
    if (entry.select) deps.showMain()
    return { ok: true, message: 'It is back in the main window.', sessionId }
  }

  function focus(sessionId: string): PopoutResult {
    const entry = entries.get(sessionId)
    if (!entry || entry.window.isDestroyed()) {
      return { ok: false, message: 'That session is not in a window of its own.', sessionId }
    }
    if (entry.window.isMinimized()) entry.window.restore()
    entry.window.show()
    entry.window.focus()
    return { ok: true, message: 'Its window is in front.', sessionId, windowId: entry.window.id }
  }

  function forward(channel: string, args: readonly unknown[]): void {
    if (channel === 'session:switched' && typeof args[0] === 'string') {
      const next = args[1] as { id?: unknown } | undefined
      if (next && typeof next.id === 'string' && next.id !== args[0]) sessionReplaced(args[0], next.id)
    }
    if (entries.size === 0) return
    if (NOT_FORWARDED.includes(channel)) return
    if (channel === 'session:data') {
      // The one push worth filtering by session: every byte every session
      // prints goes down it, and a window shows one session.
      const entry = typeof args[0] === 'string' ? entries.get(args[0]) : undefined
      if (entry && !entry.window.webContents.isDestroyed()) entry.window.webContents.send(channel, ...args)
      return
    }
    for (const entry of entries.values()) {
      if (entry.window.isDestroyed() || entry.window.webContents.isDestroyed()) continue
      entry.window.webContents.send(channel, ...args)
    }
  }

  function setLabels(labels: Readonly<Record<string, string>>): void {
    let changed = false
    for (const [sessionId, label] of Object.entries(labels)) {
      const entry = entries.get(sessionId)
      if (!entry || typeof label !== 'string' || label === '' || entry.label === label) continue
      entry.label = label
      // The window's own title is what the Window menu lists and what ⌘` and
      // Mission Control show, so the session's name has to be on it.
      if (!entry.window.isDestroyed()) entry.window.setTitle(label)
      changed = true
    }
    if (changed) announce(null)
  }

  function sessionEnded(id: string): void {
    const entry = entries.get(id)
    if (entry && !entry.window.isDestroyed()) {
      entry.closing = 'ended'
      entry.window.close()
      return
    }
    // Not open, but maybe remembered: a session that ended has nowhere to come back to.
    const key = deps.session(id)?.tabKey
    if (key && placements.delete(key)) write()
  }

  function sessionReplaced(previousId: string, nextId: string): void {
    const entry = entries.get(previousId)
    if (!entry || previousId === nextId || entries.has(nextId)) return
    entries.delete(previousId)
    entry.sessionId = nextId
    const next = deps.session(nextId)
    const nextKey = next?.tabKey ?? entry.key
    if (entry.key !== null && entry.key !== nextKey) placements.delete(entry.key)
    entry.key = nextKey
    entries.set(nextId, entry)
    remember(entry)
    write()
    announce({ kind: 'replaced', previousId, sessionId: nextId })
  }

  function rekey(fromContentsId: number, previousId: string, nextId: string): PopoutResult {
    const entry = entries.get(previousId)
    if (!entry || entry.window.webContents.id !== fromContentsId) {
      return { ok: false, message: 'That window does not hold that session.', sessionId: previousId }
    }
    const next = deps.session(nextId)
    if (next === null) return { ok: false, message: 'The replacement session is not running.', sessionId: nextId }
    sessionReplaced(previousId, nextId)
    // The main window adopts a replacement only when it is told; a switch made
    // from a session's own window is one it did not ask for.
    deps.announceReplaced(previousId, next.meta)
    return { ok: true, message: 'The window follows the new session.', sessionId: nextId, windowId: entry.window.id }
  }

  function restore(sessions: readonly PopoutSession[]): string[] {
    suspended = false
    const { all, primary } = deps.displays()
    const reopened: string[] = []
    // One window per remembered place, even if two sessions claim the same tab
    // key — the second would open exactly on top of the first.
    const openKeys = new Set([...entries.values()].map((entry) => entry.key))
    for (const session of sessions) {
      if (!session.tabKey || entries.has(session.id) || openKeys.has(session.tabKey)) continue
      const saved = placements.get(session.tabKey)
      if (!saved) continue
      if (deps.refusal(session.id) !== null) continue
      const placed = placeRestored(saved, all, primary)
      const entry = make(session, placed.bounds, saved.fullScreen)
      remember(entry)
      openKeys.add(session.tabKey)
      reopened.push(session.id)
      log('popout: restored', { sessionId: session.id, outcome: placed.outcome, display: placed.display.label })
    }
    if (reopened.length > 0) {
      write()
      announce(null)
    }
    return reopened
  }

  function suspend(): void {
    pendingSave?.cancel()
    pendingSave = null
    for (const entry of entries.values()) remember(entry)
    write()
    suspended = true
    for (const entry of [...entries.values()]) {
      if (entry.window.isDestroyed()) continue
      entry.closing = 'suspend'
      entry.window.close()
    }
  }

  function entryForContents(contentsId: number): Entry | null {
    for (const entry of entries.values()) {
      if (!entry.window.isDestroyed() && entry.window.webContents.id === contentsId) return entry
    }
    return null
  }

  function routeMenu(command: string): boolean {
    let focused: Entry | null = null
    for (const entry of entries.values()) {
      if (!entry.window.isDestroyed() && entry.window.isFocused()) focused = entry
    }
    if (focused === null) return false
    /*
     * ⌘W in a session's own window closes the window — which puts the session
     * back — and never deletes it. In the main window the same key deletes the
     * session in front, after asking. The two readings are the same rule: ⌘W
     * closes the thing that is in front, and here that thing is a window.
     */
    if (command === 'session.close') {
      dock(focused.sessionId, { select: false })
      return true
    }
    // The Window menu's two moves, asked of the window that is in front: this
    // one is already out, and "back" means this one.
    if (command === 'session.popOut') return true
    if (command === 'session.dock') {
      dock(focused.sessionId, { select: true })
      return true
    }
    // Everything else belongs to the main window — a new session, the palette,
    // Settings — so the person is taken there and the command runs there.
    deps.showMain(command)
    return true
  }

  return {
    open,
    dock,
    focus,
    view,
    isPopped: (sessionId) => entries.has(sessionId),
    forward,
    setLabels,
    sessionEnded,
    sessionReplaced,
    rekey,
    restore,
    suspend,
    sessionForContents: (contentsId) => entryForContents(contentsId)?.sessionId ?? null,
    windowIdForContents: (contentsId) => entryForContents(contentsId)?.window.id ?? null,
    routeMenu,
  }
}

function safeRead(deps: PopoutDeps): unknown {
  try {
    return deps.readFile()
  } catch {
    return null
  }
}

/* ------------------------------------------------------------------- ipc -- */

function readPoint(value: unknown): { x: number; y: number } | null {
  if (typeof value !== 'object' || value === null) return null
  const point = value as Record<string, unknown>
  return typeof point.x === 'number' && Number.isFinite(point.x) && typeof point.y === 'number' && Number.isFinite(point.y)
    ? { x: Math.round(point.x), y: Math.round(point.y) }
    : null
}

/**
 * The window's channels. Call once from `registerIpc()` — `wirePopouts` does.
 *
 * - `popout:open`      (invoke, sessionId, { at?, displayId? }) → {@link PopoutResult}
 * - `popout:dock`      (invoke, sessionId)                     → {@link PopoutResult}
 * - `popout:focus`     (invoke, sessionId)                     → {@link PopoutResult}
 * - `popout:list`      (invoke)                                → {@link PopoutView} plus `self`
 * - `popout:rekey`     (invoke, previousId, nextId)            → {@link PopoutResult}
 * - `popout:labels`    (send, { [sessionId]: label })
 * - `popout:show-main` (send, command)
 * - `popout:state`     (push) {@link PopoutView}, {@link PopoutEvent} | null
 */
export function registerPopoutIpc(
  ipcMain: IpcMain,
  registry: PopoutRegistry,
  showMain: (command?: string) => void,
): void {
  for (const channel of ['popout:open', 'popout:dock', 'popout:focus', 'popout:list', 'popout:rekey']) {
    ipcMain.removeHandler(channel)
  }
  ipcMain.removeAllListeners('popout:labels')
  ipcMain.removeAllListeners('popout:show-main')

  ipcMain.handle('popout:open', (_event: IpcMainInvokeEvent, sessionId: unknown, options: unknown) => {
    const raw = (typeof options === 'object' && options !== null ? options : {}) as Record<string, unknown>
    return registry.open(typeof sessionId === 'string' ? sessionId : '', {
      at: readPoint(raw.at),
      displayId: typeof raw.displayId === 'number' && Number.isFinite(raw.displayId) ? raw.displayId : null,
    })
  })
  ipcMain.handle('popout:dock', (_event: IpcMainInvokeEvent, sessionId: unknown) =>
    registry.dock(typeof sessionId === 'string' ? sessionId : '', { select: true }),
  )
  ipcMain.handle('popout:focus', (_event: IpcMainInvokeEvent, sessionId: unknown) =>
    registry.focus(typeof sessionId === 'string' ? sessionId : ''),
  )
  ipcMain.handle('popout:list', (event: IpcMainInvokeEvent) => ({
    ...registry.view(),
    // Which window is asking, so a session's own window can find itself in the
    // list — by window, because the session it holds can change under it.
    self: registry.windowIdForContents(event.sender.id),
  }))
  ipcMain.handle('popout:rekey', (event: IpcMainInvokeEvent, previousId: unknown, nextId: unknown) =>
    typeof previousId === 'string' && typeof nextId === 'string'
      ? registry.rekey(event.sender.id, previousId, nextId)
      : { ok: false, message: 'Which session? No id was given.', sessionId: '' },
  )
  ipcMain.on('popout:labels', (_event: IpcMainEvent, labels: unknown) => {
    if (typeof labels !== 'object' || labels === null || Array.isArray(labels)) return
    const clean: Record<string, string> = {}
    for (const [id, label] of Object.entries(labels as Record<string, unknown>)) {
      if (typeof label === 'string' && label.length <= 200) clean[id] = label
    }
    registry.setLabels(clean)
  })
  ipcMain.on('popout:show-main', (_event: IpcMainEvent, command: unknown) => {
    showMain(typeof command === 'string' && MAIN_COMMANDS.has(command) ? command : undefined)
  })
}

/* --------------------------------------------------------------- electron -- */

/** What `index.ts` knows and this module needs, to make real windows. */
export interface WirePopoutsOptions {
  ipcMain: IpcMain
  userData: string
  /** The preload every window of this app uses. */
  preload: string
  /** Dev server URL, when running under `npm run dev`. */
  rendererUrl?: string
  /** The built renderer, otherwise. */
  rendererFile: string
  /** The title-bar options the main window is built with (`titleBarChrome`). */
  chrome(): Partial<BrowserWindowConstructorOptions>
  mainBounds(): Rect | null
  showMain(command?: string): void
  sessions(): readonly PopoutSession[]
  refusal(id: string): string | null
  statusOf(id: string): string | null
  announce(view: PopoutView, event: PopoutEvent | null): void
  announceReplaced(previousId: string, meta: unknown): void
  log?(message: string, detail?: Record<string, unknown>): void
}

function electronDisplays(): { all: DisplayInfo[]; primary: DisplayInfo } {
  const toInfo = (d: Electron.Display): DisplayInfo => ({
    id: d.id,
    bounds: { ...d.bounds },
    workArea: { ...d.workArea },
    label: d.label ?? '',
  })
  return { all: screen.getAllDisplays().map(toInfo), primary: toInfo(screen.getPrimaryDisplay()) }
}

/**
 * Build the registry on real Electron windows, register its channels, and hand
 * it back. `index.ts` calls this once, after `ready`.
 */
export function wirePopouts(options: WirePopoutsOptions): PopoutRegistry {
  const file = join(options.userData, POPOUT_FILE)
  const registry = createPopoutRegistry({
    makeWindow: ({ sessionId, bounds, title }) => {
      const window = new BrowserWindow({
        ...bounds,
        minWidth: POPOUT_MIN_WIDTH,
        minHeight: POPOUT_MIN_HEIGHT,
        title,
        show: false,
        // The dark theme's --bg-primary, for the reason the main window gives
        // beside the same line: it is what Chromium paints before the first frame.
        backgroundColor: '#191919',
        ...options.chrome(),
        fullscreenable: true,
        webPreferences: {
          preload: options.preload,
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
        },
      })
      window.once('ready-to-show', () => window.show())
      // No bare Chromium windows from in here either; a link a terminal prints
      // goes through the main window's own handler, which owns that decision.
      window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
      if (options.rendererUrl) {
        const url = new URL(options.rendererUrl)
        url.searchParams.set('popout', sessionId)
        void window.loadURL(url.toString())
      } else {
        void window.loadFile(options.rendererFile, { query: { popout: sessionId } })
      }
      return window
    },
    displays: electronDisplays,
    mainBounds: options.mainBounds,
    showMain: options.showMain,
    session: (id) => options.sessions().find((s) => s.id === id) ?? null,
    refusal: options.refusal,
    statusOf: options.statusOf,
    readFile: () => {
      try {
        return JSON.parse(readFileSync(file, 'utf8')) as unknown
      } catch {
        return null
      }
    },
    writeFile: (contents) => {
      mkdirSync(options.userData, { recursive: true })
      writeFileAtomic(file, `${JSON.stringify(contents, null, 2)}\n`)
    },
    announce: options.announce,
    announceReplaced: options.announceReplaced,
    log: options.log,
  })
  registerPopoutIpc(options.ipcMain, registry, options.showMain)
  return registry
}
