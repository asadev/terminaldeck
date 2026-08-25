import { createHash, randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
// The machine's own word for itself — `Mac` here, `PC` on the Windows runner.
// Composed rather than spelled, so an assertion about a sentence the product
// builds cannot be right on one platform and wrong on another.
import { currentPlatform, machineNoun } from '../platform/host'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  CAPABILITIES,
  CAPABILITY,
  CLOSE,
  MAX_UPLOAD_CHUNK_BYTES,
  PROTOCOL_VERSION,
  type CopilotGrantWire,
  type RemoteSession,
  type ServerMessage,
  type ServerSettingKey,
  type ServerSettingWire,
} from './protocol'
import type { DevServerState, DevServers } from '../dev-server'
import type { TailnetReady } from './tailnet'
import { MAX_FAILED_ATTEMPTS, RemoteAuth } from './device-auth'
import { CopilotAccess } from './copilot-access'
import { ConsentBroker, type ConsentOutcome } from '../deck-control/consent'
import { CopilotRuns } from './copilot-runs'
import type { CopilotRemote } from './copilot-remote'
import type { WindowAskDesk } from './window-asks'
import { SessionFanout, type PtySource } from './session-fanout'
import { CODE_LENGTH, isCode } from '../../shared/short-code'
import type { HeldSession } from '../../shared/held-window'
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
  type RemoteConnection,
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
  /** Folders this desktop offers a given device. Anything unlisted gets the shared set. */
  offers: Map<string, string[]>
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
  // Per device, because that is the whole shape of the real one: a desktop
  // offers each phone the folders somebody chose for it, and a device with no
  // row of its own gets the shared list. Present on every host that can create,
  // absent on every host that cannot — the two travel together.
  fake.offers = new Map<string, string[]>()
  fake.folders = (deviceId: string): string[] => fake.offers.get(deviceId) ?? folders
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
      message: 'Paired. Approve this device in the desktop app, then reconnect.',
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

  /**
   * The push the frame has always claimed to send, and never sent.
   *
   * `browser.surfaces.rows` documents itself as *"also pushed unsolicited when
   * the strip changes"*, and until 2026-08-25 **nothing on this endpoint sent
   * it** — there was no fan-out at all. The iOS client asks once per connection
   * and then waits, so a window opened from the phone's own address bar showed
   * up in its list the next time something happened to make it ask, which on a
   * screen that never re-asks is never. Asad's sentence for the feature was
   * *"it should browser and stream here to interact"*; the page opened on the
   * server and the phone that opened it never saw it.
   *
   * The gate is read **at send time** rather than at trigger time, which is the
   * property worth pinning: a device that may not watch hears nothing about a
   * strip it could not have watched anyway.
   */
  it('pushes the browser strip when it moves, to the devices that may watch', async () => {
    const surfaces = [
      { window: 'browser:1', url: 'http://localhost:3000/', title: 'Admin', live: true },
    ]
    const harness = await serve({
      screencast: {
        // `watch` is typed as returning the promise, so the fake is written
        // `async` — an arrow returning `undefined` typechecks nowhere and the
        // repository's real gate is `npm run typecheck`, not `tsc --noEmit`.
        watch: async (): Promise<{ ok: boolean; reason?: string }> => ({ ok: true }),
        unwatch: (): void => undefined,
        ack: (): void => undefined,
        input: async (): Promise<{ ok: boolean; reason?: string }> => ({ ok: true }),
        surfaces: () => surfaces,
        dropWatcher: (): void => undefined,
      },
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    // Nobody asked. The strip moving is the whole trigger.
    expect(harness.endpoint.surfacesChanged()).toBe(1)
    const pushed = await client.until((m) => m.t === 'browser.surfaces.rows', 'the strip')
    expect(pushed.t === 'browser.surfaces.rows' && pushed.surfaces).toEqual(surfaces)
    // An unsolicited push carries no `rid`: it is answering nothing.
    expect(pushed.t === 'browser.surfaces.rows' && pushed.rid).toBeUndefined()
  })

  it('says nothing about the strip on a host that has no browser to cast', async () => {
    // The counter-example that keeps the rule honest. `screencast` absent is how
    // a host says it cannot cast, so the fan-out must be silent rather than
    // sending an empty strip — an empty list reads as *this machine has no
    // windows open*, which is a different fact.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(harness.endpoint.surfacesChanged()).toBe(0)
  })

  it('is told what this desktop can do beyond protocol v1', async () => {
    // The whole reason the version did not have to move. A phone offers the
    // localhost feature only because this list said so, so a build that stops
    // advertising it makes the button disappear rather than making a tap fail.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    // Two, and they are the only two that no session layer can take away.
    // `localhost` has no object behind it at all, and `send` is read off
    // `SessionAccess.write`, which is a *required* member of that interface —
    // so this stub-shaped host, which cannot create, close, read a screen or
    // report a plan, still serves both. Everything else on the list is gated on
    // something this fake deliberately does not have.
    // `files`, `git`, `panels` and `browser.profiles` join them since
    // 2026-08-24, and for the same reason: they need nothing injected — a
    // filesystem, `git` and a JSON file on disk are not things a host can be
    // missing the way it can be missing a session layer. The narrowing that
    // matters for them is per-device, in `capabilitiesFor`, which withholds all
    // four from a guest.
    //
    // `browser.control` is deliberately **not** on this list and is the
    // counter-example that keeps the rule honest: driving a browser needs a
    // browser, so it is gated on `options.machineBrowser` being present, and
    // this fake does not have one. A host with no Chromium never tells a phone
    // it has windows — *"a tab that refuses on every press is a worse answer
    // than a client that never knew."*
    expect(welcome.t === 'welcome' && welcome.capabilities).toEqual([
      'localhost',
      'send',
      'files',
      'git',
      'panels',
      'browser.profiles',
    ])
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

  it('advertises nothing outside `offer`, including the capability nothing else can withhold', async () => {
    /*
     * The public demo host, and the one capability it could not otherwise take
     * away.
     *
     * `create`, `upload` and `credential` each have an object behind them, so a
     * host that lacks the object does not advertise the name. `localhost` has
     * none — every host can pipe bytes to its own loopback — which means before
     * `offer` existed there was no way to build a host that did not offer a
     * stranger a tunnel into whatever it happens to be running. That is exactly
     * the host `src/headless/demo.ts` builds.
     *
     * Both directions are asserted, because a ceiling that could *add* would be
     * worse than none: naming `upload` with no uploads directory must still
     * advertise nothing, or the demo could promise a button that only ever
     * produces a refusal.
     */
    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    roots.push(dir)

    const narrowed = await serve({ offer: ['create'], uploadsDir: dir }, creatingSessions())
    const client = await connect(narrowed.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toEqual(['create'])

    const promising = await serve({ offer: ['upload'] })
    const empty = await connect(promising.port)
    empty.send(HELLO)
    const nothing = await empty.until((m) => m.t === 'welcome', 'the welcome')
    expect(nothing.t === 'welcome' && nothing.capabilities).toEqual([])
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

  /*
   * `upload.begin.dir` — a destination the *sender* named, and the one field on
   * this wire that names a place.
   *
   * `uploads.ts` opens by refusing to build a path out of two pieces of network
   * input, and that promise is kept by this layer rather than by that one: the
   * folder is resolved against the list **this host published to this device**,
   * exactly as `create` resolves its `cwd`. These three tests are the whole of
   * that rule, and they exist because the failure they prevent is a `writeFile`
   * at a location chosen across a network.
   */
  it('takes a file into a folder inside one it offered this device', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    const shared = mkdtempSync(join(tmpdir(), 'deck-shared-'))
    roots.push(dir, shared)
    // Containment rather than equality, for the reason `device-reach.ts` gives:
    // somebody who shared a project shared what is under it.
    const inside = join(shared, 'incoming')
    const harness = await serve({ uploadsDir: dir }, creatingSessions([shared]))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 3, dir: inside })
    const ready = await client.until((m) => m.t === 'upload.ready', 'the path')
    expect(ready.t === 'upload.ready' && ready.path).toBe(join(inside, 'a.bin'))
  })

  it('refuses a folder it never offered, before anything is created', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    const shared = mkdtempSync(join(tmpdir(), 'deck-shared-'))
    roots.push(dir, shared)
    const harness = await serve({ uploadsDir: dir }, creatingSessions([shared]))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 3, dir: '/etc' })
    const refusal = await client.until((m) => m.t === 'upload.failed', 'a refusal')
    // On the upload's own id, so the sender ends the right progress bar — the
    // same rule every other refusal on this verb follows.
    expect(refusal.t === 'upload.failed' && refusal.id).toBe('up-1')
    expect(existsSync(join('/etc', 'a.bin'))).toBe(false)
  })

  it('lets one of your own machines name any folder, as it may start a session anywhere', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'deck-uploads-'))
    const elsewhere = mkdtempSync(join(tmpdir(), 'deck-elsewhere-'))
    roots.push(dir, elsewhere)
    const harness = await serve(
      // What the Electron shell answers for a device approved as `mine` —
      // `reachFor`'s own rule, and the reason the offered list is not the
      // ceiling for such a device: for it that list is only suggestions.
      { uploadsDir: dir, unrestrictedFolders: () => true },
      creatingSessions(['/tmp/somewhere-else']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 3, dir: elsewhere })
    const ready = await client.until((m) => m.t === 'upload.ready', 'the path')
    expect(ready.t === 'upload.ready' && ready.path).toBe(join(elsewhere, 'a.bin'))
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

/**
 * Typing into a session this connection never attached to.
 *
 * `input`'s gate — *"Attachment is the authorisation"* — is a true sentence
 * about `input` and it was never the only door. The reach is, and `mayTouch` is
 * asked at four of them including on every `input` keystroke *after* the handle
 * check. What this capability does is let a caller that has something to say and
 * nothing to read through the second door without buying the first, which is
 * what the browser's Send-to-session picker needed: it has listed every session
 * on every paired machine since 2026-08-18 and could type into none of them,
 * because earning a handle would have meant displacing the one a terminal pane
 * on the same connection already held — dropping that pane's subscription and
 * replaying its whole scrollback at whoever was reading it.
 *
 * The assertions worth having are therefore about what is *not* in the path.
 * `attachCount` is the one that would catch a fix that worked by attaching
 * quietly, which is the tempting shape and the one his review was complaining
 * about.
 */
describe('sending to a session without attaching to it', () => {
  it('is advertised by every host, because every session layer can write', async () => {
    // Not gated the way `controls` and `usage` are: those hang off an optional
    // member of `SessionAccess` and this one is `write`, which is required. The
    // default fake here is the stub-shaped host that advertises neither of the
    // other two, and it still offers this.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.send)
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.controls)
  })

  it('reaches the session with no attach anywhere in the path', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'session.send', rid: 'snd-1', id: 'sess-1', data: 'look at this button\r' })
    const answer = await client.until((m) => m.t === 'session.sent', 'the answer')
    expect(answer).toMatchObject({ t: 'session.sent', rid: 'snd-1', id: 'sess-1', ok: true })

    // The same bytes `input` delivers, at the same door.
    expect(harness.sessions.written).toEqual([{ id: 'sess-1', data: 'look at this button\r' }])
    // And the whole point of the verb: nothing subscribed. A fix that worked by
    // attaching first would pass every assertion above this line and would take
    // a terminal pane's handle away in the real app.
    expect(harness.sessions.attachCount, 'the send attached to the session').toBe(0)
    expect(harness.sessions.detached).toEqual([])
  })

  it('refuses a device that may not touch that session, and writes nothing', async () => {
    /*
     * The door, and the only one this verb has. The sentence is deliberately the
     * one an unknown id gets — these ids are recoverable from an alert, a
     * transcript path or an older list, so a distinct refusal would confirm that
     * this one names something real.
     *
     * It arrives as a `session.sent` rather than as an `error`, unlike the same
     * refusal on `controls.apply`, because an `error` carries no `rid`: the
     * asking side holds a promise per request and would sit out its own deadline
     * over a refusal this host decided immediately.
     */
    const sessions = { ...fakeSessions(), visible: () => false }
    const harness = await serve({ sessions })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'session.send', rid: 'snd-2', id: 'sess-1', data: 'rm -rf /\r' })
    const answer = await client.until((m) => m.t === 'session.sent', 'the refusal')
    expect(answer).toMatchObject({ t: 'session.sent', rid: 'snd-2', id: 'sess-1', ok: false })
    expect(answer.t === 'session.sent' && answer.message).toContain('sess-1')
    expect(sessions.written, 'a session this device may not see was written to').toEqual([])

    // And the connection survives, like every other refused request in this file.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
  })

  it('answers a host that was told not to offer it, rather than dropping the frame', async () => {
    // `options.offer` is the one thing that can take this capability away — the
    // public demo box is that host — and a client that never read the welcome
    // still sends the frame. Silence would be a spinner on the other machine.
    const harness = await serve({ offer: [] })
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.send)

    client.send({ t: 'session.send', rid: 'snd-3', id: 'sess-1', data: 'hello' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unavailable')
    expect(harness.sessions.written).toEqual([])
  })
})

/**
 * The two settings this machine owns rather than each device, over the wire.
 *
 * The gate is the same shape as `logins`: withheld from a guest in the welcome
 * *and* refused at serve time, because there is no push frame that could correct
 * a welcome later. The refusal is `unauthorized` rather than the `unavailable`
 * its neighbour uses -- every machine has settings, so naming it leaks nothing --
 * and a host built without the store answers `unavailable`, because the device
 * may ask and this build cannot. The change push is per connection, read at send
 * time, so a device demoted between the change and the send hears nothing.
 */
describe('the two settings this machine owns', () => {
  const GUEST_CREDENTIAL = 'device-guest.Z3Vlc3Q='
  // Two devices, so `ownDevice` can tell an owner's own from a guest -- the real
  // gate keys on the device id, not the connection.
  const twoDevices: RemoteAuthenticator = {
    async authenticate(token) {
      if (token === CREDENTIAL) return { ok: true, deviceId: 'device-1', deviceName: 'Owner', credential: null }
      if (token === GUEST_CREDENTIAL) return { ok: true, deviceId: 'device-guest', deviceName: 'Guest', credential: null }
      return { ok: false, message: 'This device is not allowed in.' }
    },
  }
  const GUEST_HELLO = { ...HELLO, token: GUEST_CREDENTIAL }

  interface FakeServerSettings {
    reads: number
    applied: Array<{ key: string; value: string }>
    read(): ServerSettingWire[]
    apply(key: ServerSettingKey, value: string): { ok: boolean; message: string; setting: ServerSettingWire }
    noteChanged(): void
    onChanged(listener: () => void): () => void
    fire(): void
  }

  function fakeServerSettings(): FakeServerSettings {
    const listeners = new Set<() => void>()
    const rows: ServerSettingWire[] = [
      { key: 'agents.defaultProvider', value: 'claude', options: ['claude', 'codex', 'gemini', 'shell'] },
      { key: 'general.restoreSessions', value: 'true' },
    ]
    return {
      reads: 0,
      applied: [],
      read() {
        this.reads += 1
        return rows.map((row) => ({ ...row }))
      },
      apply(key, value) {
        this.applied.push({ key, value })
        return { ok: true, message: `set ${key}`, setting: { key, value } }
      },
      noteChanged() {
        for (const listener of [...listeners]) listener()
      },
      onChanged(listener) {
        listeners.add(listener)
        return () => listeners.delete(listener)
      },
      fire() {
        for (const listener of [...listeners]) listener()
      },
    }
  }

  it('is advertised to an owner and withheld from a guest', async () => {
    const harness = await serve({
      auth: twoDevices,
      serverSettings: fakeServerSettings(),
      ownDevice: (id) => id === 'device-1',
    })

    const owner = await connect(harness.port)
    owner.send(HELLO)
    const ownerWelcome = await owner.until((m) => m.t === 'welcome', 'the welcome')
    expect(ownerWelcome.t === 'welcome' && ownerWelcome.capabilities).toContain(CAPABILITY.settings)

    const guest = await connect(harness.port)
    guest.send(GUEST_HELLO)
    const guestWelcome = await guest.until((m) => m.t === 'welcome', 'the welcome')
    expect(guestWelcome.t === 'welcome' && guestWelcome.capabilities).not.toContain(CAPABILITY.settings)
  })

  it('is not advertised by a host that was built without the store', async () => {
    const harness = await serve({ auth: twoDevices })
    const owner = await connect(harness.port)
    owner.send(HELLO)
    const welcome = await owner.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.settings)
  })

  it('answers an owner read and apply', async () => {
    const settings = fakeServerSettings()
    const harness = await serve({ auth: twoDevices, serverSettings: settings, ownDevice: () => true })
    const owner = await connect(harness.port)
    owner.send(HELLO)
    await owner.until((m) => m.t === 'welcome', 'the welcome')

    owner.send({ t: 'settings.read', rid: 'set-1' })
    const state = await owner.until((m) => m.t === 'settings.state', 'the state')
    expect(state.t === 'settings.state' && state.settings.map((row) => row.key)).toEqual([
      'agents.defaultProvider',
      'general.restoreSessions',
    ])

    owner.send({ t: 'settings.apply', rid: 'set-2', key: 'agents.defaultProvider', value: 'codex' })
    const applied = await owner.until((m) => m.t === 'settings.applied', 'the outcome')
    expect(applied).toMatchObject({ t: 'settings.applied', rid: 'set-2', ok: true })
    expect(applied.t === 'settings.applied' && applied.setting.value).toBe('codex')
    expect(settings.applied).toEqual([{ key: 'agents.defaultProvider', value: 'codex' }])
  })

  it('refuses a guest with unauthorized and touches nothing', async () => {
    const settings = fakeServerSettings()
    const harness = await serve({ auth: twoDevices, serverSettings: settings, ownDevice: (id) => id === 'device-1' })
    const guest = await connect(harness.port)
    guest.send(GUEST_HELLO)
    await guest.until((m) => m.t === 'welcome', 'the welcome')

    guest.send({ t: 'settings.read', rid: 'g-1' })
    const readErr = await guest.until((m) => m.t === 'error', 'the read refusal')
    expect(readErr).toMatchObject({ t: 'error', code: 'unauthorized' })

    guest.send({ t: 'settings.apply', rid: 'g-2', key: 'general.restoreSessions', value: 'false' })
    const applyErr = await guest.until((m) => m.t === 'error', 'the apply refusal')
    expect(applyErr).toMatchObject({ t: 'error', code: 'unauthorized' })

    // No side effect: the store was neither read nor written for the guest.
    expect(settings.reads).toBe(0)
    expect(settings.applied).toEqual([])
    // And the connection survives, like every other refused request here.
    guest.send({ t: 'ping' })
    await guest.until((m) => m.t === 'pong', 'the pong')
  })

  it('answers unavailable, not unauthorized, when the host does not serve settings', async () => {
    const harness = await serve({ auth: twoDevices })
    const owner = await connect(harness.port)
    owner.send(HELLO)
    await owner.until((m) => m.t === 'welcome', 'the welcome')

    owner.send({ t: 'settings.read', rid: 'set-1' })
    const error = await owner.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unavailable')
  })

  it('pushes a change only to an owner device that asked to hear it', async () => {
    const settings = fakeServerSettings()
    const harness = await serve({ auth: twoDevices, serverSettings: settings, ownDevice: (id) => id === 'device-1' })

    const mineWithCap = await connect(harness.port)
    mineWithCap.send({ ...HELLO, capabilities: [CAPABILITY.settings] })
    await mineWithCap.until((m) => m.t === 'welcome', 'the welcome')

    const mineNoCap = await connect(harness.port)
    mineNoCap.send(HELLO)
    await mineNoCap.until((m) => m.t === 'welcome', 'the welcome')

    const guest = await connect(harness.port)
    guest.send({ ...GUEST_HELLO, capabilities: [CAPABILITY.settings] })
    await guest.until((m) => m.t === 'welcome', 'the welcome')

    settings.fire()

    const changed = await mineWithCap.until((m) => m.t === 'settings.changed', 'the push')
    expect(changed.t === 'settings.changed' && changed.settings.map((row) => row.key)).toEqual([
      'agents.defaultProvider',
      'general.restoreSessions',
    ])

    // A ping/pong barrier: any push that was going to arrive would have arrived
    // before the pong, so the absence below is real rather than merely early.
    mineNoCap.send({ t: 'ping' })
    await mineNoCap.until((m) => m.t === 'pong', 'the pong')
    guest.send({ t: 'ping' })
    await guest.until((m) => m.t === 'pong', 'the pong')

    expect(mineNoCap.received.some((m) => m.t === 'settings.changed')).toBe(false)
    expect(guest.received.some((m) => m.t === 'settings.changed')).toBe(false)
  })

  it('stops pushing to a device demoted between the change and the send', async () => {
    const settings = fakeServerSettings()
    let owner = true
    const harness = await serve({ auth: twoDevices, serverSettings: settings, ownDevice: () => owner })

    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: [CAPABILITY.settings] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    // Demoted after the welcome, before the change. `ownDevice` is read inside the
    // push loop at send time, so the frame is never composed for this socket.
    owner = false
    settings.fire()

    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
    expect(client.received.some((m) => m.t === 'settings.changed')).toBe(false)
  })
})

/**
 * The copilot's own terminal, asked for by name over a real socket.
 *
 * This was a live hole in 0.3.0 and not a gap in an unbuilt feature:
 * `SessionFanout.list()` was `ptys.list()` mapped with nothing taken out,
 * `attach()` admitted any id that came back from it, and remote access is on
 * unless somebody turned it off. So on every machine with a paired device, that
 * device could list, find the row whose folder is `<userData>/copilot`, attach,
 * and type into the Claude CLI that holds `deck-control` — past the per-device
 * copilot grant, past every tier, past every budget and past the confirmation
 * dialog, because none of those sit between a pty and its keyboard.
 *
 * **The point of testing it here rather than only in `session-fanout.test.ts`
 * is that absence from a list is not a permission check.** These ids leak by
 * design — `SessionMeta.originRunId` points at them, an alert names one, a
 * transcript path contains one — so the question that matters is what happens
 * when an authenticated phone asks for it *by id*, which is what a client does
 * rather than what a unit test can assert about a return value. The real
 * `SessionFanout` is wired to the real server for the same reason: this is the
 * whole path a phone actually travels.
 */
describe('the copilot’s terminal, over the wire', () => {
  const COPILOT = 'cop-7f3a'

  /** A pty layer holding one ordinary session and the copilot's. */
  function ptysWithCopilot(): PtySource & { written: string[]; resized: number } {
    const source = {
      written: [] as string[],
      resized: 0,
      list: () => [
        { id: 'sess-1', title: 'api', cwd: '/work/api', provider: 'claude', exitCode: null },
        { id: COPILOT, title: 'copilot', cwd: '/data/copilot', provider: 'claude', exitCode: null },
      ],
      write: (_id: string, data: string) => void source.written.push(data),
      resize: () => void (source.resized += 1),
      scrollback: () => 'earlier output\r\n',
      hidden: (id: string) => id === COPILOT,
    }
    return source
  }

  it('refuses a phone that asks for it by id, having never listed it', async () => {
    const ptys = ptysWithCopilot()
    const harness = await serve({ sessions: new SessionFanout(ptys) })
    const client = await connect(harness.port)
    client.send(HELLO)

    // The listing first, because that is the door the phone is meant to use.
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.sessions.map((s) => s.id)).toEqual(['sess-1'])

    // And now the door it is not: the id, typed straight into an attach frame.
    client.send({ t: 'attach', id: COPILOT, cols: 80, rows: 24 })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({
      t: 'error',
      code: 'unknown-session',
      message: `No session ${COPILOT} is running.`,
    })

    // No handle was minted, so no scrollback and no live output ever left the
    // machine — the assertion that matters, because a refusal sent *after* a
    // replay would still have published the copilot's conversation.
    expect(client.received.some((m) => m.t === 'attached')).toBe(false)
    expect(client.received.some((m) => m.t === 'output')).toBe(false)
    // And the size that travelled with the attach did not reshape its terminal.
    expect(ptys.resized).toBe(0)
  })

  it('answers exactly as it does for an id that names nothing at all', async () => {
    /*
     * A distinct refusal would confirm that the id names something real, which
     * is the one fact a device that was never meant to see it should not be
     * able to establish. `SessionFanout.attach` returns `null` for both cases
     * on purpose; this is that decision observed from the far end of a socket,
     * where it is the only thing a client can actually measure.
     */
    const harness = await serve({ sessions: new SessionFanout(ptysWithCopilot()) })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'attach', id: COPILOT })
    const hidden = await client.until((m) => m.t === 'error', 'the refusal for the copilot')
    client.send({ t: 'attach', id: 'sess-does-not-exist' })
    const absent = await client.until(
      (m) => m.t === 'error' && m.message.includes('sess-does-not-exist'),
      'the refusal for a made-up id',
    )

    expect(hidden.t === 'error' && hidden.code).toBe('unknown-session')
    expect(absent.t === 'error' && absent.code).toBe('unknown-session')
    // Same code, same sentence, one id apart.
    expect(hidden.t === 'error' && hidden.message.replace(COPILOT, 'X')).toBe(
      absent.t === 'error' ? absent.message.replace('sess-does-not-exist', 'X') : '',
    )
  })

  it('will not carry a keystroke to it, however the frame is constructed', async () => {
    /*
     * Two frames, both refused, and for two different reasons that both have to
     * hold. `server.ts` refuses `input` for a session this connection has no
     * handle for — which is already true, because the attach above failed — and
     * `SessionFanout.write` refuses it a second time whatever the transport
     * decided. The belt and the braces are deliberate: this class is injected
     * into more than one thing, and a rule that holds only because of the order
     * of checks in another file is a rule the next caller does not have.
     */
    const ptys = ptysWithCopilot()
    const harness = await serve({ sessions: new SessionFanout(ptys) })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'input', id: COPILOT, data: '/exit\r' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ code: 'unauthorized' })

    // The copilot is answering a question in its own window while this happens;
    // nothing this phone sent reached its keyboard.
    expect(ptys.written).toEqual([])
  })

  it('does not offer the copilot’s folder to the phone’s New Session picker', async () => {
    /*
     * The same hole one step to the left. A host builds the folders it offers
     * partly from the cwd of every running session, so an unfiltered list puts
     * `<userData>/copilot` in a phone's folder picker — where `create` would
     * refuse it, which is the right answer arriving in the wrong place: a
     * picker should not show a row whose only outcome is a refusal.
     */
    const ptys = ptysWithCopilot()
    const fanout = new SessionFanout({
      ...ptys,
      create: async () => ({ ok: false as const, code: 'unavailable' as const, message: 'no' }),
      folders: () => ['/work/api', '/data/copilot'],
    })
    const harness = await serve({ sessions: fanout })
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.folders).toEqual(['/work/api'])
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
    // The size travelled, so the first screen is drawn at the size it is read
    // at — and so did the device, which is what lets the session layer answer
    // "may *this* phone start here" rather than "may a phone".
    expect(sessions.requests).toEqual([
      { deviceId: 'device-1', cwd: undefined, cols: 100, rows: 30 },
    ])
  })

  it('carries the agent the client asked for all the way to the session layer', async () => {
    /*
     * The regression test for a bug that was invisible at every individual
     * layer. `machines/guest.ts` had been putting `provider` on the wire since
     * it was written; `parseClientMessage` did not list the field and dropped
     * it; this hand-off did not mention it either; and the spawn filled the gap
     * with the desktop's default. A request for `shell` came back as a `claude`
     * session on a real Windows PC, with nothing logged anywhere, because from
     * each layer's own point of view nothing had gone wrong.
     *
     * Driven over a real socket rather than by calling the handler, because the
     * drop happened *in* the parse-and-forward path and a test that constructed
     * a `CreateRequest` by hand would have passed against every version of this
     * code, including the broken one.
     */
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create', provider: 'shell' })
    await client.until((m) => m.t === 'created', 'the new session')
    expect(sessions.requests).toEqual([
      { deviceId: 'device-1', cwd: undefined, cols: undefined, rows: undefined, provider: 'shell' },
    ])
  })

  it('leaves the agent unset when the client named none, rather than choosing one', async () => {
    // The other half. A desktop's own default provider is a preference the
    // person set, and a server that invented `claude` here for every client that
    // said nothing would quietly take that preference away.
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create' })
    await client.until((m) => m.t === 'created', 'the new session')
    expect(sessions.requests[0].provider).toBeUndefined()
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

/**
 * The folders a device may use, on the wire.
 *
 * The rule itself lives in `session-create.ts` and is tested there. What this
 * server owns is narrower and was the missing half: the request has to carry
 * *which device* is asking, and the device has to be told what it may use so its
 * picker is not a guess. Before this, a phone assembled a folder list out of the
 * sessions it could see — a set that was never the same as the one the desktop
 * would accept, with nothing on either screen to explain the difference.
 */
describe('the folders a device is offered', () => {
  const TABLET = 'device-tablet.c2VjcmV0'

  /** Two paired devices, so "this one's list" is a claim with something to fail against. */
  const allowTwo: RemoteAuthenticator = {
    async authenticate(token) {
      if (token === CREDENTIAL) {
        return { ok: true, deviceId: 'device-1', deviceName: 'Test iPhone', credential: null }
      }
      if (token === TABLET) {
        return { ok: true, deviceId: 'device-tablet', deviceName: 'Test iPad', credential: null }
      }
      return { ok: false, message: 'This device is not allowed in.' }
    },
  }

  it('travels in the welcome, so the picker is drawn before anything is tapped', async () => {
    const sessions = creatingSessions()
    sessions.offers.set('device-1', ['/tmp/alpha', '/tmp/beta'])
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.folders).toEqual(['/tmp/alpha', '/tmp/beta'])
  })

  it('is this device’s list and not the other device’s', async () => {
    const sessions = creatingSessions()
    sessions.offers.set('device-1', ['/tmp/phone-only'])
    sessions.offers.set('device-tablet', ['/tmp/tablet-only'])
    const harness = await serve({ auth: allowTwo }, sessions)

    const phone = await connect(harness.port)
    phone.send(HELLO)
    const forPhone = await phone.until((m) => m.t === 'welcome', 'the phone’s welcome')

    const tablet = await connect(harness.port)
    tablet.send({ ...HELLO, token: TABLET })
    const forTablet = await tablet.until((m) => m.t === 'welcome', 'the tablet’s welcome')

    expect(forPhone.t === 'welcome' && forPhone.folders).toEqual(['/tmp/phone-only'])
    expect(forTablet.t === 'welcome' && forTablet.folders).toEqual(['/tmp/tablet-only'])
  })

  it('is absent entirely from a desktop that cannot start sessions', async () => {
    // The default fake has no `create` and therefore no `folders`. A key with an
    // empty array would read as "you may use nothing", which is a different
    // claim from "this host does not do that" — and the missing `create`
    // capability already says the second one.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && 'folders' in welcome).toBe(false)
  })

  it('is pushed again when it changes on the desktop, with no reconnect', async () => {
    // A person removing a folder in the settings panel expects the phone in
    // their other hand to stop offering it. The rule is already live without
    // this frame — `folders()` is read per request — so what this fixes is a
    // picker that would keep offering a tap whose only outcome is a refusal.
    const sessions = creatingSessions()
    sessions.offers.set('device-1', ['/tmp/alpha', '/tmp/beta'])
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    sessions.offers.set('device-1', ['/tmp/alpha'])
    expect(harness.endpoint.foldersChanged('device-1')).toBe(1)

    const pushed = await client.until((m) => m.t === 'folders', 'the new list')
    expect(pushed).toEqual({ t: 'folders', folders: ['/tmp/alpha'] })
  })

  it('pushes only to the device whose folders changed', async () => {
    const sessions = creatingSessions()
    sessions.offers.set('device-1', ['/tmp/phone-only'])
    sessions.offers.set('device-tablet', ['/tmp/tablet-only'])
    const harness = await serve({ auth: allowTwo }, sessions)

    const phone = await connect(harness.port)
    phone.send(HELLO)
    await phone.until((m) => m.t === 'welcome', 'the phone’s welcome')
    const tablet = await connect(harness.port)
    tablet.send({ ...HELLO, token: TABLET })
    await tablet.until((m) => m.t === 'welcome', 'the tablet’s welcome')

    expect(harness.endpoint.foldersChanged('device-tablet')).toBe(1)
    await tablet.until((m) => m.t === 'folders', 'the tablet’s new list')
    // Not a timing artefact: the tablet's push has already been received, and
    // this server writes in the order it is asked to.
    expect(phone.received.some((m) => m.t === 'folders')).toBe(false)
  })

  it('says nothing, and reports nothing, for a device that is not connected', async () => {
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    expect(harness.endpoint.foldersChanged('device-1')).toBe(0)
  })

  /**
   * A session started at the **Mac's own keyboard**, which is how nearly all of
   * them are started, and which nothing on this wire used to mention.
   *
   * A fresh `sessions` frame went out from four places and every one of them was
   * a device doing something: its own `create`, its own `close`, a folder change,
   * and the reply to `list`. So a phone's list and a paired laptop's sidebar were
   * a snapshot from the moment they connected. Measured before the fix: the host
   * went 2 → 5 → 7 and the reaching machine said 2 for sixty seconds, then moved
   * to 5 within a second of reconnecting. Asad, on the session picker: *"It's not
   * updated right away. Anyways, maybe we need to refresh."*
   */
  it('pushes the new list when a session is started at this machine’s own keyboard', async () => {
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.sessions.length).toBe(1)

    // Nobody asked over the wire: this is the desktop starting one by itself.
    sessions.add('made-here', '', '/tmp/allowed')
    expect(harness.endpoint.sessionsChanged()).toBe(1)

    const pushed = await client.until((m) => m.t === 'sessions', 'the new list')
    expect(pushed.t === 'sessions' && pushed.sessions.map((row) => row.id)).toContain('made-here')
  })

  it('tells nobody when nobody is connected, and does not throw', async () => {
    const harness = await serve({}, creatingSessions())
    expect(harness.endpoint.sessionsChanged()).toBe(0)
  })

  it('takes the asking device from the connection, never from the frame', async () => {
    // The one that would undo the whole feature: a client naming a device id
    // would be a client choosing whose folders it gets. `parseClientMessage`
    // rebuilds a `create` from the fields it knows, so the extra one below is
    // dropped before this server sees it — and this server passes the id the
    // handshake proved.
    const sessions = creatingSessions()
    const harness = await serve({}, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'create', deviceId: 'device-tablet', cwd: '/tmp/allowed' })
    await client.until((m) => m.t === 'created', 'the new session')
    expect(sessions.requests).toEqual([
      { deviceId: 'device-1', cwd: '/tmp/allowed', cols: undefined, rows: undefined },
    ])
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
    //
    /*
     * The wording names the machine rather than "the desktop app" since
     * 2026-08-24 — a headless server has no desktop app, and telling somebody
     * holding a phone to open one is a dead end. What this case actually guards
     * is unchanged and is asserted below: the sentence must not say *revoked*.
     *
     * The noun is **composed from the same call the product makes**, because it
     * is the running machine's own word: `Mac` here, `PC` on the Windows runner.
     * Spelling it out passed on a Mac and failed in CI on a machine where the
     * product was behaving perfectly — the sixth shape of Mac-only test this
     * repository has shipped.
     */
    expect(error.t === 'error' && error.message).toBe(
      `This device is not allowed in. Pair it again from the app on that ${machineNoun(currentPlatform())}.`,
    )
    expect(error.t === 'error' && error.message).not.toMatch(/revok/i)
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

  /*
   * The five-guess limit, which is the line the six-digit format stands on.
   *
   * `shared/short-code.ts` puts a guess at 5 × 10⁻⁶ against a million codes. The
   * five in that fraction is `pairingDesk.offers` and nothing else: `RemoteAuth`
   * also limits, but it keys on the *source*, and through the relay a source is
   * an authenticated device key that a guesser mints fresh for every attempt.
   * These tests are what fails if somebody removes the counter, moves it onto
   * the address, or lets a wrong answer skip the desk on its way to a refusal.
   */
  it('mints six digits, so the arithmetic being argued is the right one', () => {
    const { desk } = realAuth()
    const { token } = desk.create()
    expect(token).toMatch(/^[0-9]{6}$/)
    expect(token).toHaveLength(CODE_LENGTH)
    expect(isCode(token)).toBe(true)
  })

  it('kills the code after five wrong answers, however many places they came from', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const { token } = desk.create()

    // A different address and a different device name each time, which is what
    // a guesser trivially does. None of it buys a sixth attempt, because the
    // count is against the code rather than against whoever is asking.
    for (let attempt = 0; attempt < MAX_FAILED_ATTEMPTS; attempt++) {
      const guess = String((Number(token) + attempt + 1) % 1_000_000).padStart(CODE_LENGTH, '0')
      const refused = await authenticator.authenticate(guess, { name: `guesser-${attempt}`, platform: 'iOS' }, `100.86.107.${attempt}`)
      expect(refused.ok).toBe(false)
    }

    // The real code, from a source that has never failed at anything. Dead.
    const after = await authenticator.authenticate(token, phone, '100.86.107.200')
    expect(after.ok).toBe(false)
    expect(after.ok === false && after.credential).toBeUndefined()
    expect(auth.listDevices()).toEqual([])
    // And the desk itself agrees, so the rendezvous slot is down too.
    expect(desk.open()).toBe(false)
    expect(desk.offers(token)).toBe(false)
  })

  it('still has the code on the fifth attempt, so the limit is five and not four', async () => {
    const { auth, desk } = realAuth()
    const authenticator = authenticatorFor(auth, desk)
    const { token } = desk.create()

    for (let attempt = 0; attempt < MAX_FAILED_ATTEMPTS - 1; attempt++) {
      const guess = String((Number(token) + attempt + 1) % 1_000_000).padStart(CODE_LENGTH, '0')
      expect((await authenticator.authenticate(guess, phone, '100.86.107.7')).ok).toBe(false)
    }

    const paired = await authenticator.authenticate(token, phone, '100.86.107.7')
    expect(paired.ok === false && paired.credential).toMatch(/\./)
  })

  it('takes the rendezvous slot down with the code when the guesses run out', async () => {
    /*
     * A slot that outlives its code is a machine at the relay advertising an
     * address that will refuse whoever dials it — and, worse now that a code is
     * six digits, a slot an attacker can still confirm by name after the code
     * behind it is dead. Confirming a slot is how a sweep learns which of the
     * million codes was live, so a spent code has to take its slot with it.
     *
     * The beacon is stubbed because a real one dials the public relay from
     * whatever machine this test runs on.
     */
    const { auth } = realAuth()
    let stopped = false
    const desk = pairingDesk(auth, Date.now, () => ({
      stop: () => {
        stopped = true
      },
      connected: () => true,
      ready: async () => true,
    }))

    const shown = await desk.show({
      relayUrl: 'wss://relay.example',
      hostId: 'ABCDEFGHJKLMNPQRSTUVWXYZ23',
      publicKey: randomBytes(32).toString('base64'),
      name: 'This Mac',
      platform: 'darwin',
    })
    expect(shown.findable).toBe(true)
    expect(stopped).toBe(false)

    for (let attempt = 0; attempt < MAX_FAILED_ATTEMPTS; attempt++) {
      const guess = String((Number(shown.code.token) + attempt + 1) % 1_000_000).padStart(CODE_LENGTH, '0')
      expect(desk.offers(guess)).toBe(false)
    }

    expect(stopped, 'the rendezvous slot outlived the code that named it').toBe(true)
    expect(desk.open()).toBe(false)
    expect(desk.offers(shown.code.token)).toBe(false)
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
    expect(after.ok === false && after.message).toBe(
      `This device is not allowed in. Pair it again from the app on that ${machineNoun(currentPlatform())}.`,
    )
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
    // The `serve` stub is the point of this line, not decoration. It was the one
    // `createRemoteServer` call in this file without one, so `stop()` reached the
    // real `serveOff`, which asks the OS where the `tailscale` binary is — a
    // spawn of `which`, or `where.exe`, bounded at five seconds. On this Mac that
    // is a few milliseconds and invisible. On a loaded Windows runner with no
    // Tailscale installed it consumed the whole budget and the test failed at
    // 5,007 ms against a 5,000 ms limit, with nothing wrong with the code under
    // test. What is being asserted here is that stopping something that never
    // started does not throw; finding Tailscale is incidental to that, and it was
    // the only part that could be slow.
    const server = createRemoteServer({
      ...neverListens,
      readTailnet: async () => ready(),
      serve: { on: async () => ({ ok: false, message: 'not asked for' }), off: async () => {} },
    })
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

/* ----------------------------------------------------- capability `devserver` */

/**
 * A dev-server module the socket tests drive by hand.
 *
 * Deliberately *not* the real one. What is under test here is the server's half
 * — the capability negotiation, the folder gate, which folder string travels
 * onward, and who hears a pushed `dev.state` — and every one of those is a
 * question about this file. Whether "ready" means a port accepted a connection
 * is `dev-server.test.ts`'s question, and answering it twice with two fakes is
 * how two files end up disagreeing about it.
 */
function fakeDevServers(): DevServers & {
  asked: string[]
  started: string[]
  push(state: DevServerState): void
} {
  const listeners = new Set<(state: DevServerState) => void>()
  const asked: string[] = []
  const started: string[] = []
  return {
    asked,
    started,
    status(folder: string): DevServerState {
      asked.push(folder)
      return { folder, status: 'idle', script: 'dev', command: 'pnpm run dev' }
    },
    async start(folder: string, open): Promise<DevServerState> {
      started.push(folder)
      const opened = await open(folder)
      return opened.ok
        ? { folder, status: 'starting', script: 'dev', command: 'pnpm run dev', sessionId: opened.sessionId }
        : { folder, status: 'failed', script: 'dev', command: 'pnpm run dev', message: opened.message }
    },
    onChange(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    noteExit() {},
    dispose() {},
    push(state: DevServerState) {
      for (const listener of listeners) listener(state)
    },
  }
}

describe('starting a project’s dev server from a phone', () => {
  it('is not advertised by a host that has no dev-server module', async () => {
    const harness = await serve({}, creatingSessions())
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')

    expect(welcome).toMatchObject({ capabilities: expect.not.arrayContaining(['devserver']) })
  })

  it('is not advertised by a host that cannot start a session', async () => {
    // Starting a dev server *is* starting a session — there is no second
    // spawning path on purpose — so a host with no `create` must not offer it.
    const harness = await serve({ devServers: fakeDevServers() }, fakeSessions())
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')

    expect(welcome).toMatchObject({ capabilities: expect.not.arrayContaining(['devserver']) })
  })

  it('is advertised when the module, create and a folder list are all there', async () => {
    const harness = await serve({ devServers: fakeDevServers() }, creatingSessions())
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')

    expect(welcome).toMatchObject({ capabilities: expect.arrayContaining(['devserver']) })
  })

  it('cannot be asked about before the device has said who it is', async () => {
    const harness = await serve({ devServers: fakeDevServers() }, creatingSessions())
    const client = await connect(harness.port)
    client.send({ t: 'dev.status', folder: '/tmp/allowed' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({ t: 'error', code: 'unauthenticated', message: 'Say hello first.' })
    await expect(client.closed).resolves.toBe(CLOSE.policyViolation)
  })

  it('answers dev.status for a folder this device was granted', async () => {
    const dev = fakeDevServers()
    const harness = await serve({ devServers: dev }, creatingSessions(['/tmp/allowed']))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.status', folder: '/tmp/allowed' })

    const state = await client.until((m) => m.t === 'dev.state', 'the state')
    expect(state).toEqual({
      t: 'dev.state',
      state: { folder: '/tmp/allowed', status: 'idle', script: 'dev', command: 'pnpm run dev' },
    })
  })

  it('refuses a folder this device was not granted, without reading anything', async () => {
    // The load-bearing one. `dev.status`'s answer is derived from a
    // `package.json`, so a desktop that read first and authorised second would
    // let a paired phone ask whether any path on the machine is a Node project
    // and what its scripts are called. `dev.asked` staying empty is the
    // assertion — the refusal alone would not prove the disk was untouched.
    const dev = fakeDevServers()
    const harness = await serve({ devServers: dev }, creatingSessions(['/tmp/allowed']))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.status', folder: '/Users/asad/private' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
    // And the path it named is not quoted back at it.
    expect(JSON.stringify(error)).not.toContain('private')
    expect(dev.asked).toEqual([])
    expect(dev.started).toEqual([])
  })

  it('refuses a folder granted to a *different* device', async () => {
    const dev = fakeDevServers()
    const sessions = creatingSessions(['/tmp/shared'])
    // This device has its own list, and the shared folder is not on it.
    sessions.offers.set('device-1', ['/tmp/mine'])
    const harness = await serve({ devServers: dev }, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.start', folder: '/tmp/shared' })

    await client.until((m) => m.t === 'error', 'the refusal')
    expect(dev.started).toEqual([])
    expect(sessions.requests).toEqual([])
  })

  it('starts it through create, as a shell, in the desktop’s own spelling of the folder', async () => {
    const dev = fakeDevServers()
    const sessions = creatingSessions(['/tmp/allowed'])
    const harness = await serve({ devServers: dev }, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    // The client's spelling has a trailing separator. The same directory, and
    // not the string that should travel onward.
    client.send({ t: 'dev.start', folder: '/tmp/allowed/' })

    const state = await client.until((m) => m.t === 'dev.state', 'the state')
    expect(state).toMatchObject({ state: { status: 'starting', sessionId: 'made-1' } })
    // Through `create`, which is the layer that checks the grant a second time
    // and confines the session. There is no other way this feature spawns.
    expect(sessions.requests).toEqual([
      { deviceId: 'device-1', cwd: '/tmp/allowed', provider: 'shell', cols: undefined, rows: undefined },
    ])
    expect(dev.started).toEqual(['/tmp/allowed'])
  })

  it('passes the session layer’s refusal through as the failure', async () => {
    const dev = fakeDevServers()
    const sessions = creatingSessions(['/tmp/allowed'])
    sessions.refuseWith = {
      ok: false,
      code: 'unavailable',
      message: 'This Mac could not keep a session inside that folder, so it did not start one.',
    }
    const harness = await serve({ devServers: dev }, sessions)
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.start', folder: '/tmp/allowed' })

    const state = await client.until((m) => m.t === 'dev.state', 'the state')
    expect(state).toMatchObject({
      state: {
        status: 'failed',
        message: 'This Mac could not keep a session inside that folder, so it did not start one.',
      },
    })
  })

  it('pushes later changes to the phone that asked, without being polled', async () => {
    const dev = fakeDevServers()
    const harness = await serve({ devServers: dev }, creatingSessions(['/tmp/allowed']))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.status', folder: '/tmp/allowed' })
    await client.until((m) => m.t === 'dev.state', 'the first state')

    dev.push({
      folder: '/tmp/allowed',
      status: 'ready',
      script: 'dev',
      command: 'pnpm run dev',
      sessionId: 'made-1',
      port: 5173,
      url: 'http://localhost:5173',
    })

    const ready = await client.until(
      (m) => m.t === 'dev.state' && m.state.status === 'ready',
      'the ready push',
    )
    expect(ready).toMatchObject({ state: { port: 5173, url: 'http://localhost:5173' } })
  })

  it('does not push a folder the phone never asked about', async () => {
    const dev = fakeDevServers()
    const harness = await serve({ devServers: dev }, creatingSessions(['/tmp/allowed', '/tmp/other']))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.status', folder: '/tmp/allowed' })
    await client.until((m) => m.t === 'dev.state', 'the first state')

    dev.push({ folder: '/tmp/other', status: 'ready', port: 3000, url: 'http://localhost:3000' })
    // Round-trip something the server answers immediately, so "nothing arrived"
    // is a measurement rather than a race with the event loop.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    expect(client.received.filter((m) => m.t === 'dev.state').length).toBe(1)
  })

  it('refuses the verb outright on a host that never advertised it', async () => {
    const harness = await serve({}, creatingSessions(['/tmp/allowed']))
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'dev.start', folder: '/tmp/allowed' })

    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toEqual({
      t: 'error',
      code: 'unauthorized',
      message: 'Dev servers cannot be started from a phone here.',
    })
  })
})

/* ---------------------------------------------------------------- copilot -- */

/**
 * The copilot surface, over a real socket, from hello to refusal.
 *
 * The unit tests beside this one prove the rules — `copilot-enforcement.test.ts`
 * for the tier check at the point a tool is dispatched, `copilot-runs.test.ts`
 * for the run manager, `copilot-frames.test.ts` for the property that a device
 * cannot name a tool. What none of them can prove is that the frames actually
 * reach any of it, which is the failure this repository has paid for twice: a
 * feature that typechecks, passes its unit tests and is wired to nothing.
 *
 * So everything below goes down a loopback WebSocket, through the framing,
 * through the hello, through `copilotFor`, and into a real {@link CopilotRuns}
 * over a real {@link CopilotAccess}. The only fakes are the pty and the Claude
 * CLI, which cannot be spawned in a test.
 *
 * ## What changed on 2026-08-19, and why every fixture here got shorter
 *
 * Copilot access has been three things. A per-device grant riding this same
 * channel: say hello, and if a box had been ticked on the desktop the Copilot
 * tab worked. Then a **separate connection** with its own six-digit code and its
 * own credential, because a tick box was not an authorisation — which is why
 * every test in this section used to perform two ceremonies, pairing and then
 * connecting.
 *
 * It is now neither. A device's **kind**, chosen by a person at this keyboard
 * when they approved it, is the whole answer: one of his own devices reaches the
 * copilot and a guest never does. `copilot-access.ts` carries that argument and
 * preserves the one it superseded. So the second ceremony is gone from every
 * fixture, `copilot.hello` carries nothing, and there is no `copilot.connect` to
 * send.
 *
 * What did **not** get shorter is the set of things that must be refused, and
 * that is where the value of this file now sits: a guest is refused, a socket
 * that has not said hello is refused, and neither of them can measure anything
 * about the copilot by asking.
 */

function copilotHost(owners: readonly string[] = ['device-1']): {
  copilot: CopilotRuns
  links: CopilotAccess
  /**
   * The devices approved as his, which decides both halves of the rule.
   *
   * A test takes one out of here to reproduce a revocation, and starts with an
   * empty set to be a guest. `device-1` is the default because it is the one
   * device this file's authenticator knows a credential for.
   */
  mine: Set<string>
  /**
   * The eligibility rule to hand `serve()`, read off the same set.
   *
   * `index.ts` wires `copilotEligible` and `CopilotAccess.isMine` to the same
   * `kinds.kindOf`, and a harness that let them disagree could produce states
   * the product cannot — an "eligible guest" whose welcome advertises a copilot
   * it will then be refused. Passing this keeps the two answers one answer.
   */
  eligible: (deviceId: string) => boolean
  consent: ConsentBroker
  dir: string
  spawned: number
  stopped: string[]
  said: Array<{ id: string; text: string }>
  deskAttached: boolean
} {
  const dir = mkdtempSync(join(tmpdir(), 'deck-copilot-wire-'))
  roots.push(dir)
  const mine = new Set<string>(owners)
  const links = new CopilotAccess({ isMine: (deviceId) => mine.has(deviceId) })
  const alive = new Set<string>()
  const box = {
    spawned: 0,
    stopped: [] as string[],
    said: [] as Array<{ id: string; text: string }>,
    /**
     * Is a window attached as the desktop approver?
     *
     * Default false, so a test that says nothing about the desk gets the state a
     * headless host is in — and the honest consequence of it, which is that a
     * question nobody can be asked refuses itself at once rather than waiting
     * two minutes for a dialog that was never drawn.
     *
     * The tests about the *ownership* rule flip it on, because what they are
     * proving is that a device cannot answer somebody else's question — and with
     * no approver anywhere the question would resolve `no-approver` before the
     * device could try, which is a green test for the wrong reason.
     */
    deskAttached: false,
  }
  /*
   * A real broker, wired to the run manager exactly as `deck-control/index.ts`
   * wires it: `ask` fans the question out to both surfaces and `settled`
   * withdraws it from both. Fake it and the answering path — first answer wins,
   * the ownership rule, the withdrawal frame — would be tested against a mock of
   * the thing that holds all three.
   *
   * `delivered` is an OR, exactly as it is in the real wiring: one surface is
   * enough for the question to be live, and requiring both would refuse every
   * question raised while a phone happened to be in a lift.
   */
  let copilot: CopilotRuns
  const consent = new ConsentBroker({
    ask: (request) => {
      const remote = copilot.ask(request)
      return box.deskAttached || remote
    },
    settled: (id, outcome) => copilot.settled(id, outcome),
    timeoutMs: 5_000,
  })
  copilot = new CopilotRuns({
    links,
    consent: () => consent,
    callers: { set: () => {}, delete: () => true },
    endpoint: () => ({ url: 'http://127.0.0.1:5599/mcp' }),
    copilotRoot: () => join(dir, 'copilot'),
    spawn: async () => {
      box.spawned += 1
      const id = `run-${box.spawned}`
      alive.add(id)
      return id
    },
    isAlive: (id) => alive.has(id),
    stop: (id) => {
      box.stopped.push(id)
      alive.delete(id)
    },
    say: (id, text) => box.said.push({ id, text }),
    interrupt: () => {},
    desk: () => ({ status: 'running', profile: 'Personal', signedIn: true, available: true, reason: null }),
    cost: () => ({ tools: 11, turnTokens: 900 }),
    sessions: () => [],
    log: () => ({ rows: [], more: false }),
    chat: () => () => {},
  })
  return Object.assign(box, {
    copilot,
    links,
    mine,
    eligible: (deviceId: string) => mine.has(deviceId),
    consent,
    dir,
  })
}

/**
 * Open the copilot stream on this socket, which is the whole ceremony.
 *
 * One bare frame. This used to mint a six-digit code at the desktop, send it,
 * wait for a `copilot.linked` carrying a credential and hand that credential
 * back for the caller to replay — the second act of authorisation, performed
 * over the wire because that is where it happened.
 *
 * There is nothing left to prove here. The socket is already authenticated as
 * this device by `RemoteAuth`, and whether this device reaches the copilot was
 * decided when somebody at this keyboard approved it as one of their own. What
 * survives is that the stream still has to be **asked for on every socket** —
 * a session channel does not carry the copilot by existing — which is why this
 * helper exists at all rather than being deleted along with the ceremony.
 */
async function openCopilot(client: Client): Promise<void> {
  client.send({ t: 'copilot.hello' })
  await client.until(
    (m) => m.t === 'copilot.grant' && m.link.open === true,
    'the copilot stream opening',
  )
}

describe('the copilot capability is advertised only when it exists', () => {
  /**
   * The defect this pins, in the words of the filter's own comment: *the
   * advertisement cannot outlive the thing it advertises.*
   *
   * `advertised` is built by filtering `CAPABILITIES`, and a name with no case
   * in that filter falls through to `return true`. A desktop built from such a
   * tree tells every device it speaks `copilot` while implementing none of it,
   * so a client gating its Copilot tab on the capability — which is exactly what
   * the capability is for — draws a tab that answers `unauthorized` to
   * everything. The two tests here are the pair: present when the layer is
   * injected, absent when it is not.
   */
  it('leaves copilot out of the welcome on a host with no copilot layer', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.copilot)
    // And the per-device link is absent too, which is a different fact from
    // "not open on this socket" and is what stops a client drawing a Copilot tab
    // it cannot use: there is no copilot here at all.
    expect(welcome.t === 'welcome' && welcome.copilot).toBeUndefined()
  })

  /**
   * **`linked` is true and `open` is false**, and the pair is the shape of the
   * whole design in one assertion.
   *
   * `linked` says *this device reaches the copilot*, and for one of his own
   * devices it is true on the first welcome it ever receives, with nothing
   * having been minted, typed or redeemed. That is the 2026-08-19 change: this
   * used to be `false` here and stayed false until a person read a six-digit
   * code out loud, because copilot access was a separate connection. It is now
   * the kind decided at pairing, so there is no state in which a device is
   * approved as his and told *ask again*.
   *
   * `open` is false on **every** welcome, always, and that half is unchanged. A
   * session channel does not carry the copilot by existing; the client sends
   * `copilot.hello` to open the stream, on every socket, after every reconnect.
   * A desktop that reported `open: true` here would have made the stream a
   * property of having said hello.
   */
  it('advertises it, and tells one of his own devices it reaches it', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.copilot)
    expect(welcome.t === 'welcome' && welcome.copilot).toEqual({
      linked: true,
      open: false,
      grant: { read: true, act: true, alter: true },
    })
  })
})

describe('a socket that has not opened the copilot has no reach', () => {
  /**
   * **The stream is asked for per socket, and until it is, nothing works.**
   *
   * This client is fully paired and approved and is one of his own devices — the
   * welcome carried its sessions *and* its copilot link, and it could attach to
   * a terminal right now. It has simply not sent `copilot.hello` on this socket.
   * Every `copilot.*` verb it can construct is refused, *including the read-tier
   * ones*, so there is no frame it can send that measures anything about the
   * copilot at all: not whether one is running, not how many confirmations are
   * waiting, not whether it has a grant that would have been enough.
   *
   * This is what is left of a describe block that used to prove the headline
   * property of the separate copilot connection — *a device paired for sessions
   * has no copilot reach until it redeems a code*. That property moved: the
   * question is now the device's **kind**, and it is proved further down, in
   * *"the copilot is never shared with a guest"*. What remains here is the
   * per-socket half, which did not move and is still worth the whole sweep: it
   * is what stops a reconnecting client inheriting a stream it never asked for.
   */
  it('refuses every copilot verb before the stream is opened', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    const verbs = [
      { t: 'copilot.attach' },
      { t: 'copilot.state' },
      { t: 'copilot.sessions' },
      { t: 'copilot.pending' },
      { t: 'copilot.log' },
      { t: 'copilot.start' },
      { t: 'copilot.say', text: 'anything' },
      { t: 'copilot.answer', id: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5', approved: true },
    ]
    for (const frame of verbs) client.send(frame)
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    const errors = client.received.filter((m) => m.t === 'error')
    expect(errors.length).toBe(verbs.length)
    for (const error of errors) {
      expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
      // The sentence says *this device is not connected*, not *you need more
      // access*. Two different remedies, and the second would send somebody
      // looking for a checkbox that is not the obstacle.
      expect(error.t === 'error' && error.message).toMatch(/not connected to the copilot/)
    }
    // Nothing about the copilot leaked into any of it.
    expect(client.received.some((m) => m.t.startsWith('copilot.'))).toBe(false)
    expect(host.spawned).toBe(0)
  })

  /**
   * And its terminals still work, which is the other half of the same rule.
   *
   * A device with no copilot stream open is not a device in trouble — and nor is
   * a guest, which is the case this now covers with the host given no owners at
   * all. Both are ordinary paired phones and the session surface has to be
   * exactly as it was for both. The copilot going away must never look like the
   * pairing going away, because those have different remedies and a person who
   * confuses them re-pairs a device that was working.
   */
  it('leaves the session surface untouched for a guest with no copilot', async () => {
    const host = copilotHost([])
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'list' })
    const sessions = await client.until((m) => m.t === 'sessions', 'the session list')
    expect(sessions.t === 'sessions' && sessions.sessions.length).toBeGreaterThan(0)
  })
})

describe('opening the copilot stream', () => {
  /**
   * **A bare `copilot.hello` opens it, for one of his own devices.**
   *
   * The frame carries nothing. There is no code to mint, no credential to hand
   * back and no `copilot.connect` above it — all three were deleted on
   * 2026-08-19, when a device's kind became the whole answer. What the desktop
   * answers with is the grant, in full, including `alter`, on a socket that has
   * done nothing but say who it is.
   *
   * That is the assertion somebody would have to change to reintroduce a second
   * factor, and the reason it is worth pinning at this layer rather than at the
   * access object's is that the wire is where a client meets it. A phone whose
   * Copilot tab is drawn from `copilot.grant` needs this exact frame to arrive
   * with `open: true` and three tiers, or the tab renders a state nobody
   * designed.
   */
  it('opens the stream on a bare hello, with no credential anywhere', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'copilot.hello' })
    const grant = await client.until((m) => m.t === 'copilot.grant', 'the open grant')
    expect(grant).toEqual({
      t: 'copilot.grant',
      link: { linked: true, open: true, grant: { read: true, act: true, alter: true } },
    })
    // Nothing came back that a client would have to store. The whole class of
    // bug that goes with a long-lived secret on a phone — losing it, syncing it,
    // replaying it after a revocation — has no material to work with.
    expect(client.received.some((m) => m.t.startsWith('copilot.linked'))).toBe(false)

    client.send({ t: 'copilot.state' })
    const state = await client.until((m) => m.t === 'copilot.state', 'the state')
    expect(state).toMatchObject({ state: { desk: 'running', tools: 11 } })
  })

  /**
   * An older client still sending a credential is **opened**, not refused.
   *
   * This is the compatibility rule `protocol.ts` argues for at the parse site,
   * checked where it actually costs something: a phone built against the
   * previous protocol has a `credential` field in its hello and no way to stop
   * sending one, because the app on it was shipped. Refusing that frame would
   * break every already-installed client the moment a desktop updated, with a
   * sentence about a credential nobody can produce any more.
   *
   * The field is ignored rather than validated, which is the only honest
   * reading: it proves nothing now, so treating it as either a pass or a failure
   * would be inventing a meaning for a value that no longer has one.
   */
  it('ignores a credential field from a client built against the old protocol', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'copilot.hello', credential: 'bm90LWEtcmVhbC1jcmVkZW50aWFs' })
    const grant = await client.until((m) => m.t === 'copilot.grant', 'the open grant')
    expect(grant).toMatchObject({ link: { linked: true, open: true } })
    expect(client.received.some((m) => m.t === 'error')).toBe(false)
  })

  /**
   * A reconnect has to send `copilot.hello`, and until it does it has nothing.
   *
   * The device's access survives the socket; the *stream* does not. This is the
   * assertion that would go red if somebody "helpfully" made the copilot follow
   * from having said hello — which is a more tempting shortcut now that there is
   * no credential to present, and is exactly what would let a second socket
   * inherit a live agent on the strength of the pairing credential alone.
   */
  it('gives a reconnected socket nothing until it says hello again', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })

    const first = await connect(harness.port)
    first.send(HELLO)
    await first.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(first)

    const second = await connect(harness.port)
    second.send(HELLO)
    await second.until((m) => m.t === 'welcome', 'the second welcome')

    second.send({ t: 'copilot.state' })
    const error = await second.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })

    await openCopilot(second)
    second.send({ t: 'copilot.state' })
    await second.until((m) => m.t === 'copilot.state', 'the state after reopening')
  })

  /**
   * `copilot.bye` ends the stream on this socket and takes nothing else away.
   *
   * What a person closing the Copilot tab on a shared machine wants is that
   * socket's access gone. It used to be worth saying that their *credential*
   * survived it; there is none to survive now, and what replaced it is stronger
   * — the device is still one of his, so saying hello again opens the stream
   * again with nothing in between.
   */
  it('closes the stream on bye and reopens on another bare hello', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.bye' })
    await client.until(
      (m) => m.t === 'copilot.grant' && m.link.open === false,
      'the closed grant',
    )

    client.send({ t: 'copilot.state' })
    const error = await client.until((m) => m.t === 'error', 'the refusal after bye')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })

    client.send({ t: 'copilot.hello' })
    await client.until((m) => m.t === 'copilot.grant' && m.link.open === true, 'the reopened grant')
  })
})

/**
 * The same copilot, answering a **narrowed** grant.
 *
 * A proxy rather than a second `CopilotRuns`, because everything except the one
 * answer has to stay real: the run manager, the broker, the fanout and the
 * refusal sentences are what these tests are driving, and a hand-built stub of
 * fifteen methods would be testing a mock of the thing under test.
 *
 * It exists because the product can no longer produce a partial remote grant.
 * A device is one of his and reaches everything, or it is a guest and reaches
 * nothing — `copilot-access.ts` argues why the tick box between the two was
 * proving a fact that pairing had already proved, and there is now no screen,
 * file or frame that yields anything in between.
 *
 * The check it feeds is untouched and runs on every `copilot.*` message:
 * `copilotFor` asks `copilotFrameAllowed(copilot.granted(deviceId), verb)`
 * before a handler is reached. Deleting the tests below would leave that gate —
 * the one standing between a `read` grant and `copilot.answer` — with no
 * coverage at the transport at all, against the day a narrower caller arrives
 * from somewhere else. So the input is faked and the gate is real, which is the
 * right way round.
 */
function narrowedTo(copilot: CopilotRemote, grant: CopilotGrantWire): CopilotRemote {
  return new Proxy(copilot, {
    get(target, property, receiver) {
      if (property === 'granted') return () => grant
      const value = Reflect.get(target, property, receiver) as unknown
      // Bound to the target rather than the proxy, so a method reaching for the
      // run manager's own private state does not go back through this handler.
      return typeof value === 'function' ? value.bind(target) : value
    },
  })
}

describe('an open stream can watch, and the tier gate is still the gate', () => {
  /**
   * Attaching answers with the state, and the grant in it is all three tiers.
   *
   * This assertion used to read `{ read: true, act: false, alter: false }`,
   * because the fixture above it had connected the copilot with a code that
   * carried exactly that. There is no such code and no such narrowing now: this
   * is one of his own devices, so what comes back is what he was told he was
   * handing over when he approved it.
   */
  it('attaches and is answered with the state', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.attach' })
    const state = await client.until((m) => m.t === 'copilot.state', 'the state')
    expect(state).toMatchObject({
      t: 'copilot.state',
      state: { desk: 'running', run: null, tools: 11, grant: { read: true, act: true, alter: true } },
    })
  })

  it('answers every read verb and starts nothing', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.state' })
    await client.until((m) => m.t === 'copilot.state', 'the state')
    client.send({ t: 'copilot.sessions' })
    await client.until((m) => m.t === 'copilot.sessions', 'the sessions')
    client.send({ t: 'copilot.pending' })
    await client.until((m) => m.t === 'copilot.pending', 'the pending set')
    client.send({ t: 'copilot.log', limit: 20 })
    const log = await client.until((m) => m.t === 'copilot.log', 'the log')

    expect(log).toEqual({ t: 'copilot.log', rows: [], more: false })
    // Watching costs this machine one callback and spends no money. Worth
    // asserting even now that watching and acting arrive together, because it is
    // what makes a phone left open on a screen free rather than a slow leak.
    expect(host.spawned).toBe(0)
  })

  /**
   * The frames a caller should not be allowed to send, sent anyway.
   *
   * `copilot.say` is `act` because talking to the copilot *is* `sessions.send`
   * by the time it lands — it spends money and causes tool calls. `copilot.answer`
   * is `alter` because a caller that may not perform alter-tier work has no
   * business deciding whether alter-tier work happens; without that line, `read`
   * would be a way to authorise everything `act` refuses.
   *
   * The grant comes from {@link narrowedTo} rather than from the access object,
   * and that helper says why: the gate is real and runs on every message, and
   * nothing the product can do produces this input any more.
   */
  it('refuses say, start, cancel, stop and answer for a read-only grant', async () => {
    const host = copilotHost()
    const watching = narrowedTo(host.copilot, { read: true, act: false, alter: false })
    const harness = await serve({ copilot: watching, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    const acting = [
      { t: 'copilot.say', text: 'stop everything' },
      { t: 'copilot.start' },
      { t: 'copilot.cancel' },
      { t: 'copilot.stop' },
      { t: 'copilot.answer', id: '9f1c2ae0-8f1d-4b1e-9a2f-77d7c0a1b3e5', approved: true },
    ]
    for (const frame of acting) client.send(frame)
    // Waited for by count rather than one at a time, because `until` resolves on
    // anything already received and would otherwise hand back the first
    // refusal five times over — a loop that looks like it checked five frames
    // and checked one.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    const errors = client.received.filter((m) => m.t === 'error')
    expect(errors.length).toBe(acting.length)
    for (const error of errors) {
      expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
      // The sentence names the remedy rather than the tier. "You need `act`" is
      // a word from this codebase's permission model that means nothing on a
      // phone; what a person can act on is that the answer lives on their
      // desktop.
      expect(error.t === 'error' && error.message).toMatch(/Settings/)
    }

    expect(host.spawned).toBe(0)
    expect(host.said).toEqual([])
    expect(host.stopped).toEqual([])
  })

  /**
   * **Revoking the device lands on the very next frame**, with no reconnect.
   *
   * Access is read per message — `copilot.granted(deviceId)` and
   * `copilot.linked(deviceId)` inside `copilotFor` — never captured at hello.
   * This is the same property `folders()` has for `create`, and it is what makes
   * the `copilot.grant` push honest rather than load-bearing: the rule is
   * already live without it.
   *
   * The *event* is the part that changed. There is no "disconnect the copilot"
   * any more, because there is no separate connection to disconnect; revoking
   * the device is the one remedy, and it drops the kind that both halves of the
   * rule are read from. Both are driven here — the set behind `isMine` and the
   * set behind `copilotEligible` are the same set, exactly as `index.ts` wires
   * them to the same `kindOf` — because a harness where they could disagree
   * could pass while the shipped pair did not.
   *
   * Note what is *not* asserted: that anything was pushed. The refusal has to
   * arrive on the next frame the device sends regardless, which is the property
   * that survives a phone that was in a tunnel while the push went out.
   */
  it('refuses on the very next frame after the device is revoked', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.start' })
    await client.until((m) => m.t === 'copilot.state', 'the started state')
    expect(host.spawned).toBe(1)

    host.mine.delete('device-1')

    client.send({ t: 'copilot.say', text: 'anything at all' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unauthorized' })
    expect(host.said).toEqual([])

    // And the terminals are untouched by *this* layer. Revoking a device for
    // real takes the pairing with it one door up, in `remote:device:revoke`;
    // what is being pinned here is that the copilot refusing is not by itself a
    // reason for the session surface to change under somebody's hands.
    client.send({ t: 'list' })
    const sessions = await client.until((m) => m.t === 'sessions', 'the session list')
    expect(sessions.t === 'sessions' && sessions.sessions.length).toBeGreaterThan(0)
  })
})

describe('an open stream gets its own run', () => {
  it('starts one run, answers a second start with it, and says into it', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the first state')

    client.send({ t: 'copilot.start' })
    await client.until(
      (m) => m.t === 'copilot.state' && m.state.run !== null,
      'the state naming the run',
    )
    client.send({ t: 'copilot.start' })
    client.send({ t: 'copilot.say', text: 'which session is stuck?' })
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')

    // One process for two starts. A device that reconnects and taps Start —
    // which is what a person does when a screen looks empty — must not spawn a
    // second Claude CLI in the same folder.
    expect(host.spawned).toBe(1)
    expect(host.said).toEqual([{ id: 'run-1', text: 'which session is stuck?' }])
  })

  it('stops its own run and nothing else', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)

    client.send({ t: 'copilot.start' })
    await client.until((m) => m.t === 'copilot.state' && m.state.run !== null, 'the run')
    client.send({ t: 'copilot.stop' })
    await client.until((m) => m.t === 'copilot.state' && m.state.run === null, 'the stopped state')

    expect(host.stopped).toEqual(['run-1'])
  })
})

/* ------------------------------------------------ answering a confirmation */

/**
 * A question raised by this device's own run, put to it, and answered on it.
 *
 * The rule the design flags as non-obvious and which these tests exist for:
 * **a question may only be answered by the surface that owns the run that raised
 * it, or by the desktop.** Otherwise one device approves another device's
 * action, which is a permission model with a shared password.
 */
function raise(host: ReturnType<typeof copilotHost>, origin: string): Promise<ConsentOutcome> {
  return host.consent.request({
    tool: 'settings.write',
    tier: 'alter',
    summary: 'Change the density to compact',
    args: { scope: 'settings', patch: { 'appearance.density': 'compact' } },
    origin,
  })
}

describe('a confirmation answered from a device', () => {
  it('arrives with its arguments, is answered, and the answer names the device', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)
    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the state')

    const answer = raise(host, 'device:device-1')

    const ask = await client.until((m) => m.t === 'copilot.ask', 'the question')
    expect(ask).toMatchObject({
      t: 'copilot.ask',
      question: {
        tool: 'settings.write',
        tier: 'alter',
        summary: 'Change the density to compact',
        origin: 'device:device-1',
      },
    })
    // The arguments cross, verbatim. A prompt without them is a shape rather
    // than a decision, and a gate that is always answered yes is worse than no
    // gate because it looks like protection.
    expect(ask.t === 'copilot.ask' && ask.question.args).toEqual({
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    const id = ask.t === 'copilot.ask' ? ask.question.id : ''

    // And the same question is in the watch list, flagged as this device's.
    const pending = await client.until((m) => m.t === 'copilot.pending', 'the pending list')
    expect(pending.t === 'copilot.pending' && pending.questions).toEqual([
      expect.objectContaining({ id, mine: true }),
    ])

    client.send({ t: 'copilot.answer', id, approved: true })
    const outcome = await answer
    expect(outcome.granted).toBe(true)
    // `by` is what the action log records, and it is what makes "allowed on a
    // connected device" a different row from "allowed by the person".
    expect(outcome.by).toBe('device:device-1')

    const settled = await client.until((m) => m.t === 'copilot.settled', 'the withdrawal')
    expect(settled).toEqual({
      t: 'copilot.settled',
      settled: { id, granted: true, by: 'device:device-1', reason: null },
    })
  })

  it('refuses just as easily, and the refusal is what the run is told', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)
    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the state')

    const answer = raise(host, 'device:device-1')
    const ask = await client.until((m) => m.t === 'copilot.ask', 'the question')
    const id = ask.t === 'copilot.ask' ? ask.question.id : ''

    client.send({ t: 'copilot.answer', id, approved: false })
    const outcome = await answer
    expect(outcome.granted).toBe(false)
    expect(outcome.granted === false && outcome.reason).toBe('declined')
  })

  /**
   * **The frame a device should not be allowed to send.**
   *
   * `device-1` is one of his own devices with the stream open, so it holds
   * `alter`, the tier check passes and the transport hands the frame on. What
   * stops it is the ownership rule inside the broker: the question belongs to
   * another device's run.
   *
   * That rule got more load-bearing when the separate copilot connection went
   * away rather than less. Two devices reaching the copilot used to be two
   * deliberate redemptions; they are now simply two devices he owns, which is
   * the ordinary case. Without this, approving a second phone would make either
   * of them able to approve the other's actions.
   *
   * The refusal is deliberately the same one a settled question gets, so a
   * device probing for other devices' question ids learns nothing from the reply.
   */
  it('refuses to answer a question raised by another device', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)
    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the state')

    // Somebody is at the desk, so the question stays live long enough for this
    // device to try to answer it. Without that it would refuse itself as
    // `no-approver` and this test would pass for the wrong reason.
    host.deskAttached = true
    const answer = raise(host, 'device:someone-else')

    // It is visible — that is the watching half, and it is deliberate: a device
    // can say "go and look" about a question it may not answer.
    const pending = await client.until(
      (m) => m.t === 'copilot.pending' && m.questions.length > 0,
      'the pending list',
    )
    const row = pending.t === 'copilot.pending' ? pending.questions[0] : null
    expect(row?.mine).toBe(false)
    // And it never arrived as a question, so its arguments never crossed.
    expect(client.received.some((m) => m.t === 'copilot.ask')).toBe(false)

    client.send({ t: 'copilot.answer', id: row?.id ?? '', approved: true })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error).toMatchObject({ t: 'error', code: 'unavailable' })

    // Still waiting. The other device's turn is not resolved by this one's tap.
    let settledEarly = false
    void answer.then(() => {
      settledEarly = true
    })
    await new Promise((done) => setTimeout(done, 20))
    expect(settledEarly).toBe(false)
    host.consent.stop()
    await answer
  })

  /**
   * A question raised at the desk is watched, never answered, from a device.
   *
   * The desktop may answer anything — somebody standing at the machine can
   * already do by hand whatever they are approving — and the reverse is not
   * true. This is the same rule as the test above with the surfaces swapped, and
   * it is worth its own case because the desk is the one origin a device might
   * plausibly be thought to share.
   */
  it('refuses to answer a question raised at the desk', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)
    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the state')

    host.deskAttached = true
    const answer = raise(host, 'window')
    const pending = await client.until(
      (m) => m.t === 'copilot.pending' && m.questions.length > 0,
      'the pending list',
    )
    const row = pending.t === 'copilot.pending' ? pending.questions[0] : null
    expect(row?.mine).toBe(false)

    client.send({ t: 'copilot.answer', id: row?.id ?? '', approved: true })
    await client.until((m) => m.t === 'error', 'the refusal')

    // The desktop answers it instead, and the device is told where it went.
    host.consent.respond(row?.id ?? '', true, 'window')
    const outcome = await answer
    expect(outcome.granted).toBe(true)
    const settled = await client.until((m) => m.t === 'copilot.settled', 'the withdrawal')
    expect(settled).toMatchObject({ settled: { granted: true, by: 'window' } })
  })

  /**
   * A device that drops mid-prompt defaults to refusal.
   *
   * Not to a desktop dialog left standing: the run that asked is about to be
   * reaped and the person who asked is gone, so an approval landing afterwards
   * is a change nobody is waiting for. `caller-gone` is the reason that already
   * exists for exactly this shape of failure, one transport further in.
   */
  it('refuses a device’s question when its socket goes', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await openCopilot(client)
    client.send({ t: 'copilot.attach' })
    await client.until((m) => m.t === 'copilot.state', 'the state')

    const answer = raise(host, 'device:device-1')
    await client.until((m) => m.t === 'copilot.ask', 'the question')

    // Destroyed rather than closed politely: what is being reproduced is a phone
    // going into a tunnel, not a person tapping Done.
    client.socket.destroy()
    const outcome = await answer
    expect(outcome.granted).toBe(false)
    expect(outcome.granted === false && outcome.reason).toBe('caller-gone')
  })

  /**
   * Nothing is delivered to a screen nobody is looking at, so the question
   * refuses itself rather than waiting for a dialog that will never be drawn.
   *
   * The *shape* of "nobody can be asked" changed with the separate copilot
   * connection, and it is worth being precise about how, because the shorter
   * version of this test now passes for the wrong reason.
   *
   * It used to be a device connected with `read` and `act` and no `alter`:
   * `ask` re-read the grant, found the tier missing, and reported that nobody
   * had been asked. There is no such device any more — one of his own devices
   * holds all three — so that arrangement would deliver the question, wait the
   * full timeout, and pass on the timeout rather than on the property.
   *
   * The real case is the one driven here and it is a case somebody actually hits
   * with the grace window: a device that opened the stream, started a run and
   * then **detached** — closed the app, locked the phone, walked off — while its
   * run kept going and reached a confirmation. There is no watcher on this
   * device and no window on this desktop, so `ask` reports that no approver saw
   * it and the broker answers at once. That is what stops a run blocking for two
   * minutes on a dialog nobody could have answered.
   */
  it('refuses at once when nothing is watching and no window is attached', async () => {
    const host = copilotHost()
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    // The stream is open — the device reaches the copilot and holds `alter` —
    // and deliberately nothing is attached, so the question has nowhere to go.
    await openCopilot(client)

    const outcome = await raise(host, 'device:device-1')
    expect(outcome.granted).toBe(false)
    expect(outcome.granted === false && outcome.reason).toBe('no-approver')
    // And it never crossed the wire, which is the half a `no-approver` alone
    // would not prove: the arguments of a pending settings change must not be
    // pushed to a socket that is not showing them to anybody.
    expect(client.received.some((m) => m.t === 'copilot.ask')).toBe(false)
  })
})

/**
 * *"The copilot is never shared."*
 *
 * His sentence about guest devices, and the reason it is enforced as an
 * **absence** rather than as a grant that happens to be off. A device that is
 * told the capability exists draws the tab; a tab that refuses on every press
 * still advertises the feature and invites the ask, and the answer to the ask is
 * always no. So an ineligible device gets no capability, no `copilot` key in its
 * welcome, and a refusal if it sends the frame anyway.
 *
 * The last one matters most and is the one a client cannot demonstrate: the
 * advertisement is what a *client of ours* respects, and this is what the
 * machine does when something that is not a client of ours asks.
 */
describe('the copilot is never shared with a guest', () => {
  it('does not tell a guest the capability exists', async () => {
    // No owners at all, so `isMine` and `copilotEligible` agree that this device
    // is somebody else's — which is the only state the shipped app can be in,
    // since `index.ts` reads both off the same `kindOf`.
    const host = copilotHost([])
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.copilot)
    // **No `copilot` key at all** — not a key saying no. The same shape a host
    // with no copilot whatsoever sends, deliberately: from the guest's point of
    // view those are the same fact and it is entitled to neither more nor less
    // than that. A key carrying `linked: false` would be this machine admitting
    // it has a copilot and telling a guest exactly which door is locked.
    expect(welcome.t === 'welcome' && welcome.copilot).toBeUndefined()
  })

  it('still tells one of the owner’s own machines', async () => {
    // `device-1` is the one device this file's authenticator knows a credential
    // for, so the roster is written round it rather than the reverse.
    const host = copilotHost(['device-1'])
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.copilot)
    expect(welcome.t === 'welcome' && welcome.copilot).toEqual({
      linked: true,
      open: false,
      grant: { read: true, act: true, alter: true },
    })
  })

  /**
   * **A guest sending `copilot.hello` is refused**, and it has learned nothing.
   *
   * This is what became of *"refuses a connect code from a guest"* and *"refuses
   * a stored credential from a guest as well"*. Both frames are gone: there is
   * no `copilot.connect` and the hello carries nothing, so the two cases have
   * collapsed into the one frame a guest can still construct.
   *
   * It matters more now than either of them did, and the reason is uncomfortable
   * enough to write down. The hello used to be refused twice over — the kind
   * said no, and there was also no credential a guest could have obtained. The
   * second refusal is gone. What is left standing between somebody else's phone
   * and this machine's shell is one check on one line in `handleCopilotConnection`,
   * and this is the test of it.
   *
   * The welcome half of *"the copilot is never shared"* is asserted in the first
   * test of this block rather than repeated here; what this adds is what the
   * machine does when something that is not a client of ours ignores the
   * advertisement and sends the frame anyway.
   */
  it('refuses copilot.hello from a guest and opens nothing', async () => {
    const host = copilotHost([])
    const harness = await serve({ copilot: host.copilot, copilotEligible: host.eligible })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'copilot.hello' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unauthorized')
    // The sentence names re-pairing, because that is the only remedy there is: a
    // kind is fixed when a device is approved and `device-kind.ts` deliberately
    // exposes no method that changes one. Sending somebody to look for a switch
    // would be sending them to look for something that does not exist.
    expect(error.t === 'error' && error.message).toMatch(/not shared with guest devices/i)

    // And the stream did not open behind the refusal, which the next frame is
    // what proves: a `copilot.state` after this must be refused too rather than
    // answered.
    client.send({ t: 'copilot.state' })
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
    expect(client.received.filter((m) => m.t === 'error').length).toBe(2)
    expect(client.received.some((m) => m.t.startsWith('copilot.'))).toBe(false)
  })
})

/**
 * Opening a page **on the machine**, which is what a browser tab cannot do for
 * itself.
 *
 * The web client's localhost screen could say which ports were open and could
 * not open one, and `pwa/src/localhost.ts` explains at length why no amount of
 * cleverness in a tab changes that. His complaint stands anyway — *"the whole
 * reason localhost exists is to drive them"* — and this is the answer he gave
 * for the phone in the same review: the page opens there, in a tab of that
 * machine's own browser.
 *
 * Three refusals are pinned here and each closes something different: a host
 * with no window never advertises the verb, a guest may not put a window on
 * somebody else's screen, and a URL that is not http(s) is refused by the same
 * gate the app's own links go through.
 */
describe('opening a page on the machine', () => {
  it('is not advertised by a host that has no window to open one in', async () => {
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.web)
  })

  it('opens it, and answers with what was opened', async () => {
    const opened: string[] = []
    const harness = await serve({
      openUrl: (url) => {
        opened.push(url)
        return true
      },
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.web)

    client.send({ t: 'web.open', url: 'http://localhost:5173/' })
    const done = await client.until((m) => m.t === 'web.opened', 'the confirmation')
    expect(done).toEqual({ t: 'web.opened', url: 'http://localhost:5173/' })
    expect(opened).toEqual(['http://localhost:5173/'])
  })

  it('says nothing opened when no window took it', async () => {
    // The honest failure: the app is launching, or the window has just closed.
    // `unavailable` rather than `unauthorized`, because retrying is exactly what
    // fixes it — the same split `create` makes between the two codes.
    const harness = await serve({ openUrl: () => false })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    client.send({ t: 'web.open', url: 'http://localhost:5173/' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unavailable')
    expect(client.received.some((m) => m.t === 'web.opened')).toBe(false)
  })

  it('refuses anything that is not a web address, without echoing it back', async () => {
    const opened: string[] = []
    const harness = await serve({
      openUrl: (url) => {
        opened.push(url)
        return true
      },
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    // `file:` walks a window onto the user's disk and `javascript:` runs in
    // whatever is already there. Neither is a document, and neither reaches the
    // shell — the refusal happens before `openUrl` is called at all.
    client.send({ t: 'web.open', url: 'file:///Users/apple/.ssh/id_ed25519' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unauthorized')
    // The attacker's string is not quoted into a sentence that is drawn on a
    // screen — the same rule the folder refusal follows.
    expect(error.t === 'error' && error.message).not.toContain('id_ed25519')
    expect(opened).toEqual([])
  })

  it('is neither advertised to nor served for a guest', async () => {
    const opened: string[] = []
    const harness = await serve({
      openUrl: (url) => {
        opened.push(url)
        return true
      },
      // Nobody is eligible: `device-1` is the only device this file's
      // authenticator knows, so this is "every connection is a guest".
      copilotEligible: () => false,
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.web)

    // And refused anyway, because the advertisement is what a client of ours
    // respects and this is what the machine does when something else asks.
    client.send({ t: 'web.open', url: 'http://localhost:5173/' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unauthorized')
    expect(opened).toEqual([])
  })
})

/**
 * The fifth door.
 *
 * Folder enforcement landed on `list`, `attach`, `create` and `close` — the four
 * verbs that reach files. A port is the fifth thing a paired device can ask this
 * machine for, and it was never behind any of it: until now six typed digits and
 * an approval bought a byte pipe to everything listening on the loopback,
 * whatever folders the person approving had chosen.
 *
 * `localhostAllowed` in `server.ts` carries the argument for the rule at length.
 * What is pinned here is the behaviour, in both halves: a guest is not *told*
 * the capability exists, and a guest that sends the frames anyway is refused
 * without losing the connection it is holding.
 */
/**
 * The model, the effort and fast mode of a session, over the wire.
 *
 * Two properties, and the second is the one that would be dangerous to get
 * wrong. The first is the negotiation: a host whose session layer cannot read a
 * screen does not advertise this, so a client talking to one never draws a menu
 * whose every press is refused. The second is the door — `controls.apply` ends
 * in characters and a return written into somebody's pty, so it is authorised
 * exactly as `input` is and a device that may not see a session may not set its
 * model either.
 */
describe('the controls capability', () => {
  const controls = {
    read: async () => ({
      model: { value: 'Opus 5', label: 'Opus 5', source: 'screen' },
      effort: { value: null, label: null, source: null },
      fast: { value: null, label: null, source: null },
      permission: { value: null, label: null, source: null },
      live: true,
      agent: { running: true, saw: 'Claude Code' },
      gate: { canType: true, reason: null },
    }),
    apply: async () => ({
      ok: true,
      message: 'Model is now Sonnet 5.',
      reading: { value: 'Sonnet 5', label: 'Sonnet 5', source: 'screen' },
    }),
  }

  it('is not advertised by a host whose session layer cannot read a screen', async () => {
    // The stub host and the demo box are both in this position: terminals, and
    // no shadow emulator to read one off. Advertising it there would draw a
    // model menu on the far window that could only ever come back empty.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.controls)
  })

  it('carries a reading back, keyed to the request that asked for it', async () => {
    const harness = await serve({ sessions: { ...fakeSessions(), controls } })
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.controls)

    client.send({ t: 'controls.read', rid: 'ctl-1', id: 'sess-1' })
    const answer = await client.until((m) => m.t === 'controls.reading', 'the reading')
    // The request id is echoed untouched. Two panes of a split ask about the
    // same session at once, and without this they resolve each other's reads.
    expect(answer.t === 'controls.reading' && answer.rid).toBe('ctl-1')
    expect(answer.t === 'controls.reading' && answer.reading.model.label).toBe('Opus 5')
  })

  it('answers a change with what the CLI said about it', async () => {
    const harness = await serve({ sessions: { ...fakeSessions(), controls } })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'controls.apply', rid: 'ctl-2', id: 'sess-1', control: 'model', value: 'sonnet' })
    const answer = await client.until((m) => m.t === 'controls.applied', 'the answer')
    expect(answer.t === 'controls.applied' && answer.ok).toBe(true)
    // The sentence is the payload. A refusal from the account arrives the same
    // way, in the CLI's own words, because that is the only thing that tells
    // somebody at the other end what to do about it.
    expect(answer.t === 'controls.applied' && answer.message).toBe('Model is now Sonnet 5.')
  })

  it('refuses a device that may not touch that session, and never asks the layer', async () => {
    /*
     * The door that matters. `controls.apply` types into a pty, so it is
     * authorised exactly as `input` is — and the refusal is deliberately the
     * same sentence an unknown id gets, because a distinct one would confirm the
     * id names something real. These ids are recoverable from an alert, a
     * transcript path or an older list.
     */
    let asked = 0
    const watched = {
      read: async () => {
        asked += 1
        return controls.read()
      },
      apply: async () => {
        asked += 1
        return controls.apply()
      },
    }
    const harness = await serve({
      sessions: { ...fakeSessions(), controls: watched, visible: () => false },
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'controls.apply', rid: 'ctl-3', id: 'sess-1', control: 'model', value: 'sonnet' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unknown-session')
    expect(asked, 'the session layer was reached for a session this device may not see').toBe(0)

    // And the connection survives, like every other refused request here.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
  })
})

/**
 * Whose login a session is on, and running it as another one, over the wire.
 *
 * The same two properties the controls block above pins, and the second one is
 * sharper here. `controls.apply` types a slash command at a session that
 * survives it; `account.switch` **ends the agent process and starts another**,
 * so a device that may not touch a session must certainly not be able to replace
 * it — and the refusal is the same `unknown-session` an unauthorised `attach`
 * gets, because a distinct one would confirm the id names something real.
 */
describe('the account capability', () => {
  const account = {
    read: async () => ({
      current: { id: 'work', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
      accounts: [
        { id: 'work', name: 'work@example.com', provider: 'claude', color: 'acct-3', system: false },
        { id: 'system', name: 'Default', provider: 'claude', color: null, system: true },
      ],
    }),
    switch: async (sessionId: string) => ({
      ok: true,
      message: '',
      // A switch replaces the process, so the id changes. This is the field with
      // no counterpart on `controls.applied`.
      session: `${sessionId}-replaced`,
    }),
  }

  it('is not advertised by a host with no way to replace a session', async () => {
    /*
     * Gated on its own member and not on `controls`, because the two are
     * genuinely separable: `scripts/remote-host.ts` has terminals and no account
     * store, and the headless build has an account store and no session
     * lifecycle to replace one through. A chip advertised by either would be a
     * menu whose every row is refused after the press.
     */
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).not.toContain(CAPABILITY.account)
  })

  it('carries the list and the login in force, keyed to the request that asked', async () => {
    const harness = await serve({ sessions: { ...fakeSessions(), account } })
    const client = await connect(harness.port)
    client.send(HELLO)
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.account)

    client.send({ t: 'account.read', rid: 'acc-1', id: 'sess-1' })
    const answer = await client.until((m) => m.t === 'account.state', 'the state')
    expect(answer.t === 'account.state' && answer.rid).toBe('acc-1')
    expect(answer.t === 'account.state' && answer.current?.name).toBe('work@example.com')
    expect(answer.t === 'account.state' && answer.accounts.map((row) => row.id)).toEqual(['work', 'system'])
  })

  it('answers a switch with the id the session has afterwards', async () => {
    const harness = await serve({ sessions: { ...fakeSessions(), account } })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'account.switch', rid: 'acc-2', id: 'sess-1', accountId: 'system' })
    const answer = await client.until((m) => m.t === 'account.switched', 'the answer')
    expect(answer.t === 'account.switched' && answer.ok).toBe(true)
    // The whole reason this frame is not `controls.applied`: a window that kept
    // the old id would be attached to a pty this machine has already killed.
    expect(answer.t === 'account.switched' && answer.session).toBe('sess-1-replaced')
  })

  it('refuses a device that may not touch that session, and never asks the layer', async () => {
    let asked = 0
    const watched = {
      read: async () => {
        asked += 1
        return account.read()
      },
      switch: async (sessionId: string) => {
        asked += 1
        return account.switch(sessionId)
      },
    }
    const harness = await serve({
      sessions: { ...fakeSessions(), account: watched, visible: () => false },
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'account.switch', rid: 'acc-3', id: 'sess-1', accountId: 'system' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unknown-session')
    expect(asked, 'the account layer was reached for a session this device may not see').toBe(0)

    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
  })
})

/**
 * The fifth door, and what a guest is actually given at it.
 *
 * Folder enforcement landed on `list`, `attach`, `create` and `close` — the four
 * verbs that reach files. A port is the fifth thing a paired device can ask this
 * machine for, and it was never behind any of it: six typed digits and an
 * approval once bought a byte pipe to everything listening on the loopback,
 * whatever folders the person approving had chosen.
 *
 * The first fix was *every port or none*, and a guest got none. That was too
 * blunt in a way that showed up as a broken feature: a guest can already ask
 * this host to **start** the dev server in a folder it was granted, and is
 * already told the port it came up on, and then could not open it. Asad,
 * connected to his own PC as a guest — *"still as a guest I should be able to
 * open a browser."*
 *
 * So the rule is now the one the grant already implies. `localhostAllowed` and
 * `grantedPorts` in `server.ts` carry the argument; what is pinned here is the
 * behaviour, in all three halves: a guest is told the capability exists, is
 * offered only the ports this machine can name one of its folders for, and is
 * refused a tunnel to anything else with the same answer an absent port gets.
 */
describe('what a guest may reach on the loopback', () => {
  /** Every connection is a guest: `device-1` is the only device this file knows. */
  const everyoneIsAGuest = (): boolean => false

  /** A dev-server module with one folder up on one port. */
  function devServersReady(folder: string, port: number): DevServers {
    return {
      ...fakeDevServers(),
      status(asked: string): DevServerState {
        return asked === folder
          ? { folder, status: 'ready', script: 'dev', command: 'pnpm run dev', port, url: `http://localhost:${port}` }
          : { folder: asked, status: 'idle', script: 'dev', command: 'pnpm run dev' }
      },
    }
  }

  const twoPorts = async (): Promise<{ port: number; process: string; guessed: boolean }[]> => [
    { port: 4321, process: 'node', guessed: false },
    { port: 9999, process: 'postgres', guessed: false },
  ]

  it('tells a guest this machine serves localhost, because now it does', async () => {
    const harness = await serve(
      { copilotEligible: everyoneIsAGuest, devServers: devServersReady('/tmp/allowed', 4321) },
      creatingSessions(['/tmp/allowed']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.localhost)
  })

  it('offers a guest only the port its own folder grant covers', async () => {
    // 9999 is listening and is nobody's project as far as this machine can say —
    // a database, another service, somebody else's dev build. It is exactly what
    // the old *every port* rule handed over.
    const harness = await serve(
      {
        copilotEligible: everyoneIsAGuest,
        devServers: devServersReady('/tmp/allowed', 4321),
        scanPorts: twoPorts,
      },
      creatingSessions(['/tmp/allowed']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'ports' })
    const ports = await client.until((m) => m.t === 'ports', 'the port list')
    expect(ports.t === 'ports' && ports.ports).toEqual([{ port: 4321, process: 'node', guessed: false }])
  })

  it('refuses a guest a tunnel to a port outside its grant, and says nothing about it', async () => {
    const harness = await serve(
      {
        copilotEligible: everyoneIsAGuest,
        devServers: devServersReady('/tmp/allowed', 4321),
        scanPorts: twoPorts,
      },
      creatingSessions(['/tmp/allowed']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'tunnel.open', id: 'tun-1', port: 9999 })
    const closed = await client.until((m) => m.t === 'tunnel.closed', 'the refusal')
    // The same answer a port nothing is listening on gets. A distinct one would
    // confirm that 9999 names something real, which is the fact being withheld.
    expect(closed.t === 'tunnel.closed' && closed.message).toContain('9999')
    expect(client.received.some((m) => m.t === 'tunnel.opened')).toBe(false)

    // And the connection survives, as it did when this was a flat refusal: a
    // device told "not that one" must not lose the terminal it is holding.
    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
  })

  it('gives a guest nothing when this host cannot say whose folder a port is in', async () => {
    // No dev-server module, so there is no source on this machine that can name
    // a folder for a port. The correct answer for a host that cannot ask the
    // question is to offer nothing, which is the same rule `devserver`'s own
    // advertisement follows.
    const harness = await serve(
      { copilotEligible: everyoneIsAGuest, scanPorts: twoPorts },
      creatingSessions(['/tmp/allowed']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'ports' })
    const ports = await client.until((m) => m.t === 'ports', 'the port list')
    expect(ports.t === 'ports' && ports.ports).toEqual([])
  })

  it('gives a guest nothing for a folder whose dev server is not up yet', async () => {
    // `port` is set only on `ready` — a `starting` has none and a `failed` may
    // be carrying one from an attempt that is over.
    const harness = await serve(
      { copilotEligible: everyoneIsAGuest, devServers: fakeDevServers(), scanPorts: twoPorts },
      creatingSessions(['/tmp/allowed']),
    )
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'ports' })
    const ports = await client.until((m) => m.t === 'ports', 'the port list')
    expect(ports.t === 'ports' && ports.ports).toEqual([])
  })

  it('still gives one of the owner’s own machines everything', async () => {
    const harness = await serve({
      copilotEligible: (deviceId) => deviceId === 'device-1',
      scanPorts: async () => [{ port: 4321, process: 'node', guessed: false }],
    })
    const client = await connect(harness.port)
    client.send(HELLO)

    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.capabilities).toContain(CAPABILITY.localhost)
    client.send({ t: 'ports' })
    const ports = await client.until((m) => m.t === 'ports', 'the port list')
    // No dev-server module anywhere in this harness, and the whole scan arrives:
    // the narrowing is a guest's, and one of your own is not narrowed at all.
    expect(ports.t === 'ports' && ports.ports).toEqual([{ port: 4321, process: 'node', guessed: false }])
  })

  it('refuses these verbs outright on a host that never offered localhost', async () => {
    // `options.offer` is the host's own ceiling and the public demo box uses it.
    // Checked at the door as well as in the advertisement, because a client that
    // never read the welcome still sends the frame.
    const harness = await serve({ offer: [CAPABILITY.create], scanPorts: twoPorts })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'ports' })
    const error = await client.until((m) => m.t === 'error', 'the refusal')
    expect(error.t === 'error' && error.code).toBe('unauthorized')
    expect(client.received.some((m) => m.t === 'ports')).toBe(false)

    client.send({ t: 'ping' })
    await client.until((m) => m.t === 'pong', 'the pong')
  })
})

describe('a browser window on the device, driven by a session here', () => {
  /**
   * The capability that runs the other way round.
   *
   * Everything else this server advertises is a verb a client sends. `windows`
   * is a question *this machine* asks a device — a session running here, with a
   * browser window attached to it in the app on that device's screen — so what
   * it is gated on is having a desk to hold the question, and which connections
   * it may be put to is decided by what the client said in its own `hello`.
   */
  function desk(): {
    windows: WindowAskDesk
    asked: { deviceId: string; message: ServerMessage }[]
    answered: { id: string; ok: boolean; body: string }[]
  } {
    const asked: { deviceId: string; message: ServerMessage }[] = []
    const answered: { id: string; ok: boolean; body: string }[] = []
    const heldBy = new Map<string, readonly string[]>()
    let wire: {
      ask(deviceId: string, message: ServerMessage): number
      reaches(deviceId: string): boolean
    } | null = null
    return {
      asked,
      answered,
      windows: {
        serve: (next) => {
          wire = next
        },
        call: ({ deviceId, sessionId, tool, args }) => {
          const message: ServerMessage = { t: 'window.call', id: 'w-1', session: sessionId, tool, args }
          asked.push({ deviceId, message })
          wire?.ask(deviceId, message)
          return Promise.resolve({ ok: true, body: '{}' })
        },
        answer: (id, result) => {
          answered.push({ id, ...result })
          return true
        },
        held: (deviceId, sessions) => {
          heldBy.set(deviceId, sessions)
        },
        holdersOf: (sessionId) =>
          [...heldBy].filter(([, sessions]) => sessions.includes(sessionId)).map(([deviceId]) => deviceId),
        reaches: (deviceId) => wire?.reaches(deviceId) ?? false,
        gone: () => undefined,
        stop: () => undefined,
        waiting: 0,
      },
    }
  }

  it('is not advertised by a host with nowhere to hold the question', async () => {
    /*
     * The same rule every capability here follows: the thing that makes the
     * feature possible decides whether it is offered. A device told it may be
     * asked, by a host that could never ask, is a device running code for
     * nothing.
     */
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    const hello = await client.until((m) => m.t === 'welcome', 'the welcome')
    if (hello.t !== 'welcome') throw new Error('unreachable')
    expect(hello.capabilities).not.toContain('windows')
  })

  it('is advertised when there is, and reaches only a client that can answer', async () => {
    const held = desk()
    const harness = await serve({ windows: held.windows })

    // A client that has not said it holds windows. It is a device like any
    // other; it simply has no code for this frame, and a question put to it
    // would be a tool call waiting out a deadline.
    const deaf = await connect(harness.port)
    deaf.send(HELLO)
    const welcome = await deaf.until((m) => m.t === 'welcome', 'the welcome')
    if (welcome.t !== 'welcome') throw new Error('unreachable')
    expect(welcome.capabilities).toContain('windows')

    await held.windows.call({ deviceId: 'device-1', sessionId: 's1', tool: 'browser.read', args: '{}' })
    expect(deaf.received.some((m) => m.t === 'window.call')).toBe(false)

    // The same device, on a channel that said it can serve them.
    const holder = await connect(harness.port)
    holder.send({ ...HELLO, capabilities: ['windows'] })
    await holder.until((m) => m.t === 'welcome', 'the welcome')
    await held.windows.call({ deviceId: 'device-1', sessionId: 's1', tool: 'browser.read', args: '{}' })
    const call = await holder.until((m) => m.t === 'window.call', 'the browser verb')
    expect(call).toMatchObject({ t: 'window.call', session: 's1', tool: 'browser.read' })
  })

  it('hands an answer to the desk that asked, and drops one nobody asked for', async () => {
    const held = desk()
    const harness = await serve({ windows: held.windows })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['windows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'window.result', id: 'w-1', ok: true, body: '{"title":"Example"}' })
    await new Promise((settle) => setTimeout(settle, 30))
    expect(held.answered).toEqual([{ id: 'w-1', ok: true, body: '{"title":"Example"}' }])

    /*
     * And the channel stays open for an answer that crossed this end's deadline
     * on the wire. That is an ordinary race with an already correct outcome —
     * the tool call has been answered — and closing the link over it would turn
     * a slow network into a dropped machine.
     */
    client.send({ t: 'window.result', id: 'w-9', ok: true, body: '{}' })
    await new Promise((settle) => setTimeout(settle, 30))
    expect(held.answered).toHaveLength(2)
    expect(client.received.some((m) => m.t === 'error')).toBe(false)
  })

  it('writes down which of this machine’s sessions that device is holding a window for', async () => {
    /*
     * The fact that makes this feature work for a session nobody started
     * remotely — one already running here, one restored, one typed into at this
     * keyboard. The window is attached in the *other* app's map and nothing on
     * this side of the wire can see it, so the device says which sessions of
     * ours it is holding one for, and it says the whole set each time: a link
     * that dropped and came back is correct by arriving, and a detach is a set
     * with one fewer id in it.
     *
     * Without this, `windowOwnerOf` — written at the spawn — was the only
     * answer, so the six verbs on any other session resolved in this machine's
     * own empty map and said "no browser window is attached to this session"
     * about a page on somebody's screen.
     */
    const held = desk()
    const harness = await serve({ windows: held.windows })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['windows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'window.holds', sessions: ['s1', 's2'] })
    await new Promise((settle) => setTimeout(settle, 30))
    expect(held.windows.holdersOf('s1')).toEqual(['device-1'])

    // The next set replaces the last one, which is the only way a detach
    // travels.
    client.send({ t: 'window.holds', sessions: ['s2'] })
    await new Promise((settle) => setTimeout(settle, 30))
    expect(held.windows.holdersOf('s1')).toEqual([])
    expect(held.windows.holdersOf('s2')).toEqual(['device-1'])
    // And the channel is unharmed by any of it.
    expect(client.received.some((m) => m.t === 'error')).toBe(false)
  })

  it('also hands on what those windows *are*, so the session can be told it has one', async () => {
    /*
     * The half of this frame that did not exist until tonight.
     *
     * The desk above is enough to *address* a browser verb and is not one word
     * of what an agent would have to know to send one — it has the session id it
     * already had, and no slot name, no title and no URL. So the window was
     * drivable by a session that had no way to learn it existed, which is the
     * same thing as not having it: measured, an agent in that state concludes it
     * has no browser and offers to print a link.
     *
     * Both halves come off the same arriving frame and neither substitutes for
     * the other: routing with nothing to say is an agent that cannot find the
     * window, and a sentence with no route is a name that refuses.
     */
    const held = desk()
    const said: { peer: { id: string; name: string }; held: readonly HeldSession[] }[] = []
    const harness = await serve({
      windows: held.windows,
      onWindowsHeld: (peer, rows) => said.push({ peer, held: rows }),
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['windows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({
      t: 'window.holds',
      sessions: ['s1'],
      held: [
        {
          session: 's1',
          windows: [{ n: 2, title: 'Stripe', url: 'https://stripe.com', host: 'Office PC' }],
        },
      ],
    })
    await new Promise((settle) => setTimeout(settle, 30))

    /*
     * The name is this machine's own label for the device, never the one that
     * travelled — and the two differ right here, which is what makes the
     * assertion worth making. The `hello` above says `iPhone`; the roster on
     * this side says `Test iPhone`, and that is what is printed into the agent's
     * turn. A name a peer wrote would be the one string in that sentence naming a
     * computer, taken off a socket.
     */
    expect(said).toHaveLength(1)
    expect(said[0].peer).toEqual({ id: 'device-1', name: 'Test iPhone' })
    expect(said[0].held).toEqual([
      {
        session: 's1',
        windows: [{ n: 2, title: 'Stripe', url: 'https://stripe.com', host: 'Office PC' }],
      },
    ])
    // And the routing table is filled from the same frame, as it always was.
    expect(held.windows.holdersOf('s1')).toEqual(['device-1'])
  })

  it('reads a device that has never heard of the rows as claiming no window it can name', async () => {
    // Every build shipped before tonight sends `sessions` and nothing else. It
    // must keep routing exactly as it did, and it must not be read as having
    // described a window — an empty entry would print as a session that has
    // windows nobody can name.
    const held = desk()
    const seen: HeldSession[][] = []
    const harness = await serve({
      windows: held.windows,
      onWindowsHeld: (_peer, rows) => seen.push([...rows]),
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['windows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'window.holds', sessions: ['s1'] })
    await new Promise((settle) => setTimeout(settle, 30))

    expect(seen).toEqual([[]])
    expect(held.windows.holdersOf('s1')).toEqual(['device-1'])
  })

  it('drops a row for a session the same frame does not claim', async () => {
    /*
     * The two halves of one frame are one read of one map on every sender, so
     * this cannot happen honestly. It is refused anyway, and dropped rather than
     * made a reason to close the link: `sessions` is what the router acts on, so
     * a row for a session no verb will ever be addressed to is a line an agent
     * cannot use.
     */
    const held = desk()
    const seen: HeldSession[][] = []
    const harness = await serve({
      windows: held.windows,
      onWindowsHeld: (_peer, rows) => seen.push([...rows]),
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['windows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({
      t: 'window.holds',
      sessions: ['s1'],
      held: [
        { session: 's1', windows: [{ n: 1 }] },
        { session: 'never-claimed', windows: [{ n: 1, title: 'His bank' }] },
      ],
    })
    await new Promise((settle) => setTimeout(settle, 30))

    expect(seen).toEqual([[{ session: 's1', windows: [{ n: 1, title: '', url: '', host: '' }] }]])
    expect(client.received.some((m) => m.t === 'error')).toBe(false)
  })
})
describe('a browser window here, driven by a session on the device', () => {
  /**
   * The mirror, and the cell that did not exist before 2026-08-21.
   *
   * `windows` above is this machine asking a device to move a browser it holds.
   * This is the opposite arrangement — a device that dialled in has the pty, and
   * the window is in *this* app — and it is just as ordinary, because which of
   * two desktops is the host depends only on who dialled whom. It is the same
   * three frames read the other way round, gated on a second capability so that
   * a client from before tonight is never sent one it would answer by closing
   * the channel.
   */
  function server(): {
    serveWindows: (
      deviceId: string,
      call: { sessionId: string; tool: string; args: string },
    ) => Promise<{ ok: boolean; body: string }>
    seen: { deviceId: string; call: { sessionId: string; tool: string; args: string } }[]
    answer: { ok: boolean; body: string }
    fail: boolean
  } {
    const state = {
      seen: [] as { deviceId: string; call: { sessionId: string; tool: string; args: string } }[],
      answer: { ok: true, body: '{"title":"Example"}' },
      fail: false,
      serveWindows: (
        deviceId: string,
        call: { sessionId: string; tool: string; args: string },
      ): Promise<{ ok: boolean; body: string }> => {
        state.seen.push({ deviceId, call })
        if (state.fail) return Promise.reject(new Error('the browser is switched off'))
        return Promise.resolve(state.answer)
      },
    }
    return state
  }

  it('is not advertised by a host with nothing that can act on a window', async () => {
    // The same rule every capability here follows, and the one that keeps a
    // device from sending a frame nobody will answer: the headless daemon has
    // no browser, so it never claims it can be driven.
    const harness = await serve()
    const client = await connect(harness.port)
    client.send(HELLO)
    const hello = await client.until((m) => m.t === 'welcome', 'the welcome')
    if (hello.t !== 'welcome') throw new Error('unreachable')
    expect(hello.capabilities).not.toContain('hostwindows')
  })

  it('serves the verb and answers on the same socket', async () => {
    const acting = server()
    const harness = await serve({ serveWindows: acting.serveWindows })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    const welcome = await client.until((m) => m.t === 'welcome', 'the welcome')
    if (welcome.t !== 'welcome') throw new Error('unreachable')
    expect(welcome.capabilities).toContain('hostwindows')

    client.send({ t: 'window.call', id: 'w-7', session: 's1', tool: 'browser.read', args: '{}' })
    const result = await client.until((m) => m.t === 'window.result', 'the answer')
    expect(result).toEqual({ t: 'window.result', id: 'w-7', ok: true, body: '{"title":"Example"}' })
    // The device id is supplied by this end, from the connection, and never read
    // off the frame: it is the half of the caller key the far end cannot know.
    expect(acting.seen).toEqual([
      { deviceId: 'device-1', call: { sessionId: 's1', tool: 'browser.read', args: '{}' } },
    ])
  })

  it('answers even when nothing here can act, rather than leaving a turn waiting', async () => {
    /*
     * The far end is inside an MCP tool call with a model waiting on it. Silence
     * costs a whole turn and produces the thing `session-verbs.ts` was written to
     * stop: an agent that concludes it has not found the way in yet and goes
     * looking for another.
     */
    const harness = await serve({ windows: undefined })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'window.call', id: 'w-8', session: 's1', tool: 'browser.read', args: '{}' })
    const result = await client.until((m) => m.t === 'window.result', 'the refusal')
    if (result.t !== 'window.result') throw new Error('unreachable')
    expect(result.ok).toBe(false)
    expect(String(JSON.parse(result.body).message)).toContain('not set up to be driven')
  })

  it('turns a server that threw into a refusal on the wire', async () => {
    const acting = server()
    acting.fail = true
    const harness = await serve({ serveWindows: acting.serveWindows })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'window.call', id: 'w-9', session: 's1', tool: 'browser.step', args: '{}' })
    const result = await client.until((m) => m.t === 'window.result', 'the refusal')
    if (result.t !== 'window.result') throw new Error('unreachable')
    expect(result.ok).toBe(false)
    expect(String(JSON.parse(result.body).message)).toContain('switched off')
  })

  it('tells that device which of its sessions has a window here, on the welcome', async () => {
    /*
     * The fact the far end cannot derive: the window is a `WebContentsView` in
     * this process and the pty is on that computer. On the welcome rather than
     * on request, because this socket is new after every reconnect and the far
     * end's table went with the old one.
     */
    const acting = server()
    const harness = await serve({
      serveWindows: acting.serveWindows,
      windowsHeldFor: (deviceId) => (deviceId === 'device-1' ? [heldRow('s1'), heldRow('s2')] : []),
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    const holds = await client.until((m) => m.t === 'window.holds', 'the holdings')
    expect(holds).toEqual({
      t: 'window.holds',
      sessions: ['s1', 's2'],
      held: [heldRow('s1'), heldRow('s2')],
    })
  })

  it('says nothing to a client that never advertised the direction', async () => {
    /*
     * `parseServerMessage` on an older client answers a frame it has never heard
     * of by closing the channel. A device that falls off the network is a far
     * worse outcome than a window it cannot be told about — the same argument
     * `MachineLink.announceWindows` makes from the other end.
     */
    const acting = server()
    const harness = await serve({
      serveWindows: acting.serveWindows,
      windowsHeldFor: () => [heldRow('s1')],
    })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')
    await new Promise((settle) => setTimeout(settle, 30))
    expect(client.received.some((m) => m.t === 'window.holds')).toBe(false)

    // And a push has nobody to reach, which is a count rather than an error.
    expect(harness.endpoint.windowsHeldChanged()).toBe(0)
  })

  it('re-reads the set on a push, so an attach after the welcome still arrives', async () => {
    // The person attaches a window ten minutes into a session. Nothing about the
    // connection changed; the answer did.
    const acting = server()
    let held: HeldSession[] = []
    const harness = await serve({
      serveWindows: acting.serveWindows,
      windowsHeldFor: () => held,
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    await client.until((m) => m.t === 'window.holds', 'the first holdings')

    held = [heldRow('s3')]
    expect(harness.endpoint.windowsHeldChanged()).toBe(1)
    const next = await client.until(
      (m) => m.t === 'window.holds' && m.sessions.includes('s3'),
      'the new holdings',
    )
    expect(next).toEqual({ t: 'window.holds', sessions: ['s3'], held: [heldRow('s3')] })
  })

  /**
   * And the fact going the other way, which is what made every one of the tests
   * above able to say anything at all.
   *
   * `windowsHeldFor` answered the empty set to every device for as long as this
   * frame did not exist — correctly, because nothing in this app could name a
   * session on a device that dialled in, so no window was ever attached to one,
   * so no binding was ever filed under a device's id. The picker had two lists
   * and neither of them was the guest's. This is the third.
   */
  const GUEST_ROW = {
    id: 'guest-1',
    title: 'terminaldeck',
    cwd: '/Users/apple/Projects/terminaldeck',
    provider: 'claude',
    status: 'idle',
    exitCode: null,
  }

  it('keeps what a device says is running on its own computer, and shows it on the roster', async () => {
    const acting = server()
    const seen: RemoteConnection[][] = []
    const harness = await serve({
      serveWindows: acting.serveWindows,
      onConnections: (connections) => seen.push(connections),
    })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'sessions.mine', sessions: [GUEST_ROW] })
    await new Promise((settle) => setTimeout(settle, 30))

    const rows = harness.endpoint.connections()
    expect(rows).toHaveLength(1)
    expect(rows[0].sessions).toEqual([GUEST_ROW])
    // And it is pushed, not only readable: the browser's attach menu is built
    // from the roster and nothing else would tell it a terminal had opened over
    // there.
    expect(seen.at(-1)?.[0]?.sessions).toEqual([GUEST_ROW])
  })

  it('replaces the list whole, so a terminal closed over there leaves the menu', async () => {
    const acting = server()
    const harness = await serve({ serveWindows: acting.serveWindows })
    const client = await connect(harness.port)
    client.send({ ...HELLO, capabilities: ['hostwindows'] })
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'sessions.mine', sessions: [GUEST_ROW] })
    await new Promise((settle) => setTimeout(settle, 20))
    client.send({ t: 'sessions.mine', sessions: [] })
    await new Promise((settle) => setTimeout(settle, 20))

    expect(harness.endpoint.connections()[0]?.sessions).toEqual([])
  })

  it('drops the announcement on a host with no browser to attach, rather than closing the link', async () => {
    /*
     * No `serveWindows` means this host never advertised `hostWindows`, so a
     * window could never be attached to one of these rows and the list would be a
     * menu of dead entries. A client that sent it anyway is talking to an older
     * desktop, and an announcement nobody asked for is dropped — never made a
     * reason to close somebody's link.
     */
    const harness = await serve({})
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    client.send({ t: 'sessions.mine', sessions: [GUEST_ROW] })
    await new Promise((settle) => setTimeout(settle, 30))

    expect(client.received.some((m) => m.t === 'error')).toBe(false)
    expect(harness.endpoint.connections()[0]?.sessions).toEqual([])
  })

  it('is empty for a phone, which has no terminals to announce', async () => {
    const acting = server()
    const harness = await serve({ serveWindows: acting.serveWindows })
    const client = await connect(harness.port)
    client.send(HELLO)
    await client.until((m) => m.t === 'welcome', 'the welcome')

    expect(harness.endpoint.connections()[0]?.sessions).toEqual([])
  })
})

/**
 * One held window, in the shape the frame now carries.
 *
 * The rows exist so the far end can *name* the window to an agent; nothing in
 * these tests reads the title or the URL, so they are empty here for the same
 * reason a real window with nothing loaded reports them empty — a placeholder
 * that reads like a fact is the one thing these rows must never contain.
 */
function heldRow(session: string, n = 1): HeldSession {
  return { session, windows: [{ n, title: '', url: '', host: '' }] }
}
