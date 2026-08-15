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
 * `credential` is the only one that runs the other way round, and that is worth
 * saying out loud because it changes what the string means. Every other
 * capability is a verb the *desktop* will serve when the phone sends it; this one
 * is a question the *desktop asks the phone* — git on this machine needs a login
 * for a repository, and the phone is the thing holding it. So it is advertised in
 * both directions: the desktop lists it in `welcome.capabilities` to say "I may
 * ask you", and the client lists it in `hello.capabilities` to say "I can
 * answer". Both halves are needed and neither is optional in practice: a desktop
 * that asked a client which had never heard of the frame would sit there until a
 * timer gave up, which is precisely the thirty-second stall this feature exists
 * to not have.
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
  credential: 'credential',
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
export const CAPABILITIES: string[] = [
  CAPABILITY.localhost,
  CAPABILITY.create,
  CAPABILITY.upload,
  CAPABILITY.credential,
]

/**
 * What git was doing when it asked for a login.
 *
 * Two values because there are exactly two answers a person cares about, and the
 * difference between them is the whole of the prompting policy: a fetch or a
 * clone is a **read**, is reversible, and prompting for one buys nothing but
 * fatigue; a push is a **write**, is not reversible, and is the moment somebody
 * should get to see whose name goes on it.
 *
 * Sent as a fact about the operation rather than as an instruction. What the
 * client is being asked to *do* is `prompt` on the same frame, which is a
 * separate field for a separate reason — see `credential.request`.
 */
export const CREDENTIAL_OPERATIONS = ['read', 'write'] as const

export type CredentialOperation = (typeof CREDENTIAL_OPERATIONS)[number]

/**
 * Why a device would not answer, as a code rather than a sentence.
 *
 * The opposite direction from `tunnel.closed`, which carries prose, and for the
 * opposite reason: that sentence is written by the desktop and read on a phone,
 * whereas this one is written by a phone and printed into a terminal **on the
 * desktop**. The desktop owns the words that appear in its own terminal — it is
 * the side that knows whether the reader is looking at a push or a fetch, and it
 * is the side that must not pipe attacker-chosen text into a PTY. So the client
 * says which of two things happened and the desktop writes the sentence.
 *
 * `no-account` is not a refusal. It means the app on that device has no GitHub
 * connected yet, which is a different thing to be told and has a different fix.
 */
export const CREDENTIAL_DENIALS = ['denied', 'no-account'] as const

export type CredentialDenial = (typeof CREDENTIAL_DENIALS)[number]

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
 *
 * Bytes **of the encoded frame**, not of the text inside it. `chunkOutput`
 * spends this budget through `jsonCostOf`, which is the difference between a
 * cap that holds and one that holds only for ASCII: a terminal's output is
 * escape sequences, and `JSON.stringify` writes a bare control character as six
 * characters. Half of `MAX_MESSAGE_BYTES`, so the envelope and any client
 * counting slightly differently both fit in the headroom.
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

/**
 * Longest `create.provider`.
 *
 * The field names an agent CLI — `claude`, `codex`, `gemini`, `shell` — and the
 * longest of those is six characters. Thirty-two leaves room for a name nobody
 * has thought of yet while keeping the value small enough that refusing it costs
 * nothing; this parser does not know the list and deliberately does not check
 * against one. Whether a name is one this desktop can actually start is
 * `remote/session-create.ts`'s question, answered against the real provider
 * table, and the answer is a sentence rather than a closed socket.
 */
export const MAX_PROVIDER_LENGTH = 32

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

/**
 * How many capability names a client may claim, and how long each may be.
 *
 * A ceiling on an advisory field. The list is only ever compared against the
 * handful of names in {@link CAPABILITY}, so nothing is lost by refusing to
 * carry a thousand of them — and what it buys is that a `hello` cannot be made
 * to cost this process a megabyte of strings before it has authenticated.
 */
export const MAX_CLIENT_CAPABILITIES = 16
export const MAX_CAPABILITY_LENGTH = 32

/**
 * Longest username and secret a device may answer a credential request with.
 *
 * Generous rather than tight, because what is on the other end of these fields
 * is somebody's GitHub token and the shape of those is not ours to pin: a
 * classic token is 40 characters, a fine-grained one is over 90, an installation
 * token is longer still, and an OAuth flow that starts issuing something else
 * tomorrow must not be broken by a number written here today. The cap exists so
 * a hostile client cannot post a megabyte through the loopback endpoint and into
 * a `git` process, not to describe what a real token looks like.
 *
 * The username is bounded far more tightly because it genuinely is a login — or
 * one of the fixed placeholders GitHub accepts beside a token — and neither is
 * long.
 */
export const MAX_CREDENTIAL_USERNAME_LENGTH = 128
export const MAX_CREDENTIAL_SECRET_LENGTH = 4096

/**
 * Longest `host` and `repo` on a credential request.
 *
 * A hostname cannot exceed 253 characters and a GitHub `owner/name` cannot come
 * near this. Both travel outbound, so these bound what this desktop will *say*
 * rather than what it will accept — which is why they live here beside the
 * inbound caps rather than in the module that builds the frame: one file
 * describes the whole shape of the wire.
 */
export const MAX_CREDENTIAL_HOST_LENGTH = 253
export const MAX_CREDENTIAL_REPO_LENGTH = 256

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
  /**
   * `capabilities` is the client's half of the negotiation, and it is here
   * rather than in a later frame because the desktop may need it before the
   * client has sent anything else — a session started from this device can be
   * running `git push` a second after it connects.
   *
   * Optional, and absent is meaningful: it means "nothing beyond version 1",
   * which is exactly what every client shipped before this field says. Nothing
   * is granted by claiming a name — the list only decides what this desktop will
   * *send*, never what it will accept — so an inflated one buys a client nothing
   * except frames it will then have to ignore.
   */
  | { t: 'hello'; protocol: number; token: string; device: DeviceDescriptor; capabilities?: string[] }
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
   * ## `provider`, and the bug that put it here
   *
   * This field used to be absent, with a paragraph saying it was absent on
   * purpose: the phone has no honest way to know which agent CLIs are installed
   * on the far machine, so a picker built from a guess would offer choices that
   * fail. That argument is still true about a *picker*, and it was the wrong
   * conclusion, because the desktop-to-desktop client had already grown a
   * chooser and `machines/guest.ts` had been putting `provider` on the wire ever
   * since. TypeScript never complained — the value goes on through a spread,
   * which does not trigger an excess-property check — and this parser copied
   * across the fields it knew and dropped the rest without a word.
   *
   * Measured on a real Windows PC: asking for `shell` produced a `claude`
   * session. Nothing logged it, because from the desktop's side nothing had
   * happened — the frame simply never carried the field. That is the exact shape
   * of failure this file exists to prevent, arriving through the one gap a
   * parser has: a field it does not know about is indistinguishable from a field
   * that was never sent.
   *
   * So it travels, optionally, and an older client that sends nothing is
   * unaffected — it gets the desktop's own default provider, exactly as before.
   * A name this desktop cannot start is **refused with a sentence**, never
   * quietly swapped for another agent. And the `created` frame reports the
   * provider the session actually got, which is what a client should display: a
   * desktop whose Claude CLI is not installed still answers a `claude` request
   * with a shell, and says so in the answer rather than in silence.
   *
   * Deliberately **not** here:
   *
   *  - **A title.** Every other session in this app is titled after its folder,
   *    by `PtyManager`, and a phone-chosen title would be the one tab in the
   *    desktop that does not mean what the others mean. It would also be
   *    attacker-chosen display text in the desktop's own chrome, for nothing.
   *  - **`resume`.** Continuing the newest conversation in a folder is real and
   *    the desktop supports it, but only for providers that have a resume flag;
   *    a toggle that silently does nothing for a plain shell is a fake feature.
   *    Resuming a *session* — the thing the phone actually wants — is `attach`,
   *    which has worked since v1 and replays the scrollback. `machines/guest.ts`
   *    sends this one too and it is still dropped here; that is a live gap,
   *    named rather than closed, because closing it means answering the
   *    per-provider question above and not merely widening a type.
   */
  | { t: 'create'; cwd?: string; cols?: number; rows?: number; provider?: string }
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
  /* ---- capability `credential`. Refused outright when it is not advertised. -- */
  /**
   * "I heard you, and I am dealing with it."
   *
   * The one frame here that exists purely for a failure mode, and it is the
   * failure mode the whole feature is judged on. Without it there is no way to
   * tell a device that is asleep from a person who is thinking: both look like
   * silence, so the desktop would have to wait out the *human* deadline before
   * it could say "your device isn't reachable" — a thirty-second stall on a push,
   * with no explanation, which is how people stop trusting a feature.
   *
   * With it there are two deadlines. A few seconds for this, which a live app on
   * a woken phone answers instantly; then, and only then, as long as a person
   * needs to read a prompt and decide. Silence in the first window is a device
   * that is not there, and it is answered in seconds with a sentence that says
   * what to do about it.
   *
   * Sent for silent requests too, where it costs nothing — the answer follows it
   * in the same breath — because a client that only acked when it was about to
   * prompt would be one more thing that has to be right.
   */
  | { t: 'credential.ack'; id: string }
  /**
   * The login, for this one operation.
   *
   * It is used once, in memory, and is never written to this machine's disk —
   * not by the helper, which refuses git's `store`, and not here, which hands it
   * straight to the process that asked and forgets it. There is no cache to
   * expire and nothing to clean up when the device disconnects.
   *
   * `remember` is the second button on the prompt — "Approve always for this
   * repo" — and it is a *scope*, not a stored secret. It says the desktop may
   * stop asking about this repository from this device; every push still comes
   * back here for the credential itself, because this end has never held one.
   * It is ignored for a request that was not a prompt, since agreeing to
   * something nobody was asked is not consent to anything.
   */
  | { t: 'credential.answer'; id: string; username: string; password: string; remember?: true }
  /**
   * No.
   *
   * Carries a code rather than a sentence — see {@link CREDENTIAL_DENIALS} for
   * why this direction is the opposite of `tunnel.closed`. Absent means
   * `denied`, so a client that only ever refuses can send the bare frame.
   */
  | { t: 'credential.deny'; id: string; reason?: CredentialDenial }

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
      /**
       * What kind of machine this is — `'darwin'`, `'win32'`, `'linux'`.
       *
       * Sent raw rather than as a noun because the noun is presentation, and
       * the clients do not share a language for it: the desktop writes "This
       * Mac will not start a session in that folder" in English sentences it
       * composes itself, while a phone builds its own labels and would have to
       * un-say a word it was handed. Every client maps this to its own noun.
       *
       * Optional, like `capabilities`, and for the same reason: a desktop that
       * predates this field is still a desktop a current phone must talk to.
       * A client that reads nothing here must show something neutral — never
       * guess "Mac", which is the bug this field exists to end. A phone paired
       * to a Windows PC read "Running on the Mac" on its own session list,
       * because the only place the machine's kind appeared was a string
       * constant compiled into the phone.
       */
      hostPlatform?: string
      /**
       * Folders this device may start a session in, most relevant first.
       *
       * Sent so the phone's picker can show exactly what it may use, rather
       * than a list it assembled from the sessions it happens to be able to
       * see. Those two were never the same set and the difference was
       * unexplainable from the phone: the picker showed one folder, the desktop
       * would have accepted several, and nothing on either screen said why.
       *
       * The same array the desktop enforces against — see `session-create.ts`,
       * where one function answers both questions — so a folder on this list is
       * a folder that will start, subject only to it still existing.
       *
       * Optional, like `capabilities` and `hostPlatform`: a desktop that
       * predates the field is one a current phone still has to talk to, and a
       * client that reads nothing here keeps whatever it did before. Absent is
       * also what a host that cannot start sessions at all sends, which is the
       * same thing its missing `create` capability already says.
       *
       * Empty is meaningful and is not the same as absent. It means a person
       * chose no folders for this device, so New Session has nowhere to go —
       * a client that draws the button anyway will be refused with a sentence
       * that says so.
       */
      folders?: string[]
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
  /**
   * This device's folder list changed while it was connected.
   *
   * Pushed, not polled, and it carries the whole list rather than a delta —
   * there is one list per device, it is short, and a client that applied
   * deltas would need to be right about every one of them to end up with the
   * set the desktop is actually enforcing.
   *
   * It exists because the list is editable from the desktop at any moment. The
   * enforcement is already live — `folders()` is read per request, so removing
   * a folder takes effect on the very next `create` with no reconnect — and
   * without this frame the phone would keep drawing the removed folder in its
   * picker until somebody closed and reopened the app, offering a tap whose
   * only outcome is a refusal.
   *
   * An older client drops a message type it does not know and carries on, which
   * is the additive rule the capability list exists for; the worst it suffers is
   * the stale picker it has today.
   */
  | { t: 'folders'; folders: string[] }
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
  /* ---- capability `credential` ------------------------------------------- */
  /**
   * Git on this machine needs a login for a repository, and this device holds it.
   *
   * The only frame in this protocol the desktop sends unprompted as a *question*.
   * Everything else it sends is either an answer or an event; this one is waiting
   * on a reply, and the two ways to reply are `credential.answer` and
   * `credential.deny`. A client that neither acks nor answers is treated as a
   * device that is not there — see `credential.ack`.
   *
   * `repo` is `owner/name`, or **null** when git gave no path to derive one from.
   * Null is not a detail to paper over: a prompt that cannot name the repository
   * is a prompt asking somebody to approve "a push, somewhere", and a client
   * should say exactly that rather than invent a name. It happens when the remote
   * is not a two-segment path — a gist, a wiki, a self-hosted layout — and the
   * honest answer is that this desktop does not know what to call it.
   *
   * `prompt` is the instruction and `operation` is the fact, and they are two
   * fields because they answer two different questions. `operation` says what git
   * is doing, always, so a client can show activity honestly. `prompt` says
   * whether a person should be asked — false for every read, and false for a
   * write against a repository this device has already approved. Folding them
   * into one would mean sending `read` for an approved push, which is a lie told
   * to the one screen in this feature that exists to tell the truth.
   *
   * **Where the memory lives, and why it is here.** The desktop remembers which
   * repositories a device has approved; the device remembers nothing. That looks
   * backwards next to "their token stays on their device", and it is the same
   * principle: what the desktop keeps is a *scope*, in memory, for as long as the
   * app is running — never a credential, never on disk. Putting it on the device
   * instead would give the two ends two answers to "has this been approved" and
   * no way to reconcile them.
   */
  | {
      t: 'credential.request'
      id: string
      host: string
      repo: string | null
      operation: CredentialOperation
      prompt: boolean
    }

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

/**
 * A plausible agent name on `create.provider`.
 *
 * Every id this app has — `claude`, `codex`, `gemini`, `shell` — is a bare
 * lowercase word, and a name that is not shaped like one is not a name any
 * client of ours produces. Deliberately narrower than "a string this parser can
 * carry": the value selects a row in the provider table and, through it, a
 * command that gets executed, and the cheapest place to say "that is not an
 * identifier" is before anything has looked it up. Whether the identifier names
 * an agent this desktop actually has is a different question and a different
 * file — see the note in the `create` case.
 */
const PROVIDER_RE = /^[a-z][a-z0-9-]*$/

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
 * The capability names a client claims, cleaned rather than trusted.
 *
 * Lenient about the contents and strict about the shape, and the split is
 * deliberate. A field that is not an array is a client that has misunderstood
 * the protocol, and it is refused. An array with junk in it is filtered, because
 * the list is advisory — it decides only which frames this desktop will *send* —
 * and locking a device out of a shell over a stray entry in an optional field
 * would be a spectacularly bad trade.
 *
 * Names are never checked against {@link CAPABILITY} here. A client is allowed
 * to know about a capability this desktop has not heard of; the comparison
 * belongs to whoever is about to send a frame, and doing it here would mean an
 * older desktop silently erasing the half of the list it does not recognise.
 */
function capabilities(value: unknown): string[] | null {
  if (!Array.isArray(value)) return null
  const out: string[] = []
  for (const entry of value) {
    if (typeof entry !== 'string' || entry === '' || entry.length > MAX_CAPABILITY_LENGTH) continue
    if (CONTROL_CHARS.test(entry)) continue
    if (out.includes(entry)) continue
    out.push(entry)
    if (out.length >= MAX_CLIENT_CAPABILITIES) break
  }
  return out
}

/**
 * One half of a credential, as it arrives from a device.
 *
 * Control characters are **refused**, not stripped, and that is the security
 * check in this function rather than a tidiness one. The value's next stop is
 * git's credential protocol, which is a stream of `key=value` lines: a newline
 * inside a password ends the line early and the rest of it becomes a *different
 * key*, so a device could otherwise write `url=` or `quit=` into the middle of
 * an answer and change what git does with it. Git refuses these itself for the
 * same reason; refusing here means the refusal is legible — "that is not a
 * credential" — instead of surfacing later as a git error nobody can place.
 *
 * Stripping would be worse than either: it turns a hostile value into a
 * different, legal-looking one, which is the argument `create.cwd` makes.
 */
function credentialValue(value: unknown, max: number): string | null {
  if (typeof value !== 'string' || value === '' || value.length > max) return null
  return CONTROL_CHARS.test(value) ? null : value
}

/**
 * A denial code, narrowed by comparison rather than by a cast.
 *
 * The comparison returns the entry out of {@link CREDENTIAL_DENIALS}, so the
 * value that reaches the message is one this module wrote, not one a client
 * sent that happened to match. `includes` plus `as` would have produced the same
 * type and a different guarantee.
 */
function denial(value: unknown): CredentialDenial | null {
  for (const known of CREDENTIAL_DENIALS) {
    if (value === known) return known
  }
  return null
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
      const message: Extract<ClientMessage, { t: 'hello' }> = {
        t: 'hello',
        protocol,
        token: supplied,
        device,
      }
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the value that is checked has to be
      // the value that is filtered. Absent stays absent rather than becoming an
      // empty array — "said nothing" and "claimed nothing" are the same thing to
      // every reader of this field, but only one of them is what an older client
      // actually sent, and the shape a client sent is the shape a log should
      // show.
      const claimed = parsed.capabilities
      if (claimed !== undefined) {
        const cleaned = capabilities(claimed)
        if (cleaned === null) return bad('hello with an unusable capability list')
        message.capabilities = cleaned
      }
      return { ok: true, message }
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
      // Read once, for the reason spelled out on `input.data`. Shape only: this
      // parser does not hold the provider table and must not appear to — a name
      // it does not recognise is a *refusal with a sentence* from the session
      // layer, not a closed socket from here, because the person who typed it is
      // holding a phone and "the connection dropped" tells them nothing.
      //
      // The character class is what stops this being a hole rather than a field.
      // The value ends up selecting a row in a table and, through it, a command
      // to execute, so anything that is not a bare lowercase identifier is
      // refused outright rather than trimmed: a name with a slash, a space or a
      // NUL in it has no legitimate sender and every trimming rule invents a
      // *different* legal-looking name out of a hostile one.
      const rawProvider = parsed.provider
      if (rawProvider !== undefined) {
        if (typeof rawProvider !== 'string' || rawProvider === '') {
          return bad('create with an unusable provider')
        }
        if (rawProvider.length > MAX_PROVIDER_LENGTH) {
          return tooLarge('create with a provider over the name limit')
        }
        if (!PROVIDER_RE.test(rawProvider)) return bad('create with an unusable provider')
        message.provider = rawProvider
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

    /* ---- capability `credential` ---------------------------------------- */
    // Shape-checked here and authorised nowhere near here. Whether this desktop
    // asked anything at all, whether this device is the one it asked, and
    // whether the answer is still wanted are questions only the desk in
    // `credentials.ts` can answer, because only it is holding the request.
    case 'credential.ack': {
      const requestId = id(parsed.id)
      return requestId
        ? { ok: true, message: { t: 'credential.ack', id: requestId } }
        : bad('credential.ack without an id')
    }
    case 'credential.answer': {
      const requestId = id(parsed.id)
      if (!requestId) return bad('credential.answer without an id')
      // Read once each, for the reason spelled out on `input.data`.
      const rawUser = parsed.username
      const rawSecret = parsed.password
      const username = credentialValue(rawUser, MAX_CREDENTIAL_USERNAME_LENGTH)
      if (username === null) return bad('credential.answer without a usable username')
      const password = credentialValue(rawSecret, MAX_CREDENTIAL_SECRET_LENGTH)
      // The reason says the field is unusable and never why, which is the rule
      // for every refusal in this file and matters more here than anywhere else:
      // this reason is logged, and the value being described is somebody's
      // GitHub token.
      if (password === null) return bad('credential.answer without a usable secret')
      const answer: Extract<ClientMessage, { t: 'credential.answer' }> = {
        t: 'credential.answer',
        id: requestId,
        username,
        password,
      }
      // Only the literal `true`. A truthy string or a 1 would be a client whose
      // "Approve once" button widened itself into "always" through a JSON quirk,
      // and the difference between those two taps is the entire consent model.
      if (parsed.remember === true) answer.remember = true
      return { ok: true, message: answer }
    }
    case 'credential.deny': {
      const requestId = id(parsed.id)
      if (!requestId) return bad('credential.deny without an id')
      const deny: Extract<ClientMessage, { t: 'credential.deny' }> = { t: 'credential.deny', id: requestId }
      // An unknown reason is dropped rather than refused: a newer client naming
      // a denial this desktop has not heard of has still denied, and closing the
      // socket over the *label* on a "no" would turn a refusal that worked into
      // a device that fell off the network.
      const reason = denial(parsed.reason)
      if (reason !== null) deny.reason = reason
      return { ok: true, message: deny }
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

/**
 * What one code point costs *inside a JSON string*, in bytes of frame.
 *
 * This is not the same number as `utf8Length` spends on it, and the difference
 * is the whole defect this function was rewritten for. `chunkOutput` fills a
 * budget denominated in bytes on the wire, but nothing puts a bare string on
 * the wire — `serialize` wraps it in `{"t":"output","id":…,"data":"…"}`, and
 * `JSON.stringify` is not a byte-for-byte copy of what it is given:
 *
 *   - `"` and `\` become two characters each,
 *   - the five escapes with short forms (`\b \t \n \f \r`) become two,
 *   - **every other C0 control becomes six** — `\u001b`, and a terminal’s
 *     output is made of those. A cursor move is `ESC [ 1 2 ; 3 4 H`; a
 *     colour change is another. Escape alone is one byte counted and six
 *     bytes sent,
 *   - a lone surrogate becomes six as well, because `JSON.stringify` has
 *     produced well-formed output since ES2019 and escapes what it cannot
 *     encode.
 *
 * Counted as one byte each, 32 KiB of escape-heavy scrollback serialises to as
 * much as 192 KiB of frame — three times `MAX_MESSAGE_BYTES`, which is the cap
 * *every* client on this wire enforces on what it receives. The phone does not
 * render a slow frame in that case; it refuses the frame and closes the socket,
 * and what a person sees is a session that drops whenever an agent draws
 * something colourful. So the budget is spent in the currency it is denominated
 * in: bytes of JSON, not bytes of text.
 */
function jsonCostOf(code: number): number {
  if (code < 0x20) {
    // \b \t \n \f \r have two-character forms; the rest of C0 has none.
    return code === 0x08 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d ? 2 : 6
  }
  if (code === 0x22 || code === 0x5c) return 2
  if (code < 0x80) return 1
  if (code < 0x800) return 2
  // A surrogate reaching here is unpaired — `codePointAt` returns the pair as
  // one code point above 0xffff — and `JSON.stringify` writes it as `\udXXX`.
  if (code >= 0xd800 && code <= 0xdfff) return 6
  if (code < 0x10000) return 3
  return 4
}

/**
 * Split output into frames the phone can parse without stalling.
 *
 * Cut on code-point boundaries and measured in bytes of the JSON frame each
 * piece ends up inside, which is what the far end's own cap counts. Slicing
 * UTF-16 at a fixed offset instead would eventually land between the halves of
 * a surrogate pair: `JSON.stringify` encodes the halves happily, and the phone
 * renders two replacement characters — one corrupted glyph per 32 KiB of
 * scrollback, which is exactly the kind of defect nobody traces back to here.
 *
 * There is no `if (!overBytes(data, size)) return [data]` shortcut any more,
 * and its absence is deliberate rather than an oversight. That test measured
 * raw UTF-8, so a burst that was *under* the budget by that measure and three
 * times over it once escaped was handed back whole, in one frame, without ever
 * reaching the loop below — the largest frames this function produced were the
 * ones it decided not to look at. The loop answers the same in one pass: a
 * string that fits comes back out of `slice(0)` unsplit.
 *
 * The envelope around the piece — the type, the session id, the field names —
 * is not counted. It is under a hundred bytes against a 32 KiB budget and a
 * 64 KiB cap, so the headroom absorbs it; what it must never absorb is a
 * multiplier, which is what escaping is.
 */
export function chunkOutput(data: string, size = OUTPUT_CHUNK_BYTES): string[] {
  if (data === '') return []

  const out: string[] = []
  let start = 0
  let bytes = 0
  let at = 0
  while (at < data.length) {
    const code = data.codePointAt(at) as number
    const units = code > 0xffff ? 2 : 1
    const cost = jsonCostOf(code)
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

/* ============================================================================ */
/* The other direction: what a client makes of what the desktop sent            */
/* ============================================================================ */

/**
 * ## Why this lives here and not in whichever client needed it first
 *
 * Everything above narrows what arrives *at* the desktop. This section narrows
 * what arrives at a **client**, and until recently there was no client in this
 * repository that ran on Node — the phone app parses `welcome` in Swift, the
 * Android app in Kotlin and the web app in `pwa/src/protocol-client.ts`.
 *
 * A desktop can now be a guest of another desktop (`src/main/remote/machines.ts`),
 * which means the main process has to read a `welcome` too. There was a fourth
 * copy of this parser available for the taking — `pwa/src/protocol-client.ts` is
 * plain TypeScript and imports its types from this very file — and taking it is
 * not possible: `tsconfig.node.json` is a composite project that does not
 * include `pwa/`, so an import across that boundary fails to compile rather than
 * merely looking untidy.
 *
 * So the parser moves to where the vocabulary already lives, which is here. That
 * leaves the browser client holding a copy for now; it should import this one
 * and delete its own, and that is a change to `pwa/` rather than to this file.
 * Two implementations of one wire are safe when something fails on the drift —
 * `protocol.test.ts` is where that happens for this side.
 *
 * ## What is checked, and why a client checks anything at all
 *
 * The desktop on the other end is not hostile, but it is not always what
 * answers. A captive portal on hotel wifi replies to every request with its own
 * login page, and the first thing an unguarded client does with that is
 * `JSON.parse` an HTML document and read `.sessions` off the result. Validating
 * here means the guest says "that is not this app" instead of throwing inside a
 * socket handler and leaving a machine row that never explains itself.
 *
 * One bad row does not discard a list. A guest showing four of five sessions is
 * useful; one showing none because the fifth had a null title is not.
 */

export type ServerParse =
  | { ok: true; message: ServerMessage }
  | { ok: false; reason: string }

/** One session row, or null. Null rows are skipped rather than fatal. */
export function parseSession(value: unknown): RemoteSession | null {
  if (!isRecord(value)) return null
  const id = asString(value.id)
  const title = asString(value.title)
  const cwd = asString(value.cwd)
  const provider = asString(value.provider)
  const status = asString(value.status)
  if (id === null || id === '' || title === null || cwd === null) return null
  if (provider === null || status === null) return null
  const exitCode = value.exitCode === null ? null : asWhole(value.exitCode)
  return { id, title, cwd, provider, status, exitCode }
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function asWhole(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) ? value : null
}

function sessionRows(value: unknown): RemoteSession[] | null {
  if (!Array.isArray(value)) return null
  const rows: RemoteSession[] = []
  for (const entry of value) {
    const session = parseSession(entry)
    if (session !== null) rows.push(session)
  }
  return rows
}

/**
 * Short strings, dropped individually.
 *
 * Used for both `capabilities` and `folders`, which have the same rule for the
 * same reason: one unreadable entry must not cost the frame carrying it. They
 * differ in what *absent* means, and that difference is handled by the caller —
 * see the `welcome` branch.
 */
function stringList(value: unknown, maxLength: number): string[] | null {
  if (!Array.isArray(value)) return null
  const out: string[] = []
  for (const entry of value) {
    if (typeof entry === 'string' && entry !== '' && entry.length <= maxLength) out.push(entry)
  }
  return out
}

function asErrorCode(value: unknown): ProtocolErrorCode | null {
  const code = asString(value)
  if (code === null) return null
  const found = PROTOCOL_ERROR_CODES.find((known) => known === code)
  return found ?? null
}

/** The only door inbound text comes through on a client, mirroring `parseClientMessage`. */
export function parseServerMessage(raw: unknown): ServerParse {
  if (typeof raw !== 'string') return { ok: false, reason: 'not text' }
  if (overBytes(raw, MAX_MESSAGE_BYTES)) return { ok: false, reason: 'larger than the message cap' }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { ok: false, reason: 'not JSON' }
  }
  return parseServerFrame(parsed)
}

/**
 * The same reader, given the decoded value instead of the text.
 *
 * `parseClientMessage` has taken `unknown` from the start for this reason — an
 * in-process bridge hands over an object and there is no frame to measure — and
 * this is the same door on the other direction of the wire, split out rather
 * than duplicated so there is still exactly one place that says what a host may
 * say.
 *
 * It exists because a client that has to look at a frame *before* delegating
 * was paying for a second `JSON.parse` of the same text on every inbound
 * message: `pwa/src/protocol-client.ts` probes for `credential.request`, which
 * this parser deliberately does not cover, and then handed the string here to be
 * parsed all over again. Parsing once and branching costs nothing and is
 * measurably less than parsing twice on a socket carrying a terminal.
 *
 * The size cap belongs to whoever holds the text — the string cannot be
 * measured once it is an object, and a caller that decoded it has already spent
 * what the cap exists to bound. `parseServerMessage` above applies it; the PWA
 * applies it before its own single parse. A new caller of this function that
 * skips it is a caller that will happily parse a megabyte.
 */
export function parseServerFrame(parsed: unknown): ServerParse {
  if (!isRecord(parsed)) return { ok: false, reason: 'not an object' }

  switch (parsed.t) {
    case 'welcome': {
      const protocol = asWhole(parsed.protocol)
      const deviceId = asString(parsed.deviceId)
      const deviceName = asString(parsed.deviceName)
      const sessions = sessionRows(parsed.sessions)
      if (protocol === null || deviceId === null || deviceName === null || sessions === null) {
        return { ok: false, reason: 'incomplete welcome' }
      }
      // A null token means "you already had one"; a string means "store this".
      // A missing field is neither, and guessing which it meant is how a guest
      // ends up believing it is paired while holding nothing.
      const token = parsed.token === null ? null : asString(parsed.token)
      if (token === null && parsed.token !== null) {
        return { ok: false, reason: 'welcome without a token field' }
      }
      const message: Extract<ServerMessage, { t: 'welcome' }> = {
        t: 'welcome',
        protocol,
        deviceId,
        deviceName,
        token,
        sessions,
        capabilities: stringList(parsed.capabilities, MAX_CAPABILITY_LENGTH) ?? [],
      }
      // Both of the optional fields are assigned only when they are there, and
      // `folders` is the one where it matters: an absent list and an empty one
      // are two different facts about this device. Absent means the desktop
      // never mentioned folders — every build older than the field — and the
      // guest must keep doing whatever it did before. Empty means somebody
      // chose no folders for *this* device, which is a real state with a real
      // remedy, and flattening the two turns "your other machine is old" into
      // "you have been shut out".
      const hostPlatform = asString(parsed.hostPlatform)
      if (hostPlatform !== null) message.hostPlatform = hostPlatform
      const folders = stringList(parsed.folders, MAX_CWD_BYTES)
      if (folders !== null) message.folders = folders
      return { ok: true, message }
    }
    case 'sessions': {
      const sessions = sessionRows(parsed.sessions)
      return sessions === null
        ? { ok: false, reason: 'sessions without a list' }
        : { ok: true, message: { t: 'sessions', sessions } }
    }
    case 'attached': {
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'attached without an id' }
        : { ok: true, message: { t: 'attached', id } }
    }
    case 'detached': {
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'detached without an id' }
        : { ok: true, message: { t: 'detached', id } }
    }
    case 'output': {
      const id = asString(parsed.id)
      const data = asString(parsed.data)
      if (id === null || id === '' || data === null) {
        return { ok: false, reason: 'output without id and data' }
      }
      return {
        ok: true,
        message: parsed.replay === true ? { t: 'output', id, data, replay: true } : { t: 'output', id, data },
      }
    }
    case 'status': {
      const id = asString(parsed.id)
      const status = asString(parsed.status)
      if (id === null || id === '' || status === null) {
        return { ok: false, reason: 'status without id and status' }
      }
      return { ok: true, message: { t: 'status', id, status } }
    }
    case 'exit': {
      const id = asString(parsed.id)
      const exitCode = asWhole(parsed.exitCode)
      if (id === null || id === '' || exitCode === null) {
        return { ok: false, reason: 'exit without id and code' }
      }
      return { ok: true, message: { t: 'exit', id, exitCode } }
    }
    case 'created': {
      // Refused rather than half-read, unlike a row inside a list: a `sessions`
      // frame missing one entry is still a useful list, whereas this frame *is*
      // the one session, and a client that accepted a nameless one would open an
      // id the desktop never minted.
      const session = parseSession(parsed.session)
      return session === null
        ? { ok: false, reason: 'created without a session' }
        : { ok: true, message: { t: 'created', session } }
    }
    case 'folders': {
      // Refused when it carries no list at all. Unlike the optional field in
      // `welcome` there is nothing else in this frame, so reading it as "no
      // folders" would take the picker away on the strength of a malformed
      // message.
      const folders = stringList(parsed.folders, MAX_CWD_BYTES)
      return folders === null
        ? { ok: false, reason: 'folders without a list' }
        : { ok: true, message: { t: 'folders', folders } }
    }
    case 'error': {
      const code = asErrorCode(parsed.code)
      if (code === null) return { ok: false, reason: 'error with an unknown code' }
      return { ok: true, message: { t: 'error', code, message: asString(parsed.message) ?? '' } }
    }
    case 'pong':
      return { ok: true, message: { t: 'pong' } }
    default:
      // Deliberately a refusal rather than a silent skip. Everything past
      // version 1 is negotiated through `welcome.capabilities`, so a frame this
      // build has never heard of is one it never asked for — and the guest that
      // reads this only ever asks for the v1 verbs.
      return { ok: false, reason: 'unknown message type' }
  }
}
