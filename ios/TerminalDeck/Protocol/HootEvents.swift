import Foundation

/// Matches HOOT's normalized version-1 stream. A request ID is display data,
/// never permission to approve; the existing trusted ask/answer path owns that.
struct HootEvent: Equatable {
    enum Kind: String { case session, user, textDelta, message, toolCall, toolResult, approval, approvalResolved, completed, interrupted, error }
    let id: String
    let sequence: Int
    let conversationId: String
    let turnId: String
    let provider: String
    let kind: Kind
    let messageId: String
    let at: Double
    let text: String
    let toolId: String?
    let name: String?
    let input: String?
    let requestId: String?
    let failed: Bool

    static func decode(_ value: Any) -> HootEvent? {
        guard let row = value as? [String: Any], WireCodec.whole(row["version"]) == 1,
              let id = identifier(row["id"]),
              let sequence = WireCodec.whole(row["sequence"]), sequence > 0,
              let conversation = identifier(row["conversationId"]),
              let turn = row["turnId"] as? String, turn.utf8.count <= 512,
              let provider = row["provider"] as? String, ["claude", "codex", "gemini"].contains(provider),
              let rawKind = row["kind"] as? String, let kind = Kind(rawValue: rawKind),
              let message = row["messageId"] as? String, message.utf8.count <= 512,
              let at = row["at"] as? NSNumber, CFGetTypeID(at) != CFBooleanGetTypeID(), at.doubleValue.isFinite else { return nil }
        let body = row["value"] as? [String: Any] ?? [:]
        let output = body["output"]
        let outputText: String
        if let text = output as? String { outputText = text }
        else if let output, JSONSerialization.isValidJSONObject(output),
                let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), data.count <= 64 * 1024 {
            outputText = String(data: data, encoding: .utf8) ?? ""
        } else { outputText = "" }
        let rawText = body["text"] as? String ?? outputText
        guard rawText.utf8.count <= 64 * 1024 else { return nil }
        let input: String?
        if let string = body["input"] as? String { input = string }
        else if let value = body["input"], JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 16 * 1024 {
            input = String(data: data, encoding: .utf8)
        } else { input = nil }
        return .init(id: id, sequence: sequence, conversationId: conversation,
                     turnId: turn, provider: provider, kind: kind, messageId: message.isEmpty ? id : message,
                     at: at.doubleValue, text: CopilotText.display(rawText),
                     toolId: identifier(body["toolId"]) ?? ([.toolCall, .toolResult].contains(kind) ? identifier(message) : nil),
                     name: identifier(body["name"]), input: input.map { String($0.prefix(16 * 1024)) },
                     requestId: identifier(body["requestId"]) ?? ([.approval, .approvalResolved].contains(kind) ? identifier(message) : nil),
                     failed: WireCodec.literalTrue(body["isError"]) || body["status"] as? String == "failed" || (body["exitCode"] as? Int ?? 0) != 0)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 512 else { return nil }
        return string
    }
}

struct HootEventBatch: Equatable {
    let conversationId: String
    let reset: Bool
    let events: [HootEvent]

    static func decode(_ object: [String: Any]) -> HootEventBatch? {
        guard let conversation = object["conversationId"] as? String, !conversation.isEmpty,
              conversation.utf8.count <= 512,
              let reset = object["reset"] as? NSNumber, CFGetTypeID(reset) == CFBooleanGetTypeID(),
              let rows = object["events"] as? [Any], rows.count <= 600 else { return nil }
        let events = rows.compactMap(HootEvent.decode)
        // Reject a partial batch: losing one delta would silently alter the answer.
        guard events.count == rows.count, events.allSatisfy({ $0.conversationId == conversation }),
              Set(events.map(\.sequence)).count == events.count else { return nil }
        return .init(conversationId: conversation, reset: reset.boolValue, events: events)
    }
}
