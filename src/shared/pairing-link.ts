/**
 * THE PAIRING LINK FORMAT — the one place it is written down.
 *
 * A pairing link is what a phone reads off the QR code, and what a person can
 * paste. Four programs have to agree on it:
 *
 *     terminaldeck://pair?v=1&r=<relay ws url>&h=<host id>&k=<host key>&t=<token>
 *     https://<machine>.<tailnet>.ts.net:8443/#t=<token>
 *
 * the desktop writes it, `ios/TerminalDeck/Transport/PairingCode.swift` and
 * `android/…/pairing/PairingCode.kt` read it, and `pwa/src/pair.ts` reads the
 * tailnet shape. So the format is a contract between programs, not a detail of
 * any one of them.
 *
 * ## Why this is in `shared/` and not beside the panel that draws the QR
 *
 * It used to live in `src/renderer/remote/pairing-link.ts`, whose own header
 * said the format "is a contract, not a detail of this component" — while
 * sitting in the renderer, which only the window can import. That was fine for
 * exactly as long as the window was the only thing that built a link.
 *
 * It stopped being fine the moment the iOS test harness needed to mint a real
 * link to pair a simulator against a real host. `ios/Harness/live-desktop.ts`
 * is compiled by `tsconfig.node.json`, which does not include the renderer, so
 * importing it reached across a project boundary and broke the build with
 * TS6307 — a *composite project* error, which reads like a configuration
 * problem and is actually the architecture telling you where the file belongs.
 *
 * The harness was right to want the real function rather than its own copy: a
 * second implementation of a link format is how a QR code that scans starts
 * failing on the phone. So the format moved to where every side can reach it.
 *
 * ## What is here and what deliberately is not
 *
 * Here: the shape, its validators, and the two functions that write a link.
 * Nothing in this file knows what platform it is running on or has an opinion
 * about which link to offer a person — that is presentation, it needs
 * `detectPlatform`, and it stays in the renderer beside the panel that shows it.
 *
 * ## What is refused, and why refusing is the point
 *
 * A host id in the wrong alphabet, a key that is not 32 bytes, a relay address
 * that is not a WebSocket URL, a token with whitespace in it. Every one of those
 * would otherwise become a QR code that scans, parses on the phone, and fails
 * with a sentence nobody can act on. The caller shows the reason instead of the
 * code, because a link that cannot work must not be photographed.
 */

import { BRAND } from './brand'

/* -------------------------------------------------------------------------- */
/* The pieces, and what each of them has to look like                          */
/* -------------------------------------------------------------------------- */

/** Bumped only for a shape a current phone would misread. Carried as `v`. */
export const PAIRING_LINK_VERSION = '1'

/** `terminaldeck://pair?…`, spelled from the one place the name lives. */
export const PAIRING_LINK_PREFIX = `${BRAND.id}://pair`

/**
 * The host id alphabet, restated rather than imported.
 *
 * `shared/relay-wire.ts` is the definition, and it imports `node:crypto` — a
 * renderer that pulled it in would ship a Node built-in to a browser bundle,
 * and this module is imported by the renderer. The phone clients restate it for
 * the same reason, which is why `relay-client.test.ts` cross-checks the relay's
 * copy against the desktop's: two implementations of one wire are safe when
 * something fails on the drift, not when nobody edits either.
 */
const HOST_ID = /^[A-HJ-NP-Z2-9]{26}$/

/** 32 bytes of base64url is 43 characters, and the padding is optional. */
const HOST_KEY = /^[A-Za-z0-9_-]{43}=?$/

/**
 * Anything a token or an address must not contain: whitespace, and control
 * characters.
 *
 * A loop over code points rather than a character class, because a class
 * carrying raw control bytes is invisible in a diff and survives a careless copy
 * as a plain space. Everything at or below 0x20 is a space or a control
 * character, and 0x7f is delete. No encoding of a token produces any of them, so
 * their presence means something was mangled on the way here — a QR code read
 * off a screenshot, a link through a messaging app.
 */
function isTight(value: string): boolean {
  for (const character of value) {
    const code = character.codePointAt(0) ?? 0
    if (code <= 0x20 || code === 0x7f) return false
  }
  return true
}

/** What the protocol accepts, matching `pair.ts` and both phone parsers. */
export const MAX_TOKEN_LENGTH = 200

export function isHostId(value: string): boolean {
  return HOST_ID.test(value)
}

export function isHostKey(value: string): boolean {
  return HOST_KEY.test(value)
}

/**
 * A relay address a phone will open.
 *
 * `ws://` as well as `wss://` because `relay-client.ts` allows exactly one
 * `ws://` case — a relay running on this machine, for its own tests — and a link
 * builder that refused it would make that path untestable end to end. Nothing is
 * downgraded by it: everything inside the channel is sealed before it reaches
 * the socket, and the relay is treated as hostile either way.
 */
export function isRelayUrl(value: string): boolean {
  return /^wss?:\/\/\S+$/i.test(value) && isTight(value)
}

export function isPairingToken(value: string): boolean {
  return value !== '' && value.length <= MAX_TOKEN_LENGTH && isTight(value)
}

/** An address a phone's browser can open, which is what the tailnet shape is. */
export function isDirectUrl(value: string): boolean {
  return /^https?:\/\/\S+$/i.test(value) && isTight(value)
}

/* -------------------------------------------------------------------------- */
/* Writing one                                                                 */
/* -------------------------------------------------------------------------- */

/** The three published fields of `RelayState` a link is built from. */
export interface RelayIdentity {
  url: string
  hostId: string
  publicKey: string
}

/**
 * The relay link, or null when one of its parts cannot be one.
 *
 * Null rather than a best effort: a link missing its key is a link that pairs
 * against whoever answers, and a link with a truncated host id is a QR code that
 * scans and then fails on the phone with an error about a machine that does not
 * exist.
 */
export function relayPairingLink(relay: RelayIdentity, token: string): string | null {
  if (!isHostId(relay.hostId)) return null
  if (!isHostKey(relay.publicKey)) return null
  if (!isRelayUrl(relay.url)) return null
  if (!isPairingToken(token)) return null
  // `URLSearchParams` percent-encodes every value, which both phone parsers
  // decode. Hand-written concatenation would leave the relay's `://` raw and
  // depend on each parser's tolerance for it.
  const params = new URLSearchParams({
    v: PAIRING_LINK_VERSION,
    r: relay.url,
    h: relay.hostId,
    k: relay.publicKey,
    t: token,
  })
  return `${PAIRING_LINK_PREFIX}?${params.toString()}`
}

/**
 * The tailnet link: the address the desktop serves the PWA on, token in the
 * fragment.
 *
 * `#t=<token>` rather than a bare `#<token>`, because the reader on the other
 * end is `readPairToken` in `pwa/src/pair.ts` and it parses the fragment as a
 * query string — a bare token arrives there as a parameter *name* with no value
 * and reads as no token at all. Any fragment already on the base is replaced
 * rather than appended to: two hashes would make the token part of the first
 * one's value.
 */
export function directPairingLink(base: string, token: string): string | null {
  if (!isDirectUrl(base)) return null
  if (!isPairingToken(token)) return null
  const root = base.replace(/#.*$/, '').replace(/\/+$/, '')
  return `${root}/#t=${encodeURIComponent(token)}`
}
