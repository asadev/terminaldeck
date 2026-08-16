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
 * `parseServerFrame` is now the only TypeScript reader of an inbound frame in
 * this repository — `parseServerMessage` is the same reader with the text still
 * around it — so there is exactly one place where "what a host can say" is
 * written down, and one test suite that fails when it changes.
 *
 * The copy existed for a real reason and the reason has gone. That parser
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
 * 1. An inbound frame larger than `MAX_MESSAGE_BYTES` is now refused, in the
 *    shared wording, before anything decodes it. Every other reader of this
 *    wire already applied that cap; the browser client was the one that did
 *    not. `decodeServerMessage` holds it here rather than inheriting it from
 *    the shared parser, because it is the half that still has the text: once a
 *    frame is an object there is nothing left to measure.
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
  DEV_SERVER_STATUSES,
  MAX_CREDENTIAL_HOST_LENGTH,
  MAX_CREDENTIAL_REPO_LENGTH,
  MAX_CWD_BYTES,
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  parseServerFrame,
  parseSession,
  type ClientMessage,
  type CredentialOperation,
  type DevServerReport,
  type DevServerStatus,
  type DeviceDescriptor,
  type LocalPort,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from '../../src/main/remote/protocol'

export type {
  ClientMessage,
  CredentialOperation,
  DevServerReport,
  DevServerStatus,
  DeviceDescriptor,
  LocalPort,
  ProtocolErrorCode,
  RemoteSession,
  ServerMessage,
}
export { CAPABILITY, PROTOCOL_VERSION }

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
 * Takes the decoded frame rather than its text. It used to take the text and
 * `JSON.parse` it a second time, and the note here defended that cost by
 * pointing out how rarely it is reached; `decodeServerMessage` parses once now
 * and hands the same value to everything, so there is no cost left to defend.
 * The caller still asks only for `welcome` and `sessions`, because they are the
 * only two frames that can carry a session list to read times off.
 *
 * Only rows that survived `parseSession` are keyed, because the caller stores
 * this map permanently: an entry for a row the parser threw away would be a
 * timestamp for a session that is on nobody's screen, kept until the tab is
 * closed.
 */
function rowActivity(parsed: unknown): ReadonlyMap<string, number> | null {
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
 * `credential.request`, which `parseServerFrame` does not read.
 *
 * ## Why there is a second reader here, when the whole point above is that there
 * is only one
 *
 * The shared parser was added to `protocol.ts` for a desktop acting as the
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
 * is `parseServerFrame` itself, the day the guest also answers credential
 * requests; moving it there deletes this function and changes nothing else.
 *
 * Takes the decoded frame, not the text. It used to take the text, check the cap
 * and `JSON.parse` for itself, which meant every inbound frame — `output`
 * included, one per 32 KiB of scrollback — was parsed twice: once to find out it
 * was not a credential request, and once by the shared parser that then read it
 * properly. The probe is a look at one field; it does not need a parse of its
 * own.
 *
 * Null means "not that frame", not "bad frame" — the caller then delegates.
 */
function credentialRequest(parsed: unknown): DecodeResult | null {
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

/**
 * The three `localhost` frames, which `parseServerFrame` does not read either.
 *
 * ## Why this is a second exception and not the start of a habit
 *
 * The argument is `credentialRequest`'s, word for word, applied to a different
 * capability. The shared parser was written for a desktop acting as the **guest**
 * of another desktop; that guest speaks protocol v1 and negotiates nothing, so a
 * frame it has never heard of is genuinely one it never asked for, and refusing
 * unknown types is right *for it*. This client negotiates. It reads
 * `welcome.capabilities`, and it sends `{"t":"ports"}` only after seeing
 * `localhost` in there — which makes `ports`, `tunnel.opened` and `tunnel.closed`
 * frames it has agreed to receive, exactly as `credential` in `hello.capabilities`
 * makes `credential.request` one.
 *
 * The right home for all six branches is `parseServerFrame` itself, the day the
 * guest also tunnels. Moving them there deletes this function and changes
 * nothing else.
 *
 * ## Why there are three and not seven
 *
 * `net.data`, `net.ack` and `net.close` are deliberately absent, and their
 * absence is a statement about what this client does rather than an oversight.
 * A byte stream inside a tunnel begins with a `net.open` that this client never
 * sends — see `localhost.ts` for why a browser tab cannot host one — so
 * `openStream` in the desktop's `tunnel.ts` is never reached and no `net.*`
 * frame can originate. Reading frames nobody can send would be a parser for a
 * conversation this client is not in.
 *
 * Null means "not one of mine", not "bad frame": the caller then delegates to
 * the shared parser, which is what every other message type still goes through.
 */
function localhostFrame(parsed: unknown): DecodeResult | null {
  if (typeof parsed !== 'object' || parsed === null) return null
  const frame = parsed as Record<string, unknown>

  if (frame.t === 'ports') {
    const rows = frame.ports
    // A frame with no list at all is refused rather than read as "nothing is
    // listening" — the same argument the shared parser makes about `folders`.
    // An empty machine and a malformed message are different facts, and the
    // screen says different things about them.
    if (!Array.isArray(rows)) return { ok: false, reason: 'ports without a list' }
    const ports: LocalPort[] = []
    for (const row of rows) {
      // One bad row does not discard the list, for the same reason `parseSession`
      // does not: a page showing nine of ten ports is useful, and one showing
      // none because the tenth had a null process name is not.
      const port = plausiblePort(row)
      if (port !== null) ports.push(port)
    }
    return { ok: true, message: { t: 'ports', ports } }
  }

  if (frame.t === 'tunnel.opened') {
    const id = typeof frame.id === 'string' ? frame.id : ''
    const port = wholePort(frame.port)
    if (id === '' || port === null) return { ok: false, reason: 'incomplete tunnel.opened' }
    return { ok: true, message: { t: 'tunnel.opened', id, port } }
  }

  if (frame.t === 'tunnel.closed') {
    const id = typeof frame.id === 'string' ? frame.id : ''
    if (id === '') return { ok: false, reason: 'tunnel.closed without an id' }
    // The sentence is the whole payload of this frame — it is the desktop
    // explaining a refusal in words a person reads — so an absent one is
    // accepted as the empty string and the screen supplies its own. Bounded
    // because it lands on a screen; `plain` in main.ts strips control bytes out
    // of it, like every other string that came off this socket.
    const said = typeof frame.message === 'string' ? frame.message : ''
    return { ok: true, message: { t: 'tunnel.closed', id, message: said.slice(0, MAX_REFUSAL_CHARS) } }
  }

  return null
}

/**
 * `dev.state`, the third frame `parseServerFrame` does not read.
 *
 * ## Why this is the third exception and still not a habit
 *
 * The argument is `credentialRequest`'s and `localhostFrame`'s, applied to a
 * third capability, and it is the same argument because it is the same seam: the
 * shared parser was written for a desktop acting as the **guest** of another
 * desktop, and that guest negotiates nothing, so refusing a frame it has never
 * heard of is right *for it*. This client negotiates. It reads
 * `welcome.capabilities` and sends `dev.status` only after seeing `devserver` in
 * there, which makes `dev.state` a frame it has agreed to receive.
 *
 * The right home for all seven branches is `parseServerFrame` itself, the day the
 * guest also starts dev servers. Moving them there deletes these functions and
 * changes nothing else.
 *
 * ## What is refused and what is merely dropped
 *
 * A frame with no folder, or with a status this build has never heard of, is
 * **refused whole**. That is deliberately harsher than the port list one row
 * over, and the asymmetry is the point: a bad row in a list of ten leaves nine
 * useful ones, whereas this frame *is* the one project, and a row drawn as some
 * other state is precisely the wrong thing — a sixth status added on the desktop
 * should produce a missing row in an old client, never a row that lies about
 * which state it is in. `DevServerPanel.tsx` drops such a row on the desktop for
 * the same reason and in the same words.
 *
 * Every optional field is taken only when it is genuinely there and genuinely
 * usable, and never invented. The fields are not independent — `port` and `url`
 * exist only on `ready`, `message` only on `failed` — so a reader that filled in
 * a blank would be manufacturing the one state this capability's author calls
 * the genuinely wrong thing to display.
 */
function devStateFrame(parsed: unknown): DecodeResult | null {
  if (typeof parsed !== 'object' || parsed === null) return null
  const frame = parsed as Record<string, unknown>
  if (frame.t !== 'dev.state') return null

  const raw = frame.state
  if (typeof raw !== 'object' || raw === null) return { ok: false, reason: 'dev.state without a state' }
  const row = raw as Record<string, unknown>

  // Bounded by the same cap the wire puts on a folder anywhere else, because it
  // is the same value: the desktop echoes back its own spelling of a path it
  // already offered, and a client keying its rows on this string should not key
  // them on a megabyte.
  const folder = typeof row.folder === 'string' ? row.folder : ''
  if (folder === '' || folder.length > MAX_CWD_BYTES) {
    return { ok: false, reason: 'dev.state without a folder' }
  }
  const status = DEV_SERVER_STATUSES.find((known) => known === row.status)
  if (status === undefined) return { ok: false, reason: 'dev.state with an unknown status' }

  const state: DevServerReport = { folder, status }
  const port = wholePort(row.port)
  if (port !== null) state.port = port
  for (const field of ['script', 'command', 'sessionId', 'url'] as const) {
    const value = row[field]
    // Short by nature — a script name, a command line, a session id, a
    // `http://localhost:3000`. The cap is what stops a machine having a bad day
    // from pushing a wall of text into a row somebody is trying to read.
    if (typeof value === 'string' && value !== '' && value.length <= MAX_DEV_FIELD_CHARS) {
      state[field] = value
    }
  }
  // `note` is the dev server's own latest output line and `message` is the
  // desktop's sentence about a failure. Both are display text that lands on a
  // screen, both go through `plain` in main.ts like every other string that came
  // off this socket, and neither is ever parsed — the note especially, which is
  // bytes a process on somebody's machine printed.
  for (const field of ['note', 'message'] as const) {
    const value = row[field]
    if (typeof value === 'string' && value !== '') state[field] = value.slice(0, MAX_REFUSAL_CHARS)
  }
  return { ok: true, message: { t: 'dev.state', state } }
}

/**
 * How long a script name, a command line, a session id or a URL may be.
 *
 * All four are short in reality and all four are drawn on one line of a row, so
 * this is a display bound rather than a security one — `MAX_MESSAGE_BYTES` has
 * already been applied to the whole frame before any of this runs.
 */
const MAX_DEV_FIELD_CHARS = 512

/**
 * How much of a desktop's refusal is worth putting on a phone.
 *
 * The real ones are one sentence — `tunnel.ts` writes them — and the cap is here
 * so that a machine having a bad day cannot push a wall of text into a card
 * somebody is trying to read. Not a security bound; `MAX_MESSAGE_BYTES` is
 * already applied to the whole frame before anything here runs.
 */
const MAX_REFUSAL_CHARS = 300

/** A port number as the wire may carry one: a whole number in the TCP range. */
function wholePort(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isInteger(value)) return null
  return value >= 1 && value <= 65535 ? value : null
}

/**
 * One row of the port list, or null.
 *
 * `guessed` is the desktop's own word for "the process name is unknown" — see
 * `dev-ports.ts`, which sets `process: 'unknown', guessed: true` for a port
 * whose owner it could not name. So a row that arrives with an implausible name
 * is folded into exactly that shape rather than being dropped or truncated: the
 * port is real, it is answering, and the screen can say so honestly without
 * repeating a string that is not a process name.
 */
function plausiblePort(value: unknown): LocalPort | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const port = wholePort(row.port)
  if (port === null) return null
  const named = typeof row.process === 'string' ? row.process : ''
  const usable = named !== '' && named.length <= MAX_PROCESS_NAME_CHARS
  return {
    port,
    process: usable ? named : 'unknown',
    // True whenever the desktop said so *or* whenever this end could not use
    // the name it sent. Either way the honest claim is the same one.
    guessed: row.guessed === true || !usable,
  }
}

/** A command name, not a command line. `lsof` and `tasklist` both answer short. */
const MAX_PROCESS_NAME_CHARS = 64

/**
 * The only door inbound text comes through, mirroring `parseClientMessage`.
 *
 * One parse, then branches. The three readers below all want the same decoded
 * frame and used to take the text and decode it for themselves — the credential
 * probe, the shared parser, and the activity-time reader — so a `welcome`
 * arrived as three `JSON.parse` calls over identical bytes and every `output`
 * frame as two. The refusals and their wording are unchanged: the cap is applied
 * before anything is decoded, which is the property that stops a megabyte from a
 * captive portal being parsed at all, and the sentences are still the shared
 * ones every other reader of this wire uses.
 */
export function decodeServerMessage(raw: string): DecodeResult {
  // Before the parse, never after. Held here rather than inside the readers
  // because there is nothing left to measure once text is an object, and a cap
  // applied after decoding is a cap that has already been paid.
  if (overMessageCap(raw)) return { ok: false, reason: 'larger than the message cap' }
  let frame: unknown
  try {
    frame = JSON.parse(raw)
  } catch {
    // A captive portal answering with its own login page lands here, which is
    // the case this whole function is defensive for.
    return { ok: false, reason: 'not JSON' }
  }

  const credential = credentialRequest(frame)
  if (credential !== null) return credential
  const localhost = localhostFrame(frame)
  if (localhost !== null) return localhost
  const dev = devStateFrame(frame)
  if (dev !== null) return dev
  const parsed = parseServerFrame(frame)
  if (!parsed.ok) return parsed
  const message = parsed.message
  if (message.t !== 'welcome' && message.t !== 'sessions') return { ok: true, message }
  const activity = rowActivity(frame)
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
