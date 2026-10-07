import Foundation
import TerminalDeckNativeCore

/// Third-party MCP/client/configuration owners provide exactly their existing
/// resolvers and operations. Config writes must continue through claude mcp add/remove.
public protocol BackendDeckCoreEventsMCPProvider: Sendable {
    func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String
    func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue
    func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue
    func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue
    func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue
    func list(projectPath: String?) async throws -> [NativeRPCValue]
    func add(_ request: NativeRPCValue) async throws -> NativeRPCValue
    func edit(_ request: NativeRPCValue) async throws -> NativeRPCValue
    func remove(_ request: NativeRPCValue) async throws -> NativeRPCValue
    func inventory(id: String, projectPath: String?) async throws -> NativeRPCValue
    func disconnect(id: String) async throws -> NativeRPCValue?
    func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async throws -> NativeRPCValue
    func store(projectPath: String?) async throws -> NativeRPCValue
    func install(_ request: NativeRPCValue) async throws -> NativeRPCValue
    func toolFile(name: String, scope: String, projectPath: String?) async throws -> NativeRPCValue?
}

public enum BackendDeckCoreEventsTools {
    public typealias Gate = @Sendable (String, BackendMCPCallContext, NativeRPCValue) async throws -> BackendMCPToolReply
    /// Retains the source title, compact index and key-only audience for describe/list.
    public static func metadata(policies: [BackendDeckCoreSecurityToolPolicy]) throws -> [BackendDeckCoreCatalogueMetadata] {
        let definitions = try BackendDeckCoreEventsToolDefinitions.all()
        return policies.map { policy in
            let row = definitions.first { $0["id"].string == policy.tool.id }
            return BackendDeckCoreCatalogueMetadata(tool:policy.tool,title:row?["title"].string ?? policy.tool.id,
                aliases:policy.aliases,index:row?["index"].string,audience:policy.audience)
        }
    }
    public static func area(id: String, policies: [BackendDeckCoreSecurityToolPolicy], gate: @escaping Gate) throws -> BackendDeckCoreToolArea {
        var handlers: [String: BackendNativeMCPServer.Handler] = [:]
        for policy in policies { let name = policy.tool.id; handlers[name] = { context,args in try await gate(name,context,args) } }
        return try BackendDeckCoreToolArea(id:id,tools:policies.map(\.tool),describeText:policies.map { "\($0.tool.wireName): \($0.tool.description)" }.joined(separator:"\n"),handlers:handlers)
    }
    public static func notificationPolicies(hub: @escaping @Sendable () async -> BackendDeckCoreEventsHub?) throws -> [BackendDeckCoreSecurityToolPolicy] {
        try BackendDeckCoreEventsToolDefinitions.all().filter { $0["id"].string?.hasPrefix("notifications.") == true }.map { row in
            let id = row["id"].string!, tool = try tool(row,advertised:id == "notifications.wait")
            return BackendDeckCoreSecurityToolPolicy(tool:tool,audience:"keys",summary:{ args,_ in
                if id == "notifications.wait" { return "Wait for notifications" }
                if id == "notifications.list" { return "List notifications" }
                return "Acknowledge \(args["ids"].elements?.count ?? 0) notification(s)"
            },precheck:{ args,context in
                _ = try key(context,tool:id)
                if id != "notifications.list" { _ = try ids(args,id == "notifications.wait" ? "ack" : "ids") }
            },run:{ args,context in
                let keyID = try key(context,tool:id)
                guard let hub = await hub() else { throw BackendDeckCoreSecurityRefusal(.notPermitted,"Notifications are not running on this computer right now.") }
                switch id {
                case "notifications.wait":
                    let ack = await hub.ack(keyId:keyID,ids:try ids(args,"ack")), acked = ack["acked"].elements?.count ?? 0
                    let seconds = args["timeoutSeconds"].number.map { min(max($0.rounded(.towardZero),1),120) } ?? 45
                    let events = await hub.wait(keyId:keyID,timeoutMs:seconds*1_000,cancellation:context.cancellation,max:20), outstanding = await hub.size(keyId:keyID)
                    let value = BackendDeckCoreEventsSupport.object([("notifications",.array(events)),("timedOut",.bool(events.isEmpty)),("outstanding",.number(Double(outstanding))),("note",.string(events.isEmpty ? "Nothing happened in your sessions while waiting. Call notifications_wait again." : "Handle these, then pass their ids as ack on your next notifications_wait."))])
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("received",.number(Double(events.count))),("acked",.number(Double(acked))),("outstanding",.number(Double(outstanding)))]))
                case "notifications.list":
                    let events = await hub.list(keyId:keyID); return .init(value:BackendDeckCoreEventsSupport.object([("notifications",.array(events))]),summary:BackendDeckCoreEventsSupport.object([("outstanding",.number(Double(events.count)))]))
                default:
                    let value = await hub.ack(keyId:keyID,ids:try ids(args,"ids")); return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("acked",.number(Double(value["acked"].elements?.count ?? 0))),("alreadyGone",.number(Double(value["alreadyGone"].elements?.count ?? 0)))]))
                }
            })
        }
    }
    private static func key(_ context: BackendDeckCoreSecurityCallContext, tool: String) throws -> String {
        guard context.caller.kind == .key, let key = context.caller.keyID else { throw BackendDeckCoreSecurityRefusal(.notGranted,"\(tool) is for AI apps connected with an access key. Nothing here queues notifications for this caller.") }; return key
    }
    public static func ids(_ args: NativeRPCValue, _ field: String) throws -> [String] {
        if args[field].isNullish { return [] }
        guard let values = args[field].elements else { throw NativeRPCError.invalidArguments("\(field) must be a list of notification ids") }
        let ids = values.compactMap(\.string).filter { !$0.isEmpty }
        guard ids.count <= 200 else { throw NativeRPCError.invalidArguments("acknowledge at most 200 ids at once") }; return ids
    }
    public static func mcpPolicies(provider: any BackendDeckCoreEventsMCPProvider = BackendDeckCoreEventsUnavailableMCPProvider()) throws -> [BackendDeckCoreSecurityToolPolicy] {
        try BackendDeckCoreEventsToolDefinitions.all().filter { $0["id"].string?.hasPrefix("mcp.") == true }.map { row in
            let id = row["id"].string!, tool = try tool(row,advertised:false)
            let writes = ["mcp.add","mcp.edit","mcp.remove","mcp.install"].contains(id)
            return BackendDeckCoreSecurityToolPolicy(tool:tool,summary:{ args,_ in try summary(id,args) },precheck:writes ? { @Sendable (args: NativeRPCValue, context: BackendDeckCoreSecurityToolPolicy.Context) throws -> Void in
                let project = ["mcp.disconnect","mcp.import"].contains(id) ? nil : try folder(args,context:context,provider:provider)
                do {
                    switch id {
                    case "mcp.add": _ = try provider.resolveAdd(addRequest(args,projectPath:project))
                    case "mcp.edit": _ = try provider.resolveEdit(editRequest(args,projectPath:project))
                    case "mcp.remove": _ = try provider.resolveRemove(args.setting("projectPath",BackendDeckCoreEventsSupport.nullable(project)))
                    default: _ = try provider.resolveInstall(args.setting("projectPath",BackendDeckCoreEventsSupport.nullable(project)))
                    }
                } catch { throw NativeRPCError.invalidArguments(error.localizedDescription) }
            } : nil,redactArgs:["mcp.add","mcp.edit","mcp.install"].contains(id) ? { @Sendable (value: NativeRPCValue) throws -> NativeRPCValue in redactEnvValues(value) } : nil,run:{ args,context in
                let project = ["mcp.disconnect","mcp.import"].contains(id) ? nil : try folder(args,context:context,provider:provider)
                switch id {
                case "mcp.list":
                    let servers = try await provider.list(projectPath:project).map(serverView)
                    return .init(value:BackendDeckCoreEventsSupport.object([("servers",.array(servers))]),summary:BackendDeckCoreEventsSupport.object([("servers",.number(Double(servers.count)))]))
                case "mcp.add":
                    let request = try checked { try provider.resolveAdd(addRequest(args,projectPath:project)) }, value = try landed(await provider.add(request),what:"the add")
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("name",request["name"]),("scope",request["scope"]),("transport",request["transport"])]))
                case "mcp.edit":
                    let request = try editRequest(args,projectPath:project), value = try landed(await provider.edit(request),what:"the change")
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("name",request["name"]),("scope",request["scope"])]))
                case "mcp.remove":
                    let request = try checked { try provider.resolveRemove(args.setting("projectPath",BackendDeckCoreEventsSupport.nullable(project))) }, value = try landed(await provider.remove(request),what:"the removal")
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("name",request["name"]),("scope",request["scope"])]))
                case "mcp.connect":
                    let value = try await provider.inventory(id:str(args,"serverId"),projectPath:project)
                    return .init(value:value.setting("status",serverView(value["status"])),summary:BackendDeckCoreEventsSupport.object([("serverId",value["serverId"]),("state",value["status"]["state"]),("tools",.number(Double(value["tools"].elements?.count ?? 0)))]))
                case "mcp.disconnect":
                    let server = try str(args,"serverId"), status = try await provider.disconnect(id:server)
                    let value = status.map { BackendDeckCoreEventsSupport.object([("wasConnected",.bool(true)),("status",serverView($0))]) } ?? BackendDeckCoreEventsSupport.object([("serverId",.string(server)),("wasConnected",.bool(false))])
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("serverId",.string(server)),("wasConnected",.bool(status != nil))]))
                case "mcp.call":
                    let server = try str(args,"serverId"), name = try str(args,"tool"), value = try await provider.call(id:server,tool:name,arguments:record(args,"arguments") ?? .object([]),projectPath:project)
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("serverId",.string(server)),("tool",.string(name)),("ok",value["ok"]),("ms",value["durationMs"]),("truncated",value["truncated"])]))
                case "mcp.store":
                    let value = try await provider.store(projectPath:project)
                    return .init(value:BackendDeckCoreEventsRedaction.value(value),summary:BackendDeckCoreEventsSupport.object([("rows",.number(Double(value["rows"].elements?.count ?? 0)))]))
                case "mcp.install":
                    let request = try checked { try provider.resolveInstall(args.setting("projectPath",BackendDeckCoreEventsSupport.nullable(project))) }, value = try landed(await provider.install(request),what:"the install")
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("id",request["id"]),("scope",request["scope"])]))
                case "mcp.export":
                    let scope = try scope(args), name = try str(args,"name")
                    guard let value = try await provider.toolFile(name:name,scope:scope,projectPath:project) else { throw BackendDeckCoreSecurityRefusal(.notPermitted,"that server is not in the configuration. mcp.list shows them.") }
                    return .init(value:value,summary:BackendDeckCoreEventsSupport.object([("name",value["name"])]))
                default:
                    let draft = try readToolFile(str(args,"text"))
                    return .init(value:BackendDeckCoreEventsRedaction.withoutSecrets(BackendDeckCoreEventsSupport.object([("draft",draft)])),summary:BackendDeckCoreEventsSupport.object([("name",draft["name"])]))
                }
            })
        }
    }
    private static func tool(_ row: NativeRPCValue, advertised: Bool) throws -> BackendMCPTool {
        try BackendMCPTool(id:row["id"].requireString("id"),wireName:row["wire"].requireString("wire"),description:row["description"].requireString("description"),inputSchema:row["inputSchema"],tier:BackendMCPTier(rawValue:row["tier"].string ?? "") ?? .alter,advertised:advertised)
    }
    private static func checked<T>(_ resolve: () throws -> T) throws -> T { do { return try resolve() } catch { throw NativeRPCError.invalidArguments(error.localizedDescription) } }
    private static func landed(_ result: NativeRPCValue, what: String) throws -> NativeRPCValue {
        guard result["ok"].bool == true else { throw BackendDeckCoreSecurityRefusal(.notPermitted,"\(what) did not happen: \(result["message"].string ?? "unavailable")") }
        return BackendDeckCoreEventsSupport.object([("ok",.bool(true)),("message",result["message"])])
    }
    private static func str(_ args: NativeRPCValue, _ key: String) throws -> String {
        guard let raw = args[key].string, !raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("\(key) is required and must be a non-empty string") }; return raw.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    private static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        if args[key].isNullish || args[key].string == "" { return nil }
        guard let value = args[key].string else { throw NativeRPCError.invalidArguments("\(key) must be a string") }
        let trimmed = value.trimmingCharacters(in:.whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed
    }
    private static func record(_ args: NativeRPCValue, _ key: String) throws -> NativeRPCValue? {
        if args[key].isNullish { return nil }; guard args[key].fields != nil else { throw NativeRPCError.invalidArguments("\(key) must be an object") }; return args[key]
    }
    private static func scope(_ args: NativeRPCValue) throws -> String {
        guard let scope = args["scope"].string, ["user","project","local"].contains(scope) else { throw NativeRPCError.invalidArguments("scope must be one of: user, project, local") }; return scope
    }
    private static func folder(_ args: NativeRPCValue, context: BackendDeckCoreSecurityCallContext, provider: any BackendDeckCoreEventsMCPProvider) throws -> String? {
        guard let path = try optStr(args,"projectPath") else { return nil }; return try provider.knownFolder(path,context:context)
    }
    public static func addRequest(_ input: NativeRPCValue, projectPath: String?) throws -> NativeRPCValue {
        let transport = input["transport"].string ?? "stdio", env = try record(input,"env"), headers = try record(input,"headers"), source = transport == "stdio" ? env : headers
        let extras = try (source?.fields ?? []).map { field -> NativeRPCValue in
            guard let value = field.value.string else { throw NativeRPCError.invalidArguments("\(field.key) must be a string") }; return .string(field.key + (transport == "stdio" ? "=" : ": ") + value)
        }
        return BackendDeckCoreEventsSupport.object([("name",input["name"]),("scope",input["scope"].isNullish ? .string("user") : input["scope"]),("transport",.string(transport)),("command",input["command"].isNullish ? .string("") : input["command"]),("url",input["url"].isNullish ? .string("") : input["url"]),("extras",.array(extras)),("projectPath",BackendDeckCoreEventsSupport.nullable(projectPath))])
    }
    private static func editRequest(_ input: NativeRPCValue, projectPath: String?) throws -> NativeRPCValue {
        let name = try str(input,"name"), scope = try scope(input), next = try record(input,"next") ?? .object([])
        return BackendDeckCoreEventsSupport.object([("name",.string(name)),("scope",.string(scope)),("projectPath",BackendDeckCoreEventsSupport.nullable(projectPath)),("next",try addRequest(BackendDeckCoreEventsSupport.object([("name",.string(name)),("scope",.string(scope))]).merging(next),projectPath:projectPath))])
    }
    public static func redactEnvValues(_ args: NativeRPCValue) -> NativeRPCValue {
        var out = args
        for key in ["env","headers","values"] { if let fields = args[key].fields { out = out.setting(key,.object(fields.map { .init($0.key,.string("[redacted]")) })) } }
        if args["next"].fields != nil { out = out.setting("next",redactEnvValues(args["next"])) }; return out
    }
    public static func serverView(_ status: NativeRPCValue) -> NativeRPCValue {
        BackendDeckCoreEventsRedaction.value(status.removing("env")).setting("envKeys",.array((status["env"].fields ?? []).map(\.key).sorted().map(NativeRPCValue.string)))
    }
    public static func readToolFile(_ text: String) throws -> NativeRPCValue {
        func refuse(_ why: String) -> NativeRPCError { .invalidArguments("that is not a server definition: \(why)") }
        guard let raw = try? NativeRPCValue.parseJSON(Data(text.utf8)) else { throw refuse("that file is not JSON this app can read") }
        guard raw.fields != nil || raw.elements != nil else { throw refuse("that file does not hold a tool definition") }
        guard raw["kind"].string == "mcp-server" else { throw refuse("that file is not an MCP server definition") }
        let name = raw["name"].string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw refuse("that definition has no name in it") }
        let transport: String = ["stdio","http","sse"].first(where: { $0 == raw["transport"].string }) ?? "stdio"
        let command = raw["command"].string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "", url = raw["url"].string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        if transport == "stdio" && command.isEmpty { throw refuse("that definition has no command in it") }
        if transport != "stdio" && url.isEmpty { throw refuse("that definition has no URL in it") }
        let env = (raw["env"].elements ?? []).compactMap(\.string).map { $0.components(separatedBy:"=").first?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }.filter { !$0.isEmpty }.prefix(32)
        return BackendDeckCoreEventsSupport.object([("name",.string(name)),("transport",.string(transport)),("command",.string(command)),("url",.string(url)),("env",.array(env.map(NativeRPCValue.string)))])
    }
    private static func summary(_ id: String, _ args: NativeRPCValue) throws -> String {
        func text(_ field: String, _ fallback: String = "?") throws -> String { try optStr(args,field) ?? fallback }
        func names(_ field: String) -> String { (args[field].fields ?? []).map(\.key).joined(separator:", ") }
        switch id {
        case "mcp.list": return "List MCP servers" + (try optStr(args,"projectPath").map { " for " + $0 } ?? "")
        case "mcp.add":
            let how = args["transport"].string == "stdio" ? "runs \(try text("command"))" : "at \(try text("url"))", given = names(args["transport"].string == "stdio" ? "env" : "headers")
            return "Add the \(try text("scope","user")) MCP server \(try text("name")), which \(how)" + (given.isEmpty ? "" : ", given " + given)
        case "mcp.edit": return "Change the \(try text("scope")) MCP server \(try text("name"))"
        case "mcp.remove": return "Remove the \(try text("scope")) MCP server \(try text("name")) and its saved keys"
        case "mcp.connect": return "Connect to the MCP server \(try text("serverId"))"
        case "mcp.disconnect": return "Disconnect from the MCP server \(try text("serverId"))"
        case "mcp.call": let given = names("arguments"); return "Call \(try text("tool")) on the MCP server \(try text("serverId"))" + (given.isEmpty ? "" : " with " + given)
        case "mcp.store": return "Browse the MCP store"
        case "mcp.install": let given = names("values"); return "Install \(try text("id")) from the MCP store (\(try text("scope","user")) scope)" + (given.isEmpty ? "" : ", given " + given)
        case "mcp.export": return "Export the MCP server \(try text("name"))"
        default: return "Read a shared MCP server definition"
        }
    }
}

/// Explicit missing-provider behavior, never an empty inventory or a successful write.
public struct BackendDeckCoreEventsUnavailableMCPProvider: BackendDeckCoreEventsMCPProvider {
    public init() {}
    private func unavailable() -> NativeRPCError { .init(code:"unavailable",message:"The agents’ MCP client and configuration provider is unavailable on this computer right now.") }
    public func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String { throw unavailable() }
    public func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue { throw unavailable() }
    public func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue { throw unavailable() }
    public func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue { throw unavailable() }
    public func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue { throw unavailable() }
    public func list(projectPath: String?) async throws -> [NativeRPCValue] { throw unavailable() }
    public func add(_ request: NativeRPCValue) async throws -> NativeRPCValue { throw unavailable() }
    public func edit(_ request: NativeRPCValue) async throws -> NativeRPCValue { throw unavailable() }
    public func remove(_ request: NativeRPCValue) async throws -> NativeRPCValue { throw unavailable() }
    public func inventory(id: String, projectPath: String?) async throws -> NativeRPCValue { throw unavailable() }
    public func disconnect(id: String) async throws -> NativeRPCValue? { throw unavailable() }
    public func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async throws -> NativeRPCValue { throw unavailable() }
    public func store(projectPath: String?) async throws -> NativeRPCValue { throw unavailable() }
    public func install(_ request: NativeRPCValue) async throws -> NativeRPCValue { throw unavailable() }
    public func toolFile(name: String, scope: String, projectPath: String?) async throws -> NativeRPCValue? { throw unavailable() }
}
