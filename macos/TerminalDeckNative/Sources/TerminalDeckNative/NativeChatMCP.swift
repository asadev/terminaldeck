import Foundation
import TerminalDeckNativeCore

enum NativeChatMCP {
    static func selected(_ id: String?, in rows: [NativeRPCValue]) throws -> NativeRPCValue {
        let matches = rows.filter { $0["id"].string == id }
        guard matches.count == 1, let row = matches.first, row["scope"].string != "local", row["unsupported"].isNullish, row["enabled"].bool != false else { throw NativeRPCError.invalidArguments("Choose one enabled, supported app MCP connection in this Chat project. Duplicate names and local-only configurations need the MCP manager.") }
        return row
    }
    static func confirmSource(_ status: NativeRPCValue, expected: NativeRPCValue) throws {
        if let actual = status["source"].string, actual != expected["source"].string { throw NativeRPCError.invalidArguments("A different project's connection answered. Open MCP management; no provider reconnect is inferred.") }
    }
    static func state(app: [NativeRPCValue], provider: NativeRPCValue) -> NativeRPCValue {
        let rows = app.compactMap { row -> NativeRPCValue? in
            guard let id = row["id"].string else { return nil }
            let status = row["enabled"].bool == false ? "Off" : row["state"].string ?? "Not reported"
            var actions = [NativeChatPanel.action("Open MCP management", "manage")]
            if (try? selected(id, in: app)) != nil { actions.insert(NativeChatPanel.action("Test app connection", "test", id), at: 0) }
            return NativeChatPanel.row(id, row["name"].string ?? id, "App client: \(status)\nSource: \(row["source"].string ?? "Not reported")\n\(row["unsupported"].string ?? row["disabledReason"].string ?? row["error"].string ?? "")", actions)
        }
        return NativeChatPanel.state("MCP connections for this Chat project", "These connections belong to Terminal Deck's app client. They do not prove that this provider's session connected. Testing uses the existing project-scoped inventory operation. Use Provider controls for live provider-session status, sign-in and supported reconnect or configuration reload.", rows, [NativeChatPanel.action("Open MCP management", "manage")]).setting("providerSessionConnections", provider.isNullish ? .null : .array((provider.elements ?? []).map { .object([.init("name", $0["name"]), .init("status", $0["status"])]) }))
    }
}
extension NativeHootChatModel {
    func mcpFeatureTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        featurePanel("mcp", action)
        if action == "manage" { if !fixtureMode { AppModel.shared.select("mcp") }; return NativeChatPanel.state("MCP management", "Opened the existing MCP owner.", []) }
        guard !fixtureMode else { return NativeChatMCP.state(app: [], provider: .null) }
        let path = try await projectReferenceRoot()
        let raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("mcp:list", [path]))
        var app = raw.elements ?? []
        if action == "test" {
            let chosen = try NativeChatMCP.selected(request, in: app), id = chosen["id"].string ?? ""
            let inventory = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("mcp:inventory", [id, path]))
            try NativeChatMCP.confirmSource(inventory["status"], expected: chosen)
            app = app.map { $0["id"].string == id ? $0.merging(inventory["status"]) : $0 }
        }
        return NativeChatMCP.state(app: app, provider: chatProviderMCPServers)
    }
    /// The MCP servers the provider's own session last reported (also ⓘ Session's "n to reconnect").
    var chatProviderMCPServers: NativeRPCValue {
        transcriptExportEvents.reversed().first { $0.record.value["mcpServers"].elements != nil }?.record.value["mcpServers"] ?? .null
    }
}
