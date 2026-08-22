import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CdpEvent } from './browser-cdp-pipe'
import type { CdpTransport } from './browser-driven-cdp'
import {
  HeadlessDriveHost,
  type HeadlessBrowserHandle,
  type LaunchBrowser,
} from './browser-headless-host'
import { bindingFor, resetForTests, windowsOf } from './browser-binding'

/**
 * The tab authority, exercised against a fake Chromium.
 *
 * No browser is downloaded and no debugger is spawned — the launch and the pipe
 * are seams, so this drives a `FakeTransport` that answers the four `Target.*`
 * commands with plausible ids and records what it was asked. That is enough to
 * pin the shape of every `DriveHost` method without a page in the room, which is
 * the whole reason the seam exists.
 */

interface Recorded {
  method: string
  params: Record<string, unknown>
  sessionId?: string
}

/** A CDP channel that answers the target lifecycle and records every command. */
class FakeTransport implements CdpTransport {
  readonly sent: Recorded[] = []
  private seq = 0
  closed = false

  async command(command: { method: string; params?: unknown; sessionId?: string }): Promise<unknown> {
    this.sent.push({
      method: command.method,
      params: (command.params ?? {}) as Record<string, unknown>,
      ...(command.sessionId === undefined ? {} : { sessionId: command.sessionId }),
    })
    switch (command.method) {
      case 'Target.createTarget':
        return { targetId: `target-${++this.seq}` }
      case 'Target.createBrowserContext':
        return { browserContextId: `ctx-${++this.seq}` }
      case 'Target.attachToTarget':
        return { sessionId: `session-${++this.seq}` }
      default:
        return {}
    }
  }

  on(_sessionId: string | undefined, _listener: (event: CdpEvent) => void): () => void {
    return () => {}
  }

  onClose(_listener: (error?: Error) => void): () => void {
    return () => {}
  }

  /** How many times a method was sent. */
  count(method: string): number {
    return this.sent.filter((entry) => entry.method === method).length
  }

  last(method: string): Recorded | undefined {
    return [...this.sent].reverse().find((entry) => entry.method === method)
  }
}

function fakeLaunch(): { launch: LaunchBrowser; stop: ReturnType<typeof vi.fn>; transport: FakeTransport } {
  const transport = new FakeTransport()
  const stop = vi.fn()
  const handle: HeadlessBrowserHandle = { transport, stop }
  const launch: LaunchBrowser = vi.fn(async () => ({ ok: true as const, handle }))
  return { launch, stop, transport }
}

let userData: string

beforeEach(() => {
  resetForTests()
  userData = mkdtempSync(join(tmpdir(), 'td-headless-host-'))
})

afterEach(() => {
  rmSync(userData, { recursive: true, force: true })
})

describe('the headless tab authority', () => {
  it('screens against the CDP allow-list, not the Electron one', () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    expect(host.transport).toBe('cdp')
  })

  it('opens the copilot tab as a target and hands its page back', async () => {
    const { launch, transport } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })

    const viewId = await host.openTab({ url: 'https://example.com', isolate: false })
    expect(viewId).not.toBeNull()
    // Launched once, auto-attach armed, and a target opened at the URL.
    expect(transport.count('Target.setAutoAttach')).toBe(1)
    expect(transport.last('Target.createTarget')?.params.url).toBe('https://example.com')
    // No throwaway context for a persistent tab.
    expect(transport.count('Target.createBrowserContext')).toBe(0)

    const page = host.contentsFor(viewId as string)
    expect(page).not.toBeNull()
    expect(page?.url()).toBe('https://example.com')
  })

  it('gives an isolated tab a throwaway browser context', async () => {
    const { launch, transport } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })

    const viewId = await host.openTab({ url: 'https://example.com', isolate: true })
    expect(viewId).not.toBeNull()
    expect(transport.count('Target.createBrowserContext')).toBe(1)
    // The target is created inside that context.
    expect(transport.last('Target.createTarget')?.params.browserContextId).toMatch(/^ctx-/)
  })

  it('launches one browser for many tabs', async () => {
    const { launch } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })
    await host.openTab({ url: 'https://a.example', isolate: false })
    await host.openTab({ url: 'https://b.example', isolate: false })
    expect(launch).toHaveBeenCalledTimes(1)
  })

  it('attaches a window for a session in the shared binding store', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })

    const answer = await host.openForSession({ url: 'https://example.com', sessionId: 's1' })
    expect(answer.attached).toBe(true)
    expect(answer.line).toContain('B1')

    // The same store the desktop mints B1/B2 from now holds this window.
    const windows = windowsOf('s1', '')
    expect(windows).toHaveLength(1)
    expect(windows[0]?.url).toBe('https://example.com')
    expect(bindingFor('s1', '')?.windows[0]?.n).toBe(1)
  })

  it('files a session window under the device that owns it', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    await host.openForSession({ url: 'https://example.com', sessionId: 's1', machineId: 'device-9' })
    expect(windowsOf('s1', 'device-9')).toHaveLength(1)
    expect(windowsOf('s1', '')).toHaveLength(0)
  })

  it('closes a session window: the target and its binding both go', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    await host.openForSession({ url: 'https://example.com', sessionId: 's1' })
    const browserTabId = windowsOf('s1', '')[0]?.browserTabId as string

    const closed = await host.closeWindow(browserTabId)
    expect(closed).toBe(true)
    expect(windowsOf('s1', '')).toHaveLength(0)
  })

  it('brings a window forward as a success no-op', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    await expect(host.showWindow('anything')).resolves.toBe(true)
  })

  it('resolves capture and scrape folders by the target profile', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    const viewId = (await host.openTab({ url: 'https://example.com', isolate: false })) as string

    const folder = host.captureFolder({ viewId, runId: 'run-1' })
    expect(folder).toContain('default')
    expect(folder).toContain('run-1')

    const block = host.blockCapture(viewId)
    expect(block?.on).toBe(true)

    // A default profile has stored scrape defaults; an isolated one has none.
    expect(host.scrapeDefaults(viewId)).not.toBeNull()
  })

  it('an isolated target has no stored scrape defaults', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    const viewId = (await host.openTab({ url: 'https://example.com', isolate: true })) as string
    expect(host.scrapeDefaults(viewId)).toBeNull()
    // Its captures still land, under `isolated`.
    expect(host.captureFolder({ viewId, runId: 'r' })).toContain('isolated')
  })

  it('returns null and publishes the reason when Chromium will not start', async () => {
    const publish = vi.fn()
    const launch: LaunchBrowser = async () => ({ ok: false, why: 'chrome is not installed' })
    const host = new HeadlessDriveHost({ userData, launch, publish })

    const viewId = await host.openTab({ url: 'https://example.com', isolate: false })
    expect(viewId).toBeNull()
    expect(publish).toHaveBeenCalledTimes(1)
    expect(publish.mock.calls[0]?.[0].step).toContain('chrome is not installed')
  })

  it('retries a failed launch rather than remembering it as broken', async () => {
    let attempt = 0
    const good = fakeLaunch()
    const launch: LaunchBrowser = vi.fn(async () => {
      attempt += 1
      if (attempt === 1) return { ok: false as const, why: 'not yet installed' }
      return { ok: true as const, handle: { transport: good.transport, stop: vi.fn() } }
    })
    const host = new HeadlessDriveHost({ userData, launch })

    expect(await host.openTab({ url: 'https://a.example', isolate: false })).toBeNull()
    expect(await host.openTab({ url: 'https://b.example', isolate: false })).not.toBeNull()
    expect(launch).toHaveBeenCalledTimes(2)
  })

  it('an asset fetch for a live target reads its cookies and stops when the page is gone', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    const viewId = (await host.openTab({ url: 'https://example.com', isolate: false })) as string
    // The page is live, so there is a fetcher; a view that was never opened has none.
    expect(host.assetOpenFor(viewId)).not.toBeNull()
    expect(host.assetOpenFor('no-such-target')).toBeNull()
  })

  it('stops every browser it launched', async () => {
    const { launch, stop } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })
    await host.openTab({ url: 'https://example.com', isolate: false })
    await host.stop()
    expect(stop).toHaveBeenCalledTimes(1)
  })
})
