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
/**
 * `devserver` is the answer to "the localhost link you sent me is not up".
 *
 * `localhost` can list a port and tunnel to it, and neither of those has ever
 * had anything to say about the far more common case: the port is not there,
 * because the dev server is not running, and the machine it would run on is in
 * another room. This capability is `dev.status` (what is this project's dev
 * server doing) and `dev.start` (start it), plus the `dev.state` frames the
 * desktop pushes while it comes up.
 *
 * Its own name rather than part of `localhost`, and that is not tidiness. A host
 * can serve `localhost` with nothing but a socket — every build can — while this
 * one needs a session layer that can start a session *and* a device that has
 * been granted a folder to start it in. The public demo box is the case that
 * makes the split concrete: it offers `create` and nothing else, and it must not
 * offer a stranger a button that runs `npm run dev` in the owner's checkout.
 *
 * It is deliberately keyed by **folder**, not by port. A dev server is a script
 * in a project's `package.json`, run in that project's directory; there is no
 * such thing as *the* dev server on a machine with four checkouts, and the port
 * does not exist until the thing is up, which is the state the feature exists to
 * get out of. `src/main/dev-server.ts` argues this at length.
 */
/**
 * `copilot` is the one capability that is advertised and still refused.
 *
 * Every other name on this list is a promise about a *host*: this desktop
 * speaks these frames, so send them. This one is a promise about the host and
 * nothing at all about the device — whether a device reaches the copilot is
 * decided by its **kind**, chosen by a person at the machine when the device was
 * approved, and it travels beside the capability rather than inside it (see
 * `welcome.copilot` and {@link CopilotLinkWire}). It was a separate connection
 * with its own code and credential for two days in August 2026;
 * `remote/copilot-access.ts` carries both arguments.
 *
 * The split is deliberate and it is the shape `folders` already has. A
 * capability answers *can this machine do it*; a grant answers *may you*. Fold
 * them together — advertise `copilot` only to granted devices — and two things
 * break at once. A client cannot tell "this desktop is too old to have a
 * copilot" from "you have not been given access", which are two different
 * sentences with two different remedies. And a grant ticked while a phone is
 * connected could only reach it by re-sending a `welcome`, which is a frame
 * that means "you have just connected"; the push frame `copilot.grant` is what
 * that grant change actually rides on.
 *
 * Nothing is leaked by advertising it to an ungranted device. What this desktop
 * can do is not a secret — the whole list is already sent to every paired phone
 * — and a device that sends a `copilot.*` verb without a grant gets a clean
 * `unauthorized` rather than a closed socket, because a client drawing a tab it
 * cannot use is a UI bug on that client and not an attack on this one.
 */
/**
 * `close` is `create`'s opposite number, and it is deliberately its own name.
 *
 * A session can be started from a phone and, until this existed, could never be
 * ended from one. That was the shape of the gap rather than an oversight nobody
 * had noticed: v1 carries list, attach, detach, input, resize and create, and
 * `detach` is the closest thing to it, which is exactly the confusion worth
 * avoiding — detaching stops *this device* watching, closing ends the process
 * everybody is watching. `ios/TerminalDeck/Screens/SessionListView.swift` refused
 * to draw a Close button for as long as this name did not exist, and refused the
 * two available fakes with it: typing `exit` or a Ctrl-C into the pty is not
 * closing a session, because a full-screen agent CLI ignores both and the row
 * stays; and a Close that only archived would be a label describing something
 * else.
 *
 * Not folded into `create`, even though the two are the same feature read from
 * two directions. A host can genuinely have one and not the other — the demo box
 * starts sessions for strangers and must not let a stranger end somebody else's
 * — and `SessionAccess.close` is a separate optional method for that reason, so
 * a host that cannot end a session never advertises this and a client that never
 * sees it never draws the button. The same negotiation `create` gets, and the
 * same reason: a capability list assembled from a boolean somebody has to
 * remember to set is a capability list that will one day lie.
 */
export const CAPABILITY = {
  localhost: 'localhost',
  create: 'create',
  close: 'close',
  upload: 'upload',
  credential: 'credential',
  devserver: 'devserver',
  copilot: 'copilot',
  web: 'web',
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
  CAPABILITY.close,
  CAPABILITY.upload,
  CAPABILITY.credential,
  CAPABILITY.devserver,
  CAPABILITY.copilot,
  CAPABILITY.web,
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
 * The five things one project's dev server can be, as one word.
 *
 * They are five and not three because a client has to be able to draw five
 * different things, and two of the pairs are the ones that get collapsed:
 *
 *  - `no-dev-script` is **not** `idle`. `idle` means "press this"; this means
 *    "there is nothing to press, and there never will be for this folder,
 *    because its `package.json` declares no `dev`, `start` or `serve`". A client
 *    that flattens them draws a button whose only possible outcome is a refusal.
 *  - `failed` is **not** `idle` either. The session that failed is still there
 *    with the reason printed in it, and the useful thing to offer is that
 *    session — not a fresh Start button drawn as though nothing had happened.
 *
 * `starting` is the state this whole feature was asked for: "if it's not [quick]
 * then we can show some animation, loading or 'activating'". It is the one that
 * carries {@link DevServerReport.note}.
 */
export const DEV_SERVER_STATUSES = ['no-dev-script', 'idle', 'starting', 'ready', 'failed'] as const

export type DevServerStatus = (typeof DEV_SERVER_STATUSES)[number]

/**
 * One project's dev server, as a client sees it.
 *
 * Mirrors `DevServerState` in `src/main/dev-server.ts` and is declared here
 * rather than imported from it, for exactly the reason {@link LocalPort} is: the
 * shape a phone is sent is a contract with three clients in three languages, and
 * a field added to the desktop's own type must not reach the wire by accident.
 * `server.ts` rebuilds this field by field, so adding one there is a deliberate
 * act rather than a spread.
 *
 * Which fields are set for which status:
 *
 * | status          | script/command | sessionId | port/url | note | message |
 * |-----------------|----------------|-----------|----------|------|---------|
 * | `no-dev-script` | –              | –         | –        | –    | –       |
 * | `idle`          | ✓              | –         | –        | –    | –       |
 * | `starting`      | ✓              | ✓         | –        | maybe| –       |
 * | `ready`         | ✓              | ✓         | ✓        | –    | –       |
 * | `failed`        | ✓              | maybe     | –        | –    | ✓       |
 *
 * A client must still read defensively — this arrives as JSON — but it may rely
 * on the one rule the desktop enforces and tests: **`port` and `url` appear only
 * on `ready`, and `ready` is only ever sent after something accepted a TCP
 * connection on that port.** Not after a scan listed it, and not after a line of
 * the server's output mentioned it. That is the whole promise of this frame.
 */
export interface DevServerReport {
  /** The project folder, exactly as the desktop offered it in `welcome.folders`. */
  folder: string
  status: DevServerStatus
  /** The `package.json` script that runs it, e.g. `dev`. */
  script?: string
  /** The command line that will be typed, e.g. `pnpm run dev`. Display it. */
  command?: string
  /**
   * The session it is running in — a real session in `sessions`, which the
   * client can attach to, read and kill exactly like any other. This is how a
   * failure is investigated and how a dev server is stopped; there is no
   * separate stop verb, because there is no separate kind of process.
   */
  sessionId?: string
  /** Proven reachable. See the rule above. */
  port?: number
  /** `http://localhost:<port>`, ready to open through a `tunnel.open` on `port`. */
  url?: string
  /**
   * The server's own latest output line, while `starting`.
   *
   * Untrusted display text and the only field here that is: it is bytes a
   * process on the desktop printed. Draw it as text, never as markup, and never
   * parse it — the desktop has already done the only parsing anyone should do
   * with it.
   */
  note?: string
  /** Why it failed, in a sentence written by the desktop. */
  message?: string
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

/**
 * The longest URL `web.open` will carry.
 *
 * Two kilobytes is the practical ceiling every browser and every server agrees
 * on for a URL — IE's 2083 is where the number comes from and nothing since has
 * gone lower — so it is generous for the thing this verb is actually for, which
 * is `http://localhost:5173/`, and small enough that a client that has gone
 * wrong cannot push a megabyte of query string through a sealed channel and into
 * an address bar.
 */
export const MAX_URL_LENGTH = 2048

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

/* -------------------------------------------------- capability `copilot` -- */

/**
 * The three tiers a copilot connection can be given, on the wire.
 *
 * **`alter` used to be absent here and its absence was called the mechanism.**
 * `remote/copilot-grants.ts` refused to store it, refused to read it out of a
 * hand-edited file, and this type refused to carry it — three independent
 * refusals guarding the tier whose safety property is *a human at the machine
 * says yes*. That is superseded, and the reason is not that the property was
 * abandoned: it is that the second factor moved. The thing a device must have in
 * order to answer its own confirmation is no longer *be at the desk*, it is
 * *have been deliberately paired, at the desk, as one of his own devices* — a
 * decision that cannot be changed without pairing again. It was a separate
 * copilot connection with its own code for two days in between;
 * `remote/copilot-access.ts` carries both arguments and why the middle one did
 * not survive. `COPILOT-REMOTE.md` §4 has the long form.
 *
 * Not spelled `Tier` and not imported from `deck-control/surface.ts`, even
 * though the members now match. That module is main-process-only and this file
 * compiles into a browser (see the header); and the two remain genuinely
 * different sets — the tier set is `deck-control`'s, the *grantable* set is this
 * feature's, and a fourth tier added over there must not silently become
 * grantable over here by sharing a type.
 */
export type CopilotTier = 'read' | 'act' | 'alter'

/**
 * One connection's copilot access, as `welcome` and `copilot.grant` carry it.
 *
 * Always all three fields, never a partial object and never absent-meaning-false.
 * A client then has exactly one shape to read, and "no access" has one spelling
 * rather than three — which matters because the difference between them is the
 * difference between a Copilot tab that is hidden and one that is drawn and
 * refuses everything.
 */
export interface CopilotGrantWire {
  read: boolean
  act: boolean
  alter: boolean
}

/**
 * Whether this device reaches the copilot at all, and whether this socket has
 * opened the stream.
 *
 * Three facts rather than one, because a client has three different screens to
 * draw and folding them together makes one of them wrong:
 *
 *  - `linked` — this device reaches the copilot. Since 2026-08-19 that is
 *    exactly *"it was paired as one of his own"*, so a device that receives this
 *    frame at all sees `true`: a guest is sent no `copilot` key whatsoever.
 *    It is still carried, and still worth carrying, for the one case a client
 *    cannot otherwise learn about — a `copilot.grant` push saying `false`, which
 *    takes the copilot away without a reconnect. Capabilities travel only in the
 *    `welcome`, so without this frame a demoted device would keep a tab that
 *    refuses on every press.
 *  - `open` — **this socket** has sent `copilot.hello`. Every `copilot.*` verb
 *    needs it, including the read-tier ones. A client that reconnects has a
 *    `linked` of true and an `open` of false until it says hello again: the
 *    copilot is not something a session channel carries by existing, and that
 *    outlived the separate connection it was first written for.
 *  - `grant` — what the stream may do once open. Sent even while closed, so a
 *    device can show what it would get rather than discovering it a frame later.
 */
export interface CopilotLinkWire {
  linked: boolean
  open: boolean
  grant: CopilotGrantWire
}

/**
 * Which tier each `copilot.*` verb needs.
 *
 * A table rather than a check written at each call site, for the reason
 * `PROTOCOL_ERROR_CODES` is a runtime list: three clients have to agree with
 * this desktop about which controls to draw for a `read`-only phone, and a rule
 * that exists only as an `if` in `server.ts` is a rule they can only guess at.
 * The desktop still enforces it — this table is what it enforces *with*, so
 * there is one answer rather than an advertised one and an enforced one.
 *
 * **`copilot.say` is `act`, and that line is what makes `read` worth having.**
 * Talking to the copilot is `sessions.send` against a live agent: it spends
 * money, it causes tool calls, and it is how anything at all gets done. So
 * `read` is a *watching* grant — what is my copilot doing, what did it start,
 * what was it refused — and it carries no new power at all. That is the grant
 * worth handing out first.
 */
export const COPILOT_FRAME_TIER: Readonly<Record<string, CopilotTier>> = {
  'copilot.attach': 'read',
  'copilot.detach': 'read',
  'copilot.state': 'read',
  'copilot.sessions': 'read',
  'copilot.log': 'read',
  'copilot.pending': 'read',
  'copilot.start': 'act',
  'copilot.say': 'act',
  'copilot.cancel': 'act',
  'copilot.stop': 'act',
  /**
   * Answering a confirmation is `alter`, and it is the only frame that is.
   *
   * Not because answering *is* an alter action — it is not, it is a decision
   * about one — but because the tier is exactly the question being asked. A
   * connection that may not perform alter-tier work has no business deciding
   * whether alter-tier work happens, and letting a `read` device answer would
   * make the read tier a way to authorise everything the act tier refuses.
   *
   * The ownership rule is separate and is enforced in the broker, not here:
   * **a question may only be answered by the surface that raised it, or by the
   * desktop.** This table cannot express that, because it is about verbs and
   * that rule is about one particular question — see `deck-control/consent.ts`.
   */
  'copilot.answer': 'alter',
}

/**
 * The three frames that are **not** in the tier table, and why.
 *
 * `copilot.connect`, `copilot.hello` and `copilot.bye` are the authorisation
 * ceremony itself. Gating them on a tier would be circular: a device with no
 * copilot connection has no tiers, so requiring one to send the frame that
 * establishes the connection would mean no device could ever connect.
 *
 * They are listed here rather than left implicit so that a reader checking
 * "which verbs skip the tier check" gets an answer from the code instead of
 * inferring one from an absence. `server.ts` handles each of them explicitly and
 * `copilot-frames.test.ts` asserts that the two lists together cover every
 * `copilot.*` client verb — so a verb added without deciding which list it
 * belongs in fails the suite rather than falling through to a handler.
 */
export const COPILOT_UNTIERED_FRAMES: readonly string[] = ['copilot.hello', 'copilot.bye']

/**
 * Largest `copilot.say`, in UTF-8 bytes.
 *
 * The same number as {@link MAX_INPUT_BYTES}, deliberately: this *is* a paste
 * into a terminal by the time it lands, so a second, larger number here would
 * be a way to type more into a session through the copilot than through the
 * keyboard the phone already has.
 */
export const MAX_COPILOT_SAY_BYTES = MAX_INPUT_BYTES

/**
 * How many action-log rows one `copilot.log` may ask for.
 *
 * The desktop's own Activity pane allows 2000, and that is a pane rather than a
 * relay: it reads a local file into a local list. Two hundred rows is more than
 * a phone screen can show and small enough that a client in a loop cannot make
 * this Mac serialise megabytes of somebody's audit log onto a sealed channel.
 */
export const MAX_COPILOT_LOG_ROWS = 200

/**
 * Longest chat bubble, in characters, before it is cut.
 *
 * **Cut with a flag, never chunked.** `TranscriptMessage.truncated` sets the
 * precedent and the argument is the same: a chat bubble is read, not scrolled,
 * and a 400 KB agent answer split across fifty bubbles is not the conversation
 * it is a transcript of a conversation. The flag is what keeps it honest — a
 * client shows that there is more and offers the desktop, which has the file.
 */
export const MAX_COPILOT_MESSAGE_CHARS = 8 * 1024

/** One bubble of a copilot conversation. Parsed text, never terminal bytes. */
export interface CopilotChatMessage {
  /** Stable across reads, so an extended message replaces rather than duplicates. */
  id: string
  role: 'you' | 'agent'
  text: string
  /** Epoch ms of the line that started it, or 0 when the line carried no date. */
  at: number
  /** True when `text` was cut to {@link MAX_COPILOT_MESSAGE_CHARS}. */
  truncated?: true
}

/**
 * What the copilot is, as a phone draws it.
 *
 * Two different things are running and the frame says so separately, because
 * conflating them is the one thing this screen can get wrong that a person
 * would act on. `desk` is the copilot pinned in the sidebar on the Mac — the
 * conversation the person is having. `run` is *this device's own* run, which is
 * the only thing the phone can talk to. A phone that showed the desk's state on
 * its own Start button would offer to start something that is already running,
 * or refuse to because something unrelated is.
 */
export interface CopilotStateReport {
  /** The copilot at the desk: is it up. Watching this is the whole `read` tier. */
  desk: 'stopped' | 'starting' | 'running'
  /** This device's own run: its id, or null when it has none. */
  run: string | null
  /** The account the copilot runs as, by name. Never a credential. */
  profile: string | null
  /** True, false, or null when it has not been asked. */
  signedIn: boolean | null
  /** How many tools the copilot has, and what they cost it every turn. */
  tools: number
  turnTokens: number
  /** Confirmations waiting **at the desk**. Watch-only; see `copilot.pending`. */
  pending: number
  /** This device's grant, repeated here so one frame can answer "what may I do". */
  grant: CopilotGrantWire
  /**
   * Could a run start at all — is there a Claude CLI, is it signed in, is the
   * folder writable. False with a `reason` beats a Start button that fails.
   */
  available: boolean
  reason: string | null
}

/** A session the copilot started, as a phone lists it. */
export interface CopilotSessionRow {
  id: string
  title: string
  cwd: string
  provider: string
  status: string
  startedAt: number
  /** The action-log row that started it, so the phone can link the two. */
  originRunId: string | null
}

/**
 * One row of `actions.jsonl`, trimmed for the wire.
 *
 * Rebuilt field by field in `server.ts` rather than passed through, for exactly
 * the reason `DevServerReport` is: `ActionRow` is the desktop's own type and
 * this is a contract with three clients, so a field added there reaches a phone
 * only when somebody writes a line. The arguments are **not** here at all —
 * they are scrubbed before the row is written, and even scrubbed they are the
 * text of what was typed into somebody's sessions.
 */
export interface CopilotActionRow {
  id: string
  /** ISO 8601, as the log writes it. */
  at: string
  /** Canonical dotted tool id. */
  tool: string
  tier: string
  outcome: 'ok' | 'refused' | 'error'
  /** The one line the Activity pane shows. Written by the desktop. */
  detail: string
  /** Why it was refused, when it was. Null otherwise. */
  refusal: string | null
  /** Which device caused it, when a device did. Null for the person at the Mac. */
  deviceId: string | null
}

/**
 * A confirmation that is waiting, as a device *watches* it.
 *
 * This row used to carry no `mine` and the type said, in those words, that
 * there must never be an Allow or a Refuse on it. That was true while copilot
 * access was a box ticked beside a paired phone; it is not true now that a
 * copilot connection is its own authorisation. See {@link CopilotLinkWire} and
 * `COPILOT-REMOTE.md` §4.
 *
 * What survives unchanged is the *watching* half, and it is still most of the
 * value: the failure the design named is a desktop dialog on a screen nobody is
 * looking at, timing out in silence two minutes later. A device sees every
 * question, including ones it may not answer, so it can say *go and look*.
 *
 * There is deliberately no `args` here. Watching a question is not judging it,
 * and the arguments of a pending alter call are the most sensitive thing on this
 * surface — a settings key and its new value, a session id and the text about to
 * be typed into it. A device that *can* answer gets them, in full, on
 * {@link CopilotConsentQuestion}; a device that cannot has no decision to make
 * with them.
 */
export interface CopilotPendingRow {
  id: string
  tool: string
  summary: string
  requestedAt: number
  /** When it refuses itself, so the device counts down exactly as the dialog does. */
  expiresAt: number
  /**
   * May **this** connection answer it?
   *
   * Computed per device on this desktop, never inferred by the client, and it is
   * the wire half of the rule §4.2 flags as non-obvious: *a question may only be
   * answered by the surface that owns the run that raised it, or by the desktop.*
   * Otherwise device A approves device B's action, which is a permission model
   * with a shared password.
   *
   * A client must still send `copilot.answer` and be refused rather than trusting
   * this — it is drawn from a snapshot and the desktop is the boundary — but a
   * client that drew an Allow button on somebody else's question would be
   * offering a control that is always refused.
   */
  mine: boolean
}

/**
 * A confirmation this connection may answer, with everything needed to judge it.
 *
 * ## Why this is a different type from {@link CopilotPendingRow}
 *
 * Because the two answer different questions and one of them is dangerous to get
 * wrong. A pending row says *something needs attention*; this says *decide*. A
 * consent prompt without enough context becomes a reflex Yes, and a gate that is
 * always answered yes is worse than no gate at all, because it looks like
 * protection. So this carries what a person actually needs:
 *
 *  - **what** — the tool, by its canonical dotted id, and the desktop's own
 *    one-line summary. Composed by the tool that is about to run, never
 *    re-composed on the client: a client that wrote its own sentence would be
 *    describing an action it did not implement.
 *  - **who** — which run raised it. `origin` is `'window'` for the copilot at
 *    the desk and `device:<id>` for a connection's own run, so *my phone's
 *    copilot asked for this* and *the Mac's copilot asked for this* never read
 *    the same.
 *  - **with what arguments** — `args`, verbatim, already through `scrubArgs`.
 *    Every one of them, in the order the tool declares them. This is the field
 *    that turns a prompt from a shape into a decision, and it is why the type
 *    exists separately from the watch-only row.
 *  - **what happens if you say nothing** — `expiresAt`. It expires into a
 *    *refusal*, so a person who walks away has decided rather than deferred, and
 *    the countdown has to be in front of them.
 */
export interface CopilotConsentQuestion {
  id: string
  tool: string
  /** Always `alter` today. Carried so a client renders the stakes rather than assuming them. */
  tier: string
  summary: string
  /** Scrubbed arguments, verbatim, in the tool's own order. */
  args: Record<string, unknown>
  /** `'window'`, or `device:<id>` for the connection whose run raised it. */
  origin: string
  requestedAt: number
  expiresAt: number
}

/**
 * A question closed, and **where** it was answered.
 *
 * Pushed to every connection that could see the question, including the one that
 * answered it. The `by` field is the whole reason this frame is not just a
 * dismissal: first answer wins, and the surface that loses the race has to
 * withdraw its dialog *saying where it went* rather than having it vanish. A
 * dialog that disappears on its own teaches a person that the app does things
 * behind their back.
 */
export interface CopilotSettledRow {
  id: string
  granted: boolean
  /** `'window'`, `device:<id>`, or null when nobody answered — a timeout. */
  by: string | null
  /** The refusal reason when it was refused. Null when it was allowed. */
  reason: string | null
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
  /* ---- capability `close`. Refused when it is not advertised. ------------- */
  /**
   * End the session named by `id`. The process is killed; it does not come back.
   *
   * ## Not `detach`, and the difference is the whole frame
   *
   * `detach` is about this connection: stop sending me this session's bytes. It
   * has existed since v1 and it is what closing a screen on a phone does. This
   * ends the **process**, for everyone — the tab in the desktop's own window
   * goes, every other attached device gets an `exit`, and the agent's work stops
   * wherever it had got to. That is not undoable, which is why both clients ask
   * before sending it and why a client that cannot ask should not send it.
   *
   * ## One field, and the two that are deliberately absent
   *
   * There is **no signal and no force flag**. A client that could name `SIGKILL`
   * against `SIGTERM` would be a client choosing how somebody else's editor
   * exits, and neither answer is a phone's to give; the desktop ends a session
   * exactly as its own ✕ does, which is one behaviour rather than two that can
   * drift. And there is **no reason string**: it would be attacker-chosen text
   * about to be printed in the desktop's own chrome, for nothing.
   *
   * ## What authorises it
   *
   * The same door as `attach`, asked again here. This is a *fourth* door onto a
   * running session — `list`, `attach` and `create` are the other three — and it
   * is the one that opens onto somebody else's work, so a device that may not
   * see a session may not end it and is told the sentence an unknown id gets.
   * See `server.ts`, where the refusal is written, and `guest-close.test.ts`,
   * which pins it against a real socket.
   */
  | { t: 'close'; id: string }
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
  /* ---- capability `web`. Refused outright when it is not advertised. ------ */
  /**
   * Open this page **on the machine**, in its own browser.
   *
   * ## Why this exists at all
   *
   * A browser tab cannot listen on a socket. `pwa/src/localhost.ts` opens by
   * rejecting three ways around that and concludes, correctly, that the web
   * client can say which ports are open and whether one answers and cannot serve
   * through them. What it left is the complaint:
   *
   *   > *"Localhost lists ports with no way to open any of them. The whole
   *   > reason localhost exists is to drive them."*
   *
   * Both statements are true at once, and the way out is not to make a tab do
   * something no tab can do. It is the thing he asked for on the phone in the
   * same review:
   *
   *   > *"A browser started from the phone must run on the machine you are
   *   > inside — a live link or a localhost link both open on the connected
   *   > machine."*
   *
   * So the page opens **there**, in a tab of that machine's own browser, and the
   * device that asked is driving rather than viewing. That is a smaller promise
   * than a tunnel and it is a real one, and it is the only one this transport can
   * keep honestly.
   *
   * ## What is checked, and where
   *
   * `url` is a string off a network and nothing here has looked at it. Two
   * checks happen in `server.ts` before anything is opened, and both matter:
   * the URL must be http(s) — `canOpenOutside` is the same gate the app's own
   * links go through, so a `file:` or a `javascript:` cannot walk a window onto
   * somebody's disk — and the device must be one of the owner's own. A guest is
   * refused, for the same reason a guest is never offered the copilot: this
   * opens a page on a screen that is not theirs, and no folder grant says
   * anything about that.
   */
  | { t: 'web.open'; url: string }
  /* ---- capability `devserver`. Refused when it is not advertised. --------- */
  /**
   * What is this project's dev server doing?
   *
   * `folder` is a folder the *client* named and nothing has checked yet — the
   * same rule and the same wording as `create.cwd`, because it is the same
   * question with the same answer. The desktop accepts only a folder it is
   * already offering **this device** in `welcome.folders`, so the value has an
   * honest source on the phone (a row that is on screen) and naming it grants
   * nothing the device could not already do.
   *
   * The check happens *before* anything on disk is touched, and that ordering is
   * the point rather than a detail: this verb's answer is derived from a
   * `package.json`, so a desktop that read the file first and authorised second
   * would be a way for a paired phone to ask whether an arbitrary path on
   * somebody's machine is a Node project and what its scripts are called.
   */
  | { t: 'dev.status'; folder: string }
  /**
   * Start it. **This message is the consent, and there is no standing one.**
   *
   * Nothing runs on the desktop because of this feature until one of these
   * arrives, and one only arrives because a person tapped a row for a folder
   * their desktop has granted them. There is no configured list of auto-start
   * projects to get wrong and nothing to revoke: removing the folder from that
   * device's grants is the whole of the revocation, and it takes effect on the
   * next message rather than on the next reconnect.
   *
   * The command is not on the wire and cannot be. The desktop reads the folder's
   * own `package.json` and runs the script it declares; a client that could name
   * a command would be a client that could run one.
   *
   * Answered with `dev.state`, immediately, carrying `starting` — not held open
   * until the server is up. A dev server takes seconds to tens of seconds and
   * the client needs something to draw for all of them.
   */
  | { t: 'dev.start'; folder: string }
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
  /* ---- capability `copilot`. Refused per-tier, per device. ---------------- */
  /**
   * ## The rule that makes this whole surface safe: **no tool name is on the wire**
   *
   * There is no `copilot.tool`, no `copilot.run`, no argument object and no tool
   * id in any frame below. A phone sends *prose*. Tool calls are made by a Claude
   * CLI process on the desktop, over loopback, authenticated by a bearer token it
   * holds and the phone does not.
   *
   * This is the strongest available form of *"a device that was not granted
   * `alter` must not be able to reach an alter tool by any frame it can
   * construct"*, because the set of frames it can construct contains no tool at
   * all. Every other shape of this feature has to enumerate tools and deny them;
   * this one has nothing to enumerate. `copilot-frames.test.ts` pins it as a
   * property of the source text, the same way `wire-wording.test.ts` pins the
   * refusal vocabulary — a type union cannot express "and no future variant
   * either".
   *
   * It is also the rule that will be under pressure. The first person who wants
   * `copilot.tool` for a nicer phone UI — *tap to re-run that* — should be sent
   * here, because that one frame gives back everything the design bought.
   */
  /**
   * Open this socket's copilot stream.
   *
   * Answered with `copilot.grant` carrying `open: true`. Required after every
   * reconnect: a session channel does not carry the copilot by existing.
   *
   * **It carries nothing.** There was a `copilot.connect` above this until
   * 2026-08-19 — redeem a six-digit copilot code, receive a credential — and
   * this frame used to present that credential on every socket. Both are gone.
   * The second factor is *having been paired as one of his own devices*, which
   * is decided at the machine, cannot be changed without pairing again, and is
   * what makes it honest for a device to hold `alter` and answer its own
   * confirmations. See `remote/copilot-access.ts` for that argument and for the
   * one it superseded.
   */
  | { t: 'copilot.hello' }
  /**
   * Close the copilot connection on this socket, and keep the terminals.
   *
   * Not a disconnect: the credential and the record survive, so the next
   * `copilot.hello` works. It is what a client sends when a person leaves the
   * Copilot tab on a device they share.
   */
  | { t: 'copilot.bye' }
  /**
   * Answer a confirmation.
   *
   * `alter`, and refused unless this connection owns the run that raised the
   * question — see {@link COPILOT_FRAME_TIER} and `deck-control/consent.ts`.
   * First answer wins; the loser is told where it was answered rather than
   * having its dialog vanish.
   *
   * `approved` is a required boolean and nothing else is read as yes. A client
   * whose wiring sent `undefined` must not approve somebody's settings being
   * rewritten — the same rule `deck-control:consent-respond` keeps one process
   * in.
   */
  | { t: 'copilot.answer'; id: string; approved: boolean }
  /**
   * Watch this device's copilot surface, and replay what exists.
   *
   * Starts nothing and spends nothing, which is why it is `read`. Answered with
   * `copilot.state`, then — if this device already has a run — a `copilot.chat`
   * carrying `reset: true`.
   */
  | { t: 'copilot.attach' }
  /**
   * Stop the stream. **The run keeps going**, for a grace window, and that is
   * deliberate: a phone that locks its screen in a lift has not asked for its
   * agent to be killed mid-turn. See `copilot-runs.ts` for the window.
   */
  | { t: 'copilot.detach' }
  | { t: 'copilot.state' }
  /** The sessions the copilot started, each linked back to the turn that made it. */
  | { t: 'copilot.sessions' }
  /**
   * The tail of `actions.jsonl`, newest last.
   *
   * `before` pages backwards by row id rather than by index, because the file is
   * appended to while somebody is reading it and an index-based page would skip
   * or repeat rows exactly when the copilot is busiest.
   */
  | { t: 'copilot.log'; limit?: number; before?: string }
  /** Confirmations waiting at the desk. Watch-only — see {@link CopilotPendingRow}. */
  | { t: 'copilot.pending' }
  /**
   * Start this device's own run.
   *
   * Deliberately not folded into `attach`: it spawns an agent process and that
   * spends money, so it is a thing a person taps rather than a side effect of
   * opening a tab. A second one against a live run is answered with the run that
   * already exists rather than a second process.
   */
  | { t: 'copilot.start' }
  /** Say something to it. `act`, because talking to an agent *is* acting. */
  | { t: 'copilot.say'; text: string }
  /** Interrupt the current turn of **this device's own run**, and nothing else. */
  | { t: 'copilot.cancel' }
  /** End this device's own run. */
  | { t: 'copilot.stop' }

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
      /**
       * This device's copilot connection. **Absent means this host has none.**
       *
       * Carried per-device, beside the host-wide `capabilities`, for the reason
       * `folders` is and `CAPABILITY.copilot` restates: one says what this
       * machine can do, the other says what *you* may do, and a client that
       * reads the first as the second draws a control that is always refused.
       *
       * `open` is always false here, on every `welcome`, and that is not a
       * placeholder — it is the shape of the feature. A session channel does not
       * carry the copilot by existing; the client sends `copilot.hello` with its
       * stored credential and gets `copilot.grant` back with `open: true`. A
       * desktop older than this field sends nothing at all.
       */
      copilot?: CopilotLinkWire
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
  /* ---- capability `close` ------------------------------------------------- */
  /**
   * That session is gone, because this device asked.
   *
   * Sent only to the connection that asked, and only once the session layer has
   * actually ended it — never on the request being received. A client draws its
   * row away on this frame rather than optimistically on the tap, which is the
   * difference between a list that reflects the machine and one that reflects
   * what somebody pressed.
   *
   * Everybody else finds out the way they always have. A device attached to it
   * gets `exit` from the pty ending, and every other connection gets an ordinary
   * `sessions` refresh — both v1 frames, so a client that has never heard of
   * this capability still sees the session disappear. That is the same additive
   * rule `created` follows, in the same shape: the frame that names *your* action
   * is the new one, and the frames that describe the machine are the old ones.
   *
   * A refusal is a plain `error`. There is no `close.failed`, for the reason
   * `web.opened` gives about its own: the two ways this fails — the host cannot
   * close sessions, or this device may not touch that one — are both things
   * `error` already says with a code and a sentence.
   */
  | { t: 'closed'; id: string }
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
  /**
   * The page is open on the machine.
   *
   * Sent only when a tab was actually made, never on the request being received,
   * so the sentence the client draws is about something that happened. A refusal
   * is an ordinary `error` — there is no `web.failed`, because the three ways
   * this can fail (not advertised, not your machine, not a URL it will open) are
   * all things `error` already says with a code and a sentence.
   */
  | { t: 'web.opened'; url: string }
  /* ---- capability `devserver` -------------------------------------------- */
  /**
   * One project's dev server, now.
   *
   * The single frame for the whole capability: it answers `dev.status`, it
   * answers `dev.start`, and it arrives **unsolicited** every time the state
   * changes after a start — a new progress line, the moment a port accepts, a
   * timeout. One frame rather than three because to a client they are one event:
   * this row now says something different.
   *
   * Pushed rather than polled, and only to the connections that have asked about
   * that folder in this session. A client therefore does not need a timer: send
   * `dev.start`, draw whatever comes back, and keep drawing whatever arrives
   * next. There is no "are we there yet" verb and adding one would be a client
   * asking a question the desktop is already answering.
   *
   * **Handle it idempotently: the same state can arrive twice.** A `dev.start`
   * gets the state as its direct answer *and* as a push, because the direct
   * answer is what makes the state reach a client whose request changed nothing
   * (a folder already `ready`, or one with no dev script), while the push is what
   * makes every *later* change arrive. Deduplicating the overlap would mean the
   * desktop guessing which of the two a given client had already acted on.
   * Replace the row keyed by `folder` and the duplicate costs nothing.
   *
   * **Replace, do not merge.** The fields are not independent — `port` and `url`
   * exist only on `ready`, `message` only on `failed` — so folding a new state
   * into an old one leaves a dead address under a live row. That is the one
   * genuinely wrong thing a client of this frame can display.
   *
   * A refusal — a folder this device was not granted, a host that cannot start
   * sessions — comes back as a plain `error` with `unauthorized`, not as a
   * `dev.state`, because there is no folder state to report about a folder the
   * desktop will not discuss.
   */
  | { t: 'dev.state'; state: DevServerReport }
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
  /* ---- capability `copilot` ---------------------------------------------- */
  /** Answer to `copilot.state`, and pushed whenever any of it changes. */
  | { t: 'copilot.state'; state: CopilotStateReport }
  /**
   * The conversation, as **parsed messages** and never as terminal bytes.
   *
   * Merge by `id`: replace a match, append otherwise. `reset` means drop
   * everything held and take this frame as the whole conversation — which is
   * what arrives on a fresh attach and when a run is replaced.
   *
   * `run` rides along so a frame from a previous run is *dropped* rather than
   * merged into the new one. Without it a phone that reconnected after the grace
   * window expired would splice the end of a dead conversation onto the start of
   * a live one, and the person would read an answer to a question they never
   * asked in this run.
   *
   * Produced by the same parser the desktop's own chat view uses —
   * `chat-transcript.ts` — because one parser is one truth. A phone that had its
   * own would be a second reading of the same file, and the two would disagree
   * about a compaction replay within a week.
   */
  | { t: 'copilot.chat'; run: string; messages: CopilotChatMessage[]; reset?: true }
  /**
   * One tool call as it happens, already scrubbed.
   *
   * This is *"see what it is doing"*, and it is the frame that makes a refusal
   * visible: a call this device's grant did not cover arrives here with
   * `outcome: 'refused'` and `refusal: 'not-granted'`, in the copilot's own
   * words rather than as silence. A gate that denies invisibly is
   * indistinguishable from a gate that was never reached.
   */
  | { t: 'copilot.tool'; row: CopilotActionRow }
  | { t: 'copilot.sessions'; sessions: CopilotSessionRow[] }
  /**
   * Answer to `copilot.log` only, never pushed — the live view of the log is
   * `copilot.tool`. `more` says the tail was bounded, in the same spirit
   * `ToolTrail.partial` reports its own window rather than pretending to be the
   * whole file.
   */
  | { t: 'copilot.log'; rows: CopilotActionRow[]; more: boolean }
  | { t: 'copilot.pending'; questions: CopilotPendingRow[] }
  /**
   * This connection's copilot state changed: opened, closed, regranted, or
   * disconnected entirely.
   *
   * Pushed, so a disconnected device's Copilot tab goes away without a
   * reconnect. The *rule* is already live without this frame, because the grant
   * is read per message and per tool call — which is exactly what makes this
   * push honest rather than load-bearing. Same argument, same shape, as
   * `folders`.
   */
  | { t: 'copilot.grant'; link: CopilotLinkWire }
  /**
   * A confirmation this connection may answer. Pushed the moment it is raised.
   *
   * Only ever sent to the surface that owns the run that raised it. Everybody
   * else who is watching sees it as a `copilot.pending` row with `mine: false`,
   * which is a notification and not a decision.
   */
  | { t: 'copilot.ask'; question: CopilotConsentQuestion }
  /**
   * A confirmation closed, and where it was answered.
   *
   * Pushed to every connection that was told about it, including the one that
   * answered. See {@link CopilotSettledRow}: a dialog that vanishes without
   * saying where the answer came from is the app doing something behind a
   * person's back.
   */
  | { t: 'copilot.settled'; settled: CopilotSettledRow }

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
 * A project folder a client named, checked exactly the way `create.cwd` is.
 *
 * One function for the two `dev.*` verbs rather than the checks written out
 * twice, because they are the same value with the same fate: compared against
 * the folder list this desktop granted the device, and then handed to something
 * that opens a directory. The three rules are `create.cwd`'s and the reasons are
 * `create.cwd`'s — a control byte is **refused** rather than stripped, since
 * stripping turns a hostile value into a *different* legal-looking path, which
 * is the worse failure.
 *
 * Two ways of failing, distinguished, because the caller answers them
 * differently: a path over the cap is `too-large`, which is the code that says
 * "your message was too big" rather than "your message was wrong".
 */
type FolderCheck = { ok: true; folder: string } | { ok: false; tooLarge: boolean }

function devFolder(value: unknown): FolderCheck {
  if (typeof value !== 'string' || value === '') return { ok: false, tooLarge: false }
  if (overBytes(value, MAX_CWD_BYTES)) return { ok: false, tooLarge: true }
  if (CONTROL_CHARS.test(value)) return { ok: false, tooLarge: false }
  return { ok: true, folder: value }
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

    /* ---- capability `close` --------------------------------------------- */
    // An id and nothing else. Whether it names a live session, and whether this
    // device may end it, are the server's questions — the same split every verb
    // in this file follows, and here the second half is the load-bearing one.
    case 'close': {
      const sessionId = id(parsed.id)
      return sessionId
        ? { ok: true, message: { t: 'close', id: sessionId } }
        : bad('close without a session id')
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
    /* ---- capability `web` ------------------------------------------------ */
    // Length-capped and nothing more. Whether the scheme is one this machine
    // will open, and whether this device may ask, are the server's questions —
    // the same split every other verb here follows.
    case 'web.open': {
      const url = asString(parsed.url)
      if (url === null || url === '' || url.length > MAX_URL_LENGTH) {
        return bad('web.open without a usable url')
      }
      return { ok: true, message: { t: 'web.open', url } }
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

    /* ---- capability `devserver` ----------------------------------------- */
    // Shape only, and authorised nowhere near here. Whether this desktop offers
    // the capability at all, and whether this device may see or start anything
    // in the folder named, are the server's questions — it is the only thing
    // that knows which device the socket belongs to. See the header.
    case 'dev.status':
    case 'dev.start': {
      // Read once into a local, for the reason spelled out on `input.data`: on
      // the object path a property can be a getter, and the string that is
      // measured has to be the string that is forwarded.
      const verb = parsed.t
      const checked = devFolder(parsed.folder)
      if (!checked.ok) {
        return checked.tooLarge
          ? tooLarge(`${verb} with a folder over the path limit`)
          : bad(`${verb} with an unusable folder`)
      }
      return { ok: true, message: { t: verb, folder: checked.folder } }
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

    /* ---- capability `copilot` ------------------------------------------- */
    /*
     * Shape only, and authorised nowhere near here — the same division every
     * other capability keeps. Whether this desktop has a copilot at all, and
     * *which tier this device holds*, are the server's questions: it is the only
     * thing that knows which device the socket belongs to, and the grant is read
     * per message rather than at hello so that unticking a box in Settings lands
     * on the next frame instead of the next reconnect.
     *
     * Six of these carry no fields whatsoever, which is not laziness — it is the
     * property described on the `ClientMessage` variants: a phone names no tool,
     * no session, no path and no argument object, so there is nothing here for a
     * parser to be careless with. The only two with a payload are `say`, which is
     * prose, and `log`, which is a count and a row id.
     */
    case 'copilot.attach':
    case 'copilot.detach':
    case 'copilot.state':
    case 'copilot.sessions':
    case 'copilot.pending':
    case 'copilot.start':
    case 'copilot.cancel':
    case 'copilot.stop':
    case 'copilot.bye':
      // Listed one by one rather than caught by a prefix test, so that adding a
      // verb to this capability without deciding what it carries stops the build
      // instead of silently arriving as a bare frame.
      return { ok: true, message: { t: parsed.t } }
    /*
     * A bare frame, and an older client's `credential` field is ignored rather
     * than refused.
     *
     * There is nothing to carry: the socket is already authenticated as this
     * device and a person at the machine already decided whether it is one of
     * their own. Ignoring an extra field rather than rejecting it is deliberate
     * — a phone built against the previous protocol still sends one, and its
     * copilot should simply start working rather than fail with a sentence
     * about a credential nobody can produce any more.
     */
    case 'copilot.hello':
      return { ok: true, message: { t: 'copilot.hello' } }
    case 'copilot.answer': {
      const answerId = id(parsed.id)
      // A consent id is a `randomUUID` from `consent.ts`. Checked here so the
      // refusal says "that is not a question id" rather than surfacing as an
      // answer that quietly did nothing.
      if (!answerId) return bad('copilot.answer without a question id')
      /*
       * A required boolean, and **only a literal `true` is yes**.
       *
       * The same rule `deck-control:consent-respond` keeps inside the process,
       * for the same reason and with more at stake: this frame decides whether
       * an alter-tier action happens, and a client whose wiring sent `undefined`
       * or `"true"` must not have that read as approval. Refused rather than
       * coerced — a malformed answer is a client bug, and answering it as "no"
       * would hide the bug behind a plausible outcome.
       */
      const approved = parsed.approved
      if (typeof approved !== 'boolean') return bad('copilot.answer without a decision')
      return { ok: true, message: { t: 'copilot.answer', id: answerId, approved } }
    }
    case 'copilot.say': {
      // Read once, for the reason spelled out on `input.data`: on the object
      // path a property can be a getter, and the string that is measured has to
      // be the string that is forwarded. This value ends up typed into a live
      // agent's pty, which is the same destination `input.data` has.
      const text = parsed.text
      if (typeof text !== 'string' || text === '') return bad('copilot.say without text')
      // Bytes, not characters. One emoji is four of them and the cap is about
      // what gets written into a terminal.
      if (overBytes(text, MAX_COPILOT_SAY_BYTES)) {
        return tooLarge('copilot.say larger than the message limit')
      }
      // Control bytes are **refused**, not stripped, and this is the security
      // check in this branch rather than a tidiness one. The text is written
      // into a pty holding a Claude CLI: a carriage return inside it would
      // submit early and turn the rest of the message into a *second* prompt,
      // and an escape sequence would drive the CLI's own key handling. Stripping
      // would turn a hostile value into a different, legal-looking message —
      // the argument `create.cwd` makes, and it matters more here because the
      // result is a turn somebody pays for. The submitting newline is added by
      // the desktop, once, so one frame is at most one prompt.
      if (CONTROL_CHARS.test(text)) return bad('copilot.say with an unusable message')
      return { ok: true, message: { t: 'copilot.say', text } }
    }
    case 'copilot.log': {
      const message: Extract<ClientMessage, { t: 'copilot.log' }> = { t: 'copilot.log' }
      const rawLimit = parsed.limit
      if (rawLimit !== undefined) {
        const limit = whole(rawLimit, 1, MAX_COPILOT_LOG_ROWS)
        // Refused rather than clamped. A client asking for a thousand rows has
        // misunderstood the cap, and silently answering with two hundred while
        // it believes it has the whole log is how a phone draws "that is
        // everything the copilot did today" over a window.
        if (limit === null) return bad('copilot.log with a limit out of range')
        message.limit = limit
      }
      const rawBefore = parsed.before
      if (rawBefore !== undefined) {
        // A row id, which is a `randomUUID` from `control.ts`. `ID_RE` is the
        // right shape for it and it is compared against ids this process wrote,
        // so anything else can only be a miss — checked here so the refusal
        // says "that is not a row id" rather than surfacing as an empty page.
        const before = id(rawBefore)
        if (!before) return bad('copilot.log with an unusable cursor')
        message.before = before
      }
      return { ok: true, message }
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

/**
 * One row of a `ports` frame, or null.
 *
 * `guessed` is the far machine's own word for "I could not name the process
 * holding this", and it is read as a strict `true` rather than as anything
 * truthy: the difference between "node" and "something is on 3000" is the whole
 * of what that flag says, and a client that guessed at it would be inventing a
 * process name for a port nobody could identify.
 */
function parsePort(value: unknown): LocalPort | null {
  if (!isRecord(value)) return null
  const port = whole(value.port, 1, 65535)
  const process = asString(value.process)
  if (port === null || process === null) return null
  return { port, process, guessed: value.guessed === true }
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
    case 'closed': {
      // The id is the whole frame, so a nameless one is refused rather than read
      // as "something closed": a client that took it would have to guess which
      // row to remove, and the only available guess is the one the person was
      // last looking at.
      const id = asString(parsed.id)
      return id === null || id === ''
        ? { ok: false, reason: 'closed without an id' }
        : { ok: true, message: { t: 'closed', id } }
    }
    /*
     * Every localhost frame is read here now, and the last two rungs of that
     * arrived on 2026-08-18. It is worth recording why in order, because the
     * absence of these branches used to be a deliberate statement and is not any
     * more.
     *
     * This parser exists for the **desktop acting as another desktop's guest**.
     * `pwa/src/protocol-client.ts` argued that the localhost frames belonged to
     * the phone's client rather than here *"until the day the guest also
     * tunnels"*, and named the exact condition: `net.*` carries a byte stream
     * into a **listening socket**, and a desktop guest opened none.
     *
     * It does now. `src/main/localhost-reach.ts` binds a loopback listener on
     * this machine for a port on another one, so that the in-app browser can
     * open a remote dev server as an ordinary URL — his review of 2026-08-18,
     * *"shape of the application should not be changing for local and remote
     * devices"*. That listener is the missing half the older comment named, so
     * the seven branches are one set again and the split that survives is the
     * honest one: shape is checked here, and **who may ask** is checked by the
     * server, which is the rule every verb in this file follows.
     */
    case 'ports': {
      const rows = parsed.ports
      // A frame with no list at all is refused rather than read as "nothing is
      // listening" — the same argument `folders` makes. An idle machine and a
      // malformed message are different facts and a screen says different
      // things about them.
      if (!Array.isArray(rows)) return { ok: false, reason: 'ports without a list' }
      const ports: LocalPort[] = []
      for (const row of rows) {
        // One bad row does not discard the list, for the reason `sessionRows`
        // does not: a panel showing nine of ten ports is useful and one showing
        // none because the tenth had a null process name is not.
        const port = parsePort(row)
        if (port !== null) ports.push(port)
      }
      return { ok: true, message: { t: 'ports', ports } }
    }
    case 'tunnel.opened': {
      // Both fields, or nothing. The id names which pending open this answers
      // and the port is what the far machine believes it opened; a frame missing
      // either would leave a click waiting for an answer that has already come.
      const tunnelId = id(parsed.id)
      const port = portNumber(parsed.port)
      return tunnelId === null || port === null
        ? { ok: false, reason: 'incomplete tunnel.opened' }
        : { ok: true, message: { t: 'tunnel.opened', id: tunnelId, port } }
    }
    case 'tunnel.closed': {
      const tunnelId = id(parsed.id)
      if (tunnelId === null) return { ok: false, reason: 'tunnel.closed without an id' }
      // The sentence is the payload — it is the other machine explaining a
      // refusal in words somebody reads — but an absent one is not a broken
      // frame, so it becomes the empty string and this end supplies its own.
      // Uncapped for the same reason `error` below is: the whole frame is
      // already bounded by the message cap the socket enforces.
      return { ok: true, message: { t: 'tunnel.closed', id: tunnelId, message: asString(parsed.message) ?? '' } }
    }
    case 'net.data': {
      // The same three checks the client parser makes on the way in, in the same
      // order, because this is the same frame travelling the other way: a
      // channel it can be matched to, a chunk inside the cap, and base64 that is
      // really base64. `Buffer.from(x, 'base64')` never throws — it silently
      // skips what it does not recognise — so an unchecked frame becomes a
      // *shorter* body written into a browser's socket, which reads as the dev
      // server having truncated its own response.
      const channel = id(parsed.ch)
      if (channel === null) return { ok: false, reason: 'net.data without a channel id' }
      const data = parsed.data
      if (typeof data !== 'string') return { ok: false, reason: 'net.data without data' }
      if (data.length > MAX_NET_DATA_CHARS) return { ok: false, reason: 'net.data over the chunk limit' }
      if (!BASE64_RE.test(data) || data.length % 4 !== 0) return { ok: false, reason: 'net.data is not base64' }
      return { ok: true, message: { t: 'net.data', ch: channel, data } }
    }
    case 'net.ack': {
      const channel = id(parsed.ch)
      if (channel === null) return { ok: false, reason: 'net.ack without a channel id' }
      // Range-checked against the window it is an acknowledgement for. A number
      // larger than the window could only ever un-pause a stream that should
      // stay paused, which is the one thing flow control exists to prevent.
      const bytes = whole(parsed.bytes, 1, NET_WINDOW_BYTES)
      return bytes === null
        ? { ok: false, reason: 'net.ack out of range' }
        : { ok: true, message: { t: 'net.ack', ch: channel, bytes } }
    }
    case 'net.close': {
      const channel = id(parsed.ch)
      return channel === null
        ? { ok: false, reason: 'net.close without a channel id' }
        : { ok: true, message: { t: 'net.close', ch: channel } }
    }
    case 'web.opened': {
      // The URL is the whole payload: it is what the confirmation names, and the
      // far machine echoes what it *actually* opened rather than what was asked
      // for, because a redirect or a normalisation there is the truth and this
      // end's copy is not.
      const url = asString(parsed.url)
      return url === null || url === ''
        ? { ok: false, reason: 'web.opened without a url' }
        : { ok: true, message: { t: 'web.opened', url } }
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
