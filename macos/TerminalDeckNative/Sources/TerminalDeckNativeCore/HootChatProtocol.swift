import Foundation

public enum HootChatProvider: String, Sendable { case claude, codex, gemini }
public enum HootChatKind: String, Sendable {
    case session, user, textDelta, message, toolCall, toolResult, approval
    case approvalResolved, completed, interrupted, error
}

/// The provider-neutral body. IDs come from structured CLI records, not text.
public struct HootChatRecord: Equatable, Sendable {
    public let kind: HootChatKind
    public let messageID: String
    public let value: NativeRPCValue
    public init(_ kind: HootChatKind, id: String = "", value: NativeRPCValue = .null) {
        self.kind = kind; messageID = id; self.value = value
    }
    public static func text(_ kind: HootChatKind, id: String = "", _ text: String) -> Self {
        .init(kind, id: id, value: .object([.init("text", .string(text))]))
    }
}

/// Provider-emitted telemetry only. Selected settings and thread defaults never become
/// evidence that a particular model actually answered a turn.
public enum HootChatProviderRecords {
    public static func modelReceipt(_ model: NativeRPCValue, session: NativeRPCValue, turn: NativeRPCValue = .null,
                                    message: NativeRPCValue = .null, source: String) -> HootChatRecord? {
        guard let name = model.string, !name.isEmpty, name.utf8.count <= 256,
              !name.hasPrefix("<"), !["default", "auto", "unknown"].contains(name.lowercased()),
              let sessionID = session.string, !sessionID.isEmpty,
              turn.string?.isEmpty == false || message.string?.isEmpty == false else { return nil }
        return .init(.session, value: .object([.init("appliedModelReceipt", .object([
            .init("model", .string(name)), .init("providerSessionId", .string(sessionID)),
            .init("providerTurnId", turn), .init("providerMessageId", message), .init("source", .string(source))]))]))
    }

    public static func hook(_ raw: NativeRPCValue, source: String) -> HootChatRecord {
        var hook = raw.setting("sourceEvent", .string(source))
        if !hook.has("name") { hook = hook.setting("name", raw["hook_name"].isNullish ? raw["eventName"] : raw["hook_name"]) }
        if !hook.has("status") {
            hook = hook.setting("status", raw["outcome"].isNullish ? raw["subtype"] : raw["outcome"])
        }
        if !hook.has("message") {
            let output = raw["output"].isNullish ? raw["stderr"] : raw["output"]
            hook = hook.setting("message", raw["statusMessage"].isNullish ? output : raw["statusMessage"])
        }
        if !hook.has("stopReason"), ["stopped", "blocked"].contains(hook["status"].string ?? "") {
            hook = hook.setting("stopReason", raw["statusMessage"])
        }
        let entries = raw["entries"].elements ?? []
        var warnings = entries.filter { ["warning", "error"].contains($0["kind"].string ?? "") }.compactMap { $0["text"].string }
        if let warning = raw["warning"].string, !warning.isEmpty { warnings.append(warning) }
        if ["error", "failed", "blocked"].contains(hook["status"].string ?? ""), let stderr = raw["stderr"].string, !stderr.isEmpty { warnings.append(stderr) }
        let stops = entries.filter { $0["kind"].string == "stop" }.compactMap { $0["text"].string }
        if !warnings.isEmpty, hook["warning"].isNullish { hook = hook.setting("warning", .string(warnings.joined(separator: "\n"))) }
        if !stops.isEmpty { hook = hook.setting("stopReason", .string(stops.joined(separator: "\n"))) }
        var value = NativeRPCValue.object([.init("hook", hook)])
        if !warnings.isEmpty { value = value.setting("warnings", .array(warnings.map(NativeRPCValue.string))) }
        return .init(.session, id: raw["id"].string ?? raw["hook_id"].string ?? "", value: value)
    }

    /// Extract exact per-file unified patches without treating hunk contents as file headers.
    /// Unsupported/binary sections stay in the caller's aggregate source record, not invented files.
    public static func unifiedChanges(_ diff: String) -> [NativeRPCValue] {
        guard diff.utf8.count <= 2_097_152 else { return [] }
        var changes: [NativeRPCValue] = [], lines: [String] = []
        var old: String?, new: String?, inHunk = false
        func finish() {
            guard inHunk, let path = new ?? old, !path.isEmpty else { return }
            var patch = lines.joined(separator: "\n")
            if !patch.hasSuffix("\n") { patch += "\n" }
            changes.append(.object([.init("path", .string(path)), .init("diff", .string(patch))]))
        }
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                finish(); lines = []; old = nil; new = nil; inHunk = false
            }
            lines.append(line)
            if line.hasPrefix("@@ ") { inHunk = true }
            if !inHunk, line.hasPrefix("--- ") { old = diffPath(String(line.dropFirst(4))) }
            if !inHunk, line.hasPrefix("+++ ") { new = diffPath(String(line.dropFirst(4))) }
        }
        finish()
        return changes
    }
    private static func diffPath(_ raw: String) -> String? {
        let value: String
        if raw.hasPrefix("\"") {
            var bytes: [UInt8] = [], index = 1
            let input = Array(raw.utf8)
            var ended = false
            while index < input.count {
                let byte = input[index]; index += 1
                if byte == 34 { ended = true; break }
                if byte != 92 { bytes.append(byte); continue }
                guard index < input.count else { return nil }
                let escaped = input[index]; index += 1
                if (48...55).contains(escaped) {
                    var number = Int(escaped - 48), count = 1
                    while count < 3, index < input.count, (48...55).contains(input[index]) {
                        number = number * 8 + Int(input[index] - 48); index += 1; count += 1
                    }
                    guard number <= 255 else { return nil }; bytes.append(UInt8(number))
                } else {
                    let escapes: [UInt8: UInt8] = [34: 34, 92: 92, 97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
                    guard let decoded = escapes[escaped] else { return nil }; bytes.append(decoded)
                }
            }
            guard ended, let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }; value = decoded
        } else { value = String(raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        guard value != "/dev/null", !value.isEmpty, !value.contains("\0") else { return nil }
        return value.hasPrefix("a/") || value.hasPrefix("b/") ? String(value.dropFirst(2)) : value
    }

    /// ACP tool-call diff content includes before/after text, with null meaning before unknown.
    /// Keep that distinction: a missing before version is never treated as an empty new file.
    public static func acpChanges(_ content: NativeRPCValue) -> [NativeRPCValue] {
        (content.elements ?? []).compactMap { entry in
            guard entry["type"].string == "diff", let path = entry["path"].string,
                  let after = entry["newText"].string else { return nil }
            var change = NativeRPCValue.object([.init("path", .string(path)), .init("newText", .string(after)), .init("oldText", entry["oldText"])])
            if let before = entry["oldText"].string, before.utf8.count + after.utf8.count <= 1_048_576 {
                func lines(_ text: String) -> [String] {
                    guard !text.isEmpty else { return [] }
                    var values = text.components(separatedBy: "\n")
                    if text.hasSuffix("\n") { values.removeLast() }; return values
                }
                let old = lines(before), new = lines(after)
                var patch = ["--- a/" + path, "+++ b/" + path, "@@ -\(old.isEmpty ? 0 : 1),\(old.count) +\(new.isEmpty ? 0 : 1),\(new.count) @@"]
                patch += old.map { "-" + $0 }
                if !old.isEmpty, !before.hasSuffix("\n") { patch.append("\\ No newline at end of file") }
                patch += new.map { "+" + $0 }
                if !new.isEmpty, !after.hasSuffix("\n") { patch.append("\\ No newline at end of file") }
                change = change.setting("diff", .string(patch.joined(separator: "\n") + "\n"))
            }
            return change
        }
    }
}

public struct HootChatEvent: Equatable, Sendable, Identifiable {
    public let conversationID: String, turnID: String
    public let sequence: Int
    public let provider: HootChatProvider
    public let record: HootChatRecord
    public let at: Double
    public var id: String { conversationID + ":" + String(sequence) }
    public init(conversationID: String, turnID: String, sequence: Int, provider: HootChatProvider,
                record: HootChatRecord, at: Double = Date().timeIntervalSince1970 * 1000) {
        self.conversationID = conversationID; self.turnID = turnID; self.sequence = sequence
        self.provider = provider; self.record = record; self.at = at
    }
    public var wireValue: NativeRPCValue {
        .object([.init("version", .number(1)), .init("id", .string(id)), .init("conversationId", .string(conversationID)),
                 .init("turnId", .string(turnID)), .init("sequence", .number(Double(sequence))),
                 .init("provider", .string(provider.rawValue)), .init("kind", .string(record.kind.rawValue)),
                 .init("messageId", .string(record.messageID)), .init("value", record.value), .init("at", .number(at))])
    }
    public init(wire: NativeRPCValue) throws {
        guard wire["version"].number == 1, let sequence = wire["sequence"].number,
              sequence > 0, sequence.rounded() == sequence, sequence < Double(Int.max),
              let provider = HootChatProvider(rawValue: wire["provider"].string ?? ""),
              let kind = HootChatKind(rawValue: wire["kind"].string ?? ""), let at = wire["at"].number else {
            throw NativeRPCError.malformed("Invalid Hoot chat event")
        }
        self.init(conversationID: try wire["conversationId"].requireString("conversationId", nonempty: true),
                  turnID: try wire["turnId"].requireString("turnId"), sequence: Int(sequence), provider: provider,
                  record: .init(kind, id: try wire["messageId"].requireString("messageId"), value: wire["value"]), at: at)
    }
}

/// Handles byte boundaries, including a split UTF-8 scalar. No lossy conversion.
public struct HootChatJSONLines: Sendable {
    /// One line from the CLI can be very large (a resumed thread returns its whole history).
    public static let maximumLineBytes = 64 * 1_048_576
    /// What Hoot itself writes to the CLI stays small.
    // A permitted 256 KiB UTF-8 draft can expand sixfold when JSON escapes control
    // characters; native slash expansion can repeat its arguments, and four 500 KB
    // attachments add about 2.67 MB of base64. Six MiB covers that complete supported
    // envelope. Expansion happens after the separately bounded app/helper request.
    public static let maximumInputBytes = 6 * 1_048_576
    private var pending = Data()
    public init() {}
    public mutating func append(_ bytes: Data, end: Bool = false) throws -> [NativeRPCValue] {
        pending.append(bytes)
        var rows: [NativeRPCValue] = []
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            if !line.isEmpty { rows.append(try NativeRPCValue.parseJSON(line, maximumBytes: Self.maximumLineBytes)) }
        }
        guard pending.count <= Self.maximumLineBytes else { throw NativeRPCError.malformed("Hoot stream line is too large") }
        if end, !pending.isEmpty {
            rows.append(try NativeRPCValue.parseJSON(pending, maximumBytes: Self.maximumLineBytes)); pending.removeAll()
        }
        return rows
    }
}

/// Streaming snapshots and deltas share a message ID so the UI never doubles a reply.
public struct HootChatDecoder: Sendable {
    public let provider: HootChatProvider
    private var messageID = ""
    private var messageIDs: [String: String] = [:]
    private var toolIDs: [Int: String] = [:]
    private var thinkingBlocks: Set<Int> = []
    private var geminiSegment = 0
    private var activeTurnID = ""
    private var hookOwners: [String: String] = [:]
    private var hookOrder: [String] = []
    public init(provider: HootChatProvider) { self.provider = provider }
    public mutating func beginTurn(id: String) { activeTurnID = id }
    public mutating func decode(_ row: NativeRPCValue) throws -> [HootChatRecord] {
        guard row.fields != nil else { throw NativeRPCError.malformed("Expected a Hoot stream object") }
        switch provider {
        case .claude: return claude(row)
        case .codex: return codex(row)
        case .gemini: return gemini(row)
        }
    }
    private mutating func claude(_ row: NativeRPCValue) -> [HootChatRecord] {
        switch row["type"].string {
        case "system" where ["hook_started", "hook_progress", "hook_response", "stop_hook_summary"].contains(row["subtype"].string ?? ""):
            let id = row["hook_id"].string ?? "", subtype = row["subtype"].string ?? "hook"
            if subtype == "hook_started", !id.isEmpty {
                if hookOwners[id] == nil { hookOrder.append(id) }
                hookOwners[id] = activeTurnID
                if hookOrder.count > 512 { hookOwners.removeValue(forKey: hookOrder.removeFirst()) }
            }
            let record = HootChatProviderRecords.hook(row, source: "claude/system/" + subtype)
            return [.init(.session, id: record.messageID, value: record.value.setting("eventTurnId", .string(hookOwners[id] ?? "")))]
        case "system" where row["subtype"].string == "warning":
            return [.init(.session, value: .object([.init("warning", row["message"].isNullish ? row : row["message"]), .init("providerWarning", row)]))]
        case "system" where row["subtype"].string == "init":
            // Its slash commands too (names only): the "/" menu's fallback when the handshake gave none.
            var value = NativeRPCValue.object([.init("sessionId", row["session_id"])])
            if row["slash_commands"].elements != nil { value = value.setting("slashCommands", row["slash_commands"]) }
            if let tools = row["tools"].elements { value = value.setting("tools", .array(tools.compactMap(\.string).prefix(512).map(NativeRPCValue.string))) }
            return [.init(.session, value: value)]
        case "system" where row["subtype"].string == "session_state_changed":
            return [.init(.session, value: .object([.init("status", row["state"])]))]
        case "system" where row["subtype"].string == "task_started":
            return [.init(.session, value: .object([.init("taskStarted", row["task_id"]), .init("childTask", Self.childTask(row, status: "running"))]))]
        case "system" where row["subtype"].string == "task_notification":
            return [.init(.session, value: .object([.init("taskFinished", row["task_id"]), .init("childTask", Self.childTask(row, status: row["status"].string ?? "completed"))]))]
        case "system" where row["subtype"].string == "task_progress":
            return [.init(.session, value: .object([.init("childTask", Self.childTask(row, status: "running"))]))]
        case "stream_event":
            let event = row["event"], index = Int(event["index"].number ?? -1)
            let lane = row["parent_tool_use_id"].string ?? "main"
            switch event["type"].string {
            case "message_start":
                messageID = event["message"]["id"].string ?? row["uuid"].string ?? UUID().uuidString
                messageIDs[lane] = messageID; toolIDs = [:]
                if lane == "main" { thinkingBlocks = [] }
                if lane == "main", let receipt = HootChatProviderRecords.modelReceipt(event["message"]["model"], session: row["session_id"],
                    message: event["message"]["id"], source: "claude/message_start") { return [receipt] }
            case "content_block_start":
                let block = event["content_block"]
                if block["type"].string == "thinking", lane == "main" {
                    thinkingBlocks.insert(index)
                    return [.init(.session, value: .object([.init("reasoning", .object([
                        .init("id", .string((messageIDs[lane] ?? messageID) + ":thinking:" + String(index))),
                        .init("phase", .string("start")), .init("text", block["thinking"])]))]))]
                }
                if block["type"].string == "tool_use", let id = block["id"].string {
                    toolIDs[index] = id
                    return [.init(.toolCall, id: id, value: .object([.init("name", block["name"]), .init("input", block["input"])]))]
                }
            case "content_block_delta":
                let delta = event["delta"]
                if delta["type"].string == "thinking_delta", lane == "main", let text = delta["thinking"].string {
                    thinkingBlocks.insert(index)
                    return [.init(.session, value: .object([.init("reasoning", .object([
                        .init("id", .string((messageIDs[lane] ?? messageID) + ":thinking:" + String(index))),
                        .init("phase", .string("delta")), .init("text", .string(text))]))]))]
                }
                if delta["type"].string == "text_delta", let text = delta["text"].string {
                    return [.text(.textDelta, id: messageIDs[lane] ?? messageID, text)]
                }
            case "content_block_stop" where lane == "main" && thinkingBlocks.contains(index):
                thinkingBlocks.remove(index)
                return [.init(.session, value: .object([.init("reasoning", .object([
                    .init("id", .string((messageIDs[lane] ?? messageID) + ":thinking:" + String(index))), .init("phase", .string("end"))]))]))]
            default: break
            }
            return []
        case "assistant":
            let message = row["message"], id = message["id"].string ?? row["uuid"].string ?? messageID
            var records: [HootChatRecord] = [], text = ""
            if row["parent_tool_use_id"].isNullish, let receipt = HootChatProviderRecords.modelReceipt(message["model"], session: row["session_id"],
                message: message["id"], source: "claude/assistant") { records.append(receipt) }
            for (index, block) in (message["content"].elements ?? []).enumerated() {
                if block["type"].string == "thinking", row["parent_tool_use_id"].isNullish, let thought = block["thinking"].string {
                    records.append(.init(.session, value: .object([.init("reasoning", .object([
                        .init("id", .string(id + ":thinking:" + String(index))), .init("phase", .string("full")), .init("text", .string(thought))]))])))
                }
                if block["type"].string == "text" { text += block["text"].string ?? "" }
                if block["type"].string == "tool_use", let toolID = block["id"].string {
                    records.append(.init(.toolCall, id: toolID, value: .object([.init("name", block["name"]), .init("input", block["input"])])))
                }
            }
            if !text.isEmpty {
                let record = HootChatRecord.text(row["is_api_error_message"].bool == true ? .error : .message, id: id, text)
                records.insert(.init(record.kind, id: record.messageID, value: record.value.setting("providerMessageId", row["parent_tool_use_id"].isNullish ? row["uuid"] : .null)), at: 0)
            }
            // Deck Memory: how much is in view after this step. Sub-agents have their own desks.
            let usage = message["usage"]
            if row["parent_tool_use_id"].isNullish, usage.fields != nil {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].reduce(0.0) { $0 + (usage[$1].number ?? 0) }
                if tokens > 0 { records.append(.init(.session, value: .object([.init("deskUsage", .object([.init("tokens", .number(tokens))]))]))) }
            }
            return records
        case "user":
            return (row["message"]["content"].elements ?? []).compactMap { block in
                guard block["type"].string == "tool_result", let id = block["tool_use_id"].string else { return nil }
                return .init(.toolResult, id: id, value: .object([.init("output", block["content"]), .init("isError", block["is_error"]), .init("details", row["tool_use_result"])]))
            }
        case "control_request":
            let request = row["request"]
            guard let id = row["request_id"].string else { return [.text(.error, "A permission request had no ID.")] }
            if request["subtype"].string == "elicitation" {
                // Claude's control transport uses snake_case fields directly on
                // the request, rather than the tool permission's input object.
                let input = NativeRPCValue.object([
                    .init("mode", request["mode"]), .init("message", request["message"]),
                    .init("serverName", request["mcp_server_name"]), .init("requestedSchema", request["requested_schema"]),
                    .init("url", request["url"]), .init("elicitationId", request["elicitation_id"]),
                    .init("propertyOrder", request["property_order"]), .init("title", request["title"]),
                    .init("displayName", request["display_name"]), .init("description", request["description"])
                ])
                return [.init(.approval, id: id, value: .object([
                    .init("requestId", .string(id)), .init("subtype", request["subtype"]),
                    .init("name", request["title"].string.map(NativeRPCValue.string) ?? request["display_name"].string.map(NativeRPCValue.string) ?? request["mcp_server_name"]),
                    .init("input", input)
                ]))]
            }
            return [.init(.approval, id: id, value: .object([.init("requestId", .string(id)), .init("subtype", request["subtype"]),
                .init("name", request["tool_name"]), .init("input", request["input"]), .init("toolId", request["tool_use_id"]),
                .init("permissionSuggestions", request["permission_suggestions"]), .init("blockedPath", request["blocked_path"]),
                .init("reason", request["decision_reason"]), .init("decisionReasonType", request["decision_reason_type"]),
                .init("description", request["description"]), .init("title", request["title"]),
                .init("displayName", request["display_name"]), .init("mcpServer", request["mcp_server"])]))]
        case "control_cancel_request":
            return [.init(.approvalResolved, id: row["request_id"].string ?? "", value: .object([.init("allowed", .bool(false))]))]
        case "result":
            var records: [HootChatRecord] = []
            if row["is_error"].bool == true || row["subtype"].string != "success" {
                let errors = row["errors"].elements?.compactMap(\.string).joined(separator: "\n")
                records.append(.text(.error, errors.flatMap { $0.isEmpty ? nil : $0 } ?? row["result"].string ?? "Hoot's turn failed."))
            }
            records.append(.init(.completed, value: .object([.init("sessionId", row["session_id"]), .init("usage", row["usage"]), .init("modelUsage", row["modelUsage"]), .init("costUSD", row["total_cost_usd"]),
                .init("stopReason", row["stop_reason"]), .init("subtype", row["subtype"]), .init("errors", row["errors"])])))
            return records
        default: return []
        }
    }
    private static func childTask(_ row: NativeRPCValue, status: String) -> NativeRPCValue {
        var task = NativeRPCValue.object([.init("id", row["task_id"]), .init("title", row["description"]), .init("summary", row["summary"]),
                 .init("kind", row["task_type"]), .init("toolUseId", row["tool_use_id"]), .init("status", .string(status))])
        for (key, alternate) in [("parentTaskId", "parent_task_id"), ("parentThreadId", "parent_thread_id"), ("appTaskId", "app_task_id"),
                                 ("agentPath", "agent_path"), ("agentRole", "agent_role"), ("agentNickname", "agent_nickname")] {
            let value = row[key].isNullish ? row[alternate] : row[key]
            if !value.isNullish { task = task.setting(key, value) }
        }
        if !row["source"].isNullish { task = task.setting("source", row["source"]) }
        return task
    }
    private func codex(_ row: NativeRPCValue) -> [HootChatRecord] {
        switch row["type"].string {
        case "thread.started": return [.init(.session, value: .object([.init("sessionId", row["thread_id"])]))]
        case "turn.completed": return [.init(.completed, value: row["usage"])]
        case "turn.failed", "error": return [.text(.error, row["error"]["message"].string ?? row["message"].string ?? "Codex's turn failed.")]
        case "item.started", "item.updated", "item.completed":
            let item = row["item"], id = item["id"].string ?? "", done = row["type"].string == "item.completed"
            switch item["type"].string {
            case "agent_message": return [.text(.message, id: id, item["text"].string ?? "")]
            case "command_execution", "mcp_tool_call", "file_change", "web_search":
                let name = item["tool"].string ?? item["command"].string ?? item["type"].string ?? "Tool"
                let input = !item["arguments"].isNullish ? item["arguments"] : !item["changes"].isNullish ? .object([.init("changes", item["changes"])]) : .object([.init("command", item["command"]), .init("query", item["query"])])
                var records = [HootChatRecord(.toolCall, id: id, value: .object([.init("name", .string(name)), .init("input", input), .init("mcpCall", HootChatMCPProvenance.record(item))]))]
                if done { records.append(.init(.toolResult, id: id, value: .object([.init("output", item["result"].isNullish ? item["aggregated_output"] : item["result"]),
                    .init("error", item["error"]), .init("isError", .bool(item["status"].string == "failed" || !item["error"].isNullish)),
                    .init("status", item["status"]), .init("exitCode", item["exit_code"])]))) }
                return records
            default: return []
            }
        default: return []
        }
    }
    private mutating func gemini(_ row: NativeRPCValue) -> [HootChatRecord] {
        switch row["type"].string {
        case "init":
            geminiSegment = 0
            return [.init(.session, value: .object([.init("sessionId", row["session_id"])]))]
        case "message":
            guard row["role"].string == "assistant", let text = row["content"].string else { return [] }
            let id = row["message_id"].string ?? "gemini-\(geminiSegment)"
            return [.text(row["delta"].bool == true ? .textDelta : .message, id: id, text)]
        case "tool_use":
            geminiSegment += 1
            return [.init(.toolCall, id: row["tool_id"].string ?? "", value: .object([.init("name", row["tool_name"]), .init("input", row["parameters"]), .init("mcpCall", HootChatMCPProvenance.record(row))]))]
        case "tool_result":
            return [.init(.toolResult, id: row["tool_id"].string ?? "", value: .object([.init("output", row["output"]), .init("status", row["status"]),
                .init("isError", .bool(row["status"].string == "error")), .init("error", row["error"])]))]
        case "error": return [.text(.error, row["message"].string ?? "Gemini's turn failed.")]
        case "result":
            var records: [HootChatRecord] = []
            if row["status"].string != "success" { records.append(.text(.error, row["error"]["message"].string ?? "Gemini's turn failed.")) }
            records.append(.init(.completed, value: .object([.init("usage", row["stats"])])))
            return records
        default: return []
        }
    }
}

public struct HootChatRow: Equatable, Sendable, Identifiable {
    public let id: String
    public var kind: HootChatKind
    public var value: NativeRPCValue
    /// When it was written (milliseconds), and the event the row starts at (what a rewind points to).
    public var at: Double = 0
    public var sequence: Int = 0
}
public enum HootChatProjection {
    /// A reset contains whole text snapshots; taking the tail of raw deltas loses
    /// the beginning of a long reply on every reconnect/slow-reader update.
    public static func snapshotEvents(_ events: [HootChatEvent]) -> [HootChatEvent] {
        var latest: [String: HootChatEvent] = [:], texts: [String: String] = [:]
        var other: [HootChatEvent] = []
        for event in events {
            let record = event.record
            guard [.textDelta, .message].contains(record.kind) else { other.append(event); continue }
            let key = event.turnID + ":" + record.messageID
            texts[key] = record.kind == .message ? record.value["text"].string ?? "" : (texts[key] ?? "") + (record.value["text"].string ?? "")
            latest[key] = event
        }
        for (key, event) in latest {
            other.append(.init(conversationID: event.conversationID, turnID: event.turnID, sequence: event.sequence,
                               provider: event.provider, record: .init(.message, id: event.record.messageID,
                                   value: event.record.value.setting("text", .string(texts[key] ?? ""))), at: event.at))
        }
        return other.sorted { $0.sequence < $1.sequence }
    }
    public static func rows(_ events: [HootChatEvent]) -> [HootChatRow] {
        var result: [HootChatRow] = [], indices: [String: Int] = [:]
        for event in events {
            let record = event.record
            if [.session, .completed, .approvalResolved].contains(record.kind) { continue }
            let key = event.turnID + ":" + (record.messageID.isEmpty ? event.id : record.messageID)
            if let index = indices[key] {
                if record.kind == .textDelta {
                    let text = (result[index].value["text"].string ?? "") + (record.value["text"].string ?? "")
                    result[index].value = result[index].value.setting("text", .string(text))
                } else if record.kind == .toolResult {
                    var value = record.value
                    if value["partial"].bool == true {
                        value = value.setting("output", .string((result[index].value["output"].string ?? "") + (value["output"].string ?? "")))
                    }
                    result[index].value = result[index].value.merging(value).setting("finished", .bool(value["partial"].bool != true))
                } else { result[index].kind = record.kind; result[index].value = record.value }
            } else {
                indices[key] = result.count; result.append(.init(id: key, kind: record.kind, value: record.value, at: event.at, sequence: event.sequence))
            }
        }
        return result
    }
}
