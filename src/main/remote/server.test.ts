import { createHash, randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  CAPABILITIES,
  CLOSE,
  MAX_UPLOAD_CHUNK_BYTES,
  PROTOCOL_VERSION,
  type RemoteSession,
  type ServerMessage,
} from './protocol'
import type { TailnetReady } from './tailnet'
import { RemoteAuth } from './device-auth'
import {
  WS_PATH,
  authenticatorFor,
  createRemoteEndpoint,
  createRemoteServer,
  pairingDesk,
  resolveStaticPath,
  type CreateOutcome,
  type CreateRequest,
  type RemoteAuthenticator,
  type RemoteEndpoint,
  type SessionAccess,
  type SessionHandle,
} from './server'

/**
 * Everything here runs over a real loopback socket.
 *
 * The interesting behaviour of this module is what it refuses — a socket that
 * never authenticates, one that talks before it does, a frame bigger than the
 * cap — and every one of those lives in the framing and the message loop, not
 * in a function you can call directly. A test that called the handler with a
 * hand-made message would pass against a server that never reads a frame
 * correctly at all.
 *
 * The transport is a plain `http.Server` on 127.0.0.1 rather than the real
 * HTTPS one: TLS here would mean minting a certificate, which means Tailscale,
 * which means the test only runs on a machine that is on a tailnet with HTTPS
 * enabled — this one is not. `createRemoteEndpoint` exists as its own function
 * for exactly that reason, and the tailnet-shaped half is covered separately
 * through the injected seams.
 *
 * The WebSocket client below is written out for the same reason the server's
 * framing is: `ws` is not a dependency of this project.
 */

/* ------------------------------------------------------------- ws client -- */

interface Frame {
  opcode: number
  payload: Buffer
}

function maskedFrame(opcode: number, payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]

  let header: Buffer
  if (masked.length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | masked.length
  } else if (masked.length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(masked.length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(masked.length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, mask, masked])
}

/** Server frames are never masked, which keeps this reader short. */
function readFrames(buffer: Buffer): { frames: Frame[]; rest: Buffer } {
  const frames: Frame[] = []
  let at = 0
  for (;;) {
    if (buffer.length - at < 2) break
    const opcode = buffer[at] & 0x0f
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
    frames.push({ opcode, payload: buffer.subarray(offset, offset + length) })
    at = offset + length
  }
  return { frames, rest: buffer.subarray(at) }
}

interface Client {
  send(message: unknown): void
  sendFrame(frame: Buffer): void
  /** Every JSON message received so far, in order. */
  received: ServerMessage[]
  /** Resolves once `predicate` matches, or rejects on timeout. */
  until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage>
  /** The close code the server sent, once it closes. */
  closed: Promise<number>
  socket: Socket
}

function connect(port: number, path = WS_PATH, host?: string, origin?: string): Promise<Client> {
  return new Promise((settle, fail) => {
    const req = request({
      host: '127.0.0.1',
      port,
      path,
      headers: {
        connection: 'Upgrade',
        upgrade: 'websocket',
        'sec-websocket-key': randomBytes(16).toString('base64'),
        'sec-websocket-version': '13',
        ...(host ? { host } : {}),
        ...(origin ? { origin } : {}),
      },
    })

    req.on('response', (res) => fail(new Error(`upgrade refused with ${res.statusCode}`)))
    req.on('error', fail)
    req.on('upgrade', (_res, socket, head) => {
      const received: ServerMessage[] = []
      const waiters: { predicate: (m: ServerMessage) => boolean; settle: (m: ServerMessage) => void }[] = []
      let closeCode = -1
      let resolveClosed: (code: number) => void = () => {}
      const closed = new Promise<number>((done) => {
        resolveClosed = done
      })

      let buffer: Buffer = head
      const consume = (): void => {
        const { frames, rest } = readFrames(buffer)
        buffer = rest
        for (const frame of frames) {
          if (frame.opcode === 0x8) {
            closeCode = frame.payload.length >= 2 ? frame.payload.readUInt16BE(0) : 1005
            continue
          }
          if (frame.opcode !== 0x1) continue
          const message = JSON.parse(frame.payload.toString('utf8')) as ServerMessage
          received.push(message)
          for (const waiter of [...waiters]) {
            if (!waiter.predicate(message)) continue
            waiters.splice(waiters.indexOf(waiter), 1)
            waiter.settle(message)
          }
        }
      }
      consume()

      socket.on('data', (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        consume()
      })
      socket.on('close', () => resolveClosed(closeCode))
      socket.on('error', () => resolveClosed(closeCode))

      settle({
        received,
        socket: socket as Socket,
        send: (message) => socket.write(maskedFrame(0x1, Buffer.from(JSON.stringify(message), 'utf8'))),
        sendFrame: (frame) => socket.write(frame),
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
        closed,
      })
    })
    req.end()
  })
}

/* ------------------------------------------------------------------ fakes -- */

interface FakeSessions extends SessionAccess {
  emit(id: string, data: string): void
  /** Put another session in the list, as though something on the Mac started one. */
  add(id: string, replay: string, cwd?: string): RemoteSession
  written: { id: string; data: string }[]
  resized: { id: string; cols: number; rows: number }[]
  detached: string[]
  attachCount: number
}

function fakeSessions(seed: Record<string, string> = { 'sess-1': 'earlier output\r\n' }): FakeSessions {
  const listeners = new Map<string, (data: string) => void>()
  const replays = new Map<string, string>(Object.entries(seed))
  const meta: RemoteSession[] = Object.keys(seed).map((id) => ({
    id,
    title: id,
    cwd: `/tmp/${id}`,
    provider: 'claude',
    status: 'working',
    exitCode: null,
  }))

  return {
    written: [],
    resized: [],
    detached: [],
    attachCount: 0,
    list: () => meta,
    add(id, replay, cwd = `/tmp/${id}`) {
      const session: RemoteSession = { id, title: id, cwd, provider: 'shell', status: 'idle', exitCode: null }
      replays.set(id, replay)
      meta.push(session)
      return session
    },
    attach(id, onData) {
      if (!replays.has(id)) return null
      this.attachCount += 1
      listeners.set(id, onData)
      return { sessionId: id, replay: replays.get(id) as string }
    },
    write(id, data) {
      this.written.push({ id, data })
    },
    resize(id, cols, rows) {
      this.resized.push({ id, cols, rows })
    },
    detach(handle: SessionHandle) {
      this.detached.push(handle.sessionId)
      listeners.delete(handle.sessionId)
    },
    emit(id, data) {
      listeners.get(id)?.(data)
    },
  }
}

interface CreatingSessions extends FakeSessions {
  /** Every request that reached the session layer, in order. Empty is the assertion. */
  requests: CreateRequest[]
  /** Set to answer with a refusal instead of starting anything. */
  refuseWith: CreateOutcome | null
  /** Set to hold `create` open, so a test can look at the window while it runs. */
  hold: Promise<void> | null
}

/**
 * A session layer that can start one — which is what makes the desktop
 * advertise `create` at all. The default fake deliberately cannot, so that
 * every other test in this file runs against a desktop that does not offer it.
 */
function creatingSessions(folders: string[] = ['/tmp/allowed']): CreatingSessions {
  const fake = fakeSessions() as CreatingSessions
  let made = 0
  fake.requests = []
  fake.refuseWith = null
  fake.hold = null
  fake.create = async (request: CreateRequest): Promise<CreateOutcome> => {
    fake.requests.push(request)
    if (fake.hold) await fake.hold
    if (fake.refuseWith) return fake.refuseWith
    if (request.cwd !== undefined && !folders.includes(request.cwd)) {
      return { ok: false, code: 'unauthorized', message: 'This Mac will not start a session in that folder.' }
    }
    made += 1
    return { ok: true, session: fake.add(`made-${made}`, '', request.cwd ?? folders[0]) }
  }
  return fake
}

const CREDENTIAL = 'device-1.c2VjcmV0'

/** Stands in for `RemoteAuth`, so the socket tests do not spend scrypt per connection. */
const allowKnownDevice: RemoteAuthenticator = {
  async authenticate(token) {
    if (token === CREDENTIAL) {
      return { ok: true, deviceId: 'device-1', deviceName: 'Test iPhone', credential: null }
    }
    return { ok: false, message: 'This device is not allowed in.' }
  },
}

/**
 * A device that has paired and that nobody at the Mac has approved yet.
 *
 * The real `authenticatorFor` answers exactly this way: the credential travels,
 * because otherwise the pairing was for nothing, and the connection still ends.
 */
const awaitApproval: RemoteAuthenticator = {
  async authenticate() {
    return {
      ok: false,
      message: 'Paired. Approve this device on the Mac, then reconnect.',
      credential: 'device-2.bmV3',
      deviceId: 'device-2',
      deviceName: 'Unapproved iPhone',
    }
  },
}

/* ------------------------------------------------------------------ setup -- */

const HELLO = { t: 'hello', protocol: PROTOCOL_VERSION, token: CREDENTIAL, device: { name: 'iPhone', platform: 'iOS' } }

let servers: Server[] = []
let roots: string[] = []

afterEach(() => {
  for (const server of servers) server.close()
  servers = []
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  roots = []
})

interface Harness {
  port: number
  endpoint: RemoteEndpoint
  sessions: FakeSessions
  connections: number
  /** The temporary `pwa/dist` this harness is serving. */
  root: string
}

async function serve(
  overrides: Partial<Parameters<typeof createRemoteEndpoint>[0]> = {},
  sessions = fakeSessions(),
): Promise<Harness> {
  const root = mkdtempSync(join(tmpdir(), 'deck-pwa-'))
  roots.push(root)
  writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')

  const harness: Harness = { port: 0, endpoint: undefined as unknown as RemoteEndpoint, sessions, connections: 0, root }
  harness.endpoint = createRemoteEndpoint({
    sessions,
    auth: allowKnownDevice,
    webRoot: root,
    // Heartbeats would fire mid-assertion and are covered by their own timer,
    // not by these tests.
    pingIntervalMs: 0,
    onConnections: () => {
      harness.connections += 1
    },
    ...overrides,
  })

  const server = createServer(harness.endpoint.handleRequest)
  server.on('upgrade', harness.endpoint.handleUpgrade)
  servers.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
  harness.port = (server.address() as AddressInfo).port
  return harness
}

/* ------------------------------------------------------------------ tests -- */

describe('a socket that has not authenticated', () => {
  it('is closed when it says nothing at all', async () => {
    const harness = await serve({ helloTimeoutMs: 60 })
    const client = await connect(harness.port)

    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(client.received).toEqual([])
  })

  it('is closed when it asks for anything before hello', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send({ t: 'list' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({ t: 'error', code: 'unauthenticated', message: 'Say hello first.' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    // The session list is the thing being protected; it must not have leaked
    // into the refusal.
    expect(client.received.some((m) => m.t === 'sessions')).toBe(false)
  })

  it('cannot open a tunnel to this Mac before it has said who it is', async () => {
    // The localhost feature reaches a socket on this machine, so it gets the
    // same gate as everything else: an unauthenticated peer is refused and
    // closed rather than answered. Checked at this level as well as in
    // `tunnel.ts` because the gate is the *server's*, not the hub's — the hub
    // is only ever reached from the authenticated branch of `onMessage`.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send({ t: 'tunnel.open', id: 'tun-1', port: 3000 })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({ t: 'error', code: 'unauthenticated', message: 'Say hello first.' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(client.received.some((m) => m.t === 'tunnel.opened' || m.t === 'ports')).toBe(false)
  })

  it('cannot ask what is listening on this Mac before it has said who it is', async () => {
    // A port list is a description of what is running on somebody's laptop, so
    // it is behind the same door as the sessions.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send({ t: 'ports' })

    await client.until((m) => m.t === 'error', 'the refusal')
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(client.received.some((m) => m.t === 'ports')).toBe(false)
  })

  it('is closed when its credential is not one we know', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send({ ...HELLO, token: 'device-9.bm90' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(harness.connections).toBe(0)
  })

  it('is closed when it sends two hellos at once', async () => {
    // Verification is asynchronous, so both would otherwise be checked against
    // a connection that is unauthenticated for both.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    client.send(HELLO)

    await expect(client.closed).resolves.toBe(CLOSE.protocolError)
    expect(harness.endpoint.connections()).toEqual([])
  })

  it('is refused when it comes from a page on another site', async () => {
    // `Host` says where the request went; only `Origin` says where it came
    // from, and a page on any site the phone visits can dial this URL.
    const harness = await serve({ hosts: ['deck.example.ts.net:8443'] })
    await expect(
      connect(harness.port, WS_PATH, 'deck.example.ts.net:8443', 'https://evil.example.com'),
    ).rejects.toThrow(/403/)

    const client = await connect(harness.port, WS_PATH, 'deck.example.ts.net:8443', 'https://deck.example.ts.net:8443')
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
  })

  it('is refused once the server is already holding as many sockets as it will', async () => {
    // Nothing before hello costs a caller anything, so without a ceiling any
    // peer on the tailnet can spend this process's file descriptors.
    const harness = await serve({ helloTimeoutMs: 60_000 })
    const held: Client[] = []
    try {
      for (let i = 0; i < 64; i += 1) held.push(await connect(harness.port))
      await expect(connect(harness.port)).rejects.toThrow(/503/)

      // Not a permanent wall: a slot that frees up is a slot.
      held[0].socket.destroy()
      await new Promise((settle) => setTimeout(settle, 50))
      held.push(await connect(harness.port))
    } finally {
      for (const client of held) client.socket.destroy()
    }
  })

  it('is closed when it speaks a different protocol version', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send({ ...HELLO, protocol: PROTOCOL_VERSION + 1 })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'version' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
  })
})

describe('a paired device', () => {
  it('is welcomed with the sessions it can see', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome).toMatchObject({ t: 'welcome', deviceId: 'device-1', deviceName: 'Test iPhone', token: null })
    expect(welcome.t === 'welcome' && welcome.sessions.map((s) => s.id)).toEqual(['sess-1'])
    expect(harness.endpoint.connections()).toHaveLength(1)
  })

  it('is told what this desktop can do beyond protocol v1', async () => {
    // The whole reason the version did not have to move. A phone offers the
    // localhost feature only because this list said so, so a build that stops
    // advertising it makes the button disappear rather than making a tap fail.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toEqual(['localhost'])
    expect(CAPABILITIES).toContain('localhost')
  })

  it('advertises `create` only when the session layer can actually start one', async () => {
    // The gap this feature was: both phones had a New Session button gated on a
    // capability, and no desktop advertised it — so it could never appear. The
    // fix is not "advertise it"; it is "advertise it when it is true". A host
    // built on a session layer with no `create` still must not offer the button.
    const cannot = await serve()
    const dark = await connect(cannot.port)
    dark.send(HELLO)
    const without = await dark.until((m) => m.t === 'welcome', 'the welcome')
    expect(without.t === 'welcome' && without.capabilities).not.toContain('create')

    const can = await serve({}, creatingSessions())
    const lit = await connect(can.port)
    lit.send(HELLO)
    const with_ = await lit.until((m) => m.t === 'welcome', 'the welcome')
    expect(with_.t === 'welcome' && with_.capabilities).toContain('create')
    expect(CAPABILITIES).toContain('create')
  })

  it('advertises `upload` only when it has somewhere to put a file', async () => {
    // Same rule as `create`, and the same failure it is written to prevent: a
    // Send File button on somebody's phone that produces a refusal, because the
    // capability was read off a constant rather than off the thing that makes it
    // possible. Here the thing is a directory, and its absence is the switch.
    const nowhere = await serve()
    const dark = await connect(nowhere.port)
    dark.send(HELLO)
    const without = await dark.until((m) => m.t === 'welcome', 'the welcome')
    expect(without.t === 'welcome' && without.capabilities).not.toContain('upload')

    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    roots.push(dir)
    const somewhere = await serve({ uploadsDir: dir })
    const lit = await connect(somewhere.port)
    lit.send(HELLO)
    const with_ = await lit.until((m) => m.t === 'welcome', 'the welcome')
    expect(with_.t === 'welcome' && with_.capabilities).toContain('upload')
    expect(CAPABILITIES).toContain('upload')
  })

  it('refuses an upload on its own id when the host has nowhere to put one', async () => {
    // Answered on the upload's id rather than as a bare `error`, so the phone
    // ends the right progress bar instead of showing a banner about nothing.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'upload.begin', id: 'up-1', name: 'a.jpg', size: 10 })
    const refusal = await client.until((m) => m.t === 'upload.failed', 'a refusal')
    expect(refusal.t === 'upload.failed' && refusal.id).toBe('up-1')
  })

  it('carries a whole file to disk and reports where it landed', async () => {
    // The end-to-end shape, over a real socket and through the real parser: the
    // path arrives before the bytes, the bytes are acknowledged, and what is on
    // disk is what was sent. `uploads.test.ts` covers the failure modes; this
    // one exists because a feature that works in a unit test and not through
    // `parseClientMessage` is a feature that does not work.
    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    roots.push(dir)
    const harness = await serve({ uploadsDir: dir })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    const payload = randomBytes(70_000)
    client.send({ t: 'upload.begin', id: 'up-1', name: 'clip.mov', size: payload.length })
    const ready = await client.until((m) => m.t === 'upload.ready', 'the path')
    expect(ready.t === 'upload.ready' && ready.path).toBe(join(dir, 'clip.mov'))

    for (let at = 0; at < payload.length; at += MAX_UPLOAD_CHUNK_BYTES) {
      client.send({
        t: 'upload.data',
        id: 'up-1',
        data: payload.subarray(at, at + MAX_UPLOAD_CHUNK_BYTES).toString('base64'),
      })
    }
    client.send({
      t: 'upload.end',
      id: 'up-1',
      sha256: createHash('sha256').update(payload).digest('hex'),
    })

    const done = await client.until((m) => m.t === 'upload.done', 'the finish')
    expect(done.t === 'upload.done' && done.bytes).toBe(payload.length)
    expect(readFileSync(join(dir, 'clip.mov'))).toEqual(payload)
  })

  it('answers a port list, and will not tunnel to a port nothing is serving', async () => {
    const harness = await serve({ scanPorts: async () => [{ port: 4321, process: 'node', guessed: false }] })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'ports' })
    const ports = await client.until((m) => m.t === 'ports', 'the port list')
    expect(ports.t === 'ports' && ports.ports).toEqual([{ port: 4321, process: 'node', guessed: false }])

    // A port that is not in the scan is refused before any socket exists, which
    // is what stops this being a way to sweep the Mac's loopback.
    client.send({ t: 'tunnel.open', id: 'tun-1', port: 9999 })
    const closed = await client.until((m) => m.t === 'tunnel.closed', 'the refusal')
    expect(closed.t === 'tunnel.closed' && closed.message).toContain('9999')
    expect(client.received.some((m) => m.t === 'tunnel.opened')).toBe(false)
  })

  it('can list sessions', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'list' })
    const listed = await client.until((m) => m.t === 'sessions', 'the session list')
    expect(listed.t === 'sessions' && listed.sessions[0].cwd).toBe('/tmp/sess-1')
  })

  it('gets the scrollback before any live output', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')
    await client.until((m) => m.t === 'output' && m.replay === true, 'the replay')

    harness.sessions.emit('sess-1', 'live output\r\n')
    await client.until((m) => m.t === 'output' && m.replay !== true, 'the live output')

    // The whole point of the feature: reconnecting shows what was already said,
    // in the order it was said, and only then what happens next.
    const output = client.received.filter((m): m is Extract<ServerMessage, { t: 'output' }> => m.t === 'output')
    expect(output.map((m) => m.data)).toEqual(['earlier output\r\n', 'live output\r\n'])
    expect(output[0].replay).toBe(true)
    expect(output[1].replay).toBeUndefined()
  })

  it('replays the tail of an enormous scrollback rather than choking on it', async () => {
    // `PtyManager` keeps 4,000 chunks and a chunk out of a build log is
    // kilobytes, so an afternoon's session is tens of megabytes. Sent whole it
    // passes the 8 MB backpressure cap, the socket closes itself, and the phone
    // reconnects into the same attach and the same drop — the sessions most
    // worth opening from a phone would be the ones that never open.
    const marker = 'THE-VERY-LAST-LINE'
    const huge = 'a'.repeat(10 * 1024 * 1024) + marker
    const harness = await serve({}, fakeSessions({ 'sess-big': huge }))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'attach', id: 'sess-big' })
    await client.until((m) => m.t === 'attached', 'the attach')
    // Ordered after every replay frame, so its arrival means the replay is done
    // — and it arriving at all means the socket survived the attach.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    const replayed = client.received
      .filter((m): m is Extract<ServerMessage, { t: 'output' }> => m.t === 'output' && m.replay === true)
      .map((m) => m.data)
      .join('')

    expect(replayed.length).toBeLessThanOrEqual(2 * 1024 * 1024)
    // The tail is what the user was reading, so the front is what goes.
    expect(replayed.endsWith(marker)).toBe(true)
    expect(replayed.length).toBeGreaterThan(1024 * 1024)
  })

  it('is told when a session it asked for is not running', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'attach', id: 'nope' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unknown-session' })
    // Refused, not closed: a phone that opened a stale bookmark stays connected.
    expect(harness.endpoint.connections()).toHaveLength(1)
  })
})

describe('input', () => {
  it('reaches the session it is attached to', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    client.send({ t: 'input', id: 'sess-1', data: 'ls -la\r' })
    client.send({ t: 'resize', id: 'sess-1', cols: 100, rows: 30 })
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    expect(harness.sessions.written).toEqual([{ id: 'sess-1', data: 'ls -la\r' }])
    expect(harness.sessions.resized).toEqual([{ id: 'sess-1', cols: 100, rows: 30 }])
  })

  it('is refused for a session this device never attached to', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'input', id: 'sess-1', data: 'rm -rf /\r' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unauthorized' })
    // A remembered session id is not a keyboard.
    expect(harness.sessions.written).toEqual([])
  })
})

describe('starting a session from a phone', () => {
  /**
   * Creating a session is at least as sensitive as typing into one, and in one
   * respect more so: `input` can only reach a session this device already
   * attached to, whereas this makes a new process on somebody's Mac. So the
   * first two tests here are the same two the rest of this file opens with —
   * nothing before `hello`, and nothing for a device a human has not approved.
   */
  it('is refused, and the socket closed, before the phone has said who it is', async () => {
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send({ t: 'create' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({ t: 'error', code: 'unauthenticated', message: 'Say hello first.' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    // The assertion that matters: no process was started. An `error` frame with
    // a shell running behind it would be the worst possible pass.
    expect(sessions.requests).toEqual([])
    expect(client.received.some((m) => m.t === 'created')).toBe(false)
  })

  it('is refused for a device that has paired but nobody has approved', async () => {
    // The credential is real and the device is in the trust store; the human at
    // the Mac has not said yes. It gets its credential and nothing else — note
    // the empty capability list, so it is not even told this desktop can start
    // sessions — and the frame it sends afterwards reaches a closed socket.
    const sessions = creatingSessions()
    const harness = await serve({ auth: awaitApproval }, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toEqual([])
    client.send({ t: 'create' })

    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(sessions.requests).toEqual([])
    expect(harness.endpoint.connections()).toEqual([])
  })

  it('is refused by a desktop whose session layer cannot start one', async () => {
    // The default fake has no `create`, so this desktop never advertised the
    // capability. A client sending it anyway is answered rather than closed:
    // the socket is authenticated and its sessions are fine, it just asked for
    // something this Mac does not do.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unauthorized' })
    expect(harness.endpoint.connections()).toHaveLength(1)
  })

  it('starts one and answers with the row, so the tap that started it can open it', async () => {
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create', cols: 100, rows: 30 })
    const created = await client.until((m) => m.t === 'created', 'the new session')
    expect(created.t === 'created' && created.session.id).toBe('made-1')
    // The size travelled, so the first screen is drawn at the size it is read at.
    expect(sessions.requests).toEqual([{ cwd: undefined, cols: 100, rows: 30 }])
  })

  it('makes a first-class session: it is in the list, and it can be attached to', async () => {
    // The point of routing this through the real session layer rather than a
    // remote-only path. A session the phone started is a session.
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create' })
    const created = await client.until((m) => m.t === 'created', 'the new session')
    const id = created.t === 'created' ? created.session.id : ''

    client.send({ t: 'list' })
    const list = await client.until((m) => m.t === 'sessions', 'the refreshed list')
    expect(list.t === 'sessions' && list.sessions.map((s) => s.id)).toContain(id)

    client.send({ t: 'attach', id })
    await client.until((m) => m.t === 'attached' && m.id === id, 'the attach')
    sessions.emit(id, 'hello from a phone-started shell\r\n')
    const output = await client.until((m) => m.t === 'output' && m.id === id, 'live output')
    expect(output.t === 'output' && output.data).toContain('phone-started')

    client.send({ t: 'input', id, data: 'ls\r' })
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
    expect(sessions.written).toEqual([{ id, data: 'ls\r' }])
  })

  it('refuses a folder this Mac is not offering, rather than starting somewhere else', async () => {
    // Silently substituting the default would be worse than refusing: someone
    // types a command into what they believe is their project.
    const sessions = creatingSessions(['/tmp/allowed'])
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create', cwd: '/etc' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unauthorized' })
    expect(client.received.some((m) => m.t === 'created')).toBe(false)
    // Refused, not closed: a stale folder on a phone is not an attack.
    expect(harness.endpoint.connections()).toHaveLength(1)

    client.send({ t: 'create', cwd: '/tmp/allowed' })
    const created = await client.until((m) => m.t === 'created', 'the new session')
    expect(created.t === 'created' && created.session.cwd).toBe('/tmp/allowed')
  })

  it('tells every other connected device, in a frame they already understand', async () => {
    // `created` is a capability frame and the other phone may never have heard
    // of it; `sessions` is v1 and every client back to the first one reads it.
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const maker = await connect(harness.port)
    const watcher = await connect(harness.port)
    maker.send(HELLO)
    watcher.send(HELLO)
    await maker.until((m) => m.t === 'welcome', 'the welcome')
    await watcher.until((m) => m.t === 'welcome', 'the welcome')

    maker.send({ t: 'create' })
    const refreshed = await watcher.until((m) => m.t === 'sessions', 'the pushed list')
    expect(refreshed.t === 'sessions' && refreshed.sessions.map((s) => s.id)).toContain('made-1')
    expect(watcher.received.some((m) => m.t === 'created')).toBe(false)
  })

  it('starts one session for a double tap, not two', async () => {
    // Spawning is asynchronous and the socket keeps reading throughout. Without
    // a guard the second tap — or a client retrying because the first answer
    // was slow — puts two shells on somebody's Mac and shows them one.
    const sessions = creatingSessions()
    let release = (): void => {}
    sessions.hold = new Promise<void>((settle) => {
      release = settle
    })
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create' })
    client.send({ t: 'create' })
    const error = await client.until((m) => m.t === 'error', 'the second tap')
    expect(error).toMatchObject({ code: 'unavailable' })

    release()
    await client.until((m) => m.t === 'created', 'the one session')
    expect(sessions.requests).toHaveLength(1)
  })

  it('does not fall over when the phone leaves while the session is still starting', async () => {
    // The session is real and stays on the Mac — that is the honest outcome of
    // "start something" — but there is no socket left to tell about it, and
    // writing to one that has gone must not take the main process down.
    const sessions = creatingSessions()
    let release = (): void => {}
    sessions.hold = new Promise<void>((settle) => {
      release = settle
    })
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create' })
    await vi.waitFor(() => expect(sessions.requests).toHaveLength(1))
    client.socket.destroy()
    await new Promise((settle) => setTimeout(settle, 20))
    release()
    await new Promise((settle) => setTimeout(settle, 20))

    expect(harness.endpoint.connections()).toEqual([])
    expect(sessions.list().map((s) => s.id)).toContain('made-1')
  })
})

describe('frames the server will not accept', () => {
  it('rejects one larger than the cap', async () => {
    const harness = await serve({ maxMessageBytes: 1024 })
    const client = await connect(harness.port)
    client.sendFrame(maskedFrame(0x1, Buffer.alloc(4096, 0x61)))

    await expect(client.closed).resolves.toBe(CLOSE.messageTooBig)
  })

  it('rejects one that only claims to be enormous', async () => {
    const harness = await serve({ maxMessageBytes: 1024 })
    const client = await connect(harness.port)

    // A 64-bit length header and no payload: the cap has to be enforced on the
    // declared size, or the process buffers whatever a caller promises.
    const header = Buffer.alloc(14)
    header[0] = 0x81
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(64 * 1024 * 1024), 2)
    client.sendFrame(header)

    await expect(client.closed).resolves.toBe(CLOSE.messageTooBig)
  })

  it('rejects a message fragmented to sneak past the cap', async () => {
    const harness = await serve({ maxMessageBytes: 1024 })
    const client = await connect(harness.port)

    const piece = Buffer.alloc(600, 0x61)
    const start = maskedFrame(0x1, piece)
    start[0] = 0x01 // text, not final
    const rest = maskedFrame(0x0, piece)
    rest[0] = 0x80 // continuation, final
    client.sendFrame(start)
    client.sendFrame(rest)

    await expect(client.closed).resolves.toBe(CLOSE.messageTooBig)
  })

  it('rejects an unmasked frame', async () => {
    const harness = await serve()
    const client = await connect(harness.port)

    const payload = Buffer.from('{"t":"list"}', 'utf8')
    const frame = Buffer.concat([Buffer.from([0x81, payload.length]), payload])
    client.sendFrame(frame)

    await expect(client.closed).resolves.toBe(CLOSE.protocolError)
  })

  it('rejects a binary frame', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.sendFrame(maskedFrame(0x2, Buffer.from([1, 2, 3])))

    await expect(client.closed).resolves.toBe(CLOSE.unsupportedData)
  })

  it('rejects text that is not a message this protocol has', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.sendFrame(maskedFrame(0x1, Buffer.from('not json at all', 'utf8')))

    await expect(client.closed).resolves.toBe(CLOSE.protocolError)
  })
})

describe('closing', () => {
  it('drops every socket and lets go of every session', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    harness.endpoint.closeAll()

    await expect(client.closed).resolves.toBe(CLOSE.goingAway)
    // A server that stops without detaching leaks a subscription into
    // PtyManager for every phone that was connected when it stopped.
    expect(harness.sessions.detached).toEqual(['sess-1'])
    expect(harness.endpoint.connections()).toEqual([])
  })

  it('drops the sockets of a device that was just revoked', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    expect(harness.endpoint.dropDevice('device-2')).toBe(0)
    expect(harness.endpoint.dropDevice('device-1')).toBe(1)

    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(harness.sessions.detached).toEqual(['sess-1'])
  })

  it('drops one connection without touching the pairing', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    const [connection] = harness.endpoint.connections()
    // The panel lists what the phone said it was, so it has to survive the trip.
    expect(connection).toMatchObject({ deviceId: 'device-1', platform: 'iOS' })

    expect(harness.endpoint.dropConnection('no-such-connection')).toBe(false)
    expect(harness.endpoint.dropConnection(connection.id)).toBe(true)
    await expect(client.closed).resolves.toBe(CLOSE.goingAway)
  })

  it('does not admit a device that was revoked while its hello was being checked', async () => {
    // The sweep cannot see this connection — it has no device id until the
    // check lands — and the check is holding the device record it read before
    // it started hashing, so the trust store will still say yes. Verified
    // against the real `RemoteAuth`: a `verifyCredential` whose scrypt overlaps
    // `revokeDevice` returns ok. Without the marker this socket stays open,
    // attached, for as long as the app runs.
    let admit = (): void => {}
    const opened = new Promise<void>((settle) => (admit = settle))
    let arrived = (): void => {}
    const checking = new Promise<void>((settle) => (arrived = settle))

    const slowAuth: RemoteAuthenticator = {
      async authenticate() {
        arrived()
        await opened
        return { ok: true, deviceId: 'device-1', deviceName: 'Test iPhone', credential: null }
      },
    }

    const harness = await serve({ auth: slowAuth })
    const client = await connect(harness.port)
    client.send(HELLO)
    await checking

    expect(harness.endpoint.dropDevice('device-1')).toBe(0) // nothing named it yet
    admit()

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unauthorized' })
    // Same sentence as any other refusal: which of the two happened is not a
    // remote caller's business.
    expect(error.t === 'error' && error.message).toBe('This device is not allowed in. Pair it again from the Mac.')
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
    expect(harness.endpoint.connections()).toEqual([])
    expect(client.received.some((m) => m.t === 'welcome')).toBe(false)
  })

  it('lets a kicked device connect again, unlike a revoked one', async () => {
    // `dropConnection` and `dropDevice` are both "get off my machine"; only one
    // of them is "never again". A marker that outlived the sweep would turn the
    // first into the second.
    const harness = await serve()
    const first = await connect(harness.port)
    first.send(HELLO)
    await first.until((m) => m.t === 'welcome', 'the welcome')
    expect(harness.endpoint.dropDevice('device-1')).toBe(1)
    await first.closed

    const second = await connect(harness.port)
    second.send(HELLO)
    await second.until((m) => m.t === 'welcome', 'the second welcome')
  })

  it('lets go of the session when the phone half-closes without a close frame', async () => {
    // A phone that goes into a tunnel or is force-quit sends a FIN and never a
    // close frame. The server's half of an upgraded socket takes that as `end`
    // and stays writable, so `close` does not fire — and a server listening for
    // `close` alone keeps the session attached to a phone that is gone.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    client.socket.end()
    await new Promise((settle) => setTimeout(settle, 50))

    expect(harness.sessions.detached).toEqual(['sess-1'])
    expect(harness.endpoint.connections()).toEqual([])
  })

  it('drops a phone that stops answering the heartbeat', async () => {
    // The client below never sends a pong, which is what a phone in a tunnel
    // looks like: a TCP connection that stays open for minutes, holding a
    // session, with nobody on the other end.
    const harness = await serve({ pingIntervalMs: 25 })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    await expect(client.closed).resolves.toBe(CLOSE.goingAway)
    expect(harness.sessions.detached).toEqual(['sess-1'])
  })

  it('lets go of the session when the phone simply disappears', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'attach', id: 'sess-1' })
    await client.until((m) => m.t === 'attached', 'the attach')

    client.socket.destroy()
    await new Promise((settle) => setTimeout(settle, 50))

    expect(harness.sessions.detached).toEqual(['sess-1'])
    expect(harness.endpoint.connections()).toEqual([])
  })
})

describe('pairing, against the real trust store', () => {
  /**
   * Not a fake here on purpose. Everything else in this file stubs `RemoteAuth`
   * to keep scrypt out of the socket tests, which leaves the join between the
   * two modules — which secret goes down which path, and what an unapproved
   * device is told — checked by nothing at all. That join is the part most
   * likely to be wrong.
   */
  function realAuth(): { auth: RemoteAuth; desk: ReturnType<typeof pairingDesk> } {
    const dir = mkdtempSync(join(tmpdir(), 'deck-auth-'))
    roots.push(dir)
    const auth = new RemoteAuth(dir)
    return { auth, desk: pairingDesk(auth) }
  }

  const phone = { name: 'iPhone', platform: 'iOS' }

  it('pairs a phone but does not let it in until a human approves', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const { token } = desk.create()

    const paired = await authenticator.authenticate(token, phone, '100.86.107.7')
    expect(paired.ok).toBe(false)
    // The credential still has to travel or the phone can never come back —
    // and it is useless until the device is approved.
    expect(paired.ok === false && paired.credential).toMatch(/\./)
    expect(paired.ok === false && paired.message).toMatch(/[Aa]pprove/)

    const credential = paired.ok === false ? (paired.credential as string) : ''
    const early = await authenticator.authenticate(credential, phone, '100.86.107.7')
    expect(early.ok).toBe(false)

    const device = auth.listDevices()[0]
    expect(auth.approveDevice(device.id)).toBe(true)

    const admitted = await authenticator.authenticate(credential, phone, '100.86.107.7')
    expect(admitted).toMatchObject({ ok: true, deviceId: device.id })
  })

  it('gets its credential across the wire before the socket closes', async () => {
    // The whole pairing hinges on a frame that is written and then immediately
    // followed by a close. Destroying the socket in the same tick would discard
    // it unsent, the phone would have no credential, and nothing above this line
    // would notice — every other pairing test calls the authenticator directly.
    const { auth, desk } = realAuth()
    const harness = await serve({ auth: authenticatorFor(auth, desk) })
    const { token } = desk.create()

    const pairing = await connect(harness.port)
    pairing.send({ t: 'hello', protocol: PROTOCOL_VERSION, token, device: phone })

    const welcome = await pairing.until((m) => m.t === 'welcome', 'the credential')
    const credential = welcome.t === 'welcome' ? welcome.token : null
    expect(credential).toMatch(/\./)
    // Carrying a credential is not being let in.
    expect(welcome.t === 'welcome' && welcome.sessions).toEqual([])
    await expect(pairing.closed).resolves.toBe(CLOSE.policyViolation)
    expect(harness.endpoint.connections()).toEqual([])

    // Still pending: the credential is real and opens nothing.
    const early = await connect(harness.port)
    early.send({ t: 'hello', protocol: PROTOCOL_VERSION, token: credential, device: phone })
    const refused = await early.until((m) => m.t === 'error', 'the refusal')
    expect(refused).toMatchObject({ code: 'unauthorized' })
    await early.closed

    auth.approveDevice(auth.listDevices()[0].id)
    const admitted = await connect(harness.port)
    admitted.send({ t: 'hello', protocol: PROTOCOL_VERSION, token: credential, device: phone })
    const second = await admitted.until((m) => m.t === 'welcome', 'the real welcome')
    // Present exactly once, on the connection that paired.
    expect(second.t === 'welcome' && second.token).toBeNull()
    expect(second.t === 'welcome' && second.sessions.map((s) => s.id)).toEqual(['sess-1'])
  })

  it('refuses a pairing code that was cancelled', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const { token } = desk.create()
    desk.cancel()

    const refused = await authenticator.authenticate(token, phone, '100.86.107.7')
    expect(refused.ok).toBe(false)
    expect(refused.ok === false && refused.credential).toBeUndefined()
    // Cancel means cancelled, not "hidden": no device row was created either.
    expect(auth.listDevices()).toEqual([])
  })

  it('refuses the previous code once a new one is on screen', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const first = desk.create()
    desk.create()

    expect((await authenticator.authenticate(first.token, phone, '100.86.107.7')).ok).toBe(false)
    expect(auth.listDevices()).toEqual([])
  })

  it('refuses a revoked device without saying that is why', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const { token } = desk.create()
    const paired = await authenticator.authenticate(token, phone, '100.86.107.7')
    const credential = paired.ok === false ? (paired.credential as string) : ''
    const device = auth.listDevices()[0]
    auth.approveDevice(device.id)
    expect((await authenticator.authenticate(credential, phone, '100.86.107.7')).ok).toBe(true)

    auth.revokeDevice(device.id)
    const after = await authenticator.authenticate(credential, phone, '100.86.107.7')
    expect(after.ok).toBe(false)
    // "revoked" and "never heard of you" have to read the same from outside, or
    // the refusal is an oracle for which device ids are real.
    expect(after.ok === false && after.message).toBe('This device is not allowed in. Pair it again from the Mac.')
  })
})

describe('the static files', () => {
  async function get(
    port: number,
    path: string,
    host?: string,
  ): Promise<{ status: number; body: string; headers: Record<string, string | string[] | undefined> }> {
    return new Promise((settle, fail) => {
      const req = request({ host: '127.0.0.1', port, path, headers: host ? { host } : {} }, (res) => {
        let body = ''
        res.setEncoding('utf8')
        res.on('data', (chunk: string) => {
          body += chunk
        })
        res.on('end', () => settle({ status: res.statusCode ?? 0, body, headers: res.headers }))
      })
      req.on('error', fail)
      req.end()
    })
  }

  it('serves the shell', async () => {
    const harness = await serve()
    const response = await get(harness.port, '/')
    expect(response.status).toBe(200)
    expect(response.body).toContain('<title>deck</title>')
  })

  it('gives a client-side route the shell rather than a 404', async () => {
    const harness = await serve()
    const response = await get(harness.port, '/session/abc')
    expect(response.status).toBe(200)
    expect(response.body).toContain('<title>deck</title>')
  })

  it('caches the fingerprinted bundle forever and nothing else', async () => {
    // `pwa/vite.config.ts` fingerprints into /assets/ and deliberately emits
    // sw.js, manifest.webmanifest and the icons at fixed URLs, because a
    // service worker's script and scope have to stay put across builds. Those
    // are the files whose contents change from one build to the next, so an
    // immutable year on them is how a phone ends up holding a manifest — and,
    // through the worker's own install step, a shell — from a build months old.
    const harness = await serve()
    mkdirSync(join(harness.root, 'assets'))
    writeFileSync(join(harness.root, 'assets', 'index-BoSiuOJ9.js'), 'console.log(1)')
    writeFileSync(join(harness.root, 'sw.js'), 'self.addEventListener("fetch", () => {})')
    writeFileSync(join(harness.root, 'manifest.webmanifest'), '{"name":"deck"}')

    const hashed = await get(harness.port, '/assets/index-BoSiuOJ9.js')
    expect(hashed.headers['cache-control']).toBe('public, max-age=31536000, immutable')

    for (const path of ['/sw.js', '/manifest.webmanifest', '/']) {
      const stable = await get(harness.port, path)
      expect(stable.status, path).toBe(200)
      expect(stable.headers['cache-control'], path).toBe('no-cache')
    }
  })

  it('refuses to be framed', async () => {
    // The page is a live terminal on a phone that is already signed in. A tap
    // the user believes is landing on someone else's page must not land here.
    const harness = await serve()
    const response = await get(harness.port, '/')
    expect(response.headers['content-security-policy']).toBe("frame-ancestors 'none'")
    expect(response.headers['x-frame-options']).toBe('DENY')
  })

  it('refuses a Host it is not serving', async () => {
    const harness = await serve({ hosts: ['deck.example.ts.net:8443'] })
    expect((await get(harness.port, '/', 'evil.example.com')).status).toBe(403)
    expect((await get(harness.port, '/', 'deck.example.ts.net:8443')).status).toBe(200)
  })

  it('refuses an upgrade on a Host it is not serving', async () => {
    const harness = await serve({ hosts: ['deck.example.ts.net:8443'] })
    await expect(connect(harness.port, WS_PATH, 'evil.example.com')).rejects.toThrow(/403/)
  })

  it('refuses an upgrade anywhere but the socket path', async () => {
    const harness = await serve()
    await expect(connect(harness.port, '/anything-else')).rejects.toThrow(/404/)
  })
})

describe('resolveStaticPath', () => {
  /**
   * The web root, and the same directory as this platform names it.
   *
   * `resolveStaticPath` answers in resolved, host-shaped paths, so `/srv/pwa`
   * on Windows is `C:\srv\pwa` — the containment check there compares
   * backslashed absolute paths, and comparing them against a literal
   * `/srv/pwa/` prefix said "outside the root" for every answer, including the
   * ordinary asset. `ROOT` is what goes in; `RESOLVED` is what comes back.
   */
  const root = '/srv/pwa'
  const RESOLVED = resolve(root)

  it('keeps traversal inside the root', () => {
    // Encoded and plain are the same request once decoded, so both are checked
    // after decoding rather than by pattern-matching the raw string.
    //
    // These resolve to a path *inside* the root rather than to null, because
    // `normalize` collapses leading `..` against the root of an absolute path —
    // verified on this machine: `/assets/../../secret.key` normalizes to
    // `/secret.key`, not to `../secret.key`. The property that matters is not
    // which answer comes back but that no answer ever names a file outside the
    // PWA directory.
    //
    // The backslash forms are here because on Windows they are separators, not
    // filename characters: `\..\..\etc\passwd` is a traversal attempt there and
    // an oddly-named file on POSIX. Both platforms have to keep it inside, and
    // both are checked on both — the request arrives over HTTP from a phone,
    // which is free to spell it either way regardless of which OS receives it.
    for (const attempt of [
      '/../../etc/passwd',
      '/%2e%2e%2f%2e%2e%2fetc/passwd',
      '/assets/../../secret.key',
      '/..\\..\\etc\\passwd',
      '/%2e%2e%5c%2e%2e%5cetc%5cpasswd',
      '/assets/..\\..\\secret.key',
    ]) {
      const resolved = resolveStaticPath(root, attempt)
      expect(resolved, attempt).not.toBeNull()
      expect(resolved?.startsWith(RESOLVED + sep), attempt).toBe(true)
    }
  })

  it('refuses a path that resolves outside the root', () => {
    // The containment check earns its keep on a request path that is not
    // rooted, which `normalize` leaves alone.
    expect(resolveStaticPath(root, '../secret.key')).toBeNull()
    expect(resolveStaticPath(root, '../../etc/passwd')).toBeNull()
  })

  it('resolves ordinary assets', () => {
    expect(resolveStaticPath(root, '/assets/app.js')).toBe(join(RESOLVED, 'assets', 'app.js'))
    expect(resolveStaticPath(root, '/')).toBe(join(RESOLVED, 'index.html'))
  })

  it('refuses a path with a null byte', () => {
    expect(resolveStaticPath(root, '/index.html%00.png')).toBeNull()
  })
})

describe('the server as a whole', () => {
  const neverListens = {
    sessions: fakeSessions(),
    auth: allowKnownDevice,
    webRoot: '/nowhere',
    certDir: '/nowhere',
  }

  it('does not listen when the tailnet is not ready, and says why', async () => {
    const server = createRemoteServer({
      ...neverListens,
      readTailnet: async () => ({
        ready: false,
        state: 'logged-out',
        reason: 'Tailscale is installed but signed out on this Mac.',
      }),
      serve: {
        on: async () => {
          throw new Error('the proxy must never be asked for before the tailnet is ready')
        },
        off: async () => {},
      },
    })

    const status = await server.start()
    expect(status.running).toBe(false)
    expect(status.url).toBeNull()
    expect(status.reason).toBe('Tailscale is installed but signed out on this Mac.')
    expect(server.url()).toBeNull()
  })

  it('does not stay up when the proxy refuses, and passes the reason through', async () => {
    // TLS is terminated by `tailscale serve`, not in this process — Electron's
    // BoringSSL accepts the connection and never completes the handshake. So
    // the failure that matters here is the proxy refusing, not a certificate.
    const server = createRemoteServer({
      ...neverListens,
      // A real socket is bound before the proxy is asked for, so this needs a
      // port nothing else holds. 8443 is the default, and a running copy of the
      // app sits on it — which reports a port clash instead of the proxy's own
      // refusal, and that is the thing under test here.
      port: 39217,
      readTailnet: async () => ready(),
      serve: {
        on: async () => ({ ok: false, message: 'HTTPS certificates are off for this tailnet.' }),
        off: async () => {},
      },
    })

    const status = await server.start()
    expect(status.running).toBe(false)
    // The daemon's own sentence, not one of ours: the fix is in their admin
    // console and only the daemon knows which switch.
    expect(status.reason).toBe('HTTPS certificates are off for this tailnet.')
  })

  it('refuses to serve a tailnet with no MagicDNS name', async () => {
    const server = createRemoteServer({
      ...neverListens,
      readTailnet: async () => ({ ...ready(), magicDns: false, dnsName: '' }),
      serve: {
        on: async () => {
          throw new Error('the proxy must never be asked for without a name to put it on')
        },
        off: async () => {},
      },
    })

    const status = await server.start()
    expect(status.running).toBe(false)
    expect(status.reason).toMatch(/MagicDNS/)
  })

  it('is safe to stop when it never started', async () => {
    const server = createRemoteServer({ ...neverListens, readTailnet: async () => ready() })
    const status = await server.stop()
    expect(status.running).toBe(false)
    expect(status.connections).toEqual([])
  })
})

/**
 * A ready tailnet, shaped exactly as `tailnet.ts` reports this machine.
 *
 * Annotated rather than inferred on purpose: the return type is what makes a
 * rename in that module fail here instead of silently leaving these tests
 * asserting against a shape the server no longer receives.
 */
function ready(): TailnetReady {
  return {
    ready: true,
    address: '100.86.107.119',
    address6: 'fd7a:115c:a1e0::fd39:6b77',
    dnsName: 'asads-macbook-pro-1.taild11505.ts.net',
    hostName: 'asads-macbook-pro-1',
    tailnetName: 'example@gmail.com',
    magicDnsSuffix: 'taild11505.ts.net',
    magicDns: true,
    certsAvailable: true,
    binary: '/opt/homebrew/bin/tailscale',
  }
}
