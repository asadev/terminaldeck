import { describe, expect, it, vi } from 'vitest'
import type { IpcMain } from 'electron'

/**
 * The guest session has to be one stable object: `isGuest` compares a view's
 * session by identity, so a mock handing back a fresh `{}` per call would make
 * every view look foreign and quietly skip the half of this file that matters.
 */
const GUEST_SESSION = {}
const revealed: string[] = []
let onWebContentsCreated: ((event: unknown, wc: unknown) => void) | null = null

vi.mock('electron', () => ({
  app: {
    getPath: () => '/tmp',
    on: (event: string, fn: (event: unknown, wc: unknown) => void) => {
      if (event === 'web-contents-created') onWebContentsCreated = fn
    },
    userAgentFallback: 'Chromium',
  },
  shell: { showItemInFolder: (path: string) => revealed.push(path) },
  session: { fromPartition: () => GUEST_SESSION },
}))

const { clampZoom, screenshotName, registerBrowserViewIpc, releaseAllBrowserViews } = await import(
  './browser-view'
)
const { GUEST_RECORD_CHANNEL, GUEST_STEP_CHANNEL, safeAccent } = await import(
  './browser-record-preload'
)

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
  /** Everything the main process pushed into the page. */
  sent: Array<{ channel: string; payload: unknown }> = []
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
  send(channel: string, payload: unknown): void {
    this.sent.push({ channel, payload })
  }
  setZoomFactor(value: number): void {
    this.zoom = value
  }
  getZoomFactor(): number {
    return this.zoom
  }
  isDevToolsOpened(): boolean {
    return false
  }
  openDevTools(): void {}
  closeDevTools(): void {}
  setUserAgent(): void {}

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
  /** What the guest was last told about recording, if anything. */
  lastRecordMessage(): { on: boolean; accent: string } | null {
    for (let i = this.sent.length - 1; i >= 0; i--) {
      if (this.sent[i].channel === GUEST_RECORD_CHANNEL) {
        return this.sent[i].payload as { on: boolean; accent: string }
      }
    }
    return null
  }
}

const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
const channels = new Map<string, (event: unknown, ...args: unknown[]) => void>()

registerBrowserViewIpc({
  handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
    handlers.set(channel, fn)
  },
  on: (channel: string, fn: (event: unknown, ...args: unknown[]) => void) => {
    channels.set(channel, fn)
  },
} as unknown as IpcMain)

const host = new FakeContents()

function invoke(channel: string, ...args: unknown[]): unknown {
  const fn = handlers.get(channel)
  if (!fn) throw new Error(`no handler for ${channel}`)
  return fn({ sender: host }, ...args)
}

/** Announce a new guest view the way Electron does, then claim it as `tabId`. */
function openTab(tabId: string): FakeContents {
  const wc = new FakeContents()
  onWebContentsCreated?.({}, wc)
  const claimed = invoke('browser-view:claim', tabId) as { ok: boolean; reason?: string }
  expect(claimed.ok, claimed.reason).toBe(true)
  return wc
}

const RED = '#d44c47'

/* -------------------------------------------------------------------- tests -- */

describe('claiming a view', () => {
  it('refuses a devtools window, which reports the guest session as its own', () => {
    const devtools = new FakeContents()
    devtools.type = 'remote'
    onWebContentsCreated?.({}, devtools)
    expect(invoke('browser-view:claim', 'tab-dt')).toMatchObject({ ok: false })
  })

  it('refuses a tab id with nothing behind it rather than throwing later', () => {
    expect(invoke('browser-view:claim', '')).toMatchObject({ ok: false })
    expect(invoke('browser-view:claim', 42)).toMatchObject({ ok: false })
  })

  it('rejects every per-view call for a tab that was never claimed', () => {
    for (const channel of [
      'browser-view:zoom',
      'browser-view:devtools',
      'browser-view:user-agent',
      'browser-view:record',
      'browser-view:record-clear',
    ]) {
      expect(() => invoke(channel, 'nope'), channel).toThrow(/not open here/)
    }
  })
})

describe('recording across a navigation', () => {
  it('switches the guest back on for every new document', () => {
    const wc = openTab('tab-nav')
    invoke('browser-view:record', 'tab-nav', { on: true, accent: RED })
    expect(wc.lastRecordMessage()).toEqual({ on: true, accent: RED })

    // The regression: every document gets a fresh copy of the session preload,
    // so a recorder that is only armed once stops observing at the first
    // navigation — while the panel, the tab dot and the in-page badge all still
    // say Recording. A login flow navigates by definition, so this is most of
    // the flow the user thinks they just captured.
    wc.sent.length = 0
    wc.url = 'http://localhost:3000/dashboard'
    wc.emit('did-navigate', {}, wc.url)
    wc.emit('dom-ready')
    expect(wc.lastRecordMessage()).toEqual({ on: true, accent: RED })

    releaseAllBrowserViews()
  })

  it('does not arm a guest that was never recording', () => {
    const wc = openTab('tab-quiet')
    wc.emit('dom-ready')
    expect(wc.lastRecordMessage()).toBeNull()
    releaseAllBrowserViews()
  })

  it('keeps the accent when recording is stopped without one', () => {
    const wc = openTab('tab-accent')
    invoke('browser-view:record', 'tab-accent', { on: true, accent: RED })
    invoke('browser-view:record', 'tab-accent', { on: false })
    expect(wc.lastRecordMessage()).toEqual({ on: false, accent: RED })
    releaseAllBrowserViews()
  })

  it('tells the guest to stop when the tab is released', () => {
    // Release does not imply close: the workspace can unmount while its pages
    // live on. A guest left recording keeps capture-phase listeners and a badge
    // with nothing on this side listening.
    const wc = openTab('tab-release')
    invoke('browser-view:record', 'tab-release', { on: true, accent: RED })
    invoke('browser-view:release', 'tab-release')
    expect(wc.lastRecordMessage()?.on).toBe(false)
  })
})

describe('steps from the guest page', () => {
  const step = {
    v: 1,
    kind: 'click',
    target: { v: 1, path: [{ tag: 'button', id: 'go', idUnique: true }], text: 'Go', attributes: {} },
  }

  const stepsOf = (tabId: string): unknown[] =>
    (invoke('browser-view:record', tabId, { on: true, accent: RED }) as { steps: unknown[] }).steps

  it('ignores a step from a tab that is not recording', () => {
    const wc = openTab('tab-off')
    channels.get(GUEST_STEP_CHANNEL)?.({ sender: wc, senderFrame: wc.mainFrame }, step)
    // Turning recording on seeds one navigate step and nothing else: the click
    // sent while it was off was dropped rather than queued.
    expect(stepsOf('tab-off')).toHaveLength(1)
    releaseAllBrowserViews()
  })

  it('ignores a step from anything but the tab’s own main frame', () => {
    const wc = openTab('tab-frame')
    const before = stepsOf('tab-frame').length
    // A subframe: same WebContents, different frame. Fail closed.
    channels.get(GUEST_STEP_CHANNEL)?.({ sender: wc, senderFrame: { id: 999 } }, step)
    // And a frame that navigated away between send and receipt, which older
    // Electron reports by throwing rather than returning null.
    channels.get(GUEST_STEP_CHANNEL)?.(
      {
        sender: wc,
        get senderFrame(): never {
          throw new Error('frame is gone')
        },
      },
      step,
    )
    expect(stepsOf('tab-frame')).toHaveLength(before)
    releaseAllBrowserViews()
  })

  it('records a step from the main frame while recording', () => {
    const wc = openTab('tab-on')
    const before = stepsOf('tab-on').length
    channels.get(GUEST_STEP_CHANNEL)?.({ sender: wc, senderFrame: wc.mainFrame }, step)
    expect((invoke('browser-view:record-clear', 'tab-on') as { steps: unknown[] }).steps).toEqual([])
    expect(before).toBe(1)
    releaseAllBrowserViews()
  })
})

describe('revealing a screenshot', () => {
  it('refuses a path outside the screenshot directory', () => {
    revealed.length = 0
    invoke('browser-view:reveal', '/etc/passwd')
    invoke('browser-view:reveal', '/tmp/Pictures/Deck/../../../etc/passwd')
    invoke('browser-view:reveal', 42)
    expect(revealed).toEqual([])
  })

  it('reveals one of our own captures', () => {
    revealed.length = 0
    invoke('browser-view:reveal', '/tmp/Deck/example.com-20260812-163045.png')
    expect(revealed).toHaveLength(1)
  })
})

describe('zoom over the wire', () => {
  it('reads without writing when handed null', () => {
    const wc = openTab('tab-zoom')
    wc.zoom = 1.75
    expect(invoke('browser-view:zoom', 'tab-zoom', null)).toBe(1.75)
    expect(invoke('browser-view:zoom', 'tab-zoom', 12)).toBe(3)
    releaseAllBrowserViews()
  })
})

describe('screenshotName', () => {
  const at = new Date(2026, 7, 12, 16, 30, 45)

  it('names the file after the site and sorts chronologically', () => {
    expect(screenshotName('http://localhost:3000/dashboard', at)).toBe(
      'localhost-3000-20260812-163045.png',
    )
    expect(screenshotName('https://example.com/a/b', at)).toBe('example.com-20260812-163045.png')
  })

  it('cannot be talked into a path by the page it captured', () => {
    // The host comes from a URL the page can influence through redirects, and
    // this string is joined onto a directory.
    expect(screenshotName('http://a..%2F..%2Fetc/x', at)).not.toContain('/')
    expect(screenshotName('about:blank', at)).toBe('page-20260812-163045.png')
    expect(screenshotName('', at)).toBe('page-20260812-163045.png')
  })

  it('never starts with a dot, which would hide the file', () => {
    expect(screenshotName('http://[::1]:5173/', at).startsWith('.')).toBe(false)
  })
})

describe('clampZoom', () => {
  it('keeps zoom inside what Chromium will actually render', () => {
    expect(clampZoom(1)).toBe(1)
    expect(clampZoom(0.05)).toBe(0.25)
    expect(clampZoom(99)).toBe(3)
  })

  it('treats anything that is not a number as no zoom', () => {
    expect(clampZoom('2')).toBe(1)
    expect(clampZoom(Number.NaN)).toBe(1)
    // Not clamped to the maximum: an infinity is a bug upstream, not a request
    // for the biggest zoom, and answering it with 3 would hide that.
    expect(clampZoom(Number.POSITIVE_INFINITY)).toBe(1)
    expect(clampZoom(undefined)).toBe(1)
  })
})

describe('safeAccent', () => {
  it('accepts what a computed CSS custom property actually looks like', () => {
    expect(safeAccent('#2383e2')).toBe('#2383e2')
    expect(safeAccent(' #d44c47 ')).toBe('#d44c47')
    expect(safeAccent('rgba(212, 76, 71, 0.9)')).toBe('rgba(212, 76, 71, 0.9)')
  })

  it('refuses anything that could carry more than a colour into a style string', () => {
    // The value is spliced into an inline style inside an untrusted page.
    expect(safeAccent('red;position:fixed;top:0')).toBe('')
    expect(safeAccent('url(https://evil.example/x)')).toBe('')
    expect(safeAccent('expression(alert(1))')).toBe('')
    expect(safeAccent(42)).toBe('')
    expect(safeAccent(null)).toBe('')
  })
})
