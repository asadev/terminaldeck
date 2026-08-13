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

    /// The desktop can say what is listening on its own loopback, and tunnel a
    /// byte stream to one of those ports. One name for the whole feature: a
    /// desktop that could list ports but not open one would have nothing to
    /// show for it.
    static let localhost = "localhost"

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
    case hello(protocolVersion: Int, token: String, device: DeviceDescriptor)
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
    /// One browser connection on the phone's loopback listener. Only legal
    /// after the desktop has answered `tunnelOpen` with `tunnel.opened`.
    case netOpen(ch: String, tunnel: String)
    /// Bytes, base64 only on the wire — `WireCodec` does that, so nothing above
    /// it has to remember which representation it is holding.
    case netData(ch: String, data: Data)
    /// "I have written this many bytes to my socket." See `Wire.netWindowBytes`.
    case netAck(ch: String, bytes: Int)
    case netClose(ch: String)

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
}

enum ServerMessage: Equatable {
    /// `capabilities` is read defensively and defaults to empty: it is not in
    /// protocol v1, and a desktop that does not send it is telling the truth
    /// about itself by omission.
    case welcome(protocolVersion: Int, deviceId: String, deviceName: String, token: String?,
                 sessions: [RemoteSession], capabilities: Set<String>)
    case sessions([RemoteSession])
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

    /* ---- capability `localhost` ------------------------------------------ */

    case ports([LocalPort])
    case tunnelOpened(id: String, port: Int)
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
