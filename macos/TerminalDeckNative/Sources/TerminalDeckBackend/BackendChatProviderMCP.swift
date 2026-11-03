import Foundation
import TerminalDeckNativeCore

/// Per-Chat provider MCP state. This never reads the app MCP client's separate connection state,
/// writes configuration, restarts a CLI, or treats a config reload as a confirmed reconnection.
public enum BackendChatProviderMCP {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["mcp/status", "mcp/details", "mcp/auth", "mcp/reconnect"]
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }
    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, request: Request) async throws -> NativeRPCValue {
        try await execute(operation: operation, arguments: arguments, provider: provider,
            conversation: conversation, request: { method, params in
                do { return try await request(method, params) }
                catch { throw NativeRPCError(code: (error as? NativeRPCError)?.code ?? "provider-mcp-failed", message: scrub(error.localizedDescription)) }
            })
    }
    private static func execute(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                                conversation: String?, request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation) else { throw invalid("Choose a supported provider MCP action.") }
        guard provider != .gemini else {
            return unavailable(provider, "Gemini's current structured Chat protocol does not expose session MCP status, OAuth or reconnect controls.")
        }
        if provider == .codex, conversation?.isEmpty != false {
            return unavailable(provider, "This Codex conversation is not ready. Per-Chat MCP state needs its confirmed thread ID.")
        }
        let name: String?
        if operation == "mcp/status" { name = nil }
        else { name = try selectedName(arguments) }
        let status = try await inventory(provider: provider, conversation: conversation, name: name,
                                         arguments: arguments, request: request)
        if operation == "mcp/status" || operation == "mcp/details" { return status }
        guard let name, let row = status["servers"].elements?.first(where: { $0["name"].string == name }) else {
            throw invalid("Choose a server reported by this provider's current Chat connection.")
        }
        if operation == "mcp/auth" {
            guard row["canAuth"].bool == true else {
                return status.setting("availability", .string("unavailable"))
                    .setting("reason", .string("The provider has not exposed an OAuth sign-in action for this server. Read its connection error or open MCP management."))
            }
            let reply: NativeRPCValue
            if provider == .codex {
                reply = try await request("mcpServer/oauth/login", object([("threadId", .string(conversation!)), ("name", .string(name))]))
            } else {
                reply = try await request("mcp_authenticate", object([("serverName", .string(name))]))
            }
            var result = status.setting("action", .string("authenticate")).setting("requested", .bool(true))
                .setting("authenticated", .bool(false))
            if let url = authURL(reply["authorizationUrl"].string ?? reply["authUrl"].string) {
                result = result.setting("authorizationUrl", .string(url)).setting("requiresUserAction", .bool(true))
            } else if reply["requiresUserAction"].bool == true {
                result = result.setting("availability", .string("unavailable"))
                    .setting("reason", .string("The provider requested sign-in but returned no usable authorization URL."))
            } else {
                result = result.setting("reason", .string("The provider accepted the authentication request. Refresh status to confirm the connection."))
            }
            if let callback = reply["callbackExpected"].bool { result = result.setting("callbackExpected", .bool(callback)) }
            return result
        }
        if provider == .codex {
            // The installed API has no per-server reconnect. The opt-in alternative is a config
            // refresh on this provider process, with no claim about the current thread's connection.
            guard arguments["mode"].string == "reloadConfiguration" else {
                return status.setting("availability", .string("unavailable"))
                    .setting("reason", .string("Codex exposes a provider MCP configuration reload, not a per-server reconnect. This does not confirm that an existing thread reconnected."))
                    .setting("actionLabel", .string("Reload provider MCP configuration"))
                    .setting("requiredMode", .string("reloadConfiguration"))
                    .setting("reconnected", .bool(false))
            }
            _ = try await request("config/mcpServer/reload", .null)
            return status.setting("action", .string("reloadConfiguration")).setting("requested", .bool(true))
                .setting("reconnected", .bool(false)).setting("statusIsBeforeAction", .bool(true))
                .setting("reason", .string("Codex accepted a provider-process MCP configuration reload. Refresh this Chat's status to see its actual connection state."))
        }
        guard row["canReconnect"].bool == true else {
            return status.setting("availability", .string("unavailable"))
                .setting("reason", .string("This provider server is disabled or host-managed and does not expose a reconnect action here."))
        }
        _ = try await request("mcp_reconnect", object([("serverName", .string(name))]))
        do {
            let updated = try await inventory(provider: provider, conversation: conversation, name: name, arguments: .object([]), request: request)
            let connected = updated["servers"].elements?.first?["status"].string == "connected"
            return updated.setting("action", .string("reconnect")).setting("requested", .bool(true))
                .setting("reconnected", .bool(connected))
        } catch {
            return status.setting("action", .string("reconnect")).setting("requested", .bool(true))
                .setting("reconnected", .bool(false)).setting("statusIsBeforeAction", .bool(true))
                .setting("reason", .string("The provider accepted reconnect, but its resulting state could not be read: " + scrub(error.localizedDescription)))
        }
    }
    private static func inventory(provider: HootChatProvider, conversation: String?, name: String?, arguments: NativeRPCValue, request: Request) async throws -> NativeRPCValue {
        let reply: NativeRPCValue
        if provider == .codex {
            guard let conversation, !conversation.isEmpty else { throw invalid("A confirmed Codex thread is required.") }
            var params = object([("threadId", .string(conversation)), ("detail", .string("full")), ("limit", .number(100))])
            if let name { params = params.setting("serverName", .string(name)) }
            if let cursor = arguments["cursor"].string {
                guard cursor.utf8.count <= 4096 else { throw invalid("Provider page cursor is too large.") }
                params = params.setting("cursor", .string(cursor))
            }
            reply = try await request("mcpServerStatus/list", params)
        } else { reply = try await request("mcp_status", .object([])) }
        guard let rows = (provider == .codex ? reply["data"] : reply["mcpServers"]).elements else {
            throw NativeRPCError(code: "provider-mcp-unavailable", message: "The provider returned no usable per-Chat MCP inventory.")
        }
        let chosen = name.map { selected in rows.filter { $0["name"].string == selected } } ?? rows
        if name != nil, chosen.count != 1 { throw invalid("The named server is absent or ambiguous in this provider's Chat inventory.") }
        let nextCursor: NativeRPCValue
        if provider == .codex, let cursor = reply["nextCursor"].string, cursor.utf8.count <= 4096 { nextCursor = .string(cursor) }
        else { nextCursor = .null }
        return object([("provider", .string(provider.rawValue)), ("scope", .string("provider-session")),
            ("conversationId", conversation.map(NativeRPCValue.string) ?? .null), ("availability", .string("available")),
            ("servers", .array(chosen.prefix(100).map { normalize($0, provider: provider) })),
            ("nextCursor", nextCursor),
            ("reconnectLabel", .string(provider == .codex ? "Reload provider MCP configuration" : "Reconnect provider server")),
        ])
    }
    private static func normalize(_ row: NativeRPCValue, provider: HootChatProvider) -> NativeRPCValue {
        let name = row["name"].string ?? ""
        let raw = provider == .codex ? row["runtimeStatus"].string : row["status"].string
        let status: String
        switch raw {
        case "connected": status = "connected"
        case "authenticationRequired", "needs-auth": status = "needs-auth"
        case "notStarted", "starting", "pending": status = "pending"
        case "failed": status = "failed"
        case "disabled": status = "disabled"
        case "cancelled": status = "cancelled"
        default: status = "not-reported"
        }
        let transport = row["config"]["type"].string
        let origin = endpointOrigin(provider == .codex ? row["httpOrigin"].string : row["config"]["url"].string)
        let auth = row["authStatus"].string
        let canAuth = provider == .codex
            ? status != "disabled" && (auth == "notLoggedIn" || auth == "oAuth" || status == "needs-auth")
            : status != "disabled" && row["source"].string != "sdk" && (status == "needs-auth" || ["http", "sse", "claudeai-proxy"].contains(transport ?? ""))
        let canReconnect = provider == .claude && status != "disabled" && row["source"].string != "sdk"
        let tools: [NativeRPCValue]
        if provider == .codex {
            tools = (row["tools"].fields ?? []).prefix(512).map { field in tool(field.value, fallback: field.key) }
        } else { tools = (row["tools"].elements ?? []).prefix(512).map { tool($0) } }
        let toolCount = provider == .codex ? (row["tools"].fields?.count ?? 0) : (row["tools"].elements?.count ?? 0)
        var result = object([
            ("id", .string(name)), ("name", .string(name)), ("status", .string(status)),
            ("providerStatus", raw.map(NativeRPCValue.string) ?? .null), ("authStatus", auth.map(NativeRPCValue.string) ?? .null),
            ("source", row["source"].string.map { .string(scrub($0)) } ?? .null),
            ("configScope", row["scope"].string.map { .string(scrub($0)) } ?? .null),
            ("transportType", transport.map(NativeRPCValue.string) ?? (origin == nil ? .null : .string("http"))),
            ("origin", origin.map(NativeRPCValue.string) ?? .null),
            ("tools", .array(tools)), ("toolCount", .number(Double(toolCount))), ("toolsTruncated", .bool(toolCount > tools.count)),
            ("resourceCount", .number(Double(row["resources"].elements?.count ?? 0))),
            ("resourceTemplateCount", .number(Double(row["resourceTemplates"].elements?.count ?? 0))),
            ("pluginId", scalar(row["pluginId"])) ,
            ("canAuth", .bool(canAuth)), ("canReconnect", .bool(canReconnect)),
            ("canReloadConfiguration", .bool(provider == .codex)),
            ("reconnectLabel", .string(provider == .codex ? "Reload provider MCP configuration" : "Reconnect provider server")),
        ])
        let error = provider == .codex ? row["toolsError"].string : row["error"].string
        if let error { result = result.setting("error", .string(scrub(error))) }
        if let code = row["error_code"].string { result = result.setting("errorCode", .string(scrub(code))) }
        if row["serverInfo"].fields != nil {
            result = result.setting("serverInfo", object([("name", scalar(row["serverInfo"]["name"])),
                ("version", scalar(row["serverInfo"]["version"])), ("title", scalar(row["serverInfo"]["title"])),
                ("description", scalar(row["serverInfo"]["description"]))]))
        }
        return result
    }
    private static func tool(_ value: NativeRPCValue, fallback: String = "") -> NativeRPCValue {
        object([("name", scalar(value["name"].isNullish ? .string(fallback) : value["name"])),
                ("title", scalar(value["title"])), ("description", scalar(value["description"]))])
    }
    private static func selectedName(_ arguments: NativeRPCValue) throws -> String {
        guard let value = arguments["name"].string ?? arguments["id"].string, !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid("Choose an exact server name from this Chat's provider inventory.") }
        return value
    }
    private static func scalar(_ value: NativeRPCValue) -> NativeRPCValue { value.string.map { .string(scrub($0)) } ?? .null }
    private static func endpointOrigin(_ value: String?) -> String? {
        guard let value, var url = URLComponents(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        url.user = nil; url.password = nil; url.path = ""; url.query = nil; url.fragment = nil
        return url.string
    }
    private static func authURL(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 16_384, let url = URLComponents(string: value),
              let scheme = url.scheme?.lowercased(), url.host != nil, url.user == nil, url.password == nil,
              scheme == "https" || scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") else { return nil }
        return value
    }
    /// Connection errors can echo configured URLs or credential fields. Keep actionable prose,
    /// while stripping endpoint paths/queries and common secret assignments before UI/tool output.
    private static func scrub(_ value: String) -> String {
        var result = String(value.prefix(16_384))
        result = result.replacingOccurrences(of: #"(?i)\bauthorization[\"']?\s*[:=]\s*[\"']?(?:bearer|basic)\s+[^\s\"',;]+"#, with: "authorization=[redacted]", options: .regularExpression)
        let secret = #"(?i)\b(authorization|bearer|access[_-]?token|refresh[_-]?token|api[_-]?key|client[_-]?secret|password)[\"']?\s*[:= ]\s*[\"']?[^\s\"',;]+"#
        result = result.replacingOccurrences(of: secret, with: "$1=[redacted]", options: .regularExpression)
        if let expression = try? NSRegularExpression(pattern: #"https?://[^\s\"'<>]+"#, options: [.caseInsensitive]) {
            for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: endpointOrigin(String(result[range])) ?? "[endpoint]")
            }
        }
        return result
    }
    private static func unavailable(_ provider: HootChatProvider, _ reason: String) -> NativeRPCValue {
        object([("provider", .string(provider.rawValue)), ("scope", .string("provider-session")),
                ("availability", .string("unavailable")), ("reason", .string(reason)), ("servers", .array([]))])
    }
    private static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }
}
