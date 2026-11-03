import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { BLANK_URL } from './browser-url'
import {
  DRIVE_OPEN_CHANNEL,
  DRIVE_OPENED_CHANNEL,
  INSTALL_BROWSER_TIMEOUT_MS,
  INSTALL_REPUSH_MS,
  OPEN_TAB_TIMEOUT_MS,
  registerBrowserDriveIpc,
} from './browser-drive-ipc'

/**
 * Where the copilot's own page goes, and — since 2026-08-20 — where it does not.
 *
 * The original defect these tests were written for was that `browser.open` on an
 * app with no browser page open refused: the request was pushed at a
 * `BrowserWorkspace` that was not mounted, nobody answered, and the copilot fell
 * back to fetching the URL. That half still holds below.
 *
 * The half that had to change is who may answer. The push is a broadcast and
 * `claimDriveOpen` is first-come, so the pane that answered was whichever panel
 * happened to be mounted — and measured in the running app, two calls from a
 * cold start, that was a **session's own window**. The panel's tab strip is gone,
 * so its page was not moved aside, it was covered by a page in no strip anywhere,
 * and the binding map then pointed the session's window at the copilot's page.
 *
 * So the copilot now gets a pane of its own, asked for through the same channel
 * every link uses, and the drive request is *addressed* to it. What these tests
 * pin is that a pane is asked for before anything is driven, that the request
 * names it, and that a pane belonging to somebody else is never reused.
 *
 * Fake timers throughout, because the real waits are five and eight seconds and
 * a test that spent thirteen seconds proving a timeout is a test somebody
 * deletes.
 */

interface Sent {
  channel: string
  args: unknown[]
}

/** Just enough `IpcMain` for the three channels this module claims. */
function fakeIpcMain(): {
  ipcMain: Parameters<typeof registerBrowserDriveIpc>[0]
  fire(channel: string, ...args: unknown[]): void
} {
  const listeners = new Map<string, (event: unknown, ...args: unknown[]) => void>()
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const ipcMain = {
    on(channel: string, listener: (event: unknown, ...args: unknown[]) => void) {
      listeners.set(channel, listener)
      return ipcMain
    },
    handle(channel: string, handler: (event: unknown, ...args: unknown[]) => unknown) {
      handlers.set(channel, handler)
    },
  } as unknown as Parameters<typeof registerBrowserDriveIpc>[0]
  return {
    ipcMain,
    fire: (channel, ...args) => listeners.get(channel)?.({}, ...args),
  }
}

/**
 * A stand-in for the binding wiring: panes that can be opened, are nobody's
 * until said otherwise, and report a view when told to.
 */
function fakePanes() {
  let seq = 0
  const opened: { tabId: string; url: string }[] = []
  const taken = new Set<string>()
  const closed = new Set<string>()
  const views = new Map<string, string>()
  let refuse = false
  return {
    opened,
    /** The person attached this pane to a session, or closed it. */
    give: (tabId: string) => taken.add(tabId),
    close: (tabId: string) => closed.add(tabId),
    /** The renderer reported a view inside this pane. */
    show: (tabId: string, viewId: string) => views.set(tabId, viewId),
    refuseNext: () => {
      refuse = true
    },
    api: {
      open: async (url: string): Promise<string | null> => {
        if (refuse) {
          refuse = false
          return null
        }
        seq += 1
        const tabId = `browser:pane:${seq}`
        opened.push({ tabId, url })
        return tabId
      },
      free: (tabId: string): boolean => !taken.has(tabId) && !closed.has(tabId),
      view: async (tabId: string): Promise<string | null> => views.get(tabId) ?? null,
    },
  }
}

describe('the pane the copilot drives', () => {
  let sent: Sent[]
  let fire: (channel: string, ...args: unknown[]) => void
  let panes: ReturnType<typeof fakePanes>
  let openTab: (input: { url: string; isolate: boolean }) => Promise<string | null>

  beforeEach(() => {
    vi.useFakeTimers()
    sent = []
    panes = fakePanes()
    const ipc = fakeIpcMain()
    fire = ipc.fire
    const drive = registerBrowserDriveIpc(ipc.ipcMain, {
      send: (channel, ...args) => {
        sent.push({ channel, args })
      },
      pane: panes.api,
    })
    // The drive is the object under test only through its host, which is the
    // closure this module built. Reaching it through the constructed drive is
    // what makes this a test of the wiring rather than of a copy of it.
    openTab = (input) =>
      (drive as unknown as { host: { openTab: typeof openTab } }).host.openTab(input)
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  const opens = (): Sent[] => sent.filter((entry) => entry.channel === DRIVE_OPEN_CHANNEL)
  const idOf = (entry: Sent): string => (entry.args[0] as { id: string }).id
  const paneOf = (entry: Sent): unknown => (entry.args[0] as { pane?: unknown }).pane

  it('opens a pane of its own at the address, and drives the view that lands in it', async () => {
    panes.show('browser:pane:1', 'view-1')
    const promise = openTab({ url: 'https://example.com/', isolate: false })

    await expect(promise).resolves.toBe('view-1')
    // Its own pane, at the target URL — one page in one pane, so nothing is
    // covered and no second page is opened over it.
    expect(panes.opened).toEqual([{ tabId: 'browser:pane:1', url: 'https://example.com/' }])
    // Nothing was broadcast at all: there was nothing to *create* in a pane that
    // opens at the address itself.
    expect(opens()).toHaveLength(0)
  })

  it('never asks a pane that is somebody else’s — it opens another', async () => {
    panes.show('browser:pane:1', 'view-1')
    await expect(openTab({ url: 'https://example.com/', isolate: false })).resolves.toBe('view-1')

    // He attaches the copilot's pane to a session, by hand, in its own menu.
    // From that moment it is the session's window and the copilot moves out.
    panes.give('browser:pane:1')
    panes.show('browser:pane:2', 'view-2')
    await expect(openTab({ url: 'https://example.org/', isolate: false })).resolves.toBe('view-2')

    expect(panes.opened.map((entry) => entry.tabId)).toEqual(['browser:pane:1', 'browser:pane:2'])
  })

  it('reuses its own pane rather than opening a row per page', async () => {
    panes.show('browser:pane:1', 'view-1')
    await expect(openTab({ url: 'https://example.com/', isolate: false })).resolves.toBe('view-1')

    // The view inside it died — an isolation switch, a crash — but the pane is
    // still open and still nobody's, so the replacement goes in there.
    const promise = openTab({ url: 'https://example.org/', isolate: false })
    await vi.advanceTimersByTimeAsync(1)
    expect(opens()).toHaveLength(1)
    expect(paneOf(opens()[0])).toBe('browser:pane:1')
    fire(DRIVE_OPENED_CHANNEL, idOf(opens()[0]), 'view-2')

    await expect(promise).resolves.toBe('view-2')
    expect(panes.opened).toHaveLength(1)
  })

  it('addresses the request, so no other panel can claim it', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: true })
    await vi.advanceTimersByTimeAsync(1)

    // Isolated: the partition is fixed when the view is constructed, so the
    // page has to be *created* by the renderer and the pane is opened blank.
    expect(panes.opened).toEqual([{ tabId: 'browser:pane:1', url: BLANK_URL }])
    const request = opens().at(-1) as Sent
    expect(paneOf(request)).toBe('browser:pane:1')
    expect((request.args[0] as { isolate: boolean }).isolate).toBe(true)

    fire(DRIVE_OPENED_CHANNEL, idOf(request), 'view-iso')
    await expect(promise).resolves.toBe('view-iso')
  })

  it('repeats the request under one id while the pane’s panel mounts', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: true })
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS * 4)

    const repeats = opens()
    expect(repeats.length).toBeGreaterThan(1)
    // One id across every repeat. `claimDriveOpen` in the renderer dedupes by
    // id, so this is what stops four pushes producing four pages.
    expect(new Set(repeats.map(idOf)).size).toBe(1)

    await vi.advanceTimersByTimeAsync(INSTALL_BROWSER_TIMEOUT_MS)
    await expect(promise).resolves.toBeNull()
  })

  it('answers null when no window will open a pane at all', async () => {
    // The browser switched off in Features is a real state and the tool has to
    // be able to say so. A fallback that drove somebody else's pane instead
    // would be the seizure this whole arrangement exists to stop.
    panes.refuseNext()
    await expect(openTab({ url: 'https://example.com/', isolate: false })).resolves.toBeNull()
    expect(opens()).toHaveLength(0)
  })

  it('answers null when the pane opens and never reports a page', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })
    await vi.advanceTimersByTimeAsync(INSTALL_BROWSER_TIMEOUT_MS + 100)
    await expect(promise).resolves.toBeNull()
  })

  it('stops pushing once an answer arrives', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: true })
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS)
    fire(DRIVE_OPENED_CHANNEL, idOf(opens().at(-1) as Sent), 'view-3')
    await expect(promise).resolves.toBe('view-3')

    const settled = opens().length
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS * 5)
    expect(opens()).toHaveLength(settled)
  })

  it('waits no longer than the short budget on a pane that is already there', async () => {
    panes.show('browser:pane:1', 'view-1')
    await expect(openTab({ url: 'https://example.com/', isolate: false })).resolves.toBe('view-1')

    const promise = openTab({ url: 'https://example.org/', isolate: false })
    await vi.advanceTimersByTimeAsync(OPEN_TAB_TIMEOUT_MS + 10)
    await expect(promise).resolves.toBeNull()
  })
})
