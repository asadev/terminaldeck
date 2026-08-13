/**
 * The rendezvous relay: how a phone reaches a Mac that is behind a router.
 *
 * ## What this is, in one paragraph
 *
 * A Mac at home has no reachable address. Rather than punch holes, the Mac
 * opens an outbound WebSocket to this service and leaves it open; a phone opens
 * one too, naming the Mac it wants; the service staples the two together and
 * copies bytes. Outbound-only on both sides means no NAT traversal, no STUN, no
 * TURN, no port forwarding, and nothing for a corporate firewall to object to
 * beyond ordinary HTTPS.
 *
 * ## This service is treated as hostile
 *
 * We run it, and that changes nothing about how much it is trusted. Everything
 * it carries is already sealed by `shared/sealed.ts` — a Noise IK channel whose
 * keys are established between the phone and the Mac, from key material this
 * process never sees. So the relay learns: that a host is online, that a device
 * connected to it, how many bytes went each way, and when. It cannot read a
 * command, cannot inject a keystroke, and cannot man-in-the-middle the
 * handshake without failing to decrypt on the very first frame.
 *
 * That is deliberate and it is the whole reason the design is acceptable. A
 * relay that could read the stream would be a single box whose compromise hands
 * over every user's shell. This one is a box whose compromise ends sessions.
 *
 * ## Claiming a host id without accounts
 *
 * There is no login here, because a login would mean a user database, which
 * would mean this service holds something worth stealing.
 *
 * Instead the Mac invents a random 32-byte `hostSecret` on first run and keeps
 * it. Its public name is `hostId = BASE32(SHA-256(hostSecret))`, which is what
 * goes in the pairing QR. To claim the name, the Mac presents the secret and
 * the relay hashes it — a preimage nobody else can produce. The relay stores
 * neither: the mapping lives only in memory, only while the socket is open.
 *
 * So an attacker who learns a `hostId` from a photographed QR code cannot
 * impersonate that Mac here, and an attacker who learns nothing cannot squat a
 * name. Nothing survives a restart, which is correct — every host reconnects.
 *
 * ## Multiplexing, and why the envelope exists
 *
 * A Mac holds exactly one socket no matter how many phones attach, so frames
 * for different phones share it and each needs a label. Hence a 17-byte
 * envelope on the host side only: one type byte, a 16-byte channel id, then the
 * opaque payload. The phone side is unwrapped — a phone has one channel and
 * does not need to be told its own name.
 *
 * The relay never parses the payload. It could not if it wanted to.
 */

import { createHash, randomBytes } from 'node:crypto'
import { createServer, type IncomingMessage, type Server } from 'node:http'
import type { Duplex } from 'node:stream'
import { FrameReader, OPCODE, encodeFrame, handshakeResponse } from '../../src/shared/ws-frame'

/* -------------------------------------------------------------------------- */
/* Envelope                                                                    */
/* -------------------------------------------------------------------------- */

export const ENVELOPE = { open: 0x01, data: 0x02, close: 0x03 } as const
export const CHANNEL_BYTES = 16
export const ENVELOPE_HEADER = 1 + CHANNEL_BYTES

/**
 * Largest relayed payload.
 *
 * The app caps its own messages at 64 KiB. Sealing adds a 16-byte tag, and the
 * relay adds the envelope, so the cap here is that plus room rather than the
 * same number — a limit that cuts off legal traffic is an outage, and one set
 * far above the real maximum is not a limit at all.
 */
export const MAX_PAYLOAD_BYTES = 96 * 1024

export function encodeEnvelope(type: number, channel: Buffer, payload: Buffer): Buffer {
  if (channel.length !== CHANNEL_BYTES) throw new Error('channel id must be 16 bytes')
  const header = Buffer.alloc(ENVELOPE_HEADER)
  header[0] = type
  channel.copy(header, 1)
  return Buffer.concat([header, payload])
}

export interface Envelope {
  type: number
  channel: Buffer
  payload: Buffer
}

export function decodeEnvelope(frame: Buffer): Envelope | null {
  if (frame.length < ENVELOPE_HEADER) return null
  const type = frame[0]
  if (type !== ENVELOPE.open && type !== ENVELOPE.data && type !== ENVELOPE.close) return null
  return {
    type,
    channel: Buffer.from(frame.subarray(1, ENVELOPE_HEADER)),
    payload: Buffer.from(frame.subarray(ENVELOPE_HEADER)),
  }
}

/* -------------------------------------------------------------------------- */
/* Host names                                                                  */
/* -------------------------------------------------------------------------- */

/** Same alphabet as the key fingerprints: no 0/O or 1/I to misread. */
const BASE32 = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function base32(bytes: Buffer, length: number): string {
  let bits = 0
  let value = 0
  let out = ''
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5) {
      bits -= 5
      out += BASE32[(value >> bits) & 31]
      if (out.length === length) return out
    }
  }
  return out
}

/**
 * The public name of a host, derived from a secret only that host holds.
 *
 * 26 characters is 130 bits, which is not a number anyone enumerates. It is
 * shorter than the full hash because it goes in a QR code and occasionally on a
 * screen next to it.
 */
export function hostIdFor(hostSecret: Buffer): string {
  return base32(createHash('sha256').update(hostSecret).digest(), 26)
}

/** Host ids are compared as fixed-length uppercase; anything else cannot be one. */
export function isHostId(value: string): boolean {
  return /^[A-HJ-NP-Z2-9]{26}$/.test(value)
}

/* -------------------------------------------------------------------------- */
/* Sockets                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * A WebSocket in the only shape the relay needs: binary in, binary out, closed.
 *
 * Binary rather than text because everything crossing here is ciphertext.
 * Base64 would cost a third of the bandwidth for the privilege of pretending it
 * is a string.
 */
class RelaySocket {
  private readonly reader = new FrameReader(MAX_PAYLOAD_BYTES + ENVELOPE_HEADER)
  private closed = false
  private awaitingPong = false
  private readonly heartbeat: NodeJS.Timeout | null

  constructor(
    private readonly socket: Duplex,
    private readonly onMessage: (payload: Buffer) => void,
    private readonly onClose: () => void,
    heartbeatMs: number,
  ) {
    // Keystrokes are one-byte writes; Nagle would hold each one waiting for an
    // ack and a relayed session would feel like a satellite link. Narrowed with
    // `in` because `Duplex` does not declare it — only the socket underneath does.
    if ('setNoDelay' in socket && typeof socket.setNoDelay === 'function') socket.setNoDelay(true)
    socket.on('data', (chunk: Buffer) => this.receive(chunk))
    socket.on('error', () => this.finish())
    socket.on('close', () => this.finish())
    // An upgraded socket whose peer vanishes delivers 'end' and then stays
    // writable forever; listening only for 'close' leaks a host slot per
    // disappeared phone. The app's own server learned this the hard way.
    socket.on('end', () => this.finish())

    // Zero turns it off, matching `pingIntervalMs` in the app's own server and
    // `heartbeatMs` in the relay client. It is not a hypothetical option:
    // `setInterval(fn, 0)` runs every tick, so pass zero expecting "no
    // heartbeat" and instead the first pass pings, the second sees an unanswered
    // ping and kills a healthy connection. One convention, honoured everywhere.
    this.heartbeat =
      heartbeatMs > 0
        ? setInterval(() => {
            if (this.closed) return
            if (this.awaitingPong) return this.finish()
            this.awaitingPong = true
            this.write(OPCODE.ping, Buffer.alloc(0))
          }, heartbeatMs)
        : null
    this.heartbeat?.unref?.()
  }

  send(payload: Buffer): void {
    this.write(OPCODE.binary, payload)
  }

  close(): void {
    if (this.closed) return
    this.write(OPCODE.close, Buffer.alloc(0))
    this.finish()
  }

  private write(opcode: number, payload: Buffer): void {
    if (this.closed) return
    try {
      this.socket.write(encodeFrame(opcode, payload))
    } catch {
      this.finish()
    }
  }

  private finish(): void {
    if (this.closed) return
    this.closed = true
    if (this.heartbeat) clearInterval(this.heartbeat)
    this.reader.reset()
    if (!this.socket.destroyed) this.socket.end()
    this.onClose()
  }

  private receive(chunk: Buffer): void {
    if (this.closed) return
    const batch = this.reader.push(chunk)
    for (const frame of batch.frames) {
      if (this.closed) return
      if (frame.opcode === OPCODE.close) return this.finish()
      if (frame.opcode === OPCODE.ping) {
        this.write(OPCODE.pong, frame.payload)
        continue
      }
      if (frame.opcode === OPCODE.pong) {
        this.awaitingPong = false
        continue
      }
      // Fragmentation is refused rather than reassembled: the relay would
      // otherwise buffer on behalf of a peer that has not proved anything, and
      // nothing on either side of this hop fragments.
      if (!frame.fin) return this.finish()
      if (frame.opcode === OPCODE.binary) this.onMessage(frame.payload)
      // Text frames are silently ignored rather than fatal — a browser dev
      // console poking the endpoint should not drop a real session.
    }
    if (!batch.ok) this.finish()
  }
}

/* -------------------------------------------------------------------------- */
/* The relay                                                                   */
/* -------------------------------------------------------------------------- */

interface Guest {
  channel: Buffer
  socket: RelaySocket
}

interface Host {
  id: string
  socket: RelaySocket
  guests: Map<string, Guest>
}

export interface RelayOptions {
  /** Sockets with nothing to say are pinged this often. */
  heartbeatMs?: number
  /** Most phones one Mac may have attached at once. */
  maxGuestsPerHost?: number
  /** Most Macs this process will hold. */
  maxHosts?: number
  now?: () => number
}

export interface RelayStats {
  hosts: number
  guests: number
}

/**
 * The routing table. Everything here is in memory and nothing is written down.
 */
export class Rendezvous {
  private readonly hosts = new Map<string, Host>()
  private readonly options: Required<RelayOptions>

  constructor(options: RelayOptions = {}) {
    this.options = {
      heartbeatMs: options.heartbeatMs ?? 30_000,
      maxGuestsPerHost: options.maxGuestsPerHost ?? 8,
      maxHosts: options.maxHosts ?? 5_000,
      now: options.now ?? Date.now,
    }
  }

  stats(): RelayStats {
    let guests = 0
    for (const host of this.hosts.values()) guests += host.guests.size
    return { hosts: this.hosts.size, guests }
  }

  has(hostId: string): boolean {
    return this.hosts.has(hostId)
  }

  /**
   * A Mac claims its name by proving it knows the preimage.
   *
   * A second connection for a live name replaces the first rather than being
   * refused: the common cause is the same Mac reconnecting after a network
   * change while the relay has not yet noticed the old socket is dead, and
   * refusing would lock a user out of their own machine until a timeout. Both
   * connections proved the same secret, so there is no impersonation to
   * prevent — the loser is told, and its guests are cut.
   */
  attachHost(hostSecret: Buffer, socket: Duplex): { ok: true; hostId: string } | { ok: false; reason: string } {
    if (hostSecret.length !== 32) return { ok: false, reason: 'host secret must be 32 bytes' }
    if (this.hosts.size >= this.options.maxHosts && !this.hosts.has(hostIdFor(hostSecret))) {
      return { ok: false, reason: 'relay is full' }
    }
    const id = hostIdFor(hostSecret)
    this.hosts.get(id)?.socket.close()

    const host: Host = {
      id,
      socket: null as unknown as RelaySocket,
      guests: new Map(),
    }
    host.socket = new RelaySocket(
      socket,
      (payload) => this.fromHost(host, payload),
      () => this.dropHost(host),
      this.options.heartbeatMs,
    )
    this.hosts.set(id, host)
    return { ok: true, hostId: id }
  }

  /** A phone asks for a Mac by name. It proves nothing here; the seal does that. */
  attachGuest(hostId: string, socket: Duplex): { ok: true } | { ok: false; reason: string } {
    const host = this.hosts.get(hostId)
    if (!host) return { ok: false, reason: 'that machine is not online' }
    if (host.guests.size >= this.options.maxGuestsPerHost) {
      return { ok: false, reason: 'that machine has too many connections' }
    }

    const channel = randomBytes(CHANNEL_BYTES)
    const key = channel.toString('hex')
    const guest: Guest = { channel, socket: null as unknown as RelaySocket }
    guest.socket = new RelaySocket(
      socket,
      (payload) => this.fromGuest(host, guest, payload),
      () => this.dropGuest(host, key),
      this.options.heartbeatMs,
    )
    host.guests.set(key, guest)
    host.socket.send(encodeEnvelope(ENVELOPE.open, channel, Buffer.alloc(0)))
    return { ok: true }
  }

  /** Host → relay: unwrap the envelope and hand the payload to one guest. */
  private fromHost(host: Host, frame: Buffer): void {
    const envelope = decodeEnvelope(frame)
    // A host that cannot speak the envelope is a bug or an impostor with the
    // secret; either way there is nothing useful to do with the frame.
    if (!envelope) return
    const key = envelope.channel.toString('hex')
    const guest = host.guests.get(key)
    if (!guest) return
    if (envelope.type === ENVELOPE.close) return guest.socket.close()
    if (envelope.payload.length > MAX_PAYLOAD_BYTES) return guest.socket.close()
    guest.socket.send(envelope.payload)
  }

  /** Guest → relay: wrap the payload and hand it to the host. */
  private fromGuest(host: Host, guest: Guest, payload: Buffer): void {
    if (payload.length > MAX_PAYLOAD_BYTES) return guest.socket.close()
    host.socket.send(encodeEnvelope(ENVELOPE.data, guest.channel, payload))
  }

  private dropGuest(host: Host, key: string): void {
    const guest = host.guests.get(key)
    if (!guest) return
    host.guests.delete(key)
    host.socket.send(encodeEnvelope(ENVELOPE.close, guest.channel, Buffer.alloc(0)))
  }

  private dropHost(host: Host): void {
    // Only forget the entry if it is still ours: a reconnect may already have
    // replaced it, and deleting then would evict the live host.
    if (this.hosts.get(host.id) === host) this.hosts.delete(host.id)
    for (const guest of host.guests.values()) guest.socket.close()
    host.guests.clear()
  }
}

/* -------------------------------------------------------------------------- */
/* HTTP surface                                                                */
/* -------------------------------------------------------------------------- */

const HOST_PATH = '/v1/host'
const GUEST_PATH = '/v1/join'

/**
 * The host secret travels in a header rather than the URL.
 *
 * Query strings end up in access logs, proxy logs and error reports as a matter
 * of routine. This one is a bearer secret, so it goes where logs do not
 * habitually reach.
 */
const SECRET_HEADER = 'x-deck-host-secret'

function refuse(socket: Duplex, status: number, message: string): void {
  socket.end(
    `HTTP/1.1 ${status} ${message}\r\n` +
      'Connection: close\r\n' +
      'Content-Length: 0\r\n' +
      '\r\n',
  )
}

function decodeSecret(raw: string | string[] | undefined): Buffer | null {
  if (typeof raw !== 'string') return null
  const bytes = Buffer.from(raw, 'base64url')
  return bytes.length === 32 ? bytes : null
}

export interface RelayServer {
  server: Server
  rendezvous: Rendezvous
  close(): Promise<void>
}

export function createRelayServer(options: RelayOptions = {}): RelayServer {
  const rendezvous = new Rendezvous(options)

  const server = createServer((req, res) => {
    // Deliberately almost nothing: this is not a website. `/healthz` exists so
    // a container platform can tell running from listening, and it reports
    // counts rather than identities — a health endpoint that listed host ids
    // would undo the point of not storing them.
    if (req.url === '/healthz') {
      const body = JSON.stringify({ ok: true, ...rendezvous.stats() })
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      return res.end(body)
    }
    res.writeHead(404, { 'content-type': 'text/plain' })
    res.end('not found\n')
  })

  server.on('upgrade', (req: IncomingMessage, socket: Duplex) => {
    const key = req.headers['sec-websocket-key']
    const version = String(req.headers['sec-websocket-version'] ?? '')
    if (typeof key !== 'string' || version !== '13') {
      return refuse(socket, 400, 'Bad Request')
    }

    const url = new URL(req.url ?? '/', 'http://relay.invalid')

    if (url.pathname === HOST_PATH) {
      const secret = decodeSecret(req.headers[SECRET_HEADER])
      if (!secret) return refuse(socket, 401, 'Unauthorized')
      socket.write(handshakeResponse(key))
      const claimed = rendezvous.attachHost(secret, socket)
      // The socket is already upgraded, so a refusal is a close rather than a
      // status code. Nothing is told to the client beyond the disconnect.
      if (!claimed.ok) socket.end()
      return
    }

    if (url.pathname === GUEST_PATH) {
      const hostId = url.searchParams.get('host') ?? ''
      if (!isHostId(hostId)) return refuse(socket, 400, 'Bad Request')
      // Answered identically whether the host exists or not, and only then
      // closed: a 404 here would turn the endpoint into an oracle for which
      // machines are online.
      socket.write(handshakeResponse(key))
      const joined = rendezvous.attachGuest(hostId, socket)
      if (!joined.ok) socket.end()
      return
    }

    refuse(socket, 404, 'Not Found')
  })

  return {
    server,
    rendezvous,
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve())
      }),
  }
}
