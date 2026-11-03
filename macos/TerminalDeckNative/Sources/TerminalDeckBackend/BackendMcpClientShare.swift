import Foundation
import TerminalDeckNativeCore

public enum BackendMcpClientShare {
    public static func fileName(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression).replacingOccurrences(of: #"^-+|-+$"#, with: "", options: .regularExpression)
        return (safe.isEmpty ? "mcp-server" : safe) + ".mcpserver.json"
    }
    public static func fileText(_ server: BackendMcpClientConfigured) throws -> String {
        let file = NativeRPCValue.object([
            .init("terminalDeckTool", .number(1)), .init("kind", .string("mcp-server")), .init("name", .string(server.name)), .init("transport", .string(server.transport.rawValue)),
            .init("command", .string(server.transport == .stdio ? server.command : "")), .init("url", .string(server.transport == .stdio ? "" : server.command)),
            .init("env", BackendMcpClientValue.strings(server.envKeys)), .init("note", .string("This is a Terminal Deck tool definition. It holds no secrets: the names under \"env\" are the variables this server needs, and their values are not in this file. Importing it opens the add form with these fields filled in, and nothing is written until you press the button."))
        ])
        return String(decoding: try file.encodedJSON(pretty: true), as: UTF8.self) + "\n"
    }
    public static func read(_ text: String) -> NativeRPCValue {
        guard let raw = try? NativeRPCValue.parseJSON(Data(text.utf8)) else { return .object([.init("ok", .bool(false)), .init("why", .string("that file is not JSON this app can read"))]) }
        func bad(_ why: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("why", .string(why))]) }
        guard raw.fields != nil || raw.elements != nil else { return bad("that file does not hold a tool definition") }
        guard raw["kind"].string == "mcp-server" else { return bad("that file is not an MCP server definition") }
        let name = BackendMcpClientValue.text(raw["name"])
        if name.isEmpty { return bad("that definition has no name in it") }
        let transport = McpAddTransport(rawValue: raw["transport"].string ?? "") ?? .stdio
        let command = BackendMcpClientValue.text(raw["command"]), url = BackendMcpClientValue.text(raw["url"])
        if transport == .stdio && command.isEmpty { return bad("that definition has no command in it") }
        if transport != .stdio && url.isEmpty { return bad("that definition has no URL in it") }
        let env = (raw["env"].elements ?? []).compactMap(\.string).map { $0.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return .object([.init("ok", .bool(true)), .init("draft", .object([.init("name", .string(name)), .init("transport", .string(transport.rawValue)), .init("command", .string(command)), .init("url", .string(url)), .init("env", BackendMcpClientValue.strings(Array(env.prefix(32))))]))])
    }
}
