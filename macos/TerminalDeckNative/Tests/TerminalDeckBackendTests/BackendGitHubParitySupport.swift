import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

func BackendGitHubParityJSON(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
func BackendGitHubParityObject(_ values: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendGitHubRules.object(values) }
func BackendGitHubParityOutcome(stdout: String = "", stderr: String = "", code: Int = 0, missing: Bool = false, timedOut: Bool = false) -> BackendGitOutcome {
    BackendGitOutcome(ok: code == 0 && !missing && !timedOut, stdout: stdout, stderr: stderr, missing: missing, exitCode: code, timedOut: timedOut)
}
func BackendGitHubParityDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackendGitHubParity-" + label + "-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
final class BackendGitHubParityClock: @unchecked Sendable {
    private let lock = NSLock(); private var time: Double
    init(_ time: Double = 0) { self.time = time }
    func now() -> Double { lock.withLock { time } }
    func set(_ value: Double) { lock.withLock { time = value } }
}
actor BackendGitHubParityLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let all = waiters; waiters.removeAll(); for waiter in all { waiter.resume() } }
}
actor BackendGitHubParityCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
    func value() -> Int { count }
}
actor BackendGitHubParityTools: BackendGitHubToolRunning {
    struct Call: Sendable { let tool: String; let args: [String]; let cwd: String?; let environment: [String: String]; let timeout: Int; let maximum: Int }
    private let responder: @Sendable (Call) async throws -> BackendGitOutcome
    private var seen: [Call] = []
    init(_ responder: @escaping @Sendable (Call) async throws -> BackendGitOutcome) { self.responder = responder }
    func calls() -> [Call] { seen }
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        let call = Call(tool: tool, args: arguments, cwd: cwd, environment: environment, timeout: timeoutMilliseconds, maximum: maximumBytes)
        seen.append(call); return try await responder(call)
    }
}
actor BackendGitHubParityCLI: BackendGitHubToolRunning {
    private var token: String?, installed: Bool
    private var seen: [[String]] = []
    init(token: String? = nil, installed: Bool = true) { self.token = token; self.installed = installed }
    func setToken(_ value: String?) { token = value }
    func calls() -> [[String]] { seen }
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        seen.append(arguments)
        guard installed else { return BackendGitHubParityOutcome(stderr: "spawn gh ENOENT", code: 127, missing: true) }
        if arguments == ["--version"] { return BackendGitHubParityOutcome(stdout: "gh version 2.87.3\n") }
        if arguments.prefix(2) == ["auth", "token"] { return token.map { BackendGitHubParityOutcome(stdout: $0 + "\n") } ?? BackendGitHubParityOutcome(stderr: "gh: not logged in to github.com", code: 1) }
        if arguments.prefix(2) == ["auth", "logout"] { token = nil; return BackendGitHubParityOutcome() }
        throw NativeRPCError(code: "unexpected-fake-call", message: "Unexpected fake gh call")
    }
}
actor BackendGitHubParityHTTP: BackendGitHubHTTPFetching {
    struct Call: Sendable { let url: String; let method: String; let headers: [String: String]; let body: String?; let timeout: Int }
    private let responder: @Sendable (Call) async throws -> BackendGitHubHTTPResponse
    private var seen: [Call] = []
    init(_ responder: @escaping @Sendable (Call) async throws -> BackendGitHubHTTPResponse) { self.responder = responder }
    func calls() -> [Call] { seen }
    func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        let call = Call(url: url, method: method, headers: headers, body: body, timeout: timeoutMilliseconds)
        seen.append(call); return try await responder(call)
    }
}
/// A controllable sleep: no timer, Task.sleep or spin loop. Cancellation before
/// registration is remembered so a cancelled flow cannot strand a continuation.
actor BackendGitHubParitySleeper {
    private var delays: [Double] = [], pending: [UUID: CheckedContinuation<Void, Error>] = [:], cancelled: Set<UUID> = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private let immediate: Bool
    init(immediate: Bool = false) { self.immediate = immediate }
    func sleep(_ delay: Double) async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: { () async throws -> Void in
            try Task.checkCancellation()
            try await self.suspend(id, delay)
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func suspend(_ id: UUID, _ delay: Double) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delays.append(delay)
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if immediate { continuation.resume() }
                else { pending[id] = continuation }
                notify()
            }
        }
    }
    private func cancel(_ id: UUID) { if let value = pending.removeValue(forKey: id) { value.resume(throwing: CancellationError()) } else { cancelled.insert(id) } }
    private func notify() { let ready = observers.filter { delays.count >= $0.0 }; observers.removeAll { delays.count >= $0.0 }; for observer in ready { observer.1.resume() } }
    func waitForCount(_ count: Int) async { if delays.count >= count { return }; await withCheckedContinuation { observers.append((count, $0)) } }
    func values() -> [Double] { delays }
    func resumeAll() { let all = pending.values; pending.removeAll(); for value in all { value.resume() } }
}
