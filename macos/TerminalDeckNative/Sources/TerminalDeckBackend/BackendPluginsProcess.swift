import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendPluginsError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// plugins/process.ts: bidirectional JSON-RPC lines on three owned pipes, on the standard child
/// runner (`NativeChild`): the plugin leads its own process group, so a kill or its own exit takes
/// everything it started with it. Constructing the actor starts nothing; only start() creates a process.
public actor BackendPluginsProcess {
    public typealias RequestHandler = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public let id = UUID()
    private let command: String, args: [String], cwd: String, env: [String: String]
    private let onRequest: RequestHandler
    private let onExit: @Sendable (String) async -> Void
    private let timeout: Int, maximum: Int
    private var child: NativeChild?
    private let ioQueue = DispatchQueue(label: "dev.terminaldeck.plugins.pipes")
    private enum IOEvent: Sendable { case output(Data, @Sendable () -> Void), error(Data, @Sendable () -> Void), exit(Int32, Bool) }
    private var events: AsyncStream<IOEvent>.Continuation?
    private var receiving: Task<Void, Never>?
    private var buffer = Data(), stderrTail = ""
    private var inFlight = 0, nextID = 1
    private var exited = false, killed = false, reason: String?
    private struct Pending {
        let continuation: CheckedContinuation<NativeRPCValue, any Error>
        let timer: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    private var stopped: [CheckedContinuation<Void, Never>] = []
    private var stopTimer: Task<Void, Never>?
    public init(command: String, arguments: [String], cwd: String, environment: [String: String],
                timeoutMilliseconds: Int = 30_000, maximumBytes: Int = 256 * 1024,
                onRequest: @escaping RequestHandler, onExit: @escaping @Sendable (String) async -> Void) {
        self.command = command; args = arguments; self.cwd = cwd; env = environment
        timeout = max(timeoutMilliseconds, 1); maximum = max(maximumBytes, 64)
        self.onRequest = onRequest; self.onExit = onExit
    }
    public var alive: Bool { child != nil && !exited && !killed }
    public var pid: Int32? { child?.pid }
    public func start() throws {
        guard child == nil, !exited else { throw BackendPluginsError(-32000, "plugins: a process is started once") }
        let pair = AsyncStream<IOEvent>.makeStream()
        events = pair.continuation
        receiving = Task { [weak self] in
            for await event in pair.stream {
                switch event {
                case .output(let data, let consumed): await self?.receive(data); consumed()
                case .error(let data, let consumed): await self?.receiveStderr(data); consumed()
                case let .exit(code, signal): await self?.gone(code: code, signal: signal)
                }
            }
        }
        // The runner sets NOSIGPIPE on its input: a child that exits before reading its last request
        // must not SIGPIPE this whole process (Node answers EPIPE instead); the write then simply fails.
        // Its exit comes on the same serial queue after every byte, so all trailing output is emitted first.
        // Process resolved both paths against this process's folder; the runner takes whole paths.
        let spec = NativeChild.Spec(URL(fileURLWithPath: command).path, args, environment: env, cwd: URL(fileURLWithPath: cwd).path, input: .pipe)
        do {
            child = try NativeChild.start(spec, queue: ioQueue,
                output: { Self.emit($0, error: false, to: pair.continuation) },
                errors: { Self.emit($0, error: true, to: pair.continuation) },
                // Process reported a signal's own number; the runner reports it apart from 128 + it.
                exit: { end in pair.continuation.yield(.exit(end.signal ?? end.code, end.signal != nil)); pair.continuation.finish() })
        } catch { awaitGone("it could not be started (\(error.localizedDescription))"); throw error }
    }
    public func request(_ method: String, params: NativeRPCValue, timeoutMilliseconds: Int? = nil) async throws -> NativeRPCValue {
        guard alive else { throw BackendPluginsError(-32000, "the plugin is not running") }
        let id = nextID; nextID += 1
        let line = NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(Double(id))), .init("method", .string(method)), .init("params", params)]).compact
        guard line.utf8.count <= maximum else { throw BackendPluginsError(-32005, "that request is larger than \(maximum) bytes") }
        let wait = max(min(timeoutMilliseconds ?? timeout, timeout), 1)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(wait)) } catch { return }
                    let seconds = String(format: "%.1f", Double((Double(wait) / 100).rounded()) / 10).replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
                    await self?.kill("it did not answer \(method) within \(seconds) seconds")
                }
                pending[id] = Pending(continuation: continuation, timer: timer)
                write(line)
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel(); entry.continuation.resume(throwing: BackendPluginsError(-32000, "the caller hung up"))
    }
    public func notify(_ method: String, params: NativeRPCValue = .missing) {
        guard alive else { return }
        write(NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("method", .string(method)), .init("params", params)]).compact)
    }
    public func stop(_ why: String = "it was stopped") async {
        guard alive else { return }
        reason = reason ?? why; notify("shutdown"); child?.closeInput()
        stopTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }
            await self?.kill(why)
        }
        await withCheckedContinuation { stopped.append($0) }
    }
    public func kill(_ why: String) {
        guard alive else { return }; reason = reason ?? why; killed = true
        // SIGKILL to the whole group: a helper the plugin started cannot outlive it.
        child?.kill()
        failPending(why)
    }
    /// Fails quietly once its input is closed (stop, exit), as the closed handle did.
    private func write(_ line: String) { try? child?.write(Data((line + "\n").utf8)) }
    private func failPending(_ why: String) {
        let entries = pending.values; pending.removeAll()
        for entry in entries { entry.timer.cancel(); entry.continuation.resume(throwing: BackendPluginsError(-32000, "the plugin stopped: \(why)")) }
    }
    private func receiveStderr(_ data: Data) { stderrTail = BackendPluginsText.suffix(stderrTail + String(decoding: data, as: UTF8.self), 300) }
    private func gone(code: Int32, signal: Bool) {
        // The serial pipe owner emitted all trailing bytes before this event.
        let said = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let how = signal ? "it was stopped (\(code == SIGKILL ? "SIGKILL" : code == SIGTERM ? "SIGTERM" : String(code)))" : "it exited with code \(code)"
        awaitGone(said.isEmpty ? how : how + "; it last wrote: " + said)
    }
    private func awaitGone(_ how: String) {
        guard !exited else { return }; exited = true
        let why = reason ?? how; failPending(why); buffer.removeAll(); stopTimer?.cancel()
        events?.finish(); events = nil
        child?.closeInput()
        let waiting = stopped; stopped.removeAll(); for wait in waiting { wait.resume() }
        Task { await onExit(why) }
    }
    private func receive(_ data: Data) {
        guard !exited, reason == nil else { return }
        for byte in data {
            if byte == 10 {
                let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); buffer.removeAll(keepingCapacity: true)
                if !line.isEmpty { handle(line) }; if reason != nil { return }
            } else {
                guard buffer.count < maximum else { kill("it sent a message larger than \(maximum) bytes"); return }; buffer.append(byte)
            }
        }
    }
    private func handle(_ line: String) {
        guard let message = try? NativeRPCValue.parseJSON(Data(line.utf8)), message.fields != nil, message["jsonrpc"].string == "2.0" else { kill("it sent something that is not a message"); return }
        if let method = message["method"].string {
            let id = message["id"]
            guard id.number != nil || id.string != nil else { return }
            guard inFlight < 8 else { reply(id, error: BackendPluginsError(-32004, "at most 8 requests may wait at once")); return }
            inFlight += 1
            Task {
                do { let value = try await onRequest(method, message["params"]); reply(id, result: value) }
                catch { reply(id, error: error as? BackendPluginsError ?? BackendPluginsError(-32000, error.localizedDescription)) }
                inFlight -= 1
            }
            return
        }
        guard let numericID = message["id"].number else { kill("it sent something that is not a message"); return }
        guard numericID >= 1, let responseID = Int(exactly: numericID),
              let entry = pending.removeValue(forKey: responseID) else { return }
        entry.timer.cancel()
        if message["error"].fields != nil { entry.continuation.resume(throwing: BackendPluginsError(message["error"]["code"].number.flatMap { Int(exactly: $0) } ?? -32000, BackendPluginsText.prefix(message["error"]["message"].string ?? "the plugin refused", 500))) }
        else { entry.continuation.resume(returning: message["result"]) }
    }
    private func reply(_ id: NativeRPCValue, result: NativeRPCValue = .null, error: BackendPluginsError? = nil) {
        guard alive else { return }
        var value = NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", id)])
        if let error { value = value.setting("error", .object([.init("code", .number(Double(error.code))), .init("message", .string(error.message))])) }
        else { value = value.setting("result", result.isNullish ? .null : result) }
        if value.compact.utf8.count > maximum { value = value.removing("result").setting("error", .object([.init("code", .number(-32005)), .init("message", .string("the answer is larger than \(maximum) bytes"))])) }
        write(value.compact)
    }
    private nonisolated static func emit(_ data: Data, error: Bool, to stream: AsyncStream<IOEvent>.Continuation) {
        // Backpressure keeps at most one 64 KB chunk queued outside the actor;
        // a hostile line cannot outrun its 256 KB check into an unbounded queue.
        let consumed = DispatchSemaphore(value: 0)
        let ack: @Sendable () -> Void = { consumed.signal() }
        if case .enqueued = stream.yield(error ? .error(data, ack) : .output(data, ack)) { consumed.wait() }
    }
}
