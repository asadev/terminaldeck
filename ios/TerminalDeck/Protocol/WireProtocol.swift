/**
 * The wire language, as this client sees it.
 *
 * A faithful port of `src/main/remote/protocol.ts` — the desktop's own module.
 * The PWA imports that file directly across a directory boundary precisely so
 * there is no second copy to drift; Swift has no such option, so this file is
 * the copy, and the rule that comes with it is that it changes only when
 * `protocol.ts` changes, in the same commit, with the same values.
 *
 * What is *not* ported is the parsing in `parseClientMessage`. That is the
 * server's half of the conversation — it narrows what a phone sends before it
 * reaches a PTY. This end needs the mirror image: `WireCodec` narrows what the
 * desktop sends before it reaches a terminal view. See the note there for why a
 * client validates a peer it supposedly trusts.
 *
 * Kept deliberately free of UIKit and SwiftUI so the whole wire layer can be
 * exercised by the unit tests without a simulator.
 */

import Foundation

enum Wire {
    /// Bumped only for a breaking change; the desktop refuses a mismatch.
    static let protocolVersion = 1

    /// Largest inbound WebSocket message, fragments included.
    static let maxMessageBytes = 64 * 1024

    /// Largest `input` payload. A paste, not a file upload.
    static let maxInputBytes = 16 * 1024

    /// How much replay or live output the desktop puts in one `output` frame.
    static let outputChunkBytes = 32 * 1024

    /// Terminal sizes the desktop will accept. A phone in landscape with a small
    /// font can exceed neither, but a layout mid-transition can produce nonsense.
    static let minCols = 20
    static let maxCols = 500
    static let minRows = 5
    static let maxRows = 200

    /// Longest `hello.token`. The field carries an opaque bearer secret, so it is
    /// bounded rather than pinned to a shape.
    static let maxTokenLength = 200

    /// Largest chunk of tunnelled bytes in one `net.data`, before base64. Base64
    /// costs a third on top, which is what keeps the frame inside
    /// `maxMessageBytes` with the sealing tag and the envelope on it.
    static let maxNetChunkBytes = 24 * 1024

    /// How many unacknowledged bytes one side may have in flight on a tunnelled
    /// stream before it stops reading its own socket. See `PortTunnel`.
    static let netWindowBytes = 256 * 1024

    /// Largest slice of a file in one `upload.data`, before base64. The same
    /// number as `maxNetChunkBytes` and deliberately so — same envelope, same
    /// arithmetic, and two constants that must agree and are written twice are
    /// two constants that will one day not agree.
    static let maxUploadChunkBytes = 24 * 1024

    /// How many bytes of a file may be unacknowledged before the phone stops
    /// reading. See `FileUpload`: this is also what makes the progress bar
    /// measure the Mac's appetite rather than this phone's read speed.
    static let uploadWindowBytes = 256 * 1024

    /// Largest file the desktop will accept, in bytes. A 4K video is comfortably
    /// past 100 MB, so this is a ceiling rather than a guess at normal.
    static let maxUploadBytes = 512 * 1024 * 1024

    /// Longest file name the desktop will accept, in UTF-8 bytes. What the name
    /// *becomes* on disk is the Mac's decision, not this app's.
    static let maxUploadNameBytes = 255

    /**
     * Largest paste this app will put on the wire in one gesture.
     *
     * Not a protocol constant — the desktop caps a single `input` frame at
     * `maxInputBytes` and says nothing about how many of them may follow.
     * `WireCodec.chunkInput` will happily turn a 40 MB clipboard into 2,500
     * frames, which is not a paste, it is a way to make the Mac drop this phone
     * for buffering. So there is a ceiling here and the user is *told* the
     * number rather than having their paste silently shortened, which is the
     * one thing a paste must never do.
     */
    static let maxPasteBytes = 1024 * 1024

    /**
     * Longest `host` and `repo` on an inbound `credential.request`.
     *
     * The desktop bounds what it will *say* with the same two numbers. They are
     * repeated here rather than trusted because these two strings are the entire
     * content of a prompt somebody reads before approving a push — the one
     * screen in this feature that must not be able to lie about what it is
     * naming — and a hostname that will not fit on a phone is not one git
     * resolved. A hostname cannot exceed 253 characters and a GitHub
     * `owner/name` comes nowhere near 256.
     */
    static let maxCredentialHostLength = 253
    static let maxCredentialRepoLength = 256

    /**
     * Longest username and secret this client will put on the wire.
     *
     * `parseClientMessage` refuses anything longer and answers a refused frame
     * by closing the socket, so a token past this would cost the connection
     * rather than one push. Generous rather than tight, because what is in the
     * second field is somebody's GitHub token and the shape of those is not ours
     * to pin: 40 characters for a classic one, over 90 for a fine-grained one,
     * longer still for an installation token.
     */
    static let maxCredentialUsernameLength = 128
    static let maxCredentialSecretLength = 4096
}

/// WebSocket close codes used by this protocol, RFC 6455 §7.4.1 plus our own.
enum WireClose {
    static let normal = 1000
    static let goingAway = 1001
    static let protocolError = 1002
    static let unsupportedData = 1003
    static let policyViolation = 1008
    static let messageTooBig = 1009
    static let internalError = 1011
    static let tryAgainLater = 1013
}

/// A session as the phone sees it. Enough to draw a list and pick one.
struct RemoteSession: Equatable, Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    /// Free-form on purpose: the provider vocabulary belongs to the desktop.
    /// Today `claude` / `codex` / `gemini` / `shell`; a build of the desktop
    /// newer than this app will send something not in that list, and the list
    /// screen has to render it rather than drop the row.
    let provider: String
    /// Free-form for the same reason. Today `idle` / `working` / `waiting` /
    /// `input` / `completed` / `exited`.
    let status: String
    let exitCode: Int?
}

/// Identity a phone volunteers about itself. Display only — never trusted, and
/// the desktop sanitises it again on arrival.
struct DeviceDescriptor: Equatable {
    let name: String
    let platform: String
}

/**
 * What kind of machine is on the other end.
 *
 * This exists because the phone used to have no idea. `DeviceDescriptor.platform`
 * above travels the *other* way — it is this phone describing itself — and the
 * desktop never said anything about itself at all. So the session list carried a
 * string constant, `"Running on the Mac"`, and a phone paired to a Windows PC
 * read those words while looking at that PC's own dev servers.
 *
 * `unknown` is a real case and not a placeholder: every desktop released before
 * this field existed is still a desktop this app must talk to, and the honest
 * answer for one of those is a neutral noun. Guessing "Mac" for an absent field
 * is precisely the bug, so the fallback must never be a specific machine.
 */
enum HostPlatform: Equatable {
    case mac
    case windows
    case linux
    case unknown

    /// Maps the raw `process.platform` the desktop sends. Unrecognised values
    /// land on `.unknown` rather than being rejected — a desktop on a platform
    /// this build has never heard of is still one worth showing sessions for.
    init(wire: String?) {
        switch wire {
        case "darwin": self = .mac
        case "win32": self = .windows
        case "linux": self = .linux
        default: self = .unknown
        }
    }

    /// The noun to put in a sentence: "Running on the **Mac**".
    ///
    /// Deliberately no article and no capital beyond the proper noun, so callers
    /// can compose. `unknown` reads "desktop", which is true of every host this
    /// app can reach and singles out none of them.
    var noun: String {
        switch self {
        case .mac: return "Mac"
        case .windows: return "PC"
        case .linux: return "machine"
        case .unknown: return "desktop"
        }
    }
}

/// A terminal's measured size. Both or neither, never one — which is why this is
/// a struct and not two optionals.
struct TerminalSize: Equatable {
    let cols: Int
    let rows: Int

    /// Nil when the measurement is not one the desktop would accept. A caller
    /// that gets nil should attach without a size and resize once it has laid
    /// out, which is exactly what the protocol's optional size is for.
    init?(cols: Int, rows: Int) {
        guard cols >= Wire.minCols, cols <= Wire.maxCols,
              rows >= Wire.minRows, rows <= Wire.maxRows else { return nil }
        self.cols = cols
        self.rows = rows
    }
}

/**
 * Things a desktop can advertise beyond protocol v1.
 *
 * Version 1 carries `list`, `attach`, `input` and `resize` and nothing else, and
 * `parseClientMessage` closes the socket on a verb it does not know — so a
 * button that sends one would not be a feature, it would be a way to drop the
 * connection. Anything past v1 therefore has to be *offered* by the far end
 * before this app will use it, and the offer travels in `welcome.capabilities`,
 * a field a desktop that has never heard of it simply does not send.
 */
enum WireCapability {
    /**
     * The desktop can start a session on request.
     *
     * Named the same as the verb it grants, because there is exactly one verb —
     * a second name would only be a second thing for the two ends to disagree
     * about. Advertised by a real desktop whose session layer can actually
     * start one, which is not every host: `scripts/remote-host.ts` used to run
     * with a session layer that could not, and a capability read off a constant
     * would have offered a button with nothing behind it.
     */
    static let create = "create"

    /**
     * The desktop can end a session on request. `create`'s opposite number.
     *
     * Its own name rather than being implied by `create`, and the split is not
     * symmetry for its own sake: a host can genuinely have one and not the
     * other. The public demo box hands a stranger a shell and withholds this,
     * because starting something there is additive and bounded by a container
     * while ending something is neither.
     *
     * It is the capability this app waited for. `SessionListView` carried a doc
     * comment for a week saying the Close swipe was absent because no verb
     * existed and both available fakes had been refused — typing `exit` or a
     * Ctrl-C is not closing a session, since a full-screen agent CLI ignores
     * both and the row stays; a Close that only archived would be a label
     * describing something else. This is the verb, and the swipe is drawn only
     * when a desktop has said it speaks it.
     */
    static let close = "close"

    /// The desktop can say what is listening on its own loopback, and tunnel a
    /// byte stream to one of those ports. One name for the whole feature: a
    /// desktop that could list ports but not open one would have nothing to
    /// show for it.
    static let localhost = "localhost"

    /**
     * The desktop will open a page **on its own screen** because this phone
     * asked.
     *
     * A different question from `localhost`, which is why it is a different
     * name. A tunnel brings the page *here*, and that is the right answer for
     * reading a dev server on a train. This is the other half, and it is the one
     * he asked for by name: *"a browser started from the phone must run on the
     * machine you are inside — a live link or a localhost link both open on the
     * connected machine."* The phone is driving rather than viewing.
     *
     * Withheld by a host with no window to open a page in — the headless daemon
     * and the demo box are both in that position — and withheld from a device
     * that is a **guest** rather than one of the owner's own. A page appearing
     * on somebody's desktop is driving their machine, and no folder grant says
     * anything about a window; the desktop strips this name out of the welcome
     * for a guest exactly as it strips `copilot`. Both arrive here the same way,
     * as a capability the welcome did not carry, and the button is simply not
     * drawn.
     */
    static let web = "web"

    /**
     * The desktop can receive a file, and has somewhere to put it.
     *
     * Advertised by a Mac that was handed a downloads folder, which is not every
     * host: a build with nowhere to write must not draw a Send File button on
     * this phone. One name for the whole exchange — announcing, chunking,
     * acknowledging, finishing — because a phone that could announce a file but
     * not send its bytes would have nothing to show for it.
     */
    static let upload = "upload"

    /**
     * Git on the desktop may ask **this phone** for a login.
     *
     * The only capability that runs backwards, and that changes what the string
     * means on each side. Every other name here is a verb this phone sends and
     * the desktop serves; this one is a question the desktop asks and this phone
     * answers. So it is advertised in *both* directions — the desktop puts it in
     * `welcome.capabilities` to say "I may ask you", and this client puts it in
     * `hello.capabilities` to say "I can answer" — and both halves are load
     * bearing. A desktop that asked a phone which had never heard of the frame
     * would sit there until a timer gave up, which is exactly the thirty-second
     * stall on a `git push` that the feature exists to not have.
     */
    static let credential = "credential"

    /**
     * The desktop can say what a project's dev server is doing, and start it.
     *
     * Its own name rather than part of `localhost`, and the split is not
     * tidiness — it is the difference between two things a host can do
     * independently. `localhost` needs nothing but a socket, so every desktop
     * can serve it; this one needs a session layer that can start a session
     * *and* a per-device folder grant to start it in. The public demo box is the
     * case that makes it concrete: it offers `create` and nothing else, and it
     * must not draw a button on a stranger's phone that runs `npm run dev` in
     * somebody's checkout.
     *
     * Keyed by **folder**, never by port, for the reason `DevServerReport` gives:
     * a dev server is a script in one project's `package.json`, there is no such
     * thing as *the* dev server on a machine with four checkouts, and the port
     * does not exist until the thing is up — which is the state this whole
     * feature exists to get out of.
     */
    static let devserver = "devserver"

    /**
     * The desktop can speak `copilot.*` frames.
     *
     * The name lives on `Copilot.capability` rather than being spelled again
     * here, and this is an alias so that every capability in the product can
     * still be read off one type. The copilot's half of the wire is large
     * enough — a grant, five value types, seventeen frames — to have its own
     * file, and splitting the *name* away from it would be the first step in the
     * two halves drifting.
     *
     * Not in `claimed` below, deliberately, even though the desktop pushes
     * frames on this capability. `credential` is claimed because it is a
     * *question* the desktop will not ask unless something here answers it; the
     * copilot's pushes are answers to frames this phone sent first, and a phone
     * that never sends `copilot.attach` is simply never subscribed. Claiming it
     * would be telling the desktop something it has no use for.
     */
    static let copilot = Copilot.capability

    /**
     * What this build tells a desktop it can do, in `hello.capabilities`.
     *
     * Only names that run desktop→phone belong here. `create`, `localhost`,
     * `upload` and `devserver` are things this phone *asks for* and are gated by
     * what the desktop advertised, so claiming them would say nothing;
     * `credential` is a frame the desktop will only send once it has been told
     * somebody is listening for it.
     */
    static let claimed: [String] = [credential]
}

/**
 * The five things one project's dev server can be, as one word.
 *
 * A port of `DEV_SERVER_STATUSES`. They are five and not three because this app
 * has to draw five different things, and it is the two collapses that would hurt:
 *
 *  - `noDevScript` is **not** `idle`. `idle` means "press this"; this means
 *    "there is nothing to press, and there never will be for this folder,
 *    because its `package.json` declares no `dev`, `start` or `serve`". A row
 *    that flattened them would draw a button whose only possible outcome is a
 *    refusal — so this app draws no row at all for one.
 *  - `failed` is **not** `idle` either. The session that failed is still there
 *    with the reason printed in it, and the useful thing to offer is *that
 *    session* rather than a fresh Start button drawn as though nothing had
 *    happened.
 *
 * A status this build has never heard of is refused by the codec rather than
 * mapped onto a neighbour, because every one of the five draws a different
 * control and there is no honest default among them.
 */
enum DevServerStatus: String, Equatable {
    case noDevScript = "no-dev-script"
    case idle
    case starting
    case ready
    case failed
}

/**
 * One project's dev server, as this phone sees it.
 *
 * A port of `DevServerReport` in `protocol.ts`, which is itself a deliberate
 * trim of the desktop's own `DevServerState` — so this is the third hand-written
 * copy of one shape and the rule that comes with it is the rule the rest of this
 * file lives under: it changes when `protocol.ts` changes, with the same fields
 * and the same meanings.
 *
 * Which fields are set for which status, from the desktop's own table:
 *
 * | status         | script/command | sessionId | port/url | note  | message |
 * |----------------|----------------|-----------|----------|-------|---------|
 * | `noDevScript`  | –              | –         | –        | –     | –       |
 * | `idle`         | ✓              | –         | –        | –     | –       |
 * | `starting`     | ✓              | ✓         | –        | maybe | –       |
 * | `ready`        | ✓              | ✓         | ✓        | –     | –       |
 * | `failed`       | ✓              | maybe     | –        | –     | ✓       |
 *
 * ## Replace a row; never merge into one
 *
 * The fields are not independent — `port` and `url` exist only on `ready`,
 * `message` only on `failed` — so folding a new state into an old one leaves a
 * dead address under a live row. The protocol calls that "the one genuinely
 * wrong thing a client of this frame can display", and it is why this is a
 * `struct` with `let` fields rather than something a view model updates in
 * place: there is no path here that can carry a stale `url` forward.
 *
 * ## Everything on it is display text somebody else wrote
 *
 * `note` is a line a process on the far machine printed and is the field that
 * says so out loud, but `script` and `command` come from a `package.json` — a
 * file in a repository that may well have been cloned from a stranger — and
 * `message` is composed by a desktop this phone authenticated but does not
 * control. All four are drawn as text, never as markup, and the codec bounds and
 * cleans them on the way in. See `WireCodec.displayLine`.
 */
struct DevServerReport: Equatable, Identifiable, Hashable {
    /// The project folder, in **the desktop's** spelling — it comes back as the
    /// entry the desktop matched from its own grant list rather than as the
    /// string this phone sent, which can differ by a trailing separator or by
    /// case on Windows and still be the same directory. Rows are keyed on this.
    let folder: String
    let status: DevServerStatus
    /// The `package.json` script that runs it, e.g. `dev`.
    let script: String?
    /// The command line the desktop will type, e.g. `pnpm run dev`. Display it.
    let command: String?
    /**
     * The session it runs in — an **ordinary session**, in the same list every
     * other session is in, which this phone can open, read and kill exactly like
     * any other. That is why there is no stop verb in this feature and why this
     * app does not draw a Stop button: stopping a dev server is Ctrl-C in its
     * session, which already works.
     */
    let sessionId: String?
    /// Proven reachable: the desktop only ever sends this after something
    /// accepted a TCP connection on it. Safe to tunnel to — see `PortTunnel`.
    let port: Int?
    /// `http://localhost:<port>`, the address the tunnel will serve at.
    let url: String?
    /// The server's own latest output line, while `starting`. Untrusted.
    let note: String?
    /// Why it failed, in a sentence written by the desktop.
    let message: String?

    var id: String { folder }
}

/**
 * What git was doing when it asked for a login.
 *
 * A port of `CREDENTIAL_OPERATIONS`. Two values because there are exactly two
 * answers a person cares about, and the difference between them is the whole of
 * the prompting policy: a fetch or a clone is a **read**, is reversible, and
 * asking about one buys nothing but fatigue; a push is a **write**, is not
 * reversible, and is the moment somebody should get to see whose name goes on
 * it.
 *
 * It arrives as a fact, not as an instruction. What this client is asked to *do*
 * is the separate `prompt` flag on the same frame — see `credentialRequest`.
 */
enum CredentialOperation: String, Equatable {
    case read
    case write
}

/**
 * Why this device would not answer, as a code rather than a sentence.
 *
 * A port of `CREDENTIAL_DENIALS`, and the direction is the point: this string is
 * written *here* and read on somebody else's **desktop**, where it is printed
 * into a terminal. The desktop owns the words that appear in its own terminal —
 * it is the side that knows whether the reader is looking at a push or a fetch,
 * and it is the side that must not pipe text chosen by a phone into a PTY. So
 * this end says which of two things happened and the desktop writes the
 * sentence.
 *
 * `noAccount` is not a refusal. It means no GitHub is connected in this app yet,
 * which is a different thing to be told and has a different fix — and the
 * desktop's wording for it points at this phone rather than at the person who
 * pushed.
 */
enum CredentialDenial: String, Equatable {
    case denied
    case noAccount = "no-account"
}

/**
 * A port on the Mac that something is listening on.
 *
 * The desktop deliberately does not guess which framework is behind a port and
 * neither does this: `process` is the name of whatever holds the socket, and
 * `guessed` says only that even that could not be determined.
 */
struct LocalPort: Equatable, Identifiable, Hashable {
    let port: Int
    let process: String
    let guessed: Bool

    var id: Int { port }
}

enum ClientMessage: Equatable {
    /**
     * `capabilities` is this client's half of the negotiation.
     *
     * It rides on the `hello` rather than on a later frame because the desktop
     * may need it before this phone has said anything else: a session started
     * from this device can be running `git push` a second after it connects, and
     * the desktop has to know by then whether there is anything here that will
     * answer. See `WireCapability.claimed` for why the list is short.
     */
    case hello(protocolVersion: Int, token: String, device: DeviceDescriptor, capabilities: [String])
    case list
    /**
     * Start a session. **Only** legal when the desktop advertised `create`.
     *
     * Guarded at the one place that can guard it — `DeckModel` hides the button
     * — because sending this to a desktop that speaks plain v1 gets the socket
     * closed with a protocol error, which reads to a user as the network
     * dropping.
     *
     * `folder` is a directory the desktop is **already offering**: the `cwd` of
     * a session in the list on screen. The Mac refuses anything else rather
     * than quietly starting somewhere else, so this app never invents one — nil
     * means "wherever you would have started one", which is what the desktop's
     * own button does with nothing filled in.
     *
     * `size` travels for the same reason it travels on `attach`: the first
     * screen is then drawn at the size it will be read at.
     *
     * This used to be `create(title:)`, a shape invented against this repo's
     * own stand-in and never spoken by a desktop. A title is gone because every
     * session in the product is titled after its folder, by the Mac.
     */
    case create(folder: String?, size: TerminalSize?)

    /* ---- capability `close`. Never sent unless the desktop offered it. ------ */

    /**
     * End that session. **Only** legal when the desktop advertised `close`.
     *
     * ## Not `detach`, and the distinction is the whole frame
     *
     * `detach` says *stop sending me this session's bytes* and is what leaving a
     * terminal screen does. This ends the **process**: the tab on the desktop
     * goes, every other attached device gets an `exit`, and whatever the agent
     * was part-way through stops there. It is the only frame this app can send
     * whose effect cannot be taken back, which is why nothing sends it without a
     * confirmation the person read — see `SessionListView.closeAction`.
     *
     * ## One field, and the two that are deliberately absent
     *
     * No signal and no force flag. Choosing how somebody else's editor is killed
     * is not a phone's decision, and the desktop ends a session exactly as its
     * own ✕ does — one behaviour rather than two that can drift. And no reason
     * string: it would be text from this device printed into the desktop's own
     * chrome, for nothing.
     */
    case close(id: String)

    /// The size travels with the attach so the first screen arrives already the
    /// right shape; it is optional because a client that has not measured its
    /// terminal yet must still be able to attach and then resize.
    case attach(id: String, size: TerminalSize?)
    case detach(id: String)
    case input(id: String, data: String)
    case resize(id: String, cols: Int, rows: Int)
    case ping

    /* ---- capability `localhost`. Never sent unless the desktop offered it. -- */

    /// What is listening on the Mac right now.
    case ports
    /**
     * Open a tunnel to one port. **This message is the consent.**
     *
     * There is no separate permission and no confirmation sheet: nothing on the
     * Mac is reachable until this is sent, and it is sent because a person
     * tapped a port. Closing the browser view sends `tunnelClose`, which is the
     * whole of the revocation.
     */
    case tunnelOpen(id: String, port: Int)
    case tunnelClose(id: String)

    /* ---- capability `web`. Never sent unless the desktop offered it. -------- */

    /**
     * Open this page **on the machine**, in its own browser.
     *
     * The other half of localhost, and the half a tunnel cannot be. A tunnel
     * brings a dev server to this screen; this puts it on the screen of the
     * machine the person is inside, which is what he asked for in the same
     * breath as the port list — *"a live link or a localhost link both open on
     * the connected machine."*
     *
     * `url` is checked on the desktop and not here, and that split is
     * deliberate: this app composes `http://localhost:<port>/` from a row that is
     * on screen, so it never has an arbitrary address to send — but the desktop
     * still puts every one through the same gate an untrusted link goes through,
     * because a client is not a thing a machine gets to trust about what it opens.
     * Answered with `webOpened` carrying what was *actually* opened, or with a
     * plain `error`.
     */
    case webOpen(url: String)

    /// One browser connection on the phone's loopback listener. Only legal
    /// after the desktop has answered `tunnelOpen` with `tunnel.opened`.
    case netOpen(ch: String, tunnel: String)
    /// Bytes, base64 only on the wire — `WireCodec` does that, so nothing above
    /// it has to remember which representation it is holding.
    case netData(ch: String, data: Data)
    /// "I have written this many bytes to my socket." See `Wire.netWindowBytes`.
    case netAck(ch: String, bytes: Int)
    case netClose(ch: String)

    /* ---- capability `devserver`. Never sent unless the desktop offered it. -- */

    /**
     * What is this project's dev server doing?
     *
     * `folder` is one the desktop is **already offering this device** —
     * `welcome.folders`, kept current by the pushed `folders` frame — and the
     * desktop refuses anything else rather than answering about a path off the
     * network. So this app never composes one: every folder it can name is a row
     * that was on screen.
     *
     * Sending it also **subscribes** this connection to that folder. Every later
     * change arrives as a pushed `devState` with no timer on this side, which is
     * the whole reason a two-minute cold start is readable on a phone. The
     * subscription belongs to the socket, so it is re-sent on each `welcome`
     * rather than remembered across a reconnect.
     */
    case devStatus(folder: String)
    /**
     * Start it. **This message is the consent, and there is no standing one.**
     *
     * Nothing runs on the far machine because of this feature until this is
     * sent, and it is sent because a person tapped a row for a folder their
     * desktop has granted them. There is no configured list of auto-start
     * projects and nothing to revoke: removing the folder from the grant on the
     * desktop is the whole of the revocation.
     *
     * The command is not on this wire and cannot be. The desktop reads the
     * folder's own `package.json` and runs the script it declares; a client that
     * could name a command would be a client that could run one.
     *
     * Answered with a `devState` carrying `starting`, immediately — not held
     * open until the server is up, because a dev server takes seconds to tens of
     * seconds and this app needs something to draw for all of them.
     */
    case devStart(folder: String)

    /* ---- capability `upload`. Never sent unless the desktop offered it. ----- */

    /**
     * A file is coming. **This message is the consent, and it is this phone's.**
     *
     * Nothing is written to the Mac's disk until this is sent, and it is sent
     * because a person picked something in `PHPickerViewController` or
     * `UIDocumentPicker` — both of which run in another process, so this app
     * never sees the library and never asks for permission to. The Mac answers
     * with the path the file will land at, *before* any bytes move, and that
     * path is on screen while Cancel is still available.
     *
     * `name` is a suggestion. The Mac reduces it to one path component and picks
     * the real name; this app never assumes the two match.
     */
    case uploadBegin(id: String, name: String, size: Int)
    /// One slice, base64 only on the wire — `WireCodec` does that, so nothing
    /// above it has to remember which representation it is holding.
    case uploadData(id: String, data: Data)
    /// That was all of it, and this is the SHA-256 of what was read. The Mac
    /// compares it against what it wrote and deletes the file if they differ.
    case uploadEnd(id: String, sha256: String)
    /// Stop, and throw away what has landed. The Cancel button on the progress row.
    case uploadCancel(id: String)

    /* ---- capability `credential`. The one exchange that starts over there. -- */

    /**
     * "I heard you, and I am dealing with it."
     *
     * The one frame here that exists purely for a failure mode, and it is the
     * failure mode the whole feature is judged on. Without it the desktop cannot
     * tell a phone that is asleep from a person who is thinking — both look like
     * silence — so it would have to wait out the *human* deadline before it
     * could say "your device isn't reachable". That is a thirty-second stall on
     * a push with nothing on screen, which is how people stop trusting a
     * feature.
     *
     * Sent for silent requests too, where it costs nothing, because a client
     * that only acked when it was about to prompt would be one more thing that
     * has to be right.
     */
    case credentialAck(id: String)
    /**
     * The login, for this one operation.
     *
     * `remember` is the second button on the prompt — "Always for this repo" —
     * and it is a *scope*, not a stored secret: it tells the desktop it may stop
     * asking about this repository from this device. Every push still comes back
     * here for the credential itself, because the desktop has never held one.
     * The desktop ignores it on a request nobody was asked about, so a silent
     * answer sends it false.
     */
    case credentialAnswer(id: String, username: String, password: String, remember: Bool)
    /// No. Carries a code rather than a sentence — see `CredentialDenial`.
    case credentialDeny(id: String, reason: CredentialDenial)

    /* ---- capability `copilot`. Never sent unless the desktop offered it, and
       never sent unless this device's grant covers it. See `CopilotWire.swift`
       for why the second gate is here as well as on the desktop. ------------ */

    /**
     * Open the copilot connection on this socket. **No tier, and no credential.**
     *
     * **Required after every reconnect**, before any other `copilot.*` frame.
     * `welcome.copilot.open` is *always* false — a socket has presented nothing
     * at the moment it is greeted — so a client that treats the welcome as
     * "already in" sends frames that are refused. This is the frame that says
     * *it is me, on this socket*, and it is answered with `copilot.grant`
     * carrying `open: true`.
     *
     * ## It used to carry a credential, and the credential is gone
     *
     * Asad, on 2026-08-19:
     *
     * > *"Instead of giving mobile app separate connection for copilot just make
     * > it like if we are connecting as my device copilot automatically comes,
     * > if we connect as guest then copilot don't come — that's all we need to
     * > do instead of two different connections."*
     *
     * So the second act of authorisation is deleted. **Pairing a device as "My
     * device" IS the authorisation for the copilot**, which is what the approval
     * screen has always said in his own words — *"My device — Full access. It's
     * you at another keyboard"* against *"Guest — You choose what they can
     * reach. The copilot is never shared."* A device that has been approved as
     * his does not then have to prove it a second time with six digits read off
     * the machine it is already talking to.
     *
     * What authorises this frame is therefore the socket's **already
     * authenticated device identity** plus that device's kind, both of which the
     * desktop knows before the frame arrives. There is nothing to send and
     * nothing to store: `copilot.connect` is deleted from the vocabulary, there
     * is no copilot code, no copilot credential, and no state in which a device
     * is paired but the copilot is "not connected yet".
     */
    case copilotHello
    /**
     * Close the copilot connection on this socket, and keep the terminals.
     * **No tier.**
     *
     * The *connection* ends, not the authorisation: the device is still one of
     * his, so the next `copilotHello` works with no ceremony at all.
     *
     * **This client never sends it**, and has not since the *"Close the copilot
     * here"* item went — *"Why do we have Close the copilot here? It doesn't
     * make any sense."* It stays in the vocabulary because the browser client
     * sends it and because `WireCodec` pins its encoding; a verb this app can
     * spell and does not press is cheaper than a wire the two ends disagree
     * about. See `CopilotLink`, where the flag behind that menu item used to be.
     */
    case copilotBye
    /**
     * Answer a confirmation. **Tier: alter.**
     *
     * The only frame on this wire that decides anything, and it carries a
     * question id and a boolean — never a tool, never an argument. The tool, the
     * arguments and the effect were all composed on the desktop before anybody
     * was asked anything, which is what keeps the enforcement model airtight
     * while the phone holds every tier.
     *
     * Two further rules are the desktop's and are not repeated here as checks,
     * only as expectations: a question may only be answered by the surface that
     * owns the run that raised it (enforced in `ConsentBroker.respond`, with the
     * question, so a second transport cannot arrive without it), and a settled
     * question and somebody else's question get the **same** answer, so probing
     * for another device's ids learns nothing.
     */
    case copilotAnswer(id: String, approved: Bool)

    /**
     * Watch the copilot. **Tier: read.**
     *
     * Subscribes this connection to the copilot surface and asks for what
     * exists: the desktop answers with `copilot.state`, then a `copilot.chat`
     * carrying `reset`. It **starts nothing** — no process, no run, no spend —
     * which is exactly why it is separable from `copilotStart` and why the read
     * tier is a grant worth handing out on its own.
     *
     * Like `devStatus`, the subscription belongs to the *socket*, so this is
     * re-sent on every `welcome` rather than remembered across a reconnect.
     */
    case copilotAttach
    /// Stop the stream. **Tier: read.** The run keeps going — see the grace
    /// window in `CopilotLink` — because a phone going into a pocket is not a
    /// person cancelling their question.
    case copilotDetach
    /// What the copilot is: running or not, whose run, which profile, and how
    /// many confirmations are waiting at the desk. **Tier: read.**
    case copilotState
    /// The sessions the copilot started, each linked back to the turn that made
    /// it. **Tier: read.**
    case copilotSessions
    /**
     * The tail of the action log, newest last. **Tier: read.**
     *
     * `before` is a row id, for paging backwards — the same shape the desktop's
     * own Activity pane uses. `limit` is clamped to 1…200 on arrival; this end
     * sends `Copilot.logPage` and never composes a number from anything a view
     * holds.
     */
    case copilotLog(limit: Int, before: String?)
    /// Confirmations waiting **at the desk**. **Tier: read, and watch-only** —
    /// there is no frame here that answers one, by design. See `CopilotQuestion`.
    case copilotPending
    /**
     * Start this device's own copilot run. **Tier: act. The tap is the consent.**
     *
     * It spends money, which is the whole reason it is not folded into
     * `copilotAttach`: a screen that started a second Claude process because
     * somebody looked at it would be a screen with a bill attached to opening
     * it. Nothing runs on the far machine because of this feature until this is
     * sent, and it is sent because a person pressed a button that says so.
     *
     * The run is the phone's own — same folder, same `CLAUDE.md`, same
     * `memory/`, same action log as the copilot at the desk, and its own
     * conversation and its own bearer token. That separation is what makes the
     * action log able to say which of my phones did that.
     */
    case copilotStart
    /**
     * Say something to it. **Tier: act.**
     *
     * `act` and not `read`, and the line is what makes the read tier mean
     * something: talking to the copilot *is* `sessions.send` against a session,
     * it spends money and it causes tool calls. So `read` is a **watching**
     * grant — this phone shows me what my copilot is doing and cannot make it do
     * anything — which is the grant worth handing out first.
     *
     * Prose. Never a tool name, never an argument object. See the header of
     * `CopilotWire.swift`.
     */
    case copilotSay(text: String)
    /// Interrupt the current turn of **this device's own run**. **Tier: act.**
    case copilotCancel
    /// End this device's own run. **Tier: act.** Not the copilot at the desk —
    /// runs are keyed by device, and a phone that could stop the run somebody is
    /// working in would be a phone holding a power its grant does not name.
    case copilotStop
}

enum ServerMessage: Equatable {
    /**
     * `capabilities` is read defensively and defaults to empty: it is not in
     * protocol v1, and a desktop that does not send it is telling the truth
     * about itself by omission.
     *
     * `folders` is optional for the same reason and **nil is not the same as
     * empty**. Nil means the desktop never mentioned folders — every build
     * before this field existed, and every host that cannot start sessions at
     * all — so the phone keeps the list it used to assemble for itself. Empty
     * means a person sat at that machine and granted this device no folders,
     * which is a real answer and the one the New Session button has to respect.
     *
     * **`copilot` is present if and only if this phone has a copilot on that
     * machine**, and its presence is the whole answer.
     *
     * That is the shape as of 2026-08-19, and it is smaller than what it
     * replaced. The desktop writes the field only when it has a copilot layer
     * **and** the device this socket belongs to was approved as one of his own —
     * *"if we are connecting as my device copilot automatically comes, if we
     * connect as guest then copilot don't come."* A guest receives no `copilot`
     * key at all: absent, not present-and-false. So this end has one question to
     * ask of the frame rather than a ceremony to walk, and `CopilotConnection`
     * is a decoded object rather than a state machine.
     *
     * The **capability name is still not that answer**, and the distinction is
     * the reason `CopilotConnection.stated` exists: the desktop assembles
     * `capabilities` by filtering `CAPABILITIES` — every extension this build
     * knows how to serve — against what its injected objects can actually do,
     * and a build where the filter has drifted advertises a feature it cannot
     * serve. The field is written by the same object that serves the frames, so
     * it cannot drift from them. See `CopilotConnection`, where the host that
     * advertises what it does not implement is named.
     *
     * **`copilot.open` is false on every welcome, always.** Not sometimes, and
     * not "unless you were connected a moment ago": copilot access belongs to
     * the *socket*, and a socket has presented nothing at the moment it is
     * greeted. `copilotHello` opens it, on every reconnect, carrying nothing —
     * the device's identity and its kind are what authorise it. A client that
     * reads `open` as "already in" sends frames that are refused.
     *
     * `folders`, one field to the left, keeps nil and empty apart for an
     * unrelated reason of its own. Two fields, two rules, written differently
     * rather than tidied into agreement.
     */
    case welcome(protocolVersion: Int, deviceId: String, deviceName: String, token: String?,
                 sessions: [RemoteSession], capabilities: Set<String>, hostPlatform: HostPlatform,
                 folders: [String]?, copilot: CopilotConnection)
    case sessions([RemoteSession])
    /**
     * This device's folder list changed while it was connected.
     *
     * Pushed rather than polled, and it carries the whole list rather than a
     * delta — there is one list per device, it is short, and a client applying
     * deltas would have to be right about every one of them to end up with the
     * set the desktop is actually enforcing.
     *
     * It exists because the list is editable on the desktop at any moment. The
     * *rule* is already live without this frame — the Mac reads the grants on
     * every `create`, so removing a folder takes effect on the next one with no
     * reconnect — so all this does is stop the phone offering a folder whose
     * only possible outcome is a refusal.
     */
    case folders([String])
    case attached(id: String)
    case detached(id: String)
    /// `replay` marks scrollback that arrived before this client did.
    case output(id: String, data: String, replay: Bool)
    case status(id: String, status: String)
    case exit(id: String, exitCode: Int)
    case error(code: ProtocolErrorCode, message: String)
    case pong

    /* ---- capability `create` --------------------------------------------- */

    /// The session the Mac just started, for the phone that asked.
    ///
    /// The whole row rather than an id, so the tap that started it is also the
    /// tap that opens it. Every *other* connected device is told with a plain
    /// `sessions` instead, which is a frame every client back to the first one
    /// understands.
    case created(session: RemoteSession)

    /* ---- capability `close` ---------------------------------------------- */

    /**
     * That session is gone, because this phone asked.
     *
     * Sent only to the device that asked, and only once the session has actually
     * ended — never on the request being received. The row is removed on *this*
     * frame rather than optimistically on the tap, which is the difference
     * between a list that reflects the machine and one that reflects what
     * somebody pressed. Every other connected device finds out through the
     * ordinary `sessions` refresh, a v1 frame, so a client that has never heard
     * of closing still watches the row disappear.
     *
     * A refusal is a plain `error` — a folder taken back a moment ago, a session
     * that had already exited — and it arrives with the id nowhere in it, so the
     * screen says its own sentence about the row it asked about.
     */
    case closed(id: String)

    /* ---- capability `localhost` ------------------------------------------ */

    case ports([LocalPort])
    case tunnelOpened(id: String, port: Int)
    /**
     * The page is open on the machine.
     *
     * Carries what was opened rather than what was asked for: a redirect or a
     * normalisation on the far side is the truth and this end's copy is not.
     * Sent only when a tab was actually made, so the confirmation on screen is
     * about something that happened.
     */
    case webOpened(url: String)
    /**
     * The tunnel is gone, and `message` says why in a sentence to put on screen.
     *
     * One frame for a refusal, for a teardown this phone asked for and for a
     * Stop pressed on the Mac, because to this end they are one event: the page
     * being shown has nothing behind it any more. Which of the three it was is
     * in the sentence, not in a code.
     */
    case tunnelClosed(id: String, message: String)
    case netData(ch: String, data: Data)
    case netAck(ch: String, bytes: Int)
    case netClose(ch: String)

    /* ---- capability `devserver` ------------------------------------------- */

    /**
     * One project's dev server, now.
     *
     * The single frame for the whole capability: it answers `devStatus`, it
     * answers `devStart`, and it arrives **unsolicited** every time the state
     * changes after a start — a new progress line, the moment a port accepts, a
     * timeout. One frame rather than three, because to this end they are one
     * event: a row now says something different.
     *
     * **The same state can arrive twice, and that is by design.** A `devStart`
     * gets its state as a direct answer *and* as a push; deduplicating the
     * overlap would mean the desktop guessing which of the two a client had
     * already acted on. Handle it idempotently — replace the row keyed by
     * `folder` and the duplicate costs nothing. See `HostLink.devServers`.
     *
     * A refusal — a folder this device was not granted, a host that cannot start
     * sessions — comes back as a plain `error` with `unauthorized`, never as a
     * `devState`, because there is no folder state to report about a folder the
     * desktop will not discuss.
     */
    case devState(DevServerReport)

    /* ---- capability `upload` ---------------------------------------------- */

    /// The file is accepted, and this is where on the Mac it will be. Sent
    /// before a single slice is asked for, so the person can read the path while
    /// Cancel still means something.
    case uploadReady(id: String, path: String)
    /// "I have written this many more bytes." What the progress bar is drawn
    /// from — see `Wire.uploadWindowBytes` for why it is not the bytes handed to
    /// the socket.
    case uploadAck(id: String, bytes: Int)
    /// It is on disk, complete, and the digest matched. `path` is repeated
    /// rather than remembered, because a second file of the same name lands
    /// beside the first and *this* is the path to type.
    case uploadDone(id: String, path: String, bytes: Int, sha256: String)
    /// There is no file, and `message` says why. One frame for a refusal, a
    /// failure and a cancel, because to this end they are one event.
    case uploadFailed(id: String, message: String)

    /* ---- capability `credential` ------------------------------------------ */

    /**
     * Git on the desktop needs a login for a repository, and this phone holds it.
     *
     * The only frame the desktop sends as a *question*. Everything else it sends
     * is an answer or an event; this one is waiting on a reply, and the two ways
     * to reply are `credentialAnswer` and `credentialDeny` — with a
     * `credentialAck` first, always, so the desktop can tell a live phone from
     * one that is in a drawer.
     *
     * `repo` is `owner/name`, or **nil** when git gave the desktop no path to
     * derive one from — a gist, a wiki, a self-hosted layout. Nil is not a
     * detail to paper over: a prompt that cannot name the repository is asking
     * somebody to approve "a push, somewhere", and this client says exactly that
     * rather than inventing a name. It is also why "always for this repo"
     * disappears in that case: there is no repo to attach the always to, and the
     * desktop refuses to record one.
     *
     * `prompt` is the instruction and `operation` is the fact, and they are two
     * fields because they answer two different questions. `operation` says what
     * git is doing, always. `prompt` says whether a person should be asked —
     * false for every read, and false for a write against a repository this
     * device has already approved on that machine.
     */
    case credentialRequest(id: String, host: String, repo: String?,
                           operation: CredentialOperation, prompt: Bool)

    /* ---- capability `copilot` --------------------------------------------- */

    /// What the copilot is. An answer to `copilotState`, and pushed on change.
    case copilotState(CopilotState)
    /**
     * The conversation, as parsed messages — never pty bytes.
     *
     * Merge by `message.id`: replace on a match, append otherwise. `reset` means
     * drop everything and take this as the whole conversation.
     *
     * `run` is carried so a frame from a run that has since been replaced is
     * **dropped** rather than merged into the new one. Without it, a run that
     * ended while the phone was in a pocket and a fresh one started on the way
     * back would produce one conversation made of two, with no seam visible on
     * screen — a phone showing an agent apparently answering a question nobody
     * asked it.
     */
    case copilotChat(run: String, messages: [CopilotChatMessage], reset: Bool)
    /**
     * One tool call, as it happens, already scrubbed.
     *
     * This is *"see what it is doing"*, and it is also the frame that makes a
     * refusal visible: a call this device's grant did not cover arrives here
     * with `outcome: refused` and `refusal: not-granted`, in the copilot's own
     * words, rather than as silence the person has to interpret.
     */
    case copilotTool(CopilotAction)
    /// The sessions the copilot started. An answer, and pushed when the set
    /// changes.
    case copilotSessions([CopilotSessionRow])
    /// A page of the action log. An answer only — never pushed, because the live
    /// view of the same thing is `copilotTool`. `more` says the tail was
    /// bounded, in the same spirit `ToolTrail.partial` reports its own window.
    case copilotLog(rows: [CopilotAction], more: Bool)
    /// Confirmations waiting, at the desk and on other devices. An answer, and
    /// pushed when the set changes — including to empty, which is how a question
    /// that was answered or timed out leaves this phone's screen. `mine` says
    /// which of them this connection may answer; the rest are a *go and look*.
    case copilotPending([CopilotQuestion])
    /**
     * This device's copilot connection changed while it was connected.
     *
     * Chiefly this is the answer to `copilot.hello` — the frame carrying
     * `open: true` that says the socket is in, and the only thing that starts a
     * subscription. It is also how a `copilot.bye` is confirmed, and how a
     * device that stops being one of his learns it without waiting for a
     * reconnect: `linked` goes false, and this end takes the copilot away rather
     * than leaving a tab whose every press would be refused.
     *
     * The *rule* is already live without this frame — the desktop re-reads the
     * store on every frame and every tool call — which is what makes this honest
     * rather than load-bearing: it stops the phone offering a control whose only
     * outcome is a refusal, and nothing more.
     */
    case copilotGrant(CopilotConnection)
    /**
     * A confirmation **this** connection may answer, in full.
     *
     * Sent only to the surface that owns the run that raised it, and carrying
     * what a pending row deliberately does not: the tier, the origin, and every
     * argument verbatim. That is not generosity — it is the minimum somebody
     * needs to answer honestly, and withholding it produces the reflex Yes the
     * whole design refuses.
     *
     * There is no replay. A phone that reconnects while a question is
     * outstanding sees it in `copilot.pending` with `mine: true` and gets no
     * `copilot.ask`, so it has the id and not the request — and answering on an
     * id alone is answering blind. See `CopilotView`, which draws that case as a
     * *go and look* rather than as a button.
     */
    case copilotAsk(CopilotConsentQuestion)
    /**
     * A question closed, and where it was answered.
     *
     * Pushed to every connection that was told about it, **including the one
     * that answered**. First answer wins, and the surface that loses the race
     * withdraws its sheet saying where it went rather than having it vanish: a
     * dialog that disappears on its own teaches a person that the app does
     * things behind their back.
     */
    case copilotSettled(CopilotSettlement)
}

enum ProtocolErrorCode: String, CaseIterable, Equatable {
    case badMessage = "bad-message"
    case unauthenticated
    case unauthorized
    case unknownSession = "unknown-session"
    case tooLarge = "too-large"
    /// The Mac understood, would have been allowed to do it, and could not — a
    /// folder deleted since it was listed, a shell that will not spawn. Worth
    /// trying again, which is why it is not `unauthorized`: telling someone
    /// "not allowed" when the truth is "it broke" sends them to the pairing
    /// screen to fix a missing directory.
    case unavailable
    case version
}

/// Session ids as the desktop mints them. Checked here so a malformed row from
/// a peer that is not the desktop cannot become the id in an `attach`.
enum SessionID {
    private static let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
