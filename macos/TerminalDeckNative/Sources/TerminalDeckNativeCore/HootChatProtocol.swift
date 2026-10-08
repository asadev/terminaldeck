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
    public static let maximumLineBytes = 1_048_576
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
    private var geminiSegment = 0
    public init(provider: HootChatProvider) { self.provider = provider }
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
        case "system" where row["subtype"].string == "init":
            return [.init(.session, value: .object([.init("sessionId", row["session_id"])]))]
        case "system" where row["subtype"].string == "session_state_changed":
            return [.init(.session, value: .object([.init("status", row["state"])]))]
        case "system" where row["subtype"].string == "task_started":
            return [.init(.session, value: .object([.init("taskStarted", row["task_id"])]))]
        case "system" where row["subtype"].string == "task_notification":
            return [.init(.session, value: .object([.init("taskFinished", row["task_id"])]))]
        case "stream_event":
            let event = row["event"], index = Int(event["index"].number ?? -1)
            let lane = row["parent_tool_use_id"].string ?? "main"
            switch event["type"].string {
            case "message_start":
                messageID = event["message"]["id"].string ?? row["uuid"].string ?? UUID().uuidString
                messageIDs[lane] = messageID; toolIDs = [:]
            case "content_block_start":
                let block = event["content_block"]
                if block["type"].string == "tool_use", let id = block["id"].string {
                    toolIDs[index] = id
                    return [.init(.toolCall, id: id, value: .object([.init("name", block["name"]), .init("input", block["input"])]))]
                }
            case "content_block_delta":
                let delta = event["delta"]
                if delta["type"].string == "text_delta", let text = delta["text"].string {
                    return [.text(.textDelta, id: messageIDs[lane] ?? messageID, text)]
                }
            default: break
            }
            return []
        case "assistant":
            let message = row["message"], id = message["id"].string ?? row["uuid"].string ?? messageID
            var records: [HootChatRecord] = [], text = ""
            for block in message["content"].elements ?? [] {
                if block["type"].string == "text" { text += block["text"].string ?? "" }
                if block["type"].string == "tool_use", let toolID = block["id"].string {
                    records.append(.init(.toolCall, id: toolID, value: .object([.init("name", block["name"]), .init("input", block["input"])])))
                }
            }
            if !text.isEmpty { records.insert(.text(row["is_api_error_message"].bool == true ? .error : .message, id: id, text), at: 0) }
            return records
        case "user":
            return (row["message"]["content"].elements ?? []).compactMap { block in
                guard block["type"].string == "tool_result", let id = block["tool_use_id"].string else { return nil }
                return .init(.toolResult, id: id, value: .object([.init("output", block["content"]), .init("isError", block["is_error"])]))
            }
        case "control_request":
            let request = row["request"]
            guard let id = row["request_id"].string else { return [.text(.error, "A permission request had no ID.")] }
            return [.init(.approval, id: id, value: .object([.init("requestId", .string(id)), .init("subtype", request["subtype"]),
                .init("name", request["tool_name"]), .init("input", request["input"]), .init("toolId", request["tool_use_id"])]))]
        case "control_cancel_request":
            return [.init(.approvalResolved, id: row["request_id"].string ?? "", value: .object([.init("allowed", .bool(false))]))]
        case "result":
            var records: [HootChatRecord] = []
            if row["is_error"].bool == true || row["subtype"].string != "success" {
                let errors = row["errors"].elements?.compactMap(\.string).joined(separator: "\n")
                records.append(.text(.error, errors.flatMap { $0.isEmpty ? nil : $0 } ?? row["result"].string ?? "Hoot's turn failed."))
            }
            records.append(.init(.completed, value: .object([.init("sessionId", row["session_id"]), .init("usage", row["usage"])])))
            return records
        default: return []
        }
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
                let input = !item["arguments"].isNullish ? item["arguments"] : !item["changes"].isNullish ? item["changes"] : .object([.init("command", item["command"]), .init("query", item["query"])])
                var records = [HootChatRecord(.toolCall, id: id, value: .object([.init("name", .string(name)), .init("input", input)]))]
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
            return [.init(.toolCall, id: row["tool_id"].string ?? "", value: .object([.init("name", row["tool_name"]), .init("input", row["parameters"])]))]
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
                               provider: event.provider, record: .text(.message, id: event.record.messageID, texts[key] ?? ""), at: event.at))
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
                indices[key] = result.count; result.append(.init(id: key, kind: record.kind, value: record.value))
            }
        }
        return result
    }
}
