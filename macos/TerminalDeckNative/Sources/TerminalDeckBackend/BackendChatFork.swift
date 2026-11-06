import Foundation
import TerminalDeckNativeCore

/// F38 and F57. A real provider fork: the provider copies the conversation into a NEW conversation with its own
/// identity, and the app opens that in a separate Chat. It is not a rewind, and not a handoff summary.
///   Codex   -> `thread/fork` creates the new thread now; the app then opens it through the normal resume.
///   Claude  -> the CLI only forks at launch (`--resume <id> --fork-session`), so this reports the launch
///              the app must perform, with --resume-session-at for a recorded message boundary. It reports pending until the first input saves the new ID.
/// A turn the app shows is chosen by the app's own turn ID; `knownTurns` maps it to the provider's turn ID ("" when none is recorded).
/// `location/read` answers where a Chat really runs, so no Chat claims a remote or cloud location it does not have.
public enum BackendChatFork {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["fork/create", "location/read"]
    public static func changes(_ operation: String) -> Bool { operation == "fork/create" }

    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }

    public static func invoke(operation: String, args: NativeRPCValue, provider: HootChatProvider, conversation: String?, cwd: String,
                              knownTurns: [String: String], quiet: Bool, request: Request,
                              isolatedFork: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)? = nil, knownMessages: [NativeRPCValue] = []) async throws -> NativeRPCValue {
        guard operations.contains(operation), args.fields != nil, try args.encodedJSON().count <= 2_048 else {
            throw NativeRPCError.invalidArguments("Choose a supported fork or location action with bounded arguments.")
        }
        guard Set(args.fields?.map(\.key) ?? []).isSubset(of: operation == "fork/create" ? ["throughTurn", "throughSequence"] : []) else {
            throw NativeRPCError.invalidArguments("Only throughTurn can be chosen. The folder, account and provider settings come from this Chat.")
        }
        if operation == "location/read" { return location(provider: provider, conversation: conversation, cwd: cwd) }
        guard let conversation, !conversation.isEmpty, conversation.utf8.count <= 512 else {
            throw NativeRPCError(code: "unavailable", message: "The AI has no confirmed conversation to fork yet. Send a message first.")
        }
        guard quiet else { throw NativeRPCError(code: "busy", message: "Wait for the AI to finish its answer before forking this conversation.") }
        let sequence = args["throughSequence"].number
        let message = knownMessages.first { $0["sequence"].number == sequence && sequence != nil }
        if sequence != nil, message?["fork"].bool != true {
            throw NativeRPCError(code: "unavailable", message: "The AI cannot fork at that exact message. Nothing was forked.")
        }
        guard sequence == nil || args["throughTurn"].isNullish else { throw NativeRPCError.invalidArguments("Choose a message or a turn, not both.") }
        let through = message?["turnId"].string ?? args["throughTurn"].string
        if let through {
            guard !through.isEmpty, through.utf8.count <= 512, knownTurns[through] != nil else {
                throw NativeRPCError(code: "access-denied", message: "That turn does not belong to this conversation.")
            }
        }
        switch provider {
        case .codex:
            var params = object([("threadId", .string(conversation)), ("ephemeral", .bool(false)), ("excludeTurns", .bool(true))])
            if let through {
                // Codex only knows its own turn IDs. The app's turn ID is mapped to the one Codex issued for that turn.
                guard let providerTurn = knownTurns[through], !providerTurn.isEmpty, providerTurn.utf8.count <= 512 else {
                    throw NativeRPCError(code: "unavailable", message: "Codex has not finished that turn, or it was saved before Codex turn IDs were kept, so the fork cannot be cut there. Choose a later finished turn.")
                }
                params = params.setting("lastTurnId", .string(providerTurn))
            }
            // FIXFORK (16 Oct, measured on Codex 0.159.3): the process that creates a thread keeps its writer lock, and
            // thread/unsubscribe does not unload it (still loaded after 31 s), so the new Chat failed with "thread already
            // has an active writer". The fork is made in a short-lived app-server of this Chat's own launch instead; its
            // exit frees the lock and the new Chat opens the thread at once. Never in this Chat's own process.
            guard let isolatedFork else {
                throw NativeRPCError(code: "unavailable", message: "This Chat's launch is not known, so no separate fork could be made. Nothing was forked.")
            }
            let response = try await isolatedFork(params)
            guard let forked = response["thread"]["id"].string, !forked.isEmpty, forked != conversation, forked.utf8.count <= 512 else {
                throw NativeRPCError(code: "fork-unconfirmed", message: "The provider did not return a new conversation, so nothing was forked.")
            }
            if let origin = response["thread"]["forkedFromId"].string, origin != conversation {
                throw NativeRPCError(code: "fork-unconfirmed", message: "The provider forked a different conversation than this one. No fork was opened.")
            }
            return object([("provider", .string("codex")), ("mode", .string("forked")), ("conversationId", .string(forked)),
                ("parentConversationId", .string(conversation)), ("throughTurn", through.map(NativeRPCValue.string) ?? .null),
                ("cwd", response["cwd"].string.map(NativeRPCValue.string) ?? .string(cwd)), ("requiresForkLaunch", .bool(false)),
                ("executionLocation", .string("this-mac")),
                ("next", .string("Open the new conversation in its own Chat; this Chat keeps its own conversation unchanged."))])
        case .claude:
            guard through == nil || message?["providerMessageId"].string != nil else {
                throw NativeRPCError(code: "unavailable", message: "Choose a recorded message sequence for Claude. A turn ID alone does not identify a precise Claude message.")
            }
            return object([("provider", .string("claude")), ("mode", .string("launch-fork")), ("conversationId", .string(conversation)),
                ("parentConversationId", .string(conversation)), ("resumeSessionAt", message?["providerMessageId"] ?? .null), ("throughTurn", .null), ("cwd", .string(cwd)), ("requiresForkLaunch", .bool(true)),
                ("executionLocation", .string("this-mac")),
                ("next", .string("Claude forks while launching: start a new Chat that resumes this conversation as a fork. The fork gets its own conversation ID once it starts."))])
        case .gemini:
            throw NativeRPCError(code: "unavailable", message: "Gemini's chat protocol in this installation has no conversation fork.")
        }
    }

    /// Honest by construction: every Chat in this build runs its AI on this Mac. Nothing here claims a server or cloud.
    static func location(provider: HootChatProvider, conversation: String?, cwd: String) -> NativeRPCValue {
        object([("provider", .string(provider.rawValue)), ("executionLocation", .string("this-mac")),
            ("machine", .string(ProcessInfo.processInfo.hostName)), ("folder", .string(cwd)),
            ("conversationId", conversation.map(NativeRPCValue.string) ?? .null),
            ("continuation", object([("sameMacSameAccount", .bool(true)), ("otherMachines", .bool(false)), ("cloud", .bool(false)),
                ("note", .string("A saved conversation resumes only on this Mac, with the same account and folder. Another machine or the provider's cloud would start a different conversation."))])),
            ("remoteRoutes", .array([
                object([("route", .string("paired-device")), ("runsAiThere", .bool(false)),
                        ("note", .string("A paired phone shows and drives this Mac's Chat. The AI keeps running on this Mac."))]),
                object([("route", .string("server")), ("runsAiThere", .bool(false)),
                        ("note", .string("Servers offer terminals and files. Chat does not run on a server."))]),
                object([("route", .string("provider-cloud")), ("runsAiThere", .bool(false)),
                        ("note", .string("Provider cloud sessions are not connected to Chat."))])]))])
    }
}

/// FIXFORK: one Codex app-server started from a Chat's own launch, used only to create a fork, then stopped. Its exit
/// releases the fork's writer lock, so the new Chat (its own process) can open the thread.
public actor BackendChatForkProcess {
    private let child = BackendHootChatProcess()
    private var consumer: Task<Void, Never>?
    private var waiters: [String: CheckedContinuation<NativeRPCValue, Error>] = [:]
    private var ended = false

    public static func fork(launch: BackendHootChatLaunch, params: NativeRPCValue, timeout: Duration = .seconds(45)) async throws -> NativeRPCValue {
        let process = BackendChatForkProcess()
        do {
            let result = try await process.run(launch, method: "thread/fork", params: params, timeout: timeout)
            await process.stop(); return result
        } catch { await process.stop(); throw error }
    }
    static func readConversation(launch: BackendHootChatLaunch, id: String) async throws -> NativeRPCValue {
        let process = BackendChatForkProcess()
        do {
            let result = try await process.run(launch, method: "thread/read", params: .object([.init("threadId", .string(id)), .init("includeTurns", .bool(true))]), timeout: .seconds(45))
            await process.stop(); return result
        } catch { await process.stop(); throw error }
    }
    private func run(_ launch: BackendHootChatLaunch, method: String, params: NativeRPCValue, timeout: Duration) async throws -> NativeRPCValue {
        try child.start(.init(command: launch.command, arguments: launch.arguments + ["--disable", "apps", "--disable", "plugins"],
            cwd: launch.cwd, environment: launch.environment, setup: launch.setup))
        consumer = Task { [weak self, child] in
            var lines = HootChatJSONLines()
            for await output in child.output {
                guard !Task.isCancelled else { break }
                switch output {
                case .stdout(let data):
                    guard let rows = try? lines.append(data) else { await self?.finish(); return }
                    for row in rows { await self?.receive(row) }
                case .stderr: break // CLI stderr can include account details; never surfaced.
                case .exit: await self?.finish(); return
                }
            }
        }
        _ = try await request("initialize", .object([.init("clientInfo", .object([
            .init("name", .string("terminaldeck-fork")), .init("version", .string("1"))])),
            .init("capabilities", .object([.init("experimentalApi", .bool(true))]))]), timeout: timeout)
        try await child.send(BackendHootChatRPC.request("initialized"))
        return try await request(method, params, timeout: timeout)
    }
    private func request(_ method: String, _ params: NativeRPCValue, timeout: Duration) async throws -> NativeRPCValue {
        let id = UUID().uuidString
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.reject(id, NativeRPCError(code: "unavailable", message: "Codex did not answer \(method) while making the fork. Nothing was opened."))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation(isolation: self) { continuation in
            guard !ended else { continuation.resume(throwing: NativeRPCError(code: "unavailable", message: "Codex stopped while making the fork. Nothing was opened.")); return }
            waiters[id] = continuation
            Task { do { try await child.send(BackendHootChatRPC.request(method, id: .string(id), params: params)) } catch { reject(id, error) } }
        }
    }
    private func reject(_ id: String, _ error: Error) { waiters.removeValue(forKey: id)?.resume(throwing: error) }
    private func receive(_ row: NativeRPCValue) async {
        if let id = row["id"].string, let continuation = waiters.removeValue(forKey: id) {
            if row["error"].isNullish && row.has("result") { continuation.resume(returning: row["result"]) }
            else { continuation.resume(throwing: NativeRPCError(code: "unavailable", message: row["error"]["message"].string ?? "Codex refused the fork.")) }
            return
        }
        // This process only forks: any request Codex makes of it (an approval, a tool) is declined.
        if row["method"].string != nil, !row["id"].isNullish {
            try? await child.send(.object([.init("jsonrpc", .string("2.0")), .init("id", row["id"]),
                .init("error", .object([.init("code", .number(-32601)), .init("message", .string("This process only makes a fork."))]))]))
        }
    }
    private func finish() {
        ended = true
        let pending = waiters; waiters = [:]
        for continuation in pending.values { continuation.resume(throwing: NativeRPCError(code: "unavailable", message: "Codex stopped while making the fork. Nothing was opened.")) }
    }
    private func stop() async { await child.stopAndWait(); consumer?.cancel(); consumer = nil; finish() }
}
