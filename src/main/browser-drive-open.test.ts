import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { BLANK_URL } from './browser-url'
import { LINK_TAB_CHANNEL } from './link-open'
import {
  DRIVE_OPEN_CHANNEL,
  DRIVE_OPENED_CHANNEL,
  INSTALL_BROWSER_TIMEOUT_MS,
  INSTALL_REPUSH_MS,
  OPEN_TAB_TIMEOUT_MS,
  registerBrowserDriveIpc,
} from './browser-drive-ipc'

/**
 * `browser.open` on an app with no browser page open.
 *
 * This is the whole of the reported defect, pinned. Asad asked his copilot to go
 * to a page and it could not — not because the driving was broken, which it is
 * not, but because the request was pushed at a `BrowserWorkspace` component that
 * was not mounted, nobody answered, and the tool refused. Reproduced on
 * 2026-08-18 against the packaged build on the first ask in a fresh window.
 *
 * What these tests hold is the *connection*, which is the half this codebase has
 * repeatedly written and then left unwired: that a silent first attempt is
 * followed by a request for a browser page on the channel a window always
 * listens on, and that the retry re-pushes **the same id** so that the repeats
 * cannot each become a tab.
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

describe('opening a browser page for a copilot that has none', () => {
  let sent: Sent[]
  let fire: (channel: string, ...args: unknown[]) => void
  let openTab: (input: { url: string; isolate: boolean }) => Promise<string | null>

  beforeEach(() => {
    vi.useFakeTimers()
    sent = []
    const ipc = fakeIpcMain()
    fire = ipc.fire
    const drive = registerBrowserDriveIpc(ipc.ipcMain, {
      send: (channel, ...args) => {
        sent.push({ channel, args })
      },
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

  it('answers with the tab when a workspace is already mounted, and asks for nothing else', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })
    expect(opens()).toHaveLength(1)
    fire(DRIVE_OPENED_CHANNEL, idOf(opens()[0]), 'browser:1')

    await expect(promise).resolves.toBe('browser:1')
    expect(sent.some((entry) => entry.channel === LINK_TAB_CHANNEL)).toBe(false)
  })

  it('asks the window for a browser page when nothing answers, then drives the one it gets', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })

    // Nobody is mounted: the first attempt runs out.
    await vi.advanceTimersByTimeAsync(OPEN_TAB_TIMEOUT_MS)

    const install = sent.find((entry) => entry.channel === LINK_TAB_CHANNEL)
    expect(install).toBeDefined()
    // `about:blank` and not the target, or the link channel opens the page
    // itself and the drive then opens a second tab at the same address.
    expect(install?.args[0]).toBe(BLANK_URL)

    // React mounts a `BrowserWorkspace`, which subscribes and hears a repeat.
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS * 2)
    const second = opens().at(-1)
    expect(second).toBeDefined()
    fire(DRIVE_OPENED_CHANNEL, idOf(second as Sent), 'browser:2')

    await expect(promise).resolves.toBe('browser:2')
  })

  it('repeats the second request under one id, so the repeats cannot become one tab each', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })
    await vi.advanceTimersByTimeAsync(OPEN_TAB_TIMEOUT_MS)
    const before = opens().length
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS * 4)

    const repeats = opens().slice(before)
    expect(repeats.length).toBeGreaterThan(1)
    // One id across every repeat. `claimDriveOpen` in the renderer dedupes by
    // id, so this is what stops four pushes producing four browser tabs.
    expect(new Set(repeats.map(idOf)).size).toBe(1)

    await vi.advanceTimersByTimeAsync(INSTALL_BROWSER_TIMEOUT_MS)
    await expect(promise).resolves.toBeNull()
  })

  it('still answers null when the window will not produce a page at all', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })
    await vi.advanceTimersByTimeAsync(OPEN_TAB_TIMEOUT_MS + INSTALL_BROWSER_TIMEOUT_MS + 100)

    // The browser switched off in Features is a real state and the tool has to
    // be able to say so. A fallback that invented a window instead would be the
    // "page you cannot see or close" this module refuses to make.
    await expect(promise).resolves.toBeNull()
  })

  it('stops pushing once an answer arrives', async () => {
    const promise = openTab({ url: 'https://example.com/', isolate: false })
    await vi.advanceTimersByTimeAsync(OPEN_TAB_TIMEOUT_MS + INSTALL_REPUSH_MS)
    fire(DRIVE_OPENED_CHANNEL, idOf(opens().at(-1) as Sent), 'browser:3')
    await expect(promise).resolves.toBe('browser:3')

    const settled = opens().length
    await vi.advanceTimersByTimeAsync(INSTALL_REPUSH_MS * 5)
    expect(opens()).toHaveLength(settled)
  })
})
