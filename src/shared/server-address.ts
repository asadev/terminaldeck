/**
 * THE SERVER ADDRESS — the one string a phone needs before it has ever met a
 * machine.
 *
 * ## The gap this closes
 *
 * A first connection to a host is a Noise **IK** handshake, and IK means the
 * caller already knows the responder's static public key before it says a word.
 * That is the whole security property: the relay carries the bytes and cannot
 * answer in the machine's place, because a client that knows the key notices.
 *
 * Everything a host printed before this existed was a `hostId` and a
 * `fingerprint`, and neither can start that handshake. A host id is
 * `BASE32(SHA-256(host secret))` and a fingerprint is a digest of the public
 * key — both one-way. So a person could read the two most identifying strings a
 * machine has off its own screen, type them anywhere, and get no further: there
 * was **nothing valid to put in a form**. That is why every phone client shipped
 * without an add-a-server screen, and why the feature he asked for most was
 * unreachable in a build that contained all of its wire.
 *
 * The key itself has to travel. Fetching it from the relay instead is asking the
 * attacker for the fingerprint of the party you are about to trust —
 * `pwa/src/endpoint.ts` and iOS's `PairingCode.swift` both already refuse to do
 * that. So the host hands out one token carrying all three facts, a person moves
 * it however they like, and the client stores it.
 *
 * ## Exactly the shape the client already parses
 *
 * `pwa/src/endpoint.ts` has held `RelayEndpoint` — `{ kind, url, hostId,
 * hostKey }` — since the browser client learned to relay, along with
 * `asEndpoint`, the validator that decides whether a stored endpoint is usable.
 * This encodes **that object and nothing else**: the token is base64url of the
 * JSON of the very record the client keeps. A decoder here therefore produces a
 * value that the client's own validator accepts, and `server-address.test.ts`
 * pins that by running the real `asEndpoint` over the real round trip rather
 * than over a copy of the shape.
 *
 * That is why there is no shorter field-packed form and no omitted relay URL.
 * Dropping the URL when it matches the default would halve the token and would
 * mean an address whose meaning depends on which build reads it — and this
 * product's stated position is that the relay is replaceable and that pointing
 * at somebody else's is supported, not exotic. An address that silently means
 * "whichever relay you were compiled with" is not an address.
 *
 * ## What it is not
 *
 * **It is not a secret.** It carries a public key, a public name at a relay, and
 * the URL of a service designed on the assumption that whoever runs it is
 * hostile. Holding it lets somebody dial the machine and be refused: the gate is
 * the SSH login `enroll` verifies against the server's own sshd, and after that
 * a credential the host mints. That sentence travels with the address —
 * {@link ADDRESS_IS_NOT_A_SECRET} — wherever it is printed, because a string
 * this long and this random-looking will otherwise be treated as one, and the
 * people who treat it as a secret are the ones who then cannot paste it to
 * themselves.
 *
 * The pairing link this replaces *was* a secret, which is exactly why it was
 * deleted: `shared/pairing-link.ts` records that it *"was a two-hundred-character
 * string with a live bearer token inside it whose only route between two machines
 * was a messaging app — which is a pairing token somebody else's server keeps a
 * copy of."* This token is the same length and none of that is true of it. That
 * difference is the entire design.
 *
 * ## No `node:crypto` here, deliberately
 *
 * Same rule as `shared/pairing-link.ts`, which this imports its validators from:
 * this module is meant to be reachable from the browser client's bundle, and
 * `shared/relay-wire.ts` cannot be, because `hostIdFor` pulls in a Node built-in.
 * `Buffer` is fine — `pwa/vite.config.ts` binds the `buffer` package into every
 * shared module that names it, which is how `sealed.ts` and `endpoint.ts`
 * already run in a tab.
 */

import { isHostId, isRelayUrl } from './pairing-link'

/**
 * How the token announces itself, and why it is not the product's name.
 *
 * A version and a separator. The version is here so a future format is
 * *refused* by this one rather than half-parsed into an endpoint that dials the
 * wrong machine; the separator is `.` because it is one of the few printable
 * characters **not** in the base64url alphabet, so splitting on the first one is
 * unambiguous — `-` and `_` are both body characters and would not be.
 *
 * Not `terminaldeck…`: the product's name lives in `shared/brand.ts` and
 * nowhere else, and a wire format that embeds it is a rename that breaks every
 * address ever printed.
 */
export const SERVER_ADDRESS_PREFIX = 'srv1.'

/**
 * The sentence that travels with the address, everywhere it is shown.
 *
 * Written once, here, because it is a claim about the format rather than about
 * any one screen — and because the failure it prevents is somebody refusing to
 * paste the one string that makes the feature work, or worse, treating a leaked
 * one as an incident. `cli.ts`, the desktop's server page and the installer all
 * print this; the installer restates it in POSIX sh, which cannot import.
 */
export const ADDRESS_IS_NOT_A_SECRET =
  'This address is not a secret. It holds a public key and a public name at a relay, and it ' +
  'grants nothing on its own — signing in still needs a login this server already accepts.'

/**
 * A machine, as a client that has never met it needs it.
 *
 * Structurally the `RelayEndpoint` of `pwa/src/endpoint.ts`, field for field and
 * `kind` included. Restated rather than imported because the dependency runs the
 * other way — `pwa/src/` reaches into `src/shared/`, never the reverse — and
 * pinned to that file by a test rather than by a type.
 */
export interface ServerAddress {
  kind: 'relay'
  /** The rendezvous service to dial. */
  url: string
  /** Which slot at it: 26 characters of the relay's base32. */
  hostId: string
  /** The machine's X25519 static public key, base64url. What makes the handshake IK. */
  hostKey: string
}

/** The three facts a host knows about itself, in the spelling `RelayState` uses. */
export interface ServerAddressParts {
  url: string
  hostId: string
  /** Base64 or base64url; the address always carries base64url. */
  hostKey: string
}

/** A real address is about 180 characters. Anything past this is not one. */
const MAX_ADDRESS_CHARS = 4096

const KEY_BYTES = 32

/* ----------------------------------------------------------- the alphabet -- */

/**
 * Base64url, spelled out rather than named.
 *
 * `Buffer.from(text, 'base64url')` is not an option and the reason is measured:
 * the browser `Buffer` behind the web client is the `buffer` package, which does
 * not know that encoding name **and does not refuse it** — it falls through to
 * base64 and silently *drops* every `-` and `_`, producing a value some bytes
 * short. `endpoint.ts` carries the same note about the same trap. Folding the
 * two characters by hand is the version that behaves identically under Node and
 * under a tab.
 */
function toBase64Url(bytes: Buffer): string {
  return bytes.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function fromBase64Url(text: string): Buffer {
  return Buffer.from(text.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
}

/**
 * The 32 raw bytes behind a host key, in either alphabet it arrives in, or null.
 *
 * The same fold as above, for the same reason, and a length check rather than a
 * shape check: a key quietly two bytes short is a handshake that fails with no
 * reason attached. Base64 decoders skip characters they do not recognise instead
 * of refusing, so the length is the only thing that actually catches a mangled
 * key.
 */
export function hostKeyBytes(hostKey: string): Buffer | null {
  if (hostKey.length > 128) return null
  const bytes = fromBase64Url(hostKey)
  return bytes.length === KEY_BYTES ? bytes : null
}

/* -------------------------------------------------------------- the token -- */

/**
 * One machine's address, or null when the machine cannot describe itself.
 *
 * Null rather than a throw and rather than a best effort, because every caller
 * is about to *print* this: a host with no relay link has no slot and no address,
 * and the honest output is a sentence saying so. An address assembled out of
 * blanks would be a string somebody pastes into a form that then fails at the
 * handshake, minutes later, with nothing pointing back at the paste.
 */
export function formatServerAddress(parts: ServerAddressParts): string | null {
  const address = asServerAddress({ kind: 'relay', ...parts })
  if (address === null) return null
  // Written as a literal rather than spread from `address`, so the field order
  // in the token is a property of this line and not of however the caller's
  // object was built. Two hosts printing the same three facts print the same
  // string, which is what makes an address comparable by eye.
  const json = JSON.stringify({
    kind: 'relay',
    url: address.url,
    hostId: address.hostId,
    hostKey: address.hostKey,
  })
  return `${SERVER_ADDRESS_PREFIX}${toBase64Url(Buffer.from(json, 'utf8'))}`
}

/**
 * A pasted address, or null.
 *
 * Lenient about what surrounds the token — a paste out of a terminal arrives
 * with a newline on it, out of a chat window with a space — and strict about
 * everything inside it. In particular the body is **re-encoded and compared**:
 * base64 decoding silently ignores characters outside the alphabet, so a token
 * that lost its last few characters to a selection, or gained a stray one from a
 * line wrap, decodes to *something* rather than failing. Comparing the canonical
 * re-encoding is what turns that into a refusal a person can act on.
 */
export function parseServerAddress(text: string): ServerAddress | null {
  const trimmed = text.trim()
  if (trimmed.length === 0 || trimmed.length > MAX_ADDRESS_CHARS) return null
  if (!trimmed.startsWith(SERVER_ADDRESS_PREFIX)) return null

  const body = trimmed.slice(SERVER_ADDRESS_PREFIX.length)
  const bytes = fromBase64Url(body)
  if (bytes.length === 0) return null
  if (toBase64Url(bytes) !== body) return null

  let parsed: unknown = null
  try {
    parsed = JSON.parse(bytes.toString('utf8'))
  } catch {
    return null
  }
  return asServerAddress(parsed)
}

/** Whether a string is an address this build can dial. Nothing is decoded twice. */
export function isServerAddress(text: string): boolean {
  return parseServerAddress(text) !== null
}

/**
 * A decoded value narrowed to an address, or null.
 *
 * Deliberately the same three refusals `asEndpoint` makes, in the same order,
 * against the same two validators — this is the gate on the way *out* of a host
 * and that one is the gate on the way *in* to a client, and an address that
 * passed here and failed there would be a host printing something no client
 * accepts. `server-address.test.ts` runs the real `asEndpoint` over the real
 * round trip so that the two cannot drift apart quietly.
 */
export function asServerAddress(value: unknown): ServerAddress | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  if (record.kind !== 'relay') return null
  const { url, hostId, hostKey } = record
  if (typeof url !== 'string' || !isRelayUrl(url)) return null
  if (typeof hostId !== 'string' || !isHostId(hostId)) return null
  if (typeof hostKey !== 'string') return null
  const key = hostKeyBytes(hostKey)
  if (key === null) return null
  // Normalised on the way through, never passed along as it arrived. A host's
  // own `RelayState` spells its key base64url and a rendezvous offer spells the
  // same 32 bytes in standard base64; both are accepted above, and one of them
  // comes out, so the same machine has one address rather than two.
  return { kind: 'relay', url, hostId, hostKey: toBase64Url(key) }
}
