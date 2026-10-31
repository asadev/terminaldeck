import Foundation
import TerminalDeckNativeCore

/// A real provider fork with its own pipe process and memory-only transcript. It never writes a
/// main-thread message or changes its draft. The provider's ephemeral thread dies with this pipe.
public actor BackendChatSideConversation {
    private let parent: String
    private let child = BackendHootChatProcess()
    private var consumer: Task<Void, Never>?
    private var waiters: [String: CheckedContinuation<NativeRPCValue, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var events: [HootChatEvent] = []
    private var sequence = 0, transcriptBytes = 0
    private var conversation = "", activeTurn: String?, localTurn = ""
    private var busy = false, closed = false
    private var effectiveSandbox: NativeRPCValue = .null

    private init(parent: String) { self.parent = parent }
    deinit { consumer?.cancel(); child.stop() }

    public static func open(provider: HootChatProvider, conversation: String,
                            launch: BackendHootChatLaunch, disabledServers: [String] = []) async throws -> BackendChatSideConversation {
        guard provider == .codex else { throw NativeRPCError(code: "unavailable", message: "Independent ephemeral side conversations require the verified Codex fork protocol.") }
        guard !conversation.isEmpty else { throw NativeRPCError.invalidArguments("Choose an existing provider conversation to ask alongside.") }
        let side = BackendChatSideConversation(parent: conversation)
        do { try await side.start(launch, disabledServers: disabledServers); return side }
        catch { _ = await side.close(); throw error }
    }

    private func start(_ launch: BackendHootChatLaunch, disabledServers: [String]) async throws {
        // Process-local feature overrides also cover global app/plugin sources that are absent
        // from the parent's thread settings. They never update the account's config file.
        try child.start(.init(command: launch.command, arguments: launch.arguments + ["--disable", "apps", "--disable", "plugins"],
            cwd: launch.cwd, environment: launch.environment, setup: launch.setup))
        consumer = Task { [weak self, child] in
            var lines = HootChatJSONLines()
            for await output in child.output {
                guard !Task.isCancelled else { break }
                do {
                    switch output {
                    case .stdout(let data): for row in try lines.append(data) { try await self?.receive(row) }
                    case .stderr: break // CLI stderr can include account details; never surface it as transcript.
                    case .exit:
                        for row in try lines.append(Data(), end: true) { try await self?.receive(row) }
                        await self?.ended(); return
                    }
                } catch { await self?.failed(error); child.stop(); return }
            }
        }
        _ = try await request("initialize", .object([.init("clientInfo", .object([
            .init("name", .string("terminaldeck-side-question")), .init("version", .string("1"))])),
            .init("capabilities", .object([.init("experimentalApi", .bool(true))]))]))
        try await child.send(BackendHootChatRPC.request("initialized"))
        var params = launch.setup?.session ?? .object([])
        // Only supported fork options are copied from backend-owned launch settings.
        let allowed: Set<String> = ["model", "modelProvider", "config", "developerInstructions", "baseInstructions", "serviceTier"]
        params = .object((params.fields ?? []).filter { allowed.contains($0.key) })
        let effective = try await request("config/read", .object([.init("cwd", .string(launch.cwd)), .init("includeLayers", .bool(false))]))
        guard effective["config"].fields != nil else { throw unavailable("The provider did not expose enough configuration to isolate a side question.") }
        let inherited = params["config"].fields == nil ? NativeRPCValue.object([]) : params["config"]
        params = params.setting("config", Self.isolatedConfig(effective: effective["config"], inherited: inherited, disabledServers: disabledServers))
        params = params.setting("threadId", .string(parent)).setting("cwd", .string(launch.cwd))
            .setting("ephemeral", .bool(true)).setting("deferGoalContinuation", .bool(true))
            .setting("excludeTurns", .bool(true)).setting("sandbox", .string("read-only"))
            .setting("approvalPolicy", .string("never"))
        let result = try await request("thread/fork", params)
        let id = try result["thread"]["id"].requireString("side conversation ID", nonempty: true)
        guard id != parent else { throw NativeRPCError.malformed("The provider did not create an independent conversation.") }
        let sandbox = result["sandbox"]
        guard sandbox["type"].string == "readOnly",
              sandbox["networkAccess"].bool == false || sandbox["networkAccess"].string == "restricted" else {
            throw unavailable("The provider did not confirm a read-only side conversation with network access disabled. No side question was sent.")
        }
        effectiveSandbox = .object([.init("type", .string("readOnly")), .init("networkAccess", sandbox["networkAccess"])])
        conversation = id
        // A fork inherits its parent's goal. Remove that goal only from this new fork before
        // the first side question, so answering cannot resume the parent's autonomous work.
        _ = try await request("thread/goal/clear", .object([.init("threadId", .string(id))]))
        try await verifyNoRemoteTools()
        try append(.init(.session, value: .object([.init("sideConversation", .bool(true)),
            .init("parentConversationId", .string(parent)), .init("ephemeral", .bool(true)), .init("effectiveSandbox", effectiveSandbox)])))
    }

    public func send(text: String) async throws -> NativeRPCValue {
        guard !closed, !conversation.isEmpty else { throw unavailable("This side conversation is closed.") }
        guard !busy else { throw NativeRPCError(code: "busy", message: "Wait for this side answer to finish.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 131_072 else {
            throw NativeRPCError.invalidArguments("Enter a side question up to 128 KiB.")
        }
        busy = true; localTurn = UUID().uuidString; activeTurn = nil
        do {
            try await verifyNoRemoteTools()
            try append(.text(.user, text))
            let result = try await request("turn/start", .object([.init("threadId", .string(conversation)),
                .init("sandboxPolicy", .object([.init("type", .string("readOnly")), .init("networkAccess", .bool(false))])),
                .init("approvalPolicy", .string("never")),
                .init("input", .array([.object([.init("type", .string("text")), .init("text", .string(text))])]))]))
            let turn = try result["turn"]["id"].requireString("side turn ID", nonempty: true)
            if busy { activeTurn = turn }
            return read()
        } catch {
            // A missing acknowledgement does not prove the provider did not start this turn.
            // End the independent child before permitting another question or returning failure.
            _ = await close(); throw error
        }
    }

    static func isolatedConfig(effective: NativeRPCValue, inherited: NativeRPCValue, disabledServers: [String]) -> NativeRPCValue {
        var result = inherited
        let serverNames = Set(disabledServers + (effective["mcp_servers"].fields ?? []).map(\.key) + (inherited["mcp_servers"].fields ?? []).map(\.key))
        let disabled = NativeRPCValue.object([.init("enabled", .bool(false))])
        // Explicit per-name overrides survive recursive TOML merging; an empty table does not.
        result = result.setting("mcp_servers", .object(serverNames.sorted().map { .init($0, disabled) }))
        let features = inherited["features"].fields == nil ? NativeRPCValue.object([]) : inherited["features"]
        result = result.setting("features", features.setting("apps", .bool(false)).setting("plugins", .bool(false)))
        // Also remove inherited legacy write-sandbox network enablement. This request alone
        // proves nothing: the actual fork response must independently confirm read-only/no network.
        let writeSandbox = inherited["sandbox_workspace_write"].fields == nil ? NativeRPCValue.object([]) : inherited["sandbox_workspace_write"]
        result = result.setting("sandbox_workspace_write", writeSandbox.setting("network_access", .bool(false)))
        for key in ["apps", "plugins"] {
            let names = Set((effective[key].fields ?? []).map(\.key) + (inherited[key].fields ?? []).map(\.key))
            var values = NativeRPCValue.object(names.sorted().map { .init($0, disabled) })
            if key == "apps" { values = values.setting("_default", disabled) }
            result = result.setting(key, values)
        }
        return result
    }

    private func verifyNoRemoteTools() async throws {
        var cursor: String?, seen = Set<String>()
        repeat {
            var params = NativeRPCValue.object([.init("threadId", .string(conversation)), .init("limit", .number(100))])
            if let cursor { params = params.setting("cursor", .string(cursor)) }
            let result = try await request("mcpServerStatus/list", params)
            guard let servers = result["data"].elements else { throw unavailable("The provider did not confirm the side question's tool isolation.") }
            for server in servers {
                let state = server["runtimeStatus"].string ?? server["runtimeStatus"]["status"].string
                guard let tools = server["tools"].fields, tools.isEmpty, server["toolsError"].isNullish,
                      ["connected", "disabled", "cancelled"].contains(state ?? "") else {
                    throw unavailable("The provider could not confirm that all remote tools are disabled for this side question.")
                }
            }
            if result["nextCursor"].isNullish { cursor = nil }
            else {
                guard let next = result["nextCursor"].string, !next.isEmpty, seen.count < 20, seen.insert(next).inserted else {
                    throw unavailable("The side tool inventory could not be completely verified.")
                }
                cursor = next
            }
        } while cursor != nil
    }

    public func read(after cursor: Int? = nil, limit: Int = 200) -> NativeRPCValue {
        let rows = events.filter { $0.sequence > (cursor ?? 0) }.prefix(max(1, min(500, limit)))
        return .object([.init("conversationId", .string(conversation)), .init("parentConversationId", .string(parent)),
            .init("provider", .string("codex")), .init("ephemeral", .bool(true)), .init("busy", .bool(busy)),
            .init("effectiveSandbox", effectiveSandbox),
            .init("alive", .bool(child.alive)),
            .init("closed", .bool(closed)), .init("sequence", .number(Double(sequence))),
            .init("events", .array(rows.map(\.wireValue))), .init("executionLocation", .string("local"))])
    }

    /// Stops only this child pipe. No archive/delete/interrupt operation targets the parent thread.
    @discardableResult public func close() async -> NativeRPCValue {
        closed = true; busy = false; activeTurn = nil
        failWaiters(unavailable("This side conversation was closed."))
        await child.stopAndWait()
        consumer?.cancel(); consumer = nil
        events.removeAll(); transcriptBytes = 0
        return read()
    }

    private func request(_ method: String, _ params: NativeRPCValue) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation(isolation: self) { continuation in
                guard !closed else { continuation.resume(throwing: unavailable("This side conversation is closed.")); return }
                waiters[id] = continuation
                Task {
                    do { try await child.send(BackendHootChatRPC.request(method, id: .string(id), params: params)) }
                    catch { reject(id, error) }
                }
                timeouts[id] = Task {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    reject(id, unavailable("The side conversation did not acknowledge \(method)."))
                }
            }
        }, onCancel: { [weak self] in Task { _ = await self?.close() } }, isolation: self)
    }
    private func reject(_ id: String, _ error: Error) {
        timeouts.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }
    private func failWaiters(_ error: Error) {
        let pending = waiters; waiters = [:]
        for timeout in timeouts.values { timeout.cancel() }; timeouts = [:]
        for continuation in pending.values { continuation.resume(throwing: error) }
    }
    private func receive(_ row: NativeRPCValue) async throws {
        if let id = row["id"].string, let continuation = waiters.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if row["error"].isNullish && row.has("result") { continuation.resume(returning: row["result"]) }
            else { continuation.resume(throwing: unavailable(row["error"]["message"].string ?? "The side conversation request failed.")) }
            return
        }
        if row["method"].string != nil, !row["id"].isNullish {
            // A side question never grants tool permissions or borrows the parent's consent broker.
            try await child.send(.object([.init("jsonrpc", .string("2.0")), .init("id", row["id"]),
                .init("error", .object([.init("code", .number(-32601)), .init("message", .string("Side questions do not grant tool permissions."))]))]))
            return
        }
        let params = row["params"], method = row["method"].string ?? ""
        guard !closed, !conversation.isEmpty, params["threadId"].string == conversation, busy else { return }
        if method == "turn/started", let id = params["turn"]["id"].string { activeTurn = id; return }
        guard let activeTurn, (params["turnId"].string ?? params["turn"]["id"].string) == activeTurn else { return }
        switch method {
        case "item/agentMessage/delta": try append(.text(.textDelta, id: params["itemId"].string ?? "", params["delta"].string ?? ""))
        case "item/completed":
            let item = params["item"], id = item["id"].string ?? ""
            if item["type"].string == "agentMessage" { try append(.text(.message, id: id, item["text"].string ?? "")) }
            else { try append(.init(.session, id: id, value: .object([.init("providerItem", item)]))) }
        case "turn/completed":
            if params["turn"]["status"].string == "failed" { try append(.text(.error, params["turn"]["error"]["message"].string ?? "The side answer failed.")) }
            try append(.init(.completed, value: params["turn"])); busy = false; self.activeTurn = nil
        case "error": try append(.text(.error, params["error"]["message"].string ?? "The side conversation reported an error."))
        default: break
        }
    }
    private func append(_ record: HootChatRecord) throws {
        let size = try record.value.encodedJSON().count
        guard events.count < 4000, transcriptBytes + size <= 8_388_608 else { throw unavailable("The side transcript reached its limit. Close it and open another side question.") }
        sequence += 1; transcriptBytes += size
        events.append(.init(conversationID: conversation, turnID: localTurn, sequence: sequence, provider: .codex, record: record))
    }
    private func failed(_ error: Error) { closed = true; busy = false; failWaiters(error); try? append(.text(.error, error.localizedDescription)) }
    private func ended() { closed = true; busy = false; failWaiters(unavailable("The side conversation process ended.")) }
    private func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
}
