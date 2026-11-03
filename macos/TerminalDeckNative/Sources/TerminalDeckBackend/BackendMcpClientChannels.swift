import Foundation
import TerminalDeckNativeCore

/// One service/pool per app, also shared by owner-authorized MCP and remote
/// panel adapters. Config writes remain owned by the agent CLI.
public actor BackendMcpClientService {
    public typealias SaveChooser = @Sendable (String) async throws -> String?
    public typealias OpenChooser = @Sendable () async throws -> String?
    public nonisolated let configuration: BackendMcpClientConfiguration
    public nonisolated let writer: BackendMcpClientWriter
    public nonisolated let pool: BackendMcpClientPool
    public nonisolated let store: BackendMcpClientStore
    private let saveChooser: SaveChooser?, openChooser: OpenChooser?
    private var registries = Set<ObjectIdentifier>()
    private var registrationTasks: [ObjectIdentifier: Task<[String], any Error>] = [:]
    public init(writer: BackendMcpClientWriter, pool: BackendMcpClientPool? = nil, saveChooser: SaveChooser? = nil, openChooser: OpenChooser? = nil) {
        self.writer = writer; configuration = writer.configuration; self.pool = pool ?? BackendMcpClientPool(configuration: writer.configuration, loginPath: writer.loginPath)
        store = BackendMcpClientStore(writer: writer); self.saveChooser = saveChooser; self.openChooser = openChooser
    }
    public func list(_ projectPath: NativeRPCValue = .missing) async throws -> NativeRPCValue {
        // TRUTH-B: a server switched off on this page shows Off (its own config is never edited for it).
        let off = Set(BackendMcpPolicy.load().servers.filter { $0.value.off }.map(\.key))
        return .array(await pool.statuses(configuration.load(project: try BackendMcpClientConfiguration.projectPath(projectPath))).map { row in
            guard let name = row["name"].string, off.contains(name), row["enabled"].bool != false else { return row }
            return row.setting("enabled", .bool(false)).setting("disabledReason", .string("Turned off in Terminal Deck: sessions it starts do not get it."))
        })
    }
    public func connect(_ id: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue { await pool.connect(try configuration.find(id: id, project: BackendMcpClientConfiguration.projectPath(project))) }
    public func disconnect(_ id: NativeRPCValue) async throws -> NativeRPCValue {
        guard let id = id.string else { throw BackendMcpClientValue.error("mcp: a server id is required") }; return await pool.disconnect(id) ?? .null
    }
    public func inventory(_ id: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue { await pool.inventory(try configuration.find(id: id, project: BackendMcpClientConfiguration.projectPath(project))) }
    public func call(_ id: NativeRPCValue, name: NativeRPCValue, arguments: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue {
        guard let tool = name.string, !tool.isEmpty else { throw BackendMcpClientValue.error("mcp: a tool name is required") }
        let server = try configuration.find(id: id, project: BackendMcpClientConfiguration.projectPath(project))
        let args = try Self.arguments(arguments)
        return await pool.call(server, method: "tools/call", params: .object([.init("name", .string(tool)), .init("arguments", args)]), label: "Calling " + tool, tool: true)
    }
    public func resource(_ id: NativeRPCValue, uri: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue {
        guard let uri = uri.string, !uri.isEmpty else { throw BackendMcpClientValue.error("mcp: a resource uri is required") }
        let server = try configuration.find(id: id, project: BackendMcpClientConfiguration.projectPath(project))
        return await pool.call(server, method: "resources/read", params: .object([.init("uri", .string(uri))]), label: "Reading " + uri)
    }
    public func prompt(_ id: NativeRPCValue, name: NativeRPCValue, arguments: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue {
        guard let name = name.string, !name.isEmpty else { throw BackendMcpClientValue.error("mcp: a prompt name is required") }
        let server = try configuration.find(id: id, project: BackendMcpClientConfiguration.projectPath(project)), args = try Self.arguments(arguments)
        let strings = NativeRPCValue.object((args.fields ?? []).filter { !$0.value.isNullish }.map { .init($0.key, .string(BackendMcpClientValue.jsString($0.value))) })
        return await pool.call(server, method: "prompts/get", params: .object([.init("name", .string(name)), .init("arguments", strings)]), label: "Rendering " + name)
    }
    public static func arguments(_ value: NativeRPCValue) throws -> NativeRPCValue {
        if value.isNullish { return .object([]) }; guard value.fields != nil else { throw BackendMcpClientValue.error("mcp: tool arguments must be an object") }; return value
    }
    public func toolFile(name: NativeRPCValue, scope: NativeRPCValue, project: NativeRPCValue = .missing) throws -> NativeRPCValue? {
        let path = try BackendMcpClientConfiguration.projectPath(project)
        guard let server = configuration.load(project: path, asSaved: true).map(BackendMcpClientConfiguration.configured).first(where: { $0.name == name.string && $0.scope == scope.string }) else { return nil }
        return .object([.init("name", .string(server.name)), .init("fileName", .string(BackendMcpClientShare.fileName(server.name))), .init("text", .string(try BackendMcpClientShare.fileText(server)))])
    }
    public func export(name: NativeRPCValue, scope: NativeRPCValue, project: NativeRPCValue = .missing) async throws -> NativeRPCValue {
        guard let saveChooser else { return BackendMcpClientValue.failure("This build cannot save a file.") }
        guard let file = try toolFile(name: name, scope: scope, project: project) else { return BackendMcpClientValue.failure("That server is not in your configuration.") }
        guard let path = try await saveChooser(file["fileName"].string!) else { return BackendMcpClientValue.result(true, "") }
        do { try Data(file["text"].string!.utf8).write(to: URL(fileURLWithPath: path)) }
        catch { return BackendMcpClientValue.failure("That file could not be written — \(error.localizedDescription).") }
        return BackendMcpClientValue.result(true, "\(file["name"].string!) was written to \(path). It holds no values — only the names of the variables it needs — so whoever opens it fills those in themselves.")
    }
    public func importFile() async throws -> NativeRPCValue {
        guard let openChooser else { return BackendMcpClientValue.failure("This build cannot open a file.") }
        guard let path = try await openChooser() else { return BackendMcpClientValue.result(true, "") }
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { return BackendMcpClientValue.failure("That file could not be read — \(error.localizedDescription).") }
        let read = BackendMcpClientShare.read(text)
        if read["ok"].bool != true { return BackendMcpClientValue.failure("Nothing was imported: \(read["why"].string ?? "").") }
        let draft = read["draft"], name = draft["name"].string!, env = (draft["env"].elements ?? []).compactMap(\.string)
        let message = env.isEmpty ? "\(name) is filled in below. Nothing has been written yet." : "\(name) is filled in below. \(env.joined(separator: ", ")) came with no value — that is what this format does — so fill those in before you add it."
        return BackendMcpClientValue.result(true, message).setting("draft", draft)
    }
    public func stopAll() async { await pool.disconnectAll() }

    // MARK: TRUTH-B: the server's switches (BackendMcpPolicy), applied at every session launch

    private var agentsSource: (@Sendable () async -> [(id: String, name: String)])?
    /// The saved agents, for the per-agent switches (supplied once the task owner is up).
    public func setAgentsSource(_ source: @escaping @Sendable () async -> [(id: String, name: String)]) { agentsSource = source }

    private func policyServer(_ request: NativeRPCValue) throws -> String {
        guard let id = request["serverId"].string, !id.isEmpty else { throw BackendMcpClientValue.error("mcp: a server id is required") }
        let name = BackendMcpPolicy.name(id), project = try BackendMcpClientConfiguration.projectPath(request["projectPath"])
        let codexHome = configuration.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? configuration.home + "/.codex"
        guard BackendMcpPolicy.valid(name), configuration.load(project: project).contains(where: { $0["name"].string == name })
                || BackendAppAgentInventory.codexServers(file: codexHome + "/config.toml").contains(name) else {
            throw BackendMcpClientValue.error("mcp: no configured server called \(name)")
        }
        return name
    }
    public func policy(_ request: NativeRPCValue) async throws -> NativeRPCValue {
        let name = try policyServer(request), document = BackendMcpPolicy.load(), entry = document.servers[name] ?? .init()
        var answer = NativeRPCValue.object([
            .init("ok", .bool(true)), .init("enabled", .bool(!entry.off)),
            // Only the tools switched off are listed; every other tool is on.
            .init("tools", .object(entry.toolsOff.map { .init($0, .bool(false)) })),
            .init("access", .object(BackendMcpPolicy.clients.map { .init($0, .bool(!entry.clientsOff.contains($0))) })),
            .init("revision", .number(Double(document.revision)))])
        if let agentsSource {
            let agents = await agentsSource()
            answer = answer.setting("agents", .array(agents.map { .object([.init("id", .string($0.id)), .init("name", .string($0.name)),
                                                                          .init("enabled", .bool(!entry.agentsOff.contains($0.id)))]) }))
        }
        return answer
    }
    public func setPolicy(_ channel: String, _ request: NativeRPCValue) async throws -> NativeRPCValue {
        let name = try policyServer(request)
        guard let enabled = request["enabled"].bool else { throw BackendMcpClientValue.error("mcp: enabled must be true or false") }
        let revision = request["revision"].number.map { Int($0) }
        var tool: String?, client: String?, agent: String?
        switch channel {
        case "mcp:tools:set":
            guard let named = request["tool"].string, BackendMcpPolicy.valid(named) else { throw BackendMcpClientValue.error("mcp: a tool name is required") }
            tool = named
        case "mcp:access:set":
            if let named = request["client"].string {
                guard BackendMcpPolicy.clients.contains(named) else { throw BackendMcpClientValue.error("mcp: client is claude, codex or gemini") }
                client = named
            } else if let id = request["agentId"].string, !id.isEmpty, id.count <= 120 { agent = id }
            else { throw BackendMcpClientValue.error("mcp: name a client or an agent") }
        default: break
        }
        do {
            let next = try BackendMcpPolicy.change(name, expected: revision) { entry in
                if let tool { BackendMcpPolicy.toggled(&entry.toolsOff, tool, off: !enabled) }
                else if let client { BackendMcpPolicy.toggled(&entry.clientsOff, client, off: !enabled) }
                else if let agent { BackendMcpPolicy.toggled(&entry.agentsOff, agent, off: !enabled) }
                else { entry.off = !enabled }
            }
            return .object([.init("ok", .bool(true)), .init("revision", .number(Double(next))),
                            .init("message", .string("Saved. Sessions Terminal Deck starts from now on follow it; running ones keep what they had."))])
        } catch BackendMcpPolicy.Failure.stale {
            return BackendMcpClientValue.failure("These switches changed somewhere else. Open the server again and retry.")
        } catch BackendMcpPolicy.Failure.unwritable(let why) {
            return BackendMcpClientValue.failure("That could not be saved: " + why)
        }
    }

    public func register(registry: NativeChannelRegistry, ownerID: String) async throws -> [String] {
        let registryID = ObjectIdentifier(registry)
        if registries.contains(registryID) { return BackendMcpClientChannels.names }
        if let task = registrationTasks[registryID] { return try await task.value }
        let task = Task { try await self.installChannels(registry: registry, ownerID: ownerID) }
        registrationTasks[registryID] = task
        defer { registrationTasks[registryID] = nil }
        let channels = try await task.value; registries.insert(registryID); return channels
    }
    private func installChannels(registry: NativeChannelRegistry, ownerID: String) async throws -> [String] {
        var added: [String] = []
        do {
            for channel in BackendMcpClientChannels.names {
                try await registry.register(channel, ownerID: ownerID, policy: { context in
                    // Electron exposed these handlers to its own window only.
                    // Agent tools/remote guests need the existing owner grants,
                    // not arbitrary access to full inspector config payloads.
                    guard context.caller == .nativeApp || context.caller == .internalEngine else { throw NativeRPCError(code: "access-denied", message: "The MCP configuration inspector requires an app-owned caller.") }
                }) { [self] context, args in
                    let a = context.argument(0, in: args), b = context.argument(1, in: args), c = context.argument(2, in: args), d = context.argument(3, in: args)
                    switch channel {
                    case "mcp:list": return try await self.list(a)
                    case "mcp:add": return await self.writer.add(a)
                    case "mcp:remove": return await self.writer.remove(a)
                    case "mcp:edit": return await self.writer.edit(a)
                    case "mcp:store": return await self.store.view(project: try BackendMcpClientConfiguration.projectPath(a), refreshEnvironment: b.bool == true)
                    case "mcp:store-install": return await self.store.install(a)
                    case "mcp:connect": return try await self.connect(a, project: b)
                    case "mcp:disconnect": return try await self.disconnect(a)
                    case "mcp:inventory": return try await self.inventory(a, project: b)
                    case "mcp:call": return try await self.call(a, name: b, arguments: c, project: d)
                    case "mcp:read-resource": return try await self.resource(a, uri: b, project: c)
                    case "mcp:get-prompt": return try await self.prompt(a, name: b, arguments: c, project: d)
                    case "mcp:export": return try await self.export(name: a, scope: b, project: c)
                    case "mcp:import": return try await self.importFile()
                    case "mcp:policy": return try await self.policy(a)
                    case "mcp:enabled", "mcp:tools:set", "mcp:access:set": return try await self.setPolicy(channel, a)
                    default: throw NativeRPCError(code: "missing-handler", message: "No MCP handler registered for '\(channel)'")
                    }
                }
                added.append(channel)
            }
            await pool.setStatusSink { status in try? await registry.publish("mcp:state", arguments: [status]) }
            return BackendMcpClientChannels.names
        } catch {
            for channel in added { await registry.removeHandler(channel, ownerID: ownerID) }; throw error
        }
    }
}

public enum BackendMcpClientChannels {
    public static let names = ["mcp:list", "mcp:add", "mcp:remove", "mcp:store", "mcp:store-install", "mcp:edit", "mcp:export", "mcp:import", "mcp:connect", "mcp:disconnect", "mcp:inventory", "mcp:call", "mcp:read-resource", "mcp:get-prompt",
                                      "mcp:policy", "mcp:enabled", "mcp:tools:set", "mcp:access:set"]
    @discardableResult public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendMcpClientService) async throws -> [String] { try await service.register(registry: registry, ownerID: ownerID) }
}
