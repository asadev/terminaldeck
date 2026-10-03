import {
  BrowserWindow,
  Menu,
  nativeImage,
  nativeTheme,
  screen,
  systemPreferences,
  Tray,
  type IpcMain,
  type IpcMainEvent,
  type IpcMainInvokeEvent,
  type MenuItemConstructorOptions,
} from 'electron'
import { BRAND } from '../shared/brand'
import {
  CLOSE_DELAY_MS,
  menuBarTitle,
  MOMENT_MS,
  MomentTracker,
  OPEN_DELAY_MS,
  readSnapshot,
  type HootMoment,
} from '../shared/hoot-panel-model'
import { HOOT_TRAY_ICONS } from './hoot-tray-icons'
import type { CopilotChatMessage } from './remote/protocol'

/**
 * Hoot in the macOS menu bar: an owl beside the clock and the Wi-Fi, and a
 * panel that drops down under it to talk.
 *
 * Asad, 2026-10-03: *"can we give a notch bar to hoot to live where we hover
 * and it comes down a little to talk, kind of dropdown"* — and then, having
 * seen a pill at the top centre of his screen, *"i need it in menu bar not
 * here"*. So this is a status item (Electron's `Tray`), and nothing floats in
 * the middle of anybody's screen.
 *
 * ## The icon
 *
 * The orange owl, at menu-bar size, from `HootMark` itself
 * (`hoot-tray-icons.ts` and the script that makes it). Beside it a title only
 * when something needs him: for a few seconds the moment itself — "Session 2
 * needs you" — and then just the number waiting, or nothing. It blinks now and
 * then, the way every other owl in the app does, unless the Mac is set to
 * reduce motion.
 *
 * ## The panel
 *
 * Resting the pointer on the owl (a short intent delay) or clicking it opens a
 * frameless glass panel just under it: Hoot's latest messages, "Ask Hoot…",
 * and the sessions waiting on him. It is an NSPanel with the non-activating
 * mask (`type: 'panel'`), shown with `showInactive`, so hovering never takes
 * the keyboard or brings this app forward. It closes when the pointer has left
 * both the owl and the panel for a moment, on a click outside it, or on
 * Escape — and stays while the box has text or the keyboard. A click on the owl
 * pins it open and hands it the keyboard, which is what a click means.
 *
 * ## Talking to Hoot is the phone's machinery, aimed at the Hoot that runs
 *
 * Nothing here starts a second Hoot. A message goes into the Hoot pinned in the
 * sidebar through `typeAndSubmit` — the two-write submit the phone's path
 * learned the hard way (`remote/copilot-say.ts`) — and the replies are read off
 * that Hoot's own transcript with `watchRunChat`, the phone's reader, pointed
 * at the desk Hoot. If Hoot is not running the panel says so in one line and
 * offers to start *it* (`ensureCopilot`).
 *
 * ## No polling
 *
 * Every change arrives as an event the app already sends: `send()` in
 * `index.ts` hands each push to {@link HootMenuBar.forward}, the transcript is
 * watched. The only timers are the intent delays, the moment's few seconds and
 * the blink — none of them asks anything.
 */

/* ----------------------------------------------------------------- settings -- */

/** Under `copilot.*` like every setting of Hoot's (`BRAND.assistant` says why). */
export const MENUBAR_KEY = 'copilot.menuBar'

/** Absent is on: Hoot is in the menu bar unless somebody turned it off. */
export function readMenuBarEnabled(read: (key: string) => unknown): boolean {
  return read(MENUBAR_KEY) !== false
}

/* ------------------------------------------------------------------ geometry -- */

export interface Rect {
  x: number
  y: number
  width: number
  height: number
}

/** How wide the panel is. Narrow enough to sit under a menu bar item without crowding it. */
export const PANEL_WIDTH = 360
export const PANEL_MIN_HEIGHT = 120
export const PANEL_MAX_HEIGHT = 520

/**
 * Where the panel goes: just under the owl, centred on it, kept inside the
 * display it is on. An icon near the right edge — most of them — gets a panel
 * that stops at the edge rather than running off it.
 */
export function panelBounds(icon: Rect, workArea: Rect, height: number): Rect {
  const h = Math.max(PANEL_MIN_HEIGHT, Math.min(PANEL_MAX_HEIGHT, Math.round(height)))
  const centre = icon.x + icon.width / 2
  const x = Math.round(
    Math.min(Math.max(centre - PANEL_WIDTH / 2, workArea.x + 8), workArea.x + workArea.width - PANEL_WIDTH - 8),
  )
  const y = Math.round(Math.max(icon.y + icon.height + 4, workArea.y + 2))
  return { x, y, width: PANEL_WIDTH, height: h }
}

/** The blink's resting gap: long and uneven, the way the sidebar's owl blinks. */
export function nextBlinkMs(random: () => number = Math.random): number {
  return Math.round(6500 + random() * 3500)
}
const BLINK_SHUT_MS = 140

/* ----------------------------------------------------------------- snapshot -- */

export interface HootMenuBarSnapshot {
  assistant: string
  /**
   * Light or dark, as the panel's glass will be drawn — `nativeTheme`, which the
   * main process sets from the app's theme preference. Sent rather than left to
   * the page to work out: a hidden window was measured not to hear the change.
   */
  appearance: 'light' | 'dark'
  hoot: { status: 'running' | 'starting' | 'stopped'; problem: string | null }
  sessions: Array<{ id: string; label: string; status: string }>
  messages: CopilotChatMessage[]
}

/** How many messages the panel keeps. It is a glance, not the conversation. */
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

export type TrayIconFrame = 'open' | 'closed'

/** The status item, as much of Electron's `Tray` as this module touches. */
export interface TrayHandle {
  setFrame(frame: TrayIconFrame): void
  setTitle(title: string): void
  getBounds(): Rect
  on(event: 'mouse-enter' | 'mouse-leave' | 'click' | 'right-click', listener: () => void): void
  popUpMenu(items: MenuItemConstructorOptions[]): void
  destroy(): void
}

/** The panel window, as much of `BrowserWindow` as this module touches. */
export interface PanelHandle {
  readonly webContents: { readonly id: number; send(channel: string, ...args: unknown[]): void; isDestroyed(): boolean }
  isDestroyed(): boolean
  isVisible(): boolean
  setBounds(bounds: Rect): void
  getBounds(): Rect
  showInactive(): void
  hide(): void
  focus(): void
  destroy(): void
  on(event: 'blur' | 'closed', listener: () => void): void
}

export interface HootMenuBarDeps {
  makeTray(): TrayHandle
  makePanel(): PanelHandle
  /** The work area of the display holding this point. */
  workAreaAt(point: { x: number; y: number }): Rect
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
  /** Bring the main window forward with this session in front. */
  showSession(id: string): void
  /** Bring the main window forward, on a page when one is named. */
  openApp(page?: 'hoot-settings'): void
  /**
   * The app's background menu — the sessions running, open, quit — with the
   * owl's own entries placed inside it (`residentMenuItems` in `resident.ts`).
   * The owl is the app's one menu bar icon, so its right-click menu is the menu
   * the old background tray had, and that tray no longer appears beside it.
   * Absent: the owl's own entries alone.
   */
  appMenuItems?(extras: {
    afterOpen: MenuItemConstructorOptions[]
    beforeQuit: MenuItemConstructorOptions[]
  }): MenuItemConstructorOptions[]
  /** The owl appeared or went, so whoever keeps the app visible can count icons again. */
  onShownChanged?(): void
  reducedMotion(): boolean
  /** Whether the system draws this app's surfaces dark right now (`nativeTheme.shouldUseDarkColors`). */
  dark(): boolean
  /** Timers. Injected so a test can run them by hand. */
  schedule(run: () => void, ms: number): { cancel(): void }
  now?(): number
  log?(message: string, detail?: Record<string, unknown>): void
}

export interface HootMenuBar {
  /** Read the setting and make the menu bar match: the owl there, or gone. */
  apply(): void
  /**
   * Open the panel as a click on the owl would — pinned, with the keyboard.
   * The way in from the palette and from a tool, for anybody who cannot hover
   * a menu bar item: a keyboard user, or an assistant.
   */
  openPanel(): { ok: boolean; message: string }
  /** Copy one of `send()`'s pushes in, and notice the ones that change what it shows. */
  forward(channel: string, args: readonly unknown[]): void
  setLabels(labels: Readonly<Record<string, string>>): void
  snapshot(): HootMenuBarSnapshot
  say(text: string): Promise<{ ok: boolean; message: string }>
  startHoot(): Promise<{ ok: boolean; message: string }>
  showSession(id: string): { ok: boolean }
  /** The panel's page: the pointer is over it, or not. */
  pointer(contentsId: number, inside: boolean): void
  /** The panel's page: the box has text or the keyboard, so it must stay. */
  held(contentsId: number, held: boolean): void
  /** The panel's page asking for the keyboard (a press in the box). */
  focus(contentsId: number): void
  /** Escape, from the panel. */
  close(contentsId: number): void
  /** The panel's page saying how tall its content is. */
  size(contentsId: number, height: number): void
  config(): { enabled: boolean }
  configure(patch: { enabled?: boolean }): { enabled: boolean }
  isShowing(): { tray: boolean; panel: boolean; title: string }
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
const CHANGES_HOOT = new Set(['session:created', 'session:exit', 'session:removed', 'session:switched'])

/** A burst of status pushes gathered into one update. */
const SETTLE_MS = 60

export function createHootMenuBar(deps: HootMenuBarDeps): HootMenuBar {
  let tray: TrayHandle | null = null
  let panel: PanelHandle | null = null
  let labels: Record<string, string> = {}
  let messages: CopilotChatMessage[] = []
  let hootCache: ReturnType<HootMenuBarDeps['hoot']> | null = null
  let watching: { sessionId: string; stop: () => void } | null = null
  let tracker = new MomentTracker()
  let moment: HootMoment | null = null
  let title = ''
  let panelHeight = 260

  // The panel's state, and why it is open.
  let open = false
  let pinned = false
  let overIcon = false
  let overPanel = false
  let holding = false

  const timers = {
    open: null as { cancel(): void } | null,
    close: null as { cancel(): void } | null,
    moment: null as { cancel(): void } | null,
    settle: null as { cancel(): void } | null,
    blink: null as { cancel(): void } | null,
  }
  const cancel = (name: keyof typeof timers): void => {
    timers[name]?.cancel()
    timers[name] = null
  }
  const now = (): number => (deps.now ? deps.now() : Date.now())

  const hoot = (): ReturnType<HootMenuBarDeps['hoot']> => {
    if (hootCache === null) hootCache = deps.hoot()
    return hootCache
  }

  function theirs(): Array<{ id: string; title: string; status: string }> {
    const own = hoot().sessionId
    return deps.sessions().filter((session) => session.id !== own)
  }

  function snapshot(): HootMenuBarSnapshot {
    const state = hoot()
    return {
      assistant: BRAND.assistant,
      appearance: deps.dark() ? 'dark' : 'light',
      hoot: { status: state.status, problem: state.problem },
      sessions: theirs().map((session) => ({
        id: session.id,
        label: labels[session.id] ?? session.title,
        status: session.status,
      })),
      messages,
    }
  }

  /* -- the menu bar item -- */

  function retitle(): void {
    const next = menuBarTitle(moment, readSnapshot(snapshot()).sessions)
    if (next === title || tray === null) return
    title = next
    tray.setTitle(next)
    // Written down, because nothing outside the menu bar can read it back: the
    // log is how a moment that "never showed" can be told from one that did.
    deps.log?.('menu bar: title', { title: next.trim() })
  }

  function noticeSessions(): void {
    const sessions = readSnapshot(snapshot()).sessions
    const found = tracker.next(sessions, now())
    if (found !== null) {
      moment = found
      cancel('moment')
      timers.moment = deps.schedule(() => {
        timers.moment = null
        moment = null
        retitle()
      }, MOMENT_MS)
    }
    retitle()
  }

  function blink(): void {
    cancel('blink')
    if (tray === null || deps.reducedMotion()) return
    timers.blink = deps.schedule(() => {
      tray?.setFrame('closed')
      timers.blink = deps.schedule(() => {
        tray?.setFrame('open')
        blink()
      }, BLINK_SHUT_MS)
    }, nextBlinkMs())
  }

  /* -- the panel -- */

  function push(): void {
    if (panel === null || panel.isDestroyed() || panel.webContents.isDestroyed()) return
    panel.webContents.send('hoot-panel:snapshot', snapshot())
  }

  function follow(): void {
    const state = hoot()
    const wanted = open && state.status === 'running' && state.sessionId !== null ? state.sessionId : null
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
      deps.log?.('menu bar: could not follow Hoot’s transcript', {
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }

  function ensurePanel(): PanelHandle {
    if (panel !== null && !panel.isDestroyed()) return panel
    const made = deps.makePanel()
    panel = made
    // A click anywhere else, once the panel has the keyboard, is a click outside.
    made.on('blur', () => {
      if (open && !holding) hidePanel()
    })
    made.on('closed', () => {
      if (panel === made) panel = null
      open = false
    })
    return made
  }

  function place(): void {
    if (tray === null || panel === null || panel.isDestroyed()) return
    const icon = tray.getBounds()
    panel.setBounds(panelBounds(icon, deps.workAreaAt({ x: icon.x, y: icon.y }), panelHeight))
  }

  function showPanel(withKeyboard: boolean): void {
    if (tray === null) return
    cancel('open')
    cancel('close')
    const target = ensurePanel()
    hootCache = null
    place()
    if (!open) {
      open = true
      target.showInactive()
      if (!target.webContents.isDestroyed()) target.webContents.send('hoot-panel:shown')
    }
    if (withKeyboard) target.focus()
    follow()
    push()
  }

  function hidePanel(): void {
    cancel('open')
    cancel('close')
    open = false
    pinned = false
    overPanel = false
    holding = false
    if (panel !== null && !panel.isDestroyed()) panel.hide()
    follow()
  }

  /** Close a beat after the pointer has left both the owl and the panel — unless something holds it. */
  function closeSoon(): void {
    cancel('close')
    if (!open) return
    timers.close = deps.schedule(() => {
      timers.close = null
      if (!overIcon && !overPanel && !holding && !pinned) hidePanel()
    }, CLOSE_DELAY_MS)
  }

  function contextMenu(): MenuItemConstructorOptions[] {
    const settings: MenuItemConstructorOptions = {
      label: `${BRAND.assistant} Settings…`,
      click: () => deps.openApp('hoot-settings'),
    }
    const hide: MenuItemConstructorOptions = {
      label: `Hide ${BRAND.assistant} from the Menu Bar`,
      click: () => configure({ enabled: false }),
    }
    if (deps.appMenuItems) return deps.appMenuItems({ afterOpen: [settings], beforeQuit: [hide] })
    return [{ label: `Open ${BRAND.name}`, click: () => deps.openApp() }, settings, { type: 'separator' }, hide]
  }

  function addTray(): void {
    const made = deps.makeTray()
    tray = made
    title = ''
    made.on('mouse-enter', () => {
      overIcon = true
      cancel('close')
      if (!open && timers.open === null) {
        timers.open = deps.schedule(() => {
          timers.open = null
          if (overIcon) showPanel(false)
        }, OPEN_DELAY_MS)
      }
    })
    made.on('mouse-leave', () => {
      overIcon = false
      cancel('open')
      closeSoon()
    })
    made.on('click', () => {
      if (open && pinned) {
        hidePanel()
        return
      }
      pinned = true
      showPanel(true)
    })
    made.on('right-click', () => made.popUpMenu(contextMenu()))
    tracker = new MomentTracker()
    tracker.next(readSnapshot(snapshot()).sessions, now())
    retitle()
    blink()
    deps.log?.('menu bar: owl shown', { bounds: made.getBounds() })
    deps.onShownChanged?.()
  }

  function removeTray(): void {
    hidePanel()
    for (const name of Object.keys(timers) as Array<keyof typeof timers>) cancel(name)
    watching?.stop()
    watching = null
    if (panel !== null && !panel.isDestroyed()) panel.destroy()
    panel = null
    const had = tray !== null
    tray?.destroy()
    tray = null
    moment = null
    title = ''
    if (had) deps.onShownChanged?.()
  }

  function apply(): void {
    const enabled = readMenuBarEnabled(deps.read)
    if (!enabled) {
      if (tray !== null) removeTray()
      return
    }
    if (tray === null) addTray()
  }

  function configure(patch: { enabled?: boolean }): { enabled: boolean } {
    if (typeof patch.enabled === 'boolean') deps.write({ [MENUBAR_KEY]: patch.enabled })
    apply()
    return { enabled: readMenuBarEnabled(deps.read) }
  }

  function forward(channel: string, args: readonly unknown[]): void {
    if (tray === null) return
    if (PASSED_THROUGH.has(channel)) {
      if (panel !== null && !panel.isDestroyed() && !panel.webContents.isDestroyed()) {
        panel.webContents.send(channel, ...args)
      }
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
    return panel !== null && !panel.isDestroyed() && panel.webContents.id === contentsId
  }

  return {
    apply,
    openPanel: () => {
      if (tray === null) return { ok: false, message: `${BRAND.assistant} is not in the menu bar; turn it on in Settings.` }
      pinned = true
      showPanel(true)
      return { ok: true, message: '' }
    },
    forward,
    setLabels: (next) => {
      const clean: Record<string, string> = {}
      for (const [id, label] of Object.entries(next)) {
        if (typeof label === 'string' && label !== '' && label.length <= 200) clean[id] = label
      }
      if (JSON.stringify(clean) === JSON.stringify(labels)) return
      labels = clean
      retitle()
      push()
    },
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
      hidePanel()
      deps.showSession(id)
      return { ok: true }
    },
    pointer: (contentsId, inside) => {
      if (!ours(contentsId)) return
      overPanel = inside
      if (inside) cancel('close')
      else closeSoon()
    },
    held: (contentsId, held) => {
      if (!ours(contentsId)) return
      holding = held
      if (!held) closeSoon()
    },
    focus: (contentsId) => {
      if (!ours(contentsId) || panel === null) return
      panel.focus()
    },
    close: (contentsId) => {
      if (ours(contentsId)) hidePanel()
    },
    size: (contentsId, height) => {
      if (!ours(contentsId) || !Number.isFinite(height)) return
      panelHeight = height
      if (open) place()
    },
    config: () => ({ enabled: readMenuBarEnabled(deps.read) }),
    configure,
    isShowing: () => ({ tray: tray !== null, panel: open, title }),
    dispose: removeTray,
  }
}

/* ---------------------------------------------------------------------- ipc -- */

/**
 * The menu bar's channels. `wireHootMenuBar` registers them.
 *
 * - `hoot-panel:snapshot`     (invoke)        → {@link HootMenuBarSnapshot}; also pushed on every change
 * - `hoot-panel:say`          (invoke, text)  → `{ ok, message }`
 * - `hoot-panel:start-hoot`   (invoke)        → `{ ok, message }`
 * - `hoot-panel:show-session` (invoke, id)    → `{ ok }`
 * - `hoot-menubar:config`     (invoke)        → `{ enabled }`
 * - `hoot-menubar:configure`  (invoke, patch) → `{ enabled }`
 * - `hoot-menubar:open`       (invoke)        → `{ ok, message }` — the panel, pinned, as a click on the owl
 * - `hoot-panel:pointer` / `hoot-panel:held` / `hoot-panel:focus` / `hoot-panel:close` / `hoot-panel:size` (send)
 * - `session:labels`          (send, labels)  — the main window's names for its sessions
 * - `hoot-panel:shown`        (push)          — the panel just opened
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
  const sends = ['hoot-panel:pointer', 'hoot-panel:held', 'hoot-panel:focus', 'hoot-panel:close', 'hoot-panel:size', 'session:labels']
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
  ipcMain.on('hoot-panel:size', (event: IpcMainEvent, height: unknown) => {
    if (typeof height === 'number') bar.size(event.sender.id, height)
  })
  ipcMain.on('session:labels', (_event: IpcMainEvent, labels: unknown) => {
    if (typeof labels === 'object' && labels !== null && !Array.isArray(labels)) {
      bar.setLabels(labels as Record<string, string>)
    }
  })
}

/* ----------------------------------------------------------------- electron -- */

export interface WireHootMenuBarOptions
  extends Omit<HootMenuBarDeps, 'makeTray' | 'makePanel' | 'workAreaAt' | 'reducedMotion' | 'dark' | 'schedule'> {
  ipcMain: IpcMain
  preload: string
  rendererUrl?: string
  rendererFile: string
}

function frameImage(frame: TrayIconFrame): Electron.NativeImage {
  const icon = HOOT_TRAY_ICONS[frame]
  const image = nativeImage.createFromBuffer(Buffer.from(icon.colour1x, 'base64'))
  image.addRepresentation({ scaleFactor: 2, buffer: Buffer.from(icon.colour2x, 'base64') })
  // Colour on purpose, so not a template: see `.harness/tray-icons.mjs`.
  image.setTemplateImage(false)
  return image
}

/** Build the menu bar item on real Electron, register its channels, and show it if the setting says so. */
export function wireHootMenuBar(options: WireHootMenuBarOptions): HootMenuBar {
  const images: Record<TrayIconFrame, Electron.NativeImage> = { open: frameImage('open'), closed: frameImage('closed') }
  const bar = createHootMenuBar({
    ...options,
    makeTray: () => {
      const tray = new Tray(images.open)
      tray.setIgnoreDoubleClickEvents(true)
      return {
        setFrame: (frame) => tray.setImage(images[frame]),
        setTitle: (title) => tray.setTitle(title, { fontType: 'monospacedDigit' }),
        getBounds: () => tray.getBounds(),
        on: (event, listener) => {
          tray.on(event as 'click', listener)
        },
        popUpMenu: (items) => tray.popUpContextMenu(Menu.buildFromTemplate(items)),
        destroy: () => tray.destroy(),
      }
    },
    makePanel: () => {
      const window = new BrowserWindow({
        width: PANEL_WIDTH,
        height: 260,
        // An NSPanel with the non-activating mask: shown over everything, and
        // hovering it or clicking the owl does not bring this app forward.
        type: 'panel',
        frame: false,
        transparent: true,
        backgroundColor: '#00000000',
        // The system's own popover glass behind the page, with its rounded
        // corners and shadow — the same material a menu bar app's panel wears.
        vibrancy: 'popover',
        visualEffectState: 'active',
        roundedCorners: true,
        hasShadow: true,
        resizable: false,
        movable: false,
        minimizable: false,
        maximizable: false,
        fullscreenable: false,
        skipTaskbar: true,
        alwaysOnTop: true,
        show: false,
        title: BRAND.assistant,
        webPreferences: {
          preload: options.preload,
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: false,
        },
      })
      window.setAlwaysOnTop(true, 'pop-up-menu')
      // `skipTransformProcessType`, or macOS hides this app's Dock icon for the
      // instant it takes to apply `visibleOnFullScreen`.
      window.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true })
      window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
      if (options.rendererUrl) {
        const url = new URL(options.rendererUrl)
        url.searchParams.set('hootpanel', '1')
        void window.loadURL(url.toString())
      } else {
        void window.loadFile(options.rendererFile, { query: { hootpanel: '1' } })
      }
      return window
    },
    workAreaAt: (point) => screen.getDisplayNearestPoint(point).workArea,
    dark: () => nativeTheme.shouldUseDarkColors,
    reducedMotion: () => {
      try {
        return systemPreferences.getAnimationSettings().prefersReducedMotion
      } catch {
        return false
      }
    },
    schedule: (run, ms) => {
      const timer = setTimeout(run, ms)
      return { cancel: () => clearTimeout(timer) }
    },
  })
  registerHootMenuBarIpc(options.ipcMain, bar)
  bar.apply()
  return bar
}
