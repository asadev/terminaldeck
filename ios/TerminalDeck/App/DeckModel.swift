/**
 * Everything the screens read, and the only thing that talks to a transport.
 *
 * The split is the same one the desktop draws: the wire layer parses, this layer
 * decides, the views render. A view never sees a `ServerMessage` and never
 * builds a `ClientMessage`.
 *
 * ## One terminal per session, kept alive
 *
 * `bridges` outlives the terminal screen. Backing out of a session and returning
 * to it keeps its scrollback, which is what a person expects from something that
 * looks like a tab. What clears it is a re-attach — the desktop answers `attach`
 * by replaying the whole scrollback, and appending that to what is already there
 * would print every line twice.
 *
 * ## Wanted, and attached
 *
 * These are two different things and conflating them is the reason the first
 * version of this app came back from a dropped connection showing a dead
 * terminal. `wanted` is what the user has open. `attached` is what the desktop
 * has confirmed. A reconnect clears the second and not the first, and the gap
 * between them is exactly the set of `attach` frames to send when the socket
 * comes back — which is what makes walking into a lift and out again resume the
 * session instead of ending it.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class DeckModel {

    private(set) var connection: ConnectionState = .offline
    private(set) var sessions: [RemoteSession] = []
    /// Epoch-millisecond stamps, only for the sessions the desktop timestamped.
    private(set) var lastActivity: [String: Double] = [:]
    /// What is listening on the Mac. Empty until the desktop answers, and empty
    /// forever against a desktop that does not offer the `localhost` capability.
    private(set) var ports: [LocalPort] = []
    /// The one port being browsed, if any. One at a time on purpose: a phone
    /// shows one page, and a second listener held open for a tab nobody is
    /// looking at is a socket on the Mac with nothing watching it.
    private(set) var tunnel: PortTunnel?
    /// The file being sent, if any. One at a time, which is what the desktop
    /// accepts — see `send(_:into:)`.
    private(set) var upload: FileUpload?
    /// The navigation stack. `RootView` binds to it, and a deep link pushes onto it.
    var route: [Route] = []
    /// The last thing that went wrong, for the banner. Cleared on the next success.
    private(set) var lastError: String?

    /// Nil until this phone has been paired with a Mac. The pairing screen is
    /// shown off exactly this, so there is one source of truth for "am I set up".
    private(set) var credential: StoredCredential?
    /// Why the app is back at the pairing screen, when it did not start there.
    private(set) var pairingNotice: String?
    /// Set while a pairing code is being redeemed, so the button can say so.
    private(set) var isPairing = false

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private let makeTransport: (CredentialStore, DeviceDescriptor) -> Transport
    private var transport: Transport?
    /**
     * How a `PortTunnel` reaches the socket, without reaching this model.
     *
     * A tunnel needs exactly one thing — put this frame on the wire — and
     * conforming the model itself to `TunnelWire` would give every view in the
     * app a public `send(ClientMessage)`, which is the one boundary this file's
     * header says it keeps: a view never builds a wire message. One indirection
     * buys that back.
     */
    /// Not observed: `@Observable` rewrites a stored property into a computed
    /// one, and a computed property cannot be `lazy`.
    @ObservationIgnored
    private lazy var wire: TunnelWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }
    /// The same indirection for an upload, and the same reason: a `FileUpload`
    /// needs exactly one thing — put this frame on the wire — and conforming this
    /// model to the protocol directly would give every view a public
    /// `send(ClientMessage)`.
    @ObservationIgnored
    private lazy var uploadWire: UploadWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }
    private var bridges: [String: TerminalBridge] = [:]
    /// Confirmed by the desktop.
    private var attached: Set<String> = []
    /// Wanted by the user — a terminal screen is on the stack for it.
    private var wanted: Set<String> = []

    enum Route: Hashable {
        case session(String)
    }

    /// `makeTransport` is a seam for the tests, which drive this model against a
    /// scripted transport rather than a socket. Defaulted inside the body rather
    /// than in the signature: a default argument is evaluated outside the actor,
    /// and `LiveTransport` is main-actor isolated.
    init(credentials: CredentialStore,
         device: DeviceDescriptor,
         makeTransport: ((CredentialStore, DeviceDescriptor) -> Transport)? = nil) {
        self.credentials = credentials
        self.device = device
        self.makeTransport = makeTransport ?? { store, device in
            LiveTransport(device: device, credentials: store)
        }
        self.credential = credentials.load()
    }

    /// This phone's own fingerprint, for the approval prompt on the Mac. Shown
    /// on the pairing screen so the two ends can be compared by a person.
    var deviceFingerprint: String {
        sealedFingerprint(credentials.deviceKeys().publicKey)
    }

    var deviceName: String { device.name }

    var isPaired: Bool { credential != nil }

    /// Only true when the far end said it can. See `WireCapability`.
    var canCreateSessions: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.create) ?? false)
    }

    /**
     * Folders this phone may ask for a session in.
     *
     * The working directory of a session the Mac has already listed, and
     * nothing else. The Mac accepts only a folder it is already offering, so a
     * picker built from anything else would be offering choices that fail — and
     * this is the honest source, because every one of them is a row the user can
     * see. Empty is the normal state on a Mac with nothing running, and the
     * button then starts a session wherever the desktop would have.
     */
    var startableFolders: [String] {
        var seen = Set<String>()
        return sessions.compactMap { seen.insert($0.cwd).inserted ? $0.cwd : nil }
    }

    /// Whether this Mac can put its dev servers on this phone. Absent rather
    /// than disabled in the UI when false, for the same reason New Session is.
    var canBrowseLocalhost: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.localhost) ?? false)
    }

    /// Whether this Mac has somewhere to put a file. The Send buttons are hidden
    /// rather than disabled when it does not — a control that can only ever
    /// produce a refusal is not a control.
    var canSendFiles: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.upload) ?? false)
    }

    var endpointSummary: String? { credential?.endpoint.summary }

    // MARK: - Lifecycle

    func start() {
        guard credential != nil else { return }
        if transport == nil { buildTransport() }
        transport?.start()
    }

    /// The app came back to the foreground, or the network changed. The pending
    /// backoff is describing a condition that has already ended.
    func resume() {
        transport?.resume()
    }

    func refresh() {
        transport?.send(.list)
        // Asked for alongside the sessions rather than on a timer of its own.
        // The desktop's scan spawns `lsof`; polling it from a phone in a pocket
        // would run that on somebody's laptop every few seconds forever.
        if canBrowseLocalhost { transport?.send(.ports) }
    }

    private func buildTransport() {
        let transport = makeTransport(credentials, device)
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.transport = transport
    }

    // MARK: - Pairing

    /**
     * Redeem a pairing code.
     *
     * The code's token is stored as the credential straight away, marked
     * `.pairing`. That looks odd — it is a secret that is about to be spent —
     * and it is what makes the flow survive the app being killed halfway
     * through: the reconnect uses it, the desktop answers with the durable
     * credential, and `LiveTransport` swaps it in place. A token held only in
     * memory would leave a device that is paired on the Mac and unpaired here.
     */
    func pair(with rawCode: String) {
        pairingNotice = nil
        switch PairingCodeParser.parse(rawCode) {
        case let .failure(error):
            pairingNotice = error.detail
        case let .success(code):
            isPairing = true
            let stored = StoredCredential(endpoint: code.endpoint,
                                          token: code.token,
                                          kind: .pairing,
                                          deviceId: "",
                                          deviceName: device.name,
                                          pairedAt: Date())
            credentials.save(stored)
            credential = stored
            transport?.stop()
            buildTransport()
            transport?.start()
        }
    }

    /// Forget the Mac. Deliberately not "log out": the device key survives, so
    /// pairing with the same Mac again does not create a second entry in its
    /// device list for one physical phone.
    func unpair() {
        closeLocalhost()
        // Cancels the transfer and deletes the staged copy of the file. Forgetting
        // the Mac must not leave a photo sitting in this app's container.
        clearUpload()
        transport?.stop()
        transport = nil
        credentials.clear()
        credential = nil
        sessions = []
        ports = []
        lastActivity = [:]
        attached = []
        wanted = []
        bridges = [:]
        route = []
        connection = .offline
        lastError = nil
        isPairing = false
        pairingNotice = nil
    }

    // MARK: - Sessions

    func session(_ id: String) -> RemoteSession? {
        sessions.first { $0.id == id }
    }

    /// The terminal for a session, created on first use.
    func bridge(for id: String) -> TerminalBridge {
        if let existing = bridges[id] { return existing }
        let bridge = TerminalBridge()
        bridge.onInput = { [weak self] text in
            self?.sendInput(id, text)
        }
        bridge.onResize = { [weak self] cols, rows in
            self?.sendResize(id, cols: cols, rows: rows)
        }
        bridges[id] = bridge
        return bridge
    }

    /// Called when a terminal screen appears. Records the intent first, so a
    /// reconnect knows to re-attach even if the socket is down right now.
    func attach(_ id: String) {
        wanted.insert(id)
        rememberLastOpened(id)
        guard !attached.contains(id) else { return }
        // The size travels with the attach when the view has already measured
        // itself, so the first screenful arrives the right shape instead of
        // arriving at 80x25 and reflowing.
        if transport?.send(.attach(id: id, size: bridge(for: id).size)) != true {
            bridge(for: id).note(connection.detail)
        }
    }

    func detach(_ id: String) {
        wanted.remove(id)
        guard attached.contains(id) else { return }
        attached.remove(id)
        transport?.send(.detach(id: id))
    }

    /// Re-attach by hand, for the case where the automatic one cannot help —
    /// the connection came back while the screen was open and the desktop had
    /// already dropped the session's handle.
    func reattach(_ id: String) {
        attached.remove(id)
        bridges[id]?.clear()
        attach(id)
    }

    /**
     * Ask the desktop to start a session.
     *
     * Refuses rather than sends when the far end has not advertised `create`:
     * protocol v1 closes a socket on an unknown verb, so an unguarded button
     * here would drop the connection and look like the network.
     */
    func createSession(in folder: String?) {
        guard canCreateSessions else {
            lastError = "This desktop cannot start sessions from the phone."
            return
        }
        // Remembered so the `created` that comes back opens the session rather
        // than merely adding a row: the tap that started it is the tap that
        // opens it. Cleared on arrival, and by a refusal, so a `created` this
        // phone did not ask for — one it might one day be sent for another
        // reason — never yanks the user into a session.
        openWhenCreated = true
        // The phone does not choose an agent and does not name a title: the Mac
        // titles a session after its folder and picks its own default provider,
        // exactly as its own New Session button does. A picker here would be
        // offering choices this app has no honest way to know are available.
        transport?.send(.create(folder: folder, size: pendingSize))
    }

    /**
     * The size a session started from this phone should open at.
     *
     * The last size a terminal on this phone actually laid out at, so the first
     * screen of a new session arrives already the right shape instead of
     * arriving at 80x24 and reflowing — the same reason the size travels with
     * an `attach`. Nil before this phone has drawn a terminal at all, in which
     * case the Mac uses a plain 80x24 and the first `resize` fixes it.
     */
    private var pendingSize: TerminalSize? {
        bridges.values.compactMap(\.size).first
    }

    /// Set between asking for a session and being told about it. See `createSession`.
    private var openWhenCreated = false

    /// The session this phone was last looking at, if it is still running.
    /// Drives the Resume row, which is the difference between opening the app to
    /// a list and opening it to the thing you were watching.
    var resumable: RemoteSession? {
        guard let id = UserDefaults.standard.string(forKey: Self.lastOpenedKey),
              route.isEmpty,
              let session = sessions.first(where: { $0.id == id }),
              session.status != "exited" else { return nil }
        return session
    }

    private static let lastOpenedKey = "terminaldeck.lastSession.v1"

    private func rememberLastOpened(_ id: String) {
        // Not a secret: a session id is meaningless without a credential, and
        // the credential is in the Keychain.
        UserDefaults.standard.set(id, forKey: Self.lastOpenedKey)
    }

    func open(session id: String) {
        guard SessionID.isValid(id) else { return }
        if route.last != .session(id) { route.append(.session(id)) }
    }

    // MARK: - Localhost

    /**
     * Put a port on the Mac onto this phone, and hand back the tunnel to watch.
     *
     * **The tap is the consent.** There is no confirmation sheet and no setting
     * to switch on first: nothing on the Mac is reachable until this runs, it
     * only runs because a person touched a row, and `closeLocalhost` — which the
     * browser view calls when it goes away — ends it. A dialog here would ask
     * permission for the thing the tap already was.
     *
     * Returns nil only when the far end never offered the capability, which is
     * also the case in which no row exists to tap.
     */
    func openLocalhost(port: Int) -> PortTunnel? {
        guard canBrowseLocalhost else {
            lastError = "This desktop cannot show its local servers on a phone."
            return nil
        }
        // One at a time. The previous page is gone the moment this one opens, so
        // its listener and the Mac's socket go with it.
        closeLocalhost()
        let tunnel = PortTunnel(port: port, wire: wire)
        self.tunnel = tunnel
        tunnel.start()
        return tunnel
    }

    /// The browser view went away. Also called on unpair and on teardown.
    func closeLocalhost() {
        tunnel?.stop()
        tunnel = nil
    }

    // MARK: - Clipboard

    /**
     * Paste into the attached session.
     *
     * Routed through the terminal rather than straight at the wire, and that is
     * the whole of the fix this method used to need: `TerminalBridge.paste`
     * wraps the text in bracketed-paste markers when the far end asked for them,
     * so a multi-line paste into a coding CLI arrives as **one** prompt instead
     * of submitting on its first newline and running the rest as commands. The
     * bytes then come back out through `onInput`, which is the same path a
     * keystroke takes — so it is chunked to `maxInputBytes` and refused honestly
     * when the socket is down, both of which are already true there.
     *
     * Oversized pastes are refused with the numbers in the sentence rather than
     * being quietly shortened. Silently truncating a paste is the worst available
     * behaviour: the user sees the first half land, believes all of it did, and
     * the command that runs is a different command from the one they copied.
     */
    func paste(into id: String) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            lastError = "There is nothing on the clipboard."
            return
        }
        let bytes = text.utf8.count
        guard bytes <= Wire.maxPasteBytes else {
            lastError = "That paste is \(byteSize(bytes)). The most this can send at once is \(byteSize(Wire.maxPasteBytes))."
            return
        }
        guard let bridge = bridges[id] else {
            lastError = "That session is not open on this phone."
            return
        }
        bridge.paste(text)
    }

    /**
     * Copy the terminal's selection, or the visible screen when there is none.
     *
     * The fallback is not a shortcut, it is the feature: selecting text with a
     * fingertip on a phone is genuinely hard, and "copy what I am looking at" is
     * what people mean nine times out of ten. Long-pressing the terminal gives
     * the real selection for the other one.
     *
     * Returns a sentence because a copy that silently did nothing is the most
     * annoying kind of button, and because the sentence has to say *which* of
     * the two things happened — a Copy that took the whole screen when the user
     * had carefully selected one line is a bug they will not notice until they
     * paste it somewhere else.
     */
    @discardableResult
    func copy(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        if let selection = bridge.selectedText(), !selection.isEmpty {
            UIPasteboard.general.string = selection
            // Cleared, or every later Copy silently returns this same text
            // instead of the screen the user has moved on to. See `clearSelection`.
            bridge.clearSelection()
            return "Copied \(lineCount(selection)) from the selection."
        }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    /// Copy what is on screen, whatever is selected. What the actions menu
    /// offers, because a selection cannot survive the trip to that menu.
    @discardableResult
    func copyScreen(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    /// "1 line" / "12 lines". Named so the toast says what landed rather than
    /// only that something did.
    private func lineCount(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    // MARK: - Sending a file

    /**
     * Send a picked file to the Mac and type its path into a session.
     *
     * One at a time, which is what the desktop accepts and therefore what this
     * offers: a second Send while one is running would be refused over the wire,
     * and a button that produces a refusal is worse than one that is not there.
     *
     * The path is typed rather than run. `sendPath` puts a quoted path and a
     * trailing space into the prompt and stops — the user decides what the
     * command around it is, and nothing is submitted on their behalf.
     */
    func send(_ file: PickedFile, into sessionID: String) {
        guard canSendFiles else {
            lastError = "This desktop cannot receive files from a phone."
            return
        }
        guard upload == nil else {
            lastError = "One file at a time. Wait for the current one, or cancel it."
            return
        }
        guard file.size <= Wire.maxUploadBytes else {
            lastError = "That file is \(byteSize(file.size)). The most this can send is \(byteSize(Wire.maxUploadBytes))."
            // Nothing is going to read the staged copy now, and iOS only empties
            // `tmp` under storage pressure.
            if file.temporary { try? FileManager.default.removeItem(at: file.url) }
            return
        }

        let transfer = FileUpload(file: file, wire: uploadWire) { [weak self] path in
            self?.sendPath(path, into: sessionID)
        }
        upload = transfer
        transfer.start()
    }

    /// Dismiss a finished or failed transfer, and stop a running one.
    func clearUpload() {
        upload?.cancel()
        upload = nil
    }

    /**
     * Put a landed file's path into the prompt.
     *
     * Quoted, so a name with a space or an apostrophe is one word to the shell,
     * and followed by a space so the user can keep typing. **No newline** — the
     * same rule `composeSend`/`oneLine` enforce on the desktop, and for the same
     * reason: a newline into a coding CLI submits the prompt, and submitting on
     * somebody's behalf because their upload finished would be the app taking an
     * action nobody asked for.
     */
    private func sendPath(_ path: String, into sessionID: String) {
        guard let bridge = bridges[sessionID] else { return }
        // Through `paste` rather than raw, so the same control-byte stripping
        // applies. A path cannot contain a newline — the desktop refuses control
        // bytes in a name and builds the rest itself — but the one place a remote
        // string is typed into a terminal is not the place to assume that.
        bridge.paste("\(shellQuoted(path)) ")
    }

    // MARK: - Deep links

    /**
     * `terminaldeck://session/<id>` and `terminaldeck://pair?…`.
     *
     * The desktop opens a session on the phone the same way it opens the PWA: by
     * handing the OS a link. Both are checked before they go anywhere — a link
     * is the one input to this app that arrives from outside it, and an
     * unchecked id from one would end up in an `attach`.
     */
    func open(_ url: URL) {
        guard url.scheme?.lowercased() == Brand.id else { return }
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        guard let first = parts.first?.lowercased() else { return }

        if first == "pair" {
            pair(with: url.absoluteString)
            return
        }
        guard first == "session", parts.count >= 2 else { return }
        open(session: parts[1])
    }

    // MARK: - Outbound

    private func sendInput(_ id: String, _ text: String) {
        guard !text.isEmpty else { return }
        for chunk in WireCodec.chunkInput(text) {
            guard transport?.send(.input(id: id, data: chunk)) == true else {
                bridges[id]?.note("not sent — \(connection.detail)")
                return
            }
        }
    }

    private func sendResize(_ id: String, cols: Int, rows: Int) {
        // A size the desktop would refuse closes the socket, so it is dropped
        // here. A layout mid-transition really does produce a two-column
        // terminal for one frame.
        guard attached.contains(id), TerminalSize(cols: cols, rows: rows) != nil else { return }
        transport?.send(.resize(id: id, cols: cols, rows: rows))
    }

    // MARK: - Inbound

    private func handle(_ event: TransportEvent) {
        switch event {
        case let .state(state):
            let wasLive = connection.isLive
            connection = state
            if !state.isLive && wasLive {
                // The sessions this client thought it was attached to are gone
                // with the socket; the next connection has to attach again.
                attached.removeAll()
                for id in bridges.keys { bridges[id]?.note(state.detail) }
                // A tunnel cannot survive the connection carrying it, and a web
                // view left spinning on a socket that will never answer is the
                // exact failure this app is built not to have.
                tunnel?.connectionLost(state.detail)
                tunnel = nil
                ports = []
                // A transfer cannot survive the connection carrying it, and the
                // Mac deletes its half-written file on the same event. A bar
                // left creeping against a socket that will never answer is the
                // exact failure this app is built not to have.
                upload?.connectionLost(state.detail)
            }
            if state.isLive && !wasLive {
                isPairing = false
                // Everything the user still has open, re-attached without them
                // asking. `attached` was cleared above, so this is precisely the
                // set the desktop does not know about yet.
                for id in wanted {
                    bridges[id]?.note("reconnected — replaying")
                    attach(id)
                }
            }

        case let .credential(stored):
            credential = stored

        case let .needsPairing(reason):
            credential = nil
            transport = nil
            sessions = []
            attached = []
            isPairing = false
            pairingNotice = reason

        case let .message(message, activity):
            apply(message, activity: activity)
        }
    }

    private func apply(_ message: ServerMessage, activity: [String: Double]) {
        // A live tunnel gets first refusal. Byte frames are by far the chattiest
        // thing on this socket and they belong to one object; routing them here
        // would mean a second copy of its channel map, kept in step by hand.
        if tunnel?.receive(message) == true { return }
        // Uploads get the same treatment and for the same reason: the
        // acknowledgements are the chattiest thing on this socket during a
        // transfer and they belong to one object. Routing them here would mean a
        // second copy of its state, kept in step by hand.
        if upload?.receive(message) == true { return }

        switch message {
        case let .welcome(_, _, _, _, list, capabilities):
            sessions = list
            lastActivity = activity
            lastError = nil
            // Asked for as soon as the desktop says it can answer, so the list
            // is already on screen when the user looks rather than appearing a
            // beat later.
            if capabilities.contains(WireCapability.localhost) { transport?.send(.ports) }

        case let .sessions(list):
            sessions = list
            if !activity.isEmpty { lastActivity = activity }

        case let .created(session):
            // Put in the list here rather than waiting for the `sessions` frame
            // the Mac sends to *other* devices: this phone is told about its own
            // with the row, so that opening it needs no round trip.
            if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
            if !activity.isEmpty { lastActivity.merge(activity) { _, new in new } }
            lastError = nil
            if openWhenCreated {
                openWhenCreated = false
                open(session: session.id)
            }

        case let .attached(id):
            attached.insert(id)
            wanted.insert(id)
            // Whatever is on screen is about to arrive again as replay.
            bridges[id]?.clear()
            // The size, now that the desktop will accept one.
            //
            // The first attach of a session is sent from `onAppear`, before
            // SwiftUI has laid the terminal out, so it carries no size — and
            // the `sizeChanged` that follows a moment later was dropped by
            // `sendResize`, which refuses to resize a session this client is
            // not attached to yet. The result was a phone rendering a session
            // the desktop still believed was 80 columns wide: every long line
            // clipped at the right edge, which looked like a rendering bug and
            // was a race. Measured against the stand-in desktop, which logs the
            // size it is asked for.
            if let size = bridges[id]?.size {
                transport?.send(.resize(id: id, cols: size.cols, rows: size.rows))
            }

        case let .detached(id):
            attached.remove(id)

        case let .output(id, data, _):
            bridges[id]?.feed(data)

        case let .status(id, status):
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let old = sessions[index]
            sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                            provider: old.provider, status: status, exitCode: old.exitCode)

        case let .exit(id, code):
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                let old = sessions[index]
                sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                                provider: old.provider, status: "exited", exitCode: code)
            }
            bridges[id]?.note("session exited with code \(code)")

        case let .error(code, text):
            // In-session refusals arrive on a live socket and are about one
            // action, not about the connection; they belong next to the thing
            // that was refused, not in the connection banner.
            lastError = text.isEmpty ? code.rawValue : text
            // A refused request is not going to be followed by a `created`, and
            // a phone that stayed armed would jump into the *next* session it
            // was told about, whoever started it.
            openWhenCreated = false

        case let .ports(list):
            ports = list

        // Only reachable when no tunnel claimed them above, which means they
        // belong to one this phone has already forgotten — a close that crossed
        // with the last of its bytes. Nothing to do but not act on them.
        case .tunnelOpened, .tunnelClosed, .netData, .netAck, .netClose:
            break

        // Same again for an upload this phone has already forgotten: a cancel
        // that crossed with the last of its slices, or a `done` for a transfer
        // the user dismissed. Acting on one would restart a bar that is gone.
        case .uploadReady, .uploadAck, .uploadDone, .uploadFailed:
            break

        case .pong:
            break
        }
    }

    /// Clears the one-line error banner. The views call this when the user has
    /// plainly seen it — a banner that only time removes is a banner people
    /// learn to read past.
    func dismissError() {
        lastError = nil
    }
}

/// See `DeckModel.wire`. One class for both protocols, because they ask for the
/// same single method and a second identical proxy would be a second thing to
/// keep in step.
@MainActor
private final class WireProxy: TunnelWire, UploadWire {
    private let deliver: (ClientMessage) -> Bool

    init(_ deliver: @escaping (ClientMessage) -> Bool) {
        self.deliver = deliver
    }

    func send(_ message: ClientMessage) -> Bool {
        deliver(message)
    }
}
