import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { generateStatic } from '../../../shared/sealed'
import { hostIdFor } from '../../../shared/relay-wire'
import { isCode } from '../../../shared/short-code'
import { PAIRING_TTL_MS, RemoteAuth } from '../device-auth'
import { pairingDesk, type RemoteStatus } from '../server'
import type { MachineLink, MachineLinkState, MachineLinkOptions } from './guest'
import type { PairResult } from './pair'
import type { Beacon, BeaconOptions } from './rendezvous'
import { MachineStore } from './store'
import {
  MACHINES_OUTPUT_CHANNEL,
  MACHINES_STATE_CHANNEL,
  registerMachinesIpc,
  type InvokeRegistrar,
  type MachinesView,
} from './ipc'

/**
 * The feature as the app assembles it, with the two seams that would otherwise
 * dial the public internet replaced and nothing else.
 *
 * The first test is the one that matters most and it is not about a button:
 * *registering* this has to connect every machine that is already paired. The
 * bug this repository keeps re-finding is a feature that is complete, tested,
 * and only ever started by visiting its own screen.
 */

const dirs: string[] = []

afterEach(() => {
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-machines-ipc-'))
  dirs.push(dir)
  return dir
}

/** A relay this desktop is happily connected to. */
function connectedStatus(): RemoteStatus {
  return {
    running: true,
    url: null,
    address: null,
    port: 8443,
    reason: null,
    directReason: null,
    relay: {
      url: 'wss://relay.example',
      hostId: hostIdFor(Buffer.alloc(32, 2)),
      publicKey: generateStatic().publicKey.toString('base64url'),
      fingerprint: 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF',
      connected: true,
      channels: 0,
      reason: null,
      retryAt: null,
    },
    connections: [],
  }
}

function offlineStatus(): RemoteStatus {
  return { ...connectedStatus(), relay: null }
}

interface Rig {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  channels: string[]
  broadcasts: Array<{ channel: string; payload: unknown }>
  links: Array<{ options: MachineLinkOptions; connected: number; disconnected: number; woken: number }>
  beacons: Array<{ options: BeaconOptions; stopped: boolean }>
  store: MachineStore
  dir: string
}

function rig(
  options: {
    status?: () => RemoteStatus
    pair?: (input: { code: string; relayUrl: string }) => Promise<PairResult>
    dir?: string
    /** False for a relay that accepts the socket and never claims the slot. */
    slotClaimed?: boolean
  } = {},
): Rig {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const ipcMain: InvokeRegistrar = {
    handle: (channel, listener) => {
      handlers.set(channel, listener)
    },
  }
  const broadcasts: Array<{ channel: string; payload: unknown }> = []
  const links: Rig['links'] = []
  const beacons: Rig['beacons'] = []
  const dir = options.dir ?? tempDir()

  /*
   * The beacon seam is on the desk, because the desk is what publishes.
   *
   * It used to be a dependency of this registration, and that was the shape of
   * the bug: publishing lived beside one of the two screens that mint codes, so
   * the other one minted codes nobody could look up. Injecting it here is also
   * the only thing standing between this unit test and a real WebSocket to the
   * public relay from whatever machine it runs on.
   */
  const desk = pairingDesk(new RemoteAuth(dir), Date.now, (beaconOptions): Beacon => {
    const record = { options: beaconOptions, stopped: false }
    beacons.push(record)
    return {
      stop: () => {
        record.stopped = true
      },
      connected: () => !record.stopped && options.slotClaimed !== false,
      ready: () => Promise.resolve(options.slotClaimed !== false),
    }
  })

  registerMachinesIpc(ipcMain, {
    storageDir: dir,
    desk,
    status: options.status ?? connectedStatus,
    broadcast: (channel, payload) => broadcasts.push({ channel, payload }),
    createLink: (linkOptions): MachineLink => {
      const record = { options: linkOptions, connected: 0, disconnected: 0, woken: 0 }
      links.push(record)
      const state: MachineLinkState = {
        id: linkOptions.id,
        state: 'offline',
        reason: null,
        sessions: [],
        folders: null,
        capabilities: [],
        hostPlatform: '',
        retryAt: null,
      }
      return {
        connect: () => {
          record.connected += 1
        },
        disconnect: () => {
          record.disconnected += 1
        },
        wake: () => {
          record.woken += 1
        },
        state: () => state,
        attach: () => true,
        detach: () => true,
        input: () => true,
        resize: () => true,
        create: () => true,
      }
    },
    ...(options.pair ? { pair: options.pair } : {}),
  })

  return {
    channels: [...handlers.keys()],
    broadcasts,
    links,
    beacons,
    dir,
    store: new MachineStore(dir),
    invoke: async (channel, ...args) => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler(null, ...args)
    },
  }
}

function paired(dir: string): string {
  const store = new MachineStore(dir)
  const hostId = hostIdFor(Buffer.alloc(32, 11))
  store.remember({
    name: 'Studio PC',
    hostId,
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
    platform: 'win32',
  })
  return hostId
}

describe('launching', () => {
  it('dials every machine that is already paired, without anybody pressing anything', () => {
    const dir = tempDir()
    const hostId = paired(dir)

    const app = rig({ dir })

    // Not "a button could" — registering did.
    expect(app.links).toHaveLength(1)
    expect(app.links[0].options.id).toBe(hostId)
    expect(app.links[0].connected).toBe(1)
  })

  it('dials nothing when nothing has been paired', () => {
    expect(rig().links).toEqual([])
  })

  it('registers every channel the preload calls', () => {
    // The other half of `src/preload/contract.test.ts`, from this side: that one
    // proves the preload's channels are handled somewhere in `src/main`, this
    // one proves they are handled *here* and therefore by a registration the app
    // actually performs.
    expect(rig().channels.sort()).toEqual(
      [
        'machines:attach',
        'machines:code',
        'machines:code:cancel',
        'machines:connect',
        'machines:create',
        'machines:detach',
        'machines:disconnect',
        'machines:forget',
        'machines:input',
        'machines:list',
        'machines:pair',
        'machines:rename',
        'machines:resize',
      ].sort(),
    )
  })
})

describe('showing a code', () => {
  it('mints one and publishes a rendezvous for exactly as long as it lives', async () => {
    vi.useFakeTimers()
    try {
      const app = rig()
      const result = await app.invoke('machines:code')
      expect(result).toMatchObject({ ok: true })
      if (typeof result !== 'object' || result === null || !('code' in result)) throw new Error('no code')
      const code = result.code
      if (typeof code !== 'object' || code === null || !('token' in code)) throw new Error('no token')
      expect(typeof code.token === 'string' && isCode(code.token)).toBe(true)

      expect(app.beacons).toHaveLength(1)
      expect(app.beacons[0].options.code).toBe(code.token)
      expect(app.beacons[0].stopped).toBe(false)

      // One timer, tied to the life of one code. No poll, and nothing running
      // when nobody is pairing.
      vi.advanceTimersByTime(PAIRING_TTL_MS + 1)
      expect(app.beacons[0].stopped).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it('takes the rendezvous down when the code is cancelled, not just the drawing of it', async () => {
    const app = rig()
    await app.invoke('machines:code')
    await app.invoke('machines:code:cancel')
    expect(app.beacons[0].stopped).toBe(true)
  })

  it('refuses a code this machine has no way of publishing', async () => {
    // A code nobody can look up is a code that fails after somebody has typed
    // it, three metres away from the machine that could have explained.
    const app = rig({ status: offlineStatus })
    expect(await app.invoke('machines:code')).toMatchObject({ ok: false })
    expect(app.beacons).toEqual([])
  })

  it('withdraws a code whose slot never comes up, rather than showing it anyway', async () => {
    // The relay took the socket and never confirmed the slot. This screen has no
    // second way in — no QR, no link — so the code is minted, found to be
    // unpublishable, and taken back before it reaches anybody's eyes.
    const app = rig({ slotClaimed: false })
    expect(await app.invoke('machines:code')).toMatchObject({
      ok: false,
      message: expect.stringContaining('relay'),
    })
    expect(app.beacons).toHaveLength(1)
    // And the socket it opened does not outlive the attempt.
    expect(app.beacons[0].stopped).toBe(true)
  })

  it('says on the screen why no machine can be added, rather than offering a dead button', async () => {
    const view = await rig({ status: offlineStatus }).invoke('machines:list')
    expect(view).toMatchObject({ blocked: expect.stringContaining('relay') })
    expect(await rig().invoke('machines:list')).toMatchObject({ blocked: null })
  })
})

describe('adding a machine', () => {
  const offer = {
    relayUrl: 'wss://relay.example',
    hostId: hostIdFor(Buffer.alloc(32, 21)),
    publicKey: generateStatic().publicKey.toString('base64'),
    name: 'Studio PC',
    platform: 'win32',
  }

  it('stores it and dials it straight away', async () => {
    const keys = generateStatic()
    const app = rig({
      pair: () =>
        Promise.resolve({
          ok: true,
          offer,
          credential: 'abcdefghijkl.0123456789',
          deviceId: 'device-1',
          deviceName: 'This Mac',
          guestKeys: keys,
        }),
    })

    expect(await app.invoke('machines:pair', 'H4K9-2FQT')).toMatchObject({ ok: true })
    const stored = new MachineStore(app.dir).list()
    expect(stored).toHaveLength(1)
    expect(stored[0].hostId).toBe(offer.hostId)
    // Not after the next restart.
    expect(app.links).toHaveLength(1)
    expect(app.links[0].connected).toBe(1)
    expect(app.broadcasts.some((entry) => entry.channel === MACHINES_STATE_CHANNEL)).toBe(true)
  })

  it('passes a refusal back with the far machine’s own sentence', async () => {
    const app = rig({
      pair: () =>
        Promise.resolve({ ok: false, reason: 'refused', message: 'That pairing code is not right.' }),
    })
    expect(await app.invoke('machines:pair', 'H4K9-2FQT')).toEqual({
      ok: false,
      reason: 'refused',
      message: 'That pairing code is not right.',
    })
    expect(app.links).toEqual([])
  })

  it('refuses anything that is not a string before it reaches the relay', async () => {
    const app = rig({ pair: () => Promise.reject(new Error('should not be called')) })
    expect(await app.invoke('machines:pair', 42)).toMatchObject({ ok: false, reason: 'bad-code' })
  })
})

describe('the rest of the list', () => {
  it('drops the link when a machine is forgotten', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })

    const view = await app.invoke('machines:forget', hostId)
    expect(view).toMatchObject({ machines: [] })
    // A forget that only edited the file would leave a socket open to a machine
    // this desktop no longer claims to know.
    expect(app.links[0].disconnected).toBe(1)
    expect(new MachineStore(dir).list()).toEqual([])
  })

  it('renames one, and answers with what it stored', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    const view: unknown = await app.invoke('machines:rename', hostId, 'The loud one')
    expect(view).toMatchObject({ machines: [{ name: 'The loud one' }] })
  })

  it('connects and disconnects one by hand', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    await app.invoke('machines:disconnect', hostId)
    await app.invoke('machines:connect', hostId)
    expect(app.links[0].disconnected).toBe(1)
    // One from launch, one from the button.
    expect(app.links[0].connected).toBe(2)
  })

  it('answers a session verb with whether it actually went', async () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    expect(await app.invoke('machines:attach', hostId, 's1', 80, 24)).toBe(true)
    expect(await app.invoke('machines:input', hostId, 's1', 'ls')).toBe(true)
    // A machine nobody has paired with cannot be typed into, and the caller is
    // told rather than left watching keystrokes vanish.
    expect(await app.invoke('machines:input', 'nobody', 's1', 'ls')).toBe(false)
    expect(await app.invoke('machines:attach', hostId, 's1', 'wide', 24)).toBe(false)
  })

  it('pushes a machine’s output at the window with the machine it came from', () => {
    const dir = tempDir()
    const hostId = paired(dir)
    const app = rig({ dir })
    app.links[0].options.onOutput('s1', 'hello', false)
    expect(app.broadcasts).toContainEqual({
      channel: MACHINES_OUTPUT_CHANNEL,
      payload: { machineId: hostId, sessionId: 's1', data: 'hello', replay: false },
    })
  })
})

describe('waking', () => {
  it('redials every link, because a suspended one is dead and still looks fine', () => {
    const dir = tempDir()
    paired(dir)
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    const links: Array<{ woken: number }> = []
    const machines = registerMachinesIpc(
      {
        handle: (channel, listener) => {
          handlers.set(channel, listener)
        },
      },
      {
        storageDir: dir,
        desk: pairingDesk(new RemoteAuth(dir)),
        status: connectedStatus,
        broadcast: () => {},
        createLink: (linkOptions): MachineLink => {
          const record = { woken: 0 }
          links.push(record)
          const state: MachineLinkState = {
            id: linkOptions.id,
            state: 'offline',
            reason: null,
            sessions: [],
            folders: null,
            capabilities: [],
            hostPlatform: '',
            retryAt: null,
          }
          return {
            connect: () => {},
            disconnect: () => {},
            wake: () => {
              record.woken += 1
            },
            state: () => state,
            attach: () => true,
            detach: () => true,
            input: () => true,
            resize: () => true,
            create: () => true,
          }
        },
      },
    )
    machines.wake()
    expect(links[0].woken).toBe(1)

    const view: MachinesView = machines.view()
    expect(view.machines).toHaveLength(1)
    machines.stop()
  })
})
