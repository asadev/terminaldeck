/**
 * The relay path, end to end, with nothing stubbed in the middle.
 *
 * Every component here is the real one: the relay from `relay/src/rendezvous`
 * on a loopback port, the desktop's own `relay-client`, the real
 * `createRemoteEndpoint` with a real `RemoteAuth` over a temp directory, and a
 * phone written out below because `ws` is not a dependency of this project.
 *
 * That is deliberate rather than thorough. Every bug this feature has had so far
 * lived in the seams a mock replaces — masking on the client's frames, the
 * envelope, the bytes that arrive in the same TCP segment as the `101`, a
 * handshake whose transcript hashes differ by one field. A test that called
 * `onEnvelope` with a hand-made buffer would pass against a client that cannot
 * complete a single real connection.
 *
 * The last test is the one that justifies the design. It records every byte
 * that crosses the relay in both directions and asserts that none of the
 * session is legible in it. If that goes green while the property is false, the
 * reason it is acceptable to run this service at all is gone.
 */

import { mkdtempSync, rmSync } from 'node:fs'
import { createServer, connect as netConnect, type Server, type Socket } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { createRelayServer, hostIdFor as relayHostIdFor, type RelayServer } from '../../../relay/src/rendezvous'
import {
  HANDSHAKE_REPLY_BYTES,
  MAX_PAYLOAD_BYTES,
  hostIdFor,
  readSealedHandshake,
  withSealedVersion,
} from '../../shared/relay-wire'
import {
  finishHandshake,
  generateStatic,
  secretBytes,
  startHandshake,
  type SealedTransport,
  type StaticKeyPair,
} from '../../shared/sealed'
import { FrameReader, OPCODE, encodeMaskedFrame, handshakeResponse } from '../../shared/ws-frame'
import { RemoteAuth } from './device-auth'
import { loadHostIdentity, type HostIdentity } from './host-identity'
import { createRelayClient, relayEnabled, relayTarget, relayUrl, type RelayLink } from './relay-client'
import { serialize, type ClientMessage, type RemoteSession, type ServerMessage } from './protocol'
import {
  authenticatorFor,
  createRemoteEndpoint,
  createRemoteServer,
  pairingDesk,
  type RemoteEndpoint,
  type SessionAccess,
  type SessionHandle,
} from './server'
import { BLOCKED_REASONS } from './tailnet'

/* ------------------------------------------------------------- fixtures -- */

/**
 * Strings chosen to be unmistakable in a hex dump.
 *
 * The opacity test greps every byte the relay carried for each of these. A
 * realistic value like "ls -la" would match by accident somewhere in a TLS
 * record or a base64 blob and turn a real failure into a coin flip.
 */
const SESSION_ID = 'plaintext-session-d5a2'
const SCROLLBACK = 'PLAINTEXT-SCROLLBACK-a7f3'
const KEYSTROKES = 'PLAINTEXT-KEYSTROKES-b4e1'
const LIVE_OUTPUT = 'PLAINTEXT-LIVE-OUTPUT-e8c0'
const DEVICE_NAME = 'PLAINTEXT-DEVICE-c2d9'

const temps: string[] = []
const closers: Array<() => void | Promise<void>> = []

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-relay-'))
  temps.push(dir)
  return dir
}

afterEach(async () => {
  for (const close of closers.splice(0).reverse()) await close()
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true })
})

async function waitFor(predicate: () => boolean, label: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (predicate()) return
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((settle) => setTimeout(settle, 5))
  }
}

interface Sessions extends SessionAccess {
  /** Everything a phone has typed into the fake session. */
  typed: string[]
  /** Push live output at whoever is attached, after the replay has flushed. */
  emit(data: string): void
}

function fakeSessions(): Sessions {
  const listeners = new Set<(data: string) => void>()
  const typed: string[] = []
  const session: RemoteSession = {
    id: SESSION_ID,
    title: 'agent',
    cwd: '/tmp/project',
    provider: 'claude',
    status: 'running',
    exitCode: null,
  }
  return {
    typed,
    emit(data: string): void {
      for (const listener of listeners) listener(data)
    },
    list: () => [session],
    attach(id, onData): SessionHandle | null {
      if (id !== SESSION_ID) return null
      listeners.add(onData)
      return { sessionId: id, replay: SCROLLBACK }
    },
    write(_id, data): void {
      typed.push(data)
    },
    resize(): void {},
    detach(): void {
      listeners.clear()
    },
  }
}

/* ------------------------------------------------------------- the phone -- */

/**
 * A phone, in as few lines as speak the contract.
 *
 * Client frames are masked because RFC 6455 §5.3 says they must be and the
 * relay enforces it — the same rule the desktop client had to learn, from the
 * other side.
 */
class Phone {
  private readonly reader = new FrameReader(MAX_PAYLOAD_BYTES * 2, 'client')
  private readonly inbox: ServerMessage[] = []
  private readonly raw: Buffer[] = []
  private transport: SealedTransport | null = null
  private waiting: (() => void) | null = null
  closed = false
  status = 0

  private constructor(
    private readonly socket: Socket,
    readonly keys: StaticKeyPair,
  ) {}

  static async open(port: number, hostId: string, keys = generateStatic()): Promise<Phone> {
    const socket = netConnect(port, '127.0.0.1')
    const phone = new Phone(socket, keys)
    closers.push(() => {
      socket.destroy()
    })
    await new Promise<void>((settle, fail) => {
      socket.once('error', fail)
      socket.once('connect', () => settle())
    })

    socket.write(
      [
        `GET /v1/join?host=${hostId} HTTP/1.1`,
        'Host: 127.0.0.1',
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        'Sec-WebSocket-Version: 13',
        '',
        '',
      ].join('\r\n'),
    )

    let head = Buffer.alloc(0)
    let upgraded = false
    socket.on('data', (chunk: Buffer) => {
      if (upgraded) return phone.feed(chunk)
      head = Buffer.concat([head, chunk])
      const end = head.indexOf('\r\n\r\n')
      if (end === -1) return
      phone.status = Number(/HTTP\/1\.1 (\d+)/.exec(head.subarray(0, end).toString('latin1'))?.[1] ?? 0)
      const rest = Buffer.from(head.subarray(end + 4))
      upgraded = true
      if (rest.length > 0) phone.feed(rest)
    })
    socket.on('close', () => {
      phone.closed = true
      phone.wake()
    })
    await waitFor(() => upgraded || phone.closed, 'the relay to answer the phone’s upgrade')
    return phone
  }

  private wake(): void {
    const waiting = this.waiting
    this.waiting = null
    waiting?.()
  }

  private feed(chunk: Buffer): void {
    for (const frame of this.reader.push(chunk).frames) {
      if (frame.opcode === OPCODE.close) {
        this.closed = true
        continue
      }
      if (frame.opcode === OPCODE.ping) {
        this.socket.write(encodeMaskedFrame(OPCODE.pong, frame.payload))
        continue
      }
      if (frame.opcode !== OPCODE.binary) continue
      this.raw.push(frame.payload)
      if (!this.transport) continue
      const text = this.transport.receiveText(frame.payload)
      const parsed: unknown = JSON.parse(text)
      if (typeof parsed === 'object' && parsed !== null) this.inbox.push(parsed as ServerMessage)
    }
    this.wake()
  }

  /** The real Noise IK initiator half. */
  async handshake(hostPublicKey: Buffer): Promise<void> {
    const started = startHandshake(this.keys, hostPublicKey)
    this.sendRaw(withSealedVersion(started.message))
    await waitFor(() => this.raw.length > 0 || this.closed, 'the Mac’s handshake reply')
    const reply = this.raw.shift()
    if (!reply) throw new Error('the channel closed instead of answering the handshake')
    const opened = readSealedHandshake(reply, HANDSHAKE_REPLY_BYTES)
    if (!opened.ok) throw new Error(`the reply was ${opened.reason}`)
    this.transport = finishHandshake(started.pending, opened.message)
  }

  sendRaw(payload: Buffer): void {
    this.socket.write(encodeMaskedFrame(OPCODE.binary, payload))
  }

  send(message: ClientMessage): void {
    if (!this.transport) throw new Error('the phone has not finished its handshake')
    this.sendRaw(this.transport.send(Buffer.from(serialize(message), 'utf8')))
  }

  /** Wait for the first message matching `predicate`, consuming everything before it. */
  async until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage> {
    for (;;) {
      const at = this.inbox.findIndex(predicate)
      if (at !== -1) return this.inbox.splice(at, 1)[0]
      if (this.closed && this.inbox.length === 0) throw new Error(`the channel closed before ${label}`)
      await new Promise<void>((settle) => {
        const timer = setTimeout(settle, 25)
        this.waiting = () => {
          clearTimeout(timer)
          settle()
        }
      })
      if (Date.now() > this.deadline) throw new Error(`timed out waiting for ${label}`)
    }
  }

  private readonly deadline = Date.now() + 15_000

  seen(tag: ServerMessage['t']): boolean {
    return this.inbox.some((message) => message.t === tag)
  }
}

/* -------------------------------------------------------------- the Mac -- */

interface Harness {
  relay: RelayServer
  /** Where both ends dial. The gate's port when there is one. */
  port: number
  auth: RemoteAuth
  desk: ReturnType<typeof pairingDesk>
  endpoint: RemoteEndpoint
  sessions: Sessions
  identity: HostIdentity
  link: RelayLink
  hostId: string
  gate: Gate | null
}

async function listen(server: Server, port = 0): Promise<number> {
  await new Promise<void>((settle) => server.listen(port, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return address.port
}

interface Gate {
  port: number
  /** Every byte that crossed, in both directions, in arrival order. */
  seen: Buffer[]
  /** Kill every live connection and refuse new ones, the way a network does. */
  cut(): void
  /** Refuse new connections but leave the live ones alone — a wake with no wifi. */
  hold(): void
  /** Let connections through again. */
  resume(): void
}

/**
 * A length of wire between the two ends and the relay, that a test can cut.
 *
 * Node's `closeAllConnections` does not reach an upgraded socket — the server
 * stops tracking it the moment it emits `upgrade` — so it cannot simulate the
 * thing that actually happens to a laptop: the connection dying underneath a
 * link that still looks writable. This can, and it doubles as the tap that
 * proves the relay cannot read what it carries.
 */
async function gateTo(targetPort: number): Promise<Gate> {
  const seen: Buffer[] = []
  const live = new Set<Socket>()
  let open = true

  const proxy = createServer((client) => {
    if (!open) return client.destroy()
    const upstream = netConnect(targetPort, '127.0.0.1')
    live.add(client)
    live.add(upstream)
    client.on('data', (chunk: Buffer) => {
      seen.push(Buffer.from(chunk))
      upstream.write(chunk)
    })
    upstream.on('data', (chunk: Buffer) => {
      seen.push(Buffer.from(chunk))
      client.write(chunk)
    })
    const end = (): void => {
      live.delete(client)
      live.delete(upstream)
      client.destroy()
      upstream.destroy()
    }
    for (const socket of [client, upstream]) {
      socket.on('error', end)
      socket.on('close', end)
    }
  })
  closers.push(() => new Promise<void>((settle) => proxy.close(() => settle())))
  const port = await listen(proxy)

  return {
    port,
    seen,
    cut(): void {
      open = false
      for (const socket of [...live]) socket.destroy()
      live.clear()
    },
    hold(): void {
      open = false
    },
    resume(): void {
      open = true
    },
  }
}

/**
 * A relay and a Mac dialled into it, with the client's timings compressed.
 *
 * Everything else is the production wiring, including the two-way rule for who
 * may open a channel.
 */
async function mac(
  options: { gated?: boolean; now?: () => number; watchdogMs?: number } = {},
): Promise<Harness> {
  const relay = createRelayServer()
  closers.push(() => relay.close())
  const relayPort = await listen(relay.server)
  const gate = options.gated === true ? await gateTo(relayPort) : null
  const port = gate?.port ?? relayPort

  const dir = tempDir()
  const auth = new RemoteAuth(dir)
  const desk = pairingDesk(auth)
  const sessions = fakeSessions()
  const endpoint = createRemoteEndpoint({
    sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: join(dir, 'nowhere'),
    pingIntervalMs: 0,
  })
  const identity = loadHostIdentity(dir)

  const link = createRelayClient({
    url: `ws://127.0.0.1:${port}`,
    identity,
    isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    ...(options.now ? { now: options.now } : {}),
    // The sleep detector would fire on nothing here and the heartbeat is far
    // longer than any test; both are exercised by their own cases.
    watchdogMs: options.watchdogMs ?? 0,
  })
  closers.push(() => link.stop())
  link.start(endpoint.attachTransport)

  await waitFor(() => link.state().connected, 'the Mac to claim its host id at the relay')
  return { relay, port, auth, desk, endpoint, sessions, identity, link, hostId: identity.hostId, gate }
}

/** The part of a harness that pairing needs, so a caller can be less than a whole one. */
interface Pairable {
  desk: ReturnType<typeof pairingDesk>
  auth: RemoteAuth
  identity: HostIdentity
}

/** Pair a phone the way a person does: code on screen, phone redeems, human approves. */
async function pair(deck: Pairable, phone: Phone): Promise<string> {
  const code = deck.desk.create()
  await phone.handshake(deck.identity.keys.publicKey)
  phone.send({
    t: 'hello',
    protocol: 1,
    token: code.token,
    device: { name: DEVICE_NAME, platform: 'ios' },
  })
  const welcome = await phone.until((message) => message.t === 'welcome', 'the pairing welcome')
  if (welcome.t !== 'welcome' || welcome.token === null) throw new Error('no credential came back')
  deck.auth.approveDevice(welcome.deviceId)
  return welcome.token
}

/* ------------------------------------------------------------------ tests -- */

describe('the relay wire contract', () => {
  it('derives the same host id the relay routes on', () => {
    // Two implementations of one wire, which is only safe because this fails
    // the moment they disagree. The relay ships its own copy so it can be
    // deployed without the desktop tree.
    for (let i = 0; i < 8; i += 1) {
      const secret = secretBytes(32)
      expect(hostIdFor(secret)).toBe(relayHostIdFor(secret))
    }
  })

  it('refuses a relay URL that would send the host secret in clear text', () => {
    expect(relayTarget('ws://relay.example.com').ok).toBe(false)
    expect(relayTarget('http://relay.example.com').ok).toBe(false)
    expect(relayTarget('not a url').ok).toBe(false)
    expect(relayTarget('wss://relay.terminaldeck.dev').ok).toBe(true)
    // The one exception, and the only reason these tests can run at all.
    expect(relayTarget('ws://127.0.0.1:9000').ok).toBe(true)
    expect(relayTarget('ws://localhost:9000').ok).toBe(true)
  })

  it('takes the relay address from the environment over the built-in default', () => {
    expect(relayUrl({})).toBe('wss://relay.terminaldeck.dev')
    expect(relayUrl({}, 'wss://mine.example')).toBe('wss://mine.example')
    expect(relayUrl({ TERMINALDECK_RELAY_URL: 'wss://env.example' }, 'wss://mine.example')).toBe(
      'wss://env.example',
    )
    expect(relayEnabled({})).toBe(true)
    expect(relayEnabled({ TERMINALDECK_RELAY: 'off' })).toBe(false)
    expect(relayEnabled({ TERMINALDECK_RELAY: 'false' })).toBe(false)
    expect(relayEnabled({}, false)).toBe(false)
  })
})

describe('this Mac’s relay identity', () => {
  it('keeps the same host id and key across a restart', () => {
    const dir = tempDir()
    const first = loadHostIdentity(dir)
    const second = loadHostIdentity(dir)
    expect(second.hostId).toBe(first.hostId)
    expect(second.keys.publicKey.equals(first.keys.publicKey)).toBe(true)
    expect(second.keys.privateKey.equals(first.keys.privateKey)).toBe(true)
    expect(second.hostId).toBe(hostIdFor(first.hostSecret))
  })

  it('keeps the private key readable only by its owner', async () => {
    const dir = tempDir()
    loadHostIdentity(dir)
    const { statSync } = await import('node:fs')
    expect(statSync(join(dir, 'relay-identity.json')).mode & 0o777).toBe(0o600)
  })

  it('replaces an identity whose key pair does not agree, and keeps the old file', async () => {
    const dir = tempDir()
    const original = loadHostIdentity(dir)
    const file = join(dir, 'relay-identity.json')
    const { readdirSync, writeFileSync } = await import('node:fs')
    // A public key from somewhere else: the shape is right and the pair is not,
    // which otherwise fails as "handshake failed authentication" for every
    // phone in the world and looks exactly like an unpaired device.
    writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        hostSecret: original.hostSecret.toString('base64'),
        publicKey: generateStatic().publicKey.toString('base64'),
        privateKey: original.keys.privateKey.toString('base64'),
      }),
    )
    const replaced = loadHostIdentity(dir)
    expect(replaced.hostId).not.toBe(original.hostId)
    expect(readdirSync(dir).some((name) => name.includes('corrupt'))).toBe(true)
  })
})

describe('a phone reaching this Mac through the relay', () => {
  it('pairs, is approved, and then lists and attaches to a session', async () => {
    const deck = await mac()

    const first = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, first)
    // Pairing does not admit anything: the channel is refused and closed even
    // though the credential is real, because a human has not approved it yet.
    const refusal = await first.until((message) => message.t === 'error', 'the pending refusal')
    expect(refusal.t === 'error' && refusal.code).toBe('unauthorized')

    const phone = await Phone.open(deck.port, deck.hostId, first.keys)
    await phone.handshake(deck.identity.keys.publicKey)
    phone.send({ t: 'hello', protocol: 1, token: credential, device: { name: DEVICE_NAME, platform: 'ios' } })
    const welcome = await phone.until((message) => message.t === 'welcome', 'the welcome')
    expect(welcome.t === 'welcome' && welcome.sessions.map((session) => session.id)).toEqual([SESSION_ID])

    phone.send({ t: 'list' })
    const listed = await phone.until((message) => message.t === 'sessions', 'the session list')
    expect(listed.t === 'sessions' && listed.sessions[0].title).toBe('agent')

    phone.send({ t: 'attach', id: SESSION_ID })
    await phone.until((message) => message.t === 'attached', 'the attach')
    const replay = await phone.until(
      (message) => message.t === 'output' && message.replay === true,
      'the scrollback replay',
    )
    expect(replay.t === 'output' && replay.data).toBe(SCROLLBACK)

    // Live output after the replay, and a keystroke going the other way.
    deck.sessions.emit(LIVE_OUTPUT)
    const live = await phone.until(
      (message) => message.t === 'output' && message.replay === undefined,
      'live output',
    )
    expect(live.t === 'output' && live.data).toBe(LIVE_OUTPUT)

    phone.send({ t: 'input', id: SESSION_ID, data: KEYSTROKES })
    await waitFor(() => deck.sessions.typed.includes(KEYSTROKES), 'the keystroke to reach the session')

    // And the desktop can see it, with the relay named as where it came from.
    const connections = deck.endpoint.connections()
    expect(connections).toHaveLength(1)
    expect(connections[0].deviceName).toBe(DEVICE_NAME)
    expect(connections[0].address.startsWith('relay:')).toBe(true)
    expect(connections[0].sessionIds).toEqual([SESSION_ID])
  })

  it('refuses to hand a channel to a device it has never paired', async () => {
    const deck = await mac()
    // No pairing code on screen, and a key this Mac has never seen. The
    // handshake is refused before a reply exists, so the phone gets a closed
    // channel and no information at all.
    const phone = await Phone.open(deck.port, deck.hostId)
    await expect(phone.handshake(deck.identity.keys.publicKey)).rejects.toThrow(/closed/)
    expect(deck.endpoint.connections()).toEqual([])
  })

  it('refuses a device whose key was revoked, even with its credential', async () => {
    const deck = await mac()
    const first = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, first)
    const welcomeDevice = deck.auth.listDevices()[0]
    deck.auth.revokeDevice(welcomeDevice.id)

    const phone = await Phone.open(deck.port, deck.hostId, first.keys)
    // Revocation outranks everything, and it is enforced at the handshake: the
    // credential never gets a chance to be presented.
    await expect(phone.handshake(deck.identity.keys.publicKey)).rejects.toThrow(/closed/)
    expect(credential).toContain('.')
  })

  it('refuses a credential presented from a different device’s key', async () => {
    const deck = await mac()
    const owner = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, owner)

    // A second, separately paired and approved phone — so its key is known and
    // its handshake succeeds — presenting the first phone's stolen credential.
    const thief = await Phone.open(deck.port, deck.hostId)
    await pair(deck, thief)

    const attempt = await Phone.open(deck.port, deck.hostId, thief.keys)
    await attempt.handshake(deck.identity.keys.publicKey)
    attempt.send({ t: 'hello', protocol: 1, token: credential, device: { name: 'thief', platform: 'ios' } })
    const refusal = await attempt.until((message) => message.t === 'error', 'the refusal')
    expect(refusal.t === 'error' && refusal.code).toBe('unauthorized')
    expect(attempt.seen('welcome')).toBe(false)
  })

  it('lets go of a phone’s sessions when the relay link dies', async () => {
    const deck = await mac({ gated: true })
    const first = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, first)

    const phone = await Phone.open(deck.port, deck.hostId, first.keys)
    await phone.handshake(deck.identity.keys.publicKey)
    phone.send({ t: 'hello', protocol: 1, token: credential, device: { name: DEVICE_NAME, platform: 'ios' } })
    await phone.until((message) => message.t === 'welcome', 'the welcome')
    phone.send({ t: 'attach', id: SESSION_ID })
    await phone.until((message) => message.t === 'attached', 'the attach')
    expect(deck.endpoint.connections()[0].sessionIds).toEqual([SESSION_ID])

    // The link goes, and with it every channel it was carrying. A connection
    // left in the live map with its session still attached is the failure this
    // covers — it is what happened on the tailnet path before `end` was handled.
    deck.gate?.cut()
    await waitFor(() => deck.endpoint.connections().length === 0, 'the desktop to drop the phone')
  })
})

describe('the link to the relay', () => {
  it('comes back on its own after the relay drops it', async () => {
    const deck = await mac({ gated: true })
    expect(deck.relay.rendezvous.has(deck.hostId)).toBe(true)

    // Cut and held down, so the two halves of this are observable rather than a
    // race with a reconnect that is deliberately fast.
    deck.gate?.cut()
    await waitFor(() => !deck.link.state().connected, 'the Mac to notice the link died')
    expect(deck.relay.rendezvous.has(deck.hostId)).toBe(false)

    deck.gate?.resume()
    await waitFor(() => deck.link.state().connected, 'the Mac to dial back in')
    await waitFor(() => deck.relay.rendezvous.has(deck.hostId), 'the relay to have the host again')

    // And it is a working link, not merely an open socket: a phone paired
    // across the reconnect gets all the way to a welcome.
    const first = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, first)
    expect(credential).toContain('.')
  })

  it('keeps trying, and says why, when there is nothing to dial', async () => {
    // A port nothing is listening on: `mac()` cannot be used because it waits
    // for a connection that will never happen.
    const dir = tempDir()
    const auth = new RemoteAuth(dir)
    const identity = loadHostIdentity(dir)
    const spare = createServer()
    const port = await listen(spare)
    await new Promise<void>((settle) => spare.close(() => settle()))

    const link = createRelayClient({
      url: `ws://127.0.0.1:${port}`,
      identity,
      isKnownDevice: (key) => auth.knowsDeviceKey(key),
      baseBackoffMs: 20,
      maxBackoffMs: 40,
      watchdogMs: 0,
    })
    closers.push(() => link.stop())
    link.start(() => true)

    await waitFor(() => link.state().reason !== null, 'a reason for the failure')
    expect(link.state().connected).toBe(false)
    expect(link.state().reason).toMatch(/Could not reach the relay/)
    // Still trying, rather than having quietly given up.
    await waitFor(() => link.state().retryAt !== null, 'another attempt to be scheduled')
  })

  it('replaces the link when the Mac wakes up', async () => {
    // A lid closing leaves a socket that is dead and still looks writable, and
    // the wall clock is the only thing on the machine that noticed. The clock is
    // injected rather than faked globally so the timers below are real ones.
    let clock = Date.now()
    const deck = await mac({ gated: true, watchdogMs: 10, now: () => clock })

    // The wifi has not come back yet, so the redial fails and the drop is
    // visible instead of being papered over by an instant reconnect.
    deck.gate?.hold()
    clock += 10 * 60_000

    await waitFor(() => !deck.link.state().connected, 'the wake to replace a link that was asleep')
    deck.gate?.resume()
    await waitFor(() => deck.link.state().connected, 'the link to come back after the wake')
  })

  it('gives up on a relay that stops answering pings', async () => {
    // A link that accepts the upgrade and then goes silent is what a network
    // change looks like from this end: bytes leave, nothing comes back, and the
    // socket stays writable for minutes. Only the unanswered ping notices.
    const deaf = createServer((socket) => {
      socket.once('data', (chunk: Buffer) => {
        const key = /sec-websocket-key: (.+)\r\n/i.exec(chunk.toString('latin1'))?.[1] ?? ''
        socket.write(handshakeResponse(key.trim()))
      })
      socket.on('error', () => socket.destroy())
    })
    closers.push(() => new Promise<void>((settle) => deaf.close(() => settle())))
    const port = await listen(deaf)

    const dir = tempDir()
    const link = createRelayClient({
      url: `ws://127.0.0.1:${port}`,
      identity: loadHostIdentity(dir),
      isKnownDevice: () => false,
      baseBackoffMs: 5000,
      heartbeatMs: 25,
      watchdogMs: 0,
    })
    closers.push(() => link.stop())
    link.start(() => true)

    await waitFor(() => link.state().connected, 'the deaf relay to accept the upgrade')
    await waitFor(() => link.state().reason !== null, 'the ping to go unanswered')
    expect(link.state().reason).toMatch(/stopped answering pings/)
  })

  it('reports the identity a pairing code has to carry', async () => {
    const deck = await mac()
    const state = deck.link.state()
    expect(state.hostId).toBe(deck.hostId)
    expect(Buffer.from(state.publicKey, 'base64url').equals(deck.identity.keys.publicKey)).toBe(true)
    // Six groups of four, the form a person compares against their phone.
    expect(state.fingerprint).toMatch(/^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4})+$/)
    expect(state.connected).toBe(true)
    expect(state.reason).toBeNull()
  })

  it('stops dialling once remote access is switched off', async () => {
    const deck = await mac()
    deck.link.stop()
    await waitFor(() => !deck.relay.rendezvous.has(deck.hostId), 'the relay to forget this Mac')
    expect(deck.link.state().connected).toBe(false)
    // A stopped link stays stopped: nothing reschedules behind it.
    await new Promise((settle) => setTimeout(settle, 120))
    expect(deck.link.state().connected).toBe(false)
    expect(deck.link.state().retryAt).toBeNull()
  })
})

describe('remote access on a Mac with no Tailscale', () => {
  /**
   * The whole server, assembled the way `registerRemoteIpc` assembles it, with
   * the tailnet reporting the state a machine that has never installed
   * Tailscale is in.
   */
  async function serverWithoutTailnet(): Promise<{
    relay: RelayServer
    port: number
    server: ReturnType<typeof createRemoteServer>
    auth: RemoteAuth
    desk: ReturnType<typeof pairingDesk>
    identity: HostIdentity
  }> {
    const relay = createRelayServer()
    closers.push(() => relay.close())
    const port = await listen(relay.server)

    const dir = tempDir()
    const auth = new RemoteAuth(dir)
    const desk = pairingDesk(auth)
    const identity = loadHostIdentity(dir)
    const link = createRelayClient({
      url: `ws://127.0.0.1:${port}`,
      identity,
      isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
      baseBackoffMs: 20,
      watchdogMs: 0,
    })
    closers.push(() => link.stop())

    const server = createRemoteServer({
      sessions: fakeSessions(),
      auth: authenticatorFor(auth, desk),
      webRoot: join(dir, 'nowhere'),
      certDir: dir,
      pingIntervalMs: 0,
      readTailnet: async () => ({
        ready: false,
        state: 'not-installed',
        reason: BLOCKED_REASONS['not-installed'],
      }),
      serve: {
        on: async () => {
          throw new Error('nothing may ask Tailscale for a proxy when it is not installed')
        },
        off: async () => {},
      },
      relay: link,
    })
    closers.push(() => void server.stop())
    return { relay, port, server, auth, desk, identity }
  }

  it('starts, and says the tailnet is the faster route rather than the reason', async () => {
    const deck = await serverWithoutTailnet()
    const status = await deck.server.start()

    expect(status.running).toBe(true)
    // No listener means no URL: a relayed phone finds this Mac by host id, and
    // inventing an address here would put one on a screen that goes nowhere.
    expect(status.url).toBeNull()
    expect(status.directReason).toBe(BLOCKED_REASONS['not-installed'])
    expect(status.relay?.hostId).toBe(deck.identity.hostId)

    await waitFor(() => deck.server.status().relay?.connected === true, 'the relay to connect')
    expect(deck.server.status().reason).toBeNull()
  })

  it('carries a real pairing and a real attach with no tailnet anywhere', async () => {
    const deck = await serverWithoutTailnet()
    await deck.server.start()
    await waitFor(() => deck.server.status().relay?.connected === true, 'the relay to connect')

    const first = await Phone.open(deck.port, deck.identity.hostId)
    const credential = await pair(deck, first)

    const phone = await Phone.open(deck.port, deck.identity.hostId, first.keys)
    await phone.handshake(deck.identity.keys.publicKey)
    phone.send({ t: 'hello', protocol: 1, token: credential, device: { name: DEVICE_NAME, platform: 'ios' } })
    await phone.until((message) => message.t === 'welcome', 'the welcome')
    phone.send({ t: 'attach', id: SESSION_ID })
    await phone.until((message) => message.t === 'attached', 'the attach')
    expect(deck.server.connections()).toHaveLength(1)
  })

  it('stops the relay when remote access is switched off', async () => {
    const deck = await serverWithoutTailnet()
    await deck.server.start()
    await waitFor(() => deck.relay.rendezvous.has(deck.identity.hostId), 'the relay to hold the host')

    const stopped = await deck.server.stop()
    expect(stopped.running).toBe(false)
    expect(stopped.relay).toBeNull()
    // Not merely marked as stopped: the outbound link is a thing that dials
    // back in on its own, so it has to actually be told.
    await waitFor(() => !deck.relay.rendezvous.has(deck.identity.hostId), 'the relay to forget it')
  })
})

describe('what the relay can see', () => {
  it('carries a whole session without one readable byte of it', async () => {
    // Both ends dial through the gate, so what it records is exactly what a
    // relay operator — or anyone who has taken the relay — would have.
    const deck = await mac({ gated: true })

    const first = await Phone.open(deck.port, deck.hostId)
    const credential = await pair(deck, first)

    const phone = await Phone.open(deck.port, deck.hostId, first.keys)
    await phone.handshake(deck.identity.keys.publicKey)
    phone.send({ t: 'hello', protocol: 1, token: credential, device: { name: DEVICE_NAME, platform: 'ios' } })
    await phone.until((message) => message.t === 'welcome', 'the welcome')
    phone.send({ t: 'attach', id: SESSION_ID })
    await phone.until((message) => message.t === 'attached', 'the attach')
    await phone.until((message) => message.t === 'output', 'the scrollback')
    deck.sessions.emit(LIVE_OUTPUT)
    await phone.until(
      (message) => message.t === 'output' && message.replay === undefined,
      'live output',
    )
    phone.send({ t: 'input', id: SESSION_ID, data: KEYSTROKES })
    await waitFor(() => deck.sessions.typed.includes(KEYSTROKES), 'the keystroke to land')

    const wire = Buffer.concat(deck.gate?.seen ?? []).toString('latin1')

    // The positive control first: without this, a test that recorded nothing at
    // all would pass every assertion below.
    expect(wire).toContain('GET /v1/host')
    expect(wire).toContain(deck.hostId)
    expect(wire.length).toBeGreaterThan(1000)

    // And now the property the whole design rests on.
    for (const secret of [SCROLLBACK, KEYSTROKES, LIVE_OUTPUT, DEVICE_NAME, SESSION_ID, credential]) {
      expect(wire, `“${secret}” crossed the relay in the clear`).not.toContain(secret)
    }
    // Not the protocol's own shape either: a relay that can see `"t":"input"`
    // knows when someone is typing even if it cannot read what.
    for (const shape of ['"t":"', 'welcome', 'protocol', 'sessions']) {
      expect(wire, `the protocol’s ${shape} was legible`).not.toContain(shape)
    }
  })
})
