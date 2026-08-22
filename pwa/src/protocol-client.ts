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
  MAX_COPILOT_MESSAGE_CHARS,
  MAX_COPILOT_SAY_BYTES,
  MAX_CREDENTIAL_HOST_LENGTH,
  MAX_CREDENTIAL_REPO_LENGTH,
  MAX_CWD_BYTES,
  MAX_INPUT_BYTES,
  MAX_MESSAGE_BYTES,
  PROTOCOL_VERSION,
  parseServerFrame,
  parseSession,
  type ClientMessage,
  type CopilotActionRow,
  type CopilotChatMessage,
  type CopilotConsentQuestion,
  type CopilotGrantWire,
  type CopilotLinkWire,
  type CopilotPendingRow,
  type CopilotSessionRow,
  type CopilotSettledRow,
  type CopilotStateReport,
  type CopilotTier,
  type CredentialOperation,
  type DevServerReport,
  type DevServerStatus,
  type DeviceDescriptor,
  type DeviceRosterRow,
  type LocalPort,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
} from '../../src/main/remote/protocol'

export type {
  ClientMessage,
  CopilotActionRow,
  CopilotChatMessage,
  CopilotConsentQuestion,
  CopilotGrantWire,
  CopilotLinkWire,
  CopilotPendingRow,
  CopilotSessionRow,
  CopilotSettledRow,
  CopilotStateReport,
  CopilotTier,
  CredentialOperation,
  DevServerReport,
  DevServerStatus,
  DeviceDescriptor,
  DeviceRosterRow,
  LocalPort,
  ProtocolErrorCode,
  RemoteSession,
  ServerMessage,
}
export {
  CAPABILITY,
  MAX_COPILOT_MESSAGE_CHARS,
  MAX_COPILOT_SAY_BYTES,
  PROTOCOL_VERSION,
}

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
 *
 * `devices` is here for a different, sharper reason: the host sends
 * `devices.changed` unsolicited, and it sends it **only** to a connection that
 * named `devices` in its hello — because a build that never heard of the frame
 * would close the channel on the first one. This client does handle it (the
 * device screen), so naming it is honest and is what makes the roster on that
 * screen live rather than stale until the next visit.
 */
export const CLAIMED_CAPABILITIES: string[] = [CAPABILITY.credential, CAPABILITY.devices]

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

  if (frame.t === 'web.opened') {
    // Its only payload is the URL, which is what the confirmation line names —
    // the machine echoes back what it actually opened rather than what was
    // asked for, because a redirect or a normalisation there is the truth and
    // this end's copy is not.
    const url = typeof frame.url === 'string' ? frame.url : ''
    if (url === '') return { ok: false, reason: 'web.opened without a url' }
    return { ok: true, message: { t: 'web.opened', url: url.slice(0, MAX_REFUSAL_CHARS) } }
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
 * The eight `copilot.*` frames, which `parseServerFrame` does not read either.
 *
 * ## Why this is the fourth exception and still not a habit
 *
 * It is the same argument as `credentialRequest`, `localhostFrame` and
 * `devStateFrame`, applied to a fourth capability, and it is the same argument
 * because it is the same seam. `parseServerFrame` was written for a desktop
 * acting as the **guest** of another desktop; that guest speaks protocol v1 and
 * negotiates nothing, so refusing a frame it has never heard of is right *for
 * it*. This client negotiates. It sends `copilot.hello` only after a `welcome`
 * that carried a copilot for this device, and sends no other `copilot.*` verb
 * until a `copilot.grant` says the connection is open — which makes every frame
 * below one it has agreed to receive.
 *
 * The right home for all fifteen branches across these four readers is
 * `parseServerFrame` itself, the day the guest also has a copilot. Moving them
 * there deletes these functions and changes nothing else.
 *
 * ## Why there are eight and not ten
 *
 * Two are deliberately absent, and each absence is a statement about what this
 * client does rather than an oversight.
 *
 * `copilot.log` answers `copilot.log` and nothing else — it is never pushed —
 * and this client never sends one: the action log it draws is the *live* one,
 * assembled from the `copilot.tool` frames that arrive as calls happen, which is
 * what a page somebody is watching wants. Reading a frame nobody here can
 * provoke would be a parser for a conversation this client is not in, exactly as
 * `net.*` is for `localhostFrame`.
 *
 * `copilot.linked` is gone rather than merely unread. It answered
 * `copilot.connect` and carried the credential that frame minted, and both were
 * deleted on 2026-08-19 when pairing a device as one of his own became the whole
 * of the copilot's authorisation — see the header of `copilot.ts`. Nothing can
 * provoke it, there is no longer anywhere to put a credential, and a reader kept
 * for it would be a place for one to arrive.
 *
 * ## What is refused whole and what merely loses a row
 *
 * The split follows the rule the three readers above already settled on. A
 * frame that *is* one fact — `copilot.state`, `copilot.grant`, `copilot.ask`,
 * `copilot.settled` — is refused whole when that fact is incomplete, because a
 * half-read one would put a wrong claim on screen: a
 * consent prompt missing its arguments is the reflex-Yes that
 * `CopilotConsentQuestion` exists to prevent, and a grant missing a tier is a
 * control drawn for a permission nobody holds. A frame that carries a *list* —
 * the chat, the sessions, the pending questions — drops the unreadable row and
 * keeps the rest, because a screen showing four of five bubbles is useful and
 * one showing none because the fifth had a null role is not.
 *
 * Null means "not one of mine", not "bad frame": the caller then delegates to
 * the shared parser, which is what every other message type still goes through.
 */
function copilotFrame(parsed: unknown): DecodeResult | null {
  if (typeof parsed !== 'object' || parsed === null) return null
  const frame = parsed as Record<string, unknown>
  const type = frame.t
  if (typeof type !== 'string' || !type.startsWith('copilot.')) return null

  switch (type) {
    case 'copilot.state': {
      const state = copilotStateReport(frame.state)
      return state === null
        ? { ok: false, reason: 'copilot.state without a state' }
        : { ok: true, message: { t: 'copilot.state', state } }
    }

    case 'copilot.chat': {
      // The run id is what makes a frame from a *previous* run droppable rather
      // than mergeable, and the protocol says so in as many words: without it a
      // client that reconnected after the grace window would splice the end of a
      // dead conversation onto the start of a live one. So a chat frame with no
      // run is refused rather than accepted with a blank one.
      const run = typeof frame.run === 'string' ? frame.run : ''
      if (run === '') return { ok: false, reason: 'copilot.chat without a run' }
      const rows = frame.messages
      if (!Array.isArray(rows)) return { ok: false, reason: 'copilot.chat without messages' }
      const messages: CopilotChatMessage[] = []
      for (const row of rows) {
        const message = chatMessage(row)
        if (message !== null) messages.push(message)
      }
      const chat: Extract<ServerMessage, { t: 'copilot.chat' }> = { t: 'copilot.chat', run, messages }
      // `reset` is an instruction to throw away everything held, so it is acted
      // on only when the desktop said it in so many words — the same rule
      // `credential.request.prompt` follows one reader up.
      if (frame.reset === true) chat.reset = true
      return { ok: true, message: chat }
    }

    case 'copilot.tool': {
      const row = actionRow(frame.row)
      return row === null
        ? { ok: false, reason: 'copilot.tool without a row' }
        : { ok: true, message: { t: 'copilot.tool', row } }
    }

    case 'copilot.sessions': {
      const rows = frame.sessions
      if (!Array.isArray(rows)) return { ok: false, reason: 'copilot.sessions without a list' }
      const sessions: CopilotSessionRow[] = []
      for (const row of rows) {
        const session = copilotSessionRow(row)
        if (session !== null) sessions.push(session)
      }
      return { ok: true, message: { t: 'copilot.sessions', sessions } }
    }

    case 'copilot.pending': {
      const rows = frame.questions
      if (!Array.isArray(rows)) return { ok: false, reason: 'copilot.pending without a list' }
      const questions: CopilotPendingRow[] = []
      for (const row of rows) {
        const question = pendingRow(row)
        if (question !== null) questions.push(question)
      }
      return { ok: true, message: { t: 'copilot.pending', questions } }
    }

    case 'copilot.grant': {
      const link = copilotLink(frame.link)
      return link === null
        ? { ok: false, reason: 'copilot.grant without a link' }
        : { ok: true, message: { t: 'copilot.grant', link } }
    }

    case 'copilot.ask': {
      const question = consentQuestion(frame.question)
      return question === null
        ? { ok: false, reason: 'copilot.ask without a question' }
        : { ok: true, message: { t: 'copilot.ask', question } }
    }

    case 'copilot.settled': {
      const settled = settledRow(frame.settled)
      return settled === null
        ? { ok: false, reason: 'copilot.settled without a row' }
        : { ok: true, message: { t: 'copilot.settled', settled } }
    }

    default:
      // A `copilot.*` type this build has never heard of — `copilot.log`
      // included, since nothing here asks for one. Refused with a sentence
      // rather than handed to the shared parser, which would answer "unknown
      // message type" about a frame that is very much this feature's.
      return { ok: false, reason: 'a copilot frame this client did not ask for' }
  }
}

/** Three booleans, all three of them, or null. Never a partial grant. */
function copilotGrant(value: unknown): CopilotGrantWire | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  // Every field required and every field a boolean. `CopilotGrantWire` promises
  // a client exactly one shape to read, and the reason it does is that "no
  // access" must have one spelling: a grant read as `{read: true}` with the
  // other two missing would draw a watching surface for a device that may have
  // been given everything, or nothing.
  if (typeof row.read !== 'boolean' || typeof row.act !== 'boolean' || typeof row.alter !== 'boolean') {
    return null
  }
  return { read: row.read, act: row.act, alter: row.alter }
}

function copilotLink(value: unknown): CopilotLinkWire | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const grant = copilotGrant(row.grant)
  if (grant === null || typeof row.linked !== 'boolean' || typeof row.open !== 'boolean') return null
  return { linked: row.linked, open: row.open, grant }
}

/** The five things the desk can be doing, and only those five. */
const COPILOT_DESK = ['stopped', 'starting', 'running'] as const

function copilotStateReport(value: unknown): CopilotStateReport | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const desk = COPILOT_DESK.find((known) => known === row.desk)
  const grant = copilotGrant(row.grant)
  // Refused rather than defaulted, and `desk` is the one that matters: a report
  // drawn as `stopped` because the word was unreadable says the copilot is not
  // running, which is the one claim on this screen somebody would act on by
  // pressing Start against something that is already up.
  if (desk === undefined || grant === null) return null
  return {
    desk,
    run: typeof row.run === 'string' && row.run !== '' ? row.run : null,
    profile: typeof row.profile === 'string' && row.profile !== '' ? row.profile.slice(0, MAX_COPILOT_LINE_CHARS) : null,
    // Three states, and null is one of them — "it has not been asked" is not the
    // same as "no". Anything that is not a boolean folds onto null rather than
    // onto false, because false is a claim.
    signedIn: typeof row.signedIn === 'boolean' ? row.signedIn : null,
    tools: counted(row.tools),
    turnTokens: counted(row.turnTokens),
    pending: counted(row.pending),
    grant,
    // `available` decides whether a Start button can act, so an unreadable one
    // is false: offering a control that cannot work is the defect this whole
    // review is built on, and the reason below says so in the desktop's words
    // when it sent any.
    available: row.available === true,
    reason: typeof row.reason === 'string' && row.reason !== '' ? row.reason.slice(0, MAX_REFUSAL_CHARS) : null,
  }
}

/** A whole non-negative count, or zero. Never a negative and never a fraction. */
function counted(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return 0
  return value < 0 ? 0 : Math.floor(value)
}

/** Epoch milliseconds as the wire may carry them, or 0 for "no time given". */
function stamp(value: unknown): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 0
  return Math.floor(value)
}

function chatMessage(value: unknown): CopilotChatMessage | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  const text = typeof row.text === 'string' ? row.text : ''
  // The id is what makes a growing message *replace* rather than duplicate, so a
  // bubble without one would arrive again on every extension and stack up a
  // paragraph at a time. Dropped rather than given a generated id, because an id
  // invented here would never match the next frame's.
  if (id === '' || (row.role !== 'you' && row.role !== 'agent')) return null
  const message: CopilotChatMessage = {
    id,
    role: row.role,
    text: text.slice(0, MAX_COPILOT_MESSAGE_CHARS),
    at: stamp(row.at),
  }
  // Carried through rather than recomputed from the slice above: `truncated` is
  // the desktop saying *there is more of this, go and look on the machine*, and
  // a client that decided for itself would say it about a message that merely
  // reached this client's own cap.
  if (row.truncated === true) message.truncated = true
  return message
}

/** The three outcomes an action row can carry. Anything else drops the row. */
const ACTION_OUTCOMES = ['ok', 'refused', 'error'] as const

function actionRow(value: unknown): CopilotActionRow | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  const tool = typeof row.tool === 'string' ? row.tool : ''
  const outcome = ACTION_OUTCOMES.find((known) => known === row.outcome)
  // An outcome this build has never heard of drops the row rather than being
  // folded onto `ok`. This is the line in the whole feature where a permission
  // boundary becomes visible — `outcome: 'refused'` is how somebody finds out
  // the gate held — and a fourth outcome added on the desktop must produce a
  // missing row here, never one that says the call succeeded.
  if (id === '' || tool === '' || outcome === undefined) return null
  return {
    id,
    at: typeof row.at === 'string' ? row.at.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    tool: tool.slice(0, MAX_COPILOT_LINE_CHARS),
    tier: typeof row.tier === 'string' ? row.tier.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    outcome,
    detail: typeof row.detail === 'string' ? row.detail.slice(0, MAX_REFUSAL_CHARS) : '',
    refusal: typeof row.refusal === 'string' && row.refusal !== '' ? row.refusal.slice(0, MAX_REFUSAL_CHARS) : null,
    deviceId: typeof row.deviceId === 'string' && row.deviceId !== '' ? row.deviceId : null,
  }
}

function copilotSessionRow(value: unknown): CopilotSessionRow | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  if (id === '') return null
  return {
    id,
    title: typeof row.title === 'string' ? row.title.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    cwd: typeof row.cwd === 'string' ? row.cwd.slice(0, MAX_CWD_BYTES) : '',
    provider: typeof row.provider === 'string' ? row.provider.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    status: typeof row.status === 'string' ? row.status.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    startedAt: stamp(row.startedAt),
    // The join back to the action log, and the reason the scan can quote the
    // machine's own words about a session instead of inventing a sentence. Null
    // when the desktop did not say, which is a real state: a session the copilot
    // started before this build began recording the link has no row to point at.
    originRunId: typeof row.originRunId === 'string' && row.originRunId !== '' ? row.originRunId : null,
  }
}

function pendingRow(value: unknown): CopilotPendingRow | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  if (id === '') return null
  return {
    id,
    tool: typeof row.tool === 'string' ? row.tool.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    summary: typeof row.summary === 'string' ? row.summary.slice(0, MAX_REFUSAL_CHARS) : '',
    requestedAt: stamp(row.requestedAt),
    expiresAt: stamp(row.expiresAt),
    // **False unless the desktop said true.** This is the field that decides
    // whether an Allow button is drawn, and the failure direction is not
    // symmetric: a row wrongly marked `mine` draws a control that is always
    // refused, which is the defect this repository has already paid for twice.
    mine: row.mine === true,
  }
}

function consentQuestion(value: unknown): CopilotConsentQuestion | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  const tool = typeof row.tool === 'string' ? row.tool : ''
  const args = row.args
  // Refused whole when anything is missing, and `args` is the field that makes
  // it so. A consent prompt without the arguments is a shape rather than a
  // decision, and a gate that is always answered yes because there was nothing
  // to read is worse than no gate at all — it looks like protection.
  if (id === '' || tool === '' || typeof args !== 'object' || args === null || Array.isArray(args)) {
    return null
  }
  return {
    id,
    tool: tool.slice(0, MAX_COPILOT_LINE_CHARS),
    tier: typeof row.tier === 'string' ? row.tier.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    summary: typeof row.summary === 'string' ? row.summary.slice(0, MAX_REFUSAL_CHARS) : '',
    args: args as Record<string, unknown>,
    origin: typeof row.origin === 'string' ? row.origin.slice(0, MAX_COPILOT_LINE_CHARS) : '',
    requestedAt: stamp(row.requestedAt),
    expiresAt: stamp(row.expiresAt),
  }
}

function settledRow(value: unknown): CopilotSettledRow | null {
  if (typeof value !== 'object' || value === null) return null
  const row = value as Record<string, unknown>
  const id = typeof row.id === 'string' ? row.id : ''
  // `granted` decides what the withdrawn prompt says happened, so it is required
  // rather than defaulted: "it was allowed" and "it was refused" are the two
  // sentences a person most needs to be told the truth about, and a missing
  // boolean read as false would tell somebody their own Allow had been refused.
  if (id === '' || typeof row.granted !== 'boolean') return null
  return {
    id,
    granted: row.granted,
    // Null is meaningful and is not the same as an empty string: it is the
    // timeout, where nobody answered at all, and the sentence for it is
    // different from the one that names a surface.
    by: typeof row.by === 'string' && row.by !== '' ? row.by.slice(0, MAX_COPILOT_LINE_CHARS) : null,
    reason: typeof row.reason === 'string' && row.reason !== '' ? row.reason.slice(0, MAX_REFUSAL_CHARS) : null,
  }
}

/**
 * How long a tool id, a tier, a status, a run id or an origin may be.
 *
 * All of them are short in reality and all of them are drawn on one line of a
 * row, so this is a display bound rather than a security one —
 * `MAX_MESSAGE_BYTES` has already been applied to the whole frame before any of
 * this runs. It is the copilot's equivalent of {@link MAX_DEV_FIELD_CHARS} and
 * is a separate constant only because the two features' rows are separate: the
 * day one of them wants a longer field, the other should not silently follow.
 */
const MAX_COPILOT_LINE_CHARS = 200

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
  const copilot = copilotFrame(frame)
  if (copilot !== null) return copilot
  const parsed = parseServerFrame(frame)
  if (!parsed.ok) return parsed
  let message = parsed.message
  if (message.t !== 'welcome' && message.t !== 'sessions') return { ok: true, message }
  /*
   * The copilot link, put back onto a `welcome` the shared parser dropped.
   *
   * `ServerMessage` carries `copilot?: CopilotLinkWire` and `parseServerFrame`
   * does not read it — for the reason the shared parser refuses every other
   * `copilot.*` frame: it was written for a desktop acting as the guest of
   * another desktop, and a guest is exactly the device this key is withheld
   * from, so the field is one it has no use for.
   *
   * This client does use it, and since 2026-08-19 it is the *only* thing it
   * reads on the question: the key is present for one of his own devices and
   * absent for a guest, which makes its presence the whole of whether there is a
   * Copilot tab. The cost of not reading it is therefore total rather than
   * cosmetic — a machine with a copilot and a device entitled to it, drawn as
   * though neither existed.
   *
   * Read defensively and dropped when malformed, and dropping is the safe
   * direction: a client that invented a link out of an unreadable one would send
   * `copilot.hello` to a machine that never offered it, and draw a tab whose
   * every frame comes back refused.
   */
  if (message.t === 'welcome') {
    const link = copilotLink((frame as Record<string, unknown>).copilot)
    // `open` forced false whatever arrived, for the reason `copilot.ts` gives at
    // its own welcome branch: the desktop always sends false, and a client whose
    // correctness depends on the far end never having a bug is not correct.
    if (link !== null) message = { ...message, copilot: { ...link, open: false } }
  }
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
/**
 * Whether a message is short enough for `copilot.say`, measured in real bytes.
 *
 * The desktop refuses an oversized one and answers a rejected frame by closing
 * the socket, so a client that merely hoped would lose its connection over a
 * long paragraph. Unlike a keystroke this is **not** chunked: `chunkInput` splits
 * a paste because a terminal is a stream and half a paste is still half a paste,
 * whereas half a sentence to an agent is a different sentence. So the composer
 * refuses and says so, and the person shortens it.
 *
 * `TextEncoder` for the same reason `overMessageCap` uses it: `MAX_COPILOT_SAY_BYTES`
 * is a byte count and a UTF-16 length is not one.
 */
export function copilotSayFits(text: string, maxBytes: number = MAX_COPILOT_SAY_BYTES): boolean {
  return encoder.encode(text).byteLength <= maxBytes
}

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
