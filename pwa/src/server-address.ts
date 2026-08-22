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
 *   - **the token a machine actually prints** — `srv1.` and then base64url of
 *     that object — found wherever it sits in the block printed around it;
 *   - the object as JSON, printed plainly;
 *   - the object as base64 or base64url, with or without a `scheme:` in front
 *     of it, and with any whitespace a line wrap introduced;
 *   - a query string, `…?r=…&h=…&k=…` or the long spellings, which is the shape
 *     a link has if one is ever printed as one.
 *
 * The first of those is the one that matters and the one that was missing: it
 * is what `formatServerAddress` writes and what `terminaldeck address` prints,
 * and until it was read here every paste of a real address was refused. The
 * rest are tolerances around it.
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

import {
  SERVER_ADDRESS_PREFIX,
  SERVER_ADDRESS_VERSION,
  parseServerAddress,
} from '../../src/shared/server-address'
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
 * Three, not one, because the sentences differ and so does the reader's next
 * action. `empty` is a field nobody has filled in and wants no error styling at
 * all. `unreadable` is something that was pasted and is not an address, and the
 * fix is to copy the block again. `version` is the one that is *definitely* an
 * address and still cannot be used — the fix for that is a software update, and
 * saying `unreadable` about it would send somebody back to their clipboard
 * forever over a perfectly good paste.
 */
export type AddressFault = 'empty' | 'unreadable' | 'version'

export type ReadAddress =
  | { ok: true; endpoint: RelayEndpoint }
  | { ok: false; fault: 'empty' | 'unreadable' }
  /** What the token announced itself as, so the sentence can say which two builds disagree. */
  | { ok: false; fault: 'version'; version: number }

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

/* --------------------------------------------------- the versioned token -- */

/**
 * `srv1.<base64url>` — the shape a machine actually prints, which is the one
 * this file did not read.
 *
 * ## The bug this exists to have not shipped
 *
 * The three readers below were written against the *object*, which is the right
 * contract and is genuinely what every one of them decodes to. What none of them
 * had ever seen is the string a host puts on a console, because the encoder and
 * the three client screens were built in parallel and nothing fed one into the
 * other. `formatServerAddress` writes a version prefix in front of the base64 —
 * `srv1.` — and `fromBlob` drops a leading `scheme:` and nothing else, so the
 * `.` survived into the decoder, `Buffer` ignored the character it did not
 * recognise, and the JSON came out shifted and unparseable. Every phone would
 * have refused the address on paste: the whole feature, dead, with a green
 * suite behind it. `server-address-seam.test.ts` now feeds this reader the real
 * encoder's real output so that cannot recur.
 *
 * ## Why the token is looked for rather than required at the front
 *
 * Because of what `renderAddress` in `src/headless/cli.ts` prints: a `Server
 * address` heading, the token indented under it, then two sentences about what
 * to do with it and that it is not a secret. Somebody selecting that on a phone
 * gets the heading and at least one of the sentences, and refusing that paste
 * teaches them to trim a selection rather than to use the app. So each
 * whitespace-separated chunk is tested on its own, and the token is accepted
 * wherever in the block it sits.
 *
 * The last candidate is the whole paste with its whitespace removed, which
 * covers the other thing a clipboard does to one long token: a terminal that
 * wrapped it at eighty columns, or a chat app that inserted a newline.
 *
 * The body is held to base64url and to a length no accident reaches, so a `.`
 * in ordinary prose cannot be read as a version announcement — the difference
 * between "that is not an address" and "your app is too old" is a sentence
 * somebody acts on, and it has to be right.
 */
const VERSIONED_TOKEN = /^[<"'`([]*srv([0-9]{1,4})\.([A-Za-z0-9_-]{16,})[)\]>"'`,;.]*$/i

/** A token that named a format, and the format it named. */
interface Announced {
  version: number
  body: string
}

/**
 * Every candidate, not the first one — because the first one is often wrong.
 *
 * A wrapped address puts `srv1.` at the head of a line and the rest of the body
 * on the two lines below it, so the leading chunk is a token by every rule here
 * and decodes to nothing. Returning it and stopping would refuse the exact paste
 * the whitespace-joined candidate at the end of this list exists to catch.
 */
function announced(text: string): Announced[] {
  const out: Announced[] = []
  for (const chunk of [...text.split(/\s+/), text.replace(/\s+/g, '')]) {
    const found = VERSIONED_TOKEN.exec(chunk)
    if (found !== null) out.push({ version: Number(found[1]), body: found[2] })
  }
  return out
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

  // First, because it is the only shape that says out loud what it is, and
  // because it is the shape a machine actually prints.
  const tokens = announced(text)
  for (const token of tokens) {
    if (token.version !== SERVER_ADDRESS_VERSION) continue
    // Decoded by the encoder's own reader rather than by a second decoder
    // written here: one implementation of the token, one place the base64url
    // fold lives, and `asEndpoint` still makes this client's own decision about
    // whether what came out is dialable.
    const endpoint = asEndpoint(parseServerAddress(`${SERVER_ADDRESS_PREFIX}${token.body}`))
    if (endpoint.kind === 'relay') return { ok: true, endpoint }
  }

  for (const read of [fromJson, fromQuery, fromBlob]) {
    const endpoint = asEndpoint(asRelayShape(read(text)))
    if (endpoint.kind === 'relay') return { ok: true, endpoint }
  }

  // Last, and only once nothing in the paste worked: a token announcing a
  // format this build does not read is the *reason* nothing worked, and it is a
  // different sentence from "that is not an address" — but a paste that also
  // contained something readable was never a version problem.
  const foreign = tokens.find((token) => token.version !== SERVER_ADDRESS_VERSION)
  if (foreign !== undefined) return { ok: false, fault: 'version', version: foreign.version }
  return { ok: false, fault: 'unreadable' }
}
