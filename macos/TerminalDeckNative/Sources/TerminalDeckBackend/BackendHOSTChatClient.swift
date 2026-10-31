import Foundation
import TerminalDeckNativeCore

/// App-side projection. Detaching closes only its watch socket, never an AI.
public final class BackendHOSTChatClient: @unchecked Sendable {
    private let client: BackendHOSTClient
    private let lock = NSLock()
    private var jobs: [String: BackendTeamChatRecord] = [:]
    private var ids: Set<String> = []
    private var cancelWatch: (@Sendable () -> Void)?
    private var observers: [UUID: AsyncStream<NativeRPCValue>.Continuation] = [:]
    public init(client: BackendHOSTClient) { self.client = client }
    public func owns(_ id: String) -> Bool { lock.withLock { ids.contains(id) } || client.cachedSessions().contains { $0.id == id && $0.chat == true } }
    public func conversation(_ id: String) -> BackendTeamChatRecord? { lock.withLock { jobs[id] } }
    public func conversations() -> [BackendTeamChatRecord] { lock.withLock { Array(jobs.values) } }
    public func attach(changed: @escaping @Sendable (String, NativeRPCValue) async -> Void) async throws {
        detach()
        try await refreshInventory()
        let cancel = try client.watchChats { [weak self] value in
            guard let self, let id = value["id"].string else { return }
            let record = try? JSONDecoder().decode(BackendTeamChatRecord.self, from: value["job"].encodedJSON())
            let observers = lock.withLock { () -> [AsyncStream<NativeRPCValue>.Continuation] in
                ids.insert(id); if let record { jobs[id] = record }
                return Array(self.observers.values)
            }
            // Pictures inside the chat's records stay with the helper; the app gets their stand-ins (BackendChatMedia).
            let slim = value.setting("snapshot", BackendChatMedia.slim(value["snapshot"]))
            for observer in observers { observer.yield(slim) }
            await changed(id, slim["snapshot"])
        }
        lock.withLock { cancelWatch = cancel }
    }
    public func refreshInventory() async throws {
        let inventory = try await client.resource("chats.inventory", arguments: .object([]))
        let records = try JSONDecoder().decode([BackendTeamChatRecord].self, from: inventory["jobs"].encodedJSON())
        lock.withLock {
            jobs = Dictionary(uniqueKeysWithValues: records.map { ($0.session.id, $0) })
            ids = Set((inventory["sessions"].elements ?? []).compactMap { $0["id"].string }).union(jobs.keys)
        }
    }
    /// 0 for a helper that predates file checkpoints, background tasks, fork and location.
    public var sessionFeatureLevel: Int { client.hello.chatSessionFeatures ?? 0 }
    public func detach() { let cancel = lock.withLock { let c = cancelWatch; cancelWatch = nil; return c }; cancel?() }
    /// A frontend can leave while another observer remains. Audio still ends explicitly;
    /// old helpers cannot have accepted provider voice through this client in the first place.
    public func stopTransientVoice(_ id: String? = nil) async -> NativeRPCValue {
        guard (client.hello.chatFeatures ?? 0) >= 1 else {
            return .object([.init("stopped", .bool(true)), .init("supported", .bool(false)), .init("sessions", .array([]))])
        }
        do {
            return try await client.resource("chats.voice-detach", arguments: .object(id.map { [.init("id", .string($0))] } ?? []))
        } catch {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("Unknown chat service operation") || message.localizedCaseInsensitiveContains("Unknown resource") {
                return .object([.init("stopped", .bool(false)), .init("activeOrUncertain", .bool(true)),
                    .init("code", .string("helper-upgrade-required")),
                    .init("error", .string("This helper predates automatic voice detach. Provider voice stop could not be confirmed; its parent conversation and helper were kept running."))])
            }
            return .object([.init("stopped", .bool(false)), .init("activeOrUncertain", .bool(true)), .init("error", .string(error.localizedDescription))])
        }
    }
    public func call(_ verb: String, id: String, fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        if verb == "terminal", (client.hello.chatOwnedTerminals ?? 0) < 1 {
            throw NativeRPCError(code: "helper-upgrade-required", message: "This running helper predates Chat-owned app-approved terminals. Its sessions were kept running; the feature needs the next agreed helper update and restart.")
        }
        if verb == "provider", (client.hello.chatFeatures ?? 0) < 1 {
            throw NativeRPCError(code: "helper-upgrade-required", message: "This running helper predates provider features. The helper and its sessions were kept running; install the new helper at the next agreed restart.")
        }
        var arguments = NativeRPCValue.object([.init("id", .string(id))] + fields)
        let sends = verb == "say" || verb == "steer"
        let deliveryNow = Date()
        let queue = BackendChatDeliveryQueue(directory: client.paths.dataDirectory.appendingPathComponent("chat-outgoing"))
        if sends {
            arguments = arguments.setting("clientMessageId", .string(BackendChatDeliveryQueue.identity(arguments["clientMessageId"].string)))
            let claim = try queue.claim(arguments, now: deliveryNow)
            arguments = claim.message
            if claim.confirmed { return BackendChatMedia.slim(try await client.resource("chats.read", arguments: .object([.init("id", .string(id)), .init("limit", .number(500))]))) }
        }
        let result: NativeRPCValue
        do { result = try await client.resource("chats." + verb, arguments: arguments) }
        catch { if sends { queue.refused(arguments, error: error) }; throw error }
        if sends { try queue.finish(arguments) }
        if verb == "delete" || (verb == "remove" && conversation(id) == nil) { try queue.forgetConversation(id) }
        if verb == "delete" { lock.withLock { jobs[id] = nil; ids.remove(id) } }
        return BackendChatMedia.slim(result)
    }
    public func metadata(_ id: String) async throws -> BackendSessionMeta {
        try JSONDecoder().decode(BackendSessionMeta.self, from: await call("open", id: id).encodedJSON())
    }
    public func queued(_ id: String, count: Int) async throws {
        if client.hello.chatSteering == 1 {
            _ = try await call("queued", id: id, fields: [.init("count", .number(Double(count)))]); return
        }
        if count > 0, try await call("read", id: id, fields: [.init("limit", .number(1))])["job"].fields != nil {
            throw NativeRPCError(code: "chat-queue-unavailable", message: "This helper predates keeping team chats open for queued follow-ups. If this job closes, your message stays here; the helper was not restarted.")
        }
    }
    public func steer(_ id: String, text: String, attachments: [NativeRPCValue], context: NativeRPCValue, clientMessageID: String? = nil) async throws -> NativeRPCValue {
        let fields: [NativeRPCValue.Field] = [.init("text", .string(text)), .init("attachments", .array(attachments)), .init("context", context), .init("clientMessageId", .string(BackendChatDeliveryQueue.identity(clientMessageID)))]
        if client.hello.chatSteering == 1 { return try await call("steer", id: id, fields: fields) }
        let before = try await call("read", id: id, fields: [.init("limit", .number(1))])
        if before["busy"].bool != true { return try await call("say", id: id, fields: fields) }
        guard before["provider"].string != "codex" else {
            throw NativeRPCError(code: "chat-steering-unavailable", message: "This running session helper predates Codex steering. Your message stays queued until the turn ends; the helper was not restarted.")
        }
        if before["job"].fields != nil { return try await call("say", id: id, fields: fields) }
        _ = try await call("interrupt", id: id)
        _ = try await waitForTurn(id, timeout: .seconds(10))
        let stopped = try await call("read", id: id, fields: [.init("limit", .number(1))])
        guard stopped["busy"].bool != true else { throw NativeRPCError(code: "busy", message: "The AI has not confirmed the interruption. Your message stays queued.") }
        return try await call("say", id: id, fields: fields)
    }
    public func turn(_ id: String) async throws -> BackendSessionChats.Turn {
        let value = try await call("turn", id: id)
        let state: BackendSessionChats.TurnState
        switch value["state"].string {
        case "working": state = .working
        case "needs-permission": state = .needsPermission(value["requests"].elements ?? [])
        case "done": state = .done(answer: value["answer"].string ?? "")
        case "failed": state = .failed(reason: value["reason"].string ?? "Failed")
        default: state = .idle
        }
        return .init(state: state, turnID: value["turnId"].string, cursor: Int(value["cursor"].number ?? 0))
    }
    public func waitForTurn(_ id: String, timeout: Duration) async throws -> BackendSessionChats.Turn {
        let token = UUID(), pair = AsyncStream<NativeRPCValue>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { observers[token] = pair.continuation }
        defer { lock.withLock { observers[token] = nil }; pair.continuation.finish() }
        let current = try await turn(id)
        guard current.state == .working else { return current }
        return try await withThrowingTaskGroup(of: BackendSessionChats.Turn.self) { group in
            group.addTask { [self] in
                for await value in pair.stream where value["id"].string == id {
                    let next = try await turn(id)
                    if next.state != .working { return next }
                }
                return try await turn(id)
            }
            group.addTask { [self] in try await Task.sleep(for: timeout); return try await turn(id) }
            defer { group.cancelAll() }
            return try await group.next() ?? current
        }
    }
    deinit { cancelWatch?() }
}
