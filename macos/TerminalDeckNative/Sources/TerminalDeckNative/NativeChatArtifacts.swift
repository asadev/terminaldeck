import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeChatArtifact: Identifiable, Equatable {
    let id: String, title: String, destination: String, recordID: String, kind: String
    var wire: NativeRPCValue { .object([.init("id", .string(id)), .init("title", .string(title)), .init("destination", .string(destination)), .init("recordId", .string(recordID)), .init("kind", .string(kind))]) }
    static func index(_ events: [HootChatEvent]) -> [Self] {
        var result: [Self] = [], seen = Set<String>()
        func walk(_ value: NativeRPCValue, event: HootChatEvent, depth: Int) {
            guard depth < 16 else { return }
            if let fields = value.fields {
                for field in fields {
                    if ["url", "uri", "path", "filePath", "artifactPath"].contains(field.key), let text = field.value.string {
                        let url = text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text)
                        if let url, let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme), url.user == nil, url.password == nil,
                           (scheme == "file" ? url.path.hasPrefix("/") : url.host?.isEmpty == false), seen.insert(url.absoluteString).inserted {
                            let title = value["title"].string ?? value["name"].string ?? (url.lastPathComponent.isEmpty ? url.host ?? "Source" : url.lastPathComponent)
                            result.append(.init(id: event.id + ":" + url.absoluteString, title: title, destination: url.absoluteString, recordID: event.id, kind: scheme == "file" ? "file" : "web"))
                        }
                    }
                    walk(field.value, event: event, depth: depth + 1)
                }
            } else if let array = value.elements { for item in array { walk(item, event: event, depth: depth + 1) } }
            else if let text = value.string, text.utf8.count <= 2_097_152, text.first == "{" || text.first == "[", let decoded = try? NativeRPCValue.parseJSON(Data(text.utf8)) {
                walk(decoded, event: event, depth: depth + 1)
            }
        }
        for event in events where [.toolResult, .message].contains(event.record.kind) { walk(event.record.value, event: event, depth: 0) }
        return result
    }
}
extension NativeHootChatModel {
    func artifactTool(_ action: String, request: String?, query: String? = nil) throws -> NativeRPCValue {
        let entries = chatArtifacts
        if action == "open" {
            if let request {
                guard let entry = entries.first(where: { $0.id == request }), let url = URL(string: entry.destination) else { throw NativeRPCError.invalidArguments("Choose an emitted source or artifact ID from read.") }
                if entry.kind == "file" {
                    guard FileManager.default.fileExists(atPath: url.path) else { throw NativeRPCError(code: "missing-file", message: "This emitted file is no longer present at its recorded path.") }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else if !NSWorkspace.shared.open(url) { throw NativeRPCError(code: "open-failed", message: "The source could not open in the default browser.") }
            } else { chatArtifactsVisible = true }
        }
        if action == "close" { chatArtifactsVisible = false }
        let shown = entries.filter { query?.isEmpty != false || ($0.title + " " + $0.destination).localizedStandardContains(query ?? "") }
        return .object([.init("entries", .array(shown.map(\.wire))), .init("total", .number(Double(entries.count))),
            .init("scope", .string("Structured emitted HTTP(S) links and absolute file paths, including JSON tool output; plain-text tool output remains in the transcript."))])
    }
}
/// The "Links & files" tab of Instructions & sources.
struct NativeChatArtifactsView: View {
    let model: NativeHootChatModel
    @State private var query = ""
    @State private var problem: String?
    var body: some View {
        let entries = model.chatArtifacts.filter { query.isEmpty || ($0.title + " " + $0.destination).localizedStandardContains(query) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Emitted sources and files").font(.headline)
            TextField("Filter sources and files", text: $query)
            Text("\(entries.count) indexed entries · Structured links and absolute file paths only. Full tool output stays in the transcript.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title).font(.callout.weight(.semibold))
                            Text(entry.destination).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                            HStack {
                                Button(entry.kind == "file" ? "Reveal file" : "Open source") { do { _ = try model.artifactTool("open", request: entry.id) } catch { problem = error.localizedDescription } }
                                Button("Recorded event") { do { _ = try model.detailTool("open", query: String(decoding: NativeRPCValue.string(entry.recordID).encodedJSON(), as: UTF8.self)); model.chatArtifactsVisible = false; model.chatSourcesVisible = false } catch { problem = error.localizedDescription } }
                            }
                        }
                    }
                    if entries.isEmpty { Text("No matching structured sources or files were emitted.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 340)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(width: 560)
    }
}
