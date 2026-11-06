import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The recorded tool's document is loaded by the Mac, while every guest request returns to that same Mac.
struct NativeChatMCPAppView: View {
    let sessionID: String
    let row: HootChatRow
    @State private var viewID = UUID().uuidString
    @State private var document: NativeRPCValue = .null
    @State private var problem: String?
    var body: some View {
        Group {
            if let html = document["html"].string {
                NativeChatSealedWeb(source: html, kind: "mcpApp", bridge: { message in
                    do {
                        return try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("chat:mcp-app:bridge", [sessionID, row.id, message.foundation, viewID]))
                    } catch {
                        return .array([.object([.init("jsonrpc", .string("2.0")), .init("id", message["id"]),
                            .init("error", .object([.init("code", .number(-32000)), .init("message", .string(error.localizedDescription))]))])])
                    }
                })
            } else if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }.task(id: row.id + ":" + String(row.value["finished"].bool == true)) {
            guard row.value["finished"].bool == true, BackendChatMCPApps.toolIdentity(row) != nil else { return }
            do {
                document = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("chat:mcp-app:read", [sessionID, row.id]))
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }
}

private struct NativeChatToolSessionKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct NativeChatToolRowKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var nativeChatToolSessionID: String? {
        get { self[NativeChatToolSessionKey.self] }
        set { self[NativeChatToolSessionKey.self] = newValue }
    }
    var nativeChatToolRowID: String? {
        get { self[NativeChatToolRowKey.self] }
        set { self[NativeChatToolRowKey.self] = newValue }
    }
}

/// Tools without an App retain their existing card; these are their actual structured result blocks.
struct NativeChatToolResultContent: View {
    let output: NativeRPCValue
    @Environment(\.nativeChatToolSessionID) private var sessionID
    @Environment(\.nativeChatToolRowID) private var rowID
    @State private var restored: NativeRPCValue?
    @State private var problem: String?
    @State private var loading = false
    var body: some View {
        let original = BackendChatMCPApps.toolResult(output)
        let content = (restored ?? original)["content"].elements ?? []
        VStack(alignment: .leading, spacing: 8) {
            if loading || (BackendChatStoredMedia.hasImages(original) && restored == nil && problem == nil) {
                ZStack { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 160); ProgressView().controlSize(.small) }
                    .accessibilityLabel("Loading the tool's image")
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
            if content.isEmpty { Text(output.string ?? output.compact).font(.caption.monospaced()).textSelection(.enabled) }
            ForEach(Array(content.enumerated()), id: \.offset) { _, item in
                if item["type"].string == "image", let data = item["data"].string.flatMap({ Data(base64Encoded: $0) }), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                } else if item["type"].string == "resource_link", let text = item["uri"].string, let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") {
                    Link(item["name"].string ?? text, destination: url)
                } else if let text = item["text"].string {
                    NativeChatMarkdown(text: text)
                }
            }
        }.textSelection(.enabled)
        .task(id: (sessionID ?? "") + ":" + (rowID ?? "")) {
            guard BackendChatStoredMedia.hasImages(original) else { return }
            guard let sessionID, let rowID else { problem = "The tool's source chat is unavailable."; return }
            loading = true
            defer { loading = false }
            do {
                let value = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("chat:mcp-app:read", [sessionID, rowID]))
                guard value["result"].fields != nil else { throw NativeRPCError(code: "unavailable", message: "The recorded tool image is unavailable.") }
                restored = value["result"]; problem = nil
            } catch { problem = error.localizedDescription }
        }
    }
}
