/**
 * Where this browser is pointed, and who it says it is.
 *
 * ## Two routes, and which one is the requirement
 *
 * This client began with one: a socket to the address the desktop serves it
 * from, on a tailnet, where the tunnel is the encryption and there is no third
 * party carrying the bytes. That is `direct` below and it still works — but it
 * was never a design decision, it was the only thing that existed before the
 * relay, and it made the browser client usable only by someone already running
 * Tailscale. Asad, plainly: *"a lot of users will not even know about
 * Tailscale."*
 *
 * `relay` is what every other client in this product uses, and it is now what
 * this one uses too. `direct` is the fallback for anyone already on it.
 *
 * ## What a relay endpoint has to carry, and why all three
 *
 * A relay address alone reaches the relay, not a machine. Three facts are
 * needed, and dropping any one of them breaks a different thing:
 *
 *   - **relayUrl** — which rendezvous service. Configurable because the whole
 *     design assumes it is hostile; pointing at somebody else's is supported.
 *   - **hostId** — which slot at it. 26 characters, `BASE32(SHA-256(secret))`,
 *     a name an attacker can photograph and cannot claim.
 *   - **hostKey** — that machine's X25519 static public key. This is the one
 *     that makes the handshake IK instead of trust-on-first-use. Without it the
 *     relay could answer in the machine's place and nothing here would notice.
 *
 * It is stored rather than fetched, for the reason iOS states in
 * `PairingCode.swift`: fetching the key from the relay is asking the attacker
 * for the fingerprint of the person you are about to trust.
 *
 * ## The private key in storage, said out loud
 *
 * `device-auth.ts` on the machine remembers the X25519 public key a device
 * paired with, and `isKnownDevice` refuses a handshake from any other. So this
 * browser has to present the *same* key every time, which means the private half
 * outlives the tab it was made in.
 *
 * That is a real secret in a store any script on this origin can read, and it is
 * worth being honest about rather than quiet. It adds no new class of exposure:
 * the bearer credential is already there and is what actually admits a device,
 * and a page that could read one could read the other. What the key buys is that
 * a credential copied off this device is useless without it — which is exactly
 * why the machine remembers it. iOS puts its copy in the keychain and Android in
 * the keystore; a browser has no such place.
 *
 * What it does have is a choice about *how long*, and the key follows the
 * credential's answer to it — see `remember.ts`. Both go in `sessionStorage` for
 * a browser that is not this person's, and a machine they walk away from is left
 * with neither the secret that admits a device nor the identity that names one.
 * Storing the key durably beside a credential that dies with the tab would leave
 * exactly half a pairing behind: not enough to get in, and still a stable
 * identifier for this app on a computer that is not theirs.
 */

import { isHostId, isRelayUrl } from '../../src/shared/pairing-link'
import { generateStatic, staticFromSeed, type StaticKeyPair } from '../../src/shared/sealed'
import { readAcross, type StorageLike, type Stores } from './remember'

/**
 * Re-exported rather than declared. It moved to `remember.ts` when the choice
 * between the two stores became a rule of its own; every existing caller keeps
 * the name it already imports from here.
 */
export type { StorageLike }

/* ------------------------------------------------------------ endpoints -- */

/** Through the relay, sealed end to end. What a pairing link carries. */
export interface RelayEndpoint {
  kind: 'relay'
  url: string
  hostId: string
  /** The machine's X25519 static public key, base64url or base64. */
  hostKey: string
}

/**
 * Straight to a socket this browser can already open.
 *
 * No address is stored with it, deliberately. The page is served by the very
 * process it then talks to, so the address is `location` and there is no field
 * anybody can edit to point a paired browser at a different machine.
 */
export interface DirectEndpoint {
  kind: 'direct'
}

export type DeckEndpoint = RelayEndpoint | DirectEndpoint

export const DIRECT: DirectEndpoint = { kind: 'direct' }

/**
 * An endpoint read back from storage, or the direct one.
 *
 * A missing or unreadable endpoint is `direct` rather than nothing, and that is
 * the migration: every browser paired before this existed has a credential and
 * no endpoint, and it is a browser that was talking to the address it was served
 * from. Discarding those pairings to introduce a field would be an absurd trade.
 */
export function asEndpoint(value: unknown): DeckEndpoint {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return DIRECT
  const record = value as Record<string, unknown>
  if (record.kind !== 'relay') return DIRECT
  const { url, hostId, hostKey } = record
  if (typeof url !== 'string' || !isRelayUrl(url)) return DIRECT
  if (typeof hostId !== 'string' || !isHostId(hostId)) return DIRECT
  // Decoded rather than shape-checked, because a stored key can have arrived in
  // either alphabet — see `hostKeyBytes`.
  if (typeof hostKey !== 'string' || hostKeyBytes(hostKey) === null) return DIRECT
  return { kind: 'relay', url, hostId, hostKey }
}

/**
 * The 32 raw bytes behind a host key, in either alphabet it arrives in.
 *
 * This product encodes the same 32 bytes two ways, and both reach this client:
 * a pairing link carries `k` as **base64url**, because it is a URL parameter and
 * `shared/pairing-link.ts` validates it as one; a rendezvous offer carries
 * `publicKey` as **standard base64**, because `machines/ipc.ts` converts it on
 * the way out. Handling one and not the other is a pairing route that works and
 * a pairing route that does not, for the same machine.
 *
 * The two characters are folded rather than the encoding being selected, because
 * the alphabets differ in exactly those two places and nothing else — and
 * because the browser `Buffer` behind this client is the `buffer` package, which
 * does not know the name `base64url` at all and silently *drops* a `-` or `_`
 * rather than refusing it. A key quietly two bytes short is a handshake that
 * fails with no reason attached, which is why the length is checked here rather
 * than trusted from the caller's validator.
 */
export function hostKeyBytes(hostKey: string): Buffer | null {
  const bytes = Buffer.from(hostKey.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
  return bytes.length === 32 ? bytes : null
}

/* ------------------------------------------------------- device identity -- */

/** Versioned, like the credential: a format change must not be read as current. */
export const DEVICE_KEY = 'terminaldeck.device-key.v1'

/**
 * This browser's X25519 identity as one store holds it, or null.
 *
 * A stored value that is not 32 bytes is null rather than an error. The
 * consequence of that is precise and survivable: the caller makes a fresh pair,
 * the machine will not recognise it and will refuse the handshake, the banner
 * says the machine could not prove itself, and pairing again fixes it. The
 * alternative — refusing to start — would leave somebody with a client that
 * cannot even reach the screen that would fix it.
 */
export function readDeviceKeys(storage: StorageLike): StaticKeyPair | null {
  let stored: string | null = null
  try {
    stored = storage.getItem(DEVICE_KEY)
  } catch {
    // Safari in private mode throws rather than returning null.
  }
  if (stored === null) return null
  const privateKey = Buffer.from(stored, 'base64')
  if (privateKey.length !== 32) return null
  // The public half is derived rather than stored. Two fields that must agree
  // are two fields that can disagree, and a stored public key that does not
  // match its private one is a handshake that fails at the far end with nothing
  // on this side to explain it. `staticFromSeed` is the derivation `sealed.ts`
  // itself uses — X25519 clamps internally, so the stored 32 bytes are the
  // private key and the public half comes out of the curve rather than out of
  // storage.
  return staticFromSeed(privateKey)
}

/**
 * Keep this browser's identity, or carry on without keeping it.
 *
 * Separate from {@link readDeviceKeys}, and that split is the point rather than
 * tidiness. The old single function generated *and persisted* on first use,
 * which meant merely opening this page on a borrowed computer wrote a durable
 * identifier for this app into its `localStorage` — before anybody had paired,
 * and whatever they were about to answer about being remembered. Now the key is
 * made in memory and written only when a pairing is written, into whichever
 * store that pairing chose.
 */
export function saveDeviceKeys(storage: StorageLike, keys: StaticKeyPair): void {
  try {
    storage.setItem(DEVICE_KEY, keys.privateKey.toString('base64'))
  } catch {
    // Out of quota, or private mode. This session still works — it is holding
    // the key in memory — and the next launch will have to pair again.
  }
}

export function clearDeviceKeys(storage: StorageLike): void {
  try {
    storage.removeItem(DEVICE_KEY)
  } catch {
    // Nothing useful to do; the caller is already on its way to the pair screen.
  }
}

/**
 * This browser's identity for this launch, from whichever store has one.
 *
 * Nothing is written here. An unpaired browser gets a pair that exists only in
 * memory, which is what makes merely *visiting* this page on somebody else's
 * computer leave nothing behind — the key reaches a store at the same moment the
 * credential does, and into the same one, because `savePairing` writes them
 * together.
 *
 * A machine will not recognise a key it has never seen, so a browser that lost
 * its key has lost its pairing; that is why the two must never be separated, and
 * why this reads them across the stores in the same order the credential is read
 * in.
 */
export function loadDeviceIdentity(stores: Stores): StaticKeyPair {
  return readAcross(stores, readDeviceKeys)?.value ?? generateStatic()
}
