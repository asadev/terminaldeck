import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Installs one facade over the retained TAG/AGS/runtime owners. The caller
    /// supplies actual routines, skills, Hoot, choices and UI destinations.
    /// This returns the v2 reader for the existing agents.profile tool.
    func installAGOPTProfile(dependencies supplied: BackendAGOPTProfileService.Dependencies,
                             validateProject: @escaping @Sendable (BackendAGOPTProfileCall, String) async throws -> Void) async throws -> BackendAGOPTProfileService {
        guard let ags = agentSettings, let view = taskView, let authority, let core else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agent profiles need their existing settings, tasks and approval owners.")
        }
        guard ags.profileService == nil else { throw NativeRPCError(code: "composition-conflict", message: "Agent profiles already have their canonical view owner.") }
        let root = self.root, joins = self.joins, config = ags.configuration, report = self.report
        let require: @Sendable (BackendAGOPTProfileCall, String, Bool) async throws -> Void = { call, id, mutation in
            if case .app(let rpc) = call { try authority.requireLocalUI(rpc); return }
            guard case .tool(let native) = call else { throw CancellationError() }
            let caller = try await authority.resolve(native).caller
            if id == AGTDirectory.hootID {
                guard !mutation, caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "This caller cannot edit Hoot's owner settings.") }; return
            }
            guard let row = try await config.agent(id) else { throw NativeRPCError(code: "missing-agent", message: "That saved agent no longer exists.") }
            switch caller.kind {
            case .local: return
            case .key:
                guard caller.tasks else { throw NativeRPCError(code: "not-granted", message: "This key has no task-agent access.") }
                if caller.folders != nil {
                    guard let folder = row["defaultProject"].string else { throw NativeRPCError(code: "not-granted", message: "This profile needs a project inside the key's folder grant.") }
                    _ = try await authority.knownFolder(folder, native: native)
                }
            case .session:
                guard !mutation, let session = caller.sessionID, try await view.store.bySession(session)?.agentID == id else {
                    throw NativeRPCError(code: "not-granted", message: "A worker can only read its assigned agent profile.")
                }
            case .remote: throw NativeRPCError(code: "not-granted", message: "This transport has no agent-profile grant.")
            }
        }
        let authorize: @Sendable (BackendAGOPTProfileCall, String, NativeRPCValue, String) async throws -> Void = { call, operation, args, summary in
            switch call {
            case .tool(let native): try await joins.prepareNative(native, tier: .alter, sentence: summary, ownerMustAnswer: true)
            case .app(let rpc):
                try authority.requireLocalUI(rpc)
                // FORK-TASKS (11 Oct, real app: "Wake now" was refused with "The agent change was not approved"):
                // the owner pressing Wake in the app's own window IS the approval. It only starts work the owner
                // already gave the agent; every other agent change still asks.
                if args["action"].string == "wake" { return }
                let cancellation = BackendMCPCancellation()
                let outcome = await withTaskCancellationHandler {
                    await core.consent.request(tool: operation, tier: .alter, summary: summary, arguments: BackendAGOPTProfileMCP.safeArguments(args), cancellation: cancellation, origin: "window")
                } onCancel: { cancellation.cancel() }
                try Task.checkCancellation(); try authority.requireLocalUI(rpc)
                guard outcome.granted else { throw NativeRPCError(code: "approval-required", message: "The agent change was not approved.") }
            }
        }
        let profileAccess = BackendAGOPTProfileAccess(require: require, authorize: authorize, rpc: { call in
            switch call { case .app(let rpc): try authority.requireLocalUI(rpc); return rpc
            case .tool(let native): return try await authority.rpc(native) }
        }, visibleRecord: { call, record in
            if case .app = call { return true }
            guard case .tool(let native) = call else { return false }
            let caller = try await authority.resolve(native).caller
            if caller.kind == .local || caller.kind == .key && caller.tasks && caller.folders == nil { return true }
            let taskID = record["task_id"].string ?? record["taskId"].string ?? record["task"]["id"].string ?? record["id"].string
            if let taskID, let task = try await view.store.byID(taskID) {
                if caller.kind == .session {
                    guard let session = caller.sessionID else { return false }
                    return try await view.store.bySession(session)?.id == task.id
                }
                if caller.kind == .key, caller.tasks {
                    do { _ = try await authority.knownFolder(task.project, native: native); return true } catch { return false }
                }
            }
            if caller.kind == .key, caller.tasks, let folder = record["project"].string ?? record["cwd"].string {
                do { _ = try await authority.knownFolder(folder, native: native); return true } catch { return false }
            }
            return false
        }, completeHistory: { call in
            if case .app = call { return true }
            guard case .tool(let native) = call else { return false }
            let caller = try await authority.resolve(native).caller
            return caller.kind == .local || caller.kind == .key && caller.tasks && caller.folders == nil
        })
        let documents = BackendAGOPTProfileDocuments(authority: BackendFilesystemAuthority(scope: { try await authority.filesystemScope($0) }), access: profileAccess,
            currentProfile: { try await config.agent($0) }, managedPath: { try await config.managedInstructionsPath($0) })
        let writer: @Sendable (BackendAGOPTProfileCall, String, String, NativeRPCValue) async throws -> NativeRPCValue = { call, id, field, value in
            try await require(call, id, true)
            var original = NativeRPCValue.object([.init("id", .string(id)), .init("field", .string(field)), .init("value", value)])
            if case .tool(let native) = call {
                let (_, actual) = try await joins.nativeTool(native)
                guard actual["id"].string == id, actual["field"].string == field, actual["value"] == value else { throw NativeRPCError(code: "access-denied", message: "The settings change does not match its exact entered call.") }
                original = actual
            }
            if field == "project", let project = value.string { try await validateProject(call, project) }
            if field == "working_folder", let folder = value.string, case .tool(let native) = call { _ = try await authority.knownFolder(folder, native: native) }
            switch call {
            case .app:
                let revision = try await ags.store.currentRevision()
                // The trusted native field gesture is the owner's exact edit,
                // like tasks:agent-save. MCP retains its one owner card.
                return try await config.saveSettingsFieldOwner(id, field: field, value: value, expectedRevision: revision)
            case .tool(let native):
                let caller = try await authority.resolve(native).caller
                guard !["hooks", "environment_variables"].contains(field) else { throw NativeRPCError(code: "not-granted", message: "Private settings belong to the owner's native editor.") }
                if caller.kind == .key {
                    guard let key = caller.keyID else { throw NativeRPCError(code: "not-granted", message: "This profile change has no current key.") }
                    // One .alter entry charges the existing per-call/rate budget.
                    // The actor applies only safe narrowing before owner review.
                    try await BackendAGOPTProfileApprovalScope.$narrowing.withValue(true) {
                        try await joins.prepareNative(native, tier: .alter, sentence: "Save the permitted narrower agent setting", ownerMustAnswer: false)
                    }
                    let plan = try await config.prepareSettingsFieldChange(request: original, callerKeyID: key, ownerReviewOrdinaryFields: caller.askFirst != false)
                    if plan["needsApproval"].bool == true {
                        let context = try await authority.resolve(native)
                        try await core.control.approveProfileWidening(context: context, arguments: original, summary: "\(caller.keyName ?? "This AI app") asks to \(plan["summary"].string ?? "change this agent").")
                        try await require(call, id, true)
                        guard try await authority.resolve(native).caller.keyID == key else { throw NativeRPCError(code: "not-granted", message: "The key changed while approval was open.") }
                        if field == "project", let project = value.string { try await validateProject(call, project) }
                        if field == "working_folder", let folder = value.string { _ = try await authority.knownFolder(folder, native: native) }
                        _ = try await config.applyApprovedAgentChanges(planID: plan["planId"].requireString("approval plan"), callerKeyID: key)
                    }
                    guard let updated = try await config.agent(id) else { throw NativeRPCError(code: "missing-agent", message: "That agent no longer exists.") }
                    let base = try BackendAGSProfileProjection.settings(updated, defaultProvider: updated["provider"].string ?? "claude")
                    return try await ags.store.controlsView(profile: id, base: base)
                }
                guard caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "This worker cannot change agent settings.") }
                let revision = try await ags.store.currentRevision()
                try await authorize(call, "agents.settings_set", original, "Save the reviewed setting for \(id).")
                try await require(call, id, true)
                return try await config.saveSettingsFieldOwner(id, field: field, value: value, expectedRevision: revision)
            }
        }
        var deps = BackendAGOPTProfileService.Dependencies(dashboard: supplied.dashboard, runs: supplied.runs, budget: supplied.budget,
            skills: supplied.skills, choices: supplied.choices, routines: supplied.routines, perform: supplied.perform, settingsSet: writer,
            instructionsGet: { try await documents.read(call: $0, id: $1, profile: $2) },
            instructionsSet: { try await documents.save(call: $0, id: $1, profile: $2, text: $3, hash: $4, keepMine: $5) }, hoot: supplied.hoot)
        let profiles = try wired(self.sessions, "sessions").profiles
        deps.cliDefaults = { row, provider in
            guard let ai = HootChatProvider(rawValue: provider) else { return .object([]) }
            let account = row["provider"].string == provider ? row["account"].string : nil
            let selected = try await profiles.resolve(sessionProfileID: account, projectPath: row["defaultProject"].string, provider: provider)
            let defaults = BackendHootReadyDefaults.cliDefaults(provider: ai, configDir: selected.configDir)
            return .object([.init("model", .string(defaults.model)), .init("effort", .string(defaults.effort))])
        }
        let service = BackendAGOPTProfileService(configuration: config, ags: ags.store, access: profileAccess, dependencies: deps)
        let owner = "native.agent-profile-controls"
        let definitions = try BackendAGOPTProfileMCP.definitions(service: service)
        let policies = definitions.map { definition -> BackendDeckCoreSecurityToolPolicy in
            let base = joins.nativePolicy(definition)
            return BackendDeckCoreSecurityToolPolicy(tool: base.tool, aliases: base.aliases, audience: base.audience,
                keyRequiresTasks: true, spendsDeviceInput: base.spendsDeviceInput, summary: base.summary,
                precheck: base.precheck, precheckAsync: { args, current in
                    let actionChange = ["wake", "pause", "resume", "duplicate", "reset_sessions", "stop_all", "archive"].contains(args["action"].string ?? "")
                    let mutation = definition.spec.id == "agents.profile_action" ? actionChange : !["agents.settings_get", "agents.instructions_get", "agents.budget_get"].contains(definition.spec.id)
                    if mutation, ["hooks", "environment_variables"].contains(args["field"].string ?? "") {
                        throw NativeRPCError(code: "not-granted", message: "Private settings belong to the owner's native editor.")
                    }
                    try await joins.withPolicyContext(current) {
                        _ = try await joins.contexts.invoke(handler: { native, args in
                            try await require(.tool(native), args["id"].requireString("agent id", nonempty: true), mutation)
                            return .value(.null)
                        }, arguments: args, context: current)
                    }
                    try await base.precheckAsync?(args, current)
                }, escalate: base.escalate,
                ownerMustAnswer: base.ownerMustAnswer, redactArgs: BackendAGOPTProfileMCP.safeArguments, run: base.run)
        }
        let area = try BackendDeckToolsSupport.area(id: "agent-profile-controls", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try await BackendAGOPTProfileChannels.register(registry: root.registry, ownerID: owner, service: service, requireOwner: { try authority.requireLocalUI($0) })
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "agent-profile-controls", domains: ["agent-profile-controls"], ownerID: owner, invokes: Set(BackendAGOPTProfileChannels.channels), stop: { [weak self] in
                await MainActor.run { self?.agentSettings?.profileService = nil }
                await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
                try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
            self.agentSettings?.profileService = service
            return service
        } catch {
            await root.registry.removeOwner(owner); await root.mcp.removeTools(ownerID: owner)
            try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error
        }
    }
}

extension NativeCompositionProduction {
    /// Production join (L5): the profile facade over the task engine's own
    /// dashboard, run history, budget and agent actions. UI-only actions
    /// (settings, show_file, watch…) are handled in the window; MCP gets a plain reply.
    func installAGOPTProfileFromEngine() async throws {
        guard let engine = taskEngine, let view = taskView else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agent profiles need the task engine.")
        }
        let config = view.config
        let deps = BackendAGOPTProfileService.Dependencies(
            dashboard: { try await engine.dashboard(profileID: $0) },
            runs: { try await engine.runs(profileID: $0, days: $1) },
            budget: { try await engine.budget(profileID: $0) },
            perform: { _, id, action, target in
                switch action {
                case "wake": return try await engine.wakeAgent(id)
                case "pause": try await engine.pauseAgent(id); return .object([.init("paused", .bool(true))])
                case "resume": try await engine.resumeAgent(id); return .object([.init("resumed", .bool(true))])
                case "resume_once": try await engine.resumeAgent(id, once: true); return .object([.init("resumed", .bool(true))])
                case "reset_sessions": return try await engine.resetAgentSessions(id)
                case "stop_all": return try await engine.stopAgent(id, reason: "Stopped by you from the agent profile.")
                case "archive": return try await config.setStatus(id, action: "archive")
                default:
                    return .object([.init("action", .string(action)), .init("target", target.map(NativeRPCValue.string) ?? .null),
                                    .init("message", .string("Open the agent's profile in Terminal Deck to do this."))])
                }
            })
        _ = try await installAGOPTProfile(dependencies: deps, validateProject: { _, project in
            guard project == PROJProjects.independentID || PROJProjects.isValidID(project) else {
                throw NativeRPCError.invalidArguments("Choose an existing project.")
            }
        })
    }
}
