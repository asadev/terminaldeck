import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func searchPrompts(_ query: String) -> [HootChatRow] {
        rows.filter { $0.kind == .user && ($0.value["context"]["source"]["kind"].string ?? "").isEmpty &&
            !($0.value["text"].string ?? "").isEmpty && (query.isEmpty || ($0.value["text"].string ?? "").localizedStandardContains(query)) }
    }
    func promptSearchState(_ query: String) -> NativeRPCValue {
        promptRecallState.setting("matches", .array(searchPrompts(query).map { .object([.init("id", .string($0.id)), .init("text", $0.value["text"])]) }))
            .setting("conversationId", .string(conversationID))
    }
    func insertPrompt(_ id: String) throws {
        guard let row = searchPrompts("").first(where: { $0.id == id }), let text = row.value["text"].string else {
            throw NativeRPCError.invalidArguments("Choose a prompt from this conversation's history.")
        }
        try setDraftText(composerDraft.text.isEmpty ? text : composerDraft.text + "\n\n" + text)
    }
}

/// The search field at the top of Past chats (Asad, 20 Oct 2026: it does what "Find a past prompt" did).
struct NativeChatPromptSearchView: View {
    let model: NativeHootChatModel
    @State private var query = ""
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Find a past prompt in this chat", text: $query)
                .accessibilityLabel("Find a past prompt")
            if !query.isEmpty { ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.searchPrompts(query).reversed()) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.value["text"].string ?? "").lineLimit(6).textSelection(.enabled)
                            Button("Insert into draft") { do { try model.insertPrompt(row.id); problem = nil } catch { problem = error.localizedDescription } }
                                .disabled(model.readOnly || model.loading || model.changingConversation)
                        }
                    }
                    if model.searchPrompts(query).isEmpty { Text("No matching prompts").foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 80, maxHeight: 220) }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
    }
}
