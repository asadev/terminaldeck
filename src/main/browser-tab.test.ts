import { EventEmitter } from 'node:events'
import { rmSync } from 'node:fs'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * `browser-tab.ts` is the half of the feature that talks to Electron, so it had
 * no test at all. Everything it gets wrong is invisible to the pure modules:
 * which frame is allowed to speak, what happens to a load that rejects, and
 * what is left in the tab map after a view dies on its own.
 *
 * The fakes below implement only what the module touches, and they are
 * deliberately literal about the two Electron behaviours the code has to
 * survive: `loadURL` returns a promise that rejects when a navigation is
 * aborted, and `senderFrame` is null once the sending frame has gone.
 */

/** Computed inside `vi.hoisted` because the electron mock is hoisted above it. */
const USER_DATA = vi.hoisted(() => {
  const base = (process.env.TMPDIR ?? '/tmp').replace(/\/+$/, '')
  return `${base}/pawl-browser-tab-test-${process.pid}`
})

/** Set before a create when the test wants the load to abort. */
let rejectLoads = false

class FakeWebContents extends EventEmitter {
  private static nextId = 1
  readonly id = FakeWebContents.nextId++
  readonly mainFrame = { name: `frame-${this.id}` }
  readonly sent: Array<{ channel: string; args: unknown[] }> = []
  destroyed = false
  url = ''

  isDestroyed(): boolean {
    return this.destroyed
  }

  getURL(): string {
    return this.url
  }

  getTitle(): string {
    return 'Fake'
  }

  isLoading(): boolean {
    return false
  }

  readonly navigationHistory = {
    canGoBack: () => false,
    canGoForward: () => false,
    goBack: () => undefined,
    goForward: () => undefined,
  }

  loadURL(target: string): Promise<void> {
    // What an aborted navigation actually does, which is the case the app has
    // to survive rather than the case it hopes for.
    if (rejectLoads) return Promise.reject(new Error('ERR_ABORTED (-3)'))
    this.url = target
    return Promise.resolve()
  }

  send(channel: string, ...args: unknown[]): void {
    this.sent.push({ channel, args })
  }

  setWindowOpenHandler(): void {}
  reload(): void {}
  stop(): void {}

  close(): void {
    this.destroyed = true
  }

  /** A view going away without anyone asking it to: a crash, or a closing window. */
  die(): void {
    this.destroyed = true
    this.emit('destroyed')
  }
}

const created: FakeWebContentsView[] = []

class FakeWebContentsView {
  readonly webContents = new FakeWebContents()
  bounds: unknown = null
  visible = false

  constructor() {
    created.push(this)
  }

  setBackgroundColor(): void {}

  setBounds(value: unknown): void {
    this.bounds = value
  }

  setVisible(value: boolean): void {
    this.visible = value
  }
}

const fakeWindow = {
  isDestroyed: () => false,
  contentView: {
    addChildView: () => undefined,
    removeChildView: () => undefined,
  },
}

vi.mock('electron', () => ({
  app: { getPath: () => USER_DATA },
  BrowserWindow: { fromWebContents: () => fakeWindow },
  session: {
    fromPartition: () => ({
      setPermissionRequestHandler: () => undefined,
      setPermissionCheckHandler: () => undefined,
      on: () => undefined,
    }),
  },
  WebContentsView: FakeWebContentsView,
}))

const { destroyAllBrowserTabs, registerBrowserIpc } = await import('./browser-tab')
const { GUEST_CANCEL_CHANNEL, GUEST_ELEMENT_CHANNEL } = await import('./browser-preload')

type Handler = (event: unknown, ...args: unknown[]) => unknown

const handlers = new Map<string, Handler>()
const listeners = new Map<string, Handler>()

registerBrowserIpc({
  handle: (channel: string, fn: Handler) => handlers.set(channel, fn),
  on: (channel: string, fn: Handler) => listeners.set(channel, fn),
} as unknown as Parameters<typeof registerBrowserIpc>[0])

async function invoke(channel: string, event: unknown, ...args: unknown[]): Promise<unknown> {
  const fn = handlers.get(channel)
  if (!fn) throw new Error(`no handler registered for ${channel}`)
  return fn(event, ...args)
}

function emit(channel: string, event: unknown, ...args: unknown[]): void {
  const fn = listeners.get(channel)
  if (!fn) throw new Error(`no listener registered for ${channel}`)
  fn(event, ...args)
}

interface TabState {
  id: string
  url: string
  label: string
  inspecting: boolean
  error: string | null
}

/** Shaped like the guest's message, because that is what the module parses. */
const ELEMENT_PAYLOAD = {
  v: 1,
  path: [
    { tag: 'button', id: 'buy', idUnique: true, nthOfType: 1, ofTypeCount: 1 },
    { tag: 'body', nthOfType: 1, ofTypeCount: 1 },
  ],
  text: 'Buy now',
  attributes: { type: 'submit' },
}

let host: FakeWebContents

async function openTab(
  options: Record<string, unknown> = {},
): Promise<{ state: TabState; guest: FakeWebContents }> {
  const state = (await invoke('browser:create', { sender: host }, options)) as TabState
  const view = created.at(-1)
  if (!view) throw new Error('no view was constructed')
  return { state, guest: view.webContents }
}

async function inspecting(): Promise<{ state: TabState; guest: FakeWebContents }> {
  const tab = await openTab({ url: 'http://localhost:3000' })
  await invoke('browser:inspect', {}, tab.state.id, true)
  host.sent.length = 0
  return tab
}

beforeEach(() => {
  destroyAllBrowserTabs()
  created.length = 0
  rejectLoads = false
  host = new FakeWebContents()
})

afterAll(() => {
  destroyAllBrowserTabs()
  rmSync(USER_DATA, { recursive: true, force: true })
})

describe('guest messages', () => {
  it('accepts a capture from the tab’s own main frame', async () => {
    const { state, guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)

    const message = host.sent.find((m) => m.channel === 'browser:element')
    expect(message).toBeDefined()
    expect(message?.args[0]).toBe(state.id)
    const capture = message?.args[1] as { selector: string; url: string; context: string }
    expect(capture.selector).toBe('#buy')
    // The URL is the view's own, never the payload's.
    expect(capture.url).toBe('http://localhost:3000/')
    expect(capture.context).toContain('element `#buy`')
  })

  it('refuses a capture whose frame is gone rather than assuming it was the main one', async () => {
    // `senderFrame` is null once the sending frame has navigated or been
    // destroyed. Reading that as "not a subframe, then" lets an embedded frame
    // through by losing that race on purpose.
    const { guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: null }, ELEMENT_PAYLOAD)
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('refuses a capture from a subframe', async () => {
    const { guest } = await inspecting()
    emit(
      GUEST_ELEMENT_CHANNEL,
      { sender: guest, senderFrame: { name: 'an-embedded-ad' } },
      ELEMENT_PAYLOAD,
    )
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('refuses a capture from a WebContents that is not one of its tabs', async () => {
    await inspecting()
    const stranger = new FakeWebContents()
    emit(
      GUEST_ELEMENT_CHANNEL,
      { sender: stranger, senderFrame: stranger.mainFrame },
      ELEMENT_PAYLOAD,
    )
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('ignores captures while inspection is off', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('turns inspection off when the guest reports Escape', async () => {
    const { guest } = await inspecting()
    emit(GUEST_CANCEL_CHANNEL, { sender: guest, senderFrame: guest.mainFrame })
    const pushed = host.sent.filter((m) => m.channel === 'browser:state-changed')
    expect((pushed.at(-1)?.args[0] as TabState).inspecting).toBe(false)
  })
})

describe('tab lifecycle', () => {
  it('leaves no unhandled rejection behind when the blank load aborts', async () => {
    // React StrictMode creates the panel twice and closes the first one, which
    // aborts its about:blank load. An unhandled rejection in the main process
    // takes the whole app down with it.
    const seen: unknown[] = []
    const onUnhandled = (reason: unknown): void => {
      seen.push(reason)
    }
    process.on('unhandledRejection', onUnhandled)
    try {
      rejectLoads = true
      await openTab({})
      await new Promise((resolve) => setTimeout(resolve, 25))
    } finally {
      process.off('unhandledRejection', onUnhandled)
      rejectLoads = false
    }
    expect(seen).toEqual([])
  })

  it('forgets a tab whose view died on its own', async () => {
    const { state, guest } = await openTab({ url: 'http://localhost:3000' })
    expect(await invoke('browser:state', {}, state.id)).not.toBeNull()

    guest.die()

    // Gone from the map, not merely reported as empty: otherwise the entry and
    // the dead view it holds stay there for the life of the app, and every
    // guest message afterwards walks them.
    expect(await invoke('browser:state', {}, state.id)).toBeNull()
  })

  it('refuses a URL outside http(s) and says why', async () => {
    const { state, guest } = await openTab({})
    const next = (await invoke(
      'browser:navigate',
      {},
      state.id,
      'file:///Users/apple/.ssh/id_rsa',
    )) as TabState
    expect(next.error).toMatch(/http/)
    expect(guest.getURL()).not.toContain('id_rsa')
  })

  it('throws for a tab id it does not know', async () => {
    await expect(invoke('browser:navigate', {}, 'not-a-tab', 'http://x/')).rejects.toThrow(
      /no such tab/,
    )
  })

  it('does not put a page-sized URL in the tab label', async () => {
    const { state, guest } = await openTab({})
    guest.url = `http://evil.example/${'a'.repeat(200_000)}`
    const next = (await invoke('browser:state', {}, state.id)) as TabState
    expect(next.label.length).toBeLessThanOrEqual(121)
  })
})
