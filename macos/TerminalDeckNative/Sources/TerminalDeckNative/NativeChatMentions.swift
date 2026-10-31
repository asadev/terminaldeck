import SwiftUI
import TerminalDeckNativeCore

enum NativeChatMentions {
    static func receipts(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        events.filter { $0.record.kind == .user }.compactMap { event in
            let context = event.record.value["context"], mentions = context["mentions"].elements ?? []
            guard !mentions.isEmpty else { return nil }
            return NativeChatPanel.row(event.id, "Recorded context · \(event.id)", mentions.map { "\($0["kind"].string ?? "context"): \($0["name"].string ?? $0["id"].string ?? "")" }.joined(separator: "\n") + "\nRecorded with this user message. Separate recipient delivery and provider use are not inferred.")
        }
    }
}
extension NativeHootChatModel {
    func mentionsTool(_ action: String, request: String?) throws -> NativeRPCValue {
        featurePanel("mentions", action)
        if action == "insert" {
            guard !readOnly, !loading, !changingConversation, let mention = catalogue.mentions.first(where: { $0.marker == request }) else { throw NativeRPCError.invalidArguments("Choose an available context marker from this editable Chat.") }
            composerDraft.insert(mention)
        }
        let rows = catalogue.mentions.map { NativeChatPanel.row($0.marker, $0.name, "\($0.kind.rawValue) · \($0.project)\nID: \($0.id)", [NativeChatPanel.action("Add context mention to draft", "insert", $0.marker)]) }
        return NativeChatPanel.state("Context mentions and recorded receipts", "Mentions carry source IDs/metadata, not permission or automatic delegation. File/folder references use the existing bounded content reader. Hoot's routing receipts stay in its conversation; ordinary Chat does not route a message to each mentioned agent/session.", rows + NativeChatMentions.receipts(transcriptExportEvents))
    }
}
