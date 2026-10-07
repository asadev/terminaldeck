import Foundation
import Darwin
import TerminalDeckNativeCore

/// The inspector is an MCP client. BackendNativeMCPServer and its HTTP/stdin
/// relay serve agent tools in the opposite direction and are not duplicated.
public protocol BackendMcpClientTransport: Sendable {
    var pid: Int? { get }
    var stderrTail: String { get }
    func start(stderr: @escaping @Sendable (String) -> Void, closed: @escaping @Sendable () -> Void) async throws
    func request(_ method: String, params: NativeRPCValue, timeout: Int, label: String) async throws -> NativeRPCValue
    func notify(_ method: String, params: NativeRPCValue) async throws
    func close() async
}
public extension BackendMcpClientTransport { var stderrTail: String { "" } }

public struct BackendMcpClientRPCFailure: Error, LocalizedError, Sendable {
    public let code: Int; public let message: String
    public var errorDescription: String? { "MCP error \(code): \(message)" }
    public init(code: Int, message: String) { self.code = code; self.message = message }
}

/// An unstructured race returns at its wall-clock deadline even when a supplied
/// dependency ignores cancellation. The late answer is consumed once only.
enum BackendMcpClientDeadline {
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock(); private var continuation: CheckedContinuation<T, any Error>?
        private var deadline: BackendMcpClientDeadlineTicket?
        init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
        func install(_ deadline: BackendMcpClientDeadlineTicket) {
            let cancel = lock.withLock { if continuation == nil { return true }; self.deadline = deadline; return false }
            if cancel { deadline.cancel() }
        }
        func finish(_ result: Result<T, any Error>) {
            let held = lock.withLock { let held = (continuation, deadline); continuation = nil; deadline = nil; return held }
            held.1?.cancel(); held.0?.resume(with: result)
        }
    }
    static func run<T: Sendable>(_ milliseconds: Int, label: String, scheduler: any BackendMcpClientDeadlineScheduling = BackendMcpClientDispatchScheduler(), work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation)
            let operation = Task { do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) } }
            let deadline = scheduler.schedule(milliseconds: milliseconds) {
                race.finish(.failure(BackendMcpClientValue.error("\(label) timed out after \(milliseconds)ms"))); operation.cancel()
            }
            race.install(deadline)
        }
    }
}

/// Real newline-framed stdio JSON-RPC, with per-request cancellation/deadlines,
/// unsolicited request refusals, piped stderr and process death propagation.
public final class BackendMcpClientStdioTransport: BackendMcpClientTransport, @unchecked Sendable {
    private struct Pending { let continuation: CheckedContinuation<NativeRPCValue, any Error>; var deadline: BackendMcpClientDeadlineTicket? }
    private let lock = NSLock(), writeLock = NSLock()
    private let receiveQueue = DispatchQueue(label: "terminaldeck.mcp-client.receive", qos: .utility)
    private let command: String; private let arguments: [String]; private let environment: [String: String]; private let cwd: String?
    private let scheduler: any BackendMcpClientDeadlineScheduling
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    private var running = false, starting = false, ended = false, sequence = 0
    private var pending: [Int: Pending] = [:]
    private var buffer = Data()
    private var stderrText = ""
    private var outputReader: DispatchSourceRead?, errorReader: DispatchSourceRead?
    private var onStderr: (@Sendable (String) -> Void)?, onClose: (@Sendable () -> Void)?
    public init(server: NativeRPCValue, environment: [String: String], scheduler: any BackendMcpClientDeadlineScheduling = BackendMcpClientDispatchScheduler()) throws {
        guard let command = server["command"].string, !command.isEmpty else { throw BackendMcpClientValue.error("This server has no command to run.") }
        self.command = command; arguments = (server["args"].elements ?? []).compactMap(\.string); self.environment = environment; cwd = server["cwd"].string; self.scheduler = scheduler
    }
    public var pid: Int? { lock.withLock { running && !ended ? Int(process.processIdentifier) : nil } }
    public var stderrTail: String { lock.withLock { stderrText } }
    public func start(stderr: @escaping @Sendable (String) -> Void, closed: @escaping @Sendable () -> Void) async throws {
        let canStart = lock.withLock { if starting || running || ended { return false }; starting = true; onStderr = stderr; onClose = closed; return true }
        guard canStart else { throw BackendMcpClientValue.error("Not connected.") }
        guard let path = BackendNativeProviders.lookup(command, path: environment["PATH"] ?? "") else { throw BackendMcpClientValue.error("spawn \(command) ENOENT") }
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments; process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let stdoutFD = output.fileHandleForReading.fileDescriptor, stderrFD = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderrFD, F_SETFL, fcntl(stderrFD, F_GETFL) | O_NONBLOCK)
        let stdoutReader = DispatchSource.makeReadSource(fileDescriptor: stdoutFD, queue: receiveQueue)
        let stderrReader = DispatchSource.makeReadSource(fileDescriptor: stderrFD, queue: receiveQueue)
        stdoutReader.setEventHandler { [weak self] in self?.drain(stdoutFD, stderr: false) }
        stderrReader.setEventHandler { [weak self] in self?.drain(stderrFD, stderr: true) }
        lock.withLock { outputReader = stdoutReader; errorReader = stderrReader }
        stdoutReader.resume(); stderrReader.resume()
        process.terminationHandler = { [weak self] _ in
            self?.receiveQueue.async { [weak self] in
                guard let self else { return }
                // Exit may race the last readable notification. Drain the same
                // descriptors on their single queue before failing requests.
                self.drain(stdoutFD, stderr: false); self.drain(stderrFD, stderr: true)
                self.finish(BackendMcpClientValue.error("The server exited."))
            }
        }
        do {
            guard lock.withLock({ !ended }) else { throw BackendMcpClientValue.error("Not connected.") }
            try process.run()
            let accepted = lock.withLock { starting = false; if ended { return false }; running = true; return true }
            if !accepted { terminateChild(); throw BackendMcpClientValue.error("Not connected.") }
        }
        catch { finish(error); throw error }
    }
    private func drain(_ descriptor: Int32, stderr: Bool) {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                let data = Data(bytes.prefix(count))
                if stderr {
                    let text = String(decoding: data, as: UTF8.self)
                    let callback = lock.withLock {
                        stderrText = String(decoding: (stderrText + text).utf16.suffix(8_000), as: UTF16.self)
                        return onStderr
                    }
                    callback?(text)
                } else { receive(data) }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count == 0 {
                if stderr { lock.withLock { errorReader }?.cancel() }
                else {
                    lock.withLock { outputReader }?.cancel()
                    drain(errors.fileHandleForReading.fileDescriptor, stderr: true)
                    finish(BackendMcpClientValue.error("The server exited.")); terminateChild()
                }
            }
            return
        }
    }
    public func request(_ method: String, params: NativeRPCValue, timeout: Int, label: String) async throws -> NativeRPCValue {
        let id = lock.withLock { sequence += 1; return sequence }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock {
                    if ended || !running { return false }; pending[id] = Pending(continuation: continuation, deadline: nil); return true
                }
                if !ready { continuation.resume(throwing: BackendMcpClientValue.error("Not connected.")); return }
                let deadline = scheduler.schedule(milliseconds: timeout) { [weak self] in
                    self?.fail(id, error: BackendMcpClientValue.error("\(label) timed out after \(timeout)ms"), cancel: true)
                }
                let cancelled = lock.withLock { if pending[id] != nil { pending[id]?.deadline = deadline; return false }; return true }
                if cancelled { deadline.cancel() }
                do { try write(.object([.init("jsonrpc", .string("2.0")), .init("id", .number(Double(id))), .init("method", .string(method)), .init("params", params)])) }
                catch { fail(id, error: error, cancel: false) }
                if Task.isCancelled { fail(id, error: CancellationError(), cancel: true) }
            }
        } onCancel: { [weak self] in self?.fail(id, error: CancellationError(), cancel: true) }
    }
    public func notify(_ method: String, params: NativeRPCValue) async throws {
        try write(.object([.init("jsonrpc", .string("2.0")), .init("method", .string(method)), .init("params", params)]))
    }
    private func write(_ message: NativeRPCValue) throws {
        let bytes = try message.encodedJSON() + Data([10])
        try writeLock.withLock {
            guard lock.withLock({ running && !ended }) else { throw BackendMcpClientValue.error("Not connected.") }
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
    }
    private func fail(_ id: Int, error: any Error, cancel: Bool) {
        let slot = lock.withLock { pending.removeValue(forKey: id) }; guard let slot else { return }
        slot.deadline?.cancel(); slot.continuation.resume(throwing: error)
        if cancel {
            try? write(.object([.init("jsonrpc", .string("2.0")), .init("method", .string("notifications/cancelled")), .init("params", .object([.init("requestId", .number(Double(id))), .init("reason", .string(error.localizedDescription))]))]))
        }
    }
    private func receive(_ bytes: Data) {
        if bytes.isEmpty { return }
        buffer.append(bytes)
        // Reuse the shared codec's supported 64 MiB envelope bound.
        if buffer.count > 67_108_864 { finish(BackendMcpClientValue.error("MCP frame is too large.")); terminateChild(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if frame.isEmpty { continue }
            do {
                let message = try NativeRPCValue.parseJSON(frame)
                guard message["jsonrpc"].string == "2.0" else { throw BackendMcpClientValue.error("Invalid MCP JSON-RPC envelope.") }
                if let method = message["method"].string {
                    if message["id"] != .missing {
                        var reply = NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", message["id"])])
                        if method == "ping" { reply = reply.setting("result", .object([])) }
                        else { reply = reply.setting("error", .object([.init("code", .number(-32601)), .init("message", .string("Method not found: " + method))])) }
                        try? write(reply)
                    }
                    continue
                }
                guard let n = message["id"].number, n.rounded() == n, n >= 0, n < Double(Int.max) else { continue }
                let slot = lock.withLock { pending.removeValue(forKey: Int(n)) }; guard let slot else { continue }; slot.deadline?.cancel()
                if message["error"].fields != nil {
                    let offered = message["error"]["code"].number ?? -32603
                    let code = offered >= Double(Int.min) && offered < Double(Int.max) ? offered : -32603
                    slot.continuation.resume(throwing: BackendMcpClientRPCFailure(code: Int(code), message: message["error"]["message"].string ?? "Unknown MCP error"))
                } else if message.has("result") { slot.continuation.resume(returning: message["result"]) }
                else { slot.continuation.resume(throwing: BackendMcpClientValue.error("Invalid MCP response.")) }
            } catch { lock.withLock { onStderr }?("\n[transport] " + error.localizedDescription) }
        }
    }
    private func finish(_ error: any Error) {
        let state: ([Pending], (@Sendable () -> Void)?) = lock.withLock {
            if ended { return ([], nil) }; ended = true
            let held = Array(pending.values); pending.removeAll(); let callback = onClose; onClose = nil; onStderr = nil; return (held, callback)
        }
        let readers = lock.withLock { let readers = [outputReader, errorReader]; outputReader = nil; errorReader = nil; return readers }
        for reader in readers { reader?.cancel() }
        for slot in state.0 { slot.deadline?.cancel(); slot.continuation.resume(throwing: error) }; state.1?()
    }
    public func close() async {
        finish(BackendMcpClientValue.error("Not connected.")); try? input.fileHandleForWriting.close()
        terminateChild()
    }
    private func terminateChild() {
        if process.isRunning {
            let processID = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in if process.isRunning { _ = Darwin.kill(processID, SIGKILL) } }
        }
    }
}
