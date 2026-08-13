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
 * ## How this protocol grows without a version bump
 *
 * `hello` pins a version and the server refuses a mismatch, so bumping it locks
 * out every phone that is already installed — which makes the version number the
 * worst possible way to add a feature. Anything additive travels instead as a
 * *capability*: the desktop lists what it can do in `welcome.capabilities`, and a
 * client sends a verb from that list only after seeing it there. A desktop that
 * has never heard of the field does not send it, a client that has never heard
 * of a capability ignores it, and neither end has to be updated in step with the
 * other. `PROTOCOL_VERSION` moves only when the *framing* changes — when an old
 * client would misread a v1 message rather than merely not understand a new one.
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
 * Named extensions past v1, advertised in `welcome.capabilities`.
 *
 * `localhost` is the whole of the port-tunnelling feature: asking what is
 * listening on the Mac (`ports`), opening a tunnel to one of those ports
 * (`tunnel.*`), and the byte streams that ride it (`net.*`). One name rather
 * than four, because a client that can do any of it can do all of it — a phone
 * that could list ports but not open one would have nothing to show for it.
 *
 * `create` is one verb, and the capability is deliberately spelled the same as
 * the verb it grants. There is exactly one thing to negotiate here, so a second
 * name would only be a second thing for the two ends to disagree about.
 *
 * `upload` is the whole of "send a photo, a video or a file from the phone into
 * the terminal": announcing a file (`upload.begin`), the chunks that carry it
 * (`upload.data`), the acknowledgements progress is measured from (`upload.ack`)
 * and the two ways it ends. One name, for the same reason `localhost` is one
 * name — a phone that could announce a file but not send its bytes would have
 * nothing to show for it.
 *
 * ## Why these strings are not the ones the phones invented
 *
 * Both clients grew a New Session button before any desktop could serve one,
 * and each invented its own shape against its own stand-in: iOS gates on
 * `create` and sends `{"t":"create"}`; Android gates on `session.create` and
 * sends `{"t":"new"}`. Neither was ever spoken by a real desktop, so neither is
 * a compatibility obligation — but the *name* still matters, because a
 * capability string is a promise about a wire shape. `session.create` already
 * means "answers `{t:'new'}`" to an installed Android build, so reusing it for
 * a different frame would light that button up and then close the socket on the
 * frame it sends. Advertising `create` instead leaves an un-updated Android
 * client exactly where a capability it has never heard of should leave it:
 * dark, and working, until it is updated.
 */
export const CAPABILITY = {
  localhost: 'localhost',
  create: 'create',
  upload: 'upload',
} as const

/**
 * Every extension this build knows how to serve.
 *
 * Not the same question as what a given desktop *offers*: starting a session
 * needs a session layer that can start one, and a host built around a stub —
 * `scripts/remote-host.ts` before it grew PTYs — has to be able to say so. The
 * per-connection answer is assembled in `server.ts` from this list and from
 * what the injected `SessionAccess` can actually do, which is what makes the
 * button on the phone appear only when there is something behind it.
 */
export const CAPABILITIES: string[] = [CAPABILITY.localhost, CAPABILITY.create, CAPABILITY.upload]

/**
 * A port on the Mac that is being listened on, as the phone sees it.
 *
 * Deliberately the same three fields `dev-ports.ts` produces and no more. The
 * desktop does not guess which framework is behind a port and this does not
 * either; `guessed` says only that the *process name* is unknown.
 */
export interface LocalPort {
  port: number
  process: string
  guessed: boolean
}

/**
 * Largest chunk of tunnelled bytes in one `net.data`, before base64.
 *
 * Base64 costs a third on top, so 24 KiB of payload becomes 32 KiB of JSON
 * string and lands comfortably inside `MAX_MESSAGE_BYTES` with the envelope,
 * the channel id and the sealing tag on top. Picking the cap in *raw* bytes is
 * what makes that arithmetic checkable rather than hopeful.
 */
export const MAX_NET_CHUNK_BYTES = 24 * 1024

/** The encoded length of a maximal chunk: base64 is four characters per three bytes. */
export const MAX_NET_DATA_CHARS = Math.ceil(MAX_NET_CHUNK_BYTES / 3) * 4

/**
 * How many bytes one side may have in flight on a stream before it stops reading.
 *
 * A tunnelled socket has no window of its own — it is a series of application
 * messages over a shared connection — so without this a phone on a slow link
 * pulling a 40 MB source map would have the whole file buffered in the desktop's
 * heap, and `MAX_BUFFERED_BYTES` in the server would answer by dropping the
 * phone. Each side acknowledges what it has written to its own socket and the
 * sender pauses when the unacknowledged total passes this, which turns the real
 * TCP backpressure at the far end into backpressure here.
 */
export const NET_WINDOW_BYTES = 256 * 1024

/**
 * Largest slice of a file in one `upload.data`, before base64.
 *
 * The same number as `MAX_NET_CHUNK_BYTES`, and deliberately the same number
 * rather than a second one that happens to match: both are "as much as fits in
 * a frame once base64 has taken a third on top", both ride the same sealed
 * channel with the same envelope, and two constants that must agree and are
 * written twice are two constants that will one day not agree.
 */
export const MAX_UPLOAD_CHUNK_BYTES = MAX_NET_CHUNK_BYTES

/** The encoded length of a maximal chunk: base64 is four characters per three bytes. */
export const MAX_UPLOAD_DATA_CHARS = MAX_NET_DATA_CHARS

/**
 * How many bytes of a file may be unacknowledged before the phone stops reading.
 *
 * The tunnel's problem, arriving from the other direction: an upload has no
 * window of its own either, so a phone on wifi reading a 200 MB video off flash
 * would hand the whole thing to the socket faster than the desktop can write it
 * to disk, and `MAX_BUFFERED_BYTES` would answer by dropping the phone
 * mid-upload. The desktop acknowledges each slice **from the write callback** —
 * meaning the kernel has it, not that we called `write` — and the phone pauses
 * once it is this far ahead. The same number as `NET_WINDOW_BYTES` because it is
 * the same trade: enough in flight to keep a fast link busy, little enough that
 * a slow one cannot make the desktop buffer.
 *
 * It is also what makes the progress bar honest. Progress drawn from bytes handed
 * to the socket reaches 100% the moment the phone has finished reading the file,
 * which on a slow link is a bar that fills in two seconds and then sits there.
 */
export const UPLOAD_WINDOW_BYTES = NET_WINDOW_BYTES

/**
 * Largest file a phone may send, in bytes.
 *
 * A ceiling rather than a guess at what people will send: a 4K video off a
 * modern phone is comfortably past 100 MB, and refusing those would make the
 * feature useless for exactly the case it was asked for. What the cap is really
 * for is the frame that claims a size — an upload announcing 40 GB must be
 * refused before a file is created, not discovered when the disk fills.
 *
 * The refusal names both numbers, so it is a sentence somebody can act on rather
 * than "too large".
 */
export const MAX_UPLOAD_BYTES = 512 * 1024 * 1024

/**
 * Longest `upload.begin.name`, in UTF-8 bytes.
 *
 * 255 is the per-component limit on APFS, ext4 and NTFS alike, so a name past it
 * cannot become a file on any machine this runs on. It is a bound on a hostile
 * frame, not the authority on what a name may be — that is `uploads.ts`, which
 * reduces whatever arrives to a single safe path component.
 */
export const MAX_UPLOAD_NAME_BYTES = 255

/** Hex SHA-256, as the phone reports it and as the desktop answers. */
export const SHA256_HEX_LENGTH = 64

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

/**
 * Longest `create.cwd`.
 *
 * `PATH_MAX` is 1024 on macOS and a path longer than that cannot name a folder
 * this Mac has, so anything past it is refused rather than passed to a `stat`.
 * Windows tolerates longer paths in theory and no project folder is anywhere
 * near this in practice; the cap is here to keep a hostile frame small, not to
 * be the authority on what a path may be.
 */
export const MAX_CWD_BYTES = 1024

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
  /* ---- capability `create`. Refused when it is not advertised. ------------ */
  /**
   * Start a session on the Mac.
   *
   * Everything about it is optional, and that is the design rather than
   * laziness: `{"t":"create"}` on its own is a whole request, and it produces
   * the same session the desktop's own New Session button produces with nothing
   * filled in — the user's real shell or agent, in the folder the desktop would
   * have picked, with their profile and their PATH. A phone that knows nothing
   * about the Mac can still start work on it.
   *
   * `cwd` narrows that to one folder. The phone is not free to name any path:
   * the server accepts only a folder the desktop is *already offering* — one of
   * its projects, or the working directory of a session it has already listed
   * to this device — so the value has an honest source on the phone (a row that
   * is on screen) and naming it grants nothing the device could not already
   * see. A path this desktop does not offer is refused, not silently replaced
   * with the default; a New Session that quietly started somewhere else would
   * be worse than one that did not start.
   *
   * `cols`/`rows` travel for the same reason they travel on `attach`: the first
   * screen the phone draws is then already the right shape, and an agent CLI
   * that paints a box on startup paints it at the size it will be read at.
   * Both or neither, never one.
   *
   * Deliberately **not** here:
   *
   *  - **A title.** Every other session in this app is titled after its folder,
   *    by `PtyManager`, and a phone-chosen title would be the one tab in the
   *    desktop that does not mean what the others mean. It would also be
   *    attacker-chosen display text in the desktop's own chrome, for nothing.
   *  - **A provider.** The phone has no honest way to know which agent CLIs are
   *    installed on the Mac — the session list says what is *running*, which is
   *    a different question — so a picker built from it would offer choices
   *    that fail. The desktop's own default provider is the right answer and is
   *    the answer its own button uses.
   *  - **`resume`.** Continuing the newest conversation in a folder is real and
   *    the desktop supports it, but only for providers that have a resume flag;
   *    a toggle that silently does nothing for a plain shell is a fake feature.
   *    Resuming a *session* — the thing the phone actually wants — is `attach`,
   *    which has worked since v1 and replays the scrollback.
   */
  | { t: 'create'; cwd?: string; cols?: number; rows?: number }
  /* ---- capability `localhost`. Refused outright when it is not advertised. -- */
  /** What is listening on the Mac right now. */
  | { t: 'ports' }
  /**
   * Open a tunnel to one port. **This message is the consent.**
   *
   * Nothing on the Mac is reachable until one of these arrives, and one only
   * arrives because a person tapped a port on their phone. There is no standing
   * permission to revoke and no list of allowed ports to get wrong: a tunnel
   * exists between a tap and the moment the view closes, and `tunnel.close`
   * — from either end — is the whole of the teardown.
   */
  | { t: 'tunnel.open'; id: string; port: number }
  | { t: 'tunnel.close'; id: string }
  /**
   * A new byte stream inside a tunnel: one browser connection, one `ch`.
   *
   * Only legal after `tunnel.opened` has been heard. Opening a tunnel waits on
   * a port scan on the Mac, so a client that sent both in one breath would be
   * refused for naming a tunnel that does not exist yet — which is why the
   * phone binds its listening socket on the confirmation, not on the request.
   */
  | { t: 'net.open'; ch: string; tunnel: string }
  | { t: 'net.data'; ch: string; data: string }
  /** "I have written this many bytes to my socket." See `NET_WINDOW_BYTES`. */
  | { t: 'net.ack'; ch: string; bytes: number }
  | { t: 'net.close'; ch: string }
  /* ---- capability `upload`. Refused outright when it is not advertised. ---- */
  /**
   * A file is coming. **This message is the consent, and it is the phone's.**
   *
   * Nothing is written to the Mac's disk until one of these arrives, and one only
   * arrives because a person picked a photo or a file in the OS's own picker.
   * There is no standing permission and no folder to configure: the desktop
   * answers with the path the file will land at, in a folder it chose, and the
   * phone shows that path before a byte moves.
   *
   * `name` is the phone's *suggestion*. It is not a path and is never treated as
   * one — see `safeName` in `uploads.ts`, which reduces it to a single component
   * — because the only thing on the other end of this field is a `writeFile`.
   *
   * `size` is declared up front rather than discovered, and that is what makes
   * the two honest things here possible: a file too large for this Mac is refused
   * before anything is created, and the progress bar has a denominator.
   */
  | { t: 'upload.begin'; id: string; name: string; size: number }
  /** One slice of the file, base64. Only legal after `upload.ready`. */
  | { t: 'upload.data'; id: string; data: string }
  /**
   * That was all of it, and this is what the phone made of it.
   *
   * The digest is the phone's own, computed over what it read, and the desktop
   * compares it against the digest it computed over what it wrote. A mismatch
   * deletes the file rather than renaming it into place: a truncated video that
   * looks like a video is worse than no video, because the failure surfaces
   * later, somewhere else, as a corrupt file nobody can explain.
   */
  | { t: 'upload.end'; id: string; sha256: string }
  /** Stop, throw away what has landed. Sent by the Cancel button on the phone. */
  | { t: 'upload.cancel'; id: string }

export type ServerMessage =
  | {
      t: 'welcome'
      protocol: number
      deviceId: string
      deviceName: string
      token: string | null
      sessions: RemoteSession[]
      /**
       * Extensions this desktop speaks. Absent from protocol v1 and read
       * defensively by every client, so an older phone sees a `welcome` it
       * already understands and a newer one learns what it may offer.
       */
      capabilities: string[]
    }
  | { t: 'sessions'; sessions: RemoteSession[] }
  | { t: 'attached'; id: string }
  | { t: 'detached'; id: string }
  /** `replay` marks scrollback that arrived before this client did. */
  | { t: 'output'; id: string; data: string; replay?: true }
  | { t: 'status'; id: string; status: string }
  | { t: 'exit'; id: string; exitCode: number }
  | { t: 'error'; code: ProtocolErrorCode; message: string }
  | { t: 'pong' }
  /* ---- capability `create` ----------------------------------------------- */
  /**
   * The session that was just started, for the phone that asked.
   *
   * Carries the whole row rather than an id so the phone can put it in its list
   * and open it without a round trip — and it carries the id at all so that the
   * tap that started the session is also the tap that opens it. Answering with
   * a bare `sessions` list, which is what both stand-ins did, leaves the phone
   * guessing which of the rows is the new one; with two sessions in the same
   * folder there is no way to guess right.
   *
   * Every *other* connected device is told with a plain `sessions` instead, so
   * a phone that has never heard of this frame still sees the new session
   * appear. That is the same additive rule the capability list is for.
   */
  | { t: 'created'; session: RemoteSession }
  /* ---- capability `localhost` ------------------------------------------- */
  | { t: 'ports'; ports: LocalPort[] }
  | { t: 'tunnel.opened'; id: string; port: number }
  /**
   * The tunnel is gone, and `message` says why in a sentence a person can read.
   *
   * The same frame answers a refusal, a teardown the phone asked for and a Stop
   * pressed on the Mac, because to the phone they are one event: the page it is
   * showing has nothing behind it any more. Which of the three it was is in the
   * sentence, not in a code, since the only thing the client does differently is
   * what it prints.
   */
  | { t: 'tunnel.closed'; id: string; message: string }
  | { t: 'net.data'; ch: string; data: string }
  | { t: 'net.ack'; ch: string; bytes: number }
  | { t: 'net.close'; ch: string }
  /* ---- capability `upload` ---------------------------------------------- */
  /**
   * The file is accepted, and this is where it will be.
   *
   * `path` is sent *before* any bytes move, not after, and that is the whole
   * reason this frame exists rather than the upload starting on its own. The
   * person holding the phone is told where on their Mac a file is about to
   * appear at the moment they can still cancel it — which is the difference
   * between a feature and something that writes to your disk.
   */
  | { t: 'upload.ready'; id: string; path: string }
  /**
   * "I have written this many more bytes to the file."
   *
   * Sent from the write callback, so it means the kernel has the bytes rather
   * than that we called `write`. That is what the phone's window measures against
   * and what its progress bar is drawn from — see `UPLOAD_WINDOW_BYTES`.
   */
  | { t: 'upload.ack'; id: string; bytes: number }
  /**
   * It is on disk, complete, and the digest matched.
   *
   * `path` is repeated rather than remembered from `upload.ready` because it can
   * legitimately differ: a file with the same name arriving twice lands beside
   * the first rather than over it, and the phone types *this* path into the
   * terminal.
   */
  | { t: 'upload.done'; id: string; path: string; bytes: number; sha256: string }
  /**
   * It did not land, and `message` says why in a sentence a person can act on.
   *
   * One frame for a refusal, for a failure mid-write and for a cancel the phone
   * asked for, because to the phone they are one event: there is no file. Which
   * of the three it was is in the sentence, not in a code — the same argument
   * `tunnel.closed` makes.
   */
  | { t: 'upload.failed'; id: string; message: string }

/**
 * Every refusal this protocol can name, as a value rather than only a type.
 *
 * A runtime list because three clients had each written the same six strings
 * out by hand — `pwa/src/protocol-client.ts` validates an inbound `code`
 * against its own copy, and the Swift and Kotlin clients against theirs. A
 * seventh code added to a type union alone changes none of them, and the
 * symptom is not a compile error: it is a phone printing "error with an unknown
 * code" instead of the sentence the desktop sent. Anything that can import this
 * module now imports the list too.
 *
 * `unavailable` is the newest: the desktop understood the request, would have
 * been allowed to serve it, and could not — a folder that has been deleted
 * since it was listed, a shell that will not spawn. It is not `unauthorized`,
 * which says the device may not ask, and telling a user "not allowed" when the
 * truth is "it broke" sends them to the pairing screen for no reason.
 */
export const PROTOCOL_ERROR_CODES = [
  'bad-message',
  'unauthenticated',
  'unauthorized',
  'unknown-session',
  'too-large',
  'unavailable',
  'version',
] as const

export type ProtocolErrorCode = (typeof PROTOCOL_ERROR_CODES)[number]

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
 * Standard base64, checked before anything decodes it.
 *
 * `Buffer.from(x, 'base64')` never throws: it skips what it does not recognise
 * and returns whatever it managed to read, so a corrupted frame becomes a
 * shorter body written into a socket rather than an error. On a byte stream
 * that is worse than a refusal — the far end sees a truncated HTTP response and
 * blames the dev server. Checked here, refused here.
 */
const BASE64_RE = /^[A-Za-z0-9+/]*={0,2}$/

/**
 * Lower- or upper-case hex, for the SHA-256 a phone reports on `upload.end`.
 *
 * Checked rather than parsed, because the value is only ever compared against a
 * digest this process computed. A string that is not hex cannot equal one, so
 * the check buys nothing about correctness — what it buys is that the refusal
 * says "that is not a digest" instead of "the file is corrupt", which are very
 * different things to tell someone who just uploaded a 200 MB video.
 */
const HEX_RE = /^[0-9a-fA-F]+$/

/** A port a phone may name. Zero and anything past 65535 are not ports. */
function portNumber(value: unknown): number | null {
  return whole(value, 1, 65535)
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

    /* ---- capability `create` -------------------------------------------- */
    case 'create': {
      const message: Extract<ClientMessage, { t: 'create' }> = { t: 'create' }
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured must
      // be the string that is forwarded.
      const rawCwd = parsed.cwd
      if (rawCwd !== undefined) {
        if (typeof rawCwd !== 'string' || rawCwd === '') return bad('create with an unusable folder')
        if (overBytes(rawCwd, MAX_CWD_BYTES)) return tooLarge('create with a folder over the path limit')
        // A path is not display text — it is compared against a list of folders
        // and then handed to a process — so a control byte in one is refused
        // outright rather than stripped. Stripping would turn a hostile value
        // into a *different* legal-looking path, which is the worse failure.
        if (CONTROL_CHARS.test(rawCwd)) return bad('create with an unusable folder')
        // Whether this desktop will start a session in this folder is not
        // decided here and cannot be: the answer lives in the desktop's own
        // project list. See the note at the top of this file.
        message.cwd = rawCwd
      }
      const rawCols = parsed.cols
      const rawRows = parsed.rows
      if (rawCols === undefined && rawRows === undefined) return { ok: true, message }
      const cols = whole(rawCols, MIN_COLS, MAX_COLS)
      const rows = whole(rawRows, MIN_ROWS, MAX_ROWS)
      if (cols === null || rows === null) return bad('create with a size out of range')
      message.cols = cols
      message.rows = rows
      return { ok: true, message }
    }

    /* ---- capability `localhost` ----------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // offers tunnelling at all, and whether the port named is one it is willing
    // to dial, are the server's questions — see the header.
    case 'ports':
      return { ok: true, message: { t: 'ports' } }
    case 'tunnel.open': {
      const tunnelId = id(parsed.id)
      if (!tunnelId) return bad('tunnel.open without an id')
      const port = portNumber(parsed.port)
      if (port === null) return bad('tunnel.open without a port')
      return { ok: true, message: { t: 'tunnel.open', id: tunnelId, port } }
    }
    case 'tunnel.close': {
      const tunnelId = id(parsed.id)
      return tunnelId
        ? { ok: true, message: { t: 'tunnel.close', id: tunnelId } }
        : bad('tunnel.close without an id')
    }
    case 'net.open': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.open without a channel id')
      const tunnelId = id(parsed.tunnel)
      if (!tunnelId) return bad('net.open without a tunnel id')
      return { ok: true, message: { t: 'net.open', ch: channel, tunnel: tunnelId } }
    }
    case 'net.data': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.data without a channel id')
      // Read once: the length check and the value that is decoded have to be
      // the same string, for the reason spelled out on `input.data` above.
      const data = parsed.data
      if (typeof data !== 'string') return bad('net.data without data')
      if (data.length > MAX_NET_DATA_CHARS) return tooLarge('net.data over the chunk limit')
      if (!BASE64_RE.test(data)) return bad('net.data is not base64')
      // Base64 comes in groups of four. A length that is not a multiple of four
      // cannot decode to whole bytes, and `Buffer` would silently drop the tail.
      if (data.length % 4 !== 0) return bad('net.data is not base64')
      return { ok: true, message: { t: 'net.data', ch: channel, data } }
    }
    case 'net.ack': {
      const channel = id(parsed.ch)
      if (!channel) return bad('net.ack without a channel id')
      // An acknowledgement larger than the window is either a bug on the far
      // end or an attempt to unblock a paused reader by lying about progress.
      const bytes = whole(parsed.bytes, 1, NET_WINDOW_BYTES)
      if (bytes === null) return bad('net.ack out of range')
      return { ok: true, message: { t: 'net.ack', ch: channel, bytes } }
    }
    case 'net.close': {
      const channel = id(parsed.ch)
      return channel
        ? { ok: true, message: { t: 'net.close', ch: channel } }
        : bad('net.close without a channel id')
    }

    /* ---- capability `upload` -------------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // will write a file at all, and what the name becomes on disk, are answered
    // in `uploads.ts` against a real directory.
    case 'upload.begin': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.begin without an id')
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured must
      // be the string that is forwarded.
      const name = parsed.name
      if (typeof name !== 'string' || name === '') return bad('upload.begin without a name')
      if (overBytes(name, MAX_UPLOAD_NAME_BYTES)) return tooLarge('upload.begin with a name over the limit')
      // A file name is not display text — it is about to be turned into a path
      // — so a control byte in one is refused outright rather than stripped, for
      // the same reason `create.cwd` is. Stripping turns a hostile value into a
      // *different* legal-looking name, which is the worse failure.
      if (CONTROL_CHARS.test(name)) return bad('upload.begin with an unusable name')
      // Zero is not a file anybody meant to send, and it is the size a failed
      // read reports. Refused here so that "0 bytes" cannot become an upload
      // that completes instantly and produces an empty file at a real path.
      const size = whole(parsed.size, 1, MAX_UPLOAD_BYTES)
      if (size === null) return bad('upload.begin with an unusable size')
      return { ok: true, message: { t: 'upload.begin', id: uploadId, name, size } }
    }
    case 'upload.data': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.data without an id')
      const data = parsed.data
      if (typeof data !== 'string') return bad('upload.data without data')
      if (data.length > MAX_UPLOAD_DATA_CHARS) return tooLarge('upload.data over the chunk limit')
      if (!BASE64_RE.test(data)) return bad('upload.data is not base64')
      // Base64 comes in groups of four. A length that is not a multiple of four
      // cannot decode to whole bytes, and `Buffer` would silently drop the tail
      // — which on a file is a byte missing from the middle of somebody's video.
      if (data.length % 4 !== 0) return bad('upload.data is not base64')
      return { ok: true, message: { t: 'upload.data', id: uploadId, data } }
    }
    case 'upload.end': {
      const uploadId = id(parsed.id)
      if (!uploadId) return bad('upload.end without an id')
      const digest = parsed.sha256
      if (typeof digest !== 'string' || digest.length !== SHA256_HEX_LENGTH || !HEX_RE.test(digest)) {
        return bad('upload.end without a digest')
      }
      // Lower-cased here rather than compared case-insensitively later: the
      // comparison is against `createHash().digest('hex')`, which is lower case,
      // and a case-folding comparison written at the call site is a case-folding
      // comparison somebody eventually writes as `===`.
      return { ok: true, message: { t: 'upload.end', id: uploadId, sha256: digest.toLowerCase() } }
    }
    case 'upload.cancel': {
      const uploadId = id(parsed.id)
      return uploadId
        ? { ok: true, message: { t: 'upload.cancel', id: uploadId } }
        : bad('upload.cancel without an id')
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
