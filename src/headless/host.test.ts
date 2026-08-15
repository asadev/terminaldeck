import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from '../main/platform/paths'
import { REMOTE_CONNECTIONS_CHANNEL } from '../main/remote/server'
import { store } from '../main/store'
import { createHeadlessHost, type HeadlessHost } from './host'

/**
 * The headless host, started for real, under plain Node.
 *
 * This is the test that matters. Everything else in this folder checks a
 * function; this one checks the claim — that the core runs with no Electron
 * anywhere near it. Vitest is a Node process with no `app`, no `ipcMain` and no
 * BrowserWindow, so a single Electron import anywhere in the graph would make
 * this file fail to import rather than fail an assertion.
 *
 * What it deliberately does not do is touch the network. `relayEnabled: false`
 * keeps it off the public relay and `readTailnet` is pinned to "signed out", so
 * the host comes up, refuses to serve, and says why — which is itself one of the
 * states `status` has to be able to describe.
 */

let dir = ''
let host: HeadlessHost

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-headless-'))
  // The same provider the daemon installs, pointed at a temp home so nothing
  // here can read or write the real state directory on this Mac.
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  host = await createHeadlessHost({
    storageDir: dir,
    relayEnabled: false,
    readTailnet: async () => ({
      ready: false,
      state: 'logged-out',
      reason: 'This machine is signed out of Tailscale.',
    }),
    serve: {
      on: async () => ({ ok: false, message: 'not in a test' }),
      off: async () => undefined,
    },
  })
}, 30_000)

afterAll(async () => {
  await host.stop()
  resetPaths()
  rmSync(dir, { recursive: true, force: true })
})

describe('it starts with no Electron in the process', () => {
  it('registers the same channels the desktop registers', () => {
    // Not a stub of pairing, not a headless-only copy: these are the handler
    // bodies `registerRemoteIpc` installs, and the CLI calls them by the names
    // the preload uses.
    const channels = host.desk.channels()
    for (const channel of [
      'remote:status',
      'remote:pair',
      'remote:devices',
      'remote:device:approve',
      'remote:folders',
      'remote:folders:set',
    ]) {
      expect(channels).toContain(channel)
    }
  })

  it('answers remote:status with a reason rather than pretending to serve', async () => {
    const status = await host.status()
    expect(status.remote.running).toBe(false)
    expect(status.remote.reason ?? status.remote.directReason).toBeTruthy()
  })
})

describe('pairing is the desktop mechanism, not a second one', () => {
  it('mints a code of the same alphabet and shape the app shows', async () => {
    const minted = (await host.invoke('remote:pair')) as { token: string; expiresAt: number }
    // Eight symbols from the Crockford-style alphabet in shared/short-code.ts,
    // already grouped, because that is the form both screens show. A headless
    // build with its own code format would be a second thing for a phone to be
    // wrong about.
    expect(minted.token).toMatch(/^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}-[0-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$/)
    expect(minted.expiresAt).toBeGreaterThan(Date.now())
  })

  it('starts with no devices and no grants', async () => {
    expect(await host.invoke('remote:devices')).toEqual([])
    expect(await host.invoke('remote:folders')).toEqual([])
  })

  it('writes a grant through the same handler the settings panel uses', async () => {
    const written = (await host.invoke('remote:folders:set', 'device-1', [dir])) as Array<{
      deviceId: string
      folders: string[]
    }>
    expect(written).toEqual([{ deviceId: 'device-1', folders: [dir] }])
    expect(await host.invoke('remote:folders')).toEqual(written)
  })
})

describe('idle mode', () => {
  it('starts idle, holding only the relay connection', async () => {
    const status = await host.status()
    expect(status.idle.mode).toBe('idle')
    expect(status.idle.attached).toBe(0)
    expect(status.idle.holding).toEqual(['relay connection'])
    expect(status.idle.stopped).toContain('session status detection')
    expect(status.idle.stopped).toContain('localhost port scan cache')
  })

  it('wakes when a device attaches and idles again when the last one leaves', async () => {
    /*
     * Driven through the connections broadcast, which is the event the server
     * already fires — not through a method this test reaches for. If idle mode
     * were wired to anything else, this would pass while the real host never
     * woke.
     */
    host.broadcast(REMOTE_CONNECTIONS_CHANNEL, [{}, {}])
    expect((await host.status()).idle.mode).toBe('awake')
    expect((await host.status()).idle.stopped).toEqual([])

    host.broadcast(REMOTE_CONNECTIONS_CHANNEL, [])
    expect((await host.status()).idle.mode).toBe('idle')
  })

  it('ignores every other channel it is handed', async () => {
    // `broadcast` is the shell's whole outbound surface, and the endpoint pushes
    // more than one thing down it. Only the connection list may move idle mode.
    host.broadcast('remote:something-else', [{}, {}, {}])
    expect((await host.status()).idle.attached).toBe(0)
  })

  it('names what it never had rather than claiming to have stopped it', async () => {
    // The specification lists six things to stop and this build only ever ran
    // three. Silence about the other three is indistinguishable from forgetting
    // them.
    const status = await host.status()
    expect(status.neverRunning.join(' ')).toContain('cost polling')
    expect(status.neverRunning.join(' ')).toContain('transcript tailing')
  })
})

describe('status', () => {
  it('describes the machine it is on and what to do about staying reachable', async () => {
    const status = await host.status()
    expect(status.pid).toBe(process.pid)
    expect(status.stateDir).toBe(dir)
    expect(status.reachability.headline).not.toBe('')
    expect(status.reachability.kind).toBeTruthy()
  })
})

describe('sessions, which are the whole point', () => {
  /*
   * A real pty, spawned by the real starter, in a plain Node process.
   *
   * Everything else here checks that the plumbing is connected; this checks that
   * the thing on the end of it works. node-pty is a native module and the one
   * dependency that could plausibly behave differently outside Electron, and a
   * headless build whose sessions do not run is not a reduced product — it is no
   * product at all.
   */
  it('starts a shell in a folder and shows what it printed', async () => {
    const meta = await host.core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell' })
    expect(meta.cwd).toBe(dir)

    host.core.ptys.write(meta.id, 'echo headless-works\r')
    const printed = await waitFor(() => {
      const text = host.core.ptys.scrollback(meta.id)
      return text.includes('headless-works') ? text : null
    })
    expect(printed).toContain('headless-works')

    host.core.ptys.kill(meta.id)
  }, 30_000)

  it('remembers the session so a restart can put it back', async () => {
    /*
     * The half that matters most on WSL: the distribution is shut down when the
     * last terminal closes, taking every session with it, so the list on disk is
     * the difference between "the sessions came back" and "the day's work is
     * gone".
     */
    const meta = await host.core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell' })
    const remembered = storedSessions()
    expect(remembered.some((session) => session.cwd === dir)).toBe(true)

    host.core.ptys.kill(meta.id)
    await waitFor(() => (storedSessions().length === 0 ? true : null))
  }, 30_000)
})

function storedSessions(): Array<{ cwd: string }> {
  return store().getOpenSessions()
}

/**
 * Wait for something to become true, without a fixed sleep.
 *
 * A pty's output arrives on its own schedule and a fixed delay is either flaky
 * or slow. This is a poll and it is allowed to be one: it is a test waiting on
 * another process, not a running host waiting on an event it could have
 * subscribed to.
 */
async function waitFor<T>(check: () => T | null, timeoutMs = 15_000): Promise<T> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const value = check()
    if (value !== null) return value
    if (Date.now() > deadline) throw new Error('timed out waiting for the session')
    await new Promise((done) => setTimeout(done, 50))
  }
}
