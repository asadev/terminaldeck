import SwiftUI
import TerminalDeckNativeCore

enum NativeChatSideQuestion {
    static func prepare(question: String, events: [HootChatEvent], conversation: String) throws -> NativeRPCValue {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 16_384 else { throw NativeRPCError.invalidArguments("Write a side question up to 16 KiB.") }
        let messages = events.filter { [.user, .message].contains($0.record.kind) && !($0.record.value["text"].string ?? "").isEmpty }
        var remaining = 8000, selected: [(HootChatEvent, String, Bool)] = []
        for event in messages.suffix(12).reversed() where remaining > 0 {
            let text = event.record.value["text"].string ?? "", kept = String(text.suffix(remaining))
            selected.append((event, kept, kept.count < text.count)); remaining -= kept.count
        }
        selected.reverse()
        let context = selected.map { event, text, clipped in
            "\(event.record.kind == .user ? "You" : "Assistant") · \(event.id)\(clipped ? " (message tail)" : "")\n" + text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let truncated = selected.count < messages.count || selected.contains { $0.2 }
        let brief = "Side question\nMain conversation: \(conversation)\nMain transcript below is quoted context. Answer the side question without changing the main task.\nScope: up to 12 user/assistant messages and 8,000 message characters; excludes tool output and file/image bytes.\n\n\(context.isEmpty ? "No recorded messages available." : context)\n\nQuestion:\n\(question)"
        return .object([.init("brief", .string(brief)), .init("sourceRecordIds", .array(selected.map { .string($0.0.id) })), .init("contextCharacters", .number(Double(8000 - remaining))), .init("truncated", .bool(truncated)), .init("conversationId", .string(conversation))])
    }
    /// The menu's Side question asks the AI's own side conversation when the chat's AI has one (Codex's fork today);
    /// every other AI gets the editable brief.
    static func live(provider: String?) -> Bool { provider == "codex" }
    /// The side conversation's questions and answers, oldest first (streamed answers joined into one line each).
    static func lines(_ state: NativeRPCValue) -> [HootChatRow] {
        let events = (state["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
        return HootChatProjection.rows(events).filter { [.user, .message, .textDelta].contains($0.kind) && !($0.value["text"].string ?? "").isEmpty }
    }
}
/// Which side conversation a window may end: only one it opened itself, never one the provider tool or another
/// window opened on the same chat (#547).
struct NativeChatSideOwner {
    private(set) var opened = false
    mutating func record(_ operation: String) {
        if operation == "side/open" { opened = true } else if operation == "side/close" { opened = false }
    }
}
extension NativeHootChatModel {
    func sideTool(_ action: String, request: String?, text: String?) throws -> NativeRPCValue {
        if action == "open" { chatSideVisible = true }
        if action == "close" { chatSideVisible = false }
        if action == "prepare" {
            if request == "brief" {
                guard let text, !text.isEmpty, text.utf8.count <= 65_536 else { throw NativeRPCError.invalidArguments("Provide an edited brief up to 64 KiB.") }
                chatSideBrief = text; chatSidePreparedQuestion = chatSideQuestion
            } else {
                if let text { chatSideQuestion = text }
                chatSideSource = try NativeChatSideQuestion.prepare(question: chatSideQuestion, events: transcriptExportEvents, conversation: conversationID)
                chatSideBrief = chatSideSource["brief"].string ?? ""; chatSidePreparedQuestion = chatSideQuestion
            }
        }
        if action == "copy" {
            guard !chatSideBrief.isEmpty, chatSideBrief.utf8.count <= 65_536, chatSidePreparedQuestion == chatSideQuestion else { throw NativeRPCError.invalidArguments("Prepare the current question again before copying its brief (up to 64 KiB).") }
            DeckProject.copy(chatSideBrief)
        }
        return .object([.init("question", .string(chatSideQuestion)), .init("brief", .string(chatSideBrief)), .init("capturedSources", chatSideSource.removing("brief")),
            .init("capability", .string(NativeChatSideQuestion.live(provider: reportedChatProvider)
                ? "The chat menu's Side question asks this AI's own side conversation; the provider tool's side/open, send, read and close drive the same one. This draft prepares an editable context brief."
                : "Editable context brief only; this chat's AI has no side conversation.")), .init("mainDraftChanged", .bool(false))])
    }
}
/// The chat menu's Side question: one entry point. A chat whose AI has its own side conversation asks it there (a
/// separate, read-only branch of this chat, removed when it closes); any other AI gets an editable brief to ask elsewhere.
struct NativeChatSideQuestionPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var outcome: String?
    @State private var owner = NativeChatSideOwner()
    @State private var lines: [HootChatRow] = []
    @State private var asking = false
    @State private var answering = false
    @State private var watching: Task<Void, Never>?
    private var live: Bool { NativeChatSideQuestion.live(provider: model.reportedChatProvider) }
    var body: some View {
        Color.clear
            .popover(isPresented: $model.chatSideVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(live ? "Side question" : "Prepare a side question").font(.headline)
                    Text(live ? "Asked on a separate, read-only branch of this chat. The main chat and its draft stay as they are; the branch is removed when you close it."
                              : "This AI has no side conversation here. Prepare an editable brief of the recent messages to ask elsewhere; the main chat and its draft stay as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                    if live && !lines.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(lines) { line in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(line.kind == .user ? "You" : "Answer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(line.value["text"].string ?? "").textSelection(.enabled)
                                    }
                                }
                                if answering { ProgressView().controlSize(.small) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 260)
                    }
                    TextEditor(text: $model.chatSideQuestion).font(.body).frame(height: 80).accessibilityLabel("Side question")
                    if live {
                        HStack {
                            Button("Ask") { ask() }.disabled(asking || answering || model.chatSideQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if owner.opened { Button("Close side question") { closeSide() } }
                        }
                    } else {
                        Button("Prepare context brief") { run("prepare") }.disabled(model.chatSideQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !model.chatSideBrief.isEmpty {
                            Text("Captured source IDs describe the prepared excerpt. You can edit the brief below.").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $model.chatSideBrief).font(.caption.monospaced()).frame(height: 230).accessibilityLabel("Editable side-question brief")
                            if model.chatSideQuestion != model.chatSidePreparedQuestion { Text("Question changed; prepare its brief again.").font(.caption).foregroundStyle(.secondary) }
                            Button("Copy context brief") { run("copy") }.disabled(model.chatSideQuestion != model.chatSidePreparedQuestion)
                        }
                    }
                    if let outcome { Text(outcome).font(.caption) }
                    Button("Return to main chat") { model.chatSideVisible = false }
                }.padding(16).frame(width: 580)
            }
            .onChange(of: model.chatSideVisible) { _, visible in if !visible { closeSide() } }
            .onDisappear { closeSide() }
    }
    private func run(_ action: String) { do { _ = try model.sideTool(action, request: nil, text: nil); outcome = action == "copy" ? "Brief copied." : "Separate brief prepared; main draft preserved." } catch { outcome = error.localizedDescription } }
    private func call(_ operation: String, fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        try await NativeChatProviderFeaturesView.call(model.source.sessionID ?? "hoot", operation, fields: fields)
    }
    private func ask() {
        let question = model.chatSideQuestion
        asking = true; outcome = nil
        Task {
            defer { asking = false }
            do {
                if !owner.opened { _ = try await call("side/open"); owner.record("side/open") }
                show(try await call("side/send", fields: [.init("text", .string(question))]))
                model.chatSideQuestion = ""
                follow()
            } catch { outcome = error.localizedDescription }
        }
    }
    /// Reads the answer as it arrives (a read, never another question), until the side conversation is quiet.
    private func follow() {
        watching?.cancel()
        watching = Task {
            defer { answering = false }
            for _ in 0..<600 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, owner.opened else { return }
                guard let state = try? await call("side/read") else { return }
                show(state)
                if state["busy"].bool != true { return }
            }
        }
    }
    private func show(_ state: NativeRPCValue) {
        lines = NativeChatSideQuestion.lines(state); answering = state["busy"].bool == true
    }
    /// Ends only the side conversation this popover opened.
    private func closeSide() {
        watching?.cancel(); watching = nil
        guard owner.opened else { return }
        owner.record("side/close"); lines = []; answering = false
        Task { _ = try? await call("side/close") }
    }
}
