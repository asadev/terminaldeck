/**
 * The client half of the wire language.
 *
 * The types, the limits *and now the parser* come from
 * `src/main/remote/protocol.ts` — the desktop's own module, imported across the
 * directory boundary rather than restated here.
 *
 * ## Why this file no longer contains a decoder
 *
 * It used to hold a second one, written against the same frames, and a second
 * copy of a wire format is a copy that drifts. The drift does not announce
 * itself: it shows up months later as a phone that has been silently dropping a
 * message type since somebody added it to the desktop. The two had already
 * parted company in one place — an `output`, `status` or `exit` frame whose `id`
 * was the empty string was refused by the desktop's parser and accepted by this
 * one, which is a frame routed to a session that cannot exist and a bug nobody
 * would have traced back to a decoder.
 *
 * `parseServerMessage` is now the only TypeScript reader of an inbound frame in
 * this repository, so there is exactly one place where "what a host can say" is
 * written down, and one test suite that fails when it changes.
 *
 * The copy existed for a real reason and the reason has gone. `parseServerMessage`
 * was added to `protocol.ts` only when a desktop learned to be the *guest* of
 * another desktop and the main process had to read a `welcome` for itself; before
 * that the only client-side reader in this language lived here. The note at the
 * top of that file records the constraint that keeps the import legal and that
 * nothing in either file may break: `protocol.ts` may use no node built-in and no
 * DOM API — not `Buffer`, not `TextEncoder`, not `window` — because this project
 * compiles it with `"types": []` and a single `Buffer` reference in it stops the
 * phone build with `TS2591`. Tree-shaking does not save it; the bundler drops
 * unused code, the compiler still checks it.
 *
 * What stays here is what is genuinely this side's: the browser's own byte
 * counting for a paste (`chunkInput` uses `TextEncoder`, which that file may
 * not), and `decodeLastActivity`, which reads a field that is not part of
 * `RemoteSession` at all — see below.
 *
 * ## Two behaviours this delegation changes, both deliberately
 *
 * 1. An inbound frame larger than `MAX_MESSAGE_BYTES` is now refused, because
 *    `parseServerMessage` refuses it. Every other reader of this wire already
 *    applied that cap; the browser client was the one that did not.
 * 2. Refusal reasons are the desktop's wording now, and a couple of them are
 *    shorter — the old copy quoted the offending value back. Nothing reads a
 *    reason except a log line and one test, and quoting an unparsed value into a
 *    log is a habit worth losing anyway.
 *
 * ## Why inbound frames are validated at all
 *
 * The desktop is not hostile, but it is not always what answers. A captive
 * portal on hotel wifi answers every request with its own login page, and the
 * first thing this client would otherwise do with that is `JSON.parse` an HTML
 * document and then read `.sessions` off the result. Validating means the client
 * says "that is not Terminal Deck" instead of throwing inside a socket handler
 * and leaving a dead screen with no explanation.
 */

import {
  CAPABILITY,
  CREDENTIAL_OPERATIONS,
  MAX_CREDENTIAL_HOST_LENGTH,
  MAX_CREDENTIAL_REPO_LENGTH,
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  parseServerMessage,
  parseSession,
  type ClientMessage,
  type CredentialOperation,
  type DeviceDescriptor,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from '../../src/main/remote/protocol'

export type { ClientMessage, CredentialOperation, DeviceDescriptor, ProtocolErrorCode, RemoteSession, ServerMessage }
export { PROTOCOL_VERSION }

/**
 * What this client tells a desktop it can do, in `hello.capabilities`.
 *
 * Only names that run **desktop → client** belong here. `create`, `localhost`
 * and `upload` are things this page *asks for* and are gated on what the desktop
 * advertised, so claiming them would say nothing.
 *
 * `credential` is here even though this client cannot hold a GitHub token — see
 * `credential.ts`, which explains at length why a browser served by the machine
 * that would be asking is the one place that would be dishonest. What claiming
 * it buys is the difference between two sentences in somebody's terminal: an
 * unadvertised capability makes the desktop answer a push in milliseconds with
 * "your device isn't reachable", about a browser tab that is open and connected,
 * where an advertised one gets an acknowledgement and then a refusal that names
 * the real problem.
 */
export const CLAIMED_CAPABILITIES: string[] = [CAPABILITY.credential]

/**
 * One session row, or null — the desktop's `parseSession`, under the name this
 * client's callers already know it by.
 *
 * Kept as an alias rather than renamed at every call site because the name is
 * the only thing that was ever local about it: a single malformed row does not
 * discard the list, on this side for the same reason as on that one. A phone
 * that shows four of five sessions is useful; a phone that shows none because
 * the fifth had a null title is not.
 */
export { parseSession as decodeSession } from '../../src/main/remote/protocol'

export type DecodeResult =
  | {
      ok: true
      message: ServerMessage
      /**
       * Last-activity times for the rows in a `welcome` or `sessions` frame,
       * when the desktop sent any. Carried beside the message rather than
       * inside it because `RemoteSession` has no such field — see
       * `decodeLastActivity`.
       */
      activity?: ReadonlyMap<string, number>
    }
  | { ok: false; reason: string }

/**
 * When the desktop last saw this session do anything, if it says.
 *
 * `RemoteSession` carries no such field today, so the session list has nothing
 * truthful to print for a session this phone has never attached to, and prints
 * nothing rather than inventing a time. Read defensively here so that the day
 * the desktop starts sending `lastActivityAt` the list improves with no change
 * on this side. See the handoff note — the desktop has this value already, in
 * `session-activity.ts`; it just does not cross the wire.
 *
 * This is the one piece of decoding that stays on this side, and it stays
 * because it is not decoding a wire *type*: it reads a field the shared
 * `ServerMessage` does not have, and putting it into `protocol.ts` would mean
 * either inventing a field on `RemoteSession` that no desktop populates, or
 * exporting a reader for something that is not in the vocabulary.
 */
export function decodeLastActivity(value: unknown): number | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const at = (value as Record<string, unknown>).lastActivityAt
  return typeof at === 'number' && Number.isFinite(at) && at > 0 ? at : null
}

/**
 * The activity times riding along with a list frame, keyed by session id.
 *
 * Costs a second `JSON.parse` of text that has just been parsed inside
 * `parseServerMessage`, which is why the caller only reaches this for the two
 * frames that can carry a session list. `output` is the hot path — one frame per
 * 32 KiB of scrollback — and it never gets here.
 *
 * Only rows that survived `parseSession` are keyed, because the caller stores
 * this map permanently: an entry for a row the parser threw away would be a
 * timestamp for a session that is on nobody's screen, kept until the tab is
 * closed.
 */
function rowActivity(raw: string): ReadonlyMap<string, number> | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    // Unreachable: this exact text parsed a moment ago. It is caught rather
    // than asserted away because an unreachable throw on a socket's data path
    // is how a client ends up with a blank screen and no message, and "no
    // activity times" is the right answer for text this function cannot read.
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const rows = (parsed as { sessions?: unknown }).sessions
  if (!Array.isArray(rows)) return null

  const activity = new Map<string, number>()
  for (const row of rows) {
    const at = decodeLastActivity(row)
    if (at === null) continue
    const session = parseSession(row)
    if (session !== null) activity.set(session.id, at)
  }
  return activity.size > 0 ? activity : null
}

/**
 * Whether a frame is past the shared message cap, decided the cheap way first.
 *
 * A UTF-16 code unit is never fewer than one UTF-8 byte, so `length > cap`
 * already proves it. Below that the count has to be exact: 8,192 emoji are 8,192
 * units and 32,768 bytes. The desktop's own `overBytes` makes the same argument;
 * it is not imported because it is not exported, and a browser has `TextEncoder`
 * where that file may not.
 */
function overMessageCap(raw: string): boolean {
  return raw.length > MAX_MESSAGE_BYTES || encoder.encode(raw).byteLength > MAX_MESSAGE_BYTES
}

/**
 * `credential.request`, which `parseServerMessage` does not read.
 *
 * ## Why there is a second reader here, when the whole point above is that there
 * is only one
 *
 * `parseServerMessage` was added to `protocol.ts` for a desktop acting as the
 * **guest** of another desktop, and that guest speaks protocol v1 and nothing
 * else: it never advertises a capability, so it can never be sent a frame that
 * needs one, and its parser refuses unknown types on exactly that reasoning —
 * "a frame this build has never heard of is one it never asked for". This client
 * *does* ask: it puts `credential` in `hello.capabilities`, which makes
 * `credential.request` a frame it has agreed to receive.
 *
 * So this is not a second copy of the shared parser and must never become one.
 * It is one branch, for one frame the shared parser deliberately does not cover,
 * and everything else still falls through to it unchanged. The right home for it
 * is `parseServerMessage` itself, the day the guest also answers credential
 * requests; moving it there deletes this function and changes nothing else.
 *
 * Null means "not that frame", not "bad frame" — the caller then delegates.
 */
function credentialRequest(raw: string): DecodeResult | null {
  // Over the cap is not this function's refusal to write. Returning null hands
  // the frame to `parseServerMessage`, which refuses it in the shared wording
  // every other reader of this wire uses — and, more to the point, means nothing
  // here ever calls `JSON.parse` on a megabyte handed to it by whatever answered
  // the socket.
  if (overMessageCap(raw)) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null
  const frame = parsed as Record<string, unknown>
  if (frame.t !== 'credential.request') return null

  const id = typeof frame.id === 'string' ? frame.id : ''
  const host = typeof frame.host === 'string' ? frame.host : ''
  // Refused rather than half-read. There is nothing to answer without an id, and
  // nothing to draw without a host — and both are bounded because they end up on
  // a screen somebody reads before deciding what to do about a push.
  if (id === '' || host === '' || host.length > MAX_CREDENTIAL_HOST_LENGTH) {
    return { ok: false, reason: 'incomplete credential.request' }
  }
  // A missing repository and an unusable one are the same answer, and it is null
  // rather than a refusal: the desktop sends null when git gave it no path to
  // derive a name from, which is a legitimate outcome it passes along rather
  // than papering over. What this client does with null is say so.
  const named = typeof frame.repo === 'string' ? frame.repo : ''
  const repo = named !== '' && named.length <= MAX_CREDENTIAL_REPO_LENGTH ? named : null
  // Unrecognised falls to `write`, which is the desktop's own failure direction:
  // saying "read" about a push is the one mistake this field can make that
  // matters.
  const named_operation = CREDENTIAL_OPERATIONS.find((known) => known === frame.operation)
  const operation: CredentialOperation = named_operation ?? 'write'
  return {
    ok: true,
    // `prompt` is an instruction to interrupt a person, so it is acted on only
    // when the desktop said it in so many words.
    message: { t: 'credential.request', id, host, repo, operation, prompt: frame.prompt === true },
  }
}

/** The only door inbound text comes through, mirroring `parseClientMessage`. */
export function decodeServerMessage(raw: string): DecodeResult {
  const credential = credentialRequest(raw)
  if (credential !== null) return credential
  const parsed = parseServerMessage(raw)
  if (!parsed.ok) return parsed
  const message = parsed.message
  // Every other frame type is returned untouched, and returned without a second
  // parse of its text.
  if (message.t !== 'welcome' && message.t !== 'sessions') return { ok: true, message }
  const activity = rowActivity(raw)
  return activity === null ? { ok: true, message } : { ok: true, message, activity }
}

/* ---------------------------------------------------------------- outbound -- */

export function encode(message: ClientMessage): string {
  return JSON.stringify(message)
}

/**
 * The first frame, carrying what this client will *answer* as well as who it is.
 *
 * `capabilities` is load bearing rather than informational: a desktop that does
 * not see `credential` there will never send `credential.request`, so a push
 * from a folder this browser was granted fails in milliseconds with "your device
 * isn't reachable" — about a tab that is open, connected and looking at a
 * terminal. See `CLAIMED_CAPABILITIES` and `credential.ts` for what this client
 * can honestly answer with once it is asked.
 */
export function helloMessage(token: string, device: DeviceDescriptor): ClientMessage {
  return { t: 'hello', protocol: PROTOCOL_VERSION, token, device, capabilities: CLAIMED_CAPABILITIES }
}

const encoder = new TextEncoder()

/**
 * Split a paste into frames the server will accept.
 *
 * `parseClientMessage` rejects an `input` frame over `MAX_INPUT_BYTES` and the
 * server answers a rejected frame by closing the socket. A phone paste is the
 * one realistic way to exceed it — pasting a stack trace into a prompt is a
 * normal thing to do — and losing the connection over it would look like the
 * network dropping rather than like something this client did.
 *
 * Chunks are cut on code-point boundaries: slicing UTF-16 in the middle of a
 * surrogate pair sends two lone halves, which `JSON.stringify` will happily
 * encode and the far end will render as two replacement characters.
 *
 * The desktop's `chunkOutput` does the same job in the other direction and
 * cannot be borrowed for this one: it counts bytes by hand because that file may
 * not touch `TextEncoder`, and it is denominated in the output cap rather than
 * the input one. This is a browser; `TextEncoder` is free here.
 */
export function chunkInput(data: string, maxBytes: number = MAX_INPUT_BYTES): string[] {
  if (data === '') return []
  if (encoder.encode(data).byteLength <= maxBytes) return [data]

  const out: string[] = []
  let current = ''
  let bytes = 0
  for (const point of data) {
    const size = encoder.encode(point).byteLength
    if (bytes + size > maxBytes && current !== '') {
      out.push(current)
      current = ''
      bytes = 0
    }
    current += point
    bytes += size
  }
  if (current !== '') out.push(current)
  return out
}
