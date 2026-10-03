import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ BrowserWindow: class {}, screen: {} }))

const {
  createPopoutRegistry,
  registerPopoutIpc,
  MAIN_COMMANDS,
} = await import('./popout-windows')
type Registry = ReturnType<typeof createPopoutRegistry>
type Deps = Parameters<typeof createPopoutRegistry>[0]
type Handle = ReturnType<Deps['makeWindow']>
import type { DisplayInfo, Rect } from './popout-placement'

/* ----------------------------------------------------------------- fakes -- */

const LAPTOP: DisplayInfo = {
  id: 1,
  bounds: { x: 0, y: 0, width: 1512, height: 982 },
  workArea: { x: 0, y: 38, width: 1512, height: 944 },
  label: 'Built-in Retina Display',
}
const MONITOR: DisplayInfo = {
  id: 7,
  bounds: { x: 1512, y: 0, width: 2560, height: 1440 },
  workArea: { x: 1512, y: 25, width: 2560, height: 1415 },
  label: 'DELL U2723QE',
}

let nextId = 100

/** A window that behaves the way Electron's does for the events this module listens to. */
class FakeWindow implements Handle {
  readonly id = nextId++
  readonly sent: Array<{ channel: string; args: unknown[] }> = []
  readonly webContents = {
    id: this.id + 1000,
    send: (channel: string, ...args: unknown[]) => {
      this.sent.push({ channel, args })
    },
    isDestroyed: () => this.destroyed,
  }
  title: string
  bounds: Rect
  destroyed = false
  focused = false
  fullScreen = false
  minimized = false
  private listeners = new Map<string, Array<() => void>>()

  constructor(input: { bounds: Rect; title: string }) {
    this.bounds = { ...input.bounds }
    this.title = input.title
  }
  getBounds = (): Rect => ({ ...this.bounds })
  getNormalBounds = (): Rect => ({ ...this.bounds })
  isFullScreen = (): boolean => this.fullScreen
  isMinimized = (): boolean => this.minimized
  isFocused = (): boolean => this.focused
  isDestroyed = (): boolean => this.destroyed
  setTitle = (title: string): void => {
    this.title = title
  }
  setFullScreen = (on: boolean): void => {
    this.fullScreen = on
  }
  restore = (): void => {
    this.minimized = false
  }
  show = (): void => undefined
  focus = (): void => {
    this.focused = true
  }
  on(event: string, listener: () => void): void {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), listener])
  }
  emit(event: string): void {
    for (const listener of this.listeners.get(event) ?? []) listener()
  }
  /** What the red button does: `close`, then `closed`, then gone. */
  close = (): void => {
    if (this.destroyed) return
    this.emit('close')
    this.destroyed = true
    this.emit('closed')
  }
  moveTo(bounds: Rect): void {
    this.bounds = { ...bounds }
    this.emit('move')
  }
}

interface Rig {
  registry: Registry
  windows: FakeWindow[]
  announced: Array<{ view: ReturnType<Registry['view']>; event: unknown }>
  shownMain: Array<string | undefined>
  replaced: Array<{ previous: string; meta: unknown }>
  disk: { file: unknown }
  sessions: Map<string, { id: string; tabKey?: string; title: string; meta: unknown }>
  displays: { all: DisplayInfo[]; primary: DisplayInfo }
}

function rig(options: { disk?: { file: unknown }; displays?: DisplayInfo[] } = {}): Rig {
  const windows: FakeWindow[] = []
  const announced: Rig['announced'] = []
  const shownMain: Rig['shownMain'] = []
  const replaced: Rig['replaced'] = []
  const disk = options.disk ?? { file: null }
  const sessions: Rig['sessions'] = new Map([
    ['s1', { id: 's1', tabKey: 'tab-one', title: 'Session 1', meta: { id: 's1' } }],
    ['s2', { id: 's2', tabKey: 'tab-two', title: 'Session 2', meta: { id: 's2' } }],
    ['copilot', { id: 'copilot', title: 'Copilot', meta: { id: 'copilot' } }],
  ])
  const displays = { all: options.displays ?? [LAPTOP, MONITOR], primary: LAPTOP }
  const registry = createPopoutRegistry({
    makeWindow: (input) => {
      const window = new FakeWindow(input)
      windows.push(window)
      return window
    },
    displays: () => displays,
    mainBounds: () => ({ x: 60, y: 60, width: 1300, height: 860 }),
    showMain: (command) => shownMain.push(command),
    session: (id) => sessions.get(id) ?? null,
    refusal: (id) => (id === 'copilot' ? 'The copilot stays in the main window.' : null),
    statusOf: () => 'working',
    readFile: () => disk.file,
    writeFile: (file) => {
      disk.file = JSON.parse(JSON.stringify(file))
    },
    announce: (view, event) => announced.push({ view, event }),
    announceReplaced: (previous, meta) => replaced.push({ previous, meta }),
    schedule: (run) => {
      run()
      return { cancel: () => undefined }
    },
  })
  return { registry, windows, announced, shownMain, replaced, disk, sessions, displays }
}

/* ----------------------------------------------------------------- tests -- */

describe('a session in its own window', () => {
  it('opens a window for the same session and starts nothing', () => {
    const r = rig()
    const result = r.registry.open('s1')
    expect(result.ok).toBe(true)
    expect(r.windows).toHaveLength(1)
    expect(r.registry.isPopped('s1')).toBe(true)
    expect(r.registry.view().windows.map((w) => w.sessionId)).toEqual(['s1'])
    expect(r.announced.at(-1)?.event).toEqual({ kind: 'opened', sessionId: 's1' })
    // Structurally nothing can be spawned: the dependencies have no way to start
    // a session. The window is pointed at the id it was given, nothing else.
    expect(r.windows[0].title).toBe('Session 1')
  })

  it('sends that window its own session’s output and nobody else’s', () => {
    const r = rig()
    r.registry.open('s1')
    r.registry.forward('session:data', ['s1', 'hello'])
    r.registry.forward('session:data', ['s2', 'not for you'])
    r.registry.forward('session:status', ['s2', 'idle'])
    const data = r.windows[0].sent.filter((m) => m.channel === 'session:data')
    expect(data).toEqual([{ channel: 'session:data', args: ['s1', 'hello'] }])
    // Small pushes go to every window, so its chrome stays current.
    expect(r.windows[0].sent.some((m) => m.channel === 'session:status')).toBe(true)
  })

  it('does not copy the streams nothing in it reads', () => {
    const r = rig()
    r.registry.open('s1')
    r.registry.forward('devices:frame', [{}])
    r.registry.forward('machines:output', ['m', 'x'])
    expect(r.windows[0].sent).toEqual([])
  })

  it('puts the session back when its window is closed, and never ends it', () => {
    const r = rig()
    r.registry.open('s1')
    r.windows[0].close()
    expect(r.registry.isPopped('s1')).toBe(false)
    expect(r.announced.at(-1)?.event).toEqual({ kind: 'docked', sessionId: 's1', select: false })
    // Still a running session as far as this module knows — nothing removed it.
    expect(r.sessions.has('s1')).toBe(true)
    // And forgotten, so a restart does not pull it back out.
    expect((r.disk.file as { windows: unknown[] }).windows).toEqual([])
  })

  it('moves it back on request, and brings the main window forward with it selected', () => {
    const r = rig()
    r.registry.open('s1')
    const result = r.registry.dock('s1', { select: true })
    expect(result.ok).toBe(true)
    expect(r.windows[0].destroyed).toBe(true)
    expect(r.announced.at(-1)?.event).toEqual({ kind: 'docked', sessionId: 's1', select: true })
    expect(r.shownMain).toEqual([undefined])
  })

  it('answers a second open by bringing the window it already has forward', () => {
    const r = rig()
    r.registry.open('s1')
    const again = r.registry.open('s1')
    expect(again.ok).toBe(true)
    expect(r.windows).toHaveLength(1)
    expect(r.windows[0].focused).toBe(true)
  })

  it('refuses the copilot and a session that is not running, in a sentence', () => {
    const r = rig()
    expect(r.registry.open('copilot')).toMatchObject({ ok: false, message: 'The copilot stays in the main window.' })
    expect(r.registry.open('nope').ok).toBe(false)
    expect(r.windows).toHaveLength(0)
  })

  it('puts it on the display it was asked for', () => {
    const r = rig()
    const result = r.registry.open('s2', { displayId: 7 })
    expect(result.display).toBe('DELL U2723QE')
    expect(r.registry.view().windows[0].displayId).toBe(7)
    expect(r.registry.open('s1', { displayId: 42 }).ok).toBe(false)
  })

  it('names itself after the session, so the Window menu and ⌘` say which one it is', () => {
    const r = rig()
    r.registry.open('s1')
    r.registry.setLabels({ s1: 'Fix the parser' })
    expect(r.windows[0].title).toBe('Fix the parser')
    expect(r.registry.view().windows[0].label).toBe('Fix the parser')
  })
})

describe('keys pressed in a session’s own window', () => {
  it('⌘W closes the window and puts the session back, rather than deleting it', () => {
    const r = rig()
    r.registry.open('s1')
    r.windows[0].focused = true
    expect(r.registry.routeMenu('session.close')).toBe(true)
    expect(r.registry.isPopped('s1')).toBe(false)
    expect(r.announced.at(-1)?.event).toEqual({ kind: 'docked', sessionId: 's1', select: false })
  })

  it('⌘T and the rest go to the main window, which owns them', () => {
    const r = rig()
    r.registry.open('s1')
    r.windows[0].focused = true
    expect(r.registry.routeMenu('session.new')).toBe(true)
    expect(r.shownMain).toEqual(['session.new'])
    expect(r.registry.isPopped('s1')).toBe(true)
  })

  it('leaves the menu to the main window when no session window has focus', () => {
    const r = rig()
    r.registry.open('s1')
    expect(r.registry.routeMenu('session.close')).toBe(false)
    expect(r.registry.isPopped('s1')).toBe(true)
  })
})

describe('after a restart', () => {
  it('reopens each remembered window where it was, for the same tab', () => {
    const disk = { file: null as unknown }
    const before = rig({ disk })
    before.registry.open('s1')
    before.windows[0].moveTo({ x: 2100, y: 200, width: 1000, height: 700 })
    // Quitting closes the window without putting the session back.
    before.registry.suspend()
    expect(before.windows[0].destroyed).toBe(true)
    expect(before.announced.some((a) => (a.event as { kind?: string } | null)?.kind === 'docked')).toBe(false)

    // A new launch: a new process, a new id, the same tab key.
    const after = rig({ disk })
    after.sessions.delete('s1')
    after.sessions.set('s9', { id: 's9', tabKey: 'tab-one', title: 'Session 1', meta: { id: 's9' } })
    expect(after.registry.restore([...after.sessions.values()])).toEqual(['s9'])
    expect(after.windows[0].bounds).toEqual({ x: 2100, y: 200, width: 1000, height: 700 })
    expect(after.registry.view().windows[0].displayId).toBe(7)
  })

  it('reopens on the main screen when that monitor is not plugged in any more', () => {
    const disk = { file: null as unknown }
    const before = rig({ disk })
    before.registry.open('s1')
    before.windows[0].moveTo({ x: 2100, y: 200, width: 1000, height: 700 })
    before.registry.suspend()

    const after = rig({ disk, displays: [LAPTOP] })
    after.registry.restore([...after.sessions.values()])
    const bounds = after.windows[0].bounds
    expect(bounds.x).toBeGreaterThanOrEqual(0)
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(1512)
    expect(after.registry.view().windows[0].displayId).toBe(1)
  })

  it('does not bring back a window somebody closed', () => {
    const disk = { file: null as unknown }
    const before = rig({ disk })
    before.registry.open('s1')
    before.windows[0].close()
    const after = rig({ disk })
    expect(after.registry.restore([...after.sessions.values()])).toEqual([])
  })

  it('reopens once, not on every reload of the main window', () => {
    const disk = { file: null as unknown }
    const before = rig({ disk })
    before.registry.open('s1')
    before.registry.suspend()
    const after = rig({ disk })
    after.registry.restore([...after.sessions.values()])
    after.registry.restore([...after.sessions.values()])
    expect(after.windows).toHaveLength(1)
  })
})

describe('when the session changes under the window', () => {
  it('closes the window when the session ends, and forgets it', () => {
    const r = rig()
    r.registry.open('s1')
    r.registry.sessionEnded('s1')
    expect(r.windows[0].destroyed).toBe(true)
    expect(r.announced.at(-1)?.event).toBeNull()
    expect((r.disk.file as { windows: unknown[] }).windows).toEqual([])
  })

  it('follows an account switch that replaced the process', () => {
    const r = rig()
    r.registry.open('s1')
    r.sessions.set('s1b', { id: 's1b', tabKey: 'tab-one', title: 'Session 1', meta: { id: 's1b' } })
    r.registry.forward('session:switched', ['s1', { id: 's1b' }, ''])
    expect(r.registry.isPopped('s1')).toBe(false)
    expect(r.registry.isPopped('s1b')).toBe(true)
    r.registry.forward('session:data', ['s1b', 'new account'])
    expect(r.windows[0].sent.some((m) => m.channel === 'session:data' && m.args[1] === 'new account')).toBe(true)
  })

  it('follows a switch made from the window itself, and tells the main window', () => {
    const r = rig()
    r.registry.open('s1')
    r.sessions.set('s1b', { id: 's1b', tabKey: 'tab-one', title: 'Session 1', meta: { id: 's1b' } })
    expect(r.registry.rekey(999, 's1', 's1b').ok).toBe(false)
    const result = r.registry.rekey(r.windows[0].webContents.id, 's1', 's1b')
    expect(result.ok).toBe(true)
    expect(r.replaced).toEqual([{ previous: 's1', meta: { id: 's1b' } }])
  })
})

describe('the channels', () => {
  it('registers every channel and tells a window which one it is', async () => {
    const handlers = new Map<string, (...args: unknown[]) => unknown>()
    const listeners = new Map<string, (...args: unknown[]) => unknown>()
    const ipc = {
      handle: (channel: string, fn: (...args: unknown[]) => unknown) => handlers.set(channel, fn),
      removeHandler: () => undefined,
      on: (channel: string, fn: (...args: unknown[]) => unknown) => listeners.set(channel, fn),
      removeAllListeners: () => undefined,
    } as unknown as IpcMain
    const r = rig()
    const shown: Array<string | undefined> = []
    registerPopoutIpc(ipc, r.registry, (command) => shown.push(command))
    expect([...handlers.keys()].sort()).toEqual(['popout:dock', 'popout:focus', 'popout:list', 'popout:open', 'popout:rekey'])

    await handlers.get('popout:open')?.({}, 's1', { at: { x: 2500, y: 300 } })
    const contentsId = r.windows[0].webContents.id
    const listed = (await handlers.get('popout:list')?.({ sender: { id: contentsId } })) as { self: number }
    expect(listed.self).toBe(r.windows[0].id)

    listeners.get('popout:show-main')?.({}, 'view.mcp')
    listeners.get('popout:show-main')?.({}, 'something.else')
    expect(shown).toEqual(['view.mcp', undefined])
    expect(MAIN_COMMANDS.has('view.mcp')).toBe(true)

    listeners.get('popout:labels')?.({}, { s1: 'Renamed' })
    expect(r.windows[0].title).toBe('Renamed')
  })
})
