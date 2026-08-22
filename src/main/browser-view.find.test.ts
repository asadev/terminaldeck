import { describe, expect, it, vi } from 'vitest'
import type { IpcMain } from 'electron'

/**
 * Find-in-page, the page chords and print — traced the way a person meets
 * them, not the way a unit calls them.
 *
 * The route under test: a key pressed *inside a focused page* arrives at
 * `before-input-event` (the renderer never hears it — the page is its own
 * WebContents), becomes a chord push on `browser:key`, the renderer answers
 * with `browser-view:find`, and Chromium's `found-in-page` comes back as a
 * count push on `browser:find`. Every hop below is exercised against the real
 * `registerBrowserViewIpc` registrations, because the audit this lane answers
 * overturned eight "done"s whose only proof was a unit test on a function
 * nothing calls.
 */

const GUEST_SESSION = {
  setPermissionRequestHandler: () => undefined,
  setPermissionCheckHandler: () => undefined,
  on: () => undefined,
  registerPreloadScript: () => 'record-preload',
  setUserAgent: () => undefined,
}

let onWebContentsCreated: ((event: unknown, wc: unknown) => void) | null = null

vi.mock('electron', () => ({
  app: {
    getPath: () => '/tmp',
    on: (event: string, fn: (event: unknown, wc: unknown) => void) => {
      if (event === 'web-contents-created') onWebContentsCreated = fn
    },
    userAgentFallback: 'Chromium',
  },
  shell: { showItemInFolder: () => undefined },
  session: { fromPartition: () => GUEST_SESSION },
}))

const { FIND_CHANNEL, KEY_CHANNEL, guestChord, registerBrowserViewIpc, releaseAllBrowserViews } =
  await import('./browser-view')

/* ------------------------------------------------------------------ harness -- */

type Listener = (...args: unknown[]) => void

class FakeContents {
  static nextId = 1
  id = FakeContents.nextId++
  session: unknown = GUEST_SESSION
  type = 'window'
  url = 'http://localhost:3000/'
  destroyed = false
  zoom = 1
  mainFrame = { id: this.id }
  /** Pushes into this renderer: `send(channel, tabId, payload)` — three args. */
  sent: Array<{ channel: string; tabId: unknown; payload: unknown }> = []
  /** Every `findInPage` call, in order, exactly as Chromium would see it. */
  finds: Array<{ text: string; options: { forward?: boolean; findNext?: boolean } }> = []
  /** Every `stopFindInPage` action, in order. */
  stops: string[] = []
  focused = 0
  /** The last print callback, so a test can answer as the OS would. */
  printCb: ((ok: boolean, reason: string) => void) | null = null
  private listeners = new Map<string, Set<Listener>>()

  getType(): string {
    return this.type
  }
  getURL(): string {
    return this.url
  }
  isDestroyed(): boolean {
    return this.destroyed
  }
  send(channel: string, ...args: unknown[]): void {
    this.sent.push({ channel, tabId: args[0], payload: args[1] })
  }
  setZoomFactor(value: number): void {
    this.zoom = value
  }
  getZoomFactor(): number {
    return this.zoom
  }
  findInPage(text: string, options: { forward?: boolean; findNext?: boolean }): number {
    this.finds.push({ text, options })
    return this.finds.length
  }
  stopFindInPage(action: string): void {
    this.stops.push(action)
  }
  focus(): void {
    this.focused += 1
  }
  print(_options: unknown, cb: (ok: boolean, reason: string) => void): void {
    this.printCb = cb
  }
  setUserAgent(): void {}
  isDevToolsOpened(): boolean {
    return false
  }
  openDevTools(): void {}
  closeDevTools(): void {}

  on(event: string, fn: Listener): this {
    const set = this.listeners.get(event) ?? new Set<Listener>()
    set.add(fn)
    this.listeners.set(event, set)
    return this
  }
  once(event: string, fn: Listener): this {
    return this.on(event, fn)
  }
  off(event: string, fn: Listener): this {
    this.listeners.get(event)?.delete(fn)
    return this
  }
  emit(event: string, ...args: unknown[]): void {
    for (const fn of [...(this.listeners.get(event) ?? [])]) fn(...args)
  }
}

const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()

registerBrowserViewIpc({
  handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
    handlers.set(channel, fn)
  },
  on: () => undefined,
} as unknown as IpcMain)

const host = new FakeContents()

function invoke(channel: string, ...args: unknown[]): unknown {
  const fn = handlers.get(channel)
  if (!fn) throw new Error(`no handler for ${channel}`)
  return fn({ sender: host }, ...args)
}

function openTab(tabId: string): FakeContents {
  const wc = new FakeContents()
  onWebContentsCreated?.({}, wc)
  const claimed = invoke('browser-view:claim', tabId) as { ok: boolean; reason?: string }
  expect(claimed.ok, claimed.reason).toBe(true)
  return wc
}

/** What the host renderer was pushed on one channel, tagged with the tab id. */
function pushes(channel: string): Array<{ tabId: unknown; payload: unknown }> {
  return host.sent.filter((entry) => entry.channel === channel)
}

/* -------------------------------------------------------------------- chords -- */

describe('what a keystroke inside the page means', () => {
  const down = (key: string, mods: Partial<{ meta: boolean; control: boolean; shift: boolean; alt: boolean }> = {}) =>
    ({ type: 'keyDown', key, ...mods })

  it('answers the chords any browser owes its user', () => {
    expect(guestChord(down('f', { meta: true }), false)).toBe('find')
    expect(guestChord(down('F', { control: true }), false)).toBe('find')
    expect(guestChord(down('=', { meta: true }), false)).toBe('zoom-in')
    expect(guestChord(down('+', { control: true, shift: true }), false)).toBe('zoom-in')
    expect(guestChord(down('-', { meta: true }), false)).toBe('zoom-out')
    expect(guestChord(down('0', { meta: true }), false)).toBe('zoom-reset')
    expect(guestChord(down('p', { meta: true }), false)).toBe('print')
  })

  it('leaves every chord it did not claim to the site', () => {
    // ⌘⇧F is Search Sessions, app-wide; ⌘⇧P would be the palette; a bare
    // letter is typing. Stealing any of them is the opposite defect.
    expect(guestChord(down('f', { meta: true, shift: true }), false)).toBeNull()
    expect(guestChord(down('p', { meta: true, shift: true }), false)).toBeNull()
    expect(guestChord(down('f'), false)).toBeNull()
    expect(guestChord(down('f', { alt: true, meta: true }), false)).toBeNull()
    // AltGr on Windows arrives as control+alt and must keep typing '=' into
    // the page rather than zooming it.
    expect(guestChord(down('=', { control: true, alt: true }), false)).toBeNull()
    expect(guestChord({ type: 'keyUp', key: 'f', meta: true }, false)).toBeNull()
  })

  it('gives Escape and ⌘G to the find bar only while one is up', () => {
    expect(guestChord(down('Escape'), true)).toBe('find-close')
    expect(guestChord(down('Escape'), false)).toBeNull()
    expect(guestChord(down('g', { meta: true }), true)).toBe('find-next')
    expect(guestChord(down('g', { meta: true, shift: true }), true)).toBe('find-prev')
    expect(guestChord(down('g', { meta: true }), false)).toBeNull()
  })
})

/* --------------------------------------------------------------- the route -- */

describe('⌘F inside a page reaches the renderer', () => {
  it('forwards the chord and keeps the key from the site and the app menu', () => {
    const wc = openTab('tab-chord')
    let prevented = 0
    wc.emit('before-input-event', { preventDefault: () => (prevented += 1) }, {
      type: 'keyDown',
      key: 'f',
      meta: true,
    })
    expect(prevented).toBe(1)
    const sent = pushes(KEY_CHANNEL)
    expect(sent.length).toBe(1)
    expect(sent[0].payload).toBe('find')
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('does not touch a keystroke that is not a chord', () => {
    const wc = openTab('tab-typing')
    let prevented = 0
    wc.emit('before-input-event', { preventDefault: () => (prevented += 1) }, {
      type: 'keyDown',
      key: 'a',
    })
    // Escape with no find open belongs to the site too.
    wc.emit('before-input-event', { preventDefault: () => (prevented += 1) }, {
      type: 'keyDown',
      key: 'Escape',
    })
    expect(prevented).toBe(0)
    expect(pushes(KEY_CHANNEL).length).toBe(0)
    releaseAllBrowserViews()
    host.sent.length = 0
  })
})

describe('running a find', () => {
  it('starts a session, steps it, and pushes what Chromium counted', () => {
    const wc = openTab('tab-find')
    invoke('browser-view:find', 'tab-find', 'needle', { first: true })
    expect(wc.finds).toEqual([{ text: 'needle', options: { forward: true, findNext: true } }])

    // Chromium answers on found-in-page; the renderer must get the count with
    // no arithmetic of this module's own in between.
    wc.emit('found-in-page', {}, { requestId: 1, activeMatchOrdinal: 2, matches: 17, finalUpdate: true })
    const sent = pushes(FIND_CHANNEL)
    expect(sent.length).toBe(1)
    expect(sent[0].payload).toEqual({ ordinal: 2, matches: 17, final: true })

    invoke('browser-view:find', 'tab-find', 'needle', { forward: false })
    expect(wc.finds[1]).toEqual({ text: 'needle', options: { forward: false, findNext: false } })
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('treats an emptied field as the end of the session, not a search for nothing', () => {
    const wc = openTab('tab-empty')
    invoke('browser-view:find', 'tab-empty', 'x', { first: true })
    invoke('browser-view:find', 'tab-empty', '', {})
    expect(wc.finds.length).toBe(1)
    expect(wc.stops).toEqual(['clearSelection'])
    // With the session over, Escape goes back to the site.
    let prevented = 0
    wc.emit('before-input-event', { preventDefault: () => (prevented += 1) }, {
      type: 'keyDown',
      key: 'Escape',
    })
    expect(prevented).toBe(0)
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('ignores a found-in-page with no session — devtools searches its own text', () => {
    const wc = openTab('tab-noise')
    wc.emit('found-in-page', {}, { requestId: 9, activeMatchOrdinal: 1, matches: 3, finalUpdate: true })
    expect(pushes(FIND_CHANNEL).length).toBe(0)
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('zeroes the count when the document the matches were on starts to leave', () => {
    const wc = openTab('tab-nav')
    invoke('browser-view:find', 'tab-nav', 'needle', { first: true })
    wc.emit('did-start-navigation', { isMainFrame: true, isSameDocument: false })
    const counts = pushes(FIND_CHANNEL)
    expect(counts[counts.length - 1].payload).toEqual({ ordinal: 0, matches: 0, final: true })
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('closing hands the keyboard back to the page and clears the highlights', () => {
    const wc = openTab('tab-close')
    invoke('browser-view:find', 'tab-close', 'needle', { first: true })
    invoke('browser-view:find-stop', 'tab-close', 'clear')
    expect(wc.stops).toEqual(['clearSelection'])
    expect(wc.focused).toBe(1)
    releaseAllBrowserViews()
    host.sent.length = 0
  })

  it('a tab released mid-find does not keep orange marks on the page', () => {
    const wc = openTab('tab-release')
    invoke('browser-view:find', 'tab-release', 'needle', { first: true })
    invoke('browser-view:release', 'tab-release')
    expect(wc.stops).toEqual(['clearSelection'])
    host.sent.length = 0
  })

  it('refuses every new channel for a tab that was never claimed', async () => {
    for (const channel of ['browser-view:find', 'browser-view:find-stop']) {
      expect(() => invoke(channel, 'nope'), channel).toThrow(/not open here/)
    }
    // The print handler is async, so its refusal arrives as a rejection.
    await expect(invoke('browser-view:print', 'nope') as Promise<void>).rejects.toThrow(
      /not open here/,
    )
  })
})

describe('printing', () => {
  it('resolves when the dialog goes well or the person changes their mind', async () => {
    const wc = openTab('tab-print')
    const printed = invoke('browser-view:print', 'tab-print') as Promise<void>
    expect(wc.printCb).not.toBeNull()
    wc.printCb?.(true, '')
    await expect(printed).resolves.toBeUndefined()

    const cancelled = invoke('browser-view:print', 'tab-print') as Promise<void>
    wc.printCb?.(false, 'cancelled')
    await expect(cancelled).resolves.toBeUndefined()
    releaseAllBrowserViews()
  })

  it('turns a refusal into a sentence rather than a resolved silence', async () => {
    const wc = openTab('tab-noprinter')
    const printed = invoke('browser-view:print', 'tab-noprinter') as Promise<void>
    wc.printCb?.(false, 'no valid printers available')
    await expect(printed).rejects.toThrow(/could not be printed: no valid printers available/)
    releaseAllBrowserViews()
  })
})
