/**
 * The relay wire contract: the bytes four programs have to agree on.
 *
 * A phone reaches this Mac by both ends dialling out to a rendezvous service
 * and the service stapling the two sockets together. That is three or four
 * separate programs — the relay under `relay/`, the desktop's `relay-client.ts`,
 * an iOS app and an Android app — and every one of them has to produce and
 * parse the same bytes. Anything they must agree on lives here rather than in
 * whichever of them happened to need it first.
 *
 * The relay ships its own copy of the routing half (`relay/src/rendezvous.ts`)
 * because it is deployed on its own and must not depend on the desktop tree.
 * `relay-client.test.ts` therefore runs the real relay against these constants
 * and fails the moment the two drift — a cross-check is what makes two
 * implementations of one wire safe, not the hope that nobody edits either.
 *
 * ## Nothing here is a secret and nothing here is trusted
 *
 * The relay sees a routing header and ciphertext. The envelope below is
 * *plaintext* on purpose: the relay has to read a channel id to know which
 * phone a frame belongs to. Everything inside the envelope is sealed by
 * `shared/sealed.ts`, whose keys the relay never holds.
 *
 * So an attacker who owns the relay can drop frames, reorder channels and
 * count bytes. It cannot read a session, cannot inject a keystroke, and cannot
 * sit in the middle of the handshake without failing to decrypt on the first
 * frame. Every field defined here is written on the assumption that the party
 * carrying it is hostile.
 */

import { createHash } from 'node:crypto'
import { SEALED_VERSION } from './sealed'

/* -------------------------------------------------------------------------- */
/* Endpoints                                                                   */
/* -------------------------------------------------------------------------- */

/** Where a Mac claims its name. */
export const RELAY_HOST_PATH = '/v1/host'

/** Where a phone asks for one, as `?host=<hostId>`. */
export const RELAY_GUEST_PATH = '/v1/join'

/**
 * The host secret travels in a header rather than in the URL.
 *
 * Query strings end up in access logs, proxy logs and error reports as a matter
 * of routine. This one is a bearer secret, so it goes where logs do not
 * habitually reach.
 */
export const RELAY_SECRET_HEADER = 'x-deck-host-secret'

/**
 * The service the desktop dials when nothing else is configured.
 *
 * A default rather than a requirement: `relay-config.ts` reads an environment
 * variable over it, and the whole design assumes whoever runs this service is
 * hostile — so pointing it at somebody else's is a supported thing to do, not a
 * loss of security.
 */
export const DEFAULT_RELAY_URL = 'wss://relay.terminaldeck.dev'

/* -------------------------------------------------------------------------- */
/* Envelope                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * A Mac holds one socket no matter how many phones are attached, so frames for
 * different phones share it and each needs a label. Hence a 17-byte envelope on
 * the host side only: one type byte, a 16-byte channel id, then the opaque
 * payload. The phone side is unwrapped — a phone has one channel and does not
 * need to be told its own name.
 */
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

/** Null for anything that is not an envelope. Callers drop the frame; they never guess. */
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
 * The Mac invents a random 32-byte secret on first run; its public name is
 * `BASE32(SHA-256(secret))`. Claiming the name at the relay means presenting the
 * secret — a preimage nobody else can produce — so learning a host id gets an
 * attacker a name they cannot impersonate, and the relay stores neither value.
 *
 * 26 characters is 130 bits, which is not a number anyone enumerates.
 *
 * A plain hash is right *here* and would be catastrophic one layer up. This
 * secret is 32 random bytes, so there is nothing to search. The rendezvous slot
 * a pairing code names is the same function applied to a secret derived from six
 * digits, and that derivation is scrypt precisely because the input is a
 * million-wide space — see `main/remote/machines/rendezvous.ts`.
 */
export function hostIdFor(hostSecret: Buffer): string {
  return base32(createHash('sha256').update(hostSecret).digest(), 26)
}

/** Host ids are compared as fixed-length uppercase; anything else cannot be one. */
export function isHostId(value: string): boolean {
  return /^[A-HJ-NP-Z2-9]{26}$/.test(value)
}

/** Bytes in a host secret. Anything else is refused by the relay before routing. */
export const HOST_SECRET_BYTES = 32

/* -------------------------------------------------------------------------- */
/* The sealed channel, as it rides the envelope                                */
/* -------------------------------------------------------------------------- */

/**
 * ## What a channel looks like from the first byte
 *
 * The relay preserves message boundaries in both directions — one WebSocket
 * binary frame from the phone becomes exactly one `data` envelope at the Mac —
 * so the sealed channel needs no length prefix of its own. A channel is then:
 *
 *   1. relay → Mac      `open`, empty payload. A phone has arrived.
 *   2. phone → Mac      `[version][80-byte Noise IK message 1]`
 *   3. Mac → phone      `[version][48-byte Noise IK message 2]`
 *   4. either direction one sealed frame per protocol message, forever.
 *   5. either direction `close`, empty payload.
 *
 * Anything that does not match — a first payload of the wrong length, a version
 * this build does not speak, a sealed frame that fails its tag — closes the
 * channel with no explanation on the wire. Which check failed is not the
 * network's business, and saying would hand a hostile relay an oracle.
 *
 * ## Why the version byte is outside the seal, and why that is safe
 *
 * It has to be readable before any key exists, so it cannot be inside. A
 * hostile relay can therefore flip it and cause a refusal — but it can already
 * drop the connection outright, so that is not a new power. What it cannot do
 * is downgrade anything: the byte selects no primitive and enables no fallback,
 * there is exactly one accepted value, and every parameter of the handshake is
 * pinned by `NOISE_NAME` inside the transcript hash. A mismatch is a build that
 * needs updating, told apart from a cryptographic failure so the phone can say
 * which.
 */
export const RELAY_SEALED_VERSION = SEALED_VERSION

/** X25519 ephemeral (32) + the initiator's static key sealed under `es` (32 + 16). */
export const NOISE_MESSAGE_BYTES = 80

/** X25519 ephemeral (32) + an empty confirmation payload's tag (16). */
export const NOISE_REPLY_BYTES = 48

/** What a phone's first payload on a fresh channel must measure. */
export const HANDSHAKE_OPEN_BYTES = 1 + NOISE_MESSAGE_BYTES

/** What the Mac answers with. */
export const HANDSHAKE_REPLY_BYTES = 1 + NOISE_REPLY_BYTES

/** Put the version in front of a handshake message. */
export function withSealedVersion(message: Buffer): Buffer {
  return Buffer.concat([Buffer.from([RELAY_SEALED_VERSION]), message])
}

/**
 * Strip the version byte, or say why not.
 *
 * `wrong-version` is separated from `malformed` for the caller's log only. Both
 * end the channel the same way and neither is described to the far end.
 */
export type SealedOpen =
  | { ok: true; message: Buffer }
  | { ok: false; reason: 'wrong-version' | 'malformed' }

export function readSealedHandshake(payload: Buffer, expected: number): SealedOpen {
  if (payload.length !== expected) return { ok: false, reason: 'malformed' }
  if (payload[0] !== RELAY_SEALED_VERSION) return { ok: false, reason: 'wrong-version' }
  return { ok: true, message: Buffer.from(payload.subarray(1)) }
}

/* -------------------------------------------------------------------------- */
/* An AI app, reaching this Mac's tools over HTTPS through the relay           */
/* -------------------------------------------------------------------------- */

/**
 * ## What this half of the wire is for
 *
 * Everything above carries a phone's *sealed* channel. This carries something
 * else: an AI app on the internet — claude.ai, ChatGPT, a Claude Code on
 * another machine — calling this Mac's `deck-control` tools with an **access
 * key** the owner made for it. Those apps speak MCP over plain HTTPS and
 * nothing else; none of them will ever run a Noise handshake. So the relay
 * gains one HTTP route, `POST /mcp/<hostId>`, and passes each request down the
 * host's existing socket in an envelope of its own, and the answer back up.
 *
 * ## Be plain about what that costs
 *
 * **This path is not sealed.** TLS ends at the relay's reverse proxy, so the
 * relay process sees the MCP request and its answer in the clear — the tool
 * name, the arguments, the transcript text that comes back. That is a real
 * difference from a phone, whose bytes the relay cannot read at all, and the
 * settings page says so in those words. The two things that keep it acceptable:
 *
 *  1. **The relay still decides nothing.** It never checks a key — it cannot,
 *     it holds no list of them — and it forwards the credential it was handed
 *     to the desktop, which checks it against a hash on its own disk. A hostile
 *     relay can read and drop requests; it cannot forge a valid key, and every
 *     tier, confirmation and log row is applied on the Mac exactly as it is for
 *     the copilot at the desk.
 *  2. **Anybody who minds can point the app at their own relay.**
 *     `TERMINALDECK_RELAY_URL` already exists for that, and the relay is one
 *     dependency-free file.
 *
 * ## Why a second family of envelope types rather than reusing `data`
 *
 * A channel envelope's payload is ciphertext the desktop decrypts; this one is
 * an HTTP request the desktop answers. Overloading `data` would mean the
 * desktop guessing which of two things a frame was from its contents, and a
 * guess on a permission edge is not a rule. Separate type bytes, starting at
 * 0x10 so the two families cannot be confused at a glance in a hex dump.
 *
 * And it degrades cleanly in both directions. An **old desktop** decodes these
 * types as "not an envelope" and drops them, which is why the desktop announces
 * itself with `reach` — the relay only forwards to a host that has said it
 * answers MCP, and everybody else gets a fast 404 instead of a two-minute wait.
 * An **old relay** drops the desktop's `reach` frame the same way, and no
 * request ever arrives.
 *
 * The 16 bytes after the type are a **request id** the relay mints per HTTP
 * request — the same shape as a channel id, which is why `encodeEnvelope`
 * serves both. `reach` carries no request and sends sixteen zero bytes there.
 */
export const MCP_ENVELOPE = { request: 0x10, reply: 0x11, cancel: 0x12, reach: 0x13 } as const

/** Where an AI app's request arrives at the relay: `/mcp/<hostId>[/<key>]`. */
export const RELAY_MCP_PREFIX = '/mcp/'

/**
 * Largest request body the relay will forward.
 *
 * A JSON-RPC envelope is small — the loopback endpoint's own reasoning is that
 * the largest legitimate call is a four-thousand-character prompt. 64 KiB is
 * sixteen of those and still leaves the whole envelope, head included, under
 * {@link MAX_PAYLOAD_BYTES}, which is what lets a request ride in one frame.
 */
export const MCP_MAX_REQUEST_BYTES = 64 * 1024

/**
 * The answer travels in pieces no larger than this.
 *
 * Unlike a request, an answer can be big — a transcript read comes back as tens
 * of kilobytes of text — and one WebSocket frame on the host socket is capped
 * at {@link MAX_PAYLOAD_BYTES}. So the desktop cuts its answer into slices that
 * fit with room for the envelope, and the relay writes each to the HTTP
 * response as it lands.
 */
export const MCP_REPLY_CHUNK_BYTES = 60 * 1024

/**
 * Largest answer the relay will pass on, all pieces together.
 *
 * A ceiling on the relay's memory per request, not on what the tools may say:
 * the biggest bounded tool result in the catalogue is a 64 KiB transcript page,
 * so 8 MiB is a hundred times the real maximum and still a number that cannot
 * be used to make the relay hold a gigabyte.
 */
export const MCP_MAX_RESPONSE_BYTES = 8 * 1024 * 1024

/**
 * How long the relay holds an HTTP request open waiting for the desktop.
 *
 * It has to outlast the slowest honest answer, and the slowest honest answer is
 * a person deciding: an alter-tier call put to the owner waits up to the
 * consent timeout — two minutes for the copilot's own questions, less for a key
 * caller's — before the desktop refuses it. A relay that gave up first would
 * turn a clean "nobody answered" into a gateway error, and a person tapping
 * Allow after that would change something the AI had already been told failed.
 * 150 seconds is the longest consent window plus room.
 */
export const MCP_RELAY_WAIT_MS = 150_000

/** Most MCP requests one host may receive through the relay per minute. */
export const MCP_RATE_PER_MINUTE = 120

/** Most MCP requests one host may have in flight through the relay at once. */
export const MCP_MAX_IN_FLIGHT = 8

/** What the relay tells the desktop about one HTTP request. */
export interface RelayMcpHead {
  v: 1
  /** The `<key>` path segment, for apps that cannot set a header. */
  pathKey: string | null
  /** The `Authorization` header as it arrived, prefix and all. */
  authorization: string | null
  /** `Mcp-Protocol-Version`, passed through so the desktop's SDK can judge it. */
  protocolVersion: string | null
  /** `User-Agent`, for "last used by" when the client never said its name. */
  userAgent: string | null
}

/** What the desktop tells the relay to put in front of the answer. */
export interface RelayMcpReplyHead {
  status: number
  contentType: string | null
}

/** Flag bits on a reply envelope's first byte. */
export const MCP_REPLY_FIRST = 0x01
export const MCP_REPLY_LAST = 0x02

/** All zeroes: the request id slot of a frame that carries no request. */
export const MCP_NO_REQUEST = Buffer.alloc(CHANNEL_BYTES)

function withHead(head: unknown, rest: Buffer): Buffer {
  const json = Buffer.from(JSON.stringify(head), 'utf8')
  if (json.length > 0xffff) throw new Error('an MCP envelope head must fit in 64 KiB')
  const length = Buffer.alloc(2)
  length.writeUInt16BE(json.length, 0)
  return Buffer.concat([length, json, rest])
}

function readHead(payload: Buffer): { head: Record<string, unknown>; rest: Buffer } | null {
  if (payload.length < 2) return null
  const length = payload.readUInt16BE(0)
  if (payload.length < 2 + length) return null
  try {
    const head: unknown = JSON.parse(payload.subarray(2, 2 + length).toString('utf8'))
    if (typeof head !== 'object' || head === null || Array.isArray(head)) return null
    return { head: head as Record<string, unknown>, rest: Buffer.from(payload.subarray(2 + length)) }
  } catch {
    return null
  }
}

function textOrNull(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

/** Relay → desktop: one HTTP request, head then body. */
export function encodeMcpRequest(head: RelayMcpHead, body: Buffer): Buffer {
  return withHead(head, body)
}

/** Null for anything that is not a request this build can read. Callers drop it. */
export function decodeMcpRequest(payload: Buffer): { head: RelayMcpHead; body: Buffer } | null {
  const read = readHead(payload)
  if (!read || read.head.v !== 1) return null
  return {
    head: {
      v: 1,
      pathKey: textOrNull(read.head.pathKey),
      authorization: textOrNull(read.head.authorization),
      protocolVersion: textOrNull(read.head.protocolVersion),
      userAgent: textOrNull(read.head.userAgent),
    },
    body: read.rest,
  }
}

/**
 * Desktop → relay: one slice of an answer.
 *
 * The first slice carries the status and content type; the last is flagged so
 * the relay knows to end the response. A one-slice answer is both at once,
 * which is the common case.
 */
export function encodeMcpReply(flags: number, head: RelayMcpReplyHead | null, chunk: Buffer): Buffer {
  const flag = Buffer.from([flags & 0xff])
  if ((flags & MCP_REPLY_FIRST) !== 0) {
    if (!head) throw new Error('the first slice of an MCP reply must carry its head')
    return Buffer.concat([flag, withHead(head, chunk)])
  }
  return Buffer.concat([flag, chunk])
}

export interface McpReplySlice {
  first: boolean
  last: boolean
  head: RelayMcpReplyHead | null
  chunk: Buffer
}

export function decodeMcpReply(payload: Buffer): McpReplySlice | null {
  if (payload.length < 1) return null
  const flags = payload[0]
  const first = (flags & MCP_REPLY_FIRST) !== 0
  const last = (flags & MCP_REPLY_LAST) !== 0
  const rest = Buffer.from(payload.subarray(1))
  if (!first) return { first, last, head: null, chunk: rest }
  const read = readHead(rest)
  if (!read) return null
  const status = read.head.status
  if (typeof status !== 'number' || !Number.isInteger(status) || status < 100 || status > 599) return null
  return { first, last, head: { status, contentType: textOrNull(read.head.contentType) }, chunk: read.rest }
}

/** Null for anything that is not an MCP-family envelope. */
export function decodeMcpEnvelope(frame: Buffer): Envelope | null {
  if (frame.length < ENVELOPE_HEADER) return null
  const type = frame[0]
  if (
    type !== MCP_ENVELOPE.request &&
    type !== MCP_ENVELOPE.reply &&
    type !== MCP_ENVELOPE.cancel &&
    type !== MCP_ENVELOPE.reach
  ) {
    return null
  }
  return {
    type,
    channel: Buffer.from(frame.subarray(1, ENVELOPE_HEADER)),
    payload: Buffer.from(frame.subarray(ENVELOPE_HEADER)),
  }
}

/**
 * The one answer for "nothing here", byte for byte, from both ends.
 *
 * The relay sends it when the host is offline or has not said it answers MCP;
 * the desktop sends exactly the same status and bytes for a key it does not
 * recognise, a revoked key, and internet reach switched off. So a stranger
 * holding a host id — which is printed in every pairing QR code — learns
 * nothing by trying keys: "that Mac is offline" and "that key is wrong" look
 * identical from the outside. The guest route makes the same choice for the
 * same reason ("a 404 here would turn the endpoint into an oracle for which
 * machines are online"); this route has to answer *something* fast, so it
 * answers the same something for both.
 *
 * Shaped as a JSON-RPC error because the reader is an MCP client, and a client
 * that gets JSON it can parse shows the person a sentence instead of a parse
 * failure.
 */
export const MCP_NOT_FOUND_STATUS = 404
export const MCP_NOT_FOUND_BODY =
  '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Nothing answered at this address. The computer ' +
  'may be off or not connected, or this link may have been turned off."}}'
