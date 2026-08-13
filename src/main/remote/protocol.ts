/**
 * The wire language between the desktop app and a phone on the tailnet.
 *
 * Everything crossing the socket is a single JSON object with a `t` tag. Two
 * rules keep this honest, and both are about the fact that the other end is not
 * our code once the PWA is installed on someone's phone:
 *
 *  1. Nothing is trusted. `parseClientMessage` is the only way an inbound frame
 *     becomes a typed value, and it narrows every field itself rather than
 *     casting. A cast here would be a `SessionAccess.write` with whatever the
 *     phone sent as the session id.
 *  2. Sizes are bounded at this layer as well as at the frame layer. A frame
 *     under the cap can still carry a megabyte of `data`, and that gets typed
 *     into a real terminal.
 *
 * Version 1 is deliberately tiny: list, attach, input, resize. Anything richer
 * (file trees, cost, git) is the desktop's job — the phone is a window onto a
 * session that is already running, not a second copy of the app.
 *
 * ## This file runs in a browser too
 *
 * `pwa/src/protocol-client.ts` imports it, so it may use no node built-in and
 * no DOM API — not `Buffer`, not `TextEncoder`, not `window`. That is not a
 * style rule. An earlier draft counted paste size with `Buffer.byteLength`, and
 * `npx tsc -p pwa/tsconfig.json` on this machine answered:
 *
 *     src/main/remote/protocol.ts(194,11): error TS2591: Cannot find name 'Buffer'
 *
 * The phone project sets `"types": []`, so importing a type out of this module
 * pulls the whole file into that program and the build stops. Tree-shaking does
 * not save it: the bundler drops unused code, the compiler still checks it.
 *
 * Byte counting therefore happens in `utf8Length` below, which needs nothing
 * from either runtime.
 *
 * ## Where the boundary of this file is
 *
 * It shape-checks; it does not authorise. A `sessionId` that satisfies `ID_RE`
 * is a plausible id and nothing more — whether it names a live session, and
 * whether this device may talk to it, are the server's questions, answered
 * against real sessions in `SessionAccess` and against real pairings in
 * `device-auth.ts`. A parser that appeared to answer them would be the most dangerous
 * kind of wrong.
 */

/** Bumped only for a breaking change; the server refuses a mismatch. */
export const PROTOCOL_VERSION = 1

/**
 * Largest inbound WebSocket message, fragments included.
 *
 * Inbound traffic is keystrokes and short commands — a big paste is the
 * realistic maximum. 64 KiB is roughly a thousand times a normal message and
 * still small enough that a client cannot make the main process buffer.
 *
 * Enforced here as well as at the socket: a text frame is measured before it is
 * decoded, so an oversized one is refused rather than parsed. It is a cap on the
 * encoded frame, so it applies to the string path only - a caller that hands
 * over an already-decoded object has no frame to measure, and what bounds that
 * path is the per-field caps below.
 */
export const MAX_MESSAGE_BYTES = 64 * 1024

/** Largest `input` payload. A paste, not a file upload. */
export const MAX_INPUT_BYTES = 16 * 1024

/**
 * How much replay or live output goes in one `output` frame.
 *
 * Scrollback can be megabytes. Sent whole it would be one JSON string the phone
 * has to parse in a single tick — visibly janky on a phone — and it would blow
 * past whatever inbound cap the client applies to us in return.
 */
export const OUTPUT_CHUNK_BYTES = 32 * 1024

/** Terminal sizes a phone can plausibly ask for; anything else is a bug or an attack. */
export const MIN_COLS = 20
export const MAX_COLS = 500
export const MIN_ROWS = 5
export const MAX_ROWS = 200

/**
 * Longest `hello.token`.
 *
 * The field carries an opaque bearer secret minted by `device-auth.ts`, so it
 * is bounded rather than pinned to one shape — see the note on `token()`.
 */
const MAX_TOKEN_LENGTH = 200

/** WebSocket close codes used here, RFC 6455 §7.4.1 plus our own reasons. */
export const CLOSE = {
  normal: 1000,
  goingAway: 1001,
  protocolError: 1002,
  unsupportedData: 1003,
  policyViolation: 1008,
  messageTooBig: 1009,
  internalError: 1011,
  tryAgainLater: 1013,
} as const

/** A session as the phone sees it. Enough to draw a list and pick one. */
export interface RemoteSession {
  id: string
  title: string
  cwd: string
  provider: string
  /** Free-form on purpose: the status vocabulary belongs to the session layer. */
  status: string
  exitCode: number | null
}

/** Identity a phone volunteers about itself. Display only — never trusted. */
export interface DeviceDescriptor {
  name: string
  platform: string
}

export type ClientMessage =
  | { t: 'hello'; protocol: number; token: string; device: DeviceDescriptor }
  | { t: 'list' }
  /**
   * `cols`/`rows` are the phone's viewport, and they travel with the attach so
   * the first screen arrives already the right shape. They are optional because
   * a client that has not measured its terminal yet must still be able to
   * attach and then `resize`; both or neither, never one.
   */
  | { t: 'attach'; id: string; cols?: number; rows?: number }
  | { t: 'detach'; id: string }
  | { t: 'input'; id: string; data: string }
  | { t: 'resize'; id: string; cols: number; rows: number }
  | { t: 'ping' }

export type ServerMessage =
  | { t: 'welcome'; protocol: number; deviceId: string; deviceName: string; token: string | null; sessions: RemoteSession[] }
  | { t: 'sessions'; sessions: RemoteSession[] }
  | { t: 'attached'; id: string }
  | { t: 'detached'; id: string }
  /** `replay` marks scrollback that arrived before this client did. */
  | { t: 'output'; id: string; data: string; replay?: true }
  | { t: 'status'; id: string; status: string }
  | { t: 'exit'; id: string; exitCode: number }
  | { t: 'error'; code: ProtocolErrorCode; message: string }
  | { t: 'pong' }

export type ProtocolErrorCode =
  | 'bad-message'
  | 'unauthenticated'
  | 'unauthorized'
  | 'unknown-session'
  | 'too-large'
  | 'version'

/**
 * A refusal carries a code as well as a reason.
 *
 * The code is what the server puts in an `error` frame and what decides the
 * close code; the reason is for the desktop's log. Both come from here so the
 * two ends cannot disagree about which refusals exist — the client validates
 * `code` against this same union before it will believe an error frame.
 *
 * Reasons never quote the value that was refused. They are logged and sent back
 * over the wire, and echoing attacker-chosen text into both at once is how a
 * parser becomes someone else's output channel.
 */
export type ParseResult =
  | { ok: true; message: ClientMessage }
  | { ok: false; code: ProtocolErrorCode; reason: string }

/* ------------------------------------------------------------------ checks -- */

const bad = (reason: string): ParseResult => ({ ok: false, code: 'bad-message', reason })
const tooLarge = (reason: string): ParseResult => ({ ok: false, code: 'too-large', reason })

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Session ids are UUIDs from the session layer; treat anything else as hostile. */
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/

function id(value: unknown): string | null {
  return typeof value === 'string' && ID_RE.test(value) ? value : null
}

/**
 * `Number.isInteger` is false for `NaN` and for both infinities, which is the
 * property this relies on: a client that computes a size from a broken layout
 * sends `null` (that is what `JSON.stringify(NaN)` produces) or, over a
 * transport that never went through JSON, `NaN` itself. Neither may reach
 * `pty.resize`.
 */
function whole(value: unknown, min: number, max: number): number | null {
  if (typeof value !== 'number' || !Number.isInteger(value)) return null
  return value >= min && value <= max ? value : null
}

/**
 * C0 controls, DEL and C1, written as escapes and never typed literally.
 *
 * Used to *refuse* a value outright — the token, which is a machine-generated
 * secret and has no business carrying any of these. Display strings go through
 * `DISPLAY_STRIP` below instead, which is wider and strips rather than refuses.
 *
 * A raw control byte in source is invisible in every diff and every editor,
 * and a class written wrong here does not crash: `[\\u0000-...]` is a legal
 * regex matching a backslash, a `u`, and the range `0`-`\\`, so instead of
 * control bytes it silently strips the capitals and digits out of every device
 * name. That exact typo was in this file for a few minutes and only the tests
 * below noticed it.
 */
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/

/**
 * What is stripped out of a string before a person reads it.
 *
 * Wider than C0, because a device name is not only logged: it is the text a
 * human at the Mac reads when deciding whether to approve a device, and it
 * arrives from a peer that has not authenticated yet. Three groups beyond C0:
 *
 *  - **C1, U+0080-U+009F.** U+009B is CSI in eight-bit form. A terminal in
 *    UTF-8 mode that honours eight-bit controls turns a device name in a log
 *    line back into an escape sequence, which is what stripping C0 was for.
 *  - **U+2028 and U+2029.** Line and paragraph separators: a name carrying one
 *    becomes two lines in the device list and in a log.
 *  - **Bidi overrides, embeddings and isolates, U+202A-U+202E and
 *    U+2066-U+2069.** These reorder the glyphs after them, so a name can be
 *    made to render as a different name than the one stored and compared. The
 *    approval list is the one screen in this feature where a human grants
 *    access by reading attacker-chosen text, so it does not get to lie.
 *
 * Deliberately **not** stripped: U+200B-U+200D. Zero-width joiner carries every
 * multi-part emoji - family, flags, professions - and mangling the emoji in a
 * phone's name to defend against an invisible character is the worse trade.
 * Arabic and Hebrew names are untouched too: they lay out through implicit
 * bidi, not through these controls.
 */
const DISPLAY_STRIP = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g

/**
 * The bearer secret from `hello`, unchanged.
 *
 * Bounded and stripped of control bytes, and deliberately not locked to a
 * charset. What a credential looks like belongs to `device-auth.ts` — today a
 * base64url pairing token, tomorrow whatever that module mints — and a charset
 * pinned here would turn a change over there into a login that fails for no
 * visible reason. This file only has to keep the field small enough to be
 * harmless and clean enough to put in a log line. Whether it is a real
 * credential is answered by `RemoteAuth`, against a real digest.
 */
function token(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_TOKEN_LENGTH) return null
  return CONTROL_CHARS.test(value) ? null : value
}

/**
 * Trim and cap a display string. A phone can call itself anything, at any length.
 *
 * The cap is applied on a code-point boundary. `slice(0, max)` counts UTF-16
 * units, so a name whose 60th unit is the first half of a surrogate pair used to
 * come out ending in a lone surrogate - the same defect `chunkOutput` goes to
 * some trouble to avoid on the wire, reintroduced on the one string a person
 * actually reads. It renders as a replacement character and is then stored as
 * the device's name.
 */
function label(value: string, max: number): string {
  // Control characters would end up in a desktop list and, from there, in a log.
  const cleaned = value.replace(DISPLAY_STRIP, '').trim()
  if (cleaned.length <= max) return cleaned
  const last = cleaned.charCodeAt(max - 1)
  // A high surrogate in the final slot has lost its other half; drop it.
  return cleaned.slice(0, last >= 0xd800 && last <= 0xdbff ? max - 1 : max)
}

/**
 * The phone's own description of itself.
 *
 * The fields must be present and be strings — a `hello` without them is not
 * from any build of our client, and inventing a name for it would put a device
 * in the paired list that nobody can recognise later. Once present they are
 * only sanitised, never rejected: a name is display text, and refusing a login
 * over an emoji in a phone's name would be absurd.
 */
function descriptor(value: unknown): DeviceDescriptor | null {
  if (!isRecord(value)) return null
  // Read once. Checking `value.name` and then passing `value.name` on is two
  // property reads, and on the object path below a property is not necessarily
  // a stored value — a getter answers the check with a string and the second
  // read with anything at all. Here that put a non-string into `label`, which
  // threw out of a function documented never to throw.
  const name = value.name
  const platform = value.platform
  if (typeof name !== 'string' || typeof platform !== 'string') return null
  return {
    name: label(name, 60) || 'Unnamed device',
    platform: label(platform, 40) || 'unknown',
  }
}

/**
 * UTF-8 length, without allocating a copy of the string.
 *
 * `Buffer` and `TextEncoder` are both unavailable in one of the two runtimes
 * this file has to compile in (see the header). Counting also avoids building
 * a 64 KiB buffer out of a frame that is about to be refused. Lone surrogates
 * count as 3, which is what an encoder spends replacing them with U+FFFD.
 */
function utf8Length(value: string): number {
  let bytes = 0
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i)
    if (code < 0x80) bytes += 1
    else if (code < 0x800) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < value.length) {
      const low = value.charCodeAt(i + 1)
      if (low >= 0xdc00 && low <= 0xdfff) {
        bytes += 4
        i += 1
      } else bytes += 3
    } else bytes += 3
  }
  return bytes
}

/**
 * Over a byte cap, decided the cheap way first.
 *
 * A UTF-16 code unit is never fewer than one UTF-8 byte, so `length > cap`
 * already proves the string is too big and the counting loop can be skipped —
 * which is what stops a 50 MB frame from costing a 50 MB scan. Below that the
 * count has to be exact: 8,192 emoji are 8,192 units and 32,768 bytes, so
 * length alone would wave through a paste at twice the cap.
 */
function overBytes(value: string, cap: number): boolean {
  if (value.length > cap) return true
  return utf8Length(value) > cap
}

/* ------------------------------------------------------------------ parser -- */

/**
 * The only door inbound frames come through.
 *
 * Takes `unknown` rather than `string`: the socket delivers text, but a binary
 * frame, a fragment reassembled wrong, or an in-process bridge that hands over
 * the decoded object all arrive at this same function, and the one that skips
 * the checks is the one that matters.
 *
 * Returns a reason rather than throwing — the caller answers a bad message by
 * closing the socket with that reason, and an exception on the data path of a
 * socket is how a main process dies.
 */
export function parseClientMessage(raw: unknown): ParseResult {
  let parsed: unknown
  if (typeof raw === 'string') {
    if (overBytes(raw, MAX_MESSAGE_BYTES)) return tooLarge('frame over the message limit')
    try {
      parsed = JSON.parse(raw)
    } catch {
      return bad('not JSON')
    }
  } else if (ArrayBuffer.isView(raw) || raw instanceof ArrayBuffer) {
    // A socket in binary mode delivers a view, and `typeof` calls that an
    // object — it would otherwise reach the field checks as an empty record.
    return bad('binary frame')
  } else {
    parsed = raw
  }
  if (!isRecord(parsed)) return bad('not an object')

  switch (parsed.t) {
    case 'hello': {
      // Required, and refused when it is not a whole number: an earlier draft
      // read a missing version as 0 and so read `NaN` as a version too.
      const protocol = whole(parsed.protocol, 0, 65535)
      if (protocol === null) return bad('hello without a protocol version')
      const supplied = token(parsed.token)
      if (supplied === null) return bad('hello without a usable token')
      const device = descriptor(parsed.device)
      if (device === null) return bad('hello without a device descriptor')
      return { ok: true, message: { t: 'hello', protocol, token: supplied, device } }
    }
    case 'list':
      return { ok: true, message: { t: 'list' } }
    case 'ping':
      return { ok: true, message: { t: 'ping' } }
    case 'attach': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('attach without a session id')
      // Read once, for the same reason as `input.data`: the presence check and
      // the range check must be looking at the same value.
      const rawCols = parsed.cols
      const rawRows = parsed.rows
      if (rawCols === undefined && rawRows === undefined) {
        return { ok: true, message: { t: 'attach', id: sessionId } }
      }
      const cols = whole(rawCols, MIN_COLS, MAX_COLS)
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('attach with a size out of range')
      return { ok: true, message: { t: 'attach', id: sessionId, cols, rows } }
    }
    case 'detach': {
      const sessionId = id(parsed.id)
      return sessionId
        ? { ok: true, message: { t: 'detach', id: sessionId } }
        : bad('detach without a session id')
    }
    case 'input': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('input without a session id')
      // Bound to a local before anything looks at it. Type-checking
      // `parsed.data`, measuring `parsed.data` and then forwarding
      // `parsed.data` is three reads of one property, and the value that
      // reaches `SessionAccess.write` is the third — the one nothing checked.
      // That is only reachable on the object path, where a property can be a
      // getter, which is precisely the path this parser exists to cover.
      const data = parsed.data
      if (typeof data !== 'string') return bad('input without data')
      // Bytes, not characters: one emoji is four of them, and the cap is about
      // what gets typed into a PTY.
      if (overBytes(data, MAX_INPUT_BYTES)) return tooLarge('input larger than the paste limit')
      return { ok: true, message: { t: 'input', id: sessionId, data } }
    }
    case 'resize': {
      const sessionId = id(parsed.id)
      if (!sessionId) return bad('resize without a session id')
      const cols = whole(parsed.cols, MIN_COLS, MAX_COLS)
      const rows = whole(parsed.rows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('resize out of range')
      return { ok: true, message: { t: 'resize', id: sessionId, cols, rows } }
    }
    default:
      return bad('unknown message type')
  }
}

/**
 * The only thing that writes to this socket, on either end.
 *
 * One typed choke point is what stops a stray `JSON.stringify(anything)` from
 * putting a shape on the wire that the other end has never been told about —
 * the same drift this module exists to prevent, arriving through the back door.
 */
export function serialize(message: ClientMessage | ServerMessage): string {
  return JSON.stringify(message)
}

/** UTF-8 cost of one code point, matching `utf8Length`. */
function costOf(code: number): number {
  if (code < 0x80) return 1
  if (code < 0x800) return 2
  if (code < 0x10000) return 3
  return 4
}

/**
 * Split output into frames the phone can parse without stalling.
 *
 * Cut on code-point boundaries and measured in UTF-8 bytes, which is what the
 * limit is denominated in and what the far end's own cap counts. Slicing UTF-16
 * at a fixed offset instead would eventually land between the halves of a
 * surrogate pair: `JSON.stringify` encodes the halves happily, and the phone
 * renders two replacement characters — one corrupted glyph per 32 KiB of
 * scrollback, which is exactly the kind of defect nobody traces back to here.
 */
export function chunkOutput(data: string, size = OUTPUT_CHUNK_BYTES): string[] {
  if (data === '') return []
  if (!overBytes(data, size)) return [data]

  const out: string[] = []
  let start = 0
  let bytes = 0
  let at = 0
  while (at < data.length) {
    const code = data.codePointAt(at) as number
    const units = code > 0xffff ? 2 : 1
    const cost = costOf(code)
    if (bytes + cost > size && at > start) {
      out.push(data.slice(start, at))
      start = at
      bytes = 0
    }
    bytes += cost
    at += units
  }
  if (start < data.length) out.push(data.slice(start))
  return out
}
