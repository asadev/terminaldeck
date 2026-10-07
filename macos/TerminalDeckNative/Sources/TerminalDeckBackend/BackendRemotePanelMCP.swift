import Foundation
import TerminalDeckNativeCore

/// Keys cross the wire; existing environment values stay in the native MCP
/// configuration service. One supplied pool serves the local and remote UI.
public struct BackendRemotePanelMCPServer: Sendable {
    public let id: String, name: String, scope: String, transport: String, commandLine: String, url: String
    public let envKeys: [String]
    public let enabled: Bool
    public let disabledReason: String?
    public let unsupported: String?
    public init(id: String, name: String, scope: String, transport: String, commandLine: String = "", url: String = "", envKeys: [String] = [], enabled: Bool, disabledReason: String? = nil, unsupported: String? = nil) {
        self.id = id; self.name = name; self.scope = scope; self.transport = transport; self.commandLine = commandLine
        self.url = url; self.envKeys = envKeys; self.enabled = enabled; self.disabledReason = disabledReason; self.unsupported = unsupported
    }
}
public enum BackendRemotePanelMCP {
    public struct Services: Sendable {
        public let list: @Sendable (String, NativeRPCContext) async throws -> [BackendRemotePanelMCPServer]
        public let add: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)?
        public let edit: (@Sendable (BackendRemotePanelMCPServer, NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)?
        public let remove: (@Sendable (BackendRemotePanelMCPServer, String, NativeRPCContext) async throws -> NativeRPCValue)?
        public let status: (@Sendable (String) async -> NativeRPCValue?)?
        public let connect: (@Sendable (BackendRemotePanelMCPServer, NativeRPCContext) async throws -> NativeRPCValue)?
        public let disconnect: (@Sendable (String, NativeRPCContext) async throws -> Void)?
        public init(list: @escaping @Sendable (String, NativeRPCContext) async throws -> [BackendRemotePanelMCPServer],
                    add: (@Sendable (NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)? = nil,
                    edit: (@Sendable (BackendRemotePanelMCPServer, NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue)? = nil,
                    remove: (@Sendable (BackendRemotePanelMCPServer, String, NativeRPCContext) async throws -> NativeRPCValue)? = nil,
                    status: (@Sendable (String) async -> NativeRPCValue?)? = nil,
                    connect: (@Sendable (BackendRemotePanelMCPServer, NativeRPCContext) async throws -> NativeRPCValue)? = nil,
                    disconnect: (@Sendable (String, NativeRPCContext) async throws -> Void)? = nil) {
            self.list = list; self.add = add; self.edit = edit; self.remove = remove; self.status = status; self.connect = connect; self.disconnect = disconnect
        }
    }
    public static func provider(_ services: Services) -> BackendRemotePanelProvider {
        let read: @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> NativeRPCValue = { request, context in
            let all: [BackendRemotePanelMCPServer]
            do { all = try await services.list(request.path, context) } catch {
                // panels/mcp.ts:423: a read that fails is still a screen, and it still offers Add.
                var failed = NativeRPCValue.object([.init("path", .string(request.path)), .init("note", .string("The MCP configuration for \(request.path) could not be read. \(error.localizedDescription)")), .init("rows", .array([]))])
                if services.add != nil { failed = failed.setting("actions", .array([action("add", "Add a server").setting("fields", .array(form(name: "", command: "", url: "", scope: "user", keys: [], stdio: true)))])) }
                return failed
            }
            let query = (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let scope = ["user", "project", "local"].contains(request.scope ?? "") ? request.scope : nil
            let shown = all.filter { (scope == nil || $0.scope == scope) && (query.isEmpty || $0.name.lowercased().contains(query) || ($0.transport == "stdio" ? $0.commandLine : $0.url).lowercased().contains(query)) }
            var rows: [NativeRPCValue] = []
            for server in shown.prefix(200) {
                let live = await services.status?(server.id), state = live?["state"].string
                var row = NativeRPCValue.object([.init("title", .string(server.name)), .init("detail", .string(live?["error"].string ?? server.disabledReason ?? (server.transport == "stdio" ? server.commandLine : server.url))), .init("value", .string(server.scope + " · " + server.transport)), .init("id", .string(server.id))])
                if state == "ready" { row = row.setting("status", .string("ok")) }
                else if state == "failed" { row = row.setting("status", .string("bad")) }
                else if !server.enabled || services.status != nil { row = row.setting("status", .string("warn")) }
                var actions: [NativeRPCValue] = []
                if server.unsupported == nil {
                    if state == "ready" || state == "connecting" { if services.disconnect != nil { actions.append(action("disconnect", "Disconnect")) } }
                    else if services.connect != nil { actions.append(action("connect", "Connect")) }
                }
                if services.edit != nil { actions.append(action("edit", "Edit").setting("fields", .array(form(name: server.name, command: server.transport == "stdio" ? server.commandLine : "", url: server.transport == "stdio" ? "" : server.url, scope: server.scope, keys: server.transport == "stdio" ? server.envKeys : [], stdio: server.transport == "stdio")))) }
                if services.remove != nil { actions.append(action("remove", "Remove").setting("kind", .string("destructive")).setting("confirm", .string(server.scope == "project" ? "\(server.name) comes out of .mcp.json, which is committed — everyone on this project loses it." : "\(server.name) comes out of your configuration. Anything it was carrying goes with it."))) }
                if !actions.isEmpty { row = row.setting("actions", .array(actions)) }; rows.append(row)
            }
            var value = NativeRPCValue.object([.init("path", .string(request.path)), .init("rows", .array(rows))])
            if services.add != nil { value = value.setting("actions", .array([action("add", "Add a server").setting("fields", .array(form(name: "", command: "", url: "", scope: scope ?? "user", keys: [], stdio: true)))])) }
            if !all.isEmpty { value = value.setting("scopes", .array((["all"] + ["user", "project", "local"]).map { .object([.init("id", .string($0)), .init("label", .string($0 == "all" ? "All" : $0)), .init("on", .bool($0 == (scope ?? "all")))]) })) }
            if all.isEmpty { value = value.setting("note", .string("No MCP servers are configured for \(request.path).")) }
            else if rows.isEmpty { value = value.setting("note", .string(query.isEmpty ? "Nothing here is saved at \(scope ?? "this") scope." : "No configured server matches “\(request.query ?? "")”.")) }
            return value
        }
        return .init(read: read, act: { request, context in
            var notice: String
            do {
                let command = (request.fields["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), url = (request.fields["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let server = try await services.list(request.panel.path, context).first { $0.id == request.id }
                // panels/mcp.ts:547: every action but add is re-resolved against the configuration as it is now.
                if request.action != "add", server == nil { throw NativeRPCError(code: "mcp-panel-gone", message: "That server is not in this configuration any more.") }
                switch request.action {
                case "add", "edit":
                    guard !command.isEmpty || !url.isEmpty else { throw NativeRPCError.invalidArguments("Give the command that starts the server, or its URL.") }
                    let scope = request.fields["scope"] ?? "user"
                    guard ["user", "project", "local"].contains(scope) else { throw NativeRPCError.invalidArguments("That is not an MCP configuration scope") }
                    let extras = request.fields.keys.filter { $0.range(of: #"^env\.[0-9]+$"#, options: .regularExpression) != nil }.sorted { Int($0.dropFirst(4))! < Int($1.dropFirst(4))! }.compactMap { request.fields[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let transport = command.isEmpty ? (request.action == "edit" && server?.transport == "sse" ? "sse" : "http") : "stdio"
                    let input = NativeRPCValue.object([.init("name", .string(request.fields["name"] ?? "")), .init("scope", .string(scope)), .init("transport", .string(transport)), .init("command", .string(command)), .init("url", .string(url)), .init("extras", .array(extras.map(NativeRPCValue.string))), .init("projectPath", .string(request.panel.path))])
                    let result: NativeRPCValue
                    if request.action == "add" { guard let add = services.add else { throw missing("add") }; result = try await add(input, context) }
                    else { guard let edit = services.edit, let server else { throw missing("edit") }; result = try await edit(server, input, context) }
                    notice = result["message"].string ?? "The MCP writer did not report an outcome."
                case "remove": guard let server, let remove = services.remove else { throw missing("remove") }; let result = try await remove(server, request.panel.path, context); notice = result["message"].string ?? "The MCP writer did not report an outcome."
                case "connect": guard let server, let connect = services.connect else { throw missing("connect") }; let result = try await connect(server, context); notice = result["state"].string == "ready" ? "\(server.name) is connected." : "\(server.name) did not connect. " + (result["error"].string ?? "It gave no reason.")
                case "disconnect": guard let server, let disconnect = services.disconnect else { throw missing("disconnect") }; try await disconnect(server.id, context); notice = "\(server.name) is disconnected."
                default: throw NativeRPCError.invalidArguments("That is not something this panel offers.")
                }
            } catch { notice = error.localizedDescription }
            let unfiltered = BackendRemotePanelRequest(path: request.panel.path, scope: nil, query: nil)
            let redraw = try await read(unfiltered, context); return redraw.setting("notice", .string(notice))
        })
    }
    private static func missing(_ action: String) -> NativeRPCError { .init(code: "mcp-panel-action", message: "The native \(action) service or that configured server is unavailable") }
    private static func action(_ id: String, _ label: String) -> NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label))]) }
    private static func form(name: String, command: String, url: String, scope: String, keys: [String], stdio: Bool) -> [NativeRPCValue] {
        func field(_ id: String, _ label: String, _ value: String? = nil, _ hint: String? = nil) -> NativeRPCValue {
            var result = NativeRPCValue.object([.init("id", .string(id)), .init("label", .string(label))]); if let value { result = result.setting("value", .string(value)) }; if let hint { result = result.setting("placeholder", .string(hint)) }; return result
        }
        var fields = [field("name", "Name", name, "filesystem").setting("required", .bool(true)), field("command", "Command", command), field("url", "URL", url), field("scope", "Save it for", scope).setting("required", .bool(true)).setting("choices", .array(["user", "project", "local"].map(NativeRPCValue.string)))]
        for key in keys.sorted().prefix(19) { fields.append(field("env.\(fields.count)", key, key + "=", "Leave this to keep the saved value, or clear the box to drop it")) }
        fields.append(field("env.\(fields.count)", stdio ? "Environment variable" : "Header", nil, stdio ? "API_KEY=…" : "Authorization: Bearer … — saving replaces headers")); return fields
    }
}
