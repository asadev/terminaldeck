/**
 * The address a server prints, read back out of a paste.
 *
 * ## Why a browser needs one at all, when a phone has six digits
 *
 * Pairing is six digits and a rendezvous, and it works because somebody is
 * *standing at the machine* to read them off its screen. That is exactly the
 * person a headless server does not have. A box in a rack with `sshd` and no
 * display cannot show a code to anybody, and the whole point of sign-in is that
 * the account the machine already trusts is the credential — no second person,
 * no second screen.
 *
 * So the machine prints its address once, on its own console, and it is pasted
 * here. What that address must carry is not negotiable and is the same three
 * facts `endpoint.ts` documents at length:
 *
 *   - **relayUrl** — which rendezvous service to open,
 *   - **hostId** — which slot at it, 26 characters of the relay's base32,
 *   - **hostKey** — the machine's X25519 static public key.
 *
 * The third is why a host id alone can never be enough, and it is worth saying
 * once here because it is the reason this screen did not exist until now: a host
 * id is `BASE32(SHA-256(secret))`, a one-way hash, and a Noise **IK** handshake
 * needs the responder's actual key before it can send its first message. A form
 * that took a host id and nothing else would be a form whose Connect button
 * cannot be implemented.
 *
 * ## What is a contract here, and what is merely tolerated
 *
 * The **contract is the object**: `{ kind: 'relay', url, hostId, hostKey }`,
 * which is precisely what {@link asEndpoint} already validates and what this
 * client already stores against every relay pairing. Every encoding below
 * decodes to that object and is then handed to `asEndpoint` — so the three facts
 * are validated in exactly one place, by the function the rest of the client
 * already trusts, rather than by a second validator that can drift from it.
 *
 * The **encodings are tolerated, not specified**. A person pasting an address
 * off a terminal is pasting whatever that terminal printed, possibly through a
 * chat app that wrapped it, possibly with the shell's prompt still stuck to the
 * front. Refusing a perfectly good address because it arrived base64url instead
 * of base64 — or because somebody's copy took the surrounding quotes with it —
 * is a dead form with a correct-looking validator behind it. So this reads:
 *
 *   - the object as JSON, printed plainly;
 *   - the object as base64 or base64url, with or without a `scheme:` in front
 *     of it, and with any whitespace a line wrap introduced;
 *   - a query string, `…?r=…&h=…&k=…` or the long spellings, which is the shape
 *     a link has if one is ever printed as one.
 *
 * Field names are folded the same way: `url`/`relayUrl`/`relay`/`r`,
 * `hostId`/`host`/`h`, `hostKey`/`publicKey`/`key`/`k`. The last of those
 * matters more than it looks — `publicKey` is the spelling a *rendezvous offer*
 * uses (`rendezvous.ts`, `machines/ipc.ts`), so a machine that prints its offer
 * verbatim is understood rather than refused.
 *
 * ## No secret is in here, and that is the difference from the old link
 *
 * `pairing-link.ts` explains why `terminaldeck://pair?…` was deleted: it carried
 * a live bearer token, and its only route between two machines was a messaging
 * app that keeps a copy. None of the three facts above is a secret. A host id is
 * a public name, a relay URL is a public service, and a static public key is
 * public by construction — an address is worth exactly as much to somebody who
 * steals it as a hostname is, because what it opens is a channel that then asks
 * for a login. It is safe to print, safe to paste, and safe to leave in a
 * password manager.
 */

import { asEndpoint, type RelayEndpoint } from './endpoint'

/**
 * The longest paste this will look at.
 *
 * The same bound `rendezvous.ts` puts on an offer, and for the same reason: a
 * field somebody pastes into is a field somebody can paste a megabyte into, and
 * nothing legitimate here is more than a few hundred characters. Refused rather
 * than truncated — a truncated address is a malformed one, and saying "that is
 * not an address" about something this client cut in half would be a lie.
 */
export const MAX_ADDRESS_LENGTH = 4 * 1024

/**
 * Why an address could not be read.
 *
 * Two, not one, because the sentences differ and the reader's next action does
 * too: `empty` is a field nobody has filled in and wants no error styling at
 * all, while `unreadable` is something that was pasted and is not an address.
 */
export type AddressFault = 'empty' | 'unreadable'

export type ReadAddress = { ok: true; endpoint: RelayEndpoint } | { ok: false; fault: AddressFault }

/** The spellings each of the three facts arrives under. Most specific first. */
const URL_KEYS = ['url', 'relayUrl', 'relay', 'r'] as const
const HOST_ID_KEYS = ['hostId', 'host', 'h'] as const
const HOST_KEY_KEYS = ['hostKey', 'publicKey', 'key', 'k'] as const

function pick(record: Record<string, unknown>, names: readonly string[]): unknown {
  for (const name of names) {
    const value = record[name]
    if (typeof value === 'string' && value !== '') return value
  }
  return undefined
}

/**
 * One decoded thing, folded onto the shape `asEndpoint` validates.
 *
 * Nothing is checked here on purpose. Whether a URL is a relay URL, whether a
 * host id is in the alphabet and whether a key is 32 bytes in either base64 is
 * `asEndpoint`'s decision and stays `asEndpoint`'s decision; this only decides
 * which field of the paste is meant to be which.
 */
function asRelayShape(value: unknown): unknown {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  return {
    kind: 'relay',
    url: pick(record, URL_KEYS),
    hostId: pick(record, HOST_ID_KEYS),
    hostKey: pick(record, HOST_KEY_KEYS),
  }
}

/** JSON, printed plainly. Anything that is not an object falls through to null. */
function fromJson(text: string): unknown {
  if (!text.startsWith('{')) return null
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

/**
 * A query string, wherever it starts.
 *
 * `URLSearchParams` rather than `new URL`, because the scheme in front of it may
 * be one no browser knows — `terminaldeck://server?…` is not something `URL` is
 * obliged to parse, and a custom scheme must not be the thing that decides
 * whether an address is readable.
 */
function fromQuery(text: string): unknown {
  const at = text.indexOf('?')
  if (at === -1) return null
  const query = text.slice(at + 1).split('#')[0] ?? ''
  if (query === '') return null
  const found: Record<string, unknown> = {}
  for (const [name, value] of new URLSearchParams(query)) found[name] = value
  return found
}

/**
 * base64 or base64url of the JSON, with the noise a paste collects.
 *
 * A leading `scheme:` and its `//` are dropped, a `#` fragment is preferred over
 * what precedes it, and every space and line break is removed before decoding —
 * a terminal that wrapped the line at eighty columns and a chat app that
 * inserted a newline both produce an address that is otherwise perfect.
 *
 * `-` and `_` are folded to `+` and `/` rather than the encoding being selected,
 * for the reason `hostKeyBytes` states: the `Buffer` behind this client is the
 * `buffer` package, which does not know the name `base64url` and silently
 * *drops* those two characters instead of translating them.
 */
function fromBlob(text: string): unknown {
  const hash = text.lastIndexOf('#')
  let body = hash === -1 ? text : text.slice(hash + 1)
  if (hash === -1) {
    const scheme = /^[a-z][a-z0-9+.-]*:(\/\/)?/i.exec(body)
    if (scheme !== null) body = body.slice(scheme[0].length)
  }
  body = body.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/')
  if (body === '') return null
  const decoded = Buffer.from(body, 'base64').toString('utf8')
  return fromJson(decoded.trim())
}

/**
 * Read a pasted address, or say which way it failed.
 *
 * The three readers are tried in order and the first one that yields a *valid*
 * relay endpoint wins — validity being `asEndpoint`'s answer, not this
 * function's. Trying all three rather than picking one by looking at the string
 * is deliberate: a guess about which encoding this is would be one more thing to
 * be wrong about, and each reader is cheap and total.
 */
export function readServerAddress(raw: string): ReadAddress {
  // Quotes and angle brackets come along when an address is copied out of a
  // JSON blob, a shell one-liner or an email that auto-linked it.
  const text = raw.trim().replace(/^[<"'`]+/, '').replace(/[>"'`]+$/, '').trim()
  if (text === '') return { ok: false, fault: 'empty' }
  if (text.length > MAX_ADDRESS_LENGTH) return { ok: false, fault: 'unreadable' }

  for (const read of [fromJson, fromQuery, fromBlob]) {
    const endpoint = asEndpoint(asRelayShape(read(text)))
    if (endpoint.kind === 'relay') return { ok: true, endpoint }
  }
  return { ok: false, fault: 'unreadable' }
}
