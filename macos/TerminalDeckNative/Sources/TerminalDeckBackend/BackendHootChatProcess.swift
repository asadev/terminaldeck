import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendHootChatLaunch: Sendable {
    public let command: String, arguments: [String], cwd: String
    public let environment: [String: String]
    public let setup: BackendHootChatSetup?
    public init(command: String, arguments: [String], cwd: String, environment: [String: String], setup: BackendHootChatSetup? = nil) {
        self.command = command; self.arguments = arguments; self.cwd = cwd; self.environment = environment
        self.setup = setup
    }
}
public enum BackendHootChatOutput: Sendable { case stdout(Data), stderr(Data), exit(Int32) }

/// A pipe process, deliberately separate from the PTY/session terminal owner.
/// EOF on BOTH output pipes precedes exit, so the final result cannot be lost.
public final class BackendHootChatProcess: @unchecked Sendable {
    public let output: AsyncStream<BackendHootChatOutput>
    private let continuation: AsyncStream<BackendHootChatOutput>.Continuation
    private let process = Process(), incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "hoot.chat.stdin")
    private var closed = false
    private var reaped = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    public init() {
        let pair = AsyncStream<BackendHootChatOutput>.makeStream()
        output = pair.stream; continuation = pair.continuation
        _ = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    public var alive: Bool { lock.withLock { !closed && process.isRunning } }
    public func start(_ launch: BackendHootChatLaunch) throws {
        let group = DispatchGroup()
        // A short-lived child can exit before its reader queues are installed.
        // Keep exit publication behind startup and both pipe EOFs.
        group.enter()
        defer { group.leave() }
        try lock.withLock {
            guard !closed, process.processIdentifier == 0 else { throw NativeRPCError.invalidArguments("Hoot's pipe process can only start once.") }
            process.executableURL = URL(fileURLWithPath: launch.command)
            process.arguments = launch.arguments; process.environment = launch.environment
            process.currentDirectoryURL = URL(fileURLWithPath: launch.cwd)
            process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = errors
            process.terminationHandler = { [weak self] child in
                self?.exited(status: child.terminationStatus, readers: group)
            }
            do { try process.run() }
            catch { process.terminationHandler = nil; closed = true; continuation.finish(); throw error }
        }
        // The parent uses the opposite ends. Holding a parent's copy of a
        // child-owned output writer would prevent its reader from seeing EOF.
        try? incoming.fileHandleForReading.close()
        try? outgoing.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        read(outgoing.fileHandleForReading, error: false, group: group)
        read(errors.fileHandleForReading, error: true, group: group)
    }
    private func exited(status: Int32, readers: DispatchGroup) {
        let waiting = lock.withLock {
            reaped = true
            let waiting = exitWaiters; exitWaiters = []; return waiting
        }
        for waiter in waiting { waiter.resume() }
        readers.notify(queue: .global(qos: .utility)) { [self] in
            lock.withLock { closed = true; try? incoming.fileHandleForWriting.close() }
            continuation.yield(.exit(status)); continuation.finish()
        }
    }
    private func read(_ handle: FileHandle, error: Bool, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? handle.close(); group.leave() }
            var total = 0
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                // FileHandle can wait to fill its requested count on a pipe.
                // A permission request must reach the app before its child
                // can produce the next bytes, so read only what's available.
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let bytes = Data(buffer.prefix(count))
                total += bytes.count
                // A broken or hostile CLI cannot grow the event queue forever.
                if total > 32 * 1_048_576 { stop(); break }
                continuation.yield(error ? .stderr(bytes) : .stdout(bytes))
            }
        }
    }
    public func send(_ value: NativeRPCValue) async throws {
        var bytes = try value.encodedJSON(); bytes.append(10)
        guard bytes.count <= HootChatJSONLines.maximumLineBytes else { throw NativeRPCError.invalidArguments("Hoot's input is too large.") }
        let input = bytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                do {
                    guard alive else { throw NativeRPCError(code: "unavailable", message: "Hoot's CLI is no longer running.") }
                    try incoming.fileHandleForWriting.write(contentsOf: input)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func stop() {
        let pid: Int32? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            guard process.isRunning else { return nil }
            process.terminate(); return process.processIdentifier
        }
        // Do not kill a recycled PID after an intervening exit.
        if let pid { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning, process.processIdentifier == pid { Darwin.kill(pid, SIGKILL) }
        } }
    }
    public func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                if reaped || process.processIdentifier == 0 { return true }
                exitWaiters.append(continuation); return false
            }
            if finished { continuation.resume() }
        }
    }
}

public enum BackendHootChatCLI {
    public static func claudeArguments(sessionID: String?, extra: [String]) throws -> [String] {
        if let sessionID, sessionID.range(of: "^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("Invalid Hoot CLI session ID.")
        }
        var verified: [String] = [], index = 0
        while index < extra.count {
            if extra[index] == BackendCopilotLayer.appendSystemPromptFile {
                guard index + 1 < extra.count else { throw NativeRPCError.invalidArguments("Hoot's composed instructions file is missing.") }
                let data = try Data(contentsOf: URL(fileURLWithPath: extra[index + 1]), options: .mappedIfSafe)
                guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else {
                    throw NativeRPCError.invalidArguments("Hoot's composed instructions need valid UTF-8, at most 128 KiB.")
                }
                // The file spelling is only mentioned in help; use the declared
                // append flag, keeping the exact composed instructions.
                verified += ["--append-system-prompt", text]; index += 2
            } else { verified.append(extra[index]); index += 1 }
        }
        return ["--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
                "--include-partial-messages", "--permission-prompts", "host"]
            + verified + (sessionID.map { ["--resume", $0] } ?? [])
    }
    public static func user(_ text: String, attachments: [NativeRPCValue] = []) -> NativeRPCValue {
        let content: [NativeRPCValue] = [.object([.init("type", .string("text")), .init("text", .string(text))])] + attachments
        return .object([.init("type", .string("user")), .init("message", .object([.init("role", .string("user")), .init("content", .array(content))]))])
    }
    public static func approval(id: String, allowed: Bool, input: NativeRPCValue) -> NativeRPCValue {
        var answer = NativeRPCValue.object([.init("behavior", .string(allowed ? "allow" : "deny"))])
        answer = allowed ? answer.setting("updatedInput", input) : answer.setting("message", .string("The person denied this request."))
        return .object([.init("type", .string("control_response")), .init("response", .object([
            .init("subtype", .string("success")), .init("request_id", .string(id)), .init("response", answer)]))])
    }
}
