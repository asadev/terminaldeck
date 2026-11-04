import TerminalDeckNativeCore

/// Process/thread overrides only; never changes the person's Codex config or tool enablement.
/// Verified against the installed 0.166 app-server: `never` also skips MCP tool approvals,
/// whereas `on-request` + the default MCP `auto` policy can ask through elicitation.
public enum BackendCodexApprovalPolicy {
    public static func session(_ value: NativeRPCValue) -> NativeRPCValue {
        let bypass = value["sandbox"].string == "danger-full-access"
        guard bypass || value.has("approvalPolicy") else { return value }
        let approval = bypass ? "never" : value["approvalPolicy"].string ?? "on-request"
        var config = value["config"].fields == nil ? NativeRPCValue.object([]) : value["config"]
        config = config.setting("approval_policy", .string(approval))
        if bypass { config = config.setting("sandbox_mode", .string("danger-full-access")) }
        // Cover every attached server and explicit tool override, preserving disabled tools and fences.
        // Inherited servers are covered by `never` too, even when their own policy says `prompt`.
        if let servers = config["mcp_servers"].fields {
            config = config.setting("mcp_servers", .object(servers.map { server in
                var settings = server.value.setting("default_tools_approval_mode", .string(bypass ? "approve" : "prompt"))
                if let tools = settings["tools"].fields {
                    settings = settings.setting("tools", .object(tools.map {
                        .init($0.key, $0.value.setting("approval_mode", .string(bypass ? "approve" : "prompt")))
                    }))
                }
                return .init(server.key, settings)
            }))
        }
        return value.setting("approvalPolicy", .string(approval)).setting("config", config)
    }
}
