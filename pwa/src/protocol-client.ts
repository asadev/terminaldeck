/**
 * The client half of the wire language.
 *
 * The types and the limits come from `src/main/remote/protocol.ts` — the
 * desktop's own module, imported across the directory boundary rather than
 * restated here. A second copy of a wire format is a copy that drifts, and the
 * drift shows up as a phone that has been silently dropping a message type
 * since someone added it.
 *
 * Only the type declarations and the constants are used from it. The parsing
 * and serialising functions in that file are the server's side of the
 * conversation and call `Buffer`, which does not exist in a browser; they are
 * tree-shaken out because nothing here references them, and nothing here should
 * start to.
 *
 * ## Why inbound frames are validated at all
 *
 * The desktop is not hostile, but it is not always what answers. A captive
 * portal on hotel wifi answers every request with its own login page, and the
 * first thing this client would otherwise do with that is `JSON.parse` an HTML
 * document and then read `.sessions` off the result. Validating here means the
 * client says "that is not Terminal Deck" instead of throwing inside a socket
 * handler and leaving a dead screen with no explanation.
 */

import {
  MAX_INPUT_BYTES,
  PROTOCOL_ERROR_CODES,
  PROTOCOL_VERSION,
  type ClientMessage,
  type DeviceDescriptor,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from '../../src/main/remote/protocol'

export type { ClientMessage, DeviceDescriptor, ProtocolErrorCode, RemoteSession, ServerMessage }
export { PROTOCOL_VERSION }

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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function whole(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

/**
 * One session row, or null.
 *
 * A single malformed row does not discard the list — see `sessionList`. A phone
 * that shows four of five sessions is useful; a phone that shows none because
 * the fifth had a null title is not.
 */
export function decodeSession(value: unknown): RemoteSession | null {
  if (!isRecord(value)) return null
  const id = str(value.id)
  const title = str(value.title)
  const cwd = str(value.cwd)
  const provider = str(value.provider)
  const status = str(value.status)
  if (id === null || id === '' || title === null || cwd === null || provider === null || status === null) return null
  const exitCode = value.exitCode === null ? null : whole(value.exitCode)
  return { id, title, cwd, provider, status, exitCode }
}

interface DecodedList {
  sessions: RemoteSession[]
  activity: Map<string, number>
}

function sessionList(value: unknown): DecodedList | null {
  if (!Array.isArray(value)) return null
  const sessions: RemoteSession[] = []
  const activity = new Map<string, number>()
  for (const entry of value) {
    const session = decodeSession(entry)
    if (session === null) continue
    sessions.push(session)
    const at = decodeLastActivity(entry)
    if (at !== null) activity.set(session.id, at)
  }
  return { sessions, activity }
}

/**
 * When the desktop last saw this session do anything, if it says.
 *
 * `RemoteSession` carries no such field today, so the session list has nothing
 * truthful to print for a session this phone has never attached to, and prints
 * nothing rather than inventing a time. Read defensively here so that the day
 * the desktop starts sending `lastActivityAt` the list improves with no change
 * on this side. See the handoff note — the desktop has this value already, in
 * `session-activity.ts`; it just does not cross the wire.
 */
export function decodeLastActivity(value: unknown): number | null {
  if (!isRecord(value)) return null
  const at = value.lastActivityAt
  return typeof at === 'number' && Number.isFinite(at) && at > 0 ? at : null
}

/**
 * What the desktop says it can do beyond protocol v1.
 *
 * Absent means "v1 only" rather than "unknown", so the answer is an empty list
 * and never a null: a client that cannot tell the two apart ends up guessing at
 * a feature instead of hiding it. Malformed entries are dropped rather than
 * failing the whole `welcome`, for the same reason one bad session row does not
 * discard a session list.
 *
 * Nothing in this browser client acts on it yet. The port-tunnelling capability
 * needs a listening socket on the phone, which a web page cannot have — that is
 * a native-app feature and this decoder only has to not choke on it.
 */
function capabilities(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.filter((entry): entry is string => typeof entry === 'string' && entry.length > 0 && entry.length <= 32)
}

/**
 * The folders this device may start a session in, when the desktop says.
 *
 * Null and `[]` are different answers and the difference is the whole point of
 * the field. Null means this desktop never mentioned folders — every build
 * older than the field, and every host that cannot start sessions at all — and
 * a client that reads null must keep doing whatever it did before rather than
 * drawing an empty picker. `[]` means somebody chose no folders for *this*
 * device, which is a real state with a real remedy, and flattening the two
 * would turn "your desktop is old" into "you have been shut out" on the screen
 * of a phone that is three rooms away from the machine that could explain.
 *
 * Entries that are not strings are dropped rather than failing the frame, the
 * same rule `capabilities` follows: one bad row must not cost the connection
 * carrying it.
 */
function folderList(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null
  return value.filter((entry): entry is string => typeof entry === 'string' && entry !== '')
}

/**
 * The codes, from the desktop's own module rather than written out again here.
 *
 * This list used to be a copy, and a copy of a wire vocabulary is a copy that
 * goes stale silently: a code added on the desktop does not fail to compile
 * here, it makes this client answer `error with an unknown code` and throw away
 * the sentence the user needed to read.
 */
function errorCode(value: unknown): ProtocolErrorCode | null {
  const code = str(value)
  return code !== null && (PROTOCOL_ERROR_CODES as readonly string[]).includes(code)
    ? (code as ProtocolErrorCode)
    : null
}

/** The only door inbound text comes through, mirroring `parseClientMessage`. */
export function decodeServerMessage(raw: string): DecodeResult {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { ok: false, reason: 'not JSON' }
  }
  if (!isRecord(parsed)) return { ok: false, reason: 'not an object' }

  switch (parsed.t) {
    case 'welcome': {
      const protocol = whole(parsed.protocol)
      const deviceId = str(parsed.deviceId)
      const deviceName = str(parsed.deviceName)
      const list = sessionList(parsed.sessions)
      if (protocol === null || deviceId === null || deviceName === null || list === null) {
        return { ok: false, reason: 'incomplete welcome' }
      }
      // A null token means "you already had one"; a string means "store this".
      // A missing field is neither, and guessing which it meant is how a phone
      // ends up believing it is paired when it holds nothing.
      const token = parsed.token === null ? null : str(parsed.token)
      if (token === null && parsed.token !== null) return { ok: false, reason: 'welcome without a token field' }
      const message: Extract<ServerMessage, { t: 'welcome' }> = {
        t: 'welcome',
        protocol,
        deviceId,
        deviceName,
        token,
        sessions: list.sessions,
        capabilities: capabilities(parsed.capabilities),
      }
      // Assigned only when it is there, rather than written as `hostPlatform:
      // str(...)`, so that "the desktop did not say" stays distinguishable from
      // "the desktop said something this build does not recognise". Both end up
      // at the neutral noun today, but only one of them is a desktop that is
      // older than the field — see `host-platform.ts`. Carried raw: turning it
      // into a noun is the UI's job, and a decoder that returned "Mac" would be
      // putting presentation on the wire type.
      const hostPlatform = str(parsed.hostPlatform)
      if (hostPlatform !== null) message.hostPlatform = hostPlatform
      // Assigned only when it is there, for the same reason and with more at
      // stake: an absent field and an empty list are two different facts about
      // this device — see `folderList` — and a decoder that wrote `folders: []`
      // for a desktop that said nothing would report a lock-out that nobody
      // chose.
      const folders = folderList(parsed.folders)
      if (folders !== null) message.folders = folders
      return { ok: true, message, activity: list.activity }
    }
    case 'sessions': {
      const list = sessionList(parsed.sessions)
      if (list === null) return { ok: false, reason: 'sessions without a list' }
      return { ok: true, message: { t: 'sessions', sessions: list.sessions }, activity: list.activity }
    }
    case 'attached': {
      const id = str(parsed.id)
      return id ? { ok: true, message: { t: 'attached', id } } : { ok: false, reason: 'attached without an id' }
    }
    case 'detached': {
      const id = str(parsed.id)
      return id ? { ok: true, message: { t: 'detached', id } } : { ok: false, reason: 'detached without an id' }
    }
    case 'output': {
      const id = str(parsed.id)
      const data = str(parsed.data)
      if (id === null || data === null) return { ok: false, reason: 'output without id and data' }
      return {
        ok: true,
        message: parsed.replay === true ? { t: 'output', id, data, replay: true } : { t: 'output', id, data },
      }
    }
    case 'status': {
      const id = str(parsed.id)
      const status = str(parsed.status)
      if (id === null || status === null) return { ok: false, reason: 'status without id and status' }
      return { ok: true, message: { t: 'status', id, status } }
    }
    case 'exit': {
      const id = str(parsed.id)
      const exitCode = whole(parsed.exitCode)
      if (id === null || exitCode === null) return { ok: false, reason: 'exit without id and code' }
      return { ok: true, message: { t: 'exit', id, exitCode } }
    }
    case 'error': {
      const code = errorCode(parsed.code)
      const message = str(parsed.message)
      if (code === null) return { ok: false, reason: `error with an unknown code ${JSON.stringify(parsed.code)}` }
      return { ok: true, message: { t: 'error', code, message: message ?? '' } }
    }
    case 'pong':
      return { ok: true, message: { t: 'pong' } }
    case 'created': {
      // The row for the session this client just asked for. Refused rather than
      // half-read, unlike a row inside a list: a `sessions` frame missing one
      // entry is still a useful list, whereas this frame *is* the one session,
      // and a client that accepted a nameless one would navigate to an id the
      // desktop never minted.
      const session = decodeSession(parsed.session)
      if (session === null) return { ok: false, reason: 'created without a session' }
      return { ok: true, message: { t: 'created', session } }
    }
    case 'folders': {
      // Pushed when somebody edits this device's list on the desktop. Refused
      // when it carries no list at all, because unlike the optional field in
      // `welcome` there is nothing else in this frame — reading it as "no
      // folders" would take the picker away on the strength of a malformed
      // message.
      const folders = folderList(parsed.folders)
      if (folders === null) return { ok: false, reason: 'folders without a list' }
      return { ok: true, message: { t: 'folders', folders } }
    }
    default:
      return { ok: false, reason: `unknown message type ${JSON.stringify(parsed.t)}` }
  }
}

/* ---------------------------------------------------------------- outbound -- */

export function encode(message: ClientMessage): string {
  return JSON.stringify(message)
}

export function helloMessage(token: string, device: DeviceDescriptor): ClientMessage {
  return { t: 'hello', protocol: PROTOCOL_VERSION, token, device }
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
