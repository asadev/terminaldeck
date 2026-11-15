import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// The project registry is separate from the existing open-folder list.
    /// It uses the app's writer, approvals, tool catalogue and lifetime.
    func installPROJProjects() async throws {
        let owner = "native-composition:project-registry", registry = root.registry, mcp = root.mcp
        let projects = BackendPROJRegistry(fileURL: root.dataRoot.appendingPathComponent("projects.registry.json"), writable: root.state.ownership != .readOnly,
            changed: { try? await registry.publish("project-registry:changed", arguments: [$0]) })
        let settings = root.settings, joins = self.joins, authority = try wired(self.authority, "authority")
        let artifactProjects = files?.projects
        let projectIdentity: BackendPROJSettings.ProjectIdentity = { caller in
            let trusted = try await authority.resolve(caller)
            guard let id = trusted.caller.sessionID,
                  let session = authority.prepared.manager.list().first(where: { $0.id == id }) else { return nil }
            return try await projects.resolve(projectID: session.projectId, folder: session.cwd)
        }
        _ = try await projects.projects()
        BackendPROJRegistry.installed = projects   // L4: deleting an agent that leads a project clears that lead
        // Project folders (owner, 14 Nov): this Mac's own record beside the project list; the Terminal Deck folder with
        // Projects inside is made at start ("installing the app makes it"), never under a test run.
        let folders = BackendProjectFolders(file: root.dataRoot.appendingPathComponent(BackendProjectFolders.fileName), registry: projects,
                                            protected: [root.dataRoot.path])
        BackendProjectFolders.installed = folders
        if root.state.ownership != .readOnly, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { await folders.prepare() }
        if let index = files?.artifacts {
            await index.bindProjectResolver { try await projects.resolve(projectID: nil, folder: $0) }
            // The Artifacts page lists every registered project's work, with or without a session open in its folder.
            await index.bindRegisteredFolders { try await projects.projects().flatMap(\.folders) }
            await index.bindSessionProjectResolver { provider, conversation in
                let identities = Set(authority.prepared.manager.list().filter { $0.provider == provider && $0.agentSessionId == conversation }
                    .compactMap { $0.projectId }.filter(PROJProjects.isValidID))
                return identities.count == 1 ? identities.first : nil
            }
        }
        let authorize: BackendPROJMCP.Authorize = { caller, tool, args, tier in
            _ = try await authority.resolve(caller)
            var sentence: String
            switch tool {
            case "project_registry.switch": sentence = "Choose " + (args["projectId"].string.map { PROJProjects.name(for: $0) } ?? "All projects")
            case "project_registry.save":
                let logo = args["logo"].string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                sentence = "Save the project " + (args["name"].string ?? "") + (logo == nil ? "" : logo!.isEmpty ? " and remove its logo" : " with the logo " + (logo! as NSString).lastPathComponent)
                // A call that changes the project's folders says which, as short full paths (review 14 Nov).
                let wanted = (args["folders"].elements ?? []).compactMap(\.string).map(PROJProjects.normalize)
                let had = (try? await projects.projects())?.first { $0.id == args["id"].string }?.folders.map(PROJProjects.normalize) ?? []
                if Set(wanted) != Set(had) {
                    sentence += wanted.isEmpty ? " with no folder" : " with the folder" + (wanted.count == 1 ? " " : "s ") + wanted.map { BackendProjectFolders.shortPath($0) }.joined(separator: ", ")
                }
            case "project_registry.set_lead": sentence = args["lead"].string == nil ? "Remove the project's lead" : "Make " + (args["leadName"].string ?? "this agent") + " the project's lead"
            case "project_settings.set": sentence = "Change the project's settings"
            // The short FULL path, never only its last part: "Use ~/Library/Application Support/terminaldeck" must
            // read as what it is (review 14 Nov). Such folders are refused anyway (`BackendProjectFolders.refusal`).
            case "project_folders.use":
                sentence = "Use the folder " + BackendProjectFolders.shortPath(args["folder"].string ?? "") + " for " + (args["projectId"].string.map { PROJProjects.name(for: $0) } ?? "the project") + " on this Mac"
            case "project_folders.set_base":
                sentence = "Make new project folders in " + BackendProjectFolders.shortPath(args["folder"].string ?? "") + " on this Mac"
            default: sentence = "Read project information"
            }
            try await joins.prepareNative(caller, tier: tier, sentence: sentence, ownerMustAnswer: tier != .read)
        }
        let ids = try await BackendPROJMCP.register(server: mcp, registry: projects, ownerID: owner, authorize: authorize,
            resources: { kind, projectID, caller in
                if kind == "settings" {
                    guard BackendMCPToolNames.permits("project_settings.get", granted: caller.allowedTools) || BackendMCPToolNames.permits("project_settings_get", granted: caller.allowedTools) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot read project settings.")
                    }
                    let items = try await projects.projects().filter { projectID == nil || $0.id == projectID }
                    guard let read = await mcp.registrations().first(where: { $0.0.id == "project_settings.get" }) else {
                        throw NativeRPCError(code: "unavailable", message: "Project settings are unavailable.")
                    }
                    var rows: [NativeRPCValue] = []
                    let explicit = try await projectIdentity(caller)
                    let bound: String?
                    if let explicit { bound = explicit }
                    else if let folder = caller.projectRoot { bound = try await projects.resolve(projectID: nil, folder: folder) }
                    else { bound = nil }
                    for item in items {
                        if let bound, bound != item.id { continue }
                        let reply = try await read.1(caller, .object([.init("projectId", .string(item.id))]))
                        guard !reply.isError, let value = reply.structuredContent else {
                            throw NativeRPCError(code: "unavailable", message: "Project settings returned no data.")
                        }
                        rows.append(value)
                    }
                    return rows
                }
                let sources: [String: (String, String, NativeRPCValue)] = [
                    "tasks": ("tasks.list", "tasks", .object([.init("all_projects", .bool(true))])),
                    "agents": ("tasks.agents", "agents", .object([.init("do", .string("list"))])),
                    "servers": ("servers.look", "servers", .object([])),
                    "task-sources": ("connected_tasks.systems", "systems", .object([])),
                    "routines": ("routines.list", "routines", .object([])),
                    "receiver-sources": ("receiver.sources", "sources", .object([])),
                    "artifacts": ("artifacts.list", "artifacts", .object([]))
                ]
                guard let source = sources[kind] else { throw NativeRPCError.invalidArguments("Choose a project resource type.") }
                guard BackendMCPToolNames.permits(source.0, granted: caller.allowedTools) || BackendMCPToolNames.permits(source.0.replacingOccurrences(of: ".", with: "_"), granted: caller.allowedTools) else {
                    throw NativeRPCError(code: "not-granted", message: "This caller cannot read " + kind + ".")
                }
                guard let registration = await mcp.registrations().first(where: { $0.0.id == source.0 }) else {
                    throw NativeRPCError(code: "unavailable", message: "The " + kind + " reader is unavailable.")
                }
                func read(_ args: NativeRPCValue) async throws -> [NativeRPCValue] {
                    let reply = try await registration.1(caller, args)
                    guard !reply.isError, let value = reply.structuredContent else { throw NativeRPCError(code: "unavailable", message: "The " + kind + " reader returned no data.") }
                    return value[source.1].elements ?? value.elements ?? []
                }
                var rows: [NativeRPCValue]
                if kind == "artifacts" {
                    rows = []
                    guard let artifactProjects else { throw NativeRPCError(code: "unavailable", message: "Artifact folders are unavailable.") }
                    for item in await artifactProjects.list().elements ?? [] {
                        guard let folder = item["path"].string else { continue }
                        if let bound = caller.projectRoot, !TaskProjects.within(folder, bound) { continue }
                        do {
                            _ = try await authority.knownFolder(folder, native: caller)
                            rows += try await read(.object([.init("cwd", .string(folder))]))
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if !["access-denied", "not-granted"].contains((error as? NativeRPCError)?.code ?? "") { throw error }
                        }
                    }
                } else { rows = try await read(source.2) }
                if kind == "receiver-sources" { rows = rows.map { $0["source"].fields == nil ? $0 : $0["source"] } }
                return rows
            })
        try await BackendPROJSettings.register(server: mcp, registry: projects, settings: settings, ownerID: owner, authorize: authorize, projectIdentity: projectIdentity)
        try await BackendProjectFoldersTools.register(server: mcp, folders: folders, ownerID: owner, authorize: authorize)
        let toolIDs = Set(ids + BackendPROJSettings.ids + BackendProjectFoldersTools.ids)
        let registered = await mcp.registrations().filter { toolIDs.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
        let channels = ["project-registry:list", "project-registry:resolve", "project-registry:switch", "project-registry:save", "project-registry:set-lead", "project-settings:get", "project-settings:set",
                        "project-folders:list", "project-folders:use", "project-folders:set-base"]
        for channel in channels {
            let change = ["project-registry:switch", "project-registry:save", "project-registry:set-lead", "project-settings:set", "project-folders:use", "project-folders:set-base"].contains(channel)
            try await registry.register(channel, ownerID: owner, policy: { context in
                if change { try authority.requireLocalUI(context) } else { try authority.authorizeMetadata(context) }
            }) { context, args in
                let value = context.argument(0, in: args)
                switch channel {
                case "project-registry:list": return try await projects.snapshot()
                case "project-registry:resolve": return .string(try await projects.resolve(projectID: value["projectId"].string, folder: value["folder"].string))
                case "project-registry:switch":
                    guard value.has("projectId"), value["projectId"].isNullish || value["projectId"].string != nil else { throw NativeRPCError.invalidArguments("Choose a project or All projects.") }
                    return try await projects.select(value["projectId"].string)
                case "project-registry:save":
                    let item = try JSONDecoder().decode(PROJProject.self, from: value.encodedJSON())
                    return try await projects.save(item)
                case "project-registry:set-lead":
                    return try await projects.setLead(projectID: try value["projectId"].requireString("project id", nonempty: true),
                                                      lead: value["lead"].string, leadName: value["leadName"].string)
                case "project-settings:get", "project-settings:set":
                    let id = try value["projectId"].requireString("project id", nonempty: true)
                    guard try await projects.projects().contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("Choose a registered project.") }
                    if channel == "project-settings:get" { return await settings.projectSettings(id) }
                    return try await settings.patchProject(id, values: value["values"])
                // Project folders: the Settings row and the project page. "use" and "set-base" come only from his own
                // folder choice in this Mac's window (local UI); the tools above are the AI's way, under approval.
                case "project-folders:list":
                    var fields: [NativeRPCValue.Field] = [.init("terminalDeckFolder", .string(await folders.base().path)),
                        .init("projects", .array(try await folders.rows().map(BackendProjectFoldersTools.value)))]
                    if let problem = await folders.problem() { fields.append(.init("problem", .string(problem))) }
                    return .object(fields)
                case "project-folders:use":
                    return BackendProjectFoldersTools.value(try await folders.use(projectID: try value["projectId"].requireString("project id", nonempty: true),
                                                                                  folder: try value["folder"].requireString("folder", nonempty: true)))
                case "project-folders:set-base":
                    return .object([.init("terminalDeckFolder", .string(try await folders.setBase(try value["folder"].requireString("folder", nonempty: true))))])
                default: throw NativeRPCError.invalidArguments("Choose a project operation.")
                }
            }
        }
        try await root.retain(.init(name: "project-registry", domains: ["project-registry"], ownerID: owner, invokes: Set(channels), sends: [], events: ["project-registry:changed"], stop: {
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner)
        }))
    }
}
