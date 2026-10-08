/**
 * The Receiver's front door: anything that can send an HTTP request — a
 * WhatsApp gateway, a CRM, GitHub, Sentry, a server's cron job — kept for a
 * Mac that may be asleep, then handed down the socket that Mac already holds
 * open. The relay knows no vendors: only how a sender proves itself.
 *
 *     POST https://relay.example/in/<sourceId>              (header proof)
 *     POST https://relay.example/in/<sourceId>/<token>      (for senders that only take a URL)
 *
 * ## What this process knows, and what it never knows
 *
 * A Mac registers its sources over its own authenticated host socket (frame
 * `sync`). Per source the relay keeps: the random source id, a hash tag of the
 * owning host id (never the id itself), how the sender proves itself (HMAC
 * signature, token, basic auth, or nothing beyond the unguessable address),
 * an optional IP allow-list, and for token and basic auth the SHA-256 of the
 * credential. **It never holds a source secret.** An HMAC key never leaves the
 * Mac, so the Mac checks every signature again end to end, and a relay that
 * was broken into still cannot forge a signed event.
 *
 * Every accepted delivery is **sealed to the Mac's receiver key** (X25519 +
 * HKDF-SHA256 + AES-256-GCM) the moment it is read. The queue — in memory, and
 * on disk only when `RECEIVER_DIR` is set — therefore holds bytes this process
 * cannot open. That is what "encrypted at rest" means here, and it costs the
 * relay no key management at all.
 *
 * ## What it checks at the door
 *
 * Shape, size, rate, the IP allow-list, and the proof it *can* check: a
 * credential's hash for token and basic sources; the presence of the signature
 * header for HMAC sources. Everything else is the Mac's job. Nothing here composes an answer from the request, and
 * nothing here prints: the path carries a credential for token sources.
 *
 * ## Backward compatibility
 *
 * A host that never sends `sync` — every Mac released before this — owns no
 * sources, so its addresses are a fast 404 and it is never sent a frame type it
 * does not know. Phones are untouched: guests never see these frames.
 */

import {
  createCipheriv,
  createHash,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from 'node:crypto'
import { BlockList, isIP } from 'node:net'
import { mkdirSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'

/* -------------------------------------------------------------------------- */
/* The wire (mirrored by the Mac in BackendRCVWire.swift)                      */
/* -------------------------------------------------------------------------- */

export const RECEIVER_ENVELOPE = { sync: 0x20, deliver: 0x21, ack: 0x22, synced: 0x23 } as const
export const RECEIVER_PREFIX = '/in/'
export const RECEIVER_MAX_BODY_BYTES = 80 * 1024
export const RECEIVER_MAX_HEADER_VALUE = 2048
export const RECEIVER_MAX_SOURCES_PER_HOST = 64
export const RECEIVER_MAX_SOURCES = 20_000
export const RECEIVER_RATE_PER_SOURCE = 60
export const RECEIVER_RATE_PER_HOST = 300
export const RECEIVER_MAX_QUEUED_PER_SOURCE = 200
export const RECEIVER_MAX_QUEUED_PER_HOST = 500
export const RECEIVER_MAX_QUEUED_BYTES_PER_HOST = 8 * 1024 * 1024
export const RECEIVER_MAX_QUEUED_BYTES = 64 * 1024 * 1024
export const RECEIVER_RETENTION_MS = 72 * 60 * 60 * 1000
export const RECEIVER_IN_FLIGHT = 16
export const RECEIVER_SEAL_INFO = 'td-receiver-seal-v1'
export const RECEIVER_HOST_TAG_PREFIX = 'td-receiver-host-v1:'
export const RECEIVER_ACK = { kept: 1, refused: 2, unknown: 3 } as const

const CHANNEL_BYTES = 16
const NO_CHANNEL = Buffer.alloc(CHANNEL_BYTES)
export const RECEIVER_AUTH = ['hmac', 'token', 'basic', 'none'] as const
type Auth = (typeof RECEIVER_AUTH)[number]
export const RECEIVER_MAX_IP_RULES = 32
export const RECEIVER_MAX_HEADERS = 64

/** Source ids are fixed-length uppercase base32, minted on the Mac. */
const SOURCE_ID = /^[A-HJ-NP-Z2-9]{26}$/
/** A token, as far as the relay can tell. The Mac mints 43-character base64url. */
const TOKEN_SHAPE = /^[A-Za-z0-9_-]{32,128}$/
/** A signature: printable ASCII, no spaces at the ends, bounded. Its meaning is the Mac's to judge. */
const SIGNATURE_SHAPE = /^[\x21-\x7e][\x20-\x7e]{6,1022}[\x21-\x7e]$/
const HEADER_NAME = /^[a-z0-9][a-z0-9-]{0,63}$/

/**
 * Headers that are never sealed or forwarded: the proxy's own, the connection's
 * own, and cookies. Every other header travels sealed, because a sender's
 * event type or delivery id may live in any header the Mac's mapping names.
 */
export const RECEIVER_DROPPED_HEADERS = new Set([
  'host', 'connection', 'keep-alive', 'content-length', 'transfer-encoding', 'te', 'trailer', 'upgrade',
  'cookie', 'set-cookie', 'forwarded', 'via', 'x-real-ip', 'proxy-authorization', 'proxy-connection',
])

/* -------------------------------------------------------------------------- */
/* Sealing                                                                     */
/* -------------------------------------------------------------------------- */

const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')

/**
 * Seal `plain` to a raw 32-byte X25519 public key.
 *
 * Output: ephemeral public key (32) ‖ nonce (12) ‖ ciphertext ‖ tag (16). The
 * key is HKDF-SHA256(shared, salt = ephemeral ‖ recipient, info = SEAL_INFO).
 * `aad` binds the blob to its delivery so one cannot be swapped for another.
 */
export function sealTo(recipient: Buffer, plain: Buffer, aad: Buffer): Buffer {
  if (recipient.length !== 32) throw new Error('receiver key must be 32 bytes')
  const ephemeral = generateKeyPairSync('x25519')
  const ephemeralRaw = ephemeral.publicKey.export({ format: 'der', type: 'spki' }).subarray(X25519_SPKI_PREFIX.length)
  const peer = createPublicKey({ key: Buffer.concat([X25519_SPKI_PREFIX, recipient]), format: 'der', type: 'spki' })
  const shared = diffieHellman({ privateKey: ephemeral.privateKey, publicKey: peer })
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralRaw, recipient]), RECEIVER_SEAL_INFO, 32))
  const nonce = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', key, nonce)
  cipher.setAAD(aad)
  const body = Buffer.concat([cipher.update(plain), cipher.final()])
  return Buffer.concat([ephemeralRaw, nonce, body, cipher.getAuthTag()])
}

export function sealAAD(sourceId: string, deliveryId: Buffer, receivedAt: number): Buffer {
  return Buffer.from(`${sourceId}.${deliveryId.toString('hex')}.${receivedAt}`, 'utf8')
}

/** `[u16 length][JSON head][rest]`, the same framing the MCP route uses. */
export function withHead(head: unknown, rest: Buffer): Buffer {
  const json = Buffer.from(JSON.stringify(head), 'utf8')
  if (json.length > 0xffff) throw new Error('head too large')
  const length = Buffer.alloc(2)
  length.writeUInt16BE(json.length, 0)
  return Buffer.concat([length, json, rest])
}

export function readHead(payload: Buffer): { head: Record<string, unknown>; rest: Buffer } | null {
  if (payload.length < 2) return null
  const length = payload.readUInt16BE(0)
  if (payload.length < 2 + length) return null
  try {
    const head = JSON.parse(payload.subarray(2, 2 + length).toString('utf8'))
    if (typeof head !== 'object' || head === null || Array.isArray(head)) return null
    return { head: head as Record<string, unknown>, rest: Buffer.from(payload.subarray(2 + length)) }
  } catch {
    return null
  }
}

export function encodeFrame(type: number, channel: Buffer, payload: Buffer): Buffer {
  const header = Buffer.alloc(1 + CHANNEL_BYTES)
  header[0] = type
  channel.copy(header, 1, 0, CHANNEL_BYTES)
  return Buffer.concat([header, payload])
}

export function isReceiverFrame(type: number): boolean {
  return type >= RECEIVER_ENVELOPE.sync && type <= RECEIVER_ENVELOPE.synced
}

export function hostTagFor(hostId: string): string {
  return createHash('sha256').update(RECEIVER_HOST_TAG_PREFIX + hostId).digest('hex')
}

function sha256(value: string): Buffer {
  return createHash('sha256').update(value, 'utf8').digest()
}

/* -------------------------------------------------------------------------- */
/* State                                                                       */
/* -------------------------------------------------------------------------- */

interface Source {
  id: string
  hostTag: string
  auth: Auth
  /** SHA-256 of the token, or of `user:password` for basic auth. */
  secretHash: Buffer | null
  /** Where a token may also arrive, besides the path and a bearer header. */
  tokenHeader: string | null
  /** The header an HMAC sender signs into. */
  signatureHeader: string | null
  ipAllow: string[]
  ipList: BlockList | null
  enabled: boolean
  sealKey: Buffer
  hits: number[]
}

interface Queued {
  id: Buffer
  key: string
  sourceId: string
  hostTag: string
  receivedAt: number
  sealed: Buffer
}

interface Connection {
  send(frame: Buffer): void
}

interface HostState {
  connection: Connection | null
  synced: boolean
  hits: number[]
  inFlight: Set<string>
}

export type ReceiverAdmission = 'ok' | 'unknown' | 'rate' | 'full'
export type ReceiverVerdict = 'ok' | 'unknown' | 'unauthorized' | 'full'

export interface ReceiverOptions {
  /** Where the source list and sealed queue survive a restart. Unset: memory only. */
  dir?: string | null
  now?: () => number
}

export interface ReceiverStats {
  sources: number
  queued: number
  queuedBytes: number
}

export interface ReceiverRequest {
  method: string
  /** Lowercased names, single string values. */
  headers: Record<string, string>
  body: Buffer
  pathToken: string | null
  /** The sender's address as the proxy saw it, or null when unknown. */
  clientIp: string | null
}

/**
 * Sources, their queues, and the hosts currently able to take deliveries.
 *
 * No timers: expiry is checked whenever a delivery is accepted or a host
 * syncs, which is the only time an old entry can matter.
 */
export class ReceiverHub {
  private readonly sources = new Map<string, Source>()
  private readonly hosts = new Map<string, HostState>()
  private readonly queue = new Map<string, Queued>()
  private queuedBytes = 0
  private readonly now: () => number
  private readonly dir: string | null

  constructor(options: ReceiverOptions = {}) {
    this.now = options.now ?? Date.now
    this.dir = options.dir ?? null
    if (this.dir) this.load()
  }

  stats(): ReceiverStats {
    return { sources: this.sources.size, queued: this.queue.size, queuedBytes: this.queuedBytes }
  }

  /* ------------------------------------------------------------ hosts -- */

  /** The rendezvous calls this when a host socket is claimed. Nothing is sent until it syncs. */
  hostJoined(hostId: string, connection: Connection): void {
    const tag = hostTagFor(hostId)
    const state = this.host(tag)
    state.connection = connection
    state.synced = false
    state.inFlight.clear()
  }

  /** Only the connection that joined may leave: a reconnect may already have replaced it. */
  hostLeft(hostId: string, connection: Connection): void {
    const state = this.hosts.get(hostTagFor(hostId))
    if (!state || state.connection !== connection) return
    state.connection = null
    state.synced = false
    state.inFlight.clear()
  }

  /** Host → relay. Unreadable frames are dropped, as the rendezvous does with its own. */
  fromHost(hostId: string, connection: Connection, frame: Buffer): void {
    if (frame.length < 1 + CHANNEL_BYTES) return
    const tag = hostTagFor(hostId)
    const state = this.hosts.get(tag)
    if (!state || state.connection !== connection) return
    const type = frame[0]
    const channel = frame.subarray(1, 1 + CHANNEL_BYTES)
    const payload = frame.subarray(1 + CHANNEL_BYTES)
    if (type === RECEIVER_ENVELOPE.sync) return this.sync(tag, state, payload)
    if (type === RECEIVER_ENVELOPE.ack) return this.ack(tag, state, channel, payload)
  }

  private host(tag: string): HostState {
    let state = this.hosts.get(tag)
    if (!state) {
      state = { connection: null, synced: false, hits: [], inFlight: new Set() }
      this.hosts.set(tag, state)
    }
    return state
  }

  /**
   * The host's complete list of sources. Declarative: anything it no longer
   * lists is forgotten, along with whatever was queued for it.
   */
  private sync(tag: string, state: HostState, payload: Buffer): void {
    let message: unknown
    try {
      message = JSON.parse(payload.toString('utf8'))
    } catch {
      return
    }
    if (typeof message !== 'object' || message === null) return
    const record = message as Record<string, unknown>
    if (record.v !== 1 || typeof record.sealKey !== 'string' || !Array.isArray(record.sources)) return
    const sealKey = Buffer.from(record.sealKey, 'base64url')
    if (sealKey.length !== 32) return

    const accepted: string[] = []
    const refused: { id: string; reason: string }[] = []
    const listed = new Set<string>()
    for (const raw of record.sources.slice(0, 256)) {
      const parsed = parseSourceDeclaration(raw)
      const id = typeof (raw as Record<string, unknown>)?.id === 'string' ? String((raw as Record<string, unknown>).id) : ''
      if (!parsed) {
        if (SOURCE_ID.test(id)) refused.push({ id, reason: 'invalid' })
        continue
      }
      if (listed.has(parsed.id)) continue
      const existing = this.sources.get(parsed.id)
      if (existing && existing.hostTag !== tag) {
        refused.push({ id: parsed.id, reason: 'taken' })
        continue
      }
      if (listed.size >= RECEIVER_MAX_SOURCES_PER_HOST || (!existing && this.sources.size >= RECEIVER_MAX_SOURCES)) {
        refused.push({ id: parsed.id, reason: 'limit' })
        continue
      }
      listed.add(parsed.id)
      this.sources.set(parsed.id, { ...parsed, hostTag: tag, sealKey, hits: existing?.hits ?? [] })
      accepted.push(parsed.id)
    }
    for (const source of [...this.sources.values()]) {
      if (source.hostTag === tag && !listed.has(source.id)) this.forget(source.id)
    }
    this.persistSources()
    this.prune()
    state.synced = true
    state.connection?.send(
      encodeFrame(RECEIVER_ENVELOPE.synced, NO_CHANNEL, Buffer.from(JSON.stringify({ v: 1, accepted, refused, queued: this.queuedFor(tag) }))),
    )
    this.pump(tag)
  }

  private ack(tag: string, state: HostState, channel: Buffer, payload: Buffer): void {
    const key = channel.toString('hex')
    const entry = this.queue.get(key)
    if (!entry || entry.hostTag !== tag) return
    if (payload.length < 1 || payload[0] < RECEIVER_ACK.kept || payload[0] > RECEIVER_ACK.unknown) return
    state.inFlight.delete(key)
    this.drop(key)
    this.pump(tag)
  }

  private forget(sourceId: string): void {
    this.sources.delete(sourceId)
    for (const [key, entry] of [...this.queue]) if (entry.sourceId === sourceId) this.drop(key)
  }

  /* ---------------------------------------------------------- inbound -- */

  /** Before a byte of the body is read: is there anyone to keep it for, and room? */
  admit(sourceId: string): ReceiverAdmission {
    const source = this.sources.get(sourceId)
    if (!source || !source.enabled) return 'unknown'
    const at = this.now()
    if (!take(source.hits, RECEIVER_RATE_PER_SOURCE, at)) return 'rate'
    const host = this.host(source.hostTag)
    if (!take(host.hits, RECEIVER_RATE_PER_HOST, at)) return 'rate'
    this.prune()
    if (!this.hasRoom(source, 0)) return 'full'
    return 'ok'
  }

  /** Check what the relay can check, seal, queue, and pass on if the host is there. */
  accept(sourceId: string, request: ReceiverRequest): ReceiverVerdict {
    const source = this.sources.get(sourceId)
    if (!source || !source.enabled) return 'unknown'
    if (!doorProof(source, request)) return 'unauthorized'
    const headers = forwardedHeaders(request.headers)
    if (!this.hasRoom(source, request.body.length + 4096)) return 'full'

    const id = randomBytes(CHANNEL_BYTES)
    const receivedAt = this.now()
    const plain = withHead(
      { v: 1, method: request.method, headers, pathToken: request.pathToken, clientIp: request.clientIp },
      request.body,
    )
    const sealed = sealTo(source.sealKey, plain, sealAAD(sourceId, id, receivedAt))
    const entry: Queued = { id, key: id.toString('hex'), sourceId, hostTag: source.hostTag, receivedAt, sealed }
    this.queue.set(entry.key, entry)
    this.queuedBytes += sealed.length
    this.spool(entry)
    this.pump(source.hostTag)
    return 'ok'
  }

  private hasRoom(source: Source, bytes: number): boolean {
    let perSource = 0
    let perHost = 0
    let hostBytes = 0
    for (const entry of this.queue.values()) {
      if (entry.hostTag !== source.hostTag) continue
      perHost += 1
      hostBytes += entry.sealed.length
      if (entry.sourceId === source.id) perSource += 1
    }
    return (
      perSource < RECEIVER_MAX_QUEUED_PER_SOURCE &&
      perHost < RECEIVER_MAX_QUEUED_PER_HOST &&
      hostBytes + bytes <= RECEIVER_MAX_QUEUED_BYTES_PER_HOST &&
      this.queuedBytes + bytes <= RECEIVER_MAX_QUEUED_BYTES
    )
  }

  private queuedFor(tag: string): number {
    let count = 0
    for (const entry of this.queue.values()) if (entry.hostTag === tag) count += 1
    return count
  }

  /** Send what is waiting, oldest first, up to the in-flight window. */
  private pump(tag: string): void {
    const state = this.hosts.get(tag)
    if (!state || !state.connection || !state.synced) return
    for (const entry of this.queue.values()) {
      if (state.inFlight.size >= RECEIVER_IN_FLIGHT) return
      if (entry.hostTag !== tag || state.inFlight.has(entry.key)) continue
      state.inFlight.add(entry.key)
      const head = { v: 1, sourceId: entry.sourceId, receivedAt: entry.receivedAt }
      state.connection.send(encodeFrame(RECEIVER_ENVELOPE.deliver, entry.id, withHead(head, entry.sealed)))
    }
  }

  private prune(): void {
    const cutoff = this.now() - RECEIVER_RETENTION_MS
    for (const [key, entry] of [...this.queue]) {
      if (entry.receivedAt < cutoff || !this.sources.has(entry.sourceId)) this.drop(key)
    }
  }

  private drop(key: string): void {
    const entry = this.queue.get(key)
    if (!entry) return
    this.queue.delete(key)
    this.queuedBytes -= entry.sealed.length
    for (const host of this.hosts.values()) host.inFlight.delete(key)
    if (this.dir) {
      try {
        unlinkSync(join(this.dir, 'spool', `${key}.bin`))
      } catch {
        // Already gone. Nothing else could have removed it but a restart race.
      }
    }
  }

  /* ------------------------------------------------------- persistence -- */

  private persistSources(): void {
    if (!this.dir) return
    const sources = [...this.sources.values()].map((s) => ({
      id: s.id,
      hostTag: s.hostTag,
      auth: s.auth,
      secretHash: s.secretHash?.toString('hex') ?? null,
      tokenHeader: s.tokenHeader,
      signatureHeader: s.signatureHeader,
      ipAllow: s.ipAllow,
      enabled: s.enabled,
      sealKey: s.sealKey.toString('base64url'),
    }))
    atomicWrite(join(this.dir, 'receiver-sources.json'), Buffer.from(JSON.stringify({ v: 1, sources })))
  }

  private spool(entry: Queued): void {
    if (!this.dir) return
    const meta = { sourceId: entry.sourceId, hostTag: entry.hostTag, receivedAt: entry.receivedAt }
    atomicWrite(join(this.dir, 'spool', `${entry.key}.bin`), withHead(meta, entry.sealed))
  }

  /**
   * Read back what survived a restart. Anything unreadable is removed rather
   * than trusted: a half-written file must never become a delivery.
   */
  private load(): void {
    const dir = this.dir as string
    mkdirSync(join(dir, 'spool'), { recursive: true, mode: 0o700 })
    try {
      const saved = JSON.parse(readFileSync(join(dir, 'receiver-sources.json'), 'utf8')) as { v?: number; sources?: unknown[] }
      if (saved.v === 1 && Array.isArray(saved.sources)) {
        for (const raw of saved.sources.slice(0, RECEIVER_MAX_SOURCES)) {
          const parsed = parseSourceDeclaration(raw)
          const record = raw as Record<string, unknown>
          if (!parsed || typeof record.hostTag !== 'string' || !/^[0-9a-f]{64}$/.test(record.hostTag)) continue
          const sealKey = Buffer.from(String(record.sealKey ?? ''), 'base64url')
          if (sealKey.length !== 32) continue
          this.sources.set(parsed.id, { ...parsed, hostTag: record.hostTag, sealKey, hits: [] })
        }
      }
    } catch {
      // No saved list yet, or an unreadable one: start empty. Hosts re-sync on connect.
    }
    const cutoff = this.now() - RECEIVER_RETENTION_MS
    for (const name of readdirSync(join(dir, 'spool'))) {
      const path = join(dir, 'spool', name)
      const match = /^([0-9a-f]{32})\.bin$/.exec(name)
      let keep = false
      if (match) {
        try {
          const parsed = readHead(readFileSync(path))
          const head = parsed?.head
          const source = typeof head?.sourceId === 'string' ? this.sources.get(head.sourceId) : undefined
          if (parsed && head && source && head.hostTag === source.hostTag && typeof head.receivedAt === 'number' && head.receivedAt >= cutoff) {
            const entry: Queued = {
              id: Buffer.from(match[1], 'hex'),
              key: match[1],
              sourceId: source.id,
              hostTag: source.hostTag,
              receivedAt: head.receivedAt,
              sealed: parsed.rest,
            }
            if (this.hasRoom(source, entry.sealed.length)) {
              this.queue.set(entry.key, entry)
              this.queuedBytes += entry.sealed.length
              keep = true
            }
          }
        } catch {
          keep = false
        }
      }
      if (!keep) {
        try {
          unlinkSync(path)
        } catch {
          // Leave it; the next start tries again.
        }
      }
    }
  }
}

function atomicWrite(path: string, data: Buffer): void {
  const temporary = `${path}.${randomBytes(6).toString('hex')}.tmp`
  writeFileSync(temporary, data, { mode: 0o600 })
  renameSync(temporary, path)
}

/** A host's declaration of one source, or null when any part of it is not exactly right. */
function parseSourceDeclaration(raw: unknown): Omit<Source, 'hostTag' | 'sealKey' | 'hits'> | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const id = record.id
  const auth = record.auth
  if (typeof id !== 'string' || !SOURCE_ID.test(id)) return null
  if (typeof auth !== 'string' || !(RECEIVER_AUTH as readonly string[]).includes(auth)) return null
  let secretHash: Buffer | null = null
  if (auth === 'token' || auth === 'basic') {
    if (typeof record.secretHash !== 'string' || !/^[0-9a-f]{64}$/.test(record.secretHash)) return null
    secretHash = Buffer.from(record.secretHash, 'hex')
  }
  const header = (value: unknown): string | null | false => {
    if (value === undefined || value === null) return null
    return typeof value === 'string' && HEADER_NAME.test(value) && !RECEIVER_DROPPED_HEADERS.has(value) ? value : false
  }
  const tokenHeader = header(record.tokenHeader)
  const signatureHeader = header(record.signatureHeader)
  if (tokenHeader === false || signatureHeader === false) return null
  if (auth === 'hmac' && !signatureHeader) return null
  const ipAllow = record.ipAllow ?? []
  if (!Array.isArray(ipAllow) || ipAllow.length > RECEIVER_MAX_IP_RULES) return null
  let ipList: BlockList | null = null
  if (ipAllow.length > 0) {
    ipList = new BlockList()
    for (const entry of ipAllow) {
      if (typeof entry !== 'string' || !addIpRule(ipList, entry)) return null
    }
  }
  return {
    id,
    auth: auth as Auth,
    secretHash,
    tokenHeader,
    signatureHeader,
    ipAllow: ipAllow as string[],
    ipList,
    enabled: record.enabled !== false,
  }
}

/** `203.0.113.7`, `2001:db8::1`, `203.0.113.0/24` or `2001:db8::/32`. */
function addIpRule(list: BlockList, entry: string): boolean {
  const [address, prefix, extra] = entry.split('/')
  if (extra !== undefined) return false
  const family = isIP(address)
  if (family === 0) return false
  const type = family === 4 ? 'ipv4' : 'ipv6'
  if (prefix === undefined) {
    list.addAddress(address, type)
    return true
  }
  if (!/^\d{1,3}$/.test(prefix)) return false
  const bits = Number(prefix)
  if (bits > (family === 4 ? 32 : 128)) return false
  list.addSubnet(address, bits, type)
  return true
}

function forwardedHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {}
  let count = 0
  for (const [name, value] of Object.entries(headers)) {
    if (count >= RECEIVER_MAX_HEADERS) break
    if (RECEIVER_DROPPED_HEADERS.has(name) || name.startsWith('x-forwarded-') || !HEADER_NAME.test(name)) continue
    if (typeof value !== 'string' || value.length > RECEIVER_MAX_HEADER_VALUE) continue
    out[name] = value
    count += 1
  }
  return out
}

/** Sliding window, as the MCP route keeps: a bucket would let a loop run at its average forever. */
function take(hits: number[], limit: number, at: number): boolean {
  while (hits.length > 0 && hits[0] <= at - 60_000) hits.shift()
  if (hits.length >= limit) return false
  hits.push(at)
  return true
}

function presentedToken(source: Source, request: ReceiverRequest): string | null {
  if (request.pathToken !== null) return request.pathToken
  const bearer = /^Bearer ([A-Za-z0-9_-]{32,128})$/.exec(request.headers.authorization ?? '')
  if (bearer) return bearer[1]
  const header = request.headers[source.tokenHeader ?? 'x-receiver-secret']
  if (typeof header === 'string' && TOKEN_SHAPE.test(header)) return header
  return null
}

function presentedBasic(request: ReceiverRequest): string | null {
  const match = /^Basic ([A-Za-z0-9+/=]{4,512})$/.exec(request.headers.authorization ?? '')
  if (!match) return null
  const decoded = Buffer.from(match[1], 'base64').toString('utf8')
  return decoded.includes(':') ? decoded : null
}

/**
 * The proof the relay is able to judge. For HMAC sources that is the presence
 * of the signature only; the Mac, which alone holds the key, does the real check.
 */
function doorProof(source: Source, request: ReceiverRequest): boolean {
  if (source.ipList) {
    const ip = request.clientIp
    if (!ip) return false
    const family = isIP(ip)
    if (family === 0 || !source.ipList.check(ip, family === 4 ? 'ipv4' : 'ipv6')) return false
  }
  switch (source.auth) {
    case 'token': {
      const token = presentedToken(source, request)
      return token !== null && source.secretHash !== null && timingSafeEqual(sha256(token), source.secretHash)
    }
    case 'basic': {
      const pair = presentedBasic(request)
      return pair !== null && source.secretHash !== null && timingSafeEqual(sha256(pair), source.secretHash)
    }
    case 'hmac':
      return SIGNATURE_SHAPE.test(request.headers[source.signatureHeader ?? ''] ?? '')
    case 'none':
      return true
  }
}

const PRIVATE_PROXY = /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|::1$|f[cd][0-9a-f]{2}:)/i

/**
 * The sender's address. Behind the proxy the socket's peer is the proxy, which
 * appends the real peer to `x-forwarded-for` (and, in this deployment, removes
 * anything a client tried to put there itself), so its last entry is the one
 * to believe — and only when the socket really is from a private address.
 */
export function clientIpOf(remote: string | undefined, forwardedFor: string | undefined): string | null {
  const peer = (remote ?? '').replace(/^::ffff:/, '')
  if (!peer) return null
  if (PRIVATE_PROXY.test(peer) && forwardedFor) {
    const last = forwardedFor.split(',').pop()?.trim().replace(/^::ffff:/, '') ?? ''
    return isIP(last) ? last : null
  }
  return isIP(peer) ? peer : null
}

/* -------------------------------------------------------------------------- */
/* The HTTP half                                                               */
/* -------------------------------------------------------------------------- */

/** `/in/<sourceId>` or `/in/<sourceId>/<token>`, a trailing slash forgiven. */
export function parseReceiverPath(pathname: string): { sourceId: string; pathToken: string | null } | null {
  if (!pathname.startsWith(RECEIVER_PREFIX)) return null
  const parts = pathname.slice(RECEIVER_PREFIX.length).replace(/\/$/, '').split('/')
  if (parts.length === 0 || parts.length > 2) return null
  const [sourceId, pathToken] = parts
  if (!SOURCE_ID.test(sourceId)) return null
  if (pathToken !== undefined && !TOKEN_SHAPE.test(pathToken)) return null
  return { sourceId, pathToken: pathToken ?? null }
}

const COMMON_HEADERS = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } as const

/** Fixed sentences. None may ever be composed from the request. */
export const RECEIVER_BODIES = {
  received: '{"ok":true,"message":"Received."}',
  notActive: '{"ok":false,"message":"This Receiver address is not active."}',
  onlyPost: '{"ok":false,"message":"This Receiver address only takes POST or PUT."}',
  tooLarge: '{"ok":false,"message":"That delivery is larger than the Receiver accepts."}',
  tooMany: '{"ok":false,"message":"Too many deliveries for this address right now. Try again in a minute."}',
  full: '{"ok":false,"message":"The Receiver is holding as much as it can for this computer. Try again later."}',
  unauthorized: '{"ok":false,"message":"The delivery could not be verified."}',
} as const

function answer(res: ServerResponse, status: number, body: string, extra: Record<string, string> = {}): void {
  if (res.headersSent || res.writableEnded || res.destroyed) return
  res.writeHead(status, { 'content-type': 'application/json', ...COMMON_HEADERS, ...extra })
  res.end(body)
}

function lowerHeaders(req: IncomingMessage): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [name, value] of Object.entries(req.headers)) {
    if (typeof value === 'string') out[name] = value
    else if (Array.isArray(value) && typeof value[0] === 'string') out[name] = value.join(', ')
  }
  return out
}

/**
 * Handle one HTTP request, or say it was not ours. Returns false for any path
 * outside `/in/`, so every other answer the relay gives is unchanged.
 */
export function handleReceiverHttp(req: IncomingMessage, res: ServerResponse, hub: ReceiverHub): boolean {
  // The query is dropped unread: a token passed as `?token=` would be one in a place proxies log.
  const pathname = (req.url ?? '/').split('?')[0]
  if (!pathname.startsWith(RECEIVER_PREFIX)) return false

  const target = parseReceiverPath(pathname)
  if (!target) {
    answer(res, 404, RECEIVER_BODIES.notActive)
    return true
  }
  if (req.method !== 'POST' && req.method !== 'PUT') {
    answer(res, 405, RECEIVER_BODIES.onlyPost, { allow: 'POST, PUT' })
    return true
  }

  const admitted = hub.admit(target.sourceId)
  if (admitted === 'unknown') {
    answer(res, 404, RECEIVER_BODIES.notActive)
    return true
  }
  if (admitted === 'rate') {
    answer(res, 429, RECEIVER_BODIES.tooMany, { 'retry-after': '60' })
    return true
  }
  if (admitted === 'full') {
    answer(res, 503, RECEIVER_BODIES.full, { 'retry-after': '300' })
    return true
  }

  const declared = Number(req.headers['content-length'] ?? 'NaN')
  if (Number.isFinite(declared) && declared > RECEIVER_MAX_BODY_BYTES) {
    answer(res, 413, RECEIVER_BODIES.tooLarge, { connection: 'close' })
    res.once('finish', () => req.socket.destroy())
    return true
  }

  const chunks: Buffer[] = []
  let size = 0
  let settled = false
  req.on('data', (chunk: Buffer) => {
    if (settled) return
    size += chunk.length
    if (size > RECEIVER_MAX_BODY_BYTES) {
      settled = true
      answer(res, 413, RECEIVER_BODIES.tooLarge, { connection: 'close' })
      res.once('finish', () => req.socket.destroy())
      return
    }
    chunks.push(chunk)
  })
  req.on('error', () => {
    if (settled) return
    settled = true
    res.destroy()
  })
  req.on('end', () => {
    if (settled) return
    settled = true
    let verdict: ReceiverVerdict
    try {
      const forwardedFor = req.headers['x-forwarded-for']
      verdict = hub.accept(target.sourceId, {
        method: req.method ?? 'POST',
        headers: lowerHeaders(req),
        body: Buffer.concat(chunks),
        pathToken: target.pathToken,
        clientIp: clientIpOf(req.socket.remoteAddress, Array.isArray(forwardedFor) ? forwardedFor.join(',') : forwardedFor),
      })
    } catch {
      verdict = 'full'
    }
    if (verdict === 'ok') answer(res, 202, RECEIVER_BODIES.received)
    else if (verdict === 'unauthorized') answer(res, 401, RECEIVER_BODIES.unauthorized)
    else if (verdict === 'unknown') answer(res, 404, RECEIVER_BODIES.notActive)
    else answer(res, 503, RECEIVER_BODIES.full, { 'retry-after': '300' })
  })
  return true
}
