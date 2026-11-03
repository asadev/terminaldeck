import SwiftUI
import TerminalDeckNativeCore

struct NativeChatDiagnostic: Identifiable {
    let id: String, recordID: String, kind: String, text: String
    var wire: NativeRPCValue { .object([.init("id", .string(id)), .init("recordId", .string(recordID)), .init("kind", .string(kind)), .init("text", .string(text))]) }
}
enum NativeChatDiagnostics {
    static let destinations = ["advanced", "account", "connections"]
    static func records(_ events: [HootChatEvent]) -> [NativeChatDiagnostic] {
        events.flatMap { event -> [NativeChatDiagnostic] in
            let value = event.record.value
            var records: [(String, String)] = []
            if event.record.kind == .error { records.append(("error", value["text"].string ?? value["message"].string ?? value["error"]["message"].string ?? "Provider error (no message reported)")) }
            if [.session, .toolResult, .completed, .interrupted].contains(event.record.kind) {
                let warnings = (value["warnings"].elements ?? []) + (value["warning"].isNullish ? [] : [value["warning"]])
                records += warnings.compactMap { item in (item.string ?? item["message"].string ?? item["text"].string).map { ("warning", $0) } }
                if event.record.kind == .interrupted, let reason = value["stopReason"].string ?? value["reason"].string { records.append(("stopped", reason)) }
            }
            return records.enumerated().map { .init(id: event.id + ":\($0.offset)", recordID: event.id, kind: $0.element.0, text: $0.element.1) }
        }
    }
}
extension NativeHootChatModel {
    func diagnosticTool(_ action: String, request: String?, query: String? = nil) throws -> NativeRPCValue {
        if action == "open" {
            if let request {
                guard NativeChatDiagnostics.destinations.contains(request) else { throw NativeRPCError.invalidArguments("Choose advanced, account or connections.") }
                if request == "advanced" { AppModel.shared.openSettings(section: "advanced") }
                if request == "account" { chatAccountVisible = true }
                if request == "connections" { chatConnectionsVisible = true }
            } else { chatDiagnosticsVisible = true }
        }
        if action == "close" { chatDiagnosticsVisible = false }
        var records = chatDiagnostics
        if let problem { records.append(.init(id: "app-problem", recordID: "", kind: "app", text: problem)) }
        let shown = records.filter { query?.isEmpty != false || $0.text.localizedStandardContains(query ?? "") }
        let brief = "Chat diagnostic brief\nSession: \(source.sessionID ?? "hoot")\nConversation: \(conversationID)\nProvider: \(reportedChatProvider ?? "not reported")\nFilter: \(query ?? "none")\nReported items: \(shown.count) of \(records.count)\n\n" + shown.map { "[\($0.kind)] \($0.text)\nRecord: \($0.recordID)" }.joined(separator: "\n\n")
        if action == "copy" { DeckProject.copy(brief) }
        return .object([.init("records", .array(shown.map(\.wire))), .init("total", .number(Double(records.count))), .init("brief", .string(brief)), .init("destinations", .array(NativeChatDiagnostics.destinations.map(NativeRPCValue.string)))])
    }
}
struct NativeChatDiagnosticsPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var query = ""
    @State private var outcome: String?
    var body: some View {
        let state = try? model.diagnosticTool("read", request: nil, query: query)
        VStack(alignment: .leading, spacing: 12) {
            Text("This chat's diagnostics").font(.headline)
            TextField("Filter reported warnings and errors", text: $query)
            HStack {
                Button("Advanced & log folder") { open("advanced") }
                Button("Account status") { open("account") }
                Button("MCP connections") { do { try NativeChatConnections.open("mcp"); model.chatDiagnosticsVisible = false } catch { outcome = error.localizedDescription } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array((state?["records"].elements ?? []).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item["kind"].string ?? "Reported item").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(item["text"].string ?? "").font(.callout).textSelection(.enabled)
                        }
                    }
                    if state?["records"].elements?.isEmpty == true { Text("No matching warnings or errors reported.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            Button("Copy diagnostic brief for feedback") { do { _ = try model.diagnosticTool("copy", request: nil, query: query); outcome = "Chat diagnostic brief copied." } catch { outcome = error.localizedDescription } }
            Text("The brief contains this chat's reported items and identity. Advanced owns app logs and support-bundle collection.").font(.caption).foregroundStyle(.secondary)
            if let outcome { Text(outcome).font(.caption) }
        }.padding(16).frame(width: 560)
    }
    private func open(_ destination: String) { do { _ = try model.diagnosticTool("open", request: destination); model.chatDiagnosticsVisible = false } catch { outcome = error.localizedDescription } }
}
