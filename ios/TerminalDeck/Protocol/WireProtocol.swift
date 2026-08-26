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

    /**
     * The one message that may exceed `maxMessageBytes` — a `browser.frame`.
     *
     * A screencast frame's base64 JPEG is by design larger than the 64 KiB text
     * cap that guards keystrokes and outlines; the desktop admits it on its own
     * receive door as the sole exception, and this client's inbound socket has
     * to make the same room or the frame is dropped before it can be decoded and
     * drawn. It is the port of `MAX_FRAME_MESSAGE_BYTES` in `protocol.ts`:
     * `MAX_FRAME_BYTES` (67 KiB) base64s to `ceil(n/3)*4` and gains 2 KiB for the
     * envelope, and the sum still sits under the relay's 96 KiB payload ceiling.
     * The relay carrier already opened at 96 KiB for that reason; the direct
     * carrier opens at this so the tailnet path can carry a frame too.
     */
    static let maxFrameBytes = 67 * 1024
    static let maxFrameDataChars = ((maxFrameBytes + 2) / 3) * 4
    static let maxFrameMessageBytes = maxFrameDataChars + 2 * 1024

    /// The live browser view — a cast of one surface, and the taps back. Ports of
    /// the `WATCH` bounds in `protocol.ts`: a viewer's requested width and jpeg
    /// quality are clamped into these, not refused, because they come from a
    /// viewer sizing its own canvas rather than from an attacker.
    static let minWatchWidth = 160
    static let maxWatchWidth = 1600
    static let minWatchQuality = 1
    static let maxWatchQuality = 80
    /// The soft ceiling on how many surfaces one connection watches at once.
    static let maxWatchWindows = 8
    /// The most surfaces one `browser.surfaces.rows` may list.
    static let maxSurfacesReported = 64
    /// The most touch points one `browser.input.touch` may carry.
    static let maxTouchPoints = 10
    /// The longest curtain prompt a masked frame may carry.
    static let maxWatchPromptLength = 256

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

/**
 * Which shell is serving this connection — the Electron desktop, or the
 * headless host a person installed on a server.
 *
 * Carried on `welcome` beside `appVersion` so this client can say *server*
 * where it would otherwise have guessed *desktop*, and so the one sentence it
 * renders about being behind — *update this server from a desktop* — names the
 * right kind of box. A port of `HostKind` in `src/main/remote/protocol.ts`.
 *
 * `unknown` is a real case for the same reason `HostPlatform.unknown` is: the
 * field is absent from every desktop released before it existed, and a value
 * neither literal is dropped onto `unknown` rather than guessed — the same rule
 * the platform noun keeps.
 */
enum HostKind: Equatable {
    case desktop
    case headless
    case unknown

    /// Maps the wire's two literals. Absent, or anything else, is `.unknown` —
    /// which reads as the neutral "desktop or server" rather than a guess.
    init(wire: String?) {
        switch wire {
        case "desktop": self = .desktop
        case "headless": self = .headless
        default: self = .unknown
        }
    }

    /// The noun for the box behind this connection. `unknown` reads "machine",
    /// which is true of both and singles out neither.
    var noun: String {
        switch self {
        case .desktop: return "desktop"
        case .headless: return "server"
        case .unknown: return "machine"
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
    /**
     * The desktop will report a plan window's usage and a session's context.
     *
     * Shipped on the desktop since 2026-08-18 and asked for by nothing on this
     * client until now, which is the whole of why *"the phone gained a usage
     * ring and a context bar"* was true of the browser page and false of the app
     * on his phone. Nothing new was needed on the wire; there was simply nobody
     * asking.
     */
    static let usage = "usage"

    /// The desktop will say which login a session runs as, and move it to
    /// another. Its own name rather than part of `usage`, because a machine can
    /// answer one and not the other and the chip is drawn per answer.
    static let account = "account"

    /**
     * The desktop will read and set a session's model, effort, fast mode and
     * permission — `controls.read` / `controls.apply`.
     *
     * Shipped on the desktop since 0.5.0 and asked for by nothing on this
     * client until now: the desktop's own remote window already sends these
     * frames (see `readControls` / `setControl` in
     * `src/main/remote/machines/guest.ts`), so a phone could watch a session
     * and never change what it runs at. Nothing new is on the wire; there was
     * nobody asking. The cluster is drawn only when a real agent is drawing
     * that session's screen — see `SessionControlsLink`.
     */
    static let controls = "controls"

    /**
     * The two settings this **machine** owns rather than each device —
     * `settings.read` / `settings.apply`, the "This server" section.
     *
     * The coding tool a fresh session starts with, and whether the last layout
     * is restored at launch. Withheld from a guest at the source, so a device
     * that sees it in `welcome.capabilities` is entitled to change them. Claimed
     * below because the desktop pushes `settings.changed` unsolicited when
     * another device moves one, and a client that never claimed it would keep a
     * stale value with no way to hear the correction.
     */
    static let settings = "settings"

    /**
     * The roster of every device signed in here, and the one verb that removes
     * one — `devices.list` / `devices.revoke`, and the unsolicited
     * `devices.changed`.
     *
     * Withheld from a guest at the source: the host only ever puts it in a
     * welcome for one of the owner's own devices, so a device that sees it is
     * both able to manage the roster and entitled to. Claimed below because the
     * `devices.changed` push arrives without a request, and a client that had
     * not claimed it would list a roster that never moved.
     */
    static let devices = "devices"

    /**
     * Watching the machine's browser, and driving it — `browser.watch`,
     * `browser.frame`, `browser.input`, `browser.surfaces` — a live cast of one
     * surface and the taps that come back.
     *
     * Dual-listed like the browser-window capabilities: a **host** lists it in
     * `welcome.capabilities` to say *"I hold browser surfaces, I can stream one
     * and act on the taps you send it"*; a **client** lists it in
     * `hello.capabilities` to say *"I render frames and I send input"*, which is
     * why it is in `claimed`. Withheld from a guest at the source — watching the
     * owner's signed-in browser is an owner act — so a device that sees it in a
     * welcome may both watch and drive.
     */
    static let watch = "watch"

    /**
     * Walk this machine's folders, and add one to the list this device may use.
     *
     * Advertised by a host only to one of the owner's own devices — a guest is
     * never told it exists, because the point of lending a folder is that the
     * borrower cannot leave it. So its absence has two meanings this phone
     * cannot tell apart and does not need to: an older desktop, or a device
     * paired as a guest. Both draw the picker without the *Choose a folder* row,
     * which is exactly what the app looked like before this existed.
     *
     * Not in `claimed` below: this is something the phone *asks for*, gated by
     * what the host advertised, so naming it in `hello` would say nothing.
     */
    static let folderPick = "folders.pick"

    /// Read this machine's files: list a folder, read a file. **No write verb,
    /// and there will not be one** — editing a file on a machine you cannot see,
    /// on a phone keyboard, breaks a repository slowly, and a session with an
    /// agent in it is the better door. Owner devices only, and more sharply than
    /// `folderPick`: this reads *file contents*, so a guest that held it could
    /// read a private key out of a folder it was never lent.
    static let files = "files"

    /// What git says about a folder, and what one file changed — `readGitStatus`
    /// and `readFileDiff` over the wire, the same two calls the desktop has made
    /// since it had a Source control panel. Read-only: status and a diff, never a
    /// commit. Owner devices only; a diff is file contents by another name.
    static let git = "git"

    /// The four read-only panels the desktop had and the phone did not —
    /// **artifacts, store, AI readiness, MCP servers**. *"all what i asked for so
    /// many times, i need all no exceptions."* One capability for four because
    /// each is a list of rows a person reads and does not act on, and the
    /// differences are in the words rather than the structure.
    static let panels = "panels"

    /// The machine's own browser profiles. An alias of
    /// `MachineProfilesWire.capability`, the way `copilot` aliases
    /// `Copilot.capability`: the name lives beside the family it names, and every
    /// capability stays readable off this one type. Owner devices only, and more
    /// sharply than `files` — a profile *is* somebody's signed-in cookie jar.
    static let browserProfiles = MachineProfilesWire.capability
    /// Driving the machine's own browser — its windows, not this phone's. Aliased
    /// to `MachineBrowserWire.capability` the way `browserProfiles` is aliased
    /// above, so the string lives beside the model it belongs to.
    static let browserControl = MachineBrowserWire.capability

    /**
     * What this build tells a desktop it can do, in `hello.capabilities`.
     *
     * Only names that run desktop→phone belong here, either as a *question* the
     * desktop asks (`credential`), or as an unsolicited *push* a client would
     * otherwise miss (`devices` / `settings` — the `*.changed` frames), or as
     * the client half of a dual-listed name (`watch` — "I render frames and I
     * send input"). The names this phone merely *asks for* — `create`,
     * `localhost`, `upload`, `devserver`, `usage`, `account`,
     * `controls` — are gated by what the desktop advertised, so claiming them
     * would say nothing. This is the same list `CLAIMED_CAPABILITIES` carries in
     * `pwa/src/protocol-client.ts`.
     */
    static let claimed: [String] = [credential, devices, settings, watch]
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

/**
 * One sub-folder on the machine, in the folder picker.
 *
 * `readable` is carried rather than assumed because a listing of a real Linux
 * box has folders in it that this account cannot open — `/root` is on every one
 * of them — and the honest thing is to draw the row dimmed rather than to hide
 * it or to offer a tap that fails. Somebody looking for a folder they know is
 * there and cannot see goes looking for a bug in the picker.
 *
 * `granted` marks a folder already on this device's list, so browsing back to
 * one shows it is there instead of inviting somebody to add it twice.
 *
 * Identified by `path` and not by `name`: two projects called `web` under
 * different parents are one name and two rows.
 */
/**
 * One folder of the machine, as the picker is showing it.
 *
 * `path` is the machine's own answer rather than something this phone built by
 * joining strings: it is the only side that knows whether its separator is `/`
 * or `\`, and a path assembled here would be wrong on exactly the machines this
 * feature exists for.
 *
 * `parent` is `nil` at the very top, which is what the "up" row is drawn from.
 */
struct FolderListing: Equatable {
    let path: String
    let parent: String?
    let entries: [FolderEntry]
}

struct FolderEntry: Equatable, Identifiable, Hashable {
    let name: String
    let path: String
    let readable: Bool
    let granted: Bool

    var id: String { path }
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

    /* ---- capability `folders.pick`. Never sent unless it was offered. ------ */

    /**
     * List the sub-folders of `path`, so somebody can walk to the one they want.
     *
     * `nil` means *somewhere sensible*, which the machine answers as the folder
     * this device already works in. The phone deliberately does not guess a
     * starting path: it does not know whether this machine's home is
     * `/Users/apple`, `/root` or `C:\Users\asad`, and a guess that is wrong opens
     * the picker on an error.
     */
    case browseFolders(path: String?)

    /* ---- capabilities `files`, `git`, `panels` ----------------------------- */

    /// What is in this folder — files as well as directories. The sibling of
    /// `browseFolders`: that one answers *where could a session start*, this
    /// answers *what is in here*.
    case filesList(path: String)
    /// One file's bytes, as text, capped. `at`/`max` let a phone read the start
    /// of a large file rather than be refused it; the next screen is a second
    /// read from the offset the host returned, never a bigger one.
    case filesRead(path: String, at: Int?, max: Int?)
    /// What git says about this folder. Both its answers — a repository, and a
    /// folder that is not one — are answers.
    case gitStatus(path: String)
    /// One file's diff. `file` is a path git itself reported, so it is always
    /// repository-root-relative.
    case gitDiff(path: String, file: String, staged: Bool)
    /// One of the four read-only panels. `path` nil means "somewhere sensible",
    /// which the host answers as this device's first granted folder.
    case panelRead(panel: String, path: String?, scope: String?, query: String?)
    /**
     * Do the thing a panel offered.
     *
     * The `action` is a string this build never interprets — it came off a
     * `PanelAction` the host itself sent in the last `panel.rows`, and it goes
     * straight back. That is what makes a panel able to grow a button without a
     * change here, and it is safe for exactly that reason: the phone can only
     * send an action it was handed.
     *
     * `id` names a row for a row's action and is nil for the panel's own.
     */
    case panelAct(panel: String, action: String, path: String?, id: String?, fields: [String: String])

    /* ---- capability `browser.control` -------------------------------------- */

    /// What the machine's browser has open, and which sessions could own one.
    case machineWindows
    /**
     * Open one there. `isolated` gives it a partition of its own that is thrown
     * away when the window closes.
     *
     * `session` opens it **and attaches it, in one move**, and it exists because
     * of the one page a phone can show that no machine window can ever be bound
     * to. A page opened *on this phone* is a web view over a port tunnel: it
     * lives in no browser on the machine, so it has no window id, so
     * `browser.window.bind` has nothing to name — and *Attach to a session* was
     * greyed out with a line explaining why. Asad asked for the greying to go —
     * *"we should have this attachment thing for all of them, properly
     * working"* — and the honest way to grant it is to re-open the same address
     * in the machine's own browser and attach **that** window.
     *
     * What was missing was the id. An open answers with the window *list*, and
     * picking the new row back out of it by comparing lists is a race two taps
     * apart — `browser-control.ts` records the same hack being removed one layer
     * down, where **two opens in flight each find both rows**. So the host keeps
     * the id inside itself and does the attach while it still holds it; this
     * field is how a client asks for that. The answer is still the window list,
     * and the notice on it is the *bind* notice, because what happened is a bind.
     */
    case machineWindowOpen(url: String?, profile: String?, isolated: Bool, session: String?)
    /// Send an open window somewhere.
    case machineWindowGo(id: String, url: String)
    /// Back, forward, reload, close, record on or off, share or isolate.
    case machineWindowAct(id: String, action: MachineBrowserWire.Act)
    /// Bind a window to a session so the agent in it knows which window is its
    /// own. A nil session unbinds — the same frame, which is deliberate: a
    /// client that meant to unbind and one whose field went missing are the same
    /// message, and unbinding is the harmless half of that pair.
    case machineWindowBind(id: String, session: String?)
    /// Photograph it. With a session, the picture is handed to that session
    /// rather than coming back here.
    case machineWindowShot(id: String, session: String?, note: String?)
    /// What the recorder has collected on that window so far.
    case machineWindowSteps(id: String)
    /**
     * What is at one point on that window's page — the tap that says *change this*.
     *
     * `x` and `y` are **document** coordinates: the same space `browser.frame`'s
     * `scrollX`/`scrollY` are in, so a viewer turns a tap on a picture into a
     * point on the page by adding the scroll of the frame it drew.
     * `MachinePick.documentPoint` is where this end does that, and it does it
     * with the frame's own numbers rather than with a guess at the geometry.
     *
     * Document rather than viewport, because the page can scroll between the
     * frame arriving and the tap landing, and a viewport point measured against
     * an old frame hits whatever has scrolled into that spot since. The host
     * converts back with the page's own live scroll and says plainly, in a
     * sentence, when the point is no longer on screen.
     *
     * `up` is how many ancestors to walk up from the element actually hit, and
     * it is the whole of Wider/Narrower. **It must never exceed
     * `MachineBrowserWire.maxPickUp`**: the host checks that range in its
     * *parser*, and a parse failure is answered by closing the socket rather
     * than by refusing the frame. Wider clamps here; see that constant.
     */
    case machineWindowPick(id: String, x: Double, y: Double, up: Int)

    /* ---- capability `browser.profiles` ------------------------------------- */

    /// List the machine's browser profiles and which it is using. No `rid`: all
    /// three verbs answer with the whole list, which is what lets the screen
    /// confirm itself rather than print a sentence.
    case browserProfiles
    /// Switch the machine's browser to this profile — it decides which jar the
    /// **next** page opens into.
    case browserProfileUse(id: String)
    /// Empty one profile's jar on the machine. Signs that machine's browser out
    /// of everything in it, and touches nothing this phone holds.
    case browserProfileClear(id: String)

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

    /*
     * The session's own bar, and the conversation behind it. See
     * `SessionWire.swift` for what each answer carries and why the reading is
     * narrowed on arrival.
     *
     * `rid` on all four because one socket can have a terminal, a copilot and
     * this bar asking three questions at once, and the request id is the only
     * thing that tells three answers apart.
     */

    /**
     * How full a plan window is, or a session's context, or go and find out.
     *
     * `force` is the same flag `want == .refresh` implies and is written anyway,
     * because it is the field the desktop actually reads and a client that let
     * the two disagree would ask for a cheap reading and be charged for the
     * expensive one. See `UsageWant` for what each costs over there.
     */
    case usageRead(rid: String, id: String, want: UsageWant, force: Bool)
    /// Which login this session runs as, and which others this machine has.
    case accountRead(rid: String, id: String)
    /**
     * Move this session onto another login.
     *
     * The far end decides whether it takes and answers `account.switched` either
     * way — including for a login belonging to a different agent, which it
     * refuses with a sentence this app does not draw. That is why the sheet
     * makes such a row unpressable rather than pressable-and-futile; see
     * `foreignAccount`.
     */
    case accountSwitch(rid: String, id: String, accountId: String)

    /* ---- sign-in. The one frame a connection may send before a `hello`. ----- */
    /**
     * Sign in with an account this machine already trusts, instead of a code.
     *
     * A port of `enroll` in `pwa/src/signin.ts`. Pre-authentication, over a
     * sealed channel only: the host verifies `username`+`secret` against its own
     * sshd on loopback, mints a pre-approved device bound to this connection's
     * key, and answers `enrolled` with a credential — which this client stores
     * and then presents in an ordinary `hello` on the *same* socket. `enroll`
     * never authenticates the socket itself.
     *
     * `secret` is a password when `method` is `.password` and a private-key PEM
     * when `.key`; the host chooses nothing from it, it only offers it to sshd.
     * `capabilities` mirrors `hello`'s so the follow-up hello need not
     * renegotiate, and grants nothing either way. There is no capability
     * guarding this frame — there is nothing to advertise before a welcome, and
     * a host too old to know it refuses `bad-message` and closes, which this
     * client reads as "too old for sign-in; update it or use a pairing code".
     */
    case enroll(protocolVersion: Int, device: DeviceDescriptor, username: String,
                secret: String, method: EnrollMethod, capabilities: [String])

    /* ---- capability `controls`. Never sent unless the desktop offered it. --- */
    /**
     * What is this session's model, effort, fast mode and permission right now?
     *
     * Passive: the far end reads its own screen and settings and answers
     * `controls.reading`. Nothing is typed. `rid` names this question — a split
     * window can ask twice over one session — and `id` is authorised at the same
     * door `input` is.
     */
    case controlsRead(rid: String, id: String)
    /**
     * Set one control on that session. **This types into the far terminal.**
     *
     * There is no command line here and there never must be: it names one of
     * `ControlName` and a value, and the far end composes the command itself.
     * Refused over there rather than negotiated here, and every path ends in a
     * `controls.applied` — silence is never an answer.
     */
    case controlsApply(rid: String, id: String, control: ControlName, value: String)

    /* ---- capability `settings`. The two settings this machine owns. -------- */
    /// Read this machine's two server-owned settings. No key: the whole small
    /// set, answered as `settings.state`. `rid` names the ask.
    case settingsRead(rid: String)
    /// Change one server-owned setting, over there. `key` is one of
    /// `ServerSettingKey`; `value` is stringly, `'true'`/`'false'` or a provider
    /// id. The outcome is `settings.applied`; every other listener hears
    /// `settings.changed`.
    case settingsApply(rid: String, key: ServerSettingKey, value: String)

    /* ---- capability `devices`. The roster, and the one verb that removes. --- */
    /// List every device signed in here. Answered with `devices.rows`.
    case devicesList(rid: String)
    /// Remove one device — revoke doubles as deny for a pending one. Self-revoke
    /// is sign-out: the socket closing after this frame is the confirmation.
    /// Answered with `devices.revoked`, unless the asker was the one removed.
    case devicesRevoke(rid: String, device: String)

    /* ---- capability `watch`. The live view, and the taps that come back. ---- */
    /// Watch a surface: start (or renegotiate) a screencast of it. `window` is
    /// `""` for the front/own tab, else a slot name. `maxWidth`/`quality` are
    /// this viewer's request, clamped host-side. Idempotent — re-sending it is
    /// how a resize renegotiates.
    case browserWatch(window: String, maxWidth: Int, quality: Int)
    /// Stop the screencast of one surface. The mirror of watch.
    case browserUnwatch(window: String)
    /// Rendered — send the next frame. The one-in-flight backpressure that ties
    /// the cast to this phone's real draw rate. `seq` echoes the frame drawn.
    case browserFrameAck(window: String, seq: Int)
    /// A tap, a key, a gesture or a paste aimed at the frame named by `seq`, so
    /// a scroll landing mid-gesture cannot desync the mapping. See `BrowserInput`.
    case browserInput(window: String, seq: Int, input: BrowserInput)
    /// Ask which surfaces are watchable — the browser's tab strip. Answered with
    /// `browser.surfaces.rows`, also pushed when the strip changes.
    case browserSurfaces(rid: String)

    /**
     * **Take the page the agent is asking about.**
     *
     * The phone saying *that person is me*. It does not weaken the curtain and
     * it does not move the baton away from `human`: every agent command stays
     * refused and every **other** watcher stays curtained. What changes is
     * scoped to this one connection — its frames come through unmasked and its
     * taps are dispatched — because it is now the hands the handover was waiting
     * for.
     *
     * Answered with `browser.handover.state` carrying this `rid`, and refused
     * when no handover is outstanding on that window or when this connection may
     * not already watch it.
     */
    case browserHandoverTake(rid: String, window: String)

    /**
     * **Hand it back**, and say which of the two things that means.
     *
     * `carryOn` is not a boolean's worth of politeness, it is two different
     * sentences ending in two different places: `true` is *done, keep going* —
     * the baton returns to the agent, the cast uncurtains for everybody, and the
     * blocked `browser.handover` call resolves. `false` is *stop, I'll take it
     * from here* — a refusal to the agent, which ends the drive rather than
     * resuming it. Both are drawn as buttons that say those words; neither is a
     * cancel.
     */
    case browserHandoverDone(rid: String, window: String, carryOn: Bool)
}

/// How a sign-in offers its secret. A password, or a private-key PEM — the host
/// chooses nothing from it, it only hands it to sshd. Mirrors `enroll.method`.
enum EnrollMethod: String, Equatable {
    case password
    case key
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
                 hostName: String?, folders: [String]?, copilot: CopilotConnection,
                 // What build the host is running, e.g. `0.10.0` — **absent
                 // means older**, and absent is its own answer: display text and
                 // nothing to act on, bounded and stripped on arrival. There is
                 // deliberately no update verb on this wire to pair it with;
                 // what it buys is the one honest sentence a client can say when
                 // its own build is ahead — *update this server from a desktop*.
                 appVersion: String?,
                 // Which shell is serving — desktop or headless. **Absent means
                 // older**, read as `.unknown`, which names the box neutrally
                 // rather than guessing.
                 hostKind: HostKind)
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

    /* ---- capability `folders.pick` --------------------------------------- */

    /**
     * One folder's sub-folders, in answer to a `folders.browse`.
     *
     * `path` is echoed by the machine rather than remembered here, because two
     * asks can be in flight after a fast double-tap and the second answer must
     * not be drawn under the first heading. `parent` is `nil` at the very top,
     * which is what the "up" row is drawn from — working it out on the phone
     * would mean a phone that knows where the root is on Windows.
     */
    case folderEntries(path: String, parent: String?, entries: [FolderEntry])

    /* ---- capabilities `files`, `git`, `panels` ----------------------------- */

    /// A folder's contents, directories first.
    case fileRows(FileListing)
    /// A file, as far as it was read. `truncated` is why this is not just a
    /// string; `binary` is the host's answer from the bytes rather than a guess
    /// from an extension.
    case fileText(FileText)
    /// What git said. A folder that is **not a repository** is a true thing
    /// about that folder, not an error — see `GitState`.
    case gitState(path: String, status: GitState)
    /// One file's diff as git printed it. Empty when there was nothing to show.
    case gitPatch(path: String, file: String, staged: Bool, patch: String)
    /// One panel's rows. A panel with nothing to say sends a `note` instead of
    /// an empty list, so "nothing configured" is not read as "failed to load".
    case panelRows(PanelData)
    /// What the machine's browser has open — the answer to every verb of the
    /// `browser.control` family except the two that carry a payload.
    case machineWindowRows(MachineBrowserState)
    /// A picture of one window, when it was not handed to a session instead.
    case machineShot(MachineShot)
    /// What the recorder collected on one window.
    case machineRecordRows(id: String, steps: [RecordedStep])
    /**
     * One element on a machine window's page — the answer to `browser.window.pick`.
     *
     * The third frame in this family that does not answer with the window list,
     * beside the picture and the recorder's steps, and for the same reason: it
     * carries something the phone asked for by name. Every *failure* still comes
     * back as the list with one sentence on it — nothing to point at, a page that
     * has scrolled, a machine whose browser cannot be reached into at all — which
     * is what stops a sheet spinning on a promise that will never be kept.
     *
     * `id` is the window, so a screen can ignore an answer about a window it is
     * no longer showing.
     */
    case machineWindowPicked(id: String, element: InspectedElement)
    /// The machine's profiles and which one its browser is using — the answer to
    /// all three verbs of the family.
    case browserProfileRows(MachineProfileList)
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

    /**
     * The answer to one `usage.read`, and only ever to one.
     *
     * The figures are narrowed on arrival rather than carried raw — see
     * `SessionWire.swift`. `nil` figures are drawn as **nothing at all**: no
     * chip, no placeholder, no sentence saying a machine did not report.
     */
    case usageReading(rid: String, id: String, want: UsageWant, figures: UsageFigures)
    /// The answer to one `account.read`. `current` is nil when the far end had
    /// none to give, which draws the chip's neutral dot rather than no chip.
    case accountState(rid: String, id: String, current: WireAccount?, accounts: [WireAccount])
    /**
     * What happened to one `account.switch`.
     *
     * The far end's sentence is deliberately **not** on this case. Whether it
     * took is what this screen acts on — it asks again rather than renaming the
     * chip itself — and the sentence would only ever become a line of prose on a
     * bar that has none.
     */
    case accountSwitched(rid: String, id: String, ok: Bool)

    /* ---- sign-in ---------------------------------------------------------- */
    /**
     * The device that was just signed in, with the credential to reconnect as.
     *
     * The answer to `enroll`, sent once, pre-authentication, over the sealed
     * channel only. `credential` is the plaintext bearer secret — the client
     * stores it and immediately sends a normal `hello` carrying it on the *same*
     * socket. A refused sign-in is the ordinary `error` frame instead. Mirrors
     * `enrolled` in `pwa/src/signin.ts`.
     */
    case enrolled(deviceId: String, deviceName: String, credential: String)

    /* ---- capability `controls` -------------------------------------------- */
    /// One session's whole control cluster, the answer to `controls.read`. `rid`
    /// and `id` are checked before it is drawn — see `SessionControlsLink`.
    case controlsReading(rid: String, id: String, reading: ControlsReadingWire)
    /// The outcome of one `controls.apply`, carrying the far end's own sentence
    /// and the reading it **re-read** off the session after the change settled —
    /// never the pressed value, which is what makes a refused apply revert.
    case controlsApplied(rid: String, id: String, ok: Bool, message: String, reading: ControlReadingWire)

    /* ---- capability `settings` -------------------------------------------- */
    /// The whole server-owned set, the answer to `settings.read`.
    case settingsState(rid: String, settings: [ServerSettingWire])
    /// The outcome of one `settings.apply`: the far end's sentence and the
    /// machine's own re-read of the row, so a refused apply reverts.
    case settingsApplied(rid: String, ok: Bool, message: String, setting: ServerSettingWire)
    /// Unsolicited — another device (or the desktop pane) changed one of these.
    /// No `rid`: it answers no ask.
    case settingsChanged(settings: [ServerSettingWire])

    /* ---- capability `devices` --------------------------------------------- */
    /// The device roster, the answer to `devices.list`.
    case devicesRows(rid: String, devices: [DeviceRosterRow])
    /// The outcome of one `devices.revoke`, with the roster as it stands after.
    case devicesRevoked(rid: String, ok: Bool, message: String, devices: [DeviceRosterRow])
    /// Unsolicited — the roster moved (a device joined, left, or connected). No
    /// `rid`: the same shape of push `settings.changed` gives.
    case devicesChanged(devices: [DeviceRosterRow])

    /* ---- capability `watch` ----------------------------------------------- */
    /// One screencast frame — a base64 JPEG and the geometry to draw and measure
    /// against it. `masked` is the handover curtain: `data` is empty and the
    /// viewer draws its own lock card. See `BrowserFrame`.
    case browserFrame(BrowserFrame)
    /// The watchable surfaces — an answer to `browser.surfaces` (with `rid`) and
    /// an unsolicited push when the strip changes (without).
    case browserSurfaces(rid: String?, surfaces: [BrowserSurfaceRow])
    /// Who holds the handover on one window: an answer to a `take` or a `done`
    /// of ours, and an unsolicited push to every watcher when the state moves.
    /// See `BrowserHandoverState`.
    case browserHandover(BrowserHandoverState)
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
