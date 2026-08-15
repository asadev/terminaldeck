/**
 * How eight typed characters find a machine.
 *
 * ## The problem, stated honestly
 *
 * A phone pairs from a QR code, and that code carries four things: the relay
 * address, the 26-character host id, the host's 32-byte X25519 public key and
 * the pairing token. The first three are the *address* — they are what makes
 * the handshake Noise IK instead of trust-on-first-use — and none of them is a
 * secret. They are simply large: 130 bits of host id and 256 bits of key.
 *
 * A typed code cannot carry them. Forty bits is a code somebody will type; four
 * hundred is not. So a machine-to-machine pairing needs somewhere for the guest
 * to *look the address up*, and the only party both machines can already reach
 * is the relay — which is the one party in this design that is assumed to be
 * hostile.
 *
 * ## The trick, which needs no change to the relay at all
 *
 * The relay lets anybody claim a host slot by presenting a 32-byte secret; the
 * slot's public name is `BASE32(SHA-256(secret))`. It does not care where the
 * secret came from.
 *
 * So both machines derive one from the code. While a pairing code is on screen,
 * the machine showing it claims the slot named by that code and answers with its
 * real address. The machine being typed into derives the same slot, dials it,
 * and reads the address off it. Nothing was added to the relay, nothing is
 * stored anywhere, and the slot exists for exactly as long as the code does —
 * no timer, no cron, no cost when nobody is pairing.
 *
 * ## Why a hostile relay still cannot get in the middle
 *
 * If the offer were sent in the clear, the relay could substitute its own host
 * id and key, the guest would run IK against the relay, hand it the code, and
 * the relay would forward the code to the real machine — a textbook
 * man-in-the-middle, and the end of the property this whole feature is built on.
 *
 * So the rendezvous is not in the clear. The **responder's static key pair is
 * itself derived from the code**, which means the offer channel is an ordinary
 * Noise IK channel whose responder identity only somebody holding the code can
 * produce. A relay that substitutes itself fails `es` and the guest's handshake
 * refuses. There is no new handshake here, no new primitive, and no new frame
 * format on the wire: it is `sealed.ts`, unchanged, keyed by the code.
 *
 * ## Which leaves exactly one attack, and the reason for the scrypt
 *
 * A relay that records the handshake can guess the code offline: for each guess,
 * derive the responder private key and try to open the initiator's static. That
 * is a 2^40 search, and X25519 plus one AEAD is fast enough — about fifty
 * microseconds — that a GPU rig would finish it in days, and hours if somebody
 * really cared. Days is far too long to matter for a code that dies in sixty
 * seconds, but the credential the guest receives afterwards is sealed under keys
 * an attacker who eventually recovers the code could also derive.
 *
 * The seed is therefore memory-hard. `scrypt` at the same parameters
 * `device-auth.ts` uses costs about 36ms and 16MB per attempt: once per pairing
 * for each honest machine, and roughly four months of a dedicated rig for the
 * full space. Against a secret that is dead in a minute and can only ever be
 * used once, that is a margin with nothing to argue about.
 *
 * ## What is deliberately *not* here
 *
 * The rendezvous carries an address and nothing else. It does not pair, does not
 * issue a credential and does not admit anybody: the guest reads the offer,
 * closes the channel, and starts an ordinary connection to the real machine with
 * the code as its pairing token — the identical path a phone takes. Every rule
 * about who gets in stays in `device-auth.ts` and `server.ts`, where it is
 * written once.
 */

import { scryptSync } from 'node:crypto'
import { DEFAULT_RELAY_URL, HOST_SECRET_BYTES, hostIdFor, isHostId } from '../../../shared/relay-wire'
import { fingerprint, staticFromSeed } from '../../../shared/sealed'
import { normaliseCode } from '../../../shared/short-code'
import { createRelayClient, type RelayLink, type RelayState } from '../relay-client'
import { describeThisMachine } from './guest'
import type { HostIdentity } from '../host-identity'

/**
 * Domain separator, mixed in as the scrypt salt.
 *
 * Versioned because it pins the whole derivation: change the parameters below
 * and this string changes with them, so two builds that disagree fail to find
 * each other at the relay rather than half-completing a handshake with mismatched
 * keys. There is nothing to negotiate and no fallback — a rendezvous that could
 * be talked down to a cheaper KDF would be one an attacker asks to be talked
 * down.
 */
export const RENDEZVOUS_SALT = 'terminaldeck-machine-pairing-v1'

/**
 * The same parameters `device-auth.ts` hashes credentials with, and for a
 * stronger reason.
 *
 * There the KDF is defence in depth over a 256-bit random secret, so the cost is
 * a formality. Here it is the only thing standing between a forty-bit code and
 * an offline search, which is the case scrypt was designed for. ~36ms and 16MB
 * per attempt, measured on this machine.
 */
const SCRYPT = { N: 16384, r: 8, p: 1 } as const

/** 32 bytes to claim the slot with, then 32 to be the responder identity. */
const SEED_BYTES = HOST_SECRET_BYTES + 32

/**
 * The identity two machines both derive from one code.
 *
 * Shaped as a `HostIdentity` on purpose: it is handed straight to
 * `createRelayClient`, which is the same relay client the app's real identity
 * uses. Reusing it rather than writing a second WebSocket host client is the
 * whole reason the beacon below is thirty lines instead of three hundred.
 */
export function rendezvousIdentity(code: string): HostIdentity | null {
  // Normalised first, so the two ends derive from the same string however each
  // of them was typed or printed. `H4K9-2FQT`, `h4k92fqt` and a code with an
  // `O` where a zero was meant all have to land on one seed, or pairing depends
  // on which keyboard somebody used.
  const canonical = normaliseCode(code)
  if (canonical === null) return null

  const seed = scryptSync(canonical, RENDEZVOUS_SALT, SEED_BYTES, {
    ...SCRYPT,
    // maxmem defaults to 32MB and scrypt throws — rather than degrade — the
    // moment 128*N*r crosses it. Derived from the parameters so raising them
    // later stays a one-line change instead of a runtime failure.
    maxmem: 256 * SCRYPT.N * SCRYPT.r,
  })
  const hostSecret = seed.subarray(0, HOST_SECRET_BYTES)
  const keys = staticFromSeed(seed.subarray(HOST_SECRET_BYTES))
  return {
    hostSecret,
    hostId: hostIdFor(hostSecret),
    keys,
    fingerprint: fingerprint(keys.publicKey),
  }
}

/* ------------------------------------------------------------------ offer -- */

/**
 * What the machine showing the code says about itself.
 *
 * Three facts and a label, and every one of them is public: the relay address,
 * the host id, the X25519 public key, and a name for the row. There is
 * deliberately no secret in here — the channel is sealed, but a payload that
 * relied on that would be one bad refactor away from being sent in the clear,
 * and this one is not.
 */
export interface MachineOffer {
  /** The relay that machine is reachable through. */
  relayUrl: string
  hostId: string
  /** Its X25519 static public key, base64. */
  publicKey: string
  /** What it calls itself, for the row in the other machine's list. */
  name: string
  /** `darwin`, `win32` or `linux`. Empty when it declines to say. */
  platform: string
}

/**
 * What this machine can honestly say about itself right now, or null when it has
 * nothing to say.
 *
 * Null is not a detail. Every field here comes off the relay link, so a machine
 * whose link has not come up has no address to publish — and publishing an empty
 * one would put a slot at the relay answering with a host id that routes
 * nowhere. The caller turns that null into a sentence on the screen rather than
 * into a code that fails after somebody has typed it.
 *
 * It lives here, next to the frame it fills in, because two paths need it: the
 * Machines screen, which refuses to show a code without one, and the phone
 * pairing on the Remote panel, which shows its code either way because a QR
 * carries the address inside the link. Two spellings of one offer is exactly the
 * kind of thing that works on the machine it was written on — which is also why
 * the key is re-encoded below rather than passed through.
 */
export function offerFrom(relay: RelayState | null): MachineOffer | null {
  if (relay === null || !relay.connected || relay.hostId === '' || relay.publicKey === '') return null
  const me = describeThisMachine()
  return {
    relayUrl: relay.url,
    hostId: relay.hostId,
    // Re-encoded rather than passed through. `RelayState` publishes base64url
    // because it goes into a URL; the offer is JSON inside a sealed frame and
    // `parseOffer` decodes plain base64.
    publicKey: Buffer.from(relay.publicKey, 'base64url').toString('base64'),
    name: me.name,
    platform: me.platform,
  }
}

/** Bounded so a hostile answer cannot make this process hold a large string. */
const MAX_OFFER_BYTES = 4 * 1024
const MAX_NAME_LENGTH = 64

export function encodeOffer(offer: MachineOffer): string {
  return JSON.stringify({ t: 'machine', ...offer })
}

/**
 * Read an offer, or null.
 *
 * Narrowed field by field rather than cast, the same rule `parseClientMessage`
 * follows and for a sharper reason: what comes back from here is dialled and
 * then handed a pairing code. A relay that could put an arbitrary `hostId` in
 * this object would be choosing which machine the code is typed into.
 *
 * That is *also* what the sealed channel already prevents — nobody without the
 * code can produce this frame at all — so this parse is the second of two locks
 * rather than the only one. It is here because a frame that is authenticated is
 * still not a frame that is well-formed.
 */
export function parseOffer(raw: unknown): MachineOffer | null {
  if (typeof raw !== 'string' || raw.length > MAX_OFFER_BYTES) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
  const value: Record<string, unknown> = { ...parsed }
  if (value.t !== 'machine') return null
  const { relayUrl, hostId, publicKey, name, platform } = value
  if (typeof relayUrl !== 'string' || !/^wss?:\/\/\S+$/i.test(relayUrl)) return null
  if (typeof hostId !== 'string' || !isHostId(hostId)) return null
  if (typeof publicKey !== 'string' || Buffer.from(publicKey, 'base64').length !== 32) return null
  return {
    relayUrl,
    hostId,
    publicKey,
    // A name is a label and its absence is not a reason to refuse a machine.
    // Control characters are stripped for the same reason they are everywhere
    // else here: this string is rendered next to terminal output.
    name:
      typeof name === 'string'
        ? name.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, MAX_NAME_LENGTH)
        : '',
    platform: typeof platform === 'string' ? platform.slice(0, 32) : '',
  }
}

/* ----------------------------------------------------------------- beacon -- */

export interface Beacon {
  /** Stop answering. Safe to call twice, and safe to call when never started. */
  stop(): void
  /** Is the slot claimed at the relay right now? */
  connected(): boolean
  /**
   * Resolves once the slot is claimed, or false when it has not been by then.
   *
   * The reason this exists is a race with a person in it. Claiming a slot is a
   * WebSocket dial and takes a moment; a code shown before the dial lands is a
   * code that answers "no machine is showing that" to anybody quick enough to
   * type it. So the caller waits before it puts the code on screen, and shows a
   * failure rather than a code that cannot work yet.
   *
   * It is a bounded wait rather than an event because `RelayLink` publishes its
   * state and does not announce it. One-shot, at most `timeoutMs`, and then
   * gone — not a standing poll, and nothing runs when nobody is pairing.
   */
  ready(timeoutMs?: number): Promise<boolean>
}

/** How long a code will wait for its own rendezvous before it is a failure. */
export const BEACON_READY_TIMEOUT_MS = 6000

export interface BeaconOptions {
  code: string
  offer: MachineOffer
  /** The relay this machine is already connected to. */
  relayUrl?: string
  /** Seam for the tests: the same shape `createRelayClient` returns. */
  createLink?: typeof createRelayClient
}

/**
 * Answer the code that is on screen, for exactly as long as it is on screen.
 *
 * Started when somebody presses the button and stopped when the code is spent,
 * cancelled or expires. That is the whole lifecycle: there is no timer polling
 * for a guest and nothing running when nobody is pairing, which is the standing
 * rule about events rather than polling and also just what the feature needs.
 *
 * `isKnownDevice` says yes to everybody, and that is not a hole. The gate on
 * this channel is the responder key: a guest that has the code derives it and
 * completes the handshake, and a guest that does not fails `es` and never
 * reaches this callback. There is nothing behind the channel to protect — one
 * public address, sent once, and then the channel closes.
 *
 * Returns null when the code is not a code. A beacon for a string nobody can
 * type is a socket held open for nothing.
 */
export function startBeacon(options: BeaconOptions): Beacon | null {
  const identity = rendezvousIdentity(options.code)
  if (identity === null) return null

  const create = options.createLink ?? createRelayClient
  let link: RelayLink | null = null
  try {
    link = create({
      url: options.relayUrl ?? DEFAULT_RELAY_URL,
      identity,
      isKnownDevice: () => true,
    })
  } catch (error) {
    // A relay client that cannot even be constructed is a pairing that will not
    // work, and the code on screen is about to fail with a sentence about not
    // finding the machine. Loud here, because that sentence will not say this.
    console.error('[machines] could not publish a pairing rendezvous:', error)
    return null
  }

  const payload = encodeOffer(options.offer)
  link.start((_address, connect) => {
    const wire = connect({
      // A guest that talks on this channel is talking to nothing. There is no
      // protocol here; the offer is the entire conversation.
      message: () => {},
      closed: () => {},
    })
    /*
     * One tick later, and this is load-bearing rather than cautious.
     *
     * `relay-client.ts` calls this callback *before* it puts the handshake
     * reply on the wire — deliberately, so that an endpoint which is full
     * refuses the channel rather than accepting one it is about to drop.
     * Sending here synchronously therefore puts the offer in front of the
     * reply, and the guest reads its first frame as a handshake, finds it the
     * wrong length, and closes the channel: every lookup returned "no machine
     * is showing that code" against a beacon that was working perfectly.
     *
     * The reply is written in the same synchronous run as this callback
     * returns, so a microtask is enough to land behind it — and it is the
     * smallest delay that is still ordered, which matters when a person is
     * waiting to type eight characters.
     */
    queueMicrotask(() => wire.send(payload))
    // Deliberately not closed from this side. The guest reads the offer and
    // hangs up, which is one round trip; closing here would race its own
    // `send` through the relay and lose the frame often enough to matter.
    // The beacon's own `stop` takes every channel with it.
    return true
  })

  const live = link
  return {
    stop(): void {
      link?.stop()
      link = null
    },
    connected: () => link !== null && live.state().connected,
    async ready(timeoutMs = BEACON_READY_TIMEOUT_MS): Promise<boolean> {
      const deadline = Date.now() + timeoutMs
      for (;;) {
        if (link === null) return false
        if (live.state().connected) return true
        if (Date.now() >= deadline) return false
        await new Promise((settle) => setTimeout(settle, 25))
      }
    },
  }
}
