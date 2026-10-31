import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

enum ROUTINESSkillsMCP {
    static func definitions(access: BackendDeckToolsAppAccess, service: BackendROUTINESSkills,
                            currentGrant: @escaping @Sendable (BackendMCPCallContext, Bool) async throws -> BackendROUTINESSkillsGrant,
                            changed: @escaping @Sendable () async throws -> Void) throws -> [BackendDeckToolsDefinition] {
        let rows: [(String, String, BackendMCPTier, String)] = [
            ("skills.versions", "Read saved full-tree versions and Package checks for one installed skill; reading never adopts an update.", .read, #"{"type":"object","properties":{"skill":{"type":"string"},"version":{"type":"string"}},"required":["skill"],"additionalProperties":false}"#),
            ("skills.version_save", "Save a named immutable full-tree version without changing active files.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"label":{"type":"string"},"expectedDigest":{"type":"string"}},"required":["skill","label","expectedDigest"],"additionalProperties":false}"#),
            ("skills.version_adopt", "Deliberately use or roll back to a saved version; preserve edits, refuse protected skills or conflicting AI mirrors.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"version":{"type":"string"},"expectedDigest":{"type":"string"}},"required":["skill","version","expectedDigest"],"additionalProperties":false}"#),
            ("skills.version_check", "Run and save a deterministic Package check pinned to this saved version. Does not execute scripts or test AI behavior.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"version":{"type":"string"}},"required":["skill","version"],"additionalProperties":false}"#),
            ("skills.list", "List installed skills or skills available in the store.", .read, #"{"type":"object","properties":{"installed":{"type":"boolean"},"projectID":{"type":"string"}},"additionalProperties":false}"#),
            ("skills.preview", "Read a skill's instructions, files and the agents using it.", .read, #"{"type":"object","properties":{"skill":{"type":"string"}},"required":["skill"],"additionalProperties":false}"#),
            ("skills.assign", "Give a skill to saved agents. Used from their next run.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"agentIds":{"type":"array","items":{"type":"string"},"minItems":1}},"required":["skill","agentIds"],"additionalProperties":false}"#),
            ("skills.unassign", "Remove a skill from saved agents.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"agentIds":{"type":"array","items":{"type":"string"},"minItems":1}},"required":["skill","agentIds"],"additionalProperties":false}"#),
            ("skills.install", "Install a verified Store skill in a project, or null for Every project.", .alter, #"{"type":"object","properties":{"id":{"type":"string"},"project":{"type":["string","null"]}},"required":["id","project"],"additionalProperties":false}"#),
            ("skills.create", "Create a skill from supplied instructions in a project.", .alter, #"{"type":"object","properties":{"name":{"type":"string"},"summary":{"type":"string"},"category":{"type":"string"},"markdown":{"type":"string"},"project":{"type":["string","null"]}},"required":["name","summary","markdown","project"],"additionalProperties":false}"#),
            ("skills.rename", "Rename a skill that clashes with an AI command. Omit name to choose a free safe name; keeps its files and agent choices.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"},"name":{"type":"string"}},"required":["skill"],"additionalProperties":false}"#),
            ("skills.remove", "Remove a skill folder and its files. Name the skill.", .alter, #"{"type":"object","properties":{"skill":{"type":"string"}},"required":["skill"],"additionalProperties":false}"#)
        ]
        return try rows.map { id, description, tier, schema in
            let wire = id.replacingOccurrences(of: ".", with: "_")
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description, inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description) { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(tier), BackendMCPToolNames.permits(id, granted: context.allowedTools) || BackendMCPToolNames.permits(wire, granted: context.allowedTools) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller cannot use that Skills control.")
                    }
                    let channel = id.replacingOccurrences(of: ".", with: ":")
                    let safe = id == "skills.create" ? args.setting("markdown", .string("[skill instructions]")).setting("summary", .string("[description]")) : args
                    let output = try await BackendROUTINESSkillsBoundary.run(channel: channel, arguments: args, changing: tier != .read, service: service, currentGrant: { approved in
                        guard !context.cancellation.isCancelled else { throw CancellationError() }
                        try Task.checkCancellation()
                        _ = try await access.caller(context)
                        return try await currentGrant(context, approved)
                    }, approve: { plan in
                        let approval = id == "skills.create" ? plan.setting("markdown", .string("[skill instructions]")).setting("summary", .string("[description]")) : plan
                        try await access.authorize(context, id, approval, tier, description, tier != .read)
                    })
                    if tier != .read { try await changed(); try await access.record(context, id, safe, .object([.init("ok", .bool(true))])) }
                    return .value(output)
                }
            }
        }
    }
}

/// The actual factory uses this same projection. Fresh credential restrictions
/// intersect the in-flight filesystem scope; an expansion never broadens it.
enum ROUTINESSkillsCredentialScope {
    static func intersect(_ original: [String], _ limits: [String]) -> [String] {
        var roots: [String] = []
        for original in original.map(BackendROUTINESSkillsScope.canonical) {
            for limit in limits.map(BackendROUTINESSkillsScope.canonical) {
                if TaskProjects.within(original, limit) { roots.append(original) }
                else if TaskProjects.within(limit, original) { roots.append(limit) }
            }
        }
        return Array(Set(roots)).sorted()
    }
    static func grant(caller: BackendDeckCoreSecurityCaller, original: BackendMCPCallContext,
                      filesystem: BackendFilesystemScope, toolGrant: Set<String>?, approved: Bool) throws -> BackendROUTINESSkillsGrant {
        guard caller.tiers.contains(.read), !original.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "The caller no longer has access to Skills.") }
        if caller.kind == .local { return .init(readRoots: nil, writeRoots: nil, identity: "local-owner", localOwner: true) }
        guard !filesystem.unrestricted else { throw NativeRPCError(code: "not-granted", message: "A credential caller cannot inherit the Mac owner's skill access.") }
        var reads = filesystem.readRoots.map(\.path)
        var writes = approved && caller.tiers.contains(.alter) ? filesystem.writeRoots.map(\.path) : []
        if let folders = caller.folders { reads = intersect(reads, folders); writes = intersect(writes, folders) }
        if let originalRoot = original.projectRoot {
            reads = intersect(reads, [originalRoot]); writes = intersect(writes, [originalRoot])
        }
        let fingerprint = NativeRPCValue.object([
            .init("kind", .string(caller.kind.rawValue)),
            .init("session", caller.sessionID.map(NativeRPCValue.string) ?? .null),
            .init("key", caller.keyID.map(NativeRPCValue.string) ?? .null),
            .init("device", caller.deviceID.map(NativeRPCValue.string) ?? .null),
            .init("folders", caller.folders.map { .array($0.sorted().map(NativeRPCValue.string)) } ?? .null),
            .init("projectRoot", caller.projectRoot.map(NativeRPCValue.string) ?? .null),
            .init("originalRoot", original.projectRoot.map(NativeRPCValue.string) ?? .null),
            .init("tasks", .bool(caller.tasks)),
            .init("tools", .array(original.allowedTools.sorted().map(NativeRPCValue.string))),
            .init("currentTools", toolGrant.map { .array($0.sorted().map(NativeRPCValue.string)) } ?? .null),
            .init("tiers", .array(caller.tiers.map(\.rawValue).sorted().map(NativeRPCValue.string)))
        ]).compact
        return .init(readRoots: reads, writeRoots: writes, identity: fingerprint,
                     projectRoot: caller.projectRoot, agentChangesAllowed: caller.kind != .key || caller.tasks,
                     mutationsAllowed: caller.tiers.contains(.alter))
    }
}

extension NativeCompositionProduction {
    /// The skill folders every project shares (CONNECT-SKILLS, 11 Oct): the person's own, Terminal Deck's starter
    /// set shipped in the app, and Codex's own bundled ones (Codex's, so labelled Codex, never Terminal Deck).
    /// Both built-in roots are read-only on the Skills page.
    static func skillRoots(home: URL, codexHome: URL, builtIn: URL? = BackendBuiltInSkills.folder()) -> [BackendROUTINESSkills.Root] {
        var roots: [BackendROUTINESSkills.Root] = [.init(folder: home.appendingPathComponent(".claude/skills"), source: "Every project · .claude/skills")]
        if let builtIn { roots.append(.init(folder: builtIn, source: BackendBuiltInSkills.source, builtIn: true)) }
        roots.append(.init(folder: codexHome.appendingPathComponent("skills/.system"), source: BackendBuiltInSkills.codexSource, builtIn: true))
        return roots
    }

    /// Call once after installPROJProjects and the existing task/community owners.
    func installROUTINESSkills(access: BackendDeckToolsAppAccess,
                              currentSessionCaller: @escaping @Sendable (BackendMCPCallContext) async throws -> BackendDeckCoreSecurityCaller,
                              guardedChangeSkill: @escaping @Sendable (String, String, Bool, String?, BackendROUTINESSkillsEffectGuard) async throws -> NativeRPCValue) async throws {
        let owner = "native.routines-skills", root = self.root, joins = self.joins, authority = try wired(self.authority, "authority")
        let home = configuration.homeDirectory
        let liveKeys = try wired(core, "core").keys
        let invoke: @Sendable (String, [NativeRPCValue]) async throws -> NativeRPCValue = { channel, arguments in
            // This is a real, current UI metadata reader. MCP effects use the
            // typed owners and explicit credential scope below, never this context.
            try await root.registry.invoke(channel, context: authority.localContext(), arguments: arguments)
        }
        let installer = try wired(clients, "clients").community as? BackendOSStoreInstaller
        guard let taskConfiguration = taskView?.config else { throw NativeRPCError(code: "unavailable", message: "The task owner is unavailable for Skills.") }
        let dependencies = BackendROUTINESSkills.Dependencies(projects: {
            let state = try await invoke("project-registry:list", [])
            return try (state["projects"].elements ?? []).map { try JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
        }, profiles: {
            try await taskConfiguration.allAgents()
        }, catalogue: { try await invoke("community:list", []) }, install: { id, choice in
            try await invoke("community:install", [.string(id), choice])
        }, remove: { id in try await invoke("community:remove", [.string(id)]) }, ownedSkill: { folder in
            guard let installer else { return nil }
            return await installer.installed().first { row in
                (row["writes"].elements ?? []).contains { $0["path"].string == folder && $0["kind"].string == "dir" }
            }
        }, changeSkill: { id, skill, assigned, projectRoot in
            let input = NativeRPCValue.object([.init("id", .string(id)), .init("skillChange", .object([.init("skill", .string(skill)), .init("assigned", .bool(assigned)), .init("projectRoot", projectRoot.map(NativeRPCValue.string) ?? .null)]))])
            let result = try await invoke("tasks:agent-save", [input])
            guard result["ok"].bool == true, let profile = result["state"]["agents"].elements?.first(where: { $0["id"].string == id }) else {
                throw NativeRPCError(code: "save-failed", message: result["message"].string ?? "The agent's skills did not save.")
            }
            return profile
        }, renameOwnedSkill: { folder, name, effect in
            guard let installer else { throw NativeRPCError(code: "unavailable", message: "The Skills installer is unavailable.") }
            try await installer.renameSkillGuarded(folder: folder, name: name, beforeWrite: effect.verify)
        }, guardedInstall: { id, choice, guardAtOwner in
            guard let installer else { throw NativeRPCError(code: "unavailable", message: "The verified Skills installer is unavailable.") }
            return try await installer.installGuarded(id: id, choice: choice, beforeWrite: guardAtOwner.verify)
        }, guardedRemove: { id, guardAtOwner in
            guard let installer else { throw NativeRPCError(code: "unavailable", message: "The verified Skills installer is unavailable.") }
            return try await installer.removeGuarded(id: id, beforeWrite: guardAtOwner.verify)
        }, guardedChangeSkill: guardedChangeSkill)
        let system = configuration.inheritedEnvironment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let service = BackendROUTINESSkills(dependencies: dependencies, sharedRoots: Self.skillRoots(home: home, codexHome: system),
                                            home: home, writable: root.state.ownership != .readOnly,
                                            versions: BackendSkillVersions(root: root.dataRoot.appendingPathComponent("skill-versions"), writable: root.state.ownership != .readOnly))
        let registry = root.registry
        try await BackendROUTINESSkills.register(registry: registry, ownerID: owner, service: service, policy: { context in
            try authority.requireLocalUI(context)
        })
        let definitions = try ROUTINESSkillsMCP.definitions(access: access, service: service, currentGrant: { native, approved in
            let core = try await authority.resolve(native)
            var caller = core.caller
            if caller.kind == .key {
                guard let id = caller.keyID else { throw NativeRPCError(code: "not-granted", message: "The access key identity is unavailable.") }
                caller = await liveKeys.caller(id: id, nameAtArrival: caller.keyName ?? "AI app")
            } else if caller.kind == .session {
                caller = try await currentSessionCaller(native)
                guard caller.sessionID == core.caller.sessionID, caller.machineID == core.caller.machineID else { throw NativeRPCError(code: "not-granted", message: "The current session registration no longer matches this call.") }
            }
            if caller.kind == .local { return try ROUTINESSkillsCredentialScope.grant(caller: caller, original: native, filesystem: .local, toolGrant: core.granted, approved: approved) }
            let rpc = try await authority.rpc(native)
            let fs = try await authority.filesystemScope(rpc)
            return try ROUTINESSkillsCredentialScope.grant(caller: caller, original: native, filesystem: fs, toolGrant: core.granted, approved: approved)
        }, changed: {
            try await registry.publish("skills:changed", arguments: [])   // every listener: the Skills page listens as the app window
        })
        let area = try BackendDeckToolsSupport.area(id: "routines-skills", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: definitions.map { joins.nativePolicy($0) })
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "routines-skills", domains: ["routines-skills"], ownerID: owner, invokes: Set(BackendROUTINESSkills.channels), sends: [], events: ["skills:changed"], stop: {
                await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            throw error
        }
    }
}
