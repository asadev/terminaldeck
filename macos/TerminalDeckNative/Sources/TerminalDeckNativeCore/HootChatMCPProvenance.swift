import Foundation

/// Called only for the provider's typed item envelope, never for tool arguments or results.
public enum HootChatMCPProvenance {
    public static func record(_ item: NativeRPCValue) -> NativeRPCValue {
        let typedMCP = ["mcpToolCall", "mcp_tool_call"].contains(item["type"].string ?? "")
        let geminiCall = item["type"].string == "tool_use" || ["tool_call", "tool_call_update"].contains(item["sessionUpdate"].string ?? "")
        guard typedMCP || geminiCall else { return .null }
        if geminiCall, item["server"].isNullish, item["serverName"].isNullish { return .null }
        let servers = Set([item["server"].string, item["serverName"].string].compactMap { $0 })
        let tools = Set([item["tool"].string, item["toolName"].string].compactMap { $0 })
        guard servers.count == 1, tools.count == 1,
              let server = servers.first, !server.isEmpty, let tool = tools.first, !tool.isEmpty else {
            return .object([.init("invalid", .bool(true))])
        }
        return .object([.init("server", .string(server)), .init("tool", .string(tool))])
    }
}
