import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func mcpParityJSON(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
func mcpParityOutcome(_ ok: Bool = true, stdout: String = "", stderr: String = "", missing: Bool = false) -> BackendGitOutcome {
    .init(ok: ok, stdout: stdout, stderr: stderr, missing: missing, exitCode: ok ? 0 : 1, timedOut: false)
}
func mcpParityAdd(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
    NativeRPCValue.object([.init("name", .string("files")), .init("scope", .string("user")), .init("transport", .string("stdio")), .init("command", .string("npx -y @modelcontextprotocol/server-filesystem /tmp")), .init("url", .string("")), .init("extras", .array([])), .init("projectPath", .null)]).merging(patch)
}
func mcpParityFailure(_ message: String, _ work: () throws -> Void) {
    do { try work(); Issue.record("Expected refusal: \(message)") } catch { #expect(error.localizedDescription == message) }
}

struct McpParityFixture: Sendable {
    let root: URL
    init(claude: NativeRPCValue = .object([])) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendMcpClientParity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try claude.encodedJSON().write(to: root.appendingPathComponent(".claude.json"))
    }
    func dispose() { try? FileManager.default.removeItem(at: root) }
    func writer(_ runs: McpParityRuns) -> BackendMcpClientWriter {
        .init(configuration: .init(home: root.path, environment: ["HOME": root.path, "PATH": "/inherited"]), loginPath: { "/usr/bin:/bin" }, run: { command, args, env, cwd, timeout in try await runs.run(command, args, env, cwd, timeout) })
    }
}
actor McpParityRuns {
    struct Call: Sendable { let command: String; let args: [String]; let env: [String: String]; let cwd: String; let timeout: Int }
    private var calls: [Call] = []
    private var responses: [BackendGitOutcome]
    private let found: Set<String>, names: [String], failShell: Bool
    init(responses: [BackendGitOutcome] = [], found: Set<String> = ["npx", "uvx", "docker", "claude"], names: [String] = [], failShell: Bool = false) {
        self.responses = responses; self.found = found; self.names = names; self.failShell = failShell
    }
    func run(_ command: String, _ args: [String], _ env: [String: String], _ cwd: String, _ timeout: Int) throws -> BackendGitOutcome {
        calls.append(.init(command: command, args: args, env: env, cwd: cwd, timeout: timeout))
        if !responses.isEmpty { return responses.removeFirst() }
        if command == "which" { let binary = args[0]; return mcpParityOutcome(found.contains(binary), stdout: found.contains(binary) ? "/usr/bin/\(binary)\n" : "") }
        if command == "claude" { return mcpParityOutcome() }
        if failShell { throw NativeRPCError(code: "fixture", message: "no shell") }
        return mcpParityOutcome(stdout: names.joined(separator: "\n"))
    }
    func snapshot() -> [Call] { calls }
}

actor McpParityGate<T: Sendable> {
    private var result: Swift.Result<T, any Error>?
    private var waiting: [CheckedContinuation<T, any Error>] = []
    func wait() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func finish(_ answer: Swift.Result<T, any Error>) {
        guard result == nil else { return }; result = answer
        let held = waiting; waiting.removeAll(); for continuation in held { continuation.resume(with: answer) }
    }
    func succeed(_ value: T) { finish(.success(value)) }
    func fail(_ error: any Error) { finish(.failure(error)) }
}

/// Runs the production race's scheduled closure after explicit fake time moves.
/// No sleeps, wall-clock probes, external processes or busy polling occur.
final class McpParityClock: BackendMcpClientDeadlineScheduling, @unchecked Sendable {
    private struct Job { let id: Int; let due: Int; let milliseconds: Int; let fire: @Sendable () -> Void }
    private let lock = NSLock(); private var now = 0, sequence = 0
    private var jobs: [Int: Job] = [:]
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var recorded: [Int] = []
    func schedule(milliseconds: Int, fire: @escaping @Sendable () -> Void) -> BackendMcpClientDeadlineTicket {
        let (id, callbacks) = lock.withLock {
            sequence += 1; let id = sequence; recorded.append(milliseconds)
            jobs[id] = Job(id: id, due: now + milliseconds, milliseconds: milliseconds, fire: fire)
            let callbacks = watchers.filter { $0.0 == milliseconds }.map(\.1); watchers.removeAll { $0.0 == milliseconds }
            return (id, callbacks)
        }
        for callback in callbacks { callback.resume() }
        return .init { [weak self] in self?.lock.withLock { self?.jobs[id] = nil } }
    }
    func whenScheduled(_ milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if jobs.values.contains(where: { $0.milliseconds == milliseconds }) { return true }; watchers.append((milliseconds, continuation)); return false }
            if ready { continuation.resume() }
        }
    }
    func advance(_ milliseconds: Int) {
        let due = lock.withLock {
            now += milliseconds; let due = jobs.values.filter { $0.due <= now }.sorted { $0.due == $1.due ? $0.id < $1.id : $0.due < $1.due }
            for job in due { jobs[job.id] = nil }; return due
        }
        for job in due { job.fire() }
    }
    var durations: [Int] { lock.withLock { recorded } }
    var pending: Int { lock.withLock { jobs.count } }
}

actor McpParityEvents {
    private var statuses: [NativeRPCValue] = []
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
    func record(_ status: NativeRPCValue) {
        statuses.append(status)
        let ready = watchers.filter { $0.0 <= statuses.count }.map(\.1); watchers.removeAll { $0.0 <= statuses.count }
        for continuation in ready { continuation.resume() }
    }
    func whenCount(_ count: Int) async { if statuses.count >= count { return }; await withCheckedContinuation { watchers.append((count, $0)) } }
    func snapshot() -> [NativeRPCValue] { statuses }
}

final class McpParityTransport: BackendMcpClientTransport, @unchecked Sendable {
    typealias Handler = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    let pid: Int? = 321
    private let lock = NSLock()
    private let capabilities: NativeRPCValue, startError: String?, startGate: McpParityGate<Void>?, handler: Handler?
    private var onClose: (@Sendable () -> Void)?, starts = 0, closes = 0, methods: [(String, NativeRPCValue, Int, String)] = []
    let started = McpParityGate<Void>(), initializeEntered = McpParityGate<Void>()
    init(capabilities: NativeRPCValue = .object([.init("tools", .object([]))]), startError: String? = nil, startGate: McpParityGate<Void>? = nil, handler: Handler? = nil) {
        self.capabilities = capabilities; self.startError = startError; self.startGate = startGate; self.handler = handler
    }
    var counts: (Int, Int) { lock.withLock { (starts, closes) } }
    var calls: [(String, NativeRPCValue, Int, String)] { lock.withLock { methods } }
    func start(stderr: @escaping @Sendable (String) -> Void, closed: @escaping @Sendable () -> Void) async throws {
        lock.withLock { starts += 1; onClose = closed }; await started.succeed(())
        if let startError { throw NativeRPCError(code: "fixture", message: startError) }
        if let startGate { try await startGate.wait() }
    }
    func request(_ method: String, params: NativeRPCValue, timeout: Int, label: String) async throws -> NativeRPCValue {
        lock.withLock { methods.append((method, params, timeout, label)) }
        if method == "initialize" { await initializeEntered.succeed(()) }
        if let handler { return try await handler(method, params) }
        if method == "initialize" { return Self.initialize(capabilities) }
        throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found: " + method)
    }
    static func initialize(_ capabilities: NativeRPCValue = .object([.init("tools", .object([]))])) -> NativeRPCValue {
        .object([.init("protocolVersion", .string("2025-06-18")), .init("capabilities", capabilities), .init("serverInfo", .object([.init("name", .string("fake-server")), .init("version", .string("9.9.9"))])), .init("instructions", .string("Be careful."))])
    }
    func notify(_ method: String, params: NativeRPCValue) async throws {}
    func close() async { lock.withLock { closes += 1 }; die() }
    func die() { lock.withLock { onClose }?() }
}

final class McpParityFactory: @unchecked Sendable {
    private let lock = NSLock(); private var transports: [McpParityTransport]; private var made = 0
    init(_ transports: [McpParityTransport]) { self.transports = transports }
    func create(_ server: NativeRPCValue, _ env: [String: String]) throws -> any BackendMcpClientTransport {
        try lock.withLock { guard !transports.isEmpty else { throw NativeRPCError(code: "fixture", message: "Unexpected second process") }; made += 1; return transports.removeFirst() }
    }
    var count: Int { lock.withLock { made } }
}
func mcpParityServer(_ patch: NativeRPCValue = .object([])) throws -> NativeRPCValue {
    try #require(BackendMcpClientConfiguration.parse(name: "fake", raw: .object([.init("command", .string("node")), .init("args", .array([.string("server.js")]))]), scope: "user", source: "/tmp/fixture/.claude.json", environment: [:])).merging(patch)
}
func mcpParityPool(_ factory: McpParityFactory, clock: McpParityClock, events: McpParityEvents = .init(), env: (@Sendable () async throws -> String)? = nil, overrides: NativeRPCValue = .object([])) -> BackendMcpClientPool {
    .init(configuration: .init(home: "/tmp/unused-fixture", environment: [:]), loginPath: env ?? { "/usr/bin" }, timeouts: .init(overrides: overrides),
          factory: { try factory.create($0, $1) }, scheduler: clock, onStatus: { await events.record($0) })
}
func mcpParityTool(_ name: String = "echo") -> NativeRPCValue {
    .object([.init("name", .string(name)), .init("description", .string("Echoes a message")), .init("inputSchema", .object([.init("type", .string("object")), .init("properties", .object([.init("message", .object([.init("type", .string("string"))]))])), .init("required", .array([.string("message")]))]))])
}
