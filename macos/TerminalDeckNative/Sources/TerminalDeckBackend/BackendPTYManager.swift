import Foundation
import Darwin
import SwiftTerm
import TerminalDeckNativeCore

/// The complete local PTY manager. Mutable state, parser input, callbacks and
/// screen reads share one serial queue, so a read always sees preceding bytes.
/// Exiting keeps the session/output; removing a tab removes it immediately and
/// independently waits for its own process group to be reaped.
public final class BackendPTYManager: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.terminaldeck.native.pty", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let inheritedEnvironment: [String: String]
    private let onEvent: @Sendable (BackendSessionEvent) -> Void
    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private var processes: [String: BackendPTYProcess] = [:]
    private var watched = true
    private var shuttingDown = false
    private var drainWaiters: [UUID: DrainWaiter] = [:]
    private var remoteServeSequence: UInt64 = 0
    /// 27 Oct: who owns each session's size (`BackendTerminalViewers`). Resizes are applied one at a time, in the
    /// order they were decided, so a slower one can never put back a size that a later one replaced.
    private var viewers: [String: BackendTerminalViewers] = [:]
    private var sizeObservers: [UUID: @Sendable (String) -> Void] = [:]
    /// When each session last really did something here (ms since 1970; rules: `BackendSessionActivity`, 1 Nov).
    private var activity: [String: Double] = [:]
    /// 1 Nov: until when a session's output is its redraw for a new size or a remount, not activity.
    private var redrawUntil: [String: Double] = [:]
    /// 1 Nov: each session's AI as the activity rules need it (a plain shell's output counts, an AI screen's does not).
    private var activityKind: [String: (provider: String, chat: Bool)] = [:]
    private var activityListener: (@Sendable (String, Double) -> Void)?
    /// 28 Oct: when each session last printed (ms since 1970), and the last owner change's turn.
    private var outputAt: [String: Double] = [:]
    private var ownerTurns: UInt64 = 0
    private let resizeOrder = NSLock()
    private var remoteServeObservers: [UUID: @Sendable (BackendRemoteServePTYEvent) -> Void] = [:]
    /// Chat sessions (Asad, 13 Oct): listed, named, closed and typed into like any session, but with no terminal;
    /// their AI runs in its structured app mode, owned by BackendSessionChats.
    private var chats: [String: Chat] = [:]
    private final class Chat: @unchecked Sendable {
        var meta: BackendSessionMeta
        var status: BackendSessionStatus = .idle
        let controls: ChatControls
        init(meta: BackendSessionMeta, controls: ChatControls) { self.meta = meta; self.controls = controls }
    }
    /// What the manager asks of a chat session's owner.
    public struct ChatControls: Sendable {
        /// Words and keys typed from elsewhere: the chat owner edits its composer and Return sends it.
        public let send: @Sendable (String) throws -> Void
        /// The session is closed (or the app is quitting): end its AI.
        public let stop: @Sendable () -> Void
        /// The conversation as plain text, for whatever reads a session's screen.
        public let text: @Sendable () -> String
        /// Its AI's process, while one runs.
        public let pid: @Sendable () -> Int32?
        public init(send: @escaping @Sendable (String) throws -> Void, stop: @escaping @Sendable () -> Void,
                    text: @escaping @Sendable () -> String, pid: @escaping @Sendable () -> Int32?) {
            self.send = send; self.stop = stop; self.text = text; self.pid = pid
        }
    }

    private final class Session: @unchecked Sendable {
        var meta: BackendSessionMeta
        let process: BackendPTYProcess
        let terminal: ShadowTerminal
        var replay = ReplayBuffer()
        /// The modes its program set, for `remount` (27 Oct).
        var modes = BackendTerminalModes()
        var decoder = UTF8StreamDecoder()
        var status: BackendSessionStatus = .idle
        var settledViewport: String
        var settle: DispatchWorkItem?
        var watching = true
        var removed = false

        init(meta: BackendSessionMeta, process: BackendPTYProcess, terminal: ShadowTerminal) {
            self.meta = meta; self.process = process; self.terminal = terminal
            self.settledViewport = terminal.viewport()
        }
        func remount() -> String { BackendTerminalRemount.render(terminal.terminal, modes: modes) }
    }

    private struct DrainWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: DispatchWorkItem
    }

    /// The event callback is ordered on a backend queue. UI callers must hop to
    /// the main actor; do not block this callback waiting for the UI.
    /// open-shim.ts: the folder holding the `open` shim, first on every session's PATH, and
    /// `$BROWSER` pointing at it (host-core.ts spawn), so an agent's `open <url>` reaches the
    /// session's own browser window. nil until the app has written the shim.
    #if TD_HOST_PTY_GATE_INTEGRATED
    private var hostBeforeExec: (@Sendable (String, Int32) throws -> Void)?
    public func setHostBeforeExec(_ callback: @escaping @Sendable (String, Int32) throws -> Void) throws {
        try synchronized {
            guard sessions.isEmpty, processes.isEmpty, !shuttingDown else { throw BackendSessionFailure.invalidInput("The host exec gate must be installed before any session starts.") }
            hostBeforeExec = callback
        }
    }
    #endif
    #if TD_HOST_INTEGRATED
    private var hostFrontend: BackendHOSTManagerBridge?
    private var hostFrontendOnly = false
    public func installHOSTFrontend(_ bridge: BackendHOSTManagerBridge, hostedOnly: Bool = false,
                                    ready: @escaping @Sendable () -> Void,
                                    disconnected: @escaping @Sendable () -> Void) throws {
        try synchronized {
            guard hostFrontend == nil, !shuttingDown else { throw BackendSessionFailure.closed }
            hostFrontend = bridge; hostFrontendOnly = hostedOnly
        }
        do {
            try bridge.attach(snapshot: { [weak self] value in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.remoteServeSequence = max(self.remoteServeSequence, value.sequence)
                }
            }, event: { [weak self] value in
                self?.queue.async { [weak self] in
                    guard let self, let event = try? value.sessionEvent() else { return }
                    self.noteForActivity(event)
                    self.remoteServeSequence = max(self.remoteServeSequence, value.sequence)
                    for observer in Array(self.remoteServeObservers.values) {
                        observer(.init(sequence: value.sequence, event: event))
                    }
                    self.onEvent(event)
                }
            }, ready: { [weak self] in self?.queue.async(execute: ready) }, disconnected: disconnected)
        } catch { throw error } // Never silently select a second local owner.
    }
    public func createHOST(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
                           context: BackendLaunchContext, machineID: String?, independent: Bool) throws -> BackendSessionMeta {
        guard let bridge = synchronized({ hostFrontend }), !synchronized({ shuttingDown }) else { throw BackendSessionFailure.closed }
        return try bridge.create(input: input, spawn: spawn, inheritedEnvironment: inheritedEnvironment,
                                 openShim: synchronized { openShim }, context: context, machineID: machineID, independent: independent)
    }
    public func detachHOSTFrontend() {
        let retiring = synchronized { let value = hostFrontend; hostFrontend = nil; hostFrontendOnly = false; return value }
        retiring?.detach()
    }
    /// QUIT (9 Oct): before any app shutdown stops processes. Unless the explicit Stop Everything
    /// authorized it, the session host's processes are detached (they keep running in their host,
    /// exactly as when the app crashes), so the following beginShutdown/drain reach only in-app
    /// processes. Returns whether a host transport was detached.
    @discardableResult
    public func prepareShutdown(stopHosted: Bool) -> Bool {
        guard !stopHosted, synchronized({ hostFrontend }) != nil else { return false }
        detachHOSTFrontend(); return true
    }
    public func localSessionCount() -> Int { synchronized { sessions.values.filter { $0.meta.exitCode == nil && !$0.process.exited }.count } }
    public func isHostedSession(_ id: String) -> Bool { synchronized { hostFrontend }?.owns(id) ?? false }
    /// A finished job's history is opened again in the helper: let its row back into this app's list.
    public func readmitHosted(_ id: String) { synchronized { hostFrontend }?.readmit(id) }
    public func hostedSessionCount() -> Int { synchronized { hostFrontend }?.list().filter { $0.exitCode == nil }.count ?? 0 }
    #endif
    private var openShim: (directory: String, browser: String)?
    public func setOpenShim(directory: String?, browser: String?) {
        synchronized { openShim = directory.flatMap { dir in browser.map { (dir, $0) } } }
    }

    public init(inheritedEnvironment: [String: String], onEvent: @escaping @Sendable (BackendSessionEvent) -> Void) {
        self.inheritedEnvironment = inheritedEnvironment
        self.onEvent = onEvent
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Identities whose child is being forked and released outside the queue (#48).
    private var launching: Set<String> = []
    @discardableResult
    public func create(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec) throws -> BackendSessionMeta {
        #if TD_HOST_INTEGRATED
        if synchronized({ hostFrontendOnly }) { throw BackendSessionFailure.missingCapability("the resolved hosted launch seam") }
        #endif
        return try createResolved(input, spawn: spawn, id: UUID().uuidString.lowercased())
    }

    private func createResolved(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
                                id: String, resolvedEnvironment: [String: String]? = nil,
                                metadata: BackendSessionMeta? = nil) throws -> BackendSessionMeta {
        // 18 Oct (#48): checks and the identity are taken under the queue, but the fork and the host's pre-exec
        // binding (up to five seconds) run outside it, so no other session's output, typing or listing waits on a
        // new one; the child is registered under the queue once it has been released.
        let env: [String: String] = try synchronized {
            guard sessions[id] == nil, processes[id] == nil, !launching.contains(id) else { throw BackendSessionFailure.invalidInput("This session identity already exists.") }
            guard !shuttingDown else { throw BackendSessionFailure.closed }
            try Self.validateDimensions(cols: input.cols, rows: input.rows)
            guard input.cwd.hasPrefix("/"), !input.cwd.contains("\0"), !spawn.provider.isEmpty else {
                throw BackendSessionFailure.invalidInput("A session needs an absolute working folder and a resolved provider.")
            }
            var env = try resolvedEnvironment ?? BackendSessionEnvironment.forSession(id: id, inherited: inheritedEnvironment, spawn: spawn)
            if resolvedEnvironment == nil, let shim = openShim {
                env["PATH"] = BackendMacAppHandoffOpenShim.prepend(path: env["PATH"] ?? "", shim: shim.directory)
                env["BROWSER"] = shim.browser
            }
            launching.insert(id)
            return env
        }
        let cwd = spawn.hostCwd ?? input.cwd
        let process: BackendPTYProcess
        do {
            let executable = try Self.executable(spawn.command, path: env["PATH"] ?? "", cwd: cwd)
            var childGate: (@Sendable (Int32) throws -> Void)? = nil
            #if TD_HOST_PTY_GATE_INTEGRATED
            if resolvedEnvironment != nil, let callback = synchronized({ hostBeforeExec }) {
                childGate = { pid in try callback(id, pid) }
            }
            #endif
            process = try BackendPTYProcess.spawn(command: executable, args: spawn.args, environment: env,
                cwd: cwd, cols: input.cols, rows: input.rows, queue: queue, beforeExec: childGate)
        } catch let error as BackendSessionFailure {
            synchronized { _ = launching.remove(id) }
            guard case .operatingSystem = error else { throw error }
            throw BackendSessionFailure.launch(provider: spawn.provider, cwd: input.cwd,
                command: spawn.command, processCwd: cwd, cause: error.errorDescription)
        } catch { synchronized { _ = launching.remove(id) }; throw error }
        return try synchronized {
            launching.remove(id)
            // Shutdown began while the child was being prepared: it is never listed, only ended and reaped.
            guard !shuttingDown else { process.abandon(); throw BackendSessionFailure.closed }
            let meta = metadata ?? BackendSessionMeta(id: id, input: input, spawn: spawn)
            let terminal = ShadowTerminal(cols: input.cols, rows: input.rows)
            let session = Session(meta: meta, process: process, terminal: terminal)
            session.watching = watched
            // O1-R12: the spawn hook (e.g. Hoot's hidden register) runs before the session
            // can be listed, started or announced.
            spawn.beforeExposure?(id)
            sessions[id] = session
            order.append(id)
            processes[id] = process
            process.onData = { [weak self] bytes in self?.received(id: id, bytes: bytes) }
            process.onExit = { [weak self] code in self?.exited(id: id, session: session, code: code) }
            process.start()
            return meta
        }
    }

    public func list() -> [BackendSessionMeta] { synchronized {
        let local = order.compactMap { sessions[$0]?.meta ?? chats[$0]?.meta }
        #if TD_HOST_INTEGRATED
        return local + (hostFrontend?.list() ?? []).filter { sessions[$0.id] == nil }
        #else
        return local
        #endif
    } }

    #if TD_HOST_INTEGRATED
    /// Authenticated host only: preserve the app's already resolved identity,
    /// environment and metadata without inheriting launchd configuration.
    public func hostCreate(_ value: BackendHOSTProtocol.Launch) throws -> BackendSessionMeta {
        guard UUID(uuidString: value.id) != nil, value.metadata.id == value.id,
              value.metadata.cwd == value.input.cwd, value.metadata.exitCode == nil,
              value.cwd.hasPrefix("/"), !value.cwd.contains("\0"),
              value.environment[BackendSessionEnvironment.sessionVariable] == value.id,
              value.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("The resolved host launch is invalid.")
        }
        let spawn = BackendSpawnSpec(provider: value.metadata.provider, command: value.command,
            args: value.arguments, path: value.environment["PATH"] ?? "", env: value.environment,
            profile: value.metadata.profileId.map { BackendAccountIdentity(id: $0, name: value.metadata.profileName ?? $0) },
            homeProfileId: value.metadata.homeProfileId, agentSessionId: value.metadata.agentSessionId,
            resumed: value.metadata.resumed, hostCwd: value.cwd, tabKey: value.metadata.tabKey)
        return try createResolved(value.input, spawn: spawn, id: value.id,
                                  resolvedEnvironment: value.environment, metadata: value.metadata)
    }

    /// The visible screen only (SCROLL, 9 Oct): the session bar, usage parsing and readiness
    /// probes ask for the screen many times a second; a full snapshot rebuilt the whole replay
    /// and scrollback under this queue's lock each time, stalling output.
    public func hostViewport(_ id: String) -> BackendHOSTProtocol.Snapshot? {
        synchronized {
            guard let session = sessions[id] else { return nil }
            return .init(sequence: remoteServeSequence, session: session.meta,
                pid: session.meta.exitCode == nil && !session.process.exited ? session.process.pid : nil,
                replay: "", screen: session.terminal.viewport(), scrollbackText: nil, status: session.status)
        }
    }
    /// `remount`: also the bytes that draw the terminal as it is now (27 Oct), read in the same queue turn as
    /// the sequence, so no output is both in it and delivered after it. Asked for only by an attach.
    public func hostSnapshot(_ id: String, remount: Bool = false) -> BackendHOSTProtocol.Snapshot? {
        synchronized {
            if let chat = chatHostSnapshot(id) { return chat }
            guard let session = sessions[id] else { return nil }
            var value = BackendHOSTProtocol.Snapshot(sequence: remoteServeSequence, session: session.meta,
                pid: session.meta.exitCode == nil && !session.process.exited ? session.process.pid : nil,
                replay: session.replay.text, screen: session.terminal.viewport(),
                scrollbackText: String(decoding: session.terminal.terminal.getBufferAsData(kind: .normal), as: UTF8.self),
                status: session.status)
            if remount { value.remount = session.remount() }
            return value
        }
    }


    #endif

    /// Remote-serve attach replay: the snapshot and the event sequence come from
    /// the single PTY owner queue, so a replay and the events after it never
    /// overlap or leave a gap.
    /// 27 Oct: what a phone or another Mac is sent when it attaches is the terminal as it is now (`remount`),
    /// not the raw tail. A helper older than that has none to give, and its raw tail is sent as before.
    public func remoteServeSnapshot(_ id: String) -> BackendRemoteServePTYSnapshot? {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) {
            guard let actual = try? bridge.snapshot(id, remount: true) else { return nil }
            // A helper older than the remount sends its raw tail: the phone gets the small join built here instead.
            let replay = actual.remount ?? BackendTerminalJoin.build(replay: actual.replay, screen: actual.screen,
                                                                     scrollbackText: actual.scrollbackText).text
            return .init(sequence: actual.sequence, session: actual.session, replay: replay, status: actual.status)
        }
        #endif
        return synchronized {
            guard let session = sessions[id] else { return nil }
            return .init(sequence: remoteServeSequence, session: session.meta,
                         replay: session.remount(), status: session.status)
        }
    }
    public func remoteServeObserve(_ callback: @escaping @Sendable (BackendRemoteServePTYEvent) -> Void) -> NativeRPCSubscription {
        let token = UUID()
        synchronized { remoteServeObservers[token] = callback }
        return NativeRPCSubscription(id: token) { [weak self] in
            guard let self else { return }
            self.synchronized { self.remoteServeObservers[token] = nil }
        }
    }
    public func remoteServeCurrentSequence() -> UInt64 { synchronized { remoteServeSequence } }
    /// Every session event goes out through here (on the queue): sequenced for
    /// remote-serve observers, then the original onEvent callback, unchanged.
    private func emit(_ event: BackendSessionEvent) {
        noteForActivity(event)
        remoteServeSequence &+= 1
        let sequenced = BackendRemoteServePTYEvent(sequence: remoteServeSequence, event: event)
        for observer in Array(remoteServeObservers.values) { observer(sequenced) }
        onEvent(event)
    }

    // MARK: Chat sessions

    public func chatHostSnapshot(_ id: String) -> BackendHOSTProtocol.Snapshot? {
        synchronized {
            guard let chat = chats[id] else { return nil }
            let text = chat.controls.text()
            return .init(sequence: remoteServeSequence, session: chat.meta, pid: chat.controls.pid(), replay: text,
                screen: text, scrollbackText: text, status: chat.status)
        }
    }
    /// The environment and program a chat session's AI starts with: exactly what its terminal would have had.
    public func chatLaunch(id: String, spawn: BackendSpawnSpec, cwd: String) throws -> (executable: String, environment: [String: String]) {
        try synchronized {
            guard !shuttingDown else { throw BackendSessionFailure.closed }
            var env = try BackendSessionEnvironment.forSession(id: id, inherited: inheritedEnvironment, spawn: spawn)
            if let shim = openShim {
                env["PATH"] = BackendMacAppHandoffOpenShim.prepend(path: env["PATH"] ?? "", shim: shim.directory)
                env["BROWSER"] = shim.browser
            }
            env["CLAUDECODE"] = nil
            return (try Self.executable(spawn.command, path: env["PATH"] ?? "", cwd: cwd), env)
        }
    }
    /// A chat session whose AI has started: from now on it is listed and reached like any session.
    public func registerChat(_ meta: BackendSessionMeta, controls: ChatControls) throws {
        try synchronized {
            guard !shuttingDown else { controls.stop(); throw BackendSessionFailure.closed }
            guard sessions[meta.id] == nil, chats[meta.id] == nil else { throw BackendSessionFailure.invalidInput("This session identity already exists.") }
            chats[meta.id] = Chat(meta: meta, controls: controls)
            order.append(meta.id)
        }
    }
    /// A finished job stays in the list, with no process and no writable controls.
    public func finishChat(_ id: String, failed: Bool) {
        synchronized {
            guard let chat = chats[id] else { return }
            chat.meta.exitCode = failed ? 1 : 0
            chat.status = .completed
            emit(.exit(id: id, exitCode: failed ? 1 : 0))
            emit(.status(id: id, status: .completed))
        }
    }
    public func isChat(_ id: String) -> Bool { synchronized { chats[id] != nil } }
    /// A chat's AI started or finished a turn: the same status a terminal reports.
    public func chatProject(_ id: String, projectID: String?) {
        synchronized { chats[id]?.meta.projectId = projectID }
    }
    public func chatStatus(_ id: String, status: BackendSessionStatus) {
        synchronized {
            guard let chat = chats[id] else { return }
            chat.status = status
            emit(.status(id: id, status: status))
        }
    }

    /// Parser-only test seam for `remount`: the production shadow terminal and mode reader fed the chunks in
    /// order, resized before the chunk at each index in `resizes`. No PTY, process, session state or timer.
    static func remountForTesting(cols: Int, rows: Int, chunks: [Data], resizes: [Int: (cols: Int, rows: Int)] = [:]) throws -> String {
        try validateDimensions(cols: cols, rows: rows)
        let shadow = ShadowTerminal(cols: cols, rows: rows)
        var modes = BackendTerminalModes()
        for (index, chunk) in chunks.enumerated() {
            if let size = resizes[index] { shadow.terminal.resize(cols: size.cols, rows: size.rows) }
            shadow.terminal.feed(byteArray: Array(chunk)); modes.scan(chunk)
        }
        return BackendTerminalRemount.render(shadow.terminal, modes: modes)
    }

    /// Parser-only test seam using the actual production viewport helper.
    /// Does not create a PTY, process, session state or timer.
    static func viewportForTesting(cols: Int, rows: Int, chunks: [Data]) throws -> String {
        try validateDimensions(cols: cols, rows: rows)
        let shadow = ShadowTerminal(cols: cols, rows: rows)
        for chunk in chunks { shadow.terminal.feed(byteArray: Array(chunk)) }
        return shadow.viewport()
    }

    // Keep the original protocol witnesses and callable method identities unchanged.
    public func write(_ id: String, data: String) throws {
        try write(id, data: data, expectedCreatedAt: nil)
    }

    public func write(_ id: String, bytes: Data) throws {
        try write(id, bytes: bytes, expectedCreatedAt: nil)
    }

    public func write(_ id: String, data: String, expectedCreatedAt: Double?) throws {
        try write(id, bytes: Data(data.utf8), expectedCreatedAt: expectedCreatedAt)
    }

    /// Protected delivery releases its actor while the helper asks the app for
    /// fresh authority. Local writes retain the same incarnation and cache path.
    public func writeAsync(_ id: String, bytes: Data, expectedCreatedAt: Double? = nil) async throws {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) {
            noteTyping(id, bytes)
            try await bridge.writeAsync(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt); return
        }
        #endif
        try await BackendPCDecisionDelivery.verifyFinal(.input)
        try Task.checkCancellation()
        try write(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt)
    }

    public func write(_ id: String, bytes: Data, expectedCreatedAt: Double?) throws {
        noteTyping(id, bytes)
        if let chat = synchronized({ chats[id] }) {
            let text = String(decoding: bytes, as: UTF8.self)
            if let expectedCreatedAt, chat.meta.createdAt != expectedCreatedAt { throw BackendSessionFailure.missingSession }
            guard chat.meta.exitCode == nil else { throw NativeRPCError.invalidArguments("This job is finished. Start a new conversation.") }
            try chat.controls.send(text); return
        }
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) {
            try bridge.write(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt); return
        }
        #endif
        try synchronized {
            guard let session = sessions[id] else { throw BackendSessionFailure.missingSession }
            guard session.meta.exitCode == nil else { throw BackendSessionFailure.exitedSession }
            // Handoffs carry the host-owned incarnation. Check it on the SAME queue as
            // lookup and input, so a replacement cannot receive a delayed paste/Return.
            if let expectedCreatedAt, session.meta.createdAt != expectedCreatedAt {
                throw NativeRPCError(code: "stale-session", message: "The session was replaced before this input could be sent.")
            }
            // Public route to SwiftTerm's input heuristic (registerUserInput is
            // internal): sendUserInput runs it, then forwards to the delegate,
            // whose send is a no-op for this shadow, so the bytes go out once, below.
            session.terminal.terminal.sendUserInput(Array(bytes)[...])
            try session.process.write(bytes)
        }
    }

    /// This Mac's own terminal for the session is this size (`session:resize`; inside the session host, the app's
    /// request). It sizes the program while this Mac owns the size (28 Oct, `BackendTerminalViewers`).
    public func resize(_ id: String, cols: Int, rows: Int) throws {
        let size = try Self.terminalSize(cols, rows)
        try decide(id) { viewers, _ in viewers.mac = size }
    }

    /// The session was chosen on this Mac (clicked in its session list or tab strip, or "Move back here" on its
    /// panel; `session:use`): this Mac owns the size from now on (Asad, 28 Oct). True when the program was given a
    /// new size: its redraw is on the way (`settle`).
    @discardableResult
    public func macUsed(_ id: String, cols: Int, rows: Int) throws -> Bool {
        let size = try Self.terminalSize(cols, rows)
        return try decide(id) { $0.mac = size; $0.used(by: .mac, turn: $1) }
    }

    /// The phones and other Macs attached to the session, at their sizes (all of them each time; an empty list when
    /// none is left). `user`: one of them chose the session (opened it, or "Move back here") and owns the size from
    /// now on. `keep`: that choice is a phone coming back after its link dropped, to a session it had: it takes it
    /// only while nobody chose it since (this app's start included). True when the program was given a new size.
    @discardableResult
    public func setViewerSizes(_ id: String, _ claims: [BackendTerminalViewers.Claim], user: String? = nil,
                               keep: Bool = false) throws -> Bool {
        for claim in claims { _ = try Self.terminalSize(claim.size.cols, claim.size.rows) }
        let taker = user.flatMap { user in claims.last { $0.viewer == user } }
        return try decide(id) { viewers, turn in
            viewers.claims = claims
            guard let taker, !keep || viewers.turn == 0 || viewers.owner == .viewer(taker.viewer) else { return }
            viewers.used(by: .viewer(taker.viewer), name: taker.name, platform: taker.platform, turn: turn)
        }
    }

    /// Who has the session's size, for this Mac's own terminal (`session:owner`).
    public func owner(_ id: String) -> TerminalOwner {
        guard let viewers = synchronized({ self.viewers[id] }) else { return .mac }
        switch viewers.owner {
        case .mac: return .init(here: true, name: nil, kind: "computer", turn: viewers.turn)
        case .viewer:
            return .init(here: false, name: viewers.ownerName.isEmpty ? nil : viewers.ownerName,
                         kind: TerminalOwner.kind(platform: viewers.ownerPlatform), turn: viewers.turn)
        }
    }

    /// When the session last printed here (ms since 1970), for `settle`.
    public func lastOutput(_ id: String) -> Double? { synchronized { outputAt[id] } }

    /// 28 Oct: after the program was given a new size, wait for it to finish redrawing: until its output has been
    /// quiet for 120 ms, never longer than 600 ms (`TerminalSettle`). How long it waited, in ms.
    @discardableResult
    public func settle(_ id: String) async -> Double {
        let settle = TerminalSettle(start: Self.now())
        while let wake = settle.next(now: Self.now(), lastOutput: lastOutput(id)) {
            try? await Task.sleep(for: .milliseconds(max(1, Int((wake - Self.now()).rounded(.up)))))
        }
        return Self.now() - settle.start
    }

    /// When the session last really did something here (ms since 1970; `BackendSessionActivity`). Nil when nothing
    /// happened since this app started; the caller adds what the ledger kept from before (`BackendRemoteHost`).
    public func lastActivity(_ id: String) -> Double? { synchronized { activity[id] } }
    /// Called (on the manager's queue) each time a session's activity moves forward: the composition keeps it in
    /// the ledger so it survives an app restart.
    public func onActivity(_ listener: @escaping @Sendable (String, Double) -> Void) { synchronized { activityListener = listener } }
    /// Something really happened inside the session at `at` (an AI's turn started, used a tool, asked for approval
    /// or ended: its hooks). Forward only.
    public func noteActivity(_ id: String, at: Double) { synchronized { markActivity(id, at: at) } }
    private func markActivity(_ id: String, at: Double) {
        guard at > (activity[id] ?? 0) else { return }
        activity[id] = at
        activityListener?(id, at)
    }
    /// Every session event (on the queue): output time, and activity by `BackendSessionActivity`'s rules.
    private func noteForActivity(_ event: BackendSessionEvent) {
        let now = Self.now()
        switch event {
        case .removed(let id, _):
            viewers[id] = nil; activity[id] = nil; outputAt[id] = nil; redrawUntil[id] = nil; activityKind[id] = nil
        case .data(let id, _):
            outputAt[id] = now
            let kind = kindForActivity(id)
            if BackendSessionActivity.outputCounts(provider: kind?.provider, chat: kind?.chat ?? false, at: now, redrawUntil: redrawUntil[id]) { markActivity(id, at: now) }
        case .status(let id, _):
            if kindForActivity(id)?.chat == true { markActivity(id, at: now) } // a chat's status is its engine's real turn
        case .exit(let id, _):
            markActivity(id, at: now)
        }
    }
    private func kindForActivity(_ id: String) -> (provider: String, chat: Bool)? {
        if let known = activityKind[id] { return known }
        var meta = sessions[id]?.meta ?? chats[id]?.meta
        #if TD_HOST_INTEGRATED
        if meta == nil { meta = hostFrontend?.list().first(where: { $0.id == id }) }
        #endif
        guard let meta else { return nil }
        let kind = (provider: meta.provider, chat: meta.chat == true || chats[id] != nil)
        activityKind[id] = kind
        return kind
    }
    /// The program is being given a new size or redrawn for a joining terminal: its output for a moment is that redraw.
    private func expectRedraw(_ id: String) {
        let until = Self.now() + BackendSessionActivity.redrawQuietMilliseconds
        synchronized { redrawUntil[id] = max(redrawUntil[id] ?? 0, until) }
    }

    /// The session's status as last known here, without asking its session host for a snapshot.
    public func knownStatus(_ id: String) -> BackendSessionStatus? {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return bridge.cachedStatus(id) }
        #endif
        return synchronized { chats[id]?.status ?? sessions[id]?.status }
    }

    private func noteTyping(_ id: String, _ bytes: Data) {
        guard Self.isTyping(bytes) else { return }
        let at = Self.now()
        synchronized { markActivity(id, at: at) }
    }
    private static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Input a person typed or pasted, as opposed to what a terminal sends by itself (mouse reports, focus in and
    /// out, answers to the program's questions): anything left once escape sequences are taken out.
    static func isTyping(_ bytes: Data) -> Bool {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x1b else { return true }
            index = bytes.index(after: index)
            guard index < bytes.endIndex else { return false }
            let kind = bytes[index]
            index = bytes.index(after: index)
            if kind == 0x5b { // CSI: parameters and intermediates, then one final byte
                while index < bytes.endIndex, !(0x40...0x7e).contains(bytes[index]) { index = bytes.index(after: index) }
                if index < bytes.endIndex { index = bytes.index(after: index) }
            } else if kind == 0x4f, index < bytes.endIndex { index = bytes.index(after: index) } // SS3: one more byte
        }
        return false
    }

    /// Who owns the session's size and what it is (the remote host tells each phone).
    public func viewerSizes(_ id: String) -> BackendTerminalViewers? { synchronized { viewers[id] } }

    /// Called after any change of a session's size or owner.
    public func observeSizes(_ callback: @escaping @Sendable (String) -> Void) -> NativeRPCSubscription {
        let token = UUID()
        synchronized { sizeObservers[token] = callback }
        return NativeRPCSubscription(id: token) { [weak self] in
            guard let self else { return }
            self.synchronized { self.sizeObservers[token] = nil }
        }
    }

    private static func terminalSize(_ cols: Int, _ rows: Int) throws -> BackendTerminalSize {
        let size = BackendTerminalSize(cols: max(cols, 1), rows: max(rows, 1))
        try validateDimensions(cols: size.cols, rows: size.rows)
        return size
    }

    /// One change to who looks at a session, then the size its owner wants given to the program if it changed.
    /// The change is handed the turn an owner change takes. True when the program was given a new size.
    @discardableResult
    private func decide(_ id: String, _ change: (inout BackendTerminalViewers, UInt64) -> Void) throws -> Bool {
        var resized = false
        var changed = false
        try inResizeOrder {
            let known = isTerminal(id)
            let plan = synchronized { () -> (BackendTerminalSize?, Bool) in
                var viewers = known ? self.viewers[id] ?? .init() : .init()
                let before = viewers
                change(&viewers, self.ownerTurns &+ 1)
                if viewers.turn != before.turn { self.ownerTurns = viewers.turn }
                let size = known ? viewers.settle() : nil
                if known { self.viewers[id] = viewers }
                return (size, known && viewers != before)
            }
            changed = plan.1
            guard let size = plan.0 else { return }
            expectRedraw(id)
            do { try apply(id, size) } catch {
                synchronized { self.viewers[id]?.applied = nil }
                throw error
            }
            resized = true
        }
        if changed { for observer in synchronized({ Array(sizeObservers.values) }) { observer(id) } }
        return resized
    }

    /// The order lock is never waited for on the manager queue: a resize decided there (none is today) runs
    /// straight through, so a resize holding the lock and waiting for the queue cannot wait on it in turn.
    private func inResizeOrder(_ body: () throws -> Void) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil { try body(); return }
        try resizeOrder.withLock(body)
    }
    private func isTerminal(_ id: String) -> Bool {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return true }
        #endif
        return synchronized { sessions[id] != nil }
    }

    private func apply(_ id: String, _ size: BackendTerminalSize) throws {
        let cols = size.cols, rows = size.rows
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { try bridge.resize(id, cols: cols, rows: rows); return }
        #endif
        try synchronized {
            guard let session = sessions[id], session.meta.exitCode == nil else { return }
            let columns = max(cols, 1), lines = max(rows, 1)
            try Self.validateDimensions(cols: columns, rows: lines)
            try session.process.resize(cols: columns, rows: lines)
            session.terminal.terminal.resize(cols: columns, rows: lines)
        }
    }

    /// The exact escape stream for remounting the terminal, as in the old
    /// manager. The parser separately retains real scrollback; agents/UI text
    /// readers should use scrollbackText(), not try to strip this stream.
    public func scrollback(_ id: String) -> String {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return (try? bridge.snapshot(id))?.replay ?? "" }
        #endif
        return synchronized { sessions[id]?.replay.text ?? "" }
    }

    /// The bytes that draw this session's terminal as it is now, for this Mac's own terminal joining it late
    /// (`session:scrollback`, 27 Oct). `scrollback` stays the raw stream for everything that reads it as text.
    /// A session host older than the remount answers its raw tail; the join built from it (as a phone gets since
    /// 27 Oct, `BackendTerminalJoin`) starts at the last full repaint with the modes in force, not mid-drawing.
    public func remount(_ id: String) -> String {
        expectRedraw(id)
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) {
            guard let actual = try? bridge.snapshot(id, remount: true) else { return "" }
            return actual.remount ?? BackendTerminalJoin.build(replay: actual.replay, screen: actual.screen,
                                                               scrollbackText: actual.scrollbackText).text
        }
        #endif
        return synchronized { sessions[id]?.remount() ?? "" }
    }

    /// `remount`, but only a real one: nil from a session host older than the remount (its raw tail cannot be
    /// a clean redraw).
    public func remountIfAvailable(_ id: String) -> String? {
        expectRedraw(id)
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return (try? bridge.snapshot(id, remount: true))?.remount }
        #endif
        return synchronized { sessions[id]?.remount() }
    }

    public func scrollbackText(_ id: String) -> String? {
        if let chat = synchronized({ chats[id] }) { return chat.controls.text() }
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return (try? bridge.snapshot(id))?.scrollbackText }
        #endif
        return synchronized {
            guard let session = sessions[id] else { return nil }
            return String(decoding: session.terminal.terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        }
    }

    public func screen(_ id: String) -> String? {
        if let chat = synchronized({ chats[id] }) { return chat.controls.text() }
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return try? bridge.screen(id) } // cached, viewport-only (SCROLL)
        #endif
        return synchronized { sessions[id]?.terminal.viewport() }
    }

    public func pidOf(_ id: String) -> Int32? {
        if let chat = synchronized({ chats[id] }) { return chat.controls.pid() }
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return bridge.pid(id) }
        #endif
        return synchronized {
            guard let session = sessions[id], session.meta.exitCode == nil, !session.process.exited else { return nil }
            return session.process.pid
        }
    }

    @discardableResult
    public func rename(_ id: String, title: String) -> Bool {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return bridge.rename(id, title: title) }
        #endif
        return synchronized {
            let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let chat = chats[id] {
                let folder = URL(fileURLWithPath: chat.meta.cwd).lastPathComponent
                chat.meta.title = given.isEmpty ? (folder.isEmpty ? chat.meta.cwd : folder) : given
                return true
            }
            guard let session = sessions[id] else { return false }
            let folder = URL(fileURLWithPath: session.meta.cwd).lastPathComponent
            session.meta.title = given.isEmpty ? (folder.isEmpty ? session.meta.cwd : folder) : given
            return true
        }
    }

    @discardableResult
    public func setAccount(_ id: String, account: BackendAccountIdentity, home: String?) -> BackendSessionMeta? {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { return bridge.setAccount(id, account: account, home: home) }
        #endif
        return synchronized {
            if let chat = chats[id] {
                chat.meta.profileId = account.id; chat.meta.profileName = account.name
                chat.meta.homeProfileId = home == account.id ? nil : home
                return chat.meta
            }
            guard let session = sessions[id] else { return nil }
            session.meta.profileId = account.id
            session.meta.profileName = account.name
            session.meta.homeProfileId = home == account.id ? nil : home
            return session.meta
        }
    }

    public func setAgentSessionId(_ id: String, conversationId: String) {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { bridge.setConversation(id, conversation: conversationId); return }
        #endif
        synchronized {
            sessions[id]?.meta.agentSessionId = conversationId
            chats[id]?.meta.agentSessionId = conversationId
        }
    }

    public func kill(_ id: String, reason: BackendRemovalReason = .stopped) {
        #if TD_HOST_INTEGRATED
        if let bridge = synchronized({ hostFrontend }), bridge.owns(id) { bridge.remove(id, reason: reason); return }
        #endif
        synchronized { remove(id, reason: reason) }
    }

    public func killAll() {
        #if TD_HOST_INTEGRATED
        synchronized { hostFrontend }?.stopAll()
        #endif
        synchronized { for id in order { remove(id, reason: .stopped) } }
    }

    /// Stop accepting new launches, signal every owned group, then let drain()
    /// confirm exits before the root closes stores or the app terminates.
    public func beginShutdown() {
        #if TD_HOST_INTEGRATED
        synchronized { hostFrontend }?.stopAll()
        #endif
        synchronized {
            shuttingDown = true
            for id in order { remove(id, reason: .stopped) }
        }
    }

    public func setWatched(_ value: Bool) {
        #if TD_HOST_INTEGRATED
        synchronized { hostFrontend }?.setWatched(value)
        #endif
        synchronized {
            guard value != watched else { return }
            watched = value
            for session in sessions.values where session.meta.exitCode == nil {
                session.watching = value
                session.settle?.cancel(); session.settle = nil
                if value {
                    let viewport = session.terminal.viewport()
                    session.settledViewport = viewport
                    setStatus(session, next: BackendSessionClassifier.classify(viewport: viewport))
                }
            }
        }
    }

    /// Event-driven wait, with one timeout per caller and no polling loop.
    /// The drain's wait: the asked one, or (a renewal under way) the renewal's patience plus a second for the stop.
    static func drainWait(_ asked: Int, renewing: Bool) -> Int {
        renewing ? max(asked, Int(NativeSignInRenewal.patience * 1000) + 1_000) : max(asked, 0)
    }
    public func drain(timeoutMilliseconds: Int = 2_000) async -> Bool {
        #if TD_HOST_INTEGRATED
        let hostDrained = await synchronized { hostFrontend }?.drain(timeoutMilliseconds: timeoutMilliseconds) ?? true
        #else
        let hostDrained = true
        #endif
        let localDrained: Bool = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !processes.isEmpty else { continuation.resume(returning: true); return }
                // A Claude sign-in renewal under way holds its stop up to NativeSignInRenewal.patience; the drain waits
                // that long too, so a host swap or quit never gives up early and lets the kernel's hang-up cut it
                // (lane mac-signin-renewal "Left").
                let waitMilliseconds = Self.drainWait(timeoutMilliseconds, renewing: processes.values.contains { NativeSignInRenewal.inProgress($0.claudeFolder) })
                let id = UUID()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let waiter = self?.drainWaiters.removeValue(forKey: id) else { return }
                    waiter.continuation.resume(returning: false)
                }
                drainWaiters[id] = DrainWaiter(continuation: continuation, timeout: timeout)
                queue.asyncAfter(deadline: .now() + .milliseconds(waitMilliseconds), execute: timeout)
            }
        }
        return localDrained && hostDrained
    }

    private func remove(_ id: String, reason: BackendRemovalReason) {
        if let chat = chats.removeValue(forKey: id) {
            order.removeAll { $0 == id }
            chat.controls.stop()
            emit(.exit(id: id, exitCode: 0))
            emit(.removed(id: id, reason: reason))
            return
        }
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.removed = true
        session.settle?.cancel(); session.settle = nil
        order.removeAll { $0 == id }
        session.process.terminate()
        emit(.removed(id: id, reason: reason))
    }

    private func received(id: String, bytes: Data) {
        guard let session = sessions[id] else { return }
        session.terminal.terminal.feed(byteArray: Array(bytes))
        session.modes.scan(bytes)
        let text = session.decoder.push(bytes)
        if !text.isEmpty {
            session.replay.append(text)
            emit(.data(id: id, text: text))
        }
        guard session.watching, session.meta.exitCode == nil else { return }
        // A prompt's redraw/cursor/footer is not another turn. A visible work
        // signal can report working now; other output is judged once settled.
        if session.status != .working, BackendSessionClassifier.classify(viewport: session.terminal.viewport()) == .working {
            setStatus(session, next: .working)
        }
        session.settle?.cancel()
        let settle = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, !session.removed, session.meta.exitCode == nil, session.watching else { return }
            let viewport = session.terminal.viewport()
            let next = BackendSessionClassifier.classify(viewport: viewport)
            if viewport != session.settledViewport, next != session.status || session.status == .idle {
                self.setStatus(session, next: .working)
            }
            session.settledViewport = viewport
            self.setStatus(session, next: next)
            session.settle = nil
        }
        session.settle = settle
        queue.asyncAfter(deadline: .now() + .milliseconds(700), execute: settle)
    }

    private func exited(id: String, session: Session, code: Int) {
        guard processes.removeValue(forKey: id) != nil else { return }
        let final = session.decoder.finish()
        if !final.isEmpty && !session.removed {
            session.replay.append(final)
            emit(.data(id: id, text: final))
        }
        session.meta.exitCode = code
        session.settle?.cancel(); session.settle = nil
        // Even a removed session gets its one process-exit event, independently
        // of the removal event. No session is inserted back into the live map.
        setStatus(session, next: .exited)
        emit(.exit(id: id, exitCode: code))
        if processes.isEmpty {
            let waiters = Array(drainWaiters.values)
            drainWaiters.removeAll()
            for waiter in waiters { waiter.timeout.cancel(); waiter.continuation.resume(returning: true) }
        }
    }

    private func setStatus(_ session: Session, next: BackendSessionStatus) {
        guard session.status != next else { return }
        session.status = next
        emit(.status(id: session.meta.id, status: next))
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }

    private static func validateDimensions(cols: Int, rows: Int) throws {
        guard (1...1_000).contains(cols), (1...1_000).contains(rows), cols * rows <= 250_000 else {
            throw BackendSessionFailure.invalidInput("Terminal dimensions must be positive and fit the supported terminal size.")
        }
    }

    private static func executable(_ command: String, path: String, cwd: String) throws -> String {
        guard !command.isEmpty, !command.contains("\0"), !path.contains("\0"), cwd.hasPrefix("/") else {
            throw BackendSessionFailure.invalidInput("The terminal launch executable, PATH or folder is invalid.")
        }
        let candidates: [String]
        if command.hasPrefix("/") { candidates = [command] }
        else if command.contains("/") { candidates = [URL(fileURLWithPath: cwd).appendingPathComponent(command).standardizedFileURL.path] }
        else {
            candidates = path.components(separatedBy: ":").map { directory in
                let root: URL
                if directory.hasPrefix("/") { root = URL(fileURLWithPath: directory) }
                else { root = URL(fileURLWithPath: cwd).appendingPathComponent(directory) }
                return root.appendingPathComponent(command).standardizedFileURL.path
            }
        }
        for candidate in candidates {
            var info = stat()
            if access(candidate, X_OK) == 0, stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return candidate }
        }
        throw BackendSessionFailure.operatingSystem(operation: "find the requested terminal executable", code: ENOENT)
    }

    private final class ShadowTerminal: TerminalDelegate {
        var terminal: Terminal!
        init(cols: Int, rows: Int) {
            terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, termName: "xterm-256color", scrollback: 4_000))
        }
        func viewport() -> String {
            (0..<terminal.getDims().rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        }
        // This shadow parses screens; the attached terminal owns protocol
        // replies. Sending a second DSR/DA reply here would corrupt CLI input.
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private struct ReplayBuffer {
        private var chunks: [String] = []
        private var start = 0
        private var bytes = 0
        var text: String { chunks.dropFirst(start).joined() }
        mutating func append(_ text: String) {
            chunks.append(text); bytes += text.utf8.count
            while chunks.count - start > 4_000 || bytes > 16 * 1024 * 1024 {
                bytes -= chunks[start].utf8.count; start += 1
            }
            if start >= 1_000 { chunks.removeFirst(start); start = 0 }
        }
    }

    private struct UTF8StreamDecoder {
        private var pending: [UInt8] = []
        mutating func push(_ data: Data) -> String {
            pending.append(contentsOf: data)
            var boundary = pending.count
            if !pending.isEmpty {
                var lead = pending.count - 1
                while lead > 0 && pending[lead] & 0xc0 == 0x80 && pending.count - lead <= 3 { lead -= 1 }
                let byte = pending[lead]
                let expected = byte >= 0xc2 && byte <= 0xdf ? 2 : byte >= 0xe0 && byte <= 0xef ? 3 : byte >= 0xf0 && byte <= 0xf4 ? 4 : 1
                if expected > pending.count - lead { boundary = lead }
            }
            let text = String(decoding: pending.prefix(boundary), as: UTF8.self)
            pending.removeFirst(boundary)
            return text
        }
        mutating func finish() -> String {
            let result = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return result
        }
    }
}
