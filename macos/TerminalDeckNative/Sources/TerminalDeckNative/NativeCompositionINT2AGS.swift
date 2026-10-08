import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeCompositionINT2AGS: Sendable {
    let store: BackendAGSStore
    let runner: BackendAGSHookRunner
    let events: BackendAGSEvents
    let alerts: BackendAGSAlerts
    let configuration: BackendTaskConfiguration
    let baseProfile: @Sendable (String) async throws -> AGSAgentSettings
}

extension NativeCompositionProduction {
    /// One encrypted extension owner beside TAG's canonical configuration.
    func installINT2AGS(configuration config: BackendTaskConfiguration) async throws -> NativeCompositionINT2AGS {
        guard SourceNamespace.agentSettingsEnabled else {
            throw NativeRPCError(code: "unavailable", message: "Agent settings are not enabled in this release.")
        }
        guard agentSettings == nil else { throw NativeRPCError(code: "composition-conflict", message: "Agent settings already have an owner.") }
        let root = self.root, authority = self.authority!, core = self.core!, report = self.report
        let lifecycle = sessions.lifecycle
        let alertChanges = BackendAGSAlertSettingsChanges()
        let store = BackendAGSStore(persistence: try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote"), ownership: root.state.ownership),
            cipher: await sessions.agentSettingsCipher(), supportedAppEvents: Set(AGSCapabilities.appEvents), changed: {
                do { try await alertChanges.saved() }
                catch { report("Waiting-alert hooks were paused because their saved settings could not be read.") }
                try? await root.registry.publish("ags:changed", arguments: [], ownerID: BackendCompositionRoot.appOwnerID)
            })
        try await store.start(); try await config.bindAGS(store)
        let launch = BackendINT2AGSLaunch(store: store, configuration: config,
            defaultProvider: { await root.state.getPreferences()["defaultProvider"].string ?? "claude" },
            taskProfile: { [weak self] id in
                guard let view = await MainActor.run(body: { self?.taskView }) else { throw NativeRPCError(code: "unavailable", message: "The canonical task profile reader is not installed.") }
                return try await view.store.byID(id)?.agentID
            })
        try await sessions.launch.setAgentSettingsResolver { input, context in try await launch.resolve(input, context: context) }
        let runner = BackendAGSHookRunner(execute: BackendAGSHookRunner.local(workingFolder: root.dataRoot.path))
        let events = BackendAGSEvents(store: store, runner: runner, problem: { message in report(message) })
        let alerts = BackendAGSAlerts(snapshot: { await lifecycle.acceptedAlertBaseline() },
            currentStatus: { await lifecycle.acceptedAlertStatus(sessionID: $0) },
            hooksEnabled: { try await store.defaults().hooks.contains { $0.enabled && $0.event == "alert.raised" } },
            accepted: { alert in await events.alert(id: alert.id) }, problem: { message in report(message) })
        await alertChanges.bind(alerts)
        root.events.bind(agsAlerts: alerts)
        let base: @Sendable (String) async throws -> AGSAgentSettings = { id in
            guard let profile = try await config.agent(id), profile["status"].string == "active" else {
                throw NativeRPCError(code: "unavailable", message: "Choose an active existing task-agent profile.")
            }
            return try BackendAGSProfileProjection.settings(profile, defaultProvider: await root.state.getPreferences()["defaultProvider"].string ?? "claude")
        }
        let owner = "native.agent-settings", installed = NativeCompositionINT2AGS(store: store, runner: runner, events: events, alerts: alerts, configuration: config, baseProfile: base)
        do {
            try await alerts.start()
            try await BackendAGSChannels.register(registry: root.registry, ownerID: owner, store: store, runner: runner,
                baseProfile: base, requireOwner: { try authority.requireLocalUI($0) }, authorize: { rpc, channel, safe in
                    try authority.requireLocalUI(rpc); try Task.checkCancellation()
                    let cancellation = BackendMCPCancellation()
                    let outcome = await withTaskCancellationHandler {
                        await core.consent.request(tool: channel == "ags:hook-test" ? "agents.hook_test" : "agents.settings_change",
                            tier: channel == "ags:hook-test" ? .act : .alter,
                            summary: channel == "ags:hook-test" ? "Run this exact saved Terminal Deck hook once." : "Save these reviewed agent settings. Enabled hooks may run commands on future accepted events.",
                            arguments: safe, cancellation: cancellation, origin: "window")
                    } onCancel: { cancellation.cancel() }
                    try Task.checkCancellation(); try authority.requireLocalUI(rpc)
                    guard outcome.granted else { throw NativeRPCError(code: "approval-required", message: "The agent settings action was not approved.") }
                }, saveProfile: { rpc, id, settings, revision in
                    try authority.requireLocalUI(rpc)
                    _ = try await config.saveSettingsForProfile(id, settings: settings, expectedRevision: revision)
                }, defaultProvider: { await root.state.getPreferences()["defaultProvider"].string ?? "claude" })
            try await root.registry.register("ags:session-settings", ownerID: owner, policy: { try authority.requireLocalUI($0) }) { rpc, args in
                try authority.requireLocalUI(rpc); try rpc.requireCount(args, 1...1)
                let provider = try args[0].requireString("selected coding agent", nonempty: true)
                guard AGSCapabilities.providers.contains(provider) else { throw NativeRPCError(code: "unavailable", message: "Agent settings are not supported by this coding agent.") }
                let defaults = try await store.defaults().providers[provider]
                let resolved = try BackendAGSPolicy.resolve(defaults: defaults, profile: AGSAgentSettings(provider: provider))
                return .object([.init("revision", .number(Double(try await store.currentRevision()))), .init("settings", try BackendAGSCodec.value(resolved))])
            }
            try await root.retain(.init(name: "agent-settings", domains: ["agent-settings"], ownerID: owner,
                invokes: Set(BackendAGSChannels.channels).union(["ags:session-settings"]), events: ["ags:changed"], stop: {
                    await alertChanges.bind(nil)
                    root.events.bind(agsAlerts: nil)
                    await alerts.stop()
                    await events.stop(); await root.registry.removeOwner(owner)
                }))
            agentSettings = installed; return installed
        } catch {
            await alertChanges.bind(nil)
            root.events.bind(agsAlerts: nil)
            await alerts.stop()
            await events.stop(); await root.registry.removeOwner(owner); throw error
        }
    }

    func installINT2AGSTools(access: BackendDeckToolsAppAccess) async throws {
        guard SourceNamespace.agentSettingsEnabled else { return }
        guard let ags = agentSettings, let view = taskView else {
            throw NativeRPCError(code: "composition-incomplete", message: "Agent settings tools need their retained settings and task owners.")
        }
        let root = self.root, authority = self.authority!, joins = self.joins, config = ags.configuration
        let require: @Sendable (BackendMCPCallContext, String?, Bool) async throws -> Void = { native, id, mutation in
            let caller = try await authority.resolve(native).caller
            if let id { _ = try await ags.baseProfile(id) }
            switch caller.kind {
            case .local: return
            case .key:
                guard caller.tasks, let id, let profile = try await config.agent(id) else { throw NativeRPCError(code: "not-granted", message: "This key can only read or narrow its existing permitted task profiles.") }
                if caller.folders != nil {
                    guard let folder = profile["defaultProject"].string, !folder.isEmpty else { throw NativeRPCError(code: "not-granted", message: "This profile needs an explicit project inside the key's existing folder grant.") }
                    _ = try await authority.knownFolder(folder, native: native)
                }
            case .session:
                guard !mutation, let id, let session = caller.sessionID, let task = try await view.store.bySession(session), task.agentID == id else {
                    throw NativeRPCError(code: "not-granted", message: "A worker can only read the settings of its assigned task profile.")
                }
            case .remote: throw NativeRPCError(code: "unavailable", message: "This remote transport has not negotiated agent settings. Open their private editor on the owner Mac.")
            }
        }
        let scope = BackendAGSAccess(require: require, baseProfile: ags.baseProfile, saveProfile: { native, id, settings, revision in
            let caller = try await authority.resolve(native).caller
            _ = try await config.saveSettingsForProfile(id, settings: settings, expectedRevision: revision, narrowOnly: caller.kind == .key)
        })
        let definitions = try BackendAGSMCP.definitions(store: ags.store, hooks: ags.runner, access: access, scope: scope)
        guard Set(definitions.map { $0.spec.id }) == Set(BackendAGSMCP.toolIDs) else { throw NativeRPCError(code: "composition-incomplete", message: "Agent settings need all three original tool definitions.") }
        let policies = definitions.map { definition -> BackendDeckCoreSecurityToolPolicy in
            let base = joins.nativePolicy(definition)
            return BackendDeckCoreSecurityToolPolicy(tool: base.tool, aliases: base.aliases, audience: base.audience,
                keyRequiresTasks: base.keyRequiresTasks, spendsDeviceInput: base.spendsDeviceInput, summary: base.summary,
                precheck: base.precheck, precheckAsync: { args, current in
                    try await joins.withPolicyContext(current) {
                        _ = try await joins.contexts.invoke(handler: { native, args in
                            try await require(native, args["profile"].string, definition.spec.id != "agents.settings_read")
                            return .value(.null)
                        }, arguments: args, context: current)
                    }
                    try await base.precheckAsync?(args, current)
                }, escalate: base.escalate, ownerMustAnswer: base.ownerMustAnswer, redactArgs: { args in
                    args.removing("settings").removing("defaults").removing("hook")
                }, run: base.run)
        }
        let owner = "native.agent-settings-tools"
        let area = try BackendDeckToolsSupport.area(id: "agent-settings", definitions: definitions)
        let bundle = try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: definitions.map(\.catalogueMetadata), policies: policies)
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "agent-settings-tools", domains: ["agent-settings-tools"], ownerID: owner, invokes: [], stop: {
                await root.mcp.removeTools(ownerID: owner); try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch { await root.mcp.removeTools(ownerID: owner); try? joins.replaceContributions(owner: owner, [], policiesWrapped: true); throw error }
    }
}
