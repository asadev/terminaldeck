import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  BrowserWindow: class {},
  Menu: { buildFromTemplate: (items: unknown) => items },
  screen: {},
}))

const { createHootMenuBar, MENUBAR_KEY, mergeMessages, readMenuBarEnabled, registerHootMenuBarIpc } = await import(
  './hoot-menubar'
)
type Deps = Parameters<typeof createHootMenuBar>[0]

describe('the setting', () => {
  it('is on unless somebody turned it off', () => {
    expect(readMenuBarEnabled(() => undefined)).toBe(true)
    expect(readMenuBarEnabled((key) => (key === MENUBAR_KEY ? false : undefined))).toBe(false)
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

/** His Mac mini's main display: 1920 wide, a 30-point menu bar, no notch. */
const DISPLAY = { x: 0, y: 0, width: 1920, height: 1080 }

class FakeIsland {
  readonly sent: Array<{ channel: string; args: unknown[] }> = []
  readonly webContents = {
    id: 42,
    send: (channel: string, ...args: unknown[]) => this.sent.push({ channel, args }),
    isDestroyed: () => this.destroyed,
  }
  destroyed = false
  visible = false
  focused = 0
  blurred = 0
  /** Every setIgnoreMouseEvents, in order. */
  ignoring: boolean[] = []
  menus: unknown[] = []
  bounds = { x: 0, y: 0, width: 0, height: 0 }
  private listeners = new Map<string, () => void>()
  isDestroyed = (): boolean => this.destroyed
  isVisible = (): boolean => this.visible
  setBounds = (bounds: FakeIsland['bounds']): void => {
    this.bounds = bounds
  }
  getBounds = (): FakeIsland['bounds'] => this.bounds
  showInactive = (): void => {
    this.visible = true
  }
  focus = (): void => {
    this.focused += 1
    this.emit('focus')
  }
  blur = (): void => {
    this.blurred += 1
    this.emit('blur')
  }
  destroy = (): void => {
    this.destroyed = true
  }
  setIgnoreMouseEvents = (ignore: boolean): void => {
    this.ignoring.push(ignore)
  }
  popUpMenu = (items: unknown[]): void => {
    this.menus.push(items)
  }
  on(event: string, listener: () => void): void {
    this.listeners.set(event, listener)
  }
  emit(event: string): void {
    this.listeners.get(event)?.()
  }
  /** The last snapshot pushed to the page. */
  last(): { expanded: boolean; label: { text: string; attention: boolean } } | undefined {
    return this.sent.filter((m) => m.channel === 'hoot-panel:snapshot').at(-1)?.args[0] as never
  }
}

/** Timers run by hand: `advance(ms)` fires everything due within that much time. */
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

function rig(
  options: {
    hoot?: 'running' | 'stopped'
    store?: Record<string, unknown>
    notch?: { left: number; width: number; height: number } | null
    display?: { x: number; y: number; width: number; height: number }
    supported?: boolean
  } = {},
) {
  const islands: FakeIsland[] = []
  const said: Array<{ sessionId: string; text: string }> = []
  const shown: string[] = []
  const opened: Array<string | undefined> = []
  const store: Record<string, unknown> = { ...(options.store ?? {}) }
  const time = clock()
  let hootStatus = options.hoot ?? 'running'
  const watched: Array<{ cwd: string; agentSessionId: string | null }> = []
  let chat: ((update: { messages: never[]; reset: boolean }) => void) | null = null
  let stops = 0
  let hootStops = 0
  const place = {
    display: options.display ?? DISPLAY,
    barHeight: options.notch?.height ?? 30,
    notch: options.notch ?? null,
  }
  const sessions = [
    { id: 'hoot-1', title: 'copilot', status: 'working' },
    { id: 's1', title: 'api', status: 'working' },
    { id: 's2', title: 'web', status: 'idle' },
  ]
  const deps: Deps = {
    makeIsland: () => {
      const island = new FakeIsland()
      islands.push(island)
      return island
    },
    place: () => place,
    supported: options.supported,
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
    stopHoot: () => {
      hootStops += 1
      hootStatus = 'stopped'
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
    schedule: time.schedule,
    now: time.now,
  }
  const bar = createHootMenuBar(deps)
  return {
    bar,
    deps,
    islands,
    place,
    said,
    shown,
    opened,
    store,
    sessions,
    time,
    watched,
    stops: () => stops,
    hootStops: () => hootStops,
    chat: (messages: Array<{ id: string; role: 'you' | 'agent'; text: string; at: number }>) =>
      chat?.({ messages: messages as never[], reset: false }),
  }
}

/* ------------------------------------------------------------ the island -- */

describe('where the island is', () => {
  it('appears once the page says what size its pill is: centred, its top on the top edge of the screen', () => {
    const r = rig()
    r.bar.apply()
    expect(r.islands).toHaveLength(1)
    expect(r.islands[0].visible).toBe(false)
    r.bar.size(42, { width: 86, height: 30 })
    expect(r.islands[0].visible).toBe(true)
    expect(r.islands[0].bounds).toEqual({ x: 917, y: 0, width: 86, height: 30 })
  })

  it('centres on the notch on a MacBook, and on a display that is not the first one', () => {
    const r = rig({ display: { x: -1512, y: 0, width: 1512, height: 982 }, notch: { left: 656, width: 200, height: 32 } })
    r.bar.apply()
    r.bar.size(42, { width: 300, height: 32 })
    const b = r.islands[0].bounds
    expect(b.y).toBe(0)
    expect(b.x + b.width / 2).toBe(-1512 + 656 + 100)
    expect(r.bar.snapshot().geometry).toEqual({ barHeight: 32, displayWidth: 1512, notch: { left: 656, width: 200, height: 32 } })
  })

  it('is placed again when a display changes, and tells the page the new shape of things', () => {
    const r = rig()
    r.bar.apply()
    r.bar.size(42, { width: 86, height: 30 })
    r.place.display = { x: 0, y: 0, width: 2560, height: 1440 }
    r.bar.displaysChanged()
    expect(r.islands[0].bounds.x).toBe(1280 - 43)
    expect((r.islands[0].sent.at(-1)?.args[0] as { geometry: { displayWidth: number } }).geometry.displayWidth).toBe(2560)
  })

  it('takes no size the page cannot mean, and listens to its own page only', () => {
    const r = rig()
    r.bar.apply()
    r.bar.size(42, { width: Number.NaN, height: 30 })
    r.bar.size(7, { width: 86, height: 30 })
    expect(r.islands[0].visible).toBe(false)
    r.bar.size(42, { width: 5000, height: 5000 })
    expect(r.islands[0].bounds.width).toBe(1920)
    expect(r.islands[0].bounds.height).toBeLessThanOrEqual(360)
  })

  it('is not there when the setting is off, and goes and comes back with it', () => {
    const r = rig({ store: { [MENUBAR_KEY]: false } })
    r.bar.apply()
    expect(r.islands).toHaveLength(0)
    expect(r.bar.configure({ enabled: true })).toEqual({ enabled: true })
    expect(r.islands).toHaveLength(1)
    r.bar.configure({ enabled: false })
    expect(r.islands[0].destroyed).toBe(true)
    expect(r.store[MENUBAR_KEY]).toBe(false)
    expect(r.bar.isShowing().island).toBe(false)
  })

  it('is a Mac thing: nothing appears where there is no menu bar to live in', () => {
    const r = rig({ supported: false })
    r.bar.apply()
    expect(r.islands).toHaveLength(0)
  })
})

describe('what the resting pill says', () => {
  it('the name when all is quiet, and how many are working otherwise', () => {
    const r = rig()
    r.sessions[1].status = 'idle'
    r.bar.apply()
    expect(r.bar.snapshot().label).toEqual({ text: 'Hoot', attention: false })
    r.sessions[1].status = 'working'
    expect(r.bar.snapshot().label).toEqual({ text: '1 working', attention: false })
  })

  it('widens to the whole sentence for a moment, then settles to a compact "Needs you" with the dot', () => {
    const r = rig()
    r.bar.apply()
    r.bar.setLabels({ s1: 'Session 1', s2: 'Session 2' })
    r.sessions[2].status = 'input'
    r.bar.forward('session:status', ['s2', 'input'])
    r.time.advance(100)
    expect(r.islands[0].last()?.label).toEqual({ text: 'Session 2 needs you', attention: true })
    r.time.advance(4000)
    expect(r.islands[0].last()?.label).toEqual({ text: 'Needs you', attention: true })
  })

  it('says a session finished for a moment, then goes back to what it said', () => {
    const r = rig()
    r.bar.apply()
    r.bar.setLabels({ s1: 'Session 1', s2: 'Session 2' })
    r.sessions[1].status = 'completed'
    r.bar.forward('session:status', ['s1', 'completed'])
    r.time.advance(100)
    expect(r.islands[0].last()?.label.text).toBe('Session 1 finished')
    r.time.advance(4000)
    expect(r.islands[0].last()?.label.text).toBe('Hoot')
  })

  it('never grows or takes the keyboard for a moment', () => {
    const r = rig()
    r.bar.apply()
    r.sessions[2].status = 'input'
    r.bar.forward('session:status', ['s2', 'input'])
    r.time.advance(100)
    expect(r.islands[0].last()?.expanded).toBe(false)
    expect(r.islands[0].focused).toBe(0)
  })
})

/* ------------------------------------------------------- growing and back -- */

describe('growing into the panel and settling back', () => {
  it('grows a moment after the pointer rests on it — without the keyboard — and not on a pass', () => {
    const r = rig()
    r.bar.apply()
    r.bar.pointer(42, true)
    r.bar.pointer(42, false)
    r.time.advance(400)
    expect(r.bar.isShowing().expanded).toBe(false)
    r.bar.pointer(42, true)
    r.time.advance(200)
    expect(r.bar.isShowing().expanded).toBe(true)
    expect(r.islands[0].last()?.expanded).toBe(true)
    expect(r.islands[0].focused).toBe(0)
  })

  it('lets clicks through the margin around the grown shape, and takes them again on the shape', () => {
    const r = rig()
    r.bar.apply()
    r.bar.pointer(42, true)
    r.time.advance(200)
    r.bar.pointer(42, false)
    expect(r.islands[0].ignoring.at(-1)).toBe(true)
    r.bar.pointer(42, true)
    expect(r.islands[0].ignoring.at(-1)).toBe(false)
    expect(r.bar.isShowing().expanded).toBe(true)
  })

  it('settles a moment after the pointer has left the shape, and then takes every click again', () => {
    const r = rig()
    r.bar.apply()
    r.bar.pointer(42, true)
    r.time.advance(200)
    r.bar.pointer(42, false)
    r.time.advance(300)
    expect(r.bar.isShowing().expanded).toBe(true)
    r.time.advance(300)
    expect(r.bar.isShowing().expanded).toBe(false)
    expect(r.islands[0].last()?.expanded).toBe(false)
    expect(r.islands[0].ignoring.at(-1)).toBe(false)
  })

  it('stays grown while the box has text or the keyboard', () => {
    const r = rig()
    r.bar.apply()
    r.bar.pointer(42, true)
    r.time.advance(200)
    r.bar.held(42, true)
    r.bar.pointer(42, false)
    r.time.advance(2000)
    expect(r.bar.isShowing().expanded).toBe(true)
    r.bar.held(42, false)
    r.time.advance(600)
    expect(r.bar.isShowing().expanded).toBe(false)
  })

  it('grows on a press and hands it the keyboard, pinned; a click elsewhere settles it, and so does Escape', () => {
    const r = rig()
    r.bar.apply()
    r.bar.focus(42)
    expect(r.bar.isShowing().expanded).toBe(true)
    expect(r.islands[0].focused).toBe(1)
    r.bar.pointer(42, false)
    r.time.advance(2000)
    expect(r.bar.isShowing().expanded).toBe(true)
    r.islands[0].emit('blur')
    expect(r.bar.isShowing().expanded).toBe(false)
    r.bar.focus(42)
    r.bar.close(42)
    expect(r.bar.isShowing().expanded).toBe(false)
    // Escape gives the keyboard back to whatever had it.
    expect(r.islands[0].blurred).toBe(1)
  })

  it('grows from the keyboard (the palette, a tool) exactly as a press on it does', () => {
    const r = rig()
    expect(r.bar.openPanel().ok).toBe(false)
    r.bar.apply()
    expect(r.bar.openPanel()).toEqual({ ok: true, message: '' })
    expect(r.bar.isShowing().expanded).toBe(true)
    expect(r.islands[0].focused).toBe(1)
  })

  it('brings a session to the front in the app, and settles', () => {
    const r = rig()
    r.bar.apply()
    r.bar.focus(42)
    expect(r.bar.showSession('s2')).toEqual({ ok: true })
    expect(r.bar.showSession('hoot-1')).toEqual({ ok: false })
    expect(r.shown).toEqual(['s2'])
    expect(r.bar.isShowing().expanded).toBe(false)
  })

  it('opens the app, or Hoot’s settings in it, from the panel', () => {
    const r = rig()
    r.bar.apply()
    r.bar.focus(42)
    r.bar.openApp('hoot-settings')
    r.bar.openApp()
    expect(r.opened).toEqual(['hoot-settings', undefined])
    expect(r.bar.isShowing().expanded).toBe(false)
  })
})

describe('the right-click menu — the island is the app’s one presence at the top of the screen', () => {
  it('offers to open the app, Hoot’s settings, or to hide it', () => {
    const r = rig()
    r.bar.apply()
    r.bar.menu(42)
    const items = r.islands[0].menus[0] as Array<{ label?: string; click?: () => void }>
    expect(items.map((item) => item.label).filter(Boolean)).toEqual([
      'Open Terminal Deck',
      'Hoot Settings…',
      'Hide Hoot from the Top of the Screen',
    ])
    items[1].click?.()
    expect(r.opened).toEqual(['hoot-settings'])
    items[3].click?.()
    expect(r.islands[0].destroyed).toBe(true)
  })

  it('carries the app’s background menu when one is given, and says when it comes and goes', () => {
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
    expect(bar.isShowing().island).toBe(true)
    bar.menu(42)
    const items = r.islands.at(-1)?.menus[0] as Array<{ label?: string }>
    expect(items.map((item) => item.label)).toEqual([
      'Open Terminal Deck',
      'Hoot Settings…',
      'Claude Code — api',
      'Hide Hoot from the Top of the Screen',
      'Quit and Stop All Sessions',
    ])
    bar.configure({ enabled: false })
    expect(shownChanged).toHaveLength(2)
  })
})

describe('talking to Hoot', () => {
  it('types into the Hoot that is running — never a second one', async () => {
    const r = rig()
    r.bar.apply()
    expect(await r.bar.say('  Which sessions are working?  ')).toEqual({ ok: true, message: '' })
    expect(r.said).toEqual([{ sessionId: 'hoot-1', text: 'Which sessions are working?' }])
  })

  it('says in one line when Hoot is not running, starts it on request, and stops it', async () => {
    const r = rig({ hoot: 'stopped' })
    r.bar.apply()
    expect(await r.bar.say('hello')).toEqual({ ok: false, message: 'Hoot isn’t running.' })
    expect(await r.bar.startHoot()).toEqual({ ok: true, message: '' })
    expect(r.bar.snapshot().hoot.status).toBe('running')
    expect(r.bar.stopHoot()).toEqual({ ok: true, message: '' })
    expect(r.hootStops()).toBe(1)
    expect(r.bar.snapshot().hoot.status).toBe('stopped')
  })

  it('reads the replies off Hoot’s own transcript while grown, and stops when it settles', () => {
    const r = rig()
    r.bar.apply()
    r.bar.focus(42)
    expect(r.watched).toEqual([{ cwd: '/copilot', agentSessionId: 'agent-1' }])
    r.chat([{ id: 'm1', role: 'agent', text: 'Session 1 is running the tests.', at: 1 }])
    const last = r.islands[0].sent.filter((m) => m.channel === 'hoot-panel:snapshot').at(-1)
    expect((last?.args[0] as { messages: Array<{ text: string }> }).messages.map((m) => m.text)).toEqual([
      'Session 1 is running the tests.',
    ])
    r.bar.close(42)
    expect(r.stops()).toBe(1)
  })

  it('leaves Hoot’s own session out of the list and names the rest as the main window does', () => {
    const r = rig()
    r.bar.apply()
    r.bar.setLabels({ s1: 'Session 1', s2: 'Session 2' })
    expect(r.bar.snapshot().sessions.map((x) => x.label)).toEqual(['Session 1', 'Session 2'])
  })
})

describe('the channels', () => {
  it('registers every one, and listens to the island’s page and nobody else', async () => {
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
      'hoot-panel:open-app',
      'hoot-panel:say',
      'hoot-panel:show-session',
      'hoot-panel:snapshot',
      'hoot-panel:start-hoot',
      'hoot-panel:stop-hoot',
    ])
    expect([...listeners.keys()].sort()).toEqual([
      'hoot-panel:close',
      'hoot-panel:focus',
      'hoot-panel:held',
      'hoot-panel:menu',
      'hoot-panel:pointer',
      'hoot-panel:size',
      'session:labels',
    ])
    await handlers.get('hoot-panel:say')?.({}, 'hi Hoot')
    expect(r.said.at(-1)).toEqual({ sessionId: 'hoot-1', text: 'hi Hoot' })
    listeners.get('hoot-panel:size')?.({ sender: { id: 42 } }, { width: 90, height: 30 })
    expect(r.islands[0].bounds).toEqual({ x: 915, y: 0, width: 90, height: 30 })
    listeners.get('hoot-panel:focus')?.({ sender: { id: 42 } })
    listeners.get('hoot-panel:close')?.({ sender: { id: 7 } })
    expect(r.bar.isShowing().expanded).toBe(true)
    listeners.get('hoot-panel:close')?.({ sender: { id: 42 } })
    expect(r.bar.isShowing().expanded).toBe(false)
  })
})
