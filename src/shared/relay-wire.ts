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
