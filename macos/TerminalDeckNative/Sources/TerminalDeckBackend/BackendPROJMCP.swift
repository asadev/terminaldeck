import Foundation
import TerminalDeckNativeCore

public enum BackendPROJMCP {
    public typealias Authorize = @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier) async throws -> Void
    public typealias Resources = @Sendable (_ kind: String, _ projectID: String?, _ caller: BackendMCPCallContext) async throws -> [NativeRPCValue]
    public static let kinds = ["tasks", "agents", "servers", "task-sources", "routines", "receiver-sources", "artifacts", "settings"]
    public static func register(server: BackendNativeMCPServer, registry: BackendPROJRegistry,
                                ownerID: String = "native-projects", authorize: @escaping Authorize,
                                resources: Resources? = nil) async throws -> [String] {
        let tools = try contribution(registry: registry, authorize: authorize, resources: resources)
        for (spec, handler) in tools { try await server.registerTool(spec, ownerID: ownerID, handler: handler) }
        return tools.map { $0.0.id }
    }
    public static func contribution(registry: BackendPROJRegistry, authorize: @escaping Authorize,
                                    resources: Resources? = nil) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let nullable = text.setting("type", .array([.string("string"), .string("null")]))
        let array = NativeRPCValue.object([.init("type", .string("array")), .init("items", text)])
        let definitions: [(String, BackendMCPTier, String, [(String, NativeRPCValue)], [String])] = [
            ("project_registry.list", .read, "List projects, their folders and the active project. null active means all projects.", [], []),
            ("project_registry.resolve", .read, "Find the project for a folder. Older unscoped data falls back to Independent.", [("folder", text), ("projectId", text)], []),
            ("project_registry.switch", .alter, "Choose the active project, or null for all projects.", [("projectId", nullable)], ["projectId"]),
            ("project_registry.save", .alter, "Add or update a project name, folders, icon, colour and logo. An omitted colour keeps the old colour or picks the next project colour. logo: a full path to an image file on this Mac (it is copied into the app as a 256 px picture, exactly as Project settings › Logo does), \"\" to remove it, or omitted to keep it.", [("id", text), ("name", text), ("folders", array), ("icon", text), ("colour", text), ("logo", text)], ["id", "name", "folders"]),
            ("project_registry.remove_empty", .alter, "Remove one empty project registry entry with no folders or lead. Independent is kept.", [("id", text)], ["id"]),
            ("project_registry.set_lead", .alter, "Choose a project's lead: agent:<agent id> or session:<session id>, or null for no lead. Hoot gives a lead goals and the lead runs that project's agents; with no lead Hoot assigns agents directly. One lead per project.", [("projectId", text), ("lead", nullable), ("leadName", text)], ["projectId", "lead"]),
            ("project_registry.filter", .read, "Read tasks, agents, servers, task sources, routines, receiver sources, artifacts or settings for one project. Omitted projectId uses the active project; null reads all allowed projects. Existing source permissions still apply.", [("kind", text.setting("enum", .array(kinds.map(NativeRPCValue.string)))), ("projectId", nullable)], ["kind"])
        ]
        return try definitions.map { id, tier, description, properties, required in
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })), .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: schema, tier: tier)
            let handler: BackendNativeMCPServer.Handler = { caller, args in
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                guard let fields = args.fields, fields.allSatisfy({ field in properties.contains { $0.0 == field.key } }), required.allSatisfy({ args.has($0) }) else { throw NativeRPCError.invalidArguments("A required or extra project argument is invalid.") }
                for (key, shape) in properties where args.has(key) {
                    if shape["type"].elements != nil {
                        guard args[key].string != nil || args[key] == .null else { throw NativeRPCError.invalidArguments("\(key) must be a string or null.") }
                    } else if shape["type"].string == "array" {
                        guard let rows = args[key].elements, rows.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("\(key) must be a list of strings.") }
                    } else { guard args[key].string != nil else { throw NativeRPCError.invalidArguments("\(key) must be a string.") } }
                }
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller does not have the requested project access.") }
                if tier != .read { try await registry.requireWritable() }
                // A logo image is checked before anyone is asked; it is read and copied only after the yes.
                var logoSource: URL?
                if let raw = args["logo"].string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { logoSource = try BackendPROJLogos.source(raw) }
                if id == "project_registry.filter" {
                    guard kinds.contains(args["kind"].string ?? "") else { throw NativeRPCError.invalidArguments("Choose one supported project resource kind.") }
                }
                try await authorize(caller, id, args, tier)
                try Task.checkCancellation(); guard !caller.cancellation.isCancelled else { throw CancellationError() }
                switch id {
                case "project_registry.list": return .value(try await registry.snapshot())
                case "project_registry.resolve": return .value(.object([.init("projectId", .string(try await registry.resolve(projectID: args["projectId"].string, folder: args["folder"].string)))]))
                case "project_registry.switch": return .value(try await registry.select(args["projectId"].string))
                case "project_registry.remove_empty": return .value(try await registry.removeEmpty(args["id"].requireString("id", nonempty: true)))
                case "project_registry.set_lead":
                    return .value(try await registry.setLead(projectID: try args["projectId"].requireString("projectId", nonempty: true),
                                                             lead: args["lead"].string, leadName: args["leadName"].string))
                case "project_registry.filter":
                    let kind = try args["kind"].requireString("kind", nonempty: true)
                    let scope: String?
                    if args.has("projectId") { scope = args["projectId"].string } else { scope = try await registry.activeProjectID() }
                    _ = try await registry.filter([], projectID: scope)
                    guard let resources else { throw NativeRPCError(code: "unavailable", message: "Project resource reads are not installed.") }
                    let rows = try await resources(kind, scope, caller)
                    return .value(.object([.init("kind", .string(kind)), .init("projectId", scope.map(NativeRPCValue.string) ?? .null), .init("rows", .array(try await registry.filter(rows, projectID: scope)))]))
                default:
                    // A save through the tool keeps what it is not given: the logo (unless logo is passed) and the lead.
                    let id = try args["id"].requireString("id", nonempty: true)
                    let old = try await registry.projects().first { $0.id == id }
                    let oldLogo = old?.logo ?? "", directory = registry.logoDirectory
                    var logo = oldLogo
                    if let logoSource { logo = try BackendPROJLogos.adopt(logoSource, projectID: id, directory: directory) }
                    else if args.has("logo") { logo = "" }
                    let project = PROJProject(id: id, name: try args["name"].requireString("name", nonempty: true), folders: (args["folders"].elements ?? []).compactMap(\.string), icon: args["icon"].string ?? "folder", colour: args["colour"].string ?? "",
                                              logo: logo, lead: old?.lead ?? "", leadName: old?.leadName ?? "")
                    let saved: NativeRPCValue
                    do { saved = try await registry.save(project) }
                    catch { if logo != oldLogo { BackendPROJLogos.discard(logo, directory: directory) }; throw error }
                    // The old picture goes only once the project points at the new one.
                    if !oldLogo.isEmpty, oldLogo != logo { BackendPROJLogos.discard(oldLogo, directory: directory) }
                    return .value(saved)
                }
            }
            return (spec, handler)
        }
    }
}
