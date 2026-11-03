import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// Project setup as app tools (Asad's rule: every feature ships its tools, and every AI gets the same ones).
// project_setup_status: a project's "Setup N%" and what is missing, each with the tool that fixes it.
// project_setup_guide: the New project guide's pages in order, so Hoot can walk a person through them by chat.
// project_setup_open: the same guide on the person's screen, at a page.
// Creating things reuses the tools that already exist (project_registry_save / set_lead, projects_add,
// project_settings_set, tasks_agents, agents_set_role, skills_assign, projects_logo, memory_card_save).

extension NativeCompositionProduction {
    /// Never fatal: a problem here leaves every other tool working.
    func installProjectSetupTools() async {
        do { try await installProjectSetupToolsThrowing() }
        catch { NSLog("[native graph] project setup tools were not installed: %@", error.localizedDescription) }
    }

    private func installProjectSetupToolsThrowing() async throws {
        let owner = "native-composition:project-setup", mcp = root.mcp, registry = root.registry, settings = root.settings
        guard let authority else { return }
        let joins = self.joins
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let steps = text.setting("enum", .array(PROJGuideStep.allCases.map { .string($0.rawValue) }))
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("project_setup.status", .read, "A project's setup score (Setup N%) and its missing parts: what it is, logo, lead, team, skills and the project card. Each missing part names the guide page and the tools that fix it. Omit projectId for every project.",
             schema([("projectId", text)])),
            ("project_setup.guide", .read, "The New project guide's pages in order (name and look, home folder, lead, team, skills, project card, connections, review), why each matters, which are required, and the tools for each. Use it to walk a person through setting up a project by chat. A folder opened on its own is a plain session under Independent, not a project.",
             schema([])),
            // It changes what is on the person's screen, so it is not look-only.
            ("project_setup.open", .act, "Open the New project guide on the person's screen: for a new project (optionally from a folder), or for an existing project at one page.",
             schema([("projectId", text), ("folder", text), ("step", steps)])),
        ]
        let localRead: @Sendable (String) async throws -> NativeRPCValue = { channel in
            try await registry.invoke(channel, context: authority.localContext(), arguments: [])
        }
        let projectList: @Sendable () async throws -> [PROJProject] = {
            try await Self.registeredProjects(registry: registry, context: authority.localContext())
        }
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description, input) in definitions {
            if taken.contains(id) { NSLog("[native graph] project setup tool %@ is already registered by another owner; skipped", id); continue }
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot do that.") }
                _ = try await authority.resolve(caller)
                let projects = try await projectList()
                func find(_ wanted: String) throws -> PROJProject {
                    guard let found = projects.first(where: { $0.id == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }),
                          found.id != PROJProjects.independentID else {
                        throw NativeRPCError.invalidArguments("There is no project called \(wanted). project_registry_list lists them; Independent has no setup.")
                    }
                    return found
                }
                switch id {
                case "project_setup.guide":
                    // Where the built-in project-setup skill is, so any AI can read and follow it.
                    let skill = BackendBuiltInSkills.folder()?.appendingPathComponent(PROJSetup.hootSkill).appendingPathComponent("SKILL.md")
                    return .value(PROJSetup.guideWire().setting("skillFile", skill.map { .string($0.path) } ?? .null))
                case "project_setup.open":
                    let step = args["step"].string.flatMap(PROJGuideStep.init(rawValue:))
                    if let wanted = args["projectId"].string, !wanted.isEmpty {
                        let project = try find(wanted)
                        try await joins.prepareNative(caller, tier: tier, sentence: "Open the New project guide for \(project.name)", ownerMustAnswer: false)
                        await MainActor.run { PROJGuideWindow.open(project: project, step: step) }
                        return .value(.object([.init("opened", .string(project.name)), .init("step", .string((step ?? .name).rawValue))]))
                    }
                    if let folder = args["folder"].string, !folder.isEmpty {
                        guard folder.hasPrefix("/") || folder.hasPrefix("~") else { throw NativeRPCError.invalidArguments("folder must be a full path.") }
                        let path = PROJProjects.normalize(folder)
                        try await joins.prepareNative(caller, tier: tier, sentence: "Open the New project guide for \(path)", ownerMustAnswer: false)
                        await MainActor.run { PROJGuideWindow.open(folder: path) }
                        return .value(.object([.init("opened", .string("New project")), .init("folder", .string(path))]))
                    }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Open the New project guide", ownerMustAnswer: false)
                    await MainActor.run { PROJGuideWindow.open() }
                    return .value(.object([.init("opened", .string("New project"))]))
                default:
                    // A caller bound to one project's folder reads that project only.
                    let bound = caller.projectRoot.map { PROJProjects.resolve(projectID: nil, folder: $0, projects: projects) }
                    var chosen = projects.filter { $0.id != PROJProjects.independentID }
                    if let wanted = args["projectId"].string, !wanted.isEmpty { chosen = [try find(wanted)] }
                    if let bound { chosen = chosen.filter { $0.id == bound } }
                    let agentRows = (try? await localRead("tasks:state"))?["agents"].elements ?? []
                    let agents = agentRows.compactMap { PROJSetupAgent(row: $0, projects: projects) }
                    var rows: [NativeRPCValue] = []
                    for project in chosen {
                        let values = await settings.projectSettings(project.id)
                        let card = (try? await DeckMemory.store.card(.lead(project.id)).text) ?? ""
                        let score = PROJSetup.score(PROJSetup.facts(project: project, settings: values, agents: agents, card: card))
                        rows.append(PROJSetup.statusWire(project: project, score: score))
                    }
                    return .value(.object([.init("projects", .array(rows))]))
                }
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}
