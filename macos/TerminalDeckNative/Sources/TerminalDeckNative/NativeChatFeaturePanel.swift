import SwiftUI
import TerminalDeckNativeCore

enum NativeChatPanel {
    static func action(_ title: String, _ action: String, _ request: String? = nil) -> NativeRPCValue { .object([.init("title", .string(title)), .init("do", .string(action)), .init("request", request.map(NativeRPCValue.string) ?? .null)]) }
    static func row(_ id: String, _ title: String, _ detail: String, _ actions: [NativeRPCValue] = []) -> NativeRPCValue { .object([.init("id", .string(id)), .init("title", .string(title)), .init("detail", .string(detail)), .init("actions", .array(actions))]) }
    static func state(_ title: String, _ notice: String, _ rows: [NativeRPCValue], _ actions: [NativeRPCValue] = []) -> NativeRPCValue { .object([.init("title", .string(title)), .init("notice", .string(notice)), .init("rows", .array(rows)), .init("actions", .array(actions))]) }
}
extension NativeHootChatModel {
    func featurePanel(_ feature: String, _ action: String) {
        if action == "open" { chatFeaturePanels.insert(feature) }
        if action == "close" { chatFeaturePanels.remove(feature) }
    }
}
struct NativeChatFeaturePopover: View {
    @Bindable var model: NativeHootChatModel
    let feature: String
    let title: String
    var body: some View {
        Color.clear
            .popover(isPresented: Binding(get: { model.chatFeaturePanels.contains(feature) }, set: { if !$0 { model.chatFeaturePanels.remove(feature) } })) {
                NativeChatFeaturePanelView(model: model, feature: feature, title: title).padding(16).frame(width: 560)
            }
    }
}
struct NativeChatFeaturePanelView: View {
    let model: NativeHootChatModel
    let feature: String
    let title: String
    @State private var state: NativeRPCValue?
    @State private var problem: String?
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state?["title"].string ?? title).font(.headline)
            if let state {
                Text(state["notice"].string ?? "").font(.caption).foregroundStyle(.secondary)
                actions(state["actions"])
                ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                    if state["rows"].elements?.isEmpty != false { Text("No recorded entries available.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array((state["rows"].elements ?? []).enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row["title"].string ?? "").font(.callout.weight(.semibold)).textSelection(.enabled)
                            Text(row["detail"].string ?? "").font(.caption).textSelection(.enabled)
                            actions(row["actions"])
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } }.frame(maxHeight: 360)
            } else { ProgressView("Reading \(title.lowercased())…") }
            if working { ProgressView("Working…").controlSize(.small) }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Button("Refresh") { run("read") }.disabled(working)
        }
        .task(id: "\(model.transcriptRevision):\(model.chatFeatureRevision):\(model.busy)") { await load() }
    }
    private func actions(_ value: NativeRPCValue) -> some View {
        ForEach(Array((value.elements ?? []).enumerated()), id: \.offset) { _, item in Button(item["title"].string ?? "Open") { run(item["do"].string ?? "read", item["request"].string) }.disabled(working) }
    }
    private func run(_ action: String, _ request: String? = nil) { Task { working = true; defer { working = false }; do { state = try await model.featureTool(feature, action: action, args: .object([.init("request", request.map(NativeRPCValue.string) ?? .null)])); problem = nil } catch { problem = error.localizedDescription } } }
    private func load() async { do { state = try await model.featureTool(feature, action: "read", args: .object([])); problem = nil } catch { problem = error.localizedDescription } }
}
