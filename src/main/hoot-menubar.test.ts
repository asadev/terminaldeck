import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  BrowserWindow: class {},
  Menu: { buildFromTemplate: (items: unknown) => items },
  nativeImage: {},
  nativeTheme: {},
  screen: {},
  systemPreferences: {},
  Tray: class {},
}))

const { createHootMenuBar, MENUBAR_KEY, mergeMessages, nextBlinkMs, panelBounds, readMenuBarEnabled, registerHootMenuBarIpc, PANEL_WIDTH } =
  await import('./hoot-menubar')
type Deps = Parameters<typeof createHootMenuBar>[0]

/* ----------------------------------------------------------------- geometry -- */

const WORK = { x: 0, y: 30, width: 1920, height: 1050 }

describe('where the panel opens', () => {
  it('just under the owl, centred on it', () => {
    const icon = { x: 900, y: 3, width: 24, height: 24 }
    const bounds = panelBounds(icon, WORK, 300)
    expect(bounds.y).toBe(32)
    expect(bounds.x + bounds.width / 2).toBe(912)
    expect(bounds.width).toBe(PANEL_WIDTH)
  })

  it('stops at the edge of the screen for an owl near the right-hand corner, where most menu bar items are', () => {
    const icon = { x: 1880, y: 3, width: 24, height: 24 }
    const bounds = panelBounds(icon, WORK, 300)
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(1920)
  })

  it('keeps to a sensible height whatever the page reports', () => {
    const icon = { x: 900, y: 3, width: 24, height: 24 }
    expect(panelBounds(icon, WORK, 20).height).toBe(120)
    expect(panelBounds(icon, WORK, 4000).height).toBe(520)
  })
})

describe('the setting and the blink', () => {
  it('is on unless somebody turned it off', () => {
    expect(readMenuBarEnabled(() => undefined)).toBe(true)
    expect(readMenuBarEnabled((key) => (key === MENUBAR_KEY ? false : undefined))).toBe(false)
  })

  it('blinks every six and a half to ten seconds, never on a fixed beat', () => {
    expect(nextBlinkMs(() => 0)).toBe(6500)
    expect(nextBlinkMs(() => 1)).toBe(10000)
  })

  it('keeps the last few messages, replacing one that grew', () => {
    const a = { id: 'a', role: 'agent' as const, text: 'Work', at: 1 }
    const grown = mergeMessages(mergeMessages([], { messages: [a], reset: false }), {
      messages: [{ ...a, text: 'Working.' }],
      reset: false,
    })
    expect(grown).toEqual([{ ...a, text: 'Working.' }])
  })
})

/* ---------------------------------------------------------------- the rig -- */

class FakeTray {
  frames: string[] = []
  titles: string[] = []
  menus: unknown[] = []
  destroyed = false
  private listeners = new Map<string, () => void>()
  setFrame = (frame: string): void => {
    this.frames.push(frame)
  }
  setTitle = (title: string): void => {
    this.titles.push(title)
  }
  getBounds = () => ({ x: 1700, y: 3, width: 24, height: 24 })
  on(event: string, listener: () => void): void {
    this.listeners.set(event, listener)
  }
  emit(event: string): void {
    this.listeners.get(event)?.()
  }
  popUpMenu = (items: unknown[]): void => {
    this.menus.push(items)
  }
  destroy = (): void => {
    this.destroyed = true
  }
}

class FakePanel {
  readonly sent: Array<{ channel: string; args: unknown[] }> = []
  readonly webContents = {
    id: 42,
    send: (channel: string, ...args: unknown[]) => this.sent.push({ channel, args }),
    isDestroyed: () => this.destroyed,
  }
  destroyed = false
  visible = false
  focused = 0
  bounds = { x: 0, y: 0, width: 0, height: 0 }
  private listeners = new Map<string, () => void>()
  isDestroyed = (): boolean => this.destroyed
  isVisible = (): boolean => this.visible
  setBounds = (bounds: FakePanel['bounds']): void => {
    this.bounds = bounds
  }
  getBounds = (): FakePanel['bounds'] => this.bounds
  showInactive = (): void => {
    this.visible = true
  }
  hide = (): void => {
    this.visible = false
  }
  focus = (): void => {
    this.focused += 1
  }
  destroy = (): void => {
    this.destroyed = true
  }
  on(event: string, listener: () => void): void {
    this.listeners.set(event, listener)
  }
  emit(event: string): void {
    this.listeners.get(event)?.()
  }
}

/** Timers run by hand: `run(ms)` fires everything due within that much time. */
function clock() {
  let now = 0
  const queue: Array<{ at: number; run: () => void; live: boolean }> = []
  return {
    now: () => now,
    schedule: (run: () => void, ms: number) => {
      const job = { at: now + ms, run, live: true }
      queue.push(job)
      return { cancel: () => void (job.live = false) }
    },
    advance(ms: number) {
      const end = now + ms
      for (;;) {
        const due = queue.filter((j) => j.live && j.at <= end).sort((a, b) => a.at - b.at)[0]
        if (!due) break
        due.live = false
        now = due.at
        due.run()
      }
      now = end
    },
  }
}

function rig(options: { hoot?: 'running' | 'stopped'; store?: Record<string, unknown>; reducedMotion?: boolean } = {}) {
  const trays: FakeTray[] = []
  const panels: FakePanel[] = []
  const said: Array<{ sessionId: string; text: string }> = []
  const shown: string[] = []
  const opened: Array<string | undefined> = []
  const store: Record<string, unknown> = { ...(options.store ?? {}) }
  const time = clock()
  let hootStatus = options.hoot ?? 'running'
  const watched: Array<{ cwd: string; agentSessionId: string | null }> = []
  let chat: ((update: { messages: never[]; reset: boolean }) => void) | null = null
  let stops = 0
  const sessions = [
    { id: 'hoot-1', title: 'copilot', status: 'working' },
    { id: 's1', title: 'api', status: 'working' },
    { id: 's2', title: 'web', status: 'idle' },
  ]
  const deps: Deps = {
    makeTray: () => {
      const tray = new FakeTray()
      trays.push(tray)
      return tray
    },
    makePanel: () => {
      const panel = new FakePanel()
      panels.push(panel)
      return panel
    },
    workAreaAt: () => WORK,
    read: (key) => store[key],
    write: (patch) => Object.assign(store, patch),
    hoot: () =>
      hootStatus === 'running'
        ? { status: 'running', problem: null, sessionId: 'hoot-1', cwd: '/copilot', agentSessionId: 'agent-1' }
        : { status: 'stopped', problem: null, sessionId: null, cwd: '/copilot', agentSessionId: null },
    startHoot: async () => {
      hootStatus = 'running'
      return { problem: null }
    },
    say: (sessionId, text) => said.push({ sessionId, text }),
    watchChat: (cwd, agentSessionId, onUpdate) => {
      watched.push({ cwd, agentSessionId })
      chat = onUpdate as typeof chat
      return () => {
        stops += 1
      }
    },
    sessions: () => sessions,
    showSession: (id) => shown.push(id),
    openApp: (page) => opened.push(page),
    reducedMotion: () => options.reducedMotion === true,
    dark: () => true,
    schedule: time.schedule,
    now: time.now,
  }
  const bar = createHootMenuBar(deps)
  return {
    bar,
    deps,
    trays,
    panels,
    said,
    shown,
    opened,
    store,
    sessions,
    time,
    watched,
    stops: () => stops,
    chat: (messages: Array<{ id: string; role: 'you' | 'agent'; text: string; at: number }>) =>
      chat?.({ messages: messages as never[], reset: false }),
  }
}

/* -------------------------------------------------------------- the owl -- */

describe('the owl in the menu bar', () => {
  it('is there by default, with no title while nothing needs him', () => {
    const r = rig()
    r.bar.apply()
    expect(r.trays).toHaveLength(1)
    expect(r.bar.isShowing().title).toBe('')
    expect(r.panels).toHaveLength(0)
  })

  it('is not there when the setting is off, and goes and comes back with it', () => {
    const r = rig({ store: { [MENUBAR_KEY]: false } })
    r.bar.apply()
    expect(r.trays).toHaveLength(0)
    expect(r.bar.configure({ enabled: true })).toEqual({ enabled: true })
    expect(r.trays).toHaveLength(1)
    r.bar.configure({ enabled: false })
    expect(r.trays[0].destroyed).toBe(true)
    expect(r.store[MENUBAR_KEY]).toBe(false)
  })

  it('blinks now and then, and not at all when the Mac is set to reduce motion', () => {
    const r = rig()
    r.bar.apply()
    r.time.advance(10_200)
    expect(r.trays[0].frames).toEqual(['closed', 'open'])
    const still = rig({ reducedMotion: true })
    still.bar.apply()
    still.time.advance(30_000)
    expect(still.trays[0].frames).toEqual([])
  })
})

describe('a moment', () => {
  it('says "Session 2 needs you" beside the owl for a few seconds, then settles to the count waiting', () => {
    const r = rig()
    r.bar.apply()
    r.bar.setLabels({ s1: 'Session 1', s2: 'Session 2' })
    r.sessions[2].status = 'input'
    r.bar.forward('session:status', ['s2', 'input'])
    r.time.advance(100)
    expect(r.bar.isShowing().title).toBe(' Session 2 needs you')
    r.time.advance(4100)
    expect(r.bar.isShowing().title).toBe(' 1')
    r.sessions[2].status = 'waiting'
    r.bar.forward('session:status', ['s2', 'waiting'])
    r.time.advance(100)
    expect(r.bar.isShowing().title).toBe('')
  })

  it('never takes the keyboard or opens the panel for a moment', () => {
    const r = rig()
    r.bar.apply()
    r.sessions[2].status = 'input'
    r.bar.forward('session:status', ['s2', 'input'])
    r.time.advance(100)
    expect(r.panels).toHaveLength(0)
  })
})

/* ------------------------------------------------------------ the panel -- */

describe('the panel under the owl', () => {
  it('opens a moment after the pointer rests on the owl — without the keyboard — and not on a pass', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('mouse-enter')
    r.trays[0].emit('mouse-leave')
    r.time.advance(400)
    expect(r.panels).toHaveLength(0)
    r.trays[0].emit('mouse-enter')
    r.time.advance(200)
    expect(r.panels[0].visible).toBe(true)
    expect(r.panels[0].focused).toBe(0)
    expect(r.panels[0].bounds.y).toBe(32)
  })

  it('closes after the pointer has left both the owl and the panel', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('mouse-enter')
    r.time.advance(200)
    r.trays[0].emit('mouse-leave')
    r.bar.pointer(42, true)
    r.time.advance(1000)
    expect(r.panels[0].visible).toBe(true)
    r.bar.pointer(42, false)
    r.time.advance(600)
    expect(r.panels[0].visible).toBe(false)
  })

  it('stays while the box has text or the keyboard', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('mouse-enter')
    r.time.advance(200)
    r.bar.held(42, true)
    r.trays[0].emit('mouse-leave')
    r.time.advance(2000)
    expect(r.panels[0].visible).toBe(true)
    r.bar.held(42, false)
    r.time.advance(600)
    expect(r.panels[0].visible).toBe(false)
  })

  it('opens on a click and hands it the keyboard; a click outside then closes it, and so does Escape', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('click')
    expect(r.panels[0].visible).toBe(true)
    expect(r.panels[0].focused).toBe(1)
    r.trays[0].emit('mouse-leave')
    r.time.advance(2000)
    expect(r.panels[0].visible).toBe(true)
    r.panels[0].emit('blur')
    expect(r.panels[0].visible).toBe(false)
    r.trays[0].emit('click')
    r.bar.close(42)
    expect(r.panels[0].visible).toBe(false)
  })

  it('opens from the keyboard (the palette, a tool) exactly as a click on the owl does', () => {
    const r = rig()
    expect(r.bar.openPanel().ok).toBe(false)
    r.bar.apply()
    expect(r.bar.openPanel()).toEqual({ ok: true, message: '' })
    expect(r.panels[0].visible).toBe(true)
    expect(r.panels[0].focused).toBe(1)
  })

  it('a second click on the owl closes a panel the first click pinned', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('click')
    r.trays[0].emit('click')
    expect(r.panels[0].visible).toBe(false)
  })

  it('offers to open the app, Hoot’s settings, or to leave the menu bar, on a right-click', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('right-click')
    const items = r.trays[0].menus[0] as Array<{ label?: string; click?: () => void }>
    expect(items.map((item) => item.label).filter(Boolean)).toEqual([
      'Open Terminal Deck',
      'Hoot Settings…',
      'Hide Hoot from the Menu Bar',
    ])
    items[1].click?.()
    expect(r.opened).toEqual(['hoot-settings'])
    items[3].click?.()
    expect(r.trays[0].destroyed).toBe(true)
  })

  it('carries the app’s background menu when one is given — the owl is the app’s one menu bar icon', () => {
    const r = rig()
    const shownChanged: number[] = []
    const bar = createHootMenuBar({
      ...r.deps,
      appMenuItems: (extras) => [
        { label: 'Open Terminal Deck' },
        ...extras.afterOpen,
        { label: 'Claude Code — api' },
        ...extras.beforeQuit,
        { label: 'Quit and Stop All Sessions' },
      ],
      onShownChanged: () => shownChanged.push(1),
    })
    bar.apply()
    expect(shownChanged).toHaveLength(1)
    r.trays.at(-1)?.emit('right-click')
    const items = r.trays.at(-1)?.menus[0] as Array<{ label?: string }>
    expect(items.map((item) => item.label)).toEqual([
      'Open Terminal Deck',
      'Hoot Settings…',
      'Claude Code — api',
      'Hide Hoot from the Menu Bar',
      'Quit and Stop All Sessions',
    ])
    bar.configure({ enabled: false })
    expect(shownChanged).toHaveLength(2)
  })

  it('brings a waiting session to the front in the app and closes', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('click')
    expect(r.bar.showSession('s2')).toEqual({ ok: true })
    expect(r.bar.showSession('hoot-1')).toEqual({ ok: false })
    expect(r.shown).toEqual(['s2'])
    expect(r.panels[0].visible).toBe(false)
  })
})

describe('talking to Hoot', () => {
  it('types into the Hoot that is running — never a second one', async () => {
    const r = rig()
    r.bar.apply()
    expect(await r.bar.say('  Which sessions are working?  ')).toEqual({ ok: true, message: '' })
    expect(r.said).toEqual([{ sessionId: 'hoot-1', text: 'Which sessions are working?' }])
  })

  it('says in one line when Hoot is not running, and starts it on request', async () => {
    const r = rig({ hoot: 'stopped' })
    r.bar.apply()
    expect(await r.bar.say('hello')).toEqual({ ok: false, message: 'Hoot isn’t running.' })
    expect(await r.bar.startHoot()).toEqual({ ok: true, message: '' })
    expect(r.bar.snapshot().hoot.status).toBe('running')
  })

  it('reads the replies off Hoot’s own transcript while the panel is open, and stops when it closes', () => {
    const r = rig()
    r.bar.apply()
    r.trays[0].emit('click')
    expect(r.watched).toEqual([{ cwd: '/copilot', agentSessionId: 'agent-1' }])
    r.chat([{ id: 'm1', role: 'agent', text: 'Session 1 is running the tests.', at: 1 }])
    const last = r.panels[0].sent.filter((m) => m.channel === 'hoot-panel:snapshot').at(-1)
    expect((last?.args[0] as { messages: Array<{ text: string }> }).messages.map((m) => m.text)).toEqual([
      'Session 1 is running the tests.',
    ])
    r.bar.close(42)
    expect(r.stops()).toBe(1)
  })

  it('tells the panel whether its glass is light or dark, so its words stay readable on it', () => {
    const r = rig()
    r.bar.apply()
    expect(r.bar.snapshot().appearance).toBe('dark')
  })

  it('leaves Hoot’s own session out of the list and names the rest as the main window does', () => {
    const r = rig()
    r.bar.apply()
    r.bar.setLabels({ s1: 'Session 1', s2: 'Session 2' })
    expect(r.bar.snapshot().sessions.map((x) => x.label)).toEqual(['Session 1', 'Session 2'])
  })
})

describe('the channels', () => {
  it('registers every one, and listens to the panel’s page and nobody else', async () => {
    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    const listeners = new Map<string, (...args: unknown[]) => unknown>()
    const ipc = {
      handle: (channel: string, fn: (...args: unknown[]) => unknown) => handlers.set(channel, fn),
      removeHandler: () => undefined,
      on: (channel: string, fn: (...args: unknown[]) => unknown) => listeners.set(channel, fn),
      removeAllListeners: () => undefined,
    } as unknown as IpcMain
    const r = rig()
    r.bar.apply()
    registerHootMenuBarIpc(ipc, r.bar)
    expect([...handlers.keys()].sort()).toEqual([
      'hoot-menubar:config',
      'hoot-menubar:configure',
      'hoot-menubar:open',
      'hoot-panel:say',
      'hoot-panel:show-session',
      'hoot-panel:snapshot',
      'hoot-panel:start-hoot',
    ])
    expect([...listeners.keys()].sort()).toEqual([
      'hoot-panel:close',
      'hoot-panel:focus',
      'hoot-panel:held',
      'hoot-panel:pointer',
      'hoot-panel:size',
      'session:labels',
    ])
    await handlers.get('hoot-panel:say')?.({}, 'hi Hoot')
    expect(r.said.at(-1)).toEqual({ sessionId: 'hoot-1', text: 'hi Hoot' })
    r.trays[0].emit('click')
    listeners.get('hoot-panel:close')?.({ sender: { id: 7 } })
    expect(r.panels[0].visible).toBe(true)
    listeners.get('hoot-panel:close')?.({ sender: { id: 42 } })
    expect(r.panels[0].visible).toBe(false)
  })
})
