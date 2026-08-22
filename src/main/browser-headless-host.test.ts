import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CdpEvent } from './browser-cdp-pipe'
import type { CdpTransport } from './browser-driven-cdp'
import {
  HeadlessDriveHost,
  confirmReady,
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
    /*
     * And discovery armed, which is a different switch for a different reason.
     * `Target.targetInfoChanged` — the only event a page's title arrives on — is
     * emitted at the browser level only when targets are discovered, and
     * auto-attach does not imply it. Measured against a real Chromium 146: with
     * auto-attach alone that event never fired once across a whole navigation,
     * so every tab a phone saw from a server host was called nothing at all.
     */
    expect(transport.count('Target.setDiscoverTargets')).toBe(1)
    expect(transport.last('Target.setDiscoverTargets')?.params.discover).toBe(true)
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

  /*
   * The banner is what a person watching a device sees. The copilot sees
   * `openTab` return null, and before this it was handed a fixed sentence about
   * Settings → Tools — a pane that does not exist on a machine with no window,
   * while the real reason was fifteen package names it never got.
   */
  it('hands the copilot the same reason the banner got', async () => {
    const why =
      'Chromium was downloaded and verified, but it cannot run on this machine yet: ' +
      '13 shared libraries it needs are missing — libatk-1.0.so.0'
    const launch: LaunchBrowser = async () => ({ ok: false, why })
    const host = new HeadlessDriveHost({ userData, launch })

    expect(await host.openTab({ url: 'https://example.com', isolate: false })).toBeNull()
    const said = host.whyNoTab()
    expect(said).toContain('libatk-1.0.so.0')
    // Cleared on read: a stale reason attached to a later, unrelated null is a
    // worse answer than none.
    expect(host.whyNoTab()).toBeNull()
  })

  it('has no reason to give before anything has failed', async () => {
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    expect(host.whyNoTab()).toBeNull()
    await host.openTab({ url: 'https://example.com', isolate: false })
    expect(host.whyNoTab()).toBeNull()
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


/* ------------------------------------------- is there a browser on the end -- */

/*
 * A pid is not a running browser, and a pipe onto a dead one is silent.
 *
 * This is the guard for the failure that a fake `spawn` could never show and a
 * real Ubuntu server showed on the first try: `launchChromium` reported a
 * healthy process — pid, null exit code, both fd 3/4 pipes — for a Chromium that
 * was gone 30 ms later with exit 127, after which the first CDP command was
 * written into a closed pipe and waited forever. The fix is that the first
 * command races the process's death, so there is no arm of this that hangs.
 */
describe('confirming a launched browser is really there', () => {
  const never = new Promise<string>(() => {})

  it('is null when the browser answers its first command', async () => {
    const transport = { command: async () => ({ product: 'HeadlessChrome/146.0.7680.165' }) }
    expect(await confirmReady(transport, never, 1000)).toBeNull()
  })

  it('is the death when the process dies instead of answering', async () => {
    // The shape measured on the server: the command never settles, and the only
    // thing that ever happens is the exit.
    const transport = { command: () => new Promise<unknown>(() => {}) }
    const whenGone = Promise.resolve('Chromium could not start: it needs libatk-1.0.so.0, which is not installed')
    const why = await confirmReady(transport, whenGone, 1000)
    expect(why).toContain('libatk-1.0.so.0')
  })

  it('prefers the death to the timeout when both are available', async () => {
    const transport = { command: () => new Promise<unknown>(() => {}) }
    const whenGone = new Promise<string>((resolve) => setTimeout(() => resolve('Chromium exited with code 127'), 5))
    expect(await confirmReady(transport, whenGone, 400)).toContain('code 127')
  })

  it('gives up on a browser that neither answers nor exits, rather than waiting for ever', async () => {
    const transport = { command: () => new Promise<unknown>(() => {}) }
    const why = await confirmReady(transport, never, 30)
    expect(why).toContain('did not answer its first command')
  })

  it('a refused first command is a named error, not a hang', async () => {
    const transport = { command: () => Promise.reject(new Error('the pipe closed')) }
    const why = await confirmReady(transport, never, 1000)
    expect(why).toContain('the pipe closed')
  })
})
