import SwiftUI
import TerminalDeckNativeCore

enum NativeChatConnections {
    static let destinations = ["mcp", "plugins", "ai-apps"]
    static func state(plugins: NativeRPCValue, apps: NativeRPCValue, tools: [HootComposerTool]) -> NativeRPCValue {
        .object([.init("appPlugins", .array((plugins["plugins"].elements ?? []).map { row in
            .object([.init("name", row["name"]), .init("version", row["version"]), .init("state", row["state"]), .init("enabled", row["enabled"])])
        })), .init("inboundAIApps", .object([.init("connected", apps["internet"]["connected"]), .init("internetOn", apps["internet"]["on"])])),
            .init("chatToolCatalogue", .array(tools.map { .object([.init("name", .string($0.name)), .init("enabled", .bool($0.enabled))]) })),
            .init("providerNativePluginsAndApps", .null), .init("destinations", .array(destinations.map(NativeRPCValue.string)))])
    }
    @MainActor static func open(_ destination: String) throws {
        guard destinations.contains(destination) else { throw NativeRPCError.invalidArguments("Choose mcp, plugins or ai-apps.") }
        if destination == "mcp" { AppModel.shared.select("mcp") }
        else { AppModel.shared.openSettings(section: destination) }
    }
}
extension NativeHootChatModel {
    func connectionTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        if action == "open" {
            if let request { try NativeChatConnections.open(request) } else { chatConnectionsVisible = true }
        }
        if action == "close" { chatConnectionsVisible = false }
        async let plugins = connectionMetadata("plugins:state")
        async let apps = connectionMetadata("ai-apps:state")
        return await NativeChatConnections.state(plugins: plugins, apps: apps, tools: catalogue.tools)
    }
    private func connectionMetadata(_ channel: String) async -> NativeRPCValue {
        (try? NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke(channel))) ?? .null
    }
}
/// App connections, MCP status and the provider's own connections are one job: the server list of ⓘ Session › Connections, a tab each.
struct NativeChatConnectionsPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var state: NativeRPCValue?
    @State private var problem: String?
    var body: some View {
        NativeChatTabbedPanel([("app", "App tools"), ("mcp", "MCP servers"), ("provider", "Provider")], first: model.chatFeaturePanels.contains("mcp") && !model.chatConnectionsVisible ? "mcp" : "app") { tab in
            switch tab {
            case "mcp": NativeChatFeaturePanelView(model: model, feature: "mcp", title: "MCP status").padding(16).frame(width: 560)
            case "provider": NativeChatProviderConnectionsView(sessionID: model.source.sessionID ?? "hoot")
            default: app
            }
        }
    }
    private var app: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools, app plugins and AI app access").font(.headline)
            Text("These are Terminal Deck's own integrations. The provider's own plugins and apps are in the Provider tab.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("MCP connections") { open("mcp") }
                Button("App plugins") { open("plugins") }
                Button("AI app access") { open("ai-apps") }
            }
            if let state {
                let connected = state["inboundAIApps"]["connected"].bool
                Text("AI apps reaching this Mac: \(connected.map { $0 ? "Connected" : "Not connected" } ?? "Not reported")").font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array((state["appPlugins"].elements ?? []).enumerated()), id: \.offset) { _, plugin in
                            Text("\(plugin["name"].string ?? "Plugin") · \(plugin["state"].string ?? "State not reported")").font(.callout)
                        }
                        Text("Chat tool configuration").font(.subheadline)
                        ForEach(model.catalogue.tools) { tool in Text("\(tool.name) · \(tool.enabled ? "Enabled" : "Disabled")").font(.caption) }
                        Text("Enabled is a configuration state. Open MCP connections for actual connection health and approved connection actions.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
            } else { ProgressView("Reading integration status…") }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Button("Refresh status") { load() }
        }.padding(16).frame(width: 530).task { load() }
    }
    private func close() { model.chatConnectionsVisible = false; model.chatFeaturePanels.remove("mcp") }
    private func open(_ destination: String) { do { try NativeChatConnections.open(destination); close() } catch { problem = error.localizedDescription } }
    private func load() { Task { do { state = try await model.connectionTool("read", request: nil); problem = nil } catch { problem = error.localizedDescription } } }
}
