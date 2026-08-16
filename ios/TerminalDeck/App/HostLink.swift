/**
 * One machine, and everything this phone knows about it.
 *
 * This is the object that used to *be* `DeckModel`. Splitting it out is the whole
 * of multi-host: the relay has always been a map of host ids and the protocol has
 * never had an opinion about what a host is — a phone genuinely cannot tell a Mac
 * from a Windows PC, because nothing on the wire says — so the only thing that
 * was ever single was the phone's own storage and the phone's own state. There is
 * now one of these per paired machine, and `DeckModel` holds the collection.
 *
 * ## What is *not* shared between hosts, and why that is free
 *
 * Everything below the transport. Each link owns its own `LiveTransport`, which
 * owns its own `Carrier`, which for a relay endpoint runs its own Noise IK
 * handshake against that host's static key. Two machines therefore cannot read
 * each other's sessions even though the same phone is talking to both: the keys
 * were never in the same place to begin with. That isolation costs nothing to
 * keep and would have to be deliberately dismantled to lose, which is why this
 * type has no notion of a "shared" anything.
 *
 * What *is* shared is the phone's static identity — one key, so a machine that
 * has approved this phone once has approved this phone — and the heartbeat tick,
 * so N sockets cost one radio wake-up rather than N. See `Heartbeat`.
 *
 * ## Wanted, and attached
 *
 * Two different things, and conflating them is why the first version of this app
 * came back from a dropped connection showing a dead terminal. `wanted` is what
 * the user has open. `attached` is what the host has confirmed. A reconnect
 * clears the second and not the first, and the gap between them is exactly the
 * set of `attach` frames to send when the socket comes back.
 */

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class HostLink: Identifiable {

    /// Which machine this is. Stable across re-pairings, and the key everything
    /// above this object uses to name it.
    let id: String

    /// What this phone holds about the machine. Replaced in place when the host
    /// mints a durable credential or the user renames it.
    private(set) var credential: StoredCredential

    private(set) var connection: ConnectionState = .offline

    /**
     * Whether this machine's connection is worth putting on screen, which is not
     * the same question as what its connection *is*.
     *
     * `ConnectionGrace` holds the whole rule and says why. What matters here is
     * that it lives on the machine rather than on a screen: a link that has been
     * down for a minute must not get a fresh five seconds of silence every time
     * somebody navigates back to the list, and the pill, the list's banner and a
     * terminal's banner must not each have their own opinion about whether now
     * is the moment to say something.
     */
    let notice: ConnectionNotice

    private(set) var sessions: [RemoteSession] = []
    /// Epoch-millisecond stamps, only for the sessions the host timestamped.
    private(set) var lastActivity: [String: Double] = [:]
    /// What is listening on this machine. Empty against a host that does not
    /// offer the `localhost` capability.
    private(set) var ports: [LocalPort] = []
    /// The one port being browsed on this machine, if any.
    private(set) var tunnel: PortTunnel?
    /// The file on its way to this machine, if any.
    private(set) var upload: FileUpload?
    /// The last thing that went wrong here. Cleared on the next success.
    private(set) var lastError: String?
    /// What kind of machine this is, as the host itself said in its `welcome`.
    ///
    /// Per host and not global: one phone holds several machines at once, and a
    /// Mac and a Windows PC are routinely both in that list. A single app-wide
    /// value would be right for whichever was greeted last and wrong for the
    /// other — which is a subtler version of the constant string it replaces.
    private(set) var hostPlatform: HostPlatform = .unknown

    /// What the switcher shows. The user's name for the machine, or its address.
    var label: String { credential.label }

    /**
     * Told about a credential the host minted, so the collection on disk can be
     * updated without this object reaching into the store itself.
     *
     * A link that wrote to the Keychain directly would be N writers to one
     * drawer, and the one bug that must not exist here is a write for one host
     * that lands on another.
     */
    var onCredential: ((StoredCredential) -> Void)?
    /// This machine refused the credential for good. The link is about to be torn
    /// down; the sentence says why.
    var onNeedsPairing: ((String) -> Void)?
    /**
     * The connection changed.
     *
     * The collection needs this for one thing: knowing when a redemption is over,
     * whichever way it went. Without it `isPairing` is set by `pair` and cleared
     * by nobody — the Pair button then reads "Pairing…" and stays *disabled*
     * forever, so the next machine cannot be added at all. That is not a
     * hypothetical: it is what the two-host UI test found, and the symptom was a
     * sheet that would not close rather than a button that would not press.
     */
    var onConnectionChange: ((ConnectionState) -> Void)?
    /// A session was started on this machine at this phone's request.
    var onCreated: ((String) -> Void)?

    /**
     * The session list on this machine changed.
     *
     * Every path that can change a status goes through here — the whole list,
     * one `status` frame, an `exit`, a session this phone asked for — because
     * the thing above is watching for *transitions* and a transition missed is
     * an alert that never fires. See `SessionAlerts`.
     *
     * The reason distinguishes a change that happened while this phone was
     * listening from the first list after a connection came back, which is a
     * catch-up: what is in it happened while nothing here was running.
     */
    var onSessionsChanged: (([RemoteSession], AlertReason) -> Void)?

    /**
     * Git on this machine wants a GitHub login, and this phone is the thing
     * holding one.
     *
     * Handed straight up rather than answered here, because the answer is not a
     * per-machine decision: there is one account on this phone, one question on
     * screen at a time, and a person looking at two machines must not be asked
     * two things at once by two objects that do not know about each other. See
     * `CredentialResponder`.
     */
    var onCredentialRequest: ((CredentialRequest) -> Void)?

    private let credentials: CredentialStore
    private let device: DeviceDescriptor
    private var transport: Transport?
    private let makeTransport: (String, CredentialStore, DeviceDescriptor) -> Transport

    /// How a `PortTunnel` reaches the socket without reaching this object's API.
    /// One indirection buys back the rule that a view never builds a wire message.
    @ObservationIgnored
    private lazy var wire: TunnelWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }
    @ObservationIgnored
    private lazy var uploadWire: UploadWire = WireProxy { [weak self] message in
        self?.transport?.send(message) ?? false
    }

    private var bridges: [String: TerminalBridge] = [:]
    /// Confirmed by the host.
    private var attached: Set<String> = []
    /// Wanted by the user — a terminal screen is on the stack for it.
    private var wanted: Set<String> = []
    /// Set between asking this machine for a session and being told about it.
    private var openWhenCreated = false
    /// Lines from inspect mode waiting for their session to finish attaching.
    private var pendingAgentLines: [String: [String]] = [:]

    /// `notice` is a seam for the tests in the same way `makeTransport` is: the
    /// real one holds a clock and a timer, and a test hands in one whose clock it
    /// controls so five seconds can pass without five seconds passing.
    init(credential: StoredCredential,
         credentials: CredentialStore,
         device: DeviceDescriptor,
         makeTransport: ((String, CredentialStore, DeviceDescriptor) -> Transport)? = nil,
         notice: ConnectionNotice? = nil) {
        self.id = credential.hostId
        self.credential = credential
        self.credentials = credentials
        self.device = device
        self.notice = notice ?? ConnectionNotice()
        // Defaulted inside the body rather than in the signature: a default
        // argument is evaluated outside the actor, and `LiveTransport` is
        // main-actor isolated.
        self.makeTransport = makeTransport ?? { hostId, store, device in
            LiveTransport(hostId: hostId, device: device, credentials: store)
        }
    }

    // MARK: - Capabilities

    /// Only true when this machine said it can. See `WireCapability`.
    var canCreateSessions: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.create) ?? false)
    }

    var canBrowseLocalhost: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.localhost) ?? false)
    }

    var canSendFiles: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.upload) ?? false)
    }

    /**
     * Whether git on this machine may ask **this phone** for a login.
     *
     * The one capability that runs backwards, so this is not a button being
     * gated — it is whether a sentence on the session sheet is true. A machine
     * that never advertised `credential` will never ask, and telling somebody
     * their GitHub account answers pushes from a machine that cannot ask would
     * be a promise nothing here can keep.
     */
    var canAskForGitLogins: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.credential) ?? false)
    }

    /**
     * Whether this machine will discuss its projects' dev servers.
     *
     * Its own capability rather than part of `canBrowseLocalhost`, and the two
     * genuinely come apart: every desktop can tunnel a port, while starting a
     * dev server needs a session layer that can start a session *and* a folder
     * this device was granted. A host can offer either without the other, and
     * the public demo box offers neither.
     */
    var canUseDevServers: Bool {
        connection.isLive && (transport?.capabilities.contains(WireCapability.devserver) ?? false)
    }

    var endpointSummary: String { credential.endpoint.summary }

    /**
     * Folders this phone may ask for a session in **on this machine**.
     *
     * Two sources, and which one is in use is decided by the desktop rather than
     * by this app:
     *
     *  - **What the machine granted this device.** `welcome.folders`, kept
     *    current by the pushed `folders` frame. It is the same array the desktop
     *    enforces against — one function answers both questions over there — so
     *    a folder on this list is a folder that will actually start, subject
     *    only to it still existing.
     *  - **The working directories already on screen**, for a desktop old enough
     *    not to have said. That was the only source before grants existed, and
     *    the two were never the same set: the picker offered one folder while
     *    the Mac would have accepted several, and nothing on either screen
     *    explained why.
     *
     * Per host by construction: offering a Mac's folder to a Windows PC would be
     * a picker full of choices that fail.
     */
    var startableFolders: [String] {
        if let granted { return granted }
        var seen = Set<String>()
        return sessions.compactMap { seen.insert($0.cwd).inserted ? $0.cwd : nil }
    }

    /**
     * What this machine says this device may use, or nil if it has never said.
     *
     * Nil is a desktop that predates the field. **Empty is a person choosing
     * none**, which is why this is not flattened to `[]` on arrival: the two
     * lead to different screens, and collapsing them would put the older
     * desktop's phone in front of the newer desktop's "no folders" message.
     */
    private(set) var granted: [String]?

    /// Whether a session can be started at all right now. The capability says
    /// the machine *can*; an empty grant says this device *may not*, and a
    /// button that is only ever refused is not a button.
    var canStartSomewhere: Bool {
        canCreateSessions && granted?.isEmpty != true
    }

    // MARK: - Lifecycle

    func start() {
        // The grace period starts here rather than at the first state event, so
        // that the five seconds cover the dial itself. A transport that is slow
        // to say anything at all is exactly the case the rule is written for.
        notice.observe(connection)
        if transport == nil { build() }
        transport?.start()
    }

    /// The app came back to the foreground, or the network changed.
    func resume() {
        // A suspended app runs no timers, so the notice may be holding a
        // deadline that passed while the phone was in a pocket. See
        // `ConnectionNotice.refresh`.
        notice.refresh()
        transport?.resume()
    }

    func refresh() {
        transport?.send(.list)
        // Asked for alongside the sessions rather than on a timer of its own.
        // The host's scan spawns `lsof`; polling it from a phone in a pocket
        // would run that on somebody's laptop every few seconds forever.
        if canBrowseLocalhost { transport?.send(.ports) }
        // Pull-to-refresh, and nothing else, asks these again. A dev server's
        // changes are *pushed* — see `askDevServers` — so a timer here would be
        // this app polling a question the desktop is already answering, which is
        // the one thing the frame's own documentation asks clients not to do.
        // What a pull genuinely fixes is a folder whose reply was lost with a
        // socket the app has since replaced.
        askDevServers()
    }

    /// Take this machine down without forgetting it — the app is closing, or the
    /// user is unpairing and the store is about to be written by someone else.
    func stop() {
        closeLocalhost()
        clearUpload()
        transport?.stop()
        transport = nil
        sessions = []
        ports = []
        // The subscription these rows were kept alive by belonged to the socket
        // that is being dropped. Keeping them would leave a `starting` spinner
        // over a folder nothing is going to report on again.
        devServers = [:]
        lastActivity = [:]
        // Back to "this machine has not said", not to "this machine granted
        // nothing". The grant belongs to a live connection, and remembering an
        // empty one across a stop would leave a phone refusing to offer New
        // Session on a machine that has simply not been asked yet.
        granted = nil
        attached = []
        wanted = []
        bridges = [:]
        pendingAgentLines = [:]
        connection = .offline
        // Told rather than reset. A machine that is being torn down and brought
        // straight back up — which is what re-pairing does — is one continuous
        // outage from the person's point of view, so the clock that was already
        // running keeps running.
        notice.observe(connection)
        lastError = nil
    }

    func rename(_ name: String?) {
        credential = credential.renamed(name)
        onCredential?(credential)
    }

    private func build() {
        let transport = makeTransport(id, credentials, device)
        transport.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.transport = transport
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

    func reattach(_ id: String) {
        attached.remove(id)
        bridges[id]?.clear()
        attach(id)
    }

    func createSession(in folder: String?) {
        guard canCreateSessions else {
            lastError = "\(label) cannot start sessions from the phone."
            return
        }
        openWhenCreated = true
        transport?.send(.create(folder: folder, size: pendingSize))
    }

    private var pendingSize: TerminalSize? {
        bridges.values.compactMap(\.size).first
    }

    /**
     * The session this phone was last looking at **on this machine**, if it is
     * still running.
     *
     * Per host and stored per host, which is the difference between a Resume row
     * that means something and one that offers the wrong machine's work: with two
     * machines paired, a single remembered id would follow the user across the
     * switcher and point at a session the host in front of them has never heard
     * of.
     */
    var resumable: RemoteSession? {
        guard let id = UserDefaults.standard.string(forKey: lastOpenedKey),
              let session = sessions.first(where: { $0.id == id }),
              session.status != "exited" else { return nil }
        return session
    }

    private var lastOpenedKey: String { "terminaldeck.lastSession.v2.\(id)" }

    private func rememberLastOpened(_ sessionId: String) {
        // Not a secret: a session id is meaningless without a credential, and
        // the credential is in the Keychain.
        UserDefaults.standard.set(sessionId, forKey: lastOpenedKey)
    }

    // MARK: - Localhost

    /**
     * Put a port on this machine onto the phone, and hand back the tunnel.
     *
     * **The tap is the consent.** Nothing on the machine is reachable until this
     * runs, it only runs because a person touched a row, and `closeLocalhost` —
     * which the browser view calls when it goes away — ends it.
     */
    func openLocalhost(port: Int) -> PortTunnel? {
        guard canBrowseLocalhost else {
            lastError = "\(label) cannot show its local servers on a phone."
            return nil
        }
        closeLocalhost()
        let tunnel = PortTunnel(port: port, wire: wire)
        self.tunnel = tunnel
        tunnel.start()
        return tunnel
    }

    func closeLocalhost() {
        tunnel?.stop()
        tunnel = nil
    }

    // MARK: - Dev servers

    /**
     * One row per project folder, **keyed by the folder the desktop named**.
     *
     * A dictionary rather than an array because of the one rule this feature
     * cannot get wrong: a `dev.state` **replaces** the row for its folder and
     * never merges into it. The fields on a report are not independent — `port`
     * and `url` exist only on `ready`, `message` only on `failed` — so a merge
     * leaves a dead address sitting under a live row, which the protocol calls
     * the one genuinely wrong thing a client of this frame can display. A
     * subscript assignment cannot do anything else, which is why it is a
     * dictionary of whole values rather than a mutable row somebody updates.
     *
     * The key is the desktop's spelling of the folder, taken off the frame,
     * never the string this phone sent: the two can differ by a trailing
     * separator or by case on Windows and still be the same directory. That
     * matches, because every folder this app can name came out of
     * `welcome.folders` — the desktop's own list — so the string it sends and
     * the string that comes back are the same string.
     *
     * Cleared with the connection, deliberately: pushes stop when the socket
     * does, so a `starting` row kept across a drop would spin forever
     * describing a moment that has passed.
     */
    private(set) var devServers: [String: DevServerReport] = [:]

    /**
     * How many folders this connection will ask about.
     *
     * The desktop's `MAX_DEV_FOLDERS`, mirrored. It is not a display limit: the
     * desktop *answers* a `dev.status` for any granted folder but only
     * **subscribes** the first eight, so a ninth would get one reply and then go
     * quiet — a row that says `starting` and never changes again, which is worse
     * than a row that is not there. Asking for what will be pushed keeps every
     * row on screen live.
     */
    static let maxDevFolders = 8

    /**
     * The folders this phone will ask about, in the order the desktop offered
     * them — most relevant first, which is what makes the cap land on the ones
     * least likely to be looked at.
     *
     * Read from `granted` rather than from `startableFolders`, and the
     * difference matters only in the case that should never happen. Those two
     * are the same list whenever a machine has said anything about folders;
     * where they differ is the fallback, which invents a list out of the working
     * directories of sessions this phone can see. That fallback is right for the
     * New Session picker — it is what a desktop older than per-device grants
     * would have accepted — and it is wrong here, because this capability is
     * authorised against the grant list and nothing else. A machine that somehow
     * advertised `devserver` without sending a grant would be asked about
     * folders it never offered, and every one of those questions comes back as
     * an `unauthorized` error banner on the session list. Nil means "I have not
     * been told", and the honest thing to do with that is ask nothing.
     */
    var devFolders: [String] {
        guard canUseDevServers, let granted else { return [] }
        return Array(granted.prefix(Self.maxDevFolders))
    }

    /**
     * The rows worth drawing, in the desktop's own order.
     *
     * `noDevScript` folders are filtered out here rather than in the view, and
     * that is the protocol's rule rather than a layout choice: it means "there is
     * nothing to press, and there never will be for this folder". A row for one
     * could only ever carry a button whose single possible outcome is a refusal.
     * A folder that has not answered yet has no row either — there is nothing
     * true to say about it until it does.
     */
    var devServerRows: [DevServerReport] {
        devFolders.compactMap { devServers[$0] }.filter { $0.status != .noDevScript }
    }

    func devServer(for folder: String) -> DevServerReport? {
        devServers[folder]
    }

    /**
     * Ask about every folder, which is also what subscribes to them.
     *
     * Called on each `welcome` rather than once, because the subscription lives
     * on the desktop's *connection*: a reconnect is a new connection and knows
     * nothing about what the last one was watching. Called again when the grant
     * list changes, because a folder added on the desktop has never been asked
     * about at all.
     */
    func askDevServers() {
        guard canUseDevServers else { return }
        for folder in devFolders { transport?.send(.devStatus(folder: folder)) }
    }

    /**
     * Start one project's dev server. **The tap is the consent.**
     *
     * Nothing runs on the far machine because of this feature until this is
     * sent. There is no queue and no retry: the desktop answers immediately with
     * `starting` and then pushes every change, so a press that does not reach
     * the socket is a press that did nothing, and saying so is better than a row
     * that spins over a message that was never sent.
     */
    func startDevServer(in folder: String) {
        guard canUseDevServers else {
            lastError = "\(label) cannot start dev servers from the phone."
            return
        }
        guard transport?.send(.devStart(folder: folder)) == true else {
            lastError = "Not connected — \(label) was not asked to start that."
            return
        }
    }

    // MARK: - Clipboard

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

    @discardableResult
    func copy(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        if let selection = bridge.selectedText(), !selection.isEmpty {
            UIPasteboard.general.string = selection
            bridge.clearSelection()
            return "Copied \(lineCount(selection)) from the selection."
        }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    @discardableResult
    func copyScreen(from id: String) -> String {
        guard let bridge = bridges[id] else { return "Nothing to copy." }
        let screen = bridge.visibleText()
        guard !screen.isEmpty else { return "Nothing to copy." }
        UIPasteboard.general.string = screen
        return "Copied \(lineCount(screen)) from the screen."
    }

    private func lineCount(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines == 1 ? "1 line" : "\(lines) lines"
    }

    // MARK: - Sending a file

    func send(_ file: PickedFile, into sessionID: String) {
        guard canSendFiles else {
            lastError = "\(label) cannot receive files from a phone."
            return
        }
        guard upload == nil else {
            lastError = "One file at a time. Wait for the current one, or cancel it."
            return
        }
        guard file.size <= Wire.maxUploadBytes else {
            lastError = "That file is \(byteSize(file.size)). The most this can send is \(byteSize(Wire.maxUploadBytes))."
            if file.temporary { try? FileManager.default.removeItem(at: file.url) }
            return
        }

        let transfer = FileUpload(file: file, wire: uploadWire) { [weak self] path in
            self?.sendPath(path, into: sessionID)
        }
        upload = transfer
        transfer.start()
    }

    func clearUpload() {
        upload?.cancel()
        upload = nil
    }

    /**
     * Put a landed file's path into the prompt.
     *
     * Quoted, so a name with a space or an apostrophe is one word to the shell,
     * and followed by a space so the user can keep typing. **No newline** — the
     * same rule `Inspect.composeSend` enforces, and for the same reason.
     */
    private func sendPath(_ path: String, into sessionID: String) {
        guard let bridge = bridges[sessionID] else { return }
        bridge.paste("\(shellQuoted(path)) ")
    }

    // MARK: - Inspect mode

    /// Sessions on this machine an inspected element can be described to.
    var agentTargets: [RemoteSession] {
        sessions.filter { $0.status != "exited" }
    }

    /**
     * Where the next inspected element goes **on this machine**.
     *
     * The desktop has a focused session and sends there. The browser screen was
     * opened from a list, so the answer has to be worked out — and the honest
     * default is the session this phone was last looking at here, which is nine
     * times out of ten the agent building the page being inspected.
     */
    var agentTarget: String? {
        get {
            let running = agentTargets
            if let chosen = chosenAgentTarget, running.contains(where: { $0.id == chosen }) { return chosen }
            if let remembered = UserDefaults.standard.string(forKey: lastOpenedKey),
               running.contains(where: { $0.id == remembered }) { return remembered }
            return running.first?.id
        }
        set { chosenAgentTarget = newValue }
    }

    private var chosenAgentTarget: String?

    /**
     * Type one line describing an element into a session on this machine.
     *
     * **No newline, ever.** `Inspect.composeSend` has already flattened the whole
     * thing to a single line for exactly this reason: a newline into a coding CLI
     * submits the prompt, and submitting on somebody's behalf because they
     * described a button is the app taking an action nobody asked for.
     *
     * Sent raw rather than through `paste`, deliberately: `paste` wraps text in
     * bracketed-paste markers, and this line has to be byte-identical to the one
     * the desktop hands the same agent.
     */
    @discardableResult
    func sendToAgent(_ line: String, into id: String) -> String {
        guard !line.isEmpty else { return "There was nothing to send." }
        guard let session = session(id) else { return "That session is not on \(label) any more." }
        guard connection.isLive else { return "Not connected — that did not reach \(label)." }

        if attached.contains(id) {
            sendInput(id, line)
            return "Sent to \(session.title)."
        }

        /*
         * The host refuses `input` for a session this device has not attached to
         * — `server.ts` answers it with `unauthorized` — so the attach comes
         * first and the line waits for the confirmation.
         *
         * The session stays attached afterwards rather than being detached
         * again. It is not a leak: the user just told an agent to change
         * something, and the next thing they will want is to watch it do that.
         */
        pendingAgentLines[id, default: []].append(line)
        attach(id)
        expireAgentLine(id)
        return "Opening \(session.title) to send it…"
    }

    /// Anything held for a session the host never confirmed. Twelve seconds is
    /// far longer than an attach takes and short enough that nobody is still
    /// waiting; the alternative is a line that silently never arrives.
    private func expireAgentLine(_ id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.pendingAgentLines[id] != nil else { return }
            self.pendingAgentLines[id] = nil
            self.lastError = "That session did not open, so the change was not sent."
        }
    }

    private func flushAgentLines(_ id: String) {
        guard let lines = pendingAgentLines.removeValue(forKey: id) else { return }
        for line in lines { sendInput(id, line) }
    }

    // MARK: - Credentials

    /**
     * Answer a credential question this machine asked.
     *
     * A narrow door on purpose. Everything else in this app reaches the socket
     * through a method that names what it is doing, and the one thing that must
     * not appear is a general "send this frame" seam that a view could reach —
     * the prompt *is* a view. `CredentialAnswer` has three cases and every one
     * of them carries an id the desktop minted, so nothing can be said through
     * here that was not asked for.
     *
     * The reply is dropped when the socket is down rather than queued. There is
     * nothing to queue for: the desktop settles a request the moment its own
     * connection to this device goes, and a reply arriving on a later socket
     * would be answering a question that no longer exists.
     */
    func answer(_ answer: CredentialAnswer) {
        transport?.send(answer.message)
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
        guard attached.contains(id), TerminalSize(cols: cols, rows: rows) != nil else { return }
        transport?.send(.resize(id: id, cols: cols, rows: rows))
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Inbound

    private func handle(_ event: TransportEvent) {
        switch event {
        case let .state(state):
            let wasLive = connection.isLive
            connection = state
            // Every state, including the ones that change nothing on screen.
            // The rule is a function of the whole sequence, not of the
            // interesting parts of it — see `ConnectionGrace.unsettledSince`.
            notice.observe(state)
            onConnectionChange?(state)
            if !state.isLive && wasLive {
                attached.removeAll()
                for id in bridges.keys { bridges[id]?.note(state.detail) }
                tunnel?.connectionLost(state.detail)
                tunnel = nil
                ports = []
                // Same reason the ports go: these rows are only true while
                // something is pushing them, and a spinner nobody is going to
                // update is a screen that lies about what the machine is doing.
                // They come back on the next `welcome`, which re-subscribes.
                devServers = [:]
                upload?.connectionLost(state.detail)
            }
            if state.isLive && !wasLive {
                for id in wanted {
                    bridges[id]?.note("reconnected — replaying")
                    attach(id)
                }
            }

        case let .credential(stored):
            credential = stored
            onCredential?(stored)

        case let .needsPairing(reason):
            transport = nil
            sessions = []
            attached = []
            onNeedsPairing?(reason)

        case let .message(message, activity):
            apply(message, activity: activity)
        }
    }

    private func apply(_ message: ServerMessage, activity: [String: Double]) {
        // A live tunnel gets first refusal. Byte frames are by far the chattiest
        // thing on this socket and they belong to one object.
        if tunnel?.receive(message) == true { return }
        if upload?.receive(message) == true { return }

        switch message {
        case let .welcome(_, _, _, _, list, capabilities, platform, folders):
            sessions = list
            lastActivity = activity
            lastError = nil
            hostPlatform = platform
            granted = folders
            if capabilities.contains(WireCapability.localhost) { transport?.send(.ports) }
            // After `granted` is set, because the folders this asks about are
            // read from it — and on every welcome, because the desktop's
            // subscription belongs to the connection this welcome arrived on.
            askDevServers()
            // A welcome is by definition the first list on a new connection, so
            // whatever changed in it changed while this phone was not attached.
            onSessionsChanged?(sessions, .catchUp)

        case let .sessions(list):
            sessions = list
            if !activity.isEmpty { lastActivity = activity }
            onSessionsChanged?(sessions, .live)

        case let .folders(list):
            // Whole list, not a delta. A folder removed on the desktop stops
            // being offered here without a reconnect, which is the only way the
            // picker and the rule the Mac enforces can stay the same thing.
            granted = list
            /*
             * A folder that has just been taken away must lose its row, and it
             * must lose it here rather than by being filtered out at the point
             * of drawing.
             *
             * `devServerRows` does read through `devFolders`, so a dropped
             * folder does disappear from the screen either way — but the state
             * would still be sitting in this dictionary, and a folder that is
             * granted again a minute later would come back showing whatever it
             * was doing before it was revoked, with no `dev.status` yet sent to
             * say whether that is still true.
             */
            let keep = Set(list)
            devServers = devServers.filter { keep.contains($0.key) }
            // And a folder that has just been *added* has never been asked
            // about. Asking again for the ones already known costs one frame
            // each and re-subscribes them, which is harmless — the answer is
            // the state they are already showing.
            askDevServers()

        case let .created(session):
            if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
            if !activity.isEmpty { lastActivity.merge(activity) { _, new in new } }
            lastError = nil
            if openWhenCreated {
                openWhenCreated = false
                onCreated?(session.id)
            }
            onSessionsChanged?(sessions, .live)

        case let .attached(id):
            attached.insert(id)
            wanted.insert(id)
            bridges[id]?.clear()
            if let size = bridges[id]?.size {
                transport?.send(.resize(id: id, cols: size.cols, rows: size.rows))
            }
            // A line from inspect mode that was waiting for exactly this. Sent
            // after the resize so the agent's prompt box is already the right
            // width when the text lands in it.
            flushAgentLines(id)

        case let .detached(id):
            attached.remove(id)

        case let .output(id, data, _):
            bridges[id]?.feed(data)

        case let .status(id, status):
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            let old = sessions[index]
            sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                            provider: old.provider, status: status, exitCode: old.exitCode)
            // The frame that carries most of the alerts: `working` → `waiting`
            // is a desktop saying an agent has stopped and wants somebody.
            onSessionsChanged?(sessions, .live)

        case let .exit(id, code):
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                let old = sessions[index]
                sessions[index] = RemoteSession(id: old.id, title: old.title, cwd: old.cwd,
                                                provider: old.provider, status: "exited", exitCode: code)
                onSessionsChanged?(sessions, .live)
            }
            bridges[id]?.note("session exited with code \(code)")

        case let .error(code, text):
            lastError = text.isEmpty ? code.rawValue : text
            openWhenCreated = false

        case let .ports(list):
            ports = list

        case let .devState(report):
            /*
             * Replace. Never merge.
             *
             * A subscript assignment of a whole value is the entire enforcement
             * of the rule, and it is written as one line on purpose: anything
             * that reached in to update a field would be the merge the protocol
             * warns about, and would leave a `ready` row's `url` under a
             * `starting` or a `failed` that has no address at all.
             *
             * Idempotent by construction, which the wire requires: a `dev.start`
             * is answered directly *and* pushed, so the same state arrives
             * twice. Writing it twice costs nothing.
             */
            devServers[report.folder] = report

        case let .credentialRequest(id, origin, repo, operation, prompt):
            // The machine's *name* travels with the question, not just its id.
            // The prompt's third line is which machine asked, and by the time it
            // is drawn this link may not be the one on screen — a phone paired
            // with three machines can be looking at any of them when a fourth
            // thing happens on a fourth.
            onCredentialRequest?(CredentialRequest(id: id,
                                                   machineId: self.id,
                                                   machineName: label,
                                                   origin: origin,
                                                   repo: repo,
                                                   operation: operation,
                                                   prompt: prompt))

        case .tunnelOpened, .tunnelClosed, .netData, .netAck, .netClose:
            break

        case .uploadReady, .uploadAck, .uploadDone, .uploadFailed:
            break

        case .pong:
            break
        }
    }
}

/// See `HostLink.wire`. One class for both protocols, because they ask for the
/// same single method and a second identical proxy would be a second thing to
/// keep in step.
@MainActor
final class WireProxy: TunnelWire, UploadWire {
    private let deliver: (ClientMessage) -> Bool

    init(_ deliver: @escaping (ClientMessage) -> Bool) {
        self.deliver = deliver
    }

    func send(_ message: ClientMessage) -> Bool {
        deliver(message)
    }
}
