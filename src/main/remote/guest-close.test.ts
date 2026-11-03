/**
 * Ending a session from a device, and the door that decides who may.
 *
 * ## What is being pinned
 *
 * `close` is the fourth door onto a machine's running work. `list` decides what
 * a device is shown, `attach` decides what it may read, `create` decides where
 * it may start something — all three grew a per-device rule — and this one
 * decides what it may **destroy**. It is the only verb on this wire whose effect
 * cannot be taken back: an agent mid-edit is a process, and killing it does not
 * leave the work somewhere to be recovered from.
 *
 * So the interesting assertion in this file is not that closing works. It is
 * that a guest paired into one folder cannot end a session running in another,
 * and that the session layer is **never asked** in that case — a desktop that
 * ended the session and then decided whether it was allowed to would already
 * have done the thing. `requests` being empty is the assertion, not the refusal
 * text.
 *
 * ## Why it drives a real socket
 *
 * For the reason `server.test.ts` opens with: the behaviour lives in the message
 * loop, and a test that called the handler with a hand-made frame would pass
 * against a server that never reads a frame correctly. The client below is
 * written out rather than imported because `ws` is not a dependency of this
 * project, and it is deliberately the smallest one that can send a text frame
 * and read the answers — everything larger is already covered next door.
 */

import { randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { CAPABILITY, PROTOCOL_VERSION, type RemoteSession, type ServerMessage } from './protocol'
import {
  WS_PATH,
  createRemoteEndpoint,
  type RemoteAuthenticator,
  type SessionAccess,
  type SessionHandle,
} from './server'

/* ---------------------------------------------------------------- client -- */

function maskedText(payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  let header: Buffer
  if (masked.length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | masked.length
  } else {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(masked.length, 2)
  }
  // 0x1 is a text frame; nothing here sends anything else.
  header[0] = 0x81
  return Buffer.concat([header, mask, masked])
}

interface Client {
  send(message: unknown): void
  received: ServerMessage[]
  until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage>
}

function connect(port: number): Promise<Client> {
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
    req.on('error', fail)
    req.on('upgrade', (_res, socket: Socket, head: Buffer) => {
      const received: ServerMessage[] = []
      const waiters: { predicate: (m: ServerMessage) => boolean; settle: (m: ServerMessage) => void }[] = []
      let buffer = head

      const drain = (): void => {
        let at = 0
        for (;;) {
          if (buffer.length - at < 2) break
          let length = buffer[at + 1] & 0x7f
          let offset = at + 2
          if (length === 126) {
            if (buffer.length < offset + 2) break
            length = buffer.readUInt16BE(offset)
            offset += 2
          } else if (length === 127) {
            if (buffer.length < offset + 8) break
            length = Number(buffer.readBigUInt64BE(offset))
            offset += 8
          }
          if (buffer.length < offset + length) break
          const opcode = buffer[at] & 0x0f
          const payload = buffer.subarray(offset, offset + length)
          at = offset + length
          // 0x1 text; a close or a ping is not this file's business.
          if (opcode !== 0x1) continue
          const message = JSON.parse(payload.toString('utf8')) as ServerMessage
          received.push(message)
          for (const waiter of [...waiters]) {
            if (!waiter.predicate(message)) continue
            waiters.splice(waiters.indexOf(waiter), 1)
            waiter.settle(message)
          }
        }
        buffer = buffer.subarray(at)
      }

      drain()
      socket.on('data', (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        drain()
      })

      settle({
        send: (message) => socket.write(maskedText(Buffer.from(JSON.stringify(message), 'utf8'))),
        received,
        until: (predicate, label) =>
          new Promise((done, reject) => {
            const already = received.find(predicate)
            if (already) return done(already)
            const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), 2000)
            waiters.push({
              predicate,
              settle: (message) => {
                clearTimeout(timer)
                done(message)
              },
            })
          }),
      })
    })
    req.end()
  })
}

/* ------------------------------------------------------------------ fakes -- */

/**
 * Two sessions in two folders, and a per-device rule that separates them.
 *
 * `visible` is the same shape `SessionFanout` builds from `device-reach.ts`: the
 * owner's own machines reach everything, a guest reaches the folders somebody
 * chose for it. Written as a literal here so the test is about the *door* rather
 * than about the grant store behind it.
 */
interface Fake extends SessionAccess {
  /** Every id the session layer was actually asked to end, in order. */
  closed: string[]
  living: RemoteSession[]
}

const OWNER_SESSION: RemoteSession = {
  id: 'sess-owner',
  title: 'terminaldeck',
  cwd: '/tmp/private',
  provider: 'claude',
  status: 'working',
  exitCode: null,
}

const SHARED_SESSION: RemoteSession = {
  id: 'sess-shared',
  title: 'shared',
  cwd: '/tmp/shared',
  provider: 'shell',
  status: 'idle',
  exitCode: null,
}

/** Which folders each device may reach. Anything unlisted reaches everything. */
const GRANTS = new Map<string, string[]>([['guest-1', ['/tmp/shared']]])

function fakeSessions(closable = true): Fake {
  const fake: Fake = {
    closed: [],
    living: [OWNER_SESSION, SHARED_SESSION],
    list: () => fake.living,
    visible: (deviceId, sessionId) => {
      const session = fake.living.find((s) => s.id === sessionId)
      if (!session) return false
      const granted = GRANTS.get(deviceId)
      return granted === undefined ? true : granted.includes(session.cwd)
    },
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
  }
  if (closable) {
    fake.close = (id: string): boolean => {
      const before = fake.living.length
      fake.living = fake.living.filter((session) => session.id !== id)
      if (fake.living.length === before) return false
      fake.closed.push(id)
      return true
    }
  }
  return fake
}

/** Whichever device the credential names. One secret per identity, no scrypt. */
const authenticator: RemoteAuthenticator = {
  async authenticate(token) {
    if (token === 'owner-1.c2VjcmV0') {
      return { ok: true, deviceId: 'owner-1', deviceName: 'The laptop', credential: null }
    }
    if (token === 'guest-1.c2VjcmV0') {
      return { ok: true, deviceId: 'guest-1', deviceName: 'A guest phone', credential: null }
    }
    return { ok: false, message: 'This device is not allowed in.' }
  },
}

function hello(token: string): unknown {
  return { t: 'hello', protocol: PROTOCOL_VERSION, token, device: { name: 'phone', platform: 'iOS' } }
}

/* ------------------------------------------------------------------ setup -- */

let servers: Server[] = []
let roots: string[] = []

afterEach(() => {
  for (const server of servers) server.close()
  servers = []
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  roots = []
})

async function serve(sessions: Fake): Promise<{ port: number; sessions: Fake }> {
  const root = mkdtempSync(join(tmpdir(), 'deck-close-'))
  roots.push(root)
  writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')
  const endpoint = createRemoteEndpoint({ sessions, auth: authenticator, webRoot: root, pingIntervalMs: 0 })
  const server = createServer(endpoint.handleRequest)
  server.on('upgrade', endpoint.handleUpgrade)
  servers.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
  return { port: (server.address() as AddressInfo).port, sessions }
}

async function greet(port: number, token: string): Promise<Client> {
  const client = await connect(port)
  client.send(hello(token))
  await client.until((m) => m.t === 'welcome', 'the welcome')
  return client
}

/* ------------------------------------------------------------------ tests -- */

describe('the capability is derived from the method, not from a flag', () => {
  it('is advertised by a host whose session layer can end a session', async () => {
    const { port } = await serve(fakeSessions())
    const client = await greet(port, 'owner-1.c2VjcmV0')
    const welcome = client.received.find((m) => m.t === 'welcome')
    expect(welcome).toMatchObject({ capabilities: expect.arrayContaining([CAPABILITY.close]) })
  })

  it('is absent from a host whose session layer cannot', async () => {
    // The whole of the negotiation: a client talking to this host never draws a
    // Close button, so it never sends a frame that could only be refused.
    const { port } = await serve(fakeSessions(false))
    const client = await greet(port, 'owner-1.c2VjcmV0')
    const welcome = client.received.find((m) => m.t === 'welcome') as { capabilities: string[] }
    expect(welcome.capabilities).not.toContain(CAPABILITY.close)
  })

  it('refuses the verb rather than closing the socket, when it is not advertised', async () => {
    // A client that sends an unadvertised verb gets a sentence it can print. The
    // socket survives, because the person holding it is looking at a list that
    // is still true.
    const host = await serve(fakeSessions(false))
    const client = await greet(host.port, 'owner-1.c2VjcmV0')
    client.send({ t: 'close', id: OWNER_SESSION.id })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({
      t: 'error',
      code: 'unauthorized',
      message: 'Sessions cannot be closed from a device here.',
    })
    expect(host.sessions.living).toHaveLength(2)
  })
})

describe('one of the owner’s own devices', () => {
  it('closes a session and is told which one', async () => {
    const host = await serve(fakeSessions())
    const client = await greet(host.port, 'owner-1.c2VjcmV0')
    client.send({ t: 'close', id: OWNER_SESSION.id })

    const done = await client.until((m) => m.t === 'closed', 'the confirmation')
    expect(done).toEqual({ t: 'closed', id: OWNER_SESSION.id })
    expect(host.sessions.closed).toEqual([OWNER_SESSION.id])
  })

  it('is refused for an id that names nothing, without the session layer inventing one', async () => {
    const host = await serve(fakeSessions())
    const client = await greet(host.port, 'owner-1.c2VjcmV0')
    client.send({ t: 'close', id: '2f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unknown-session' })
    expect(host.sessions.closed).toEqual([])
  })

  it('lets every other connected device see the row go, on a frame they already understand', async () => {
    // `closed` names *your* action and is a capability frame; `sessions` is v1.
    // A client that has never heard of closing still watches the session vanish,
    // which is the additive rule the whole capability system exists for.
    const host = await serve(fakeSessions())
    const watcher = await greet(host.port, 'guest-1.c2VjcmV0')
    const closer = await greet(host.port, 'owner-1.c2VjcmV0')
    closer.send({ t: 'close', id: SHARED_SESSION.id })

    const refreshed = (await watcher.until(
      (m) => m.t === 'sessions',
      'the refreshed list',
    )) as { sessions: RemoteSession[] }
    expect(refreshed.sessions).toEqual([])
    expect(watcher.received.some((m) => m.t === 'closed')).toBe(false)
  })
})

describe('a guest may not close a session it was never granted', () => {
  it('is refused, and the session layer is never asked', async () => {
    /*
     * The assertion this file exists for.
     *
     * `guest-1` holds `/tmp/shared` and nothing else. `sess-owner` is running in
     * `/tmp/private`, which is somebody's actual work — and until `close`
     * existed, no frame could reach it. The refusal has to happen *before* the
     * session layer is asked anything, so `closed` being empty is the real
     * assertion and the error frame is only how the guest finds out.
     */
    const host = await serve(fakeSessions())
    const client = await greet(host.port, 'guest-1.c2VjcmV0')
    client.send({ t: 'close', id: OWNER_SESSION.id })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({
      t: 'error',
      code: 'unknown-session',
      message: `No session ${OWNER_SESSION.id} is running.`,
    })
    expect(host.sessions.closed).toEqual([])
    expect(host.sessions.living.map((s) => s.id)).toEqual([OWNER_SESSION.id, SHARED_SESSION.id])
  })

  it('is told the same sentence an id that names nothing gets', async () => {
    // Deliberately identical, and it is the same argument `attach` makes: a
    // distinct refusal would confirm that the id names something real, and these
    // ids are recoverable from an alert, a transcript path, or a list taken
    // before a folder was removed.
    const host = await serve(fakeSessions())
    const guest = await greet(host.port, 'guest-1.c2VjcmV0')
    guest.send({ t: 'close', id: OWNER_SESSION.id })
    const hidden = await guest.until((m) => m.t === 'error', 'the refusal for a granted-away session')

    const owner = await greet(host.port, 'owner-1.c2VjcmV0')
    owner.send({ t: 'close', id: OWNER_SESSION.id.replace('owner', 'ghost') })
    const missing = await owner.until((m) => m.t === 'error', 'the refusal for an id that names nothing')

    expect(hidden).toEqual({
      t: 'error',
      code: 'unknown-session',
      message: `No session ${OWNER_SESSION.id} is running.`,
    })
    expect(missing).toMatchObject({ code: 'unknown-session' })
  })

  it('closes the one it *was* granted, so the refusal is about reach and not about being a guest', async () => {
    const host = await serve(fakeSessions())
    const client = await greet(host.port, 'guest-1.c2VjcmV0')
    client.send({ t: 'close', id: SHARED_SESSION.id })

    const done = await client.until((m) => m.t === 'closed', 'the confirmation')
    expect(done).toEqual({ t: 'closed', id: SHARED_SESSION.id })
    expect(host.sessions.closed).toEqual([SHARED_SESSION.id])
  })
})
