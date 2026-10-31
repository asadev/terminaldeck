import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func transcriptExport(copy: Bool = false) throws -> NativeRPCValue {
        guard transcriptExportReady else { throw NativeRPCError(code: "history-loading", message: "Wait for the full recorded conversation to load before exporting.") }
        let text = try ChatTranscriptExport.markdown(events: transcriptExportEvents, session: source.sessionID ?? "hoot", conversation: conversationID)
        if copy { DeckProject.copy(text) }
        return .object([.init("format", .string("markdown")), .init("text", .string(text)), .init("copied", .bool(copy)),
            .init("conversationId", .string(conversationID)), .init("records", .number(Double(transcriptExportEvents.count))),
            .init("scope", .string("complete app journal; attachment references only; excludes binary files and unsent drafts"))])
    }
}
struct NativeChatExportView: View {
    let model: NativeHootChatModel
    @State private var outcome: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export conversation").font(.headline)
            Text("All recorded messages, streamed text, tools and emitted metadata. Includes attachment references; file and image bytes stay outside the export. Unsent drafts are excluded.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Copy complete recorded transcript") {
                do { _ = try model.transcriptExport(copy: true); outcome = "Markdown copied." } catch { outcome = error.localizedDescription }
            }.disabled(!model.transcriptExportReady)
            if let outcome { Text(outcome).font(.caption).textSelection(.enabled) }
        }.padding(16).frame(width: 380)
    }
}
