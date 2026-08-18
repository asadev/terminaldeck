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
  return `${base}/terminaldeck-browser-tab-test-${process.pid}`
})

/** Set before a create when the test wants the load to abort. */
let rejectLoads = false

/** Set when the test wants `capturePage` to fail, as it does on a hidden view. */
let captureFails = false

interface WindowOpenDetails {
  url: string
  frameName: string
  disposition: string
  features: string
}

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

  /**
   * What Electron's own `capturePage` does, closely enough.
   *
   * Present because a capture now photographs the page before it sends — the
   * popup that answers a click hides the page to be seen over it, and without a
   * still frame the website appears to vanish. `captureFails` is the other half
   * of the contract: the capture must still arrive when the photograph does not.
   */
  capturePage(): Promise<{
    getSize(): { width: number; height: number }
    resize(options: { width: number }): unknown
    toJPEG(quality: number): Buffer
  }> {
    if (captureFails) return Promise.reject(new Error('Current display surface not available'))
    const image = {
      getSize: () => ({ width: 2000, height: 1000 }),
      resize: () => image,
      toJPEG: () => Buffer.from('jpeg-bytes'),
    }
    return Promise.resolve(image)
  }

  /**
   * Kept rather than discarded, because it stopped being a refusal.
   *
   * It used to be a one-liner that always answered `deny` and wrote a message
   * on the page, so a test could drive the same code path through a refused
   * navigation instead. Now it decides between "a tab of ours" and "refuse",
   * and the first of those is the whole point of the change — see
   * `link-open.ts`. There is nothing else that reaches it.
   */
  /**
   * The full details Chromium sends, not only the address.
   *
   * The handler routes on the disposition and the frame name as well now: a
   * sized or named request is a sign-in pop-up and becomes a real window with a
   * real opener, and everything else is a link and becomes a tab in this
   * window. A fake that only carried the URL would let the handler read
   * `undefined` for the two fields the routing turns on.
   */
  windowOpenHandler: ((details: WindowOpenDetails) => unknown) | null = null

  setWindowOpenHandler(handler: (details: WindowOpenDetails) => unknown): void {
    this.windowOpenHandler = handler
  }

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
  /** Every colour the module painted, in order — the last one is what shows. */
  readonly backgrounds: string[] = []

  constructor() {
    created.push(this)
  }

  setBackgroundColor(value: string): void {
    this.backgrounds.push(value)
  }

  setBounds(value: unknown): void {
    this.bounds = value
  }

  setVisible(value: boolean): void {
    this.visible = value
  }
}

/**
 * A window that can be listened to and can be destroyed.
 *
 * An `EventEmitter`, unlike the plain object this used to be, because the module
 * now registers `once('closed')` on it — a view whose window has gone must not
 * be left composited, and a fake with no `once` would have made that
 * unwriteable rather than merely untested.
 */
class FakeWindow extends EventEmitter {
  destroyed = false
  readonly removed: unknown[] = []
  readonly contentView = {
    addChildView: () => undefined,
    removeChildView: (view: unknown) => {
      this.removed.push(view)
    },
  }

  isDestroyed(): boolean {
    return this.destroyed
  }

  /** What closing a window does, in the order Electron does it. */
  close(): void {
    this.destroyed = true
    this.emit('closed')
  }
}

let fakeWindow = new FakeWindow()

vi.mock('electron', () => ({
  app: {
    getPath: () => USER_DATA,
    // Real Electron always has one; the guest session's user agent is
    // derived from it, and Google's sign-in behaviour turns on what is in
    // it. See `browser-user-agent.ts`.
    userAgentFallback:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Electron/41.10.5 Safari/537.36',
  },
  BrowserWindow: { fromWebContents: () => fakeWindow },
  session: {
    fromPartition: () => ({
      setPermissionRequestHandler: () => undefined,
      setPermissionCheckHandler: () => undefined,
      on: () => undefined,
      // The flow recorder's script is attached per session, and that attachment
      // moved into `browser-profiles.ts` so every profile gets it rather than
      // only the first one. A fake session that cannot be hardened is one this
      // module cannot use, which is the honest shape of the dependency.
      registerPreloadScript: () => 'record-preload',
      setUserAgent: () => undefined,
    }),
  },
  WebContentsView: FakeWebContentsView,
}))

const { destroyAllBrowserTabs, readCaptureRect, registerBrowserIpc, shouldComposite } =
  await import('./browser-tab')
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
  failed: boolean
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
): Promise<{ state: TabState; guest: FakeWebContents; view: FakeWebContentsView }> {
  const state = (await invoke('browser:create', { sender: host }, options)) as TabState
  const view = created.at(-1)
  if (!view) throw new Error('no view was constructed')
  return { state, guest: view.webContents, view }
}

/** The newest state the module pushed at the renderer. */
function lastPush(): TabState {
  const pushed = host.sent.filter((m) => m.channel === 'browser:state-changed')
  const state = pushed.at(-1)?.args[0] as TabState | undefined
  if (!state) throw new Error('no state was pushed')
  return state
}

async function inspecting(): Promise<{ state: TabState; guest: FakeWebContents }> {
  const tab = await openTab({ url: 'http://localhost:3000' })
  await invoke('browser:inspect', {}, tab.state.id, true)
  host.sent.length = 0
  return tab
}

/**
 * Let the microtask queue drain.
 *
 * A capture is now sent *after* the page has been photographed, so the message
 * arrives a promise tick after the guest's IPC rather than inside it. The
 * ordering is deliberate — see `freezeFrame` — so the tests wait rather than
 * asserting on a synchronous send that no longer exists.
 */
const settled = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(() => {
  destroyAllBrowserTabs()
  created.length = 0
  rejectLoads = false
  captureFails = false
  host = new FakeWebContents()
  // A fresh window per test as well as a fresh host: the module watches each
  // window once, and a window carried over would arrive already closed.
  fakeWindow = new FakeWindow()
})

afterAll(() => {
  destroyAllBrowserTabs()
  rmSync(USER_DATA, { recursive: true, force: true })
})

describe('guest messages', () => {
  it('accepts a capture from the tab’s own main frame', async () => {
    const { state, guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    await settled()

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
    await settled()
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('refuses a capture from a subframe', async () => {
    const { guest } = await inspecting()
    emit(
      GUEST_ELEMENT_CHANNEL,
      { sender: guest, senderFrame: { name: 'an-embedded-ad' } },
      ELEMENT_PAYLOAD,
    )
    await settled()
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
    await settled()
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('ignores captures while inspection is off', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    await settled()
    expect(host.sent.some((m) => m.channel === 'browser:element')).toBe(false)
  })

  it('carries the element’s box through, so the popup can open at it', async () => {
    const { guest } = await inspecting()
    emit(
      GUEST_ELEMENT_CHANNEL,
      { sender: guest, senderFrame: guest.mainFrame },
      { ...ELEMENT_PAYLOAD, rect: { x: 40, y: 120, width: 200, height: 32 } },
    )
    await settled()
    const message = host.sent.find((m) => m.channel === 'browser:element')
    expect((message?.args[1] as { rect: unknown }).rect).toEqual({
      x: 40,
      y: 120,
      width: 200,
      height: 32,
    })
  })

  it('says null rather than guessing when the page reported no box', async () => {
    const { guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    await settled()
    const message = host.sent.find((m) => m.channel === 'browser:element')
    expect((message?.args[1] as { rect: unknown }).rect).toBeNull()
  })

  it('photographs the page, so the popup does not open over a black hole', async () => {
    // The popup is HTML and the page is a native layer above the renderer, so
    // opening the popup necessarily hides the page. Without a still frame the
    // website appears to vanish the instant it is clicked.
    const { guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    await settled()
    const message = host.sent.find((m) => m.channel === 'browser:element')
    expect((message?.args[1] as { pageImage: string }).pageImage).toMatch(/^data:image\/jpeg;base64,/)
  })

  it('still delivers the capture when the photograph fails', async () => {
    // A backdrop is the least important thing on the path between a click and
    // the answer to it. Losing it must cost the backdrop and nothing else.
    captureFails = true
    const { guest } = await inspecting()
    emit(GUEST_ELEMENT_CHANNEL, { sender: guest, senderFrame: guest.mainFrame }, ELEMENT_PAYLOAD)
    await settled()
    const message = host.sent.find((m) => m.channel === 'browser:element')
    expect(message).toBeDefined()
    expect((message?.args[1] as { pageImage: string }).pageImage).toBe('')
    expect((message?.args[1] as { selector: string }).selector).toBe('#buy')
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

/**
 * The recording of 2026-08-16, on Windows: a new tab opened on
 * `http://localhost:3000`, nothing was listening, and the first thing the
 * product ever showed was Chromium's red "connection refused" document. The
 * app's own message underneath it said `ERR_CONNECTION_REFUSED (-102)`, which
 * is the same machine text in a smaller font.
 *
 * These pin both halves of the fix: the sentence, and the flag that lets the
 * renderer put that sentence on screen INSTEAD of the error page.
 */
describe('a load that fails', () => {
  it('reports a written sentence, not a Chromium constant', async () => {
    const { state, guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/', true)

    const next = lastPush()
    expect(next.id).toBe(state.id)
    expect(next.error).toContain('localhost:3000')
    expect(next.error).not.toContain('ERR_')
    expect(next.error).not.toContain('-102')
  })

  it('marks the view as showing an error page, which a refusal does not', async () => {
    // `error` alone cannot drive the renderer: a blocked pop-up sets it too and
    // leaves a perfectly good page on screen. Only `failed` means "what is in
    // the view is Chromium's error document".
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0

    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/', true)
    expect(lastPush().failed).toBe(true)
  })

  it('survives the error page committing on top of it', async () => {
    /*
     * The ordering bug this was written for. Chromium fires `did-fail-load` and
     * then commits its error document, which is a navigation carrying the URL
     * that just failed. `tab.error = null` on every `did-navigate` therefore
     * wiped the message one event after it was written, and the user was left
     * looking at the raw error page with nothing explaining it.
     */
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/', true)
    host.sent.length = 0

    guest.emit('did-navigate', {}, 'http://localhost:3000/')

    const next = lastPush()
    expect(next.error, 'the error page wiped its own explanation').not.toBeNull()
    expect(next.failed).toBe(true)
  })

  it('clears once the tab lands somewhere that works', async () => {
    const { state, guest } = await openTab({ url: 'http://localhost:3000' })
    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/', true)
    host.sent.length = 0

    guest.emit('did-navigate', {}, 'http://localhost:5173/')

    const next = lastPush()
    expect(next.error).toBeNull()
    expect(next.failed).toBe(false)
    expect((await invoke('browser:state', {}, state.id) as TabState).failed).toBe(false)
  })

  it('lets Reload retry the same address, which did-navigate deliberately cannot', async () => {
    // "Try that again" is the whole purpose of the control, and the URL match
    // that protects the message from the error page would otherwise make the
    // one address that failed the one address that can never clear.
    const { state, guest } = await openTab({ url: 'http://localhost:3000' })
    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://localhost:3000/', true)

    const reloaded = (await invoke('browser:reload', {}, state.id)) as TabState
    expect(reloaded.failed).toBe(false)
    expect(reloaded.error).toBeNull()

    host.sent.length = 0
    guest.emit('did-navigate', {}, 'http://localhost:3000/')
    expect(lastPush().failed).toBe(false)
  })

  it('says nothing at all about an aborted navigation', async () => {
    // -3 is what typing a new address mid-load reports, and what Stop reports,
    // and what a tab closing mid-load reports. None of them is a failure.
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    guest.emit('did-fail-load', {}, -3, 'ERR_ABORTED', 'http://localhost:3000/', true)
    expect(host.sent.filter((m) => m.channel === 'browser:state-changed')).toEqual([])
  })

  it('ignores a subframe that failed, because the page itself is fine', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    guest.emit('did-fail-load', {}, -102, 'ERR_CONNECTION_REFUSED', 'http://ads.example/', false)
    expect(host.sent.filter((m) => m.channel === 'browser:state-changed')).toEqual([])
  })

  it('keeps a blocked navigation out of the error-page path', async () => {
    // The other half of the `error` / `failed` split, from the other side: this
    // must set a message and must NOT make the renderer hide the page.
    const { guest, view } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    guest.emit('will-navigate', { preventDefault: () => undefined }, 'file:///etc/passwd')

    const next = lastPush()
    expect(next.error).toMatch(/http/)
    expect(next.failed, 'a refusal is not an error page').toBe(false)
    expect(view.visible).toBe(false)
  })
})

/**
 * `target="_blank"`, which used to be answered with *"Blocked a pop-up to X."*
 *
 * Asad, 2026-08-17: *"currently it's opening a separate window — I want it to
 * use the same window inside Terminal Deck for browser."* A guest still gets no
 * window of Chromium's — that part was right and stays — but the destination
 * now becomes a tab in the workspace strip, which is a window of the app's.
 */
describe('a link that asks for a new window', () => {
  const openWindow = (guest: FakeWebContents, url: string): unknown => {
    const handler = guest.windowOpenHandler
    if (!handler) throw new Error('no window-open handler was registered')
    // The whole details object, because the handler routes on more than the
    // address now: a sized or named request is a sign-in pop-up and becomes a
    // real window, everything else is a link and becomes a tab here. See
    // `browser-popup.ts` for the dispositions Chromium actually reports.
    return handler({ url, frameName: '', disposition: 'foreground-tab', features: '' })
  }

  /** The shape a page produces with `window.open(url, 'oauth', 'width=…')`. */
  const openPopup = (guest: FakeWebContents, url: string): unknown => {
    const handler = guest.windowOpenHandler
    if (!handler) throw new Error('no window-open handler was registered')
    return handler({
      url,
      frameName: 'oauth',
      disposition: 'new-window',
      features: 'width=500,height=600',
    })
  }

  it('becomes a tab in this window instead of a pop-up', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0

    expect(openWindow(guest, 'https://example.com/docs')).toEqual({ action: 'deny' })
    expect(host.sent).toEqual([
      { channel: 'link:open-tab', args: ['https://example.com/docs'] },
    ])
    // And no banner: nothing was refused, so there is nothing to apologise for.
    expect(host.sent.filter((m) => m.channel === 'browser:state-changed')).toEqual([])
  })

  it('never gets a window of Chromium’s for an ordinary link', async () => {
    // The deny is not a detail for a *link*. A bare Electron window would have
    // no toolbar, no address bar and none of the navigation guards above.
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    expect(openWindow(guest, 'https://example.com/')).toEqual({ action: 'deny' })
    expect(openWindow(guest, 'file:///etc/passwd')).toEqual({ action: 'deny' })
  })

  /**
   * The one thing that must not be tidied back into a single `deny`.
   *
   * Answering every `window.open` with `deny` makes the *page's* own handle come
   * back `null` — measured on Electron 41.10.5 — so the sign-in library that
   * opened it waits forever for a `postMessage` from a window it was never
   * given. That is the whole of *"the verification link gets stuck"* and the QR
   * that *"appeared and then stopped"* in the 2026-08-17 review, and it is
   * silent: nothing throws, and the destination even finishes the sign-in in a
   * tab. It simply cannot say so.
   */
  it('lets a real sign-in pop-up be a real window, with a real opener', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0
    const answer = openPopup(guest, 'https://accounts.example.com/oauth') as {
      action: string
      overrideBrowserWindowOptions?: { webPreferences?: { sandbox?: boolean } }
    }
    expect(answer.action).toBe('allow')
    // On this tab's own session, sandboxed, with context isolation — a pop-up
    // is a window with fewer checks than a tab, so this is the one place the
    // hardening must not be relaxed.
    expect(answer.overrideBrowserWindowOptions?.webPreferences?.sandbox).toBe(true)
    // And it is not also opened as a tab: two of them is the bug wearing a
    // different face.
    expect(host.sent.filter((m) => m.channel === 'link:open-tab')).toEqual([])
  })

  it('still refuses a pop-up to a scheme a page must not reach', async () => {
    const { guest } = await openTab({ url: 'http://localhost:3000' })
    expect(openPopup(guest, 'file:///etc/passwd')).toEqual({ action: 'deny' })
  })

  it('still refuses anything that is not http or https, and says so', async () => {
    const { guest, view } = await openTab({ url: 'http://localhost:3000' })
    host.sent.length = 0

    openWindow(guest, 'file:///etc/passwd')
    expect(
      host.sent.filter((m) => m.channel === 'link:open-tab'),
      'a website must not be able to open a file: URL anywhere',
    ).toEqual([])

    const next = lastPush()
    expect(next.error).toMatch(/only http and https/)
    expect(next.failed, 'a refusal is not an error page').toBe(false)
    expect(view.visible).toBe(false)
  })
})

/**
 * "An empty browser page is white in dark mode" — the same recording.
 *
 * The view used to be constructed with a hardcoded `#ffffff`, which is both a
 * white rectangle in the middle of a dark app and a raw hex literal in a
 * codebase whose every colour comes from `tokens.css`.
 */
describe('the view’s backdrop', () => {
  it('wears the app’s canvas colour when there is no page in it', async () => {
    const { view } = await openTab({ background: '#191919' })
    expect(view.backgrounds.at(-1)).toBe('#191919')
  })

  it('wears white for a real page, whatever the app theme is', async () => {
    // Load-bearing: bare HTML declares no background, so a dark base colour
    // renders an unstyled dev-server page as black text on dark grey.
    const { view } = await openTab({ url: 'http://localhost:3000', background: '#191919' })
    expect(view.backgrounds.at(-1)).toBe('#ffffff')
  })

  it('changes on the way into a navigation, not on the way out of one', async () => {
    // `did-navigate` is a frame late — the document has already committed, so
    // switching there shows one frame of the previous colour.
    const { guest, view } = await openTab({ background: '#191919' })
    expect(view.backgrounds.at(-1)).toBe('#191919')

    guest.emit('did-start-navigation', {
      url: 'http://localhost:5173/',
      isMainFrame: true,
      isSameDocument: false,
    })
    expect(view.backgrounds.at(-1)).toBe('#ffffff')
  })

  it('ignores a navigation that swaps no document', async () => {
    const { guest, view } = await openTab({ url: 'http://localhost:3000', background: '#191919' })
    const before = view.backgrounds.length
    guest.emit('did-start-navigation', {
      url: 'http://localhost:3000/#section',
      isMainFrame: true,
      isSameDocument: true,
    })
    guest.emit('did-start-navigation', {
      url: 'http://ads.example/frame',
      isMainFrame: false,
      isSameDocument: false,
    })
    expect(view.backgrounds.length).toBe(before)
  })

  it('falls back to white rather than to black when no colour was sent', async () => {
    // An older preload, or a token rename. Conventional-but-wrong beats a black
    // rectangle nobody chose.
    const { view } = await openTab({})
    expect(view.backgrounds.at(-1)).toBe('#ffffff')
    const refused = await openTab({ background: 'var(--bg-primary)' })
    expect(refused.view.backgrounds.at(-1)).toBe('#ffffff')
  })
})

/**
 * The bug of 2026-08-17, and the rule that ends it.
 *
 * He pressed ⌘R with a page open. The strip came back holding one terminal tab,
 * the mode switch read Terminal, Claude Code's own `bypass permissions on
 * (shift+tab to cycle)` was visible along the bottom of the window — and
 * `example.com` was painted over all of it. Nothing had crashed: the renderer's
 * document had been replaced, React unmount cleanups do not run for a page
 * unload, and the host WebContents is the *same object* across a reload, so
 * neither the panel's teardown nor the `destroyed` registration fired. The old
 * `WebContentsView` simply stayed a child of the window, at its last rectangle,
 * with its last visibility.
 *
 * These pin both halves. The rule is a pure function so it can be stated
 * without a window; the integration cases drive the three events that make a
 * renderer stop owning its views, because the rule is worthless if nothing
 * reports the facts it reads.
 */
describe('a view cannot outlive the renderer that asked for it', () => {
  /** A tab that is genuinely on screen: asked for, and with room to be in. */
  async function shownTab(): Promise<{ id: string; view: FakeWebContentsView }> {
    const { state, view } = await openTab({ url: 'http://localhost:3000' })
    emit('browser:bounds', { sender: host }, state.id, { x: 0, y: 0, width: 800, height: 600 })
    emit('browser:visible', { sender: host }, state.id, true)
    expect(view.visible, 'the fixture never showed the view').toBe(true)
    return { id: state.id, view }
  }

  it('hides and forgets a page when the renderer reloads', async () => {
    const { id, view } = await shownTab()

    // ⌘R. `did-start-navigation` on the *host* — the app's own renderer — with a
    // real document swap. This is the exact event the old code never listened
    // for, and the WebContents is deliberately not destroyed here because a
    // reload does not destroy it.
    host.emit('did-start-navigation', {
      url: 'file:///app/index.html',
      isMainFrame: true,
      isSameDocument: false,
    })

    expect(view.visible, 'the page was left composited over the reloaded window').toBe(false)
    expect(await invoke('browser:state', {}, id)).toBeNull()
    expect(host.destroyed, 'a reload must not be mistaken for a destroyed renderer').toBe(false)
  })

  it('hides and forgets a page when the renderer process dies', async () => {
    // A crashed renderer is replaced in place, so again nothing is destroyed and
    // again the view would otherwise float over whatever came back.
    const { id, view } = await shownTab()
    host.emit('render-process-gone', {}, { reason: 'crashed' })
    expect(view.visible).toBe(false)
    expect(await invoke('browser:state', {}, id)).toBeNull()
  })

  it('hides and forgets a page when the window closes under it', async () => {
    const { id, view } = await shownTab()
    fakeWindow.close()
    expect(view.visible).toBe(false)
    expect(await invoke('browser:state', {}, id)).toBeNull()
  })

  it('leaves the page alone for a navigation that owns nothing', async () => {
    // A fragment link and a subframe are not the document being replaced. If
    // either counted, the browser panel would tear itself down for an anchor.
    const { id, view } = await shownTab()

    host.emit('did-start-navigation', {
      url: 'file:///app/index.html#settings',
      isMainFrame: true,
      isSameDocument: true,
    })
    host.emit('did-start-navigation', {
      url: 'https://ads.example/frame',
      isMainFrame: false,
      isSameDocument: false,
    })

    expect(view.visible).toBe(true)
    expect(await invoke('browser:state', {}, id)).not.toBeNull()
  })

  it('watches a renderer once, however many tabs it opens', async () => {
    // Every `browser:create` calls the watcher, so an unguarded registration
    // would add a listener per tab — the `MaxListenersExceededWarning` that
    // `web-contents-teardown.ts` exists to have removed, reintroduced here.
    await openTab({ url: 'http://localhost:3000' })
    await openTab({ url: 'http://localhost:5173' })
    await openTab({ url: 'http://localhost:8080' })
    expect(host.listenerCount('did-start-navigation')).toBe(1)
    expect(host.listenerCount('render-process-gone')).toBe(1)
  })

  it('will not show a page the renderer asks for after its document has moved on', async () => {
    /*
     * The clause that does not depend on any teardown having run.
     *
     * Everything above destroys the tab, so it also proves the destroy. This one
     * proves the *rule*: even with a live host, a live window, room on screen and
     * the renderer asking for it, a view stamped with a document that is no
     * longer the current one is never composited.
     */
    const asked = {
      wanted: true,
      width: 800,
      height: 600,
      hostAlive: true,
      windowAlive: true,
      bornInto: 0,
      hostDocument: 0,
    }
    expect(shouldComposite(asked)).toBe(true)
    expect(shouldComposite({ ...asked, hostDocument: 1 })).toBe(false)
  })

  it('refuses on every other ground on its own', () => {
    const asked = {
      wanted: true,
      width: 800,
      height: 600,
      hostAlive: true,
      windowAlive: true,
      bornInto: 3,
      hostDocument: 3,
    }
    expect(shouldComposite({ ...asked, wanted: false })).toBe(false)
    expect(shouldComposite({ ...asked, hostAlive: false })).toBe(false)
    expect(shouldComposite({ ...asked, windowAlive: false })).toBe(false)
    // A zero-sized view still paints a white sliver at its origin.
    expect(shouldComposite({ ...asked, width: 0 })).toBe(false)
    expect(shouldComposite({ ...asked, height: 0 })).toBe(false)
  })
})

/**
 * The rectangle comes from an untrusted page and is interpolated into an inline
 * `style` on our own trusted document, so it is checked like everything else
 * that crosses that line — not because the arithmetic is delicate, but because
 * `left: 1e308px` is a layout that never recovers.
 */
describe('readCaptureRect', () => {
  it('takes a plain rectangle', () => {
    expect(readCaptureRect({ x: 1, y: 2, width: 3, height: 4 })).toEqual({
      x: 1,
      y: 2,
      width: 3,
      height: 4,
    })
  })

  it('refuses anything that is not four finite numbers', () => {
    expect(readCaptureRect(null)).toBeNull()
    expect(readCaptureRect('40,120')).toBeNull()
    expect(readCaptureRect({ x: 1, y: 2, width: 3 })).toBeNull()
    expect(readCaptureRect({ x: 1, y: 2, width: 3, height: Number.NaN })).toBeNull()
    expect(readCaptureRect({ x: Number.POSITIVE_INFINITY, y: 0, width: 1, height: 1 })).toBeNull()
  })

  it('clamps a number that would break the layout it lands in', () => {
    const rect = readCaptureRect({ x: 1e308, y: -1e308, width: 1e308, height: -5 })
    expect(rect).toEqual({ x: 100000, y: -100000, width: 100000, height: 0 })
  })
})
