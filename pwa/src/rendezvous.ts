/**
 * How six typed digits find a machine, from a browser.
 *
 * ## The problem this solves, and why a code cannot simply be dialled
 *
 * Reaching a machine takes three facts: the relay, the 26-character host id and
 * the machine's X25519 public key. They are the *address*, and they are what
 * makes the handshake Noise IK rather than trust-on-first-use. They are not
 * secret — they are simply large, 130 bits of host id and 256 of key, and six
 * digits somebody reads off one screen cannot carry them.
 *
 * A link used to carry all of it, and a QR code used to carry the link. Both are
 * gone: the QR did not work, and a link is a bearer secret with a route through
 * a chat app attached. So a typed code needs somewhere to look the address up,
 * and the only party both ends can already reach is the relay — the one party
 * this design assumes is hostile.
 *
 * ## The mechanism, which is the desktop's and is not restated
 *
 * `src/main/remote/machines/rendezvous.ts` carries the full argument and it is
 * worth reading there rather than summarising badly here. In one paragraph: the
 * machine showing a code claims a relay slot named by that code, and answers on
 * it with its real address. Both ends derive the slot's secret *and the
 * responder's static key pair* from the code, so the offer channel is an
 * ordinary sealed channel whose responder identity only somebody holding the
 * code can produce. A relay that substitutes itself fails `es` and this client's
 * handshake refuses it. Nothing was added to the relay and nothing is stored
 * anywhere; the slot exists for exactly as long as the code is on screen.
 *
 * The seed is memory-hard, and with six digits that is no longer a precaution.
 * There are only 10^6 codes; if the slot were named by a hash, anybody could
 * sweep the million in seconds, find the live slot, learn the code exactly, and
 * spend the five guesses `server.ts` allows on a single certain one. scrypt at
 * these parameters costs about a third of a second in a browser — once per
 * pairing here, and about ten CPU-hours for the whole space. The full argument
 * is in the desktop's module and is worth reading there.
 *
 * ## What is shared with the desktop and what is not
 *
 * Shared, imported: `staticFromSeed` and the whole handshake from
 * `shared/sealed.ts`; `hostIdFor`, `HOST_SECRET_BYTES` and the relay's default
 * address from `shared/relay-wire.ts`; `normaliseCode` from
 * `shared/short-code.ts`; the address validators from `shared/pairing-link.ts`.
 *
 * Not shared, and stated plainly because somebody will otherwise assume it is:
 * the **salt and the scrypt parameters** below, and the offer parser. The
 * desktop's copy lives in `src/main/remote/machines/rendezvous.ts`, which imports
 * `node:scrypt` and the desktop's own relay client — main-process code a browser
 * bundle cannot pull in. `shared/pairing-link.ts` restates the host-id alphabet
 * for exactly the same reason and says so.
 *
 * Two implementations of one derivation are safe when something fails on the
 * drift rather than when nobody edits either, so `rendezvous.test.ts` pins these
 * values against vectors generated from the desktop's own module. If somebody
 * changes the salt over there and not here, the vector stops matching and the
 * suite says so — instead of a pairing code that is typed correctly and finds
 * nothing.
 */

import { scryptAsync } from '@noble/hashes/scrypt.js'
import { isHostId, isRelayUrl } from '../../src/shared/pairing-link'
import { DEFAULT_RELAY_URL, HOST_SECRET_BYTES, hostIdFor } from '../../src/shared/relay-wire'
import { generateStatic, staticFromSeed, type StaticKeyPair } from '../../src/shared/sealed'
import { normaliseCode } from '../../src/shared/short-code'
import { hostKeyBytes, type RelayEndpoint } from './endpoint'
import { relaySocket, type BinarySocketLike } from './relay-socket'

/**
 * The domain separator, mixed in as the scrypt salt.
 *
 * Versioned because it pins the whole derivation: change the parameters below
 * and this string changes with them, so two builds that disagree fail to find
 * each other at the relay rather than half-completing a handshake with
 * mismatched keys. There is nothing to negotiate and no fallback.
 *
 * It must equal `RENDEZVOUS_SALT` in the desktop's module, byte for byte.
 */
export const RENDEZVOUS_SALT = 'terminaldeck-machine-pairing-v1'

/** The desktop's parameters, and they must stay the desktop's parameters. */
const SCRYPT = { N: 16384, r: 8, p: 1 } as const

/** 32 bytes to name the slot with, then 32 to be the responder identity. */
const SEED_BYTES = HOST_SECRET_BYTES + 32

/** How long a lookup waits. The code lives sixty seconds and both halves fit inside it. */
export const LOOKUP_TIMEOUT_MS = 12_000

export interface RendezvousIdentity {
  hostId: string
  keys: StaticKeyPair
}

/**
 * The identity two machines both derive from one code, or null for a string
 * nobody could have typed.
 *
 * Normalised first, so the two ends derive from the same string however each was
 * typed or printed: `482913`, ` 482 913 ` and `482-913` — the shape a code comes
 * back in after a round trip through a chat app — all have to land on one seed,
 * or pairing depends on what somebody's keyboard put between the digits.
 *
 * Asynchronous where the desktop's is not, and only for that reason: `scryptSync`
 * on the main thread of a browser freezes the page for the third of a second it
 * takes, on the one screen where somebody is watching to see whether their code
 * worked. `scryptAsync` yields between blocks and produces identical bytes —
 * which `rendezvous.test.ts` checks rather than assumes.
 */
export async function rendezvousIdentity(code: string): Promise<RendezvousIdentity | null> {
  const canonical = normaliseCode(code)
  if (canonical === null) return null

  const seed = Buffer.from(
    await scryptAsync(canonical, RENDEZVOUS_SALT, { ...SCRYPT, dkLen: SEED_BYTES }),
  )
  const hostSecret = seed.subarray(0, HOST_SECRET_BYTES)
  return { hostId: hostIdFor(hostSecret), keys: staticFromSeed(seed.subarray(HOST_SECRET_BYTES)) }
}

/* ------------------------------------------------------------------ offer -- */

/** Bounded so a hostile answer cannot make this page hold a large string. */
const MAX_OFFER_BYTES = 4 * 1024

/**
 * The longest machine name an offer may name itself with.
 *
 * The same twenty-four `machines.ts` caps a nickname at, and for the same
 * reason: this string ends up on a switcher chip beside a connection state. It
 * is also a bound on untrusted input — the offer is authenticated, not trusted —
 * so a machine that called itself four kilobytes cannot make a chip that fills
 * the screen.
 */
const MAX_OFFER_NAME_LENGTH = 24

/** What a machine's rendezvous offer says, once it is safe to believe. */
export interface MachineOffer {
  endpoint: RelayEndpoint
  /**
   * What the machine calls itself — its hostname. Empty when it did not say.
   *
   * This used to be thrown away here, on the grounds that *"the machine names
   * itself in `welcome` a second later"*. It does not. `welcome.deviceName` is
   * the name the machine has for **this device** — the phone — echoed back to
   * it, and nothing in the whole protocol tells a client the host's own name.
   * So the switcher chips read `2JJGF8` and `9ZA6K3`, the relay slot codes, for
   * a person who owns one Mac and one Windows PC and could not tell them apart.
   * The desktop's own guest client has always taken the name from right here
   * (`main/remote/machines/ipc.ts`, at `machines:pair`); this client is the one
   * that dropped it.
   */
  name: string
}

/**
 * Read an offer, or null.
 *
 * Narrowed field by field rather than cast, and it is the second of two locks
 * rather than the only one: nobody without the code can produce this frame at
 * all, because the channel it arrives on is sealed against a key derived from
 * the code. It is here because a frame that is authenticated is still not a
 * frame that is well-formed — and what comes out of this function is dialled and
 * then handed a pairing token.
 *
 * `platform` is still dropped, and that one is right: the machine says what kind
 * of thing it is in `welcome.hostPlatform`, over a channel that is authenticated
 * *and* current, and `host-platform.ts` already reads it.
 */
export function parseOffer(raw: string): MachineOffer | null {
  if (raw.length > MAX_OFFER_BYTES) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
  const value = parsed as Record<string, unknown>
  if (value.t !== 'machine') return null

  const { relayUrl, hostId, publicKey } = value
  if (typeof relayUrl !== 'string' || !isRelayUrl(relayUrl)) return null
  if (typeof hostId !== 'string' || !isHostId(hostId)) return null
  /*
   * Decoded, not shape-checked — and this is the one field where using the
   * shared validator would have been wrong.
   *
   * An offer carries 32 bytes as **standard base64**, because `machines/ipc.ts`
   * re-encodes them on the way out — and standard base64 of 32 random bytes
   * contains a `+` or a `/` most of the time. A validator written for the
   * base64url form (`[A-Za-z0-9_-]{43}=?`) that the old pairing link carried
   * would therefore refuse most real machines, intermittently, in a way that
   * looks like the code having expired. That regex is what used to be here. The
   * desktop's own `parseOffer` decodes and measures for the same reason;
   * `hostKeyBytes` does both alphabets.
   */
  if (typeof publicKey !== 'string' || hostKeyBytes(publicKey) === null) return null

  /*
   * Stripped of control characters before it is measured, the same cleaning the
   * desktop applies to the same field. A name is display text from a machine
   * this browser has never spoken to before, and an escape sequence in one would
   * be a chip that repaints the page around it.
   */
  const name =
    typeof value.name === 'string'
      ? value.name.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, MAX_OFFER_NAME_LENGTH)
      : ''

  return { endpoint: { kind: 'relay', url: relayUrl, hostId, hostKey: publicKey }, name }
}

/* ----------------------------------------------------------------- lookup -- */

export interface LookupOptions {
  code: string
  /** The relay this browser dials. The far machine names its own in the offer. */
  relayUrl?: string
  timeoutMs?: number
  /** Seam for the tests and the live harness. */
  open?: (url: string) => BinarySocketLike
}

/**
 * Ask the rendezvous where the machine behind this code is.
 *
 * Nothing is sent. The machine showing the code answers as soon as the sealed
 * channel is up, and the whole conversation is that one frame — so this opens a
 * channel, takes the first thing that arrives, and hangs up.
 *
 * A throwaway identity is used rather than this browser's own, matching the
 * desktop: the rendezvous authenticates the *responder*, nothing on the far side
 * stores or looks at who dialled, and putting the durable device key on a channel
 * before there is a machine to associate it with would be spending it for
 * nothing.
 *
 * Null covers every failure — a code nobody is showing, a relay that will not
 * answer, an offer that does not parse — because the caller's next sentence is
 * the same in all of them and telling them apart would mean describing the
 * relay's behaviour to a person who cannot act on it.
 */
export async function lookupMachine(options: LookupOptions): Promise<MachineOffer | null> {
  const identity = await rendezvousIdentity(options.code)
  if (identity === null) return null
  const relayUrl = options.relayUrl ?? DEFAULT_RELAY_URL

  return new Promise<MachineOffer | null>((resolve) => {
    let settled = false
    const finish = (offer: MachineOffer | null): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        socket.close(1000, 'lookup finished')
      } catch {
        // Already gone; there is nothing left to close.
      }
      resolve(offer)
    }
    const timer = setTimeout(() => finish(null), options.timeoutMs ?? LOOKUP_TIMEOUT_MS)

    let socket: ReturnType<typeof relaySocket>
    try {
      socket = relaySocket({
        relayUrl,
        hostId: identity.hostId,
        hostPublicKey: identity.keys.publicKey,
        deviceKeys: generateStatic(),
        open: options.open,
      })
    } catch {
      clearTimeout(timer)
      resolve(null)
      return
    }

    socket.onmessage = (event) => finish(typeof event.data === 'string' ? parseOffer(event.data) : null)
    socket.onclose = () => finish(null)
  })
}
