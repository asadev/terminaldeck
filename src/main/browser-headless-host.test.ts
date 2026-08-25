import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
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
import { bindingFor, ownerOf, resetForTests, windowsOf } from './browser-binding'
import {
  clearProfileStorage,
  profileStorageOwner,
  resetProfileStorageForTests,
} from './browser-profile-storage'

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
  /**
   * What `Page.getNavigationHistory` answers, when a test is driving back or
   * forward. Empty by default, which is a page on its first document.
   */
  history: { currentIndex: number; entries: Array<{ id: number; url: string }> } = {
    currentIndex: -1,
    entries: [],
  }

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
      case 'Page.getNavigationHistory':
        return this.history
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

/**
 * A launch that answers a **separate** browser per user-data directory, and says
 * when each one is gone.
 *
 * The single-handle `fakeLaunch` above cannot show either of the two things this
 * file now has to: that a named profile is a second Chromium against its own
 * directory, and that emptying a profile waits for that process to end. A
 * browser that never reports its death is the case `HeadlessBrowserHandle.whenGone`
 * is optional for, and it is covered separately.
 */
function fakeLaunches(): {
  launch: LaunchBrowser
  /** Every `--user-data-dir` a browser was started against, in order. */
  dirs: string[]
  /** Stop the browser for a directory, as its process ending would. */
  died(dir: string): void
  stopped(dir: string): number
  transportFor(dir: string): FakeTransport
} {
  const dirs: string[] = []
  const transports = new Map<string, FakeTransport>()
  const stops = new Map<string, number>()
  const deaths = new Map<string, (why: string) => void>()

  const launch: LaunchBrowser = async ({ userDataDir: dir }) => {
    dirs.push(dir)
    const transport = new FakeTransport()
    transports.set(dir, transport)
    const whenGone = new Promise<string>((resolve) => deaths.set(dir, resolve))
    return {
      ok: true as const,
      handle: {
        transport,
        stop: () => stops.set(dir, (stops.get(dir) ?? 0) + 1),
        whenGone,
      },
    }
  }

  return {
    launch,
    dirs,
    died: (dir) => deaths.get(dir)?.('the browser exited'),
    stopped: (dir) => stops.get(dir) ?? 0,
    transportFor: (dir) => transports.get(dir) as FakeTransport,
  }
}

/** A profile id shaped the way `randomUUID` mints them, which is the only other shape accepted. */
const PROFILE = '7f2a1c94-3d8e-4b21-9a55-0c6d1e83f4b7'

/**
 * Write a `browser-profiles.json` naming these profiles, as the desktop's own
 * `browser-profiles.ts` writes it.
 *
 * The real file, not a stub: this host reads the machine's profile list to
 * refuse a window in a profile that does not exist, and a test that faked the
 * read would be testing a second idea of what a profile is.
 */
function writeProfiles(dir: string, ids: readonly string[]): void {
  mkdirSync(dir, { recursive: true })
  writeFileSync(
    join(dir, 'browser-profiles.json'),
    JSON.stringify({
      version: 1,
      activeId: 'default',
      profiles: [
        { id: 'default', name: 'Default', partition: 'persist:terminaldeck-browser', createdAt: 0 },
        ...ids.map((id, at) => ({
          id,
          name: `Profile ${at + 1}`,
          partition: `persist:terminaldeck-browser-${id}`,
          createdAt: 1,
        })),
      ],
    }),
  )
}

let userData: string

beforeEach(() => {
  resetForTests()
  resetProfileStorageForTests()
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

  /* ------------------------------------------------ the door that binds nothing -- */

  it('opens a window that is registered, closable and attached to nothing', async () => {
    /*
     * The door `machine-browser.ts` waited for. Its header recorded the hack it
     * was standing in for: the session door was the only one that minted a shell
     * id, so the phone's New Window went through it with a session id of `''`
     * and undid the attach in the next line. A window a phone opens belongs to
     * nobody — *"Nothing is chosen by default. Not the focused session, not the
     * newest, not the only one"* — and this is the door that means it.
     */
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    const opened = await host.openWindow({ url: 'https://example.com', isolate: false })
    expect(opened.ok).toBe(true)
    if (!opened.ok) return

    expect(opened.browserTabId).toMatch(/^browser:\d+:[0-9a-f]{8}$/)
    expect(host.contentsFor(opened.viewId)).not.toBeNull()
    // Registered, so it can be closed again — the property `openTab` does not
    // have and the reason the phone could never use that door.
    expect(await host.closeWindow(opened.browserTabId)).toBe(true)
    // And it was never in the binding store, under any session id.
    expect(ownerOf(opened.browserTabId)).toBeNull()
  })

  it('opens an isolated window in a throwaway context of its own', async () => {
    const { launch, transport } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })
    const opened = await host.openWindow({ url: 'https://example.com', isolate: true })
    expect(opened.ok).toBe(true)
    expect(transport.count('Target.createBrowserContext')).toBe(1)
    expect(transport.last('Target.createTarget')?.params.browserContextId).toMatch(/^ctx-/)
  })

  /* ------------------------------------------------------ one jar per profile -- */

  it('opens a named profile in a second Chromium with its own user-data directory', async () => {
    /*
     * *"We don't have profiles like we have in the Mac desktop application of the
     * browser."* On a server a profile is not a session partition — there is no
     * Electron to hand a partition name to — it is a whole second browser process
     * against `<userData>/Partitions/<profileId>`. Not a `--profile-directory`,
     * which selects a profile inside one user-data directory and cannot be chosen
     * per target over CDP, and not a browser context, which is the thing that
     * deliberately does not persist.
     */
    writeProfiles(userData, [PROFILE])
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })

    await host.openWindow({ url: 'https://a.example', isolate: false })
    await host.openWindow({ url: 'https://b.example', isolate: false, profileId: PROFILE })

    expect(launches.dirs).toEqual([
      join(userData, 'Partitions', 'default'),
      join(userData, 'Partitions', PROFILE),
    ])
    // Two browsers, and the second window was opened in the second one.
    expect(launches.transportFor(join(userData, 'Partitions', PROFILE)).count('Target.createTarget')).toBe(1)
  })

  it('refuses a profile id that is not one this app mints, without echoing it back', async () => {
    /*
     * The id arrives from a phone and becomes the last segment of a
     * `--user-data-dir`. `browser-profiles.ts` makes the same check for the same
     * reason — *"`fromPartition` will happily create a directory for **any**
     * string — including one with a path separator in it"* — and over this wire
     * the consequence is a browser launched somewhere else on the disk.
     */
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    const opened = await host.openWindow({
      url: 'https://a.example',
      isolate: false,
      profileId: '../../../../etc',
    })
    expect(opened.ok).toBe(false)
    if (!opened.ok) expect(opened.why).not.toContain('etc')
    expect(launches.dirs).toEqual([])
  })

  it('refuses a profile this machine does not have rather than minting one', async () => {
    // Opening a window in an unknown profile would *create* the jar — a new
    // empty cookie store on a server, made by a tap, listed by nothing.
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    const opened = await host.openWindow({ url: 'https://a.example', isolate: false, profileId: PROFILE })
    expect(opened.ok).toBe(false)
    if (!opened.ok) expect(opened.why).toContain('not a profile on this machine')
    expect(launches.dirs).toEqual([])
  })

  /* --------------------------------------------------- moving between the jars -- */

  it('re-opens a window in the other jar under the same window id', async () => {
    const { launch, transport } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })
    const opened = await host.openWindow({ url: 'https://example.com', isolate: false })
    expect(opened.ok).toBe(true)
    if (!opened.ok) return

    const moved = await host.repartitionWindow(opened.browserTabId, true)
    expect(moved).not.toBeNull()
    expect(moved?.viewId).not.toBe(opened.viewId)
    // A throwaway context for the new page, and the old target closed — in that
    // order, so a failure would have left the window exactly as it was.
    expect(transport.count('Target.createBrowserContext')).toBe(1)
    expect(transport.last('Target.closeTarget')?.params.targetId).toBe(opened.viewId)
    // The window is still the same window, and still closable by the same id.
    expect(host.contentsFor(moved?.viewId as string)).not.toBeNull()
    expect(await host.closeWindow(opened.browserTabId)).toBe(true)
  })

  /* ----------------------------------------------------------- back and forward -- */

  it('goes back to the entry it read out of the page’s own history', async () => {
    const { launch, transport } = fakeLaunch()
    transport.history = {
      currentIndex: 1,
      entries: [
        { id: 7, url: 'https://example.com/' },
        { id: 8, url: 'https://example.com/pricing' },
      ],
    }
    const host = new HeadlessDriveHost({ userData, launch })
    const viewId = (await host.openTab({ url: 'https://example.com/pricing', isolate: false })) as string

    expect(await host.historyMove(viewId, 'back')).toEqual({ moved: true })
    // The id was read out of the history, not composed: entry 7 is the
    // neighbour of the index the page is at.
    expect(transport.last('Page.navigateToHistoryEntry')?.params.entryId).toBe(7)
  })

  it('refuses a history entry whose address is not one this app would open', async () => {
    /*
     * A page cannot talk Chromium into a `file:` entry from an http document, so
     * this refusal should never fire — which is exactly why it is asserted. The
     * entry's URL goes through `isNavigationAllowed`, the same allow-list a typed
     * address passes, so the guard is screening what it always screened: where
     * the page is about to be.
     */
    const { launch, transport } = fakeLaunch()
    transport.history = {
      currentIndex: 1,
      entries: [
        { id: 7, url: 'file:///etc/passwd' },
        { id: 8, url: 'https://example.com/pricing' },
      ],
    }
    const host = new HeadlessDriveHost({ userData, launch })
    const viewId = (await host.openTab({ url: 'https://example.com/pricing', isolate: false })) as string

    const outcome = await host.historyMove(viewId, 'back')
    expect(outcome.moved).toBe(false)
    expect(transport.count('Page.navigateToHistoryEntry')).toBe(0)
  })

  it('says there is nothing to go back to rather than moving somewhere', async () => {
    const { launch, transport } = fakeLaunch()
    transport.history = { currentIndex: 0, entries: [{ id: 7, url: 'https://example.com/' }] }
    const host = new HeadlessDriveHost({ userData, launch })
    const viewId = (await host.openTab({ url: 'https://example.com/', isolate: false })) as string

    const outcome = await host.historyMove(viewId, 'back')
    expect(outcome.moved).toBe(false)
    if (!outcome.moved) expect(outcome.why).toContain('nothing to go back to')
    expect(transport.count('Page.navigateToHistoryEntry')).toBe(0)
  })

  it('stops every browser it launched', async () => {
    const { launch, stop } = fakeLaunch()
    const host = new HeadlessDriveHost({ userData, launch })
    await host.openTab({ url: 'https://example.com', isolate: false })
    await host.stop()
    expect(stop).toHaveBeenCalledTimes(1)
  })
})


/* ------------------------------------------------- emptying one of its jars -- */

/**
 * The phone's *Clear this profile*, from the end that owns the directory.
 *
 * The defect this replaces is the worst kind this codebase knows about: a
 * control that reported success it had not achieved. `browserProfilesFor` in
 * `remote/server.ts` rebuilt the profile directory out of the partition string
 * as `<stateDir>/browser/<partition>`, a path that has never existed on any
 * machine — the desktop's are at `<userData>/Partitions/<name>` and this host's
 * at `<userData>/Partitions/<profileId>` — and `rm(..., { force: true })` calls a
 * missing path a success. The screen said the profile was cleared and every
 * cookie was still there.
 *
 * So the directory is not rebuilt from a string any more. This host answers for
 * it, because this host is what chose the `--user-data-dir` and is holding the
 * Chromium with those files open.
 */
describe('emptying a profile on a server', () => {
  it('hands over the directory Chromium was launched with, not one assembled from a partition string', async () => {
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    await host.openWindow({ url: 'https://example.com', isolate: false })

    const owner = profileStorageOwner()
    expect(owner).not.toBeNull()
    // The same string, from the same source, as the one the browser is running
    // against. That equality is the whole fix.
    expect(owner?.directoryFor('default')).toBe(launches.dirs[0])
    expect(owner?.directoryFor('default')).toBe(join(userData, 'Partitions', 'default'))
    // And an id this app never minted is answered for by nobody, so no clear can
    // ever be pointed at a path built from one.
    expect(owner?.directoryFor('../../etc')).toBeNull()

    await host.stop()
  })

  it('removes the profile’s real directory, which the old path never touched', async () => {
    /*
     * The regression guard, stated as the two paths. The directory that exists is
     * the one Chromium runs against; the one the broken line named is
     * `<stateDir>/browser/<partition>`, and it is created here on purpose so that
     * a clear which deleted it — and only it — would still fail this test.
     */
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    await host.openWindow({ url: 'https://example.com', isolate: false })

    const real = join(userData, 'Partitions', 'default')
    mkdirSync(real, { recursive: true })
    writeFileSync(join(real, 'Cookies'), 'a session token')
    const oldGuess = join(userData, 'browser', 'terminaldeck-browser')
    mkdirSync(oldGuess, { recursive: true })

    const clearing = clearProfileStorage({
      userData,
      profileId: 'default',
      partition: 'persist:terminaldeck-browser',
    })
    // The browser is stopped first and the clear waits for it to be gone; this
    // is that process ending.
    await Promise.resolve()
    launches.died(real)
    const outcome = await clearing

    expect(outcome.state).toBe('cleared')
    expect(existsSync(real)).toBe(false)
    expect(launches.stopped(real)).toBe(1)
    // And the path the broken version deleted is still sitting there, which is
    // what makes this test fail against that version rather than pass by luck.
    expect(existsSync(oldGuess)).toBe(true)

    await host.stop()
  })

  it('takes the profile’s windows with it rather than leaving rows pointing at nothing', async () => {
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    await host.openForSession({ url: 'https://example.com', sessionId: 's1' })
    expect(windowsOf('s1', '')).toHaveLength(1)

    const dir = join(userData, 'Partitions', 'default')
    mkdirSync(dir, { recursive: true })
    const clearing = clearProfileStorage({
      userData,
      profileId: 'default',
      partition: 'persist:terminaldeck-browser',
    })
    await Promise.resolve()
    launches.died(dir)
    expect((await clearing).state).toBe('cleared')

    // A binding row outliving its page is *"an agent steering a window that is
    // not there"*, and a cleared profile has taken every one of its pages.
    expect(windowsOf('s1', '')).toEqual([])
    await host.stop()
  })

  it('does not report a clear when the browser would not stop', async () => {
    /*
     * The one outcome that used to be invisible. Deleting a directory Chromium
     * has open is not a clear — on Windows the unlink fails outright, and on
     * POSIX it succeeds while the running browser writes its in-memory jar back —
     * so a browser that will not stop stops the clear, before a file is removed.
     * The wait is `whenGone`, which is never resolved here.
     */
    const launches = fakeLaunches()
    const host = new HeadlessDriveHost({ userData, launch: launches.launch })
    await host.openWindow({ url: 'https://example.com', isolate: false })

    const dir = join(userData, 'Partitions', 'default')
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'Cookies'), 'a session token')

    vi.useFakeTimers()
    try {
      const clearing = clearProfileStorage({
        userData,
        profileId: 'default',
        partition: 'persist:terminaldeck-browser',
      })
      await vi.advanceTimersByTimeAsync(30_000)
      const outcome = await clearing
      expect(outcome.state).toBe('held')
      if (outcome.state === 'held') expect(outcome.why).toContain('had not stopped')
    } finally {
      vi.useRealTimers()
    }
    // Nothing was removed, which is what "not cleared" has to mean.
    expect(existsSync(join(dir, 'Cookies'))).toBe(true)
    await host.stop()
  })

  it('stops answering for its directories once it has stopped', async () => {
    // A registration that outlived its host would tell a clear to wait for a
    // process that has already ended.
    const host = new HeadlessDriveHost({ userData, launch: fakeLaunch().launch })
    expect(profileStorageOwner()).not.toBeNull()
    await host.stop()
    expect(profileStorageOwner()).toBeNull()
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
