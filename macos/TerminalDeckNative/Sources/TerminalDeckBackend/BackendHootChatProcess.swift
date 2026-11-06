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

/// Stop can cancel a prepared input until the writer takes it. Once writing starts,
/// delivery is uncertain until its receipt, even when Stop arrives meanwhile.
final class BackendHootChatInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var writing = false
    var writeStarted: Bool { lock.withLock { writing } }
    @discardableResult func cancel() -> Bool { lock.withLock { cancelled = true; return !writing } }
    func check() throws {
        try lock.withLock {
            if cancelled { throw NativeRPCError(code: "queued-send-stopped", message: "Stopped. Review this queued message before sending it.") }
        }
    }
    func beginWrite() throws {
        try lock.withLock {
            if cancelled { throw NativeRPCError(code: "queued-send-stopped", message: "Stopped. Review this queued message before sending it.") }
            writing = true
        }
    }
}

/// A pipe process, deliberately separate from the PTY/session terminal owner, on the standard
/// child runner (`NativeChild`): its own process group, so a stop, or its own exit, takes every
/// program the CLI started with it. EOF on BOTH output pipes precedes exit, so the final result cannot be lost.
public final class BackendHootChatProcess: @unchecked Sendable {
    public let output: Output
    private let continuation: AsyncStream<BackendHootChatOutput>.Continuation
    private let backlog = Backlog()
    /// The queue never holds more than one line of the largest size the reader accepts.
    static let backlogLimit = HootChatJSONLines.maximumLineBytes
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "hoot.chat.stdin")
    /// Dropped at exit: its callbacks hold this object, so keeping it would keep both forever.
    private var child: NativeChild?
    private var started = false
    private var closed = false
    private var inputClosed = false
    private var reaped = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    /// One output stream's secret filter and cap, touched only on the child's serial queue.
    private final class Reader: @unchecked Sendable {
        let filter: BackendAPISecretStream, error: Bool
        var capped = false
        init(_ secret: String?, error: Bool) { filter = BackendAPISecretStream(secret); self.error = error }
    }
    /// Bytes handed to `output` that its reader has not taken yet.
    final class Backlog: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        func add(_ count: Int) -> Int { lock.withLock { bytes += count; return bytes } }
        func take(_ count: Int) { lock.withLock { bytes -= count } }
    }
    /// The child's output in order. Taking an item gives its bytes back to the backlog the cap counts.
    public struct Output: AsyncSequence, Sendable {
        public typealias Element = BackendHootChatOutput
        let stream: AsyncStream<BackendHootChatOutput>, backlog: Backlog
        public struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncStream<BackendHootChatOutput>.Iterator
            let backlog: Backlog
            public mutating func next() async -> BackendHootChatOutput? {
                let item = await base.next()
                switch item {
                case .stdout(let bytes)?, .stderr(let bytes)?: backlog.take(bytes.count)
                default: break
                }
                return item
            }
        }
        public func makeAsyncIterator() -> AsyncIterator { .init(base: stream.makeAsyncIterator(), backlog: backlog) }
    }
    public init() {
        let pair = AsyncStream<BackendHootChatOutput>.makeStream()
        output = Output(stream: pair.stream, backlog: backlog); continuation = pair.continuation
    }
    public var alive: Bool { lock.withLock { !closed && child?.isRunning == true } }
    public var processPID: Int32? { lock.withLock { !closed && child?.isRunning == true ? child?.pid : nil } }
    public func start(_ launch: BackendHootChatLaunch) throws {
        let expanded = try BackendAPIAccountEnvironment.expand(launch.environment, command: launch.command)
        let readers = [Reader(expanded.secret, error: false), Reader(expanded.secret, error: true)]
        // Held across the launch: a fast child's callbacks (the cap's stop, its exit) wait for `child`.
        try lock.withLock {
            guard !closed, !started else { throw NativeRPCError.invalidArguments("Hoot's pipe process can only start once.") }
            // Process resolved both against this process's folder; the runner takes whole paths.
            let spec = NativeChild.Spec(URL(fileURLWithPath: launch.command).path, launch.arguments, environment: expanded.values,
                                        cwd: URL(fileURLWithPath: launch.cwd).path, input: .pipe)
            do {
                // The runner reads only what's available, so a permission request reaches the app
                // before its child can produce the next bytes.
                child = try NativeChild.start(spec, output: { [self] in receive($0, readers[0]) },
                                              errors: { [self] in receive($0, readers[1]) },
                                              exit: { [self] in exited($0, readers: readers) })
                // A Claude Code chat is never stopped during a sign-in renewal (`NativeChild.claudeFolder`).
                child?.claudeFolder = NativeSignInRenewal.folder(command: launch.command, arguments: launch.arguments, environment: expanded.values)
                started = true
            } catch { closed = true; continuation.finish(); throw error }
        }
    }
    private func exited(_ end: NativeChild.Termination, readers: [Reader]) {
        let waiting = lock.withLock {
            reaped = true; closed = true; child = nil
            let waiting = exitWaiters; exitWaiters = []; return waiting
        }
        for waiter in waiting { waiter.resume() }
        for reader in readers {
            let remaining = reader.filter.finish()
            if !remaining.isEmpty { continuation.yield(reader.error ? .stderr(remaining) : .stdout(remaining)) }
        }
        // Process reported a signal's own number; the runner reports it apart from 128 + it.
        continuation.yield(.exit(end.signal ?? end.code)); continuation.finish()
    }
    private func receive(_ bytes: Data, _ reader: Reader) {
        guard !reader.capped else { return }
        let safe = reader.filter.feed(bytes)
        guard !safe.isEmpty else { return }
        // A broken or hostile CLI cannot grow the event queue forever. Only what the reader has not taken yet counts:
        // a lifetime total killed a healthy long-lived Hoot mid-answer after 32 MiB of output (#83).
        if backlog.add(safe.count) > Self.backlogLimit { reader.capped = true; stop(); return }
        continuation.yield(reader.error ? .stderr(safe) : .stdout(safe))
    }
    /// Shared preflight and writer encoding, including the terminating line break. Callers
    /// can reject an unsendable envelope before committing their turn or chat journal.
    public static func inputData(_ value: NativeRPCValue) throws -> Data {
        var bytes = try value.encodedJSON(); bytes.append(10)
        guard bytes.count <= HootChatJSONLines.maximumInputBytes else {
            throw NativeRPCError(code: "provider-input-limit", message: "The complete encoded Chat message exceeds the 6 MiB transport limit. Keep the draft and reduce its attached context or files.")
        }
        return bytes
    }
    public func send(_ value: NativeRPCValue) async throws {
        try await send(value, gate: nil)
    }
    func send(_ value: NativeRPCValue, gate: BackendHootChatInputGate?) async throws {
        let input = try Self.inputData(value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.async { [self] in
                do {
                    guard let child = lock.withLock({ !closed && !inputClosed ? self.child : nil }), child.isRunning else { throw NativeRPCError(code: "unavailable", message: "Hoot's CLI input is no longer available.") }
                    try gate?.beginWrite()
                    try child.write(input)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// EOF only, ordered after prior writes. Private app-server command connections use
    /// their documented disconnect cleanup before any signal fallback; the parent pipe
    /// never calls this just because a frontend detaches.
    public func closeInput() async {
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                let child: NativeChild? = lock.withLock {
                    if inputClosed { return nil }; inputClosed = true; return self.child
                }
                child?.closeInput()
                continuation.resume()
            }
        }
    }
    public func stop() {
        let child: NativeChild? = lock.withLock {
            guard !closed else { return nil }
            closed = true; return self.child
        }
        // SIGTERM to the whole group, SIGKILL a second later if it is still there (Claude Code: after any
        // sign-in renewal under way, and to Claude Code alone first). The runner signals only a child it
        // has not reaped, so a recycled PID is never hit.
        child?.terminate(grace: .seconds(1))
    }
    public func stopAndWait() async {
        stop()
        await waitForExit()
    }
    /// Wait without signalling. Owned command connections first close stdin and give the
    /// provider its normal disconnect cleanup; the owner supplies a bounded signal fallback.
    public func waitForExit() async {
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                if reaped || !started { return true }
                exitWaiters.append(continuation); return false
            }
            if finished { continuation.resume() }
        }
    }
}

public enum BackendHootChatCLI {
    static func planningEnvironment(_ source: [String: String]) -> [String: String] {
        var result = source
        let disabled = source["CLAUDE_CODE_ENABLE_TASKS"].map { ["0", "false", "no"].contains($0.lowercased()) } ?? false
        if !disabled, result["CLAUDE_CODE_ENABLE_TODO_TOOLS"] == nil { result["CLAUDE_CODE_ENABLE_TODO_TOOLS"] = "1" }
        // F29: file checkpoints are an SDK-mode opt-in. Unless the person turned them off, the CLI snapshots files
        // before each message so a restore can be previewed and approved later.
        let checkpointsOff = source["CLAUDE_CODE_DISABLE_FILE_CHECKPOINTING"].map { !["0", "false", "no", ""].contains($0.lowercased()) } ?? false
        if !checkpointsOff, result["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == nil { result["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] = "1" }
        return result
    }
    /// Hoot's deck tools that only read: they never ask, at the CLI or in the app.
    public static let readOnlyDeckTools: Set<String> = ["tools_describe", "sessions_list", "sessions_get", "sessions_result", "sessions_transcript",
        "projects_list", "git_status", "git_diff", "alerts_list", "settings_read", "memory_search", "memory_card_read", "memory_board_read",
        "memory_diary_read", "playbook_read", "hoot_chat_read", "hoot_chat_background"]
    /// The mode the person chose always reaches the CLI, whatever this Mac's own Claude settings say (H10, 11 Oct:
    /// with no flag, a personal `defaultMode: bypassPermissions` and `allow: Bash` let "Ask first" ask nothing).
    /// Ask first uses the CLI's `default` mode plus ask rules (which beat a personal allow rule);
    /// Auto → ask rule for commands; Bypass and Plan only → as chosen. Reads are allowed in every mode.
    static func withChosenMode(_ extra: [String]) throws -> [String] {
        var result: [String] = [], mode: String?, settings: String?, index = 0
        while index < extra.count {
            if extra[index] == "--permission-mode", index + 1 < extra.count { mode = extra[index + 1]; index += 2; continue }
            if extra[index] == "--settings", index + 1 < extra.count { settings = extra[index + 1]; index += 2; continue }
            result.append(extra[index]); index += 1
        }
        let asking: Bool = mode == nil || mode == "default" || mode == "manual"
        let cliMode = asking ? "default" : mode!
        let ask = asking ? ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"] : cliMode == "acceptEdits" ? ["Bash"] : []
        var merged = NativeRPCValue.object([])
        if let settings {
            let bytes = settings.hasPrefix("{") ? Data(settings.utf8) : try Data(contentsOf: URL(fileURLWithPath: settings))
            merged = try NativeRPCValue.parseJSON(bytes).requireObject("Hoot's CLI settings")
        }
        var permissions = merged["permissions"].fields == nil ? NativeRPCValue.object([]) : merged["permissions"]
        func adding(_ key: String, _ values: [String]) {
            let existing = (permissions[key].elements ?? []).compactMap(\.string)
            let all = existing + values.filter { !existing.contains($0) }
            if !all.isEmpty { permissions = permissions.setting(key, .array(all.map(NativeRPCValue.string))) }
        }
        adding("ask", ask)
        adding("allow", readOnlyDeckTools.sorted().map { "mcp__deck-control__" + $0 })
        merged = merged.setting("permissions", permissions)
        return ["--permission-mode", cliMode, "--settings", merged.compact] + result
    }
    public static func claudeArguments(sessionID: String?, extra: [String]) throws -> [String] {
        let extra = try withChosenMode(extra)
        if let sessionID, sessionID.range(of: "^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("Invalid Hoot CLI session ID.")
        }
        var verified: [String] = [], index = 0
        while index < extra.count {
            if extra[index] == BackendCopilotLayer.appendSystemPromptFile {
                guard index + 1 < extra.count else { throw NativeRPCError.invalidArguments("Hoot's composed instructions file is missing.") }
                let data = try Data(contentsOf: URL(fileURLWithPath: extra[index + 1]), options: .mappedIfSafe)
                guard data.count <= 131_072, String(data: data, encoding: .utf8) != nil else {
                    throw NativeRPCError.invalidArguments("Hoot's composed instructions need valid UTF-8, at most 128 KiB.")
                }
                // Checked here, then handed over by path (#553): the text itself on the command
                // line would show Hoot's private instructions in every process list. Claude Code
                // 2.1.302 accepts the file spelling (a hidden option) and appends it unchanged.
                verified += [BackendCopilotLayer.appendSystemPromptFile, extra[index + 1]]; index += 2
            } else { verified.append(extra[index]); index += 1 }
        }
        // "--permission-prompts host" alone asks nobody: without the stdio prompt tool Claude Code refuses
        // anything that needs permission on its own ("…but you haven't granted it yet") and the app never
        // hears of it. Measured with claude 2.1.293: with "--permission-prompt-tool stdio" the request
        // (can_use_tool) reaches the app, which answers it from Hoot's permission choice or shows it to the person.
        return ["--print", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
                "--include-partial-messages", "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]
            + verified + (sessionID.map { ["--resume", $0] } ?? [])
    }
    public static func user(_ text: String, attachments: [NativeRPCValue] = [], uuid: String? = nil) -> NativeRPCValue {
        let content: [NativeRPCValue] = [.object([.init("type", .string("text")), .init("text", .string(text))])] + attachments
        var fields: [NativeRPCValue.Field] = [.init("type", .string("user")), .init("message", .object([.init("role", .string("user")), .init("content", .array(content))]))]
        // The message's own ID is what a file checkpoint is named by (F29).
        if let uuid, UUID(uuidString: uuid) != nil { fields.append(.init("uuid", .string(uuid))) }
        return .object(fields)
    }
    public static func approval(id: String, allowed: Bool, input: NativeRPCValue, message: String? = nil,
                                updatedPermissions: NativeRPCValue? = nil) -> NativeRPCValue {
        var answer = NativeRPCValue.object([.init("behavior", .string(allowed ? "allow" : "deny"))])
        answer = allowed ? answer.setting("updatedInput", input) : answer.setting("message", .string(message ?? "The person denied this request."))
        if allowed, let updatedPermissions { answer = answer.setting("updatedPermissions", updatedPermissions) }
        return .object([.init("type", .string("control_response")), .init("response", .object([
            .init("subtype", .string("success")), .init("request_id", .string(id)), .init("response", answer)]))])
    }
    /// Claude's elicitation response is distinct from a can_use_tool permission.
    /// URL and declined requests omit content; form content is validated by the store.
    public static func elicitation(id: String, allowed: Bool, content: NativeRPCValue? = nil) -> NativeRPCValue {
        var answer = NativeRPCValue.object([.init("action", .string(allowed ? "accept" : "decline"))])
        if allowed, let content { answer = answer.setting("content", content) }
        return .object([.init("type", .string("control_response")), .init("response", .object([
            .init("subtype", .string("success")), .init("request_id", .string(id)), .init("response", answer)]))])
    }
}
