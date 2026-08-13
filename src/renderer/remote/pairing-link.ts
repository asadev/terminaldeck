/**
 * THE PAIRING LINK — the one place its format is written down.
 *
 * A pairing link is what a phone reads off the QR code on this panel. Four
 * programs have to agree on it and only one of them is in this repository's
 * renderer: the desktop writes it here, `ios/TerminalDeck/Transport/PairingCode.swift`
 * and `android/…/pairing/PairingCode.kt` read it, and `pwa/src/pair.ts` reads
 * the tailnet shape of it. So the format is a contract, not a detail of this
 * component, and this file is the copy the desktop is written against.
 *
 * ## Two shapes, because there are two ways to reach a Mac
 *
 *     terminaldeck://pair?v=1&r=<relay ws url>&h=<host id>&k=<host key>&t=<token>
 *     https://<machine>.<tailnet>.ts.net:8443/#t=<token>
 *
 * The first is the relay path. It carries three things because a phone that has
 * never met this Mac needs all three before it can say a word:
 *
 *   - **`h`** — the 26-character host id from `shared/relay-wire.ts`. It is how
 *     the relay finds this Mac, and it is a name rather than a secret: it is
 *     `BASE32(SHA-256(hostSecret))`, so knowing it does not let anybody claim
 *     it.
 *   - **`k`** — this Mac's X25519 static public key, 32 bytes, base64url. This
 *     is what makes the handshake Noise **IK** rather than trust-on-first-use:
 *     the phone knows which machine it is talking to before it sends anything,
 *     so a relay that swaps itself into the middle fails to decrypt instead of
 *     succeeding as a man in the middle. Without `k` the whole relay path would
 *     be "trust whoever the rendezvous service says this is".
 *   - **`t`** — the single-use pairing token from `device-auth.ts`. The only
 *     secret in the link, worth sixty seconds and one redemption.
 *
 * `r` names the relay, so a build pointed at a relay that is not the default
 * still produces a link a stock phone can follow. `v` is the format version;
 * both phone parsers ignore it today, and it exists so a future shape can be
 * told apart from this one rather than mis-parsed as it.
 *
 * The second shape is the tailnet path the PWA already uses. It carries no key
 * because there is no third party to seal against: the tunnel is the encryption
 * and the certificate on the MagicDNS name is what proves the machine.
 *
 * ## Why the relay link is a query and the tailnet link is a fragment
 *
 * On the `https://` shape the token has to stay out of the request, because
 * every hop that sees a request logs it — access logs, proxy logs, `Referer`
 * headers. A fragment is never sent to a server, which is `pair.ts`'s argument
 * and this file keeps it.
 *
 * On the `terminaldeck://` shape there is no server and no request. The OS hands
 * the whole URL to the app that claims the scheme and nothing else sees it, so
 * the query is safe — and it is also the only shape both phone clients read:
 * the iOS parser reads `URLComponents.queryItems`, which a fragment is not.
 * Writing the fragment form here would produce a link that Android accepts and
 * iOS silently refuses, which is the worst of the three options.
 *
 * ## What is checked here, and what is not
 *
 * Shape, and only shape. Whether the relay is reachable, whether the token is
 * still alive, whether that key is the one this Mac holds — none of those are
 * answerable from a string, and the phones answer them for real a second later.
 * What is refused is anything that cannot be a link: a host id in the wrong
 * alphabet, a key that is not 32 bytes, a relay address that is not a WebSocket
 * URL, a token with whitespace in it. Every one of those would otherwise become
 * a QR code that scans, parses on the phone, and fails with a sentence nobody
 * can act on — and the caller shows the reason instead of the code, because a
 * link that cannot work must not be photographed.
 */

import { BRAND } from '../../shared/brand'

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
 * renderer that pulled it in would ship a Node built-in to a browser bundle.
 * The phone clients restate it for the same reason, which is why
 * `relay-client.test.ts` cross-checks the relay's copy against the desktop's:
 * two implementations of one wire are safe when something fails on the drift,
 * not when nobody edits either.
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

/* -------------------------------------------------------------------------- */
/* Which link to hand over                                                     */
/* -------------------------------------------------------------------------- */

export type PairPath = 'relay' | 'direct'

export interface PairingRoute {
  kind: PairPath
  /** The name on the button that selects it. */
  label: string
  /** What choosing it costs and buys, in one line. */
  note: string
  link: string
}

/** The parts of the remote status a link can be built from. */
export interface PairingSources {
  relay: { url: string; hostId: string; publicKey: string; connected: boolean } | null
  url: string | null
}

/** How each path is named and what choosing it means, in one line each. */
const ROUTE: Record<PairPath, Omit<PairingRoute, 'link'>> = {
  relay: {
    kind: 'relay',
    label: 'Through the relay',
    note: 'The phone will reach this Mac from any network, sealed end to end.',
  },
  direct: {
    kind: 'direct',
    label: 'Direct on your tailnet',
    note: 'One hop and no third party — but this phone will only reach this Mac from your tailnet.',
  },
}

/**
 * Which paths could carry a code right now, best first.
 *
 * The relay comes first when it is connected, and that ordering is a decision
 * about the phone's future rather than about this minute: the code a phone reads
 * is the endpoint it keeps. Pair over the tailnet and the phone can reach this
 * Mac from the tailnet and nowhere else, which is a surprise waiting at an
 * airport. Pair over the relay and it works from both, at the cost of one hop.
 *
 * A relay that is not connected is not a path. Handing over a code for a route
 * that is down produces a phone that scans, waits, and fails — and this panel's
 * one rule is that it never claims a connection that does not exist.
 *
 * Separate from `pairingRoutes` because the Pair button has to know whether
 * pressing it can lead anywhere *before* there is a token to build a link from.
 */
export function pairingPaths(sources: PairingSources): PairPath[] {
  const paths: PairPath[] = []
  const relay = sources.relay
  if (
    relay !== null &&
    relay.connected &&
    isHostId(relay.hostId) &&
    isHostKey(relay.publicKey) &&
    isRelayUrl(relay.url)
  ) {
    paths.push('relay')
  }
  if (sources.url !== null && isDirectUrl(sources.url)) paths.push('direct')
  return paths
}

/** Every path above, with the link a phone would read, best first. */
export function pairingRoutes(sources: PairingSources, token: string): PairingRoute[] {
  return pairingPaths(sources).flatMap((kind): PairingRoute[] => {
    const link =
      kind === 'relay'
        ? relayPairingLink(sources.relay as RelayIdentity, token)
        : directPairingLink(sources.url as string, token)
    return link === null ? [] : [{ ...ROUTE[kind], link }]
  })
}

/**
 * The route to show, honouring the choice while it is still a real one.
 *
 * A path can vanish while a code is on screen — the relay drops, Tailscale is
 * switched off — and the selected one then has to fall back rather than leave a
 * link that no longer goes anywhere on a screen somebody is photographing.
 */
export function chooseRoute(
  routes: readonly PairingRoute[],
  preferred: PairPath | null,
): PairingRoute | null {
  return routes.find((route) => route.kind === preferred) ?? routes[0] ?? null
}
