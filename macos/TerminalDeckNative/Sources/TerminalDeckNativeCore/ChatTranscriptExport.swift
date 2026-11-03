import Foundation

/// Exports every retained provider-neutral record, including tool values. No viewport/page limit.
public enum ChatTranscriptExport {
    public static func markdown(events: [HootChatEvent], session: String, conversation: String) throws -> String {
        let records = events.sorted { $0.sequence < $1.sequence }
        let providers = Set(records.map { $0.provider.rawValue }).sorted().joined(separator: ", ")
        var parts = ["# Conversation transcript", "Session: \(session)\nConversation: \(conversation)\nProviders: \(providers.isEmpty ? "not reported" : providers)\nRecords: \(records.count)\nSequence range: \(records.first.map { String($0.sequence) } ?? "none")–\(records.last.map { String($0.sequence) } ?? "none")",
            "Scope: complete loaded app journal, including messages, streamed text, tools, approvals, errors and emitted metadata. Attachment references are included where recorded; file/image/audio bytes are not embedded. Unsent drafts and provider history outside this app journal are excluded. Streamed deltas are retained as separate records to avoid losing content."]
        for event in records {
            let role: String
            switch event.record.kind {
            case .user: role = "You"
            case .message: role = "Assistant"
            case .textDelta: role = "Assistant stream"
            case .toolCall: role = "Tool call"
            case .toolResult: role = "Tool result"
            default: role = event.record.kind.rawValue
            }
            var body = event.record.value["text"].string ?? ""
            let metadata = event.record.value.fields == nil ? event.record.value : event.record.value.removing("text")
            if !metadata.isNullish, metadata.fields?.isEmpty != true {
                let data = try JSONSerialization.data(withJSONObject: metadata.foundation, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                let json = String(decoding: data, as: UTF8.self)
                // A fence longer than any run in the payload keeps even embedded Markdown intact.
                let fence = String(repeating: "`", count: max(3, longestFence(json) + 1))
                body += (body.isEmpty ? "" : "\n\n") + fence + "json\n" + json + "\n" + fence
            }
            parts.append("## \(event.sequence). \(role)\n\nTurn: \(event.turnID) · Provider: \(event.provider.rawValue) · Recorded at: \(event.at) ms\n\n\(body)")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
    private static func longestFence(_ text: String) -> Int {
        var count = 0, longest = 0
        for character in text { count = character == "`" ? count + 1 : 0; longest = max(longest, count) }
        return longest
    }
}
