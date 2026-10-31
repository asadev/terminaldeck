import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { registerRemoteIpc, type RemoteIpcDeps, type SessionAccess } from '../remote/server'
import { FolderGrants } from '../remote/folder-grants'
import { DeviceKinds } from '../remote/device-kind'
import { describeThisMachine } from '../remote/machines/guest'
import { NATIVE_REFUSAL, NATIVE_SHELL_FLAG } from './mode'

/**
 * Remote access in the native shell: on, under its own identity, over the relay
 * only. The direct half — a Tailscale address, port 8443 and `tailscale serve`
 * — is the whole machine's and stays with the installed app.
 */

const sessions: SessionAccess = { list: () => [], attach: () => null, write: () => {}, resize: () => {}, detach: () => {} }

function register(overrides: Partial<RemoteIpcDeps>): { failures: string[]; tailnetAsked: number; serveAsked: number; call(channel: string): Promise<unknown> } {
  const handlers = new Map<string, (...args: unknown[]) => unknown>()
  const failures: string[] = []
  const counts = { tailnetAsked: 0, serveAsked: 0 }
  registerRemoteIpc(
    {
      handle(channel: string, handler: (...args: unknown[]) => unknown) {
        handlers.set(channel, handler)
      },
    } as unknown as Parameters<typeof registerRemoteIpc>[0],
    {
      sessions,
      folders: new FolderGrants(mkdtempSync(join(tmpdir(), 'td-native-remote-grants-'))),
      kinds: new DeviceKinds(mkdtempSync(join(tmpdir(), 'td-native-remote-kinds-'))),
      forgetDevice: () => {},
      webRoot: join(mkdtempSync(join(tmpdir(), 'td-native-remote-')), 'nowhere'),
      storageDir: mkdtempSync(join(tmpdir(), 'td-native-remote-store-')),
      broadcast: () => {},
      relayEnabled: false,
      // A tailnet that is up — so the only thing stopping the direct half is the gate.
      readTailnet: async () => {
        counts.tailnetAsked++
        return { ready: true, address: '100.64.0.1', dnsName: 'mac.example.ts.net', magicDns: true } as never
      },
      serve: {
        on: async () => {
          counts.serveAsked++
          throw new Error('the native shell must never ask Tailscale for a proxy')
        },
        off: async () => {},
      },
      onStartFailure: (reason) => failures.push(reason),
      ...overrides,
    },
  )
  return {
    failures,
    get tailnetAsked() {
      return counts.tailnetAsked
    },
    get serveAsked() {
      return counts.serveAsked
    },
    call: async (channel) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler({})
    },
  }
}

async function settle(until: () => boolean): Promise<void> {
  for (let i = 0; i < 100 && !until(); i++) await new Promise((done) => setTimeout(done, 20))
}

describe('remote access in the native shell', () => {
  beforeEach(() => {
    process.argv.push(NATIVE_SHELL_FLAG)
  })
  afterEach(() => {
    process.argv.splice(process.argv.lastIndexOf(NATIVE_SHELL_FLAG), 1)
  })

  it('dials at launch like the installed app does, and never touches Tailscale', async () => {
    const rig = register({})
    await settle(() => rig.failures.length > 0)
    // The launch dial happened: with no relay in this test it says why it is down.
    expect(rig.failures).toEqual([NATIVE_REFUSAL.direct])
    expect(rig.tailnetAsked).toBe(0)
    expect(rig.serveAsked).toBe(0)
  })

  it('starts when a person presses Start, rather than refusing', async () => {
    const rig = register({ autoStart: false })
    const status = (await rig.call('remote:start')) as { running: boolean; reason: string | null }
    expect(status.reason).toBe(NATIVE_REFUSAL.direct)
    expect(rig.serveAsked).toBe(0)
  })

  it('calls itself by a name of its own', () => {
    expect(describeThisMachine().name).toMatch(/ \(native\)$/)
  })
})
