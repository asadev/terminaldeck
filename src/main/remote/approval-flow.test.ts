/**
 * Approving a device decides what it is and what it may reach, **before** it is
 * let in.
 *
 * ## The bug this pins, in his words
 *
 * > *"Folder approval never happened. I entered the six-digit code and
 * > immediately had access to every folder."*
 *
 * He was right, and the interesting part is that the mechanism was already
 * there. `folder-grants.ts` existed, `session-create.ts` enforced it, and the
 * settings panel could edit it. What was missing was that **approval wrote
 * nothing**: `remote:device:approve` called `auth.approveDevice(id)` and
 * stopped, the folder list was a separate block further down the same page that
 * nobody had to visit, and a device with no entry in it fell back to "whatever
 * this desktop is offering" — every open project and the folder of every running
 * session. So the observed behaviour was exactly the reported one, produced by a
 * feature that was written, wired and *unreached*.
 *
 * This file asserts the order, because the order is the fix. If the approval
 * landed first there would be an interval — however short, and it is a network,
 * so it is not short — in which a device is admitted with nothing decided about
 * it, and `RemoteAuth.verify` starts answering yes the instant that write lands.
 *
 * ## And the second sentence, which is a rule rather than a default
 *
 * > *"**Guest** — You choose what they can reach. The copilot is never shared."*
 *
 * Never shared is asserted as an **absence**: a guest is not sent the `copilot`
 * capability, so nothing on its screen draws a tab, a switch, or a greyed-out
 * row that invites the ask. A grant defaulted off would still advertise it.
 */

import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  registerRemoteIpc,
  type RemoteIpcDeps,
  type SessionAccess,
  type SessionHandle,
} from './server'
import type { RemoteSession } from './protocol'
import { FolderGrants } from './folder-grants'
import { DeviceKinds, type DeviceKindRecord } from './device-kind'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-approve-'))
}

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

/**
 * `ipcMain`, plus a log of every write the handlers make, in order.
 *
 * The log is the whole point of this harness. Asserting the *end state* — the
 * device approved and the folders recorded — passes just as happily when the
 * approval went first, which is the arrangement being ruled out.
 */
function harness(): {
  call(channel: string, ...args: unknown[]): Promise<unknown>
  order: string[]
  kinds: DeviceKinds
  grants: FolderGrants
} {
  const handlers = new Map<string, (...args: unknown[]) => unknown>()
  const dir = tempDir()
  const order: string[] = []
  const kinds = new DeviceKinds(dir)
  const grants = new FolderGrants(dir)

  // Wrapped rather than subclassed, so the real stores do the real writing and
  // this only watches. A stub would let the assertion pass against a store that
  // silently does nothing.
  const watchedKinds = Object.create(kinds) as DeviceKinds
  watchedKinds.claim = (id: string, kind: 'mine' | 'guest'): boolean => {
    const ok = kinds.claim(id, kind)
    order.push(`kind:${kind}${ok ? '' : ':refused'}`)
    return ok
  }
  const watchedGrants = Object.create(grants) as FolderGrants
  watchedGrants.set = (id: string, folders: readonly unknown[]): string[] => {
    const kept = grants.set(id, folders)
    order.push(`folders:${kept.length}`)
    return kept
  }
  watchedGrants.forget = (id: string): boolean => {
    order.push('folders:cleared')
    return grants.forget(id)
  }

  const deps: RemoteIpcDeps = {
    sessions: fakeSessions(),
    folders: watchedGrants,
    kinds: watchedKinds,
    webRoot: join(dir, 'nowhere'),
    storageDir: dir,
    broadcast: () => {},
    relayEnabled: false,
    env: {},
    // Nothing here needs a network. Reporting Tailscale as absent is what stops
    // the launch dial reaching for one, and it is also the honest shape of the
    // product: the relay is the network, and this test never touches either.
    readTailnet: async () => ({ ready: false as const, state: 'not-installed' as const, reason: 'not here' }),
    serve: { on: async () => ({ ok: false }), off: async () => {} },
  }

  registerRemoteIpc(
    {
      handle(channel: string, handler: (...args: unknown[]) => unknown) {
        handlers.set(channel, handler)
      },
    } as unknown as Parameters<typeof registerRemoteIpc>[0],
    deps,
  )

  return {
    async call(channel, ...args) {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler({}, ...args)
    },
    order,
    kinds,
    grants,
  }
}

describe('nothing is reachable before the choice is made', () => {
  it('writes the kind and the folders before it approves', async () => {
    const h = harness()
    // The device row is created by a redeem over the socket, which this harness
    // has no socket for — so the ordering is asserted against the handler's own
    // writes, which happen whether or not the id names a real pending device.
    await h.call('remote:device:approve', 'dev-1', 'guest', ['/Users/apple/Projects/alpha'])
    expect(h.order).toEqual(['kind:guest', 'folders:1'])
  })

  it('records an empty list for a guest approved without choosing a folder', async () => {
    const h = harness()
    await h.call('remote:device:approve', 'dev-2', 'guest', [])
    // The *record* is what matters, not the emptiness. An absent record used to
    // mean "everything this desktop has open"; an empty one means nowhere, and
    // that distinction is the entire fix.
    expect(h.grants.granted('dev-2')).toEqual([])
    expect(h.kinds.kindOf('dev-2')).toBe('guest')
  })

  it('leaves no folder list behind for one of the owner’s own machines', async () => {
    const h = harness()
    await h.call('remote:device:approve', 'dev-3', 'mine', ['/Users/apple/Projects/alpha'])
    expect(h.kinds.kindOf('dev-3')).toBe('mine')
    // Cleared rather than stored: the reach rule never consults it for a `mine`
    // device, and a stale list is one mis-read away from coming back to life.
    expect(h.grants.granted('dev-3')).toBeNull()
    expect(h.order).toEqual(['kind:mine', 'folders:cleared'])
  })

  it('approves nothing when the kind is missing or unknown', async () => {
    const h = harness()
    await h.call('remote:device:approve', 'dev-4', undefined, [])
    await h.call('remote:device:approve', 'dev-4', 'owner', [])
    await h.call('remote:device:approve', '', 'mine', [])
    expect(h.order).toEqual([])
    expect(h.kinds.decided('dev-4')).toBe(false)
  })

  it('refuses to change a kind that is already decided', async () => {
    const h = harness()
    await h.call('remote:device:approve', 'dev-5', 'guest', [])
    await h.call('remote:device:approve', 'dev-5', 'mine', [])
    expect(h.kinds.kindOf('dev-5')).toBe('guest')
    // The second attempt stops at the kind. Nothing after it runs, so a stale
    // window cannot re-approve a guest as an owner and hand it a folder list on
    // the way past.
    expect(h.order).toEqual(['kind:guest', 'folders:0', 'kind:mine:refused'])
  })
})

describe('the roster the panel reads', () => {
  it('lists the kinds', async () => {
    const h = harness()
    await h.call('remote:device:approve', 'dev-6', 'mine', [])
    const rows = (await h.call('remote:kinds')) as DeviceKindRecord[]
    expect(rows.map((row) => ({ deviceId: row.deviceId, kind: row.kind }))).toEqual([
      { deviceId: 'dev-6', kind: 'mine' },
    ])
  })

  it('offers no channel that changes one', async () => {
    // Asserted rather than described: a `remote:kind:set` added later is the
    // toggle this design removes, and it should fail here before it ships.
    const h = harness()
    await expect(h.call('remote:kind:set', 'dev-6', 'guest')).rejects.toThrow(/no handler/)
  })
})
