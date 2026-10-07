import Foundation
import Darwin
import TerminalDeckNativeCore

public protocol BackendDevSessionAccess: Sendable {
    /// This actual opener must preserve the local/device grant and confinement
    /// path. A development command is typed into a real visible shell session.
    func openShell(folder: String, context: NativeRPCContext) async throws -> String
    func type(sessionID: String, text: String, context: NativeRPCContext) async throws
    func output(sessionID: String, context: NativeRPCContext) async throws -> String
    func alive(sessionID: String) async -> Bool
}
public struct BackendDevSessionAdapter: BackendDevSessionAccess, Sendable {
    private let manager: BackendPTYManager
    private let open: @Sendable (String, NativeRPCContext) async throws -> String
    private let authorize: @Sendable (String, NativeRPCContext) async throws -> Void
    public init(manager: BackendPTYManager, openShell: @escaping @Sendable (String, NativeRPCContext) async throws -> String,
                authorizeSession: @escaping @Sendable (String, NativeRPCContext) async throws -> Void) {
        self.manager = manager; open = openShell; authorize = authorizeSession
    }
    public func openShell(folder: String, context: NativeRPCContext) async throws -> String { try await open(folder, context) }
    public func type(sessionID: String, text: String, context: NativeRPCContext) async throws { try await authorize(sessionID, context); try manager.write(sessionID, data: text) }
    public func output(sessionID: String, context: NativeRPCContext) async throws -> String { try await authorize(sessionID, context); return manager.scrollback(sessionID) }
    public func alive(sessionID: String) async -> Bool { manager.pidOf(sessionID) != nil }
}

/// dev-server.ts's real state machine: lockfile-selected declared scripts,
/// deduplicated starts, fresh baseline ports, actual loopback readiness and
/// useful failure sessions left intact. No job starts during construction.
/// What the dev-server job needs from port discovery; a test supplies a fake scan.
public protocol BackendDevPortScanning: Sendable {
    func scan(force: Bool) async throws -> [BackendDevPort]
}
extension BackendDevPortScanning {
    public func scan() async throws -> [BackendDevPort] { try await scan(force: false) }
}
extension BackendDevPortDiscovery: BackendDevPortScanning {}

public actor BackendDevServers {
    private let files: BackendFilesystemService
    private let sessions: any BackendDevSessionAccess
    private let ports: any BackendDevPortScanning
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private final class Entry: @unchecked Sendable {
        let id = UUID(); var state: NativeRPCValue; var task: Task<Void, Never>?
        init(_ state: NativeRPCValue) { self.state = state }
    }
    private var entries: [String: Entry] = [:]
    private var starts: [String: Task<NativeRPCValue, any Error>] = [:]
    private var listeners: [UUID: @Sendable (NativeRPCValue) async -> Void] = [:]
    private var logListeners: [UUID: @Sendable (String, String) async -> Void] = [:]
    private var stopped = false
    public init(files: BackendFilesystemService, sessions: any BackendDevSessionAccess, ports: any BackendDevPortScanning,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.files = files; self.sessions = sessions; self.ports = ports; self.now = now; self.sleep = sleep
    }
    public func status(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let key = Self.folderKey(folder)
        if let entry = entries[key] {
            if ["starting", "ready"].contains(entry.state["status"].string ?? ""), let id = entry.state["sessionId"].string, !(await sessions.alive(sessionID: id)) {
                let state = try await resting(folder, context: context)
                // TS statusOf decides and sets in one synchronous step. Here the folder read
                // suspends, and the watcher may have recorded the failure meanwhile: a
                // `failed` is a report and must not be overwritten by the idle answer.
                guard Self.stillLive(entry, key: key, sessionID: id, in: entries) else { return entry.state }
                await set(entry, state); return state
            }
            return entry.state
        }
        return try await resting(folder, context: context)
    }
    public func start(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard !stopped else { throw NativeRPCError(code: "closed", message: "Development services have stopped") }
        let key = Self.folderKey(folder)
        if let pending = starts[key] { return try await pending.value }
        let task = Task { try await self.begin(folder: folder, context: context) }
        starts[key] = task
        defer { starts[key] = nil }
        return try await task.value
    }
    private func begin(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let state = try await status(folder: folder, context: context)
        if ["starting", "ready"].contains(state["status"].string ?? "") { return state }
        let rest = try await resting(folder, context: context)
        if rest["status"].string == "no-dev-script" { return rest }
        let key = Self.folderKey(folder), entry = Entry(rest)
        entries[key]?.task?.cancel(); entries[key] = entry
        let before: Set<Int>
        do { before = Set(try await ports.scan(force: true).map(\.port)) }
        catch { await fail(entry, sessionID: nil, message: "This machine could not say which ports are already in use, so nothing was started."); return entry.state }
        try Task.checkCancellation()
        let id: String
        do { id = try await sessions.openShell(folder: folder, context: context) }
        catch { await fail(entry, sessionID: nil, message: (error as? LocalizedError)?.errorDescription ?? "The session could not be opened."); return entry.state }
        let starting = rest.setting("status", .string("starting")).setting("sessionId", .string(id))
        await set(entry, starting)
        entry.task = Task { [weak self] in await self?.run(entry: entry, key: key, sessionID: id, before: before, context: context) }
        return starting
    }
    private func run(entry: Entry, key: String, sessionID: String, before: Set<Int>, context: NativeRPCContext) async {
        do {
            let promptDeadline = now().addingTimeInterval(3)
            while now() < promptDeadline {
                try Task.checkCancellation()
                guard current(entry, key: key) else { return }
                guard await sessions.alive(sessionID: sessionID) else { await fail(entry, sessionID: sessionID, message: "The session ended before the command could be run."); return }
                if !(try await sessions.output(sessionID: sessionID, context: context)).isEmpty { break }
                try await sleep(.milliseconds(50))
            }
            guard current(entry, key: key) else { return }
            guard await sessions.alive(sessionID: sessionID) else { await fail(entry, sessionID: sessionID, message: "The session ended before the command could be run."); return }
            try await sessions.type(sessionID: sessionID, text: (entry.state["command"].string ?? "") + "\r", context: context)
            let deadline = now().addingTimeInterval(90)
            while now() < deadline {
                try await sleep(.milliseconds(750)); try Task.checkCancellation()
                guard current(entry, key: key) else { return }
                let output = try await sessions.output(sessionID: sessionID, context: context)
                let tail = String(output.suffix(16 * 1024))
                if let note = Self.latestLine(tail), note != entry.state["note"].string { await set(entry, entry.state.setting("note", .string(note))) }
                var candidates = Self.portsInOutput(tail).filter { !before.contains($0) }.map { (port: $0, v4: true, v6: true) }
                if let scanned = try? await ports.scan() {
                    for port in scanned where !before.contains(port.port) && !candidates.contains(where: { $0.port == port.port }) {
                        candidates.append((port.port, port.ipv4, port.ipv6))
                    }
                }
                for candidate in candidates {
                    for host in (candidate.v4 ? ["127.0.0.1"] : []) + (candidate.v6 ? ["::1"] : []) {
                        guard current(entry, key: key) else { return }
                        if await BackendDevDialer.dial(port: candidate.port, host: host, timeoutMilliseconds: 1_000) {
                            let ready = Self.state(folder: entry.state["folder"].string ?? key, status: "ready", script: entry.state["script"].string,
                                command: entry.state["command"].string, sessionID: sessionID).setting("port", .number(Double(candidate.port))).setting("url", .string("http://localhost:\(candidate.port)"))
                            await set(entry, ready); return
                        }
                    }
                }
                if !(await sessions.alive(sessionID: sessionID)) {
                    // TS dev-server.ts watch: `${entry.state.command ?? 'The command'} exited without anything listening. …`
                    await fail(entry, sessionID: sessionID, message: (entry.state["command"].string ?? "The command") + " exited without anything listening. Its output is in the session it ran in."); return
                }
            }
            if current(entry, key: key) { await fail(entry, sessionID: sessionID, message: "Nothing accepted a connection within 90 seconds. The command is still running, so its output will say why.") }
        } catch is CancellationError { return }
        catch { if current(entry, key: key) { await fail(entry, sessionID: sessionID, message: "This machine stopped being able to tell whether the dev server came up.") } }
    }
    /// Root forwards real PTY data/exit events here. Logs remain per session;
    /// subscribers are authorized by the integration factory's actual scope.
    public func received(sessionID: String, text: String) async {
        guard entries.values.contains(where: { $0.state["sessionId"].string == sessionID }) else { return }
        for listener in logListeners.values { await listener(sessionID, text) }
    }
    public func noteExit(sessionID: String, context: NativeRPCContext) async {
        for entry in entries.values where entry.state["sessionId"].string == sessionID && ["starting", "ready"].contains(entry.state["status"].string ?? "") {
            entry.task?.cancel()
            let key = Self.folderKey(entry.state["folder"].string ?? "")
            if let state = try? await resting(entry.state["folder"].string ?? "", context: context),
               Self.stillLive(entry, key: key, sessionID: sessionID, in: entries) { await set(entry, state) }
        }
    }
    public func onChange(_ listener: @escaping @Sendable (NativeRPCValue) async -> Void) -> UUID { let id = UUID(); listeners[id] = listener; return id }
    public func onLog(_ listener: @escaping @Sendable (String, String) async -> Void) -> UUID { let id = UUID(); logListeners[id] = listener; return id }
    public func removeListener(_ id: UUID) { listeners[id] = nil; logListeners[id] = nil }
    public func stop() { stopped = true; starts.values.forEach { $0.cancel() }; starts.removeAll(); entries.values.forEach { $0.task?.cancel() }; listeners.removeAll(); logListeners.removeAll() }
    private func current(_ entry: Entry, key: String) -> Bool { !stopped && entries[key]?.id == entry.id }
    /// Still the folder's entry, still starting or ready on that same session.
    private static func stillLive(_ entry: Entry, key: String, sessionID: String, in entries: [String: Entry]) -> Bool {
        entries[key]?.id == entry.id && ["starting", "ready"].contains(entry.state["status"].string ?? "") && entry.state["sessionId"].string == sessionID
    }
    private func set(_ entry: Entry, _ value: NativeRPCValue) async { entry.state = value; for listener in listeners.values { await listener(value) } }
    private func fail(_ entry: Entry, sessionID: String?, message: String) async {
        await set(entry, Self.state(folder: entry.state["folder"].string ?? "", status: "failed", script: entry.state["script"].string,
            command: entry.state["command"].string, sessionID: sessionID).setting("message", .string(message)))
    }
    private func resting(_ folder: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        _ = try await files.authority.authorize(folder, context: context)
        let package = try? await files.read(root: folder, relative: "package.json", context: context)
        guard package?["kind"].string == "text", (package?["bytes"].number ?? .infinity) <= 1_024 * 1_024,
              let text = package?["text"].string, let body = try? NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: 1_024 * 1_024), body["scripts"].fields != nil else { return Self.state(folder: folder, status: "no-dev-script") }
        guard let script = ["dev", "start", "serve"].first(where: { !(body["scripts"][$0].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return Self.state(folder: folder, status: "no-dev-script") }
        var manager = "npm"
        for (file, candidate) in [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun"), ("package-lock.json", "npm"), ("npm-shrinkwrap.json", "npm")] {
            if (try? await files.authority.resolve(root: folder, relative: file, context: context)) != nil { manager = candidate; break }
        }
        return Self.state(folder: folder, status: "idle", script: script, command: manager + " run " + script)
    }
    private static func state(folder: String, status: String, script: String? = nil, command: String? = nil, sessionID: String? = nil) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("folder", .string(folder)), .init("status", .string(status))]
        if let script { fields.append(.init("script", .string(script))) }; if let command { fields.append(.init("command", .string(command))) }; if let sessionID { fields.append(.init("sessionId", .string(sessionID))) }
        return .object(fields)
    }
    private static func folderKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    public static func portsInOutput(_ text: String) -> [Int] {
        var found: [Int] = []
        for pattern in [#"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|::1?):(\d{1,5})"#, #"\bport\s+(\d{1,5})\b"#] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), let port = Int(text[range]), (1...65_535).contains(port), !found.contains(port) { found.append(port) }
            }
        }
        return found
    }
    public static func latestLine(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: #"\x1b\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression).replacingOccurrences(of: "\r", with: "\n")
        return clean.components(separatedBy: "\n").reversed().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }.map { String($0.prefix(200)) }
    }
}
