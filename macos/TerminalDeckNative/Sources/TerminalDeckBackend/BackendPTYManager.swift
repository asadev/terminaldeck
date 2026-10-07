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
    private var remoteServeObservers: [UUID: @Sendable (BackendRemoteServePTYEvent) -> Void] = [:]

    private final class Session: @unchecked Sendable {
        var meta: BackendSessionMeta
        let process: BackendPTYProcess
        let terminal: ShadowTerminal
        var replay = ReplayBuffer()
        var decoder = UTF8StreamDecoder()
        var status: BackendSessionStatus = .idle
        var settle: DispatchWorkItem?
        var watching = true
        var removed = false

        init(meta: BackendSessionMeta, process: BackendPTYProcess, terminal: ShadowTerminal) {
            self.meta = meta; self.process = process; self.terminal = terminal
        }
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
    private var openShim: (directory: String, browser: String)?
    public func setOpenShim(directory: String?, browser: String?) {
        synchronized { openShim = directory.flatMap { dir in browser.map { (dir, $0) } } }
    }

    public init(inheritedEnvironment: [String: String], onEvent: @escaping @Sendable (BackendSessionEvent) -> Void) {
        self.inheritedEnvironment = inheritedEnvironment
        self.onEvent = onEvent
        queue.setSpecific(key: queueKey, value: 1)
    }

    @discardableResult
    public func create(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec) throws -> BackendSessionMeta {
        try synchronized {
            guard !shuttingDown else { throw BackendSessionFailure.closed }
            try Self.validateDimensions(cols: input.cols, rows: input.rows)
            guard input.cwd.hasPrefix("/"), !input.cwd.contains("\0"), !spawn.provider.isEmpty else {
                throw BackendSessionFailure.invalidInput("A session needs an absolute working folder and a resolved provider.")
            }
            let id = UUID().uuidString.lowercased()
            var env = try BackendSessionEnvironment.forSession(id: id, inherited: inheritedEnvironment, spawn: spawn)
            if let shim = openShim {
                env["PATH"] = BackendMacAppHandoffOpenShim.prepend(path: env["PATH"] ?? "", shim: shim.directory)
                env["BROWSER"] = shim.browser
            }
            let cwd = spawn.hostCwd ?? input.cwd
            let process: BackendPTYProcess
            do {
                let executable = try Self.executable(spawn.command, path: env["PATH"] ?? "", cwd: cwd)
                process = try BackendPTYProcess.spawn(command: executable, args: spawn.args, environment: env,
                    cwd: cwd, cols: input.cols, rows: input.rows, queue: queue)
            } catch let error as BackendSessionFailure {
                guard case .operatingSystem = error else { throw error }
                throw BackendSessionFailure.launch(provider: spawn.provider, cwd: input.cwd,
                    command: spawn.command, processCwd: cwd, cause: error.errorDescription)
            }
            let meta = BackendSessionMeta(id: id, input: input, spawn: spawn)
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

    public func list() -> [BackendSessionMeta] { synchronized { order.compactMap { sessions[$0]?.meta } } }

    /// Remote-serve attach replay: the snapshot and the event sequence come from
    /// the single PTY owner queue, so a replay and the events after it never
    /// overlap or leave a gap.
    public func remoteServeSnapshot(_ id: String) -> BackendRemoteServePTYSnapshot? {
        synchronized {
            guard let session = sessions[id] else { return nil }
            return .init(sequence: remoteServeSequence, session: session.meta,
                         replay: session.replay.text, status: session.status)
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
        remoteServeSequence &+= 1
        let sequenced = BackendRemoteServePTYEvent(sequence: remoteServeSequence, event: event)
        for observer in Array(remoteServeObservers.values) { observer(sequenced) }
        onEvent(event)
    }

    /// Parser-only test seam using the actual production viewport helper.
    /// Does not create a PTY, process, session state or timer.
    static func viewportForTesting(cols: Int, rows: Int, chunks: [Data]) throws -> String {
        try validateDimensions(cols: cols, rows: rows)
        let shadow = ShadowTerminal(cols: cols, rows: rows)
        for chunk in chunks { shadow.terminal.feed(byteArray: Array(chunk)) }
        return shadow.viewport()
    }

    public func write(_ id: String, data: String) throws {
        try write(id, bytes: Data(data.utf8))
    }

    public func write(_ id: String, bytes: Data) throws {
        try synchronized {
            guard let session = sessions[id] else { throw BackendSessionFailure.missingSession }
            guard session.meta.exitCode == nil else { throw BackendSessionFailure.exitedSession }
            // Public route to SwiftTerm's input heuristic (registerUserInput is
            // internal): sendUserInput runs it, then forwards to the delegate,
            // whose send is a no-op for this shadow, so the bytes go out once, below.
            session.terminal.terminal.sendUserInput(Array(bytes)[...])
            try session.process.write(bytes)
        }
    }

    public func resize(_ id: String, cols: Int, rows: Int) throws {
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
        synchronized { sessions[id]?.replay.text ?? "" }
    }

    public func scrollbackText(_ id: String) -> String? {
        synchronized {
            guard let session = sessions[id] else { return nil }
            return String(decoding: session.terminal.terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        }
    }

    public func screen(_ id: String) -> String? { synchronized { sessions[id]?.terminal.viewport() } }

    public func pidOf(_ id: String) -> Int32? {
        synchronized {
            guard let session = sessions[id], session.meta.exitCode == nil, !session.process.exited else { return nil }
            return session.process.pid
        }
    }

    @discardableResult
    public func rename(_ id: String, title: String) -> Bool {
        synchronized {
            guard let session = sessions[id] else { return false }
            let given = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = URL(fileURLWithPath: session.meta.cwd).lastPathComponent
            session.meta.title = given.isEmpty ? (folder.isEmpty ? session.meta.cwd : folder) : given
            return true
        }
    }

    @discardableResult
    public func setAccount(_ id: String, account: BackendAccountIdentity, home: String?) -> BackendSessionMeta? {
        synchronized {
            guard let session = sessions[id] else { return nil }
            session.meta.profileId = account.id
            session.meta.profileName = account.name
            session.meta.homeProfileId = home == account.id ? nil : home
            return session.meta
        }
    }

    public func setAgentSessionId(_ id: String, conversationId: String) {
        synchronized { sessions[id]?.meta.agentSessionId = conversationId }
    }

    public func kill(_ id: String, reason: BackendRemovalReason = .stopped) {
        synchronized { remove(id, reason: reason) }
    }

    public func killAll() {
        synchronized { for id in order { remove(id, reason: .stopped) } }
    }

    /// Stop accepting new launches, signal every owned group, then let drain()
    /// confirm exits before the root closes stores or the app terminates.
    public func beginShutdown() {
        synchronized {
            shuttingDown = true
            for id in order { remove(id, reason: .stopped) }
        }
    }

    public func setWatched(_ value: Bool) {
        synchronized {
            guard value != watched else { return }
            watched = value
            for session in sessions.values where session.meta.exitCode == nil {
                session.watching = value
                session.settle?.cancel(); session.settle = nil
                if value { setStatus(session, next: BackendSessionClassifier.classify(viewport: session.terminal.viewport())) }
            }
        }
    }

    /// Event-driven wait, with one timeout per caller and no polling loop.
    public func drain(timeoutMilliseconds: Int = 2_000) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !processes.isEmpty else { continuation.resume(returning: true); return }
                let id = UUID()
                let timeout = DispatchWorkItem { [weak self] in
                    guard let waiter = self?.drainWaiters.removeValue(forKey: id) else { return }
                    waiter.continuation.resume(returning: false)
                }
                drainWaiters[id] = DrainWaiter(continuation: continuation, timeout: timeout)
                queue.asyncAfter(deadline: .now() + .milliseconds(max(timeoutMilliseconds, 0)), execute: timeout)
            }
        }
    }

    private func remove(_ id: String, reason: BackendRemovalReason) {
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
        let text = session.decoder.push(bytes)
        if !text.isEmpty {
            session.replay.append(text)
            emit(.data(id: id, text: text))
        }
        guard session.watching, session.meta.exitCode == nil else { return }
        setStatus(session, next: .working)
        session.settle?.cancel()
        let settle = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, !session.removed, session.meta.exitCode == nil, session.watching else { return }
            self.setStatus(session, next: BackendSessionClassifier.classify(viewport: session.terminal.viewport()))
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
