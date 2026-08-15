/**
 * Remote access dials out at launch, unless this Mac was told not to.
 *
 * ## Why this file exists
 *
 * The requirement is A1.1/A1.2: reach your Mac from a phone with no Tailscale,
 * no VPN, and **no online/offline toggle** — it just works. The code did the
 * opposite for as long as the relay has existed. `registerRemoteIpc` built the
 * server and then waited: `start()` ran only from the `remote:start` channel,
 * which only the Settings panel calls, which needs two presses. Nothing re-ran
 * it on the next launch.
 *
 * That is not a subtle gap. Measured on the machine this was written on: the
 * host identity on disk, two paired iPhones in the trust store, the relay
 * reachable — and not one socket from this Mac to it. A phone attaching to that
 * host was attaching to something that was not there.
 *
 * Nothing in the type system could have caught it and no existing test did,
 * because every test that starts a server calls `start()` itself. So the thing
 * asserted here is the one thing those cannot assert: that **nobody has to**.
 */
import { describe, expect, it } from 'vitest'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  registerRemoteIpc,
  type RemoteIpcDeps,
  type SessionAccess,
  type SessionHandle,
} from './server'
import type { RemoteSession } from './protocol'
import { FolderGrants } from './folder-grants'

/** Enough of a session layer to construct the server. Nothing attaches here. */
function fakeSessions(): SessionAccess {
  const session: RemoteSession = {
    id: 'sess-1',
    title: 'agent',
    cwd: '/tmp/project',
    provider: 'claude',
    status: 'running',
    exitCode: null,
  }
  return {
    list: () => [session],
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
  }
}

/** A stand-in for `ipcMain` that keeps the handlers so a test can call them. */
function fakeIpc(): {
  ipcMain: Parameters<typeof registerRemoteIpc>[0]
  call(channel: string): Promise<unknown>
} {
  const handlers = new Map<string, (...args: unknown[]) => unknown>()
  return {
    ipcMain: {
      handle(channel: string, handler: (...args: unknown[]) => unknown) {
        handlers.set(channel, handler)
      },
    } as unknown as Parameters<typeof registerRemoteIpc>[0],
    async call(channel) {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler({})
    },
  }
}

/**
 * Wire it up the way `index.ts` does, minus Electron.
 *
 * The relay is off and Tailscale is reported missing, so the launch dial is
 * guaranteed to fail — which is the point. A failure that arrives proves the
 * dial was attempted; nothing else in this file needs a network.
 */
function register(overrides: Partial<RemoteIpcDeps> = {}): {
  ipc: ReturnType<typeof fakeIpc>
  enabled: boolean[]
  failures: string[]
} {
  const ipc = fakeIpc()
  const enabled: boolean[] = []
  const failures: string[] = []
  registerRemoteIpc(ipc.ipcMain, {
    sessions: fakeSessions(),
    // A real store over a temp directory rather than a stand-in: it writes only
    // when something grants a folder, and nothing in this file does.
    folders: new FolderGrants(mkdtempSync(join(tmpdir(), 'td-autostart-grants-'))),
    webRoot: join(mkdtempSync(join(tmpdir(), 'td-autostart-')), 'nowhere'),
    storageDir: mkdtempSync(join(tmpdir(), 'td-autostart-store-')),
    broadcast: () => {},
    relayEnabled: false,
    // Never the machine this runs on. Without these the launch dial would bind
    // a loopback port and ask the developer's own Tailscale for a proxy.
    readTailnet: async () => ({
      ready: false,
      state: 'not-installed',
      reason: 'Tailscale is not installed on this Mac.',
    }),
    serve: {
      on: async () => {
        throw new Error('nothing may ask Tailscale for a proxy in this test')
      },
      off: async () => {},
    },
    onEnabledChange: (on) => enabled.push(on),
    onStartFailure: (reason) => failures.push(reason),
    ...overrides,
  })
  return { ipc, enabled, failures }
}

/** The launch dial is not awaited, so give it a turn to land. */
async function settle(until: () => boolean = () => true): Promise<void> {
  for (let i = 0; i < 100; i++) {
    await new Promise((done) => setTimeout(done, 20))
    if (until()) return
  }
}

describe('remote access at launch', () => {
  it('dials without anybody pressing anything', async () => {
    const { failures } = register()
    await settle(() => failures.length > 0)
    // With no relay and no Tailscale there is nothing to come up, so the
    // observable fact is the attempt and its complaint. Silence here is the
    // regression: it would mean start() was never called.
    expect(failures.length).toBe(1)
    expect(failures[0]).toBeTruthy()
  })

  it('stays down when this Mac was told to stay down', async () => {
    const { failures } = register({ autoStart: false })
    await settle(() => failures.length > 0)
    expect(failures).toEqual([])
  })

  it('does not record the launch dial as a decision the user made', async () => {
    const { enabled, failures } = register()
    await settle(() => failures.length > 0)
    // Only a press writes to settings. Recording the automatic start would
    // make "on" indistinguishable from "never touched", and the difference is
    // the whole point of the stored key.
    expect(enabled).toEqual([])
  })

  it('remembers being switched off, so the next launch does not undo it', async () => {
    const { ipc, enabled } = register({ autoStart: false })
    await ipc.call('remote:stop')
    expect(enabled).toEqual([false])
  })

  it('does not remember a start that failed', async () => {
    const { ipc, enabled } = register({ autoStart: false })
    const status = (await ipc.call('remote:start')) as { running: boolean }
    expect(status.running).toBe(false)
    // Arming the next launch to retry something already refused would turn one
    // failure into a failure on every boot.
    expect(enabled).toEqual([])
  })
})
