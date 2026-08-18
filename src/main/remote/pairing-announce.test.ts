/**
 * A device that pairs, or is answered, tells the window.
 *
 * ## The defect this pins
 *
 * v0.4.0 made approval the gate: a paired device reaches nothing until somebody
 * at this machine says what it is and which folders it may open. Then the app
 * announced it nowhere. There was no alert, no badge and no notification, and
 * the only surface that listed a waiting device — Settings → Remote — was not
 * told either, because **pairing produces no connection**.
 *
 * That last part is the whole mechanism and it is easy to miss. `authenticatorFor`
 * redeems the code, creates the device row, and then deliberately refuses the
 * socket so the credential can travel while nothing is admitted. A refused socket
 * never gets a `deviceId`, and `publicConnections` skips anything without one, so
 * `remote:connections` — the one push this feature has — fired with a list that
 * was identical before and after. The settings pane sat there, already open on
 * the pairing screen because that is where the six digits came from, showing no
 * waiting device. Four browser pairings were watched sitting pending through
 * repeated approval attempts; this is the likeliest reason.
 *
 * So the three moments a device's *state* changes now push on that channel:
 * pairing, approval and refusal. Both listeners — the settings pane and the
 * alerts feed behind the bell — ignore the payload and re-read, which is why
 * widening the signal costs one read on a rare event and closes the hole.
 *
 * ## Why the pairing case goes all the way to a socket
 *
 * Because the bug was in the wiring, not in the logic. Every part of this was
 * individually correct — the authenticator called its hook, the channel existed,
 * the panel subscribed — and the announcement still never happened, because the
 * hook was only ever handed to the headless daemon. A test that called the
 * callback directly would have passed on the broken build. So this one mints a
 * real code through the real IPC handler, opens a real WebSocket, and sends a
 * real `hello` at the assembled server.
 */

import { createServer, request } from 'node:http'
import type { AddressInfo, Socket } from 'node:net'
import { mkdtempSync, rmSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { registerRemoteIpc, WS_PATH, type RemoteIpcDeps, type SessionAccess, type SessionHandle } from './server'
import { PROTOCOL_VERSION, type RemoteSession } from './protocol'
import { FolderGrants } from './folder-grants'
import { DeviceKinds } from './device-kind'
import { RemoteAuth } from './device-auth'

const roots: string[] = []
const stops: Array<() => Promise<unknown>> = []

afterEach(async () => {
  for (const stop of stops.splice(0)) await stop().catch(() => undefined)
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-announce-'))
  roots.push(dir)
  return dir
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

interface Harness {
  call(channel: string, ...args: unknown[]): Promise<unknown>
  /** Every channel `broadcast` was called on, in order. */
  pushed: string[]
  /** Resolves the next time the remote-changed channel fires. */
  nextPush(): Promise<void>
  auth: RemoteAuth
  port: number
}

/**
 * A free port, discovered rather than chosen.
 *
 * Several agents share this machine and a hard-coded port is a test that fails
 * for a reason that has nothing to do with the thing under test. Bind zero, read
 * what the kernel handed out, give it straight back. The window between the
 * close and the server's own bind is a race in principle and has never been one
 * in practice; a fixed number is a certainty of collision rather than a risk.
 */
async function freePort(): Promise<number> {
  const probe = createServer()
  await new Promise<void>((settle) => probe.listen(0, '127.0.0.1', () => settle()))
  const port = (probe.address() as AddressInfo).port
  await new Promise<void>((settle) => probe.close(() => settle()))
  return port
}

async function harness(options: { port?: number } = {}): Promise<Harness> {
  const handlers = new Map<string, (...args: unknown[]) => unknown>()
  const dir = tempDir()
  const pushed: string[] = []
  let waiting: (() => void) | null = null
  const port = options.port ?? (await freePort())

  const deps: RemoteIpcDeps = {
    sessions: fakeSessions(),
    folders: new FolderGrants(dir),
    kinds: new DeviceKinds(dir),
    webRoot: join(dir, 'nowhere'),
    storageDir: dir,
    port,
    broadcast: (channel) => {
      pushed.push(channel)
      const resume = waiting
      waiting = null
      resume?.()
    },
    relayEnabled: false,
    // Nothing must dial out, and nothing must start before a test asks it to.
    // The launch dial is the app's real behaviour and is asserted elsewhere; here
    // it would bind a port during construction and race the assertions.
    autoStart: false,
    env: {},
    /*
     * A tailnet that is ready, on loopback.
     *
     * `127.0.0.1` rather than a 100.64/10 address on purpose: the endpoint binds
     * loopback either way, and the host allow-list is built from this value, so
     * making it the address the test actually connects to is what lets the
     * upgrade through without weakening the check being exercised.
     */
    readTailnet: async () => ({
      ready: true as const,
      address: '127.0.0.1',
      address6: null,
      dnsName: 'test-machine.example.ts.net',
      hostName: 'test-machine',
      tailnetName: 'example.ts.net',
      magicDnsSuffix: 'example.ts.net',
      magicDns: true,
      certsAvailable: false,
      binary: '/usr/bin/false',
    }),
    serve: { on: async () => ({ ok: true }), off: async () => {} },
  }

  const ipc = registerRemoteIpc(
    {
      handle(channel: string, handler: (...args: unknown[]) => unknown) {
        handlers.set(channel, handler)
      },
    } as unknown as Parameters<typeof registerRemoteIpc>[0],
    deps,
  )

  const call = async (channel: string, ...args: unknown[]): Promise<unknown> => {
    const handler = handlers.get(channel)
    if (!handler) throw new Error(`no handler for ${channel}`)
    return handler({}, ...args)
  }
  stops.push(() => call('remote:stop'))

  return {
    call,
    pushed,
    nextPush: () =>
      new Promise<void>((settle) => {
        waiting = settle
      }),
    auth: ipc.auth,
    port,
  }
}

/* ------------------------------------------------------------- a socket -- */

/**
 * One masked client text frame.
 *
 * Written by hand because this project has no WebSocket client dependency — it
 * implements the protocol itself, so its tests speak it themselves too. Masking
 * is not optional: RFC 6455 requires every client frame to be masked and the
 * endpoint refuses one that is not.
 */
function textFrame(message: unknown): Buffer {
  const payload = Buffer.from(JSON.stringify(message), 'utf8')
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4] as number
  const header =
    payload.length < 126
      ? Buffer.from([0x81, 0x80 | payload.length])
      : Buffer.from([0x81, 0x80 | 126, (payload.length >> 8) & 0xff, payload.length & 0xff])
  return Buffer.concat([header, mask, masked])
}

function upgrade(port: number): Promise<Socket> {
  return new Promise((settle, fail) => {
    const req = request({
      host: '127.0.0.1',
      port,
      path: WS_PATH,
      headers: {
        connection: 'Upgrade',
        upgrade: 'websocket',
        'sec-websocket-key': randomBytes(16).toString('base64'),
        'sec-websocket-version': '13',
      },
    })
    req.on('response', (res) => fail(new Error(`upgrade refused with ${res.statusCode}`)))
    req.on('error', fail)
    req.on('upgrade', (_res, socket) => settle(socket))
    // Flushed explicitly. An upgrade request has no body, and without this the
    // headers sit in Node's buffer and nothing ever reaches the server.
    req.end()
  })
}

/* ------------------------------------------------------------ the tests -- */

describe('a device that pairs is announced', () => {
  it('pushes on the remote channel the moment a code is redeemed', async () => {
    const h = await harness()
    const status = (await h.call('remote:start')) as { running: boolean }
    expect(status.running).toBe(true)

    const minted = (await h.call('remote:pair')) as { token: string }
    expect(typeof minted.token).toBe('string')

    const socket = await upgrade(h.port)
    const announced = h.nextPush()
    socket.write(
      textFrame({
        t: 'hello',
        protocol: PROTOCOL_VERSION,
        token: minted.token,
        device: { name: 'iPhone', platform: 'iOS' },
      }),
    )

    await announced
    socket.destroy()

    expect(h.pushed).toContain('remote:connections')
    // And the thing being announced is real: a device row exists, and it is
    // waiting. If this said `approved` the announcement would be the least of
    // the problems.
    const devices = h.auth.listDevices()
    expect(devices).toHaveLength(1)
    expect(devices[0]?.status).toBe('pending')
  })
})

describe('answering a waiting device is announced too', () => {
  /**
   * The bell counts devices that are waiting, so the count has to come down when
   * one stops waiting — and approval usually happens in the settings pane, which
   * is a different surface from the one holding the badge. Only the main process
   * knows both.
   */
  it('pushes when a device is approved', async () => {
    const h = await harness()
    h.pushed.length = 0
    await h.call('remote:device:approve', 'dev-1', 'guest', ['/tmp/project'])
    expect(h.pushed).toEqual(['remote:connections'])
  })

  it('pushes when a device is refused', async () => {
    const h = await harness()
    // A real row, because revocation of one that does not exist is a no-op and
    // the next test is about exactly that.
    const token = h.auth.createPairingToken().token
    const redeemed = await h.auth.redeemPairingToken(token, 'iPad', '127.0.0.1')
    expect(redeemed.ok).toBe(true)
    h.pushed.length = 0

    await h.call('remote:device:revoke', redeemed.ok ? redeemed.device.id : '')
    expect(h.pushed).toEqual(['remote:connections'])
  })

  it('says nothing when there was nothing to revoke', async () => {
    const h = await harness()
    h.pushed.length = 0
    await h.call('remote:device:revoke', 'never-existed')
    // A push nothing can act on is a re-read of the whole remote state for no
    // reason, on a channel two surfaces listen to. Silence is the answer.
    expect(h.pushed).toEqual([])
  })
})
