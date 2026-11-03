import Foundation
import TerminalDeckNativeCore

public protocol BackendBrowserToolReach: BackendLaunchCapability {
    func reachesDeviceWindows(_ deviceKey: String) async -> Bool
    func hostHoldsWindows() async -> Bool
}
public struct BackendBrowserToolReachAdapter: BackendBrowserToolReach, Sendable {
    public let readiness: BackendLaunchReadiness
    private let device: @Sendable (String) async -> Bool
    private let host: @Sendable () async -> Bool
    public init(readiness: BackendLaunchReadiness, reachesDeviceWindows: @escaping @Sendable (String) async -> Bool,
                hostHoldsWindows: @escaping @Sendable () async -> Bool) {
        self.readiness = readiness; device = reachesDeviceWindows; host = hostHoldsWindows
    }
    public func reachesDeviceWindows(_ deviceKey: String) async -> Bool { await device(deviceKey) }
    public func hostHoldsWindows() async -> Bool { await host() }
}

/// The actual ready session-tools/project-tools seam. Prepare, compose, spawn,
/// bind and unwind are one transaction; root sends process events here so a
/// fast child exit cannot race binding into a leaked caller/seat/config.
public actor BackendCoordinatedSessionLaunch {
    public struct Result: Sendable {
        public let session: BackendSessionMeta
        public let notices: [String]
        public let browserTools: Bool
        public let projectTools: Bool
        public let implementations: Set<BackendMCPImplementation>
    }
    private let launcher: BackendSessionLauncher
    private let providers: any BackendProviderLaunchResolver
    #if TD_HOST_ACCOUNT_BRIDGE
    private let sessionTools: any BackendHOSTOrdinaryToolLeaseOwner
    private let projectTools: any BackendHOSTProjectToolLeaseOwner
    private let hostMachineID: String
    #else
    private let sessionTools: BackendSessionToolLeases
    private let projectTools: BackendProjectToolComposition
    #endif
    private let reach: any BackendBrowserToolReach
    private var chatSurvival = false
    public func setChatSurvival(_ enabled: Bool) { chatSurvival = enabled }
    private let gate = BackendSessionAsyncGate()
    private var launches = 0
    private var stopped = false
    private var agsBinding: BackendAGSLaunchBinding?
    private var agsChoices: BackendAGSSessionChoices?
    private var agsTabs: [String: String] = [:]
    /// 22 Oct (Reviewer, finding 5): the tabs on the saved restore list (and held to start again). Their choices are
    /// kept when the 512-entry store is full, so a tab not restored yet keeps its model, effort and permission.
    private var agsSavedTabs: (@Sendable () async -> Set<String>)?
    public func setAgentSettingsBinding(_ binding: BackendAGSLaunchBinding, choices: BackendAGSSessionChoices,
                                        savedTabs: (@Sendable () async -> Set<String>)? = nil) throws {
        guard !gate.isBusy, launches == 0, !stopped, agsBinding == nil else { throw BackendSessionFailure.invalidInput("Agent settings launch binding already has an owner.") }
        agsBinding = binding; agsChoices = choices; agsSavedTabs = savedTabs
    }
    public var hasAgentSettingsBinding: Bool { agsBinding != nil }
    private var agentSettingsResolver: (@Sendable (BackendCreateSessionInput, BackendLaunchContext) async throws -> BackendCreateSessionInput)?
    public func setAgentSettingsResolver(_ resolver: @escaping @Sendable (BackendCreateSessionInput, BackendLaunchContext) async throws -> BackendCreateSessionInput) throws {
        guard !gate.isBusy, launches == 0, !stopped, agentSettingsResolver == nil else { throw BackendSessionFailure.invalidInput("The agent settings launch resolver already has an owner or active launch.") }
        agentSettingsResolver = resolver
    }
    /// session-verbs.ts noteNoVerbs: why a session was launched without the browser verbs,
    /// for the "cannot drive" line its agent is told (host-core.ts:1779).
    private var verbs: BackendAppSessionVerbsRegistry?
    public func setVerbsRegistry(_ registry: BackendAppSessionVerbsRegistry?) { verbs = registry }
    public init(launcher: BackendSessionLauncher, providers: any BackendProviderLaunchResolver,
                sessionTools: BackendSessionToolLeases, projectTools: BackendProjectToolComposition,
                reach: any BackendBrowserToolReach) throws {
        for (name, state) in [("provider resolution", providers.readiness), ("session MCP endpoint", sessionTools.readiness),
                              ("project MCP composition", projectTools.readiness), ("browser window reach", reach.readiness)] {
            guard state == .ready else { throw BackendSessionFailure.missingCapability(name) }
        }
        #if TD_HOST_ACCOUNT_BRIDGE
        hostMachineID = "" // Original local constructor preserves its existing identity.
        #endif
        self.launcher = launcher; self.providers = providers; self.sessionTools = sessionTools
        self.projectTools = projectTools; self.reach = reach
    }

    #if TD_HOST_ACCOUNT_BRIDGE
    public init(launcher: BackendSessionLauncher, providers: any BackendProviderLaunchResolver,
                sessionTools: any BackendHOSTOrdinaryToolLeaseOwner, projectTools: any BackendHOSTProjectToolLeaseOwner,
                reach: any BackendBrowserToolReach, machineID: String) throws {
        guard providers.readiness == .ready, sessionTools.readiness == .ready,
              projectTools.readiness == .ready, reach.readiness == .ready else {
            throw BackendSessionFailure.missingCapability("actual hosted tool and provider owners")
        }
        self.launcher = launcher; self.providers = providers; self.sessionTools = sessionTools
        self.projectTools = projectTools; self.reach = reach; hostMachineID = machineID
    }
    #endif
    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext()) async throws -> Result {
        #if TD_HOST_ACCOUNT_BRIDGE
        return try await BackendHOSTMixedLeaseRoute.$hosted.withValue((input.chat == true && chatSurvival && context.deviceBoundary == nil && context.appFenceID == nil && !context.isAppComposed) || BackendHOSTMixedLeaseRoute.eligible(input, context)) {
            try await createRouted(input, context: context)
        }
        #else
        return try await createRouted(input, context: context)
        #endif
    }
    private func createRouted(_ input: BackendCreateSessionInput, context: BackendLaunchContext) async throws -> Result {
        // 18 Oct (#413): preparing a launch's tools (which can wait on MCP or project endpoints) runs outside the gate, so
        // several starts (a tab restore) prepare side by side and an ended session is cleaned up meanwhile. Only
        // spawn-to-bind stays one transaction with process events, so a fast exit still cannot race the binding.
        launches += 1; defer { launches -= 1 }
        var gated = false
        defer { if gated { gate.leave() } }
        guard !stopped else { throw BackendSessionFailure.closed }
        try Task.checkCancellation()
        var requested = input
        // This key comes from the existing authorized saved ledger restore path.
        var ownSavedChoice = false
        if requested.agentSettings == nil, BackendAGSLaunchScope.restoring, let key = requested.tabKey {
            requested.agentSettings = try await agsChoices?.choice(tabKey: key)
            ownSavedChoice = requested.agentSettings != nil
        }
        let resolving = requested
        var input = try await BackendAGSLaunchScope.$ownSavedChoice.withValue(ownSavedChoice) {
            try await agentSettingsResolver?(resolving, context)
        } ?? requested
        let path = try await providers.loginPath()
        let provider = try await providers.resolve(input, loginPath: path)
        // New starts ignore profile, seat and project permission defaults. Restores and live switches keep theirs.
        // R73 (Asad, reaffirmed 2 Nov): every new session from any surface starts in bypass; no start-mode choice.
        if !BackendAGSLaunchScope.restoring, input.replaces == nil,
           let permission = BackendTAGLaunchArguments.newSessionPermission(provider: provider.id) {
            input.permissionMode = permission
            if var settings = input.agentSettings {
                settings.permissionMode = permission
                input.agentSettings = settings
            }
        }
        let originalInput = input
        var resolvedInput = input
        resolvedInput.provider = provider.id
        let forDevice = context.deviceBoundary != nil
        let hostWindows = await reach.hostHoldsWindows()
        let deviceWindows: Bool
        if let device = context.deviceBoundary?.deviceKey { deviceWindows = await reach.reachesDeviceWindows(device) }
        else { deviceWindows = false }
        var browser: BackendPreparedToolLease?
        var agsPrepared: BackendAGSPreparedLaunch?
        var projectServerName: String?
        var project: BackendPreparedProjectTools?
        var created: BackendSessionMeta?
        var notices: [String] = []
        do {
            if let settings = input.agentSettings {
                guard let agsBinding else { throw BackendSessionFailure.missingCapability("the selected-account agent settings launch binding") }
                if context.rememberTab { try await agsChoices?.prepareForLaunch() }
                projectServerName = try await projectTools.agentSettingsServerName(provider: provider.id, cwd: input.cwd, loginPath: path)
                let nativeNames = Set(["deck-control"] + (projectServerName.map { [$0] } ?? []))
                let preparing = input
                agsPrepared = try await BackendAGSLaunchScope.$ownSavedChoice.withValue(ownSavedChoice) {
                    try await agsBinding.prepare(preparing, settings: settings, context: context, nativeServerNames: nativeNames)
                }
                input = agsPrepared!.input; input.agentSettings = nil
                resolvedInput = input
            }
            let settings = agsPrepared?.settings
            // L8 (11 Oct): Codex and Gemini sessions get the same deck-control lease (same token, same grant), handed
            // over in their own config form below (BackendSessionAppTools). Before, they got none of the app's tools.
            if !context.isAppComposed && BackendSessionAppTools.handedTo(provider: provider.id) && settings?.mcpServers["deck-control"] != false && (!forDevice || hostWindows || deviceWindows) {
                do { browser = try await sessionTools.prepareOrdinary(restricting: settings?.allowedTools ?? input.allowedTools, deniedTools: settings?.deniedTools ?? input.deniedTools ?? [], taskID: input.taskID, taskProject: input.taskProject) }
                catch { if agsPrepared != nil { throw error }; notices.append("Browser/session tools are unavailable for this launch because their real endpoint or registered tools are not ready.") }
            } else if !context.isAppComposed {
                notices.append(forDevice && !hostWindows && !deviceWindows
                    ? "The device that started this session cannot serve browser windows."
                    : "This provider has no measured ordinary-session browser MCP override.")
            }
            if !forDevice && !context.isAppComposed && ["claude", "codex", "gemini"].contains(provider.id) && (projectServerName == nil || settings?.mcpServers[projectServerName!] != false) {
                do { project = try await projectTools.prepare(provider: provider.id, cwd: input.cwd, loginPath: path, allowedTools: settings?.allowedTools ?? input.allowedTools, deniedTools: settings?.deniedTools ?? input.deniedTools ?? [], taskID: input.taskID, taskProject: input.taskProject) }
                catch { if agsPrepared != nil { throw error }; notices.append("Project tools could not be supplied; the project's existing agent settings were kept. \(Self.safeError(error))") }
            }
            var environment = context.environmentOverrides
            for (name, value) in project?.environment ?? [:] { environment[name] = value }
            for (name, value) in browser?.environment ?? [:] { environment[name] = value }
            var files = (browser?.readableFiles ?? []) + (project?.readableFiles ?? [])
            // The same lease for every AI, translated by its CLI's adapter (BackendSessionAppTools).
            var browserArguments: [String] = []
            if let lease = browser {
                let handover = BackendSessionAppTools.handover(provider: provider.id, leaseArguments: lease.arguments, leaseFiles: lease.readableFiles,
                    taskSession: input.taskID != nil, environment: environment, inAgentSettings: agsPrepared != nil)
                browserArguments = handover.arguments
                for (name, value) in handover.environment { environment[name] = value }
                files += handover.readableFiles
                if let problem = handover.problem { notices.append(problem) }
            }
            // TRUTH-B: the MCP page's choices (server off, tool off, per AI, per agent), and its servers for Codex
            // and Gemini too (they were Claude Code's only). Never written into an AI's own config.
            if !context.isAppComposed, BackendSessionAppTools.handedTo(provider: provider.id) {
                let geminiDefaults = environment["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                let page = BackendMcpPolicy.launch(provider: provider.id, cwd: input.cwd, agentID: input.agentProfileID ?? input.agentInstructions,
                    agentSettings: agsPrepared != nil, home: NSHomeDirectory(), inherited: ProcessInfo.processInfo.environment,
                    environment: environment, privateDirectory: geminiDefaults ?? BackendMcpPolicy.launchDirectory())
                browserArguments += page.arguments
                for (name, value) in page.environment { environment[name] = value }
                files += page.readableFiles
            }
            let boundary = context.deviceBoundary.map {
                BackendDeviceBoundary(deviceKey: $0.deviceKey, folder: $0.folder,
                    writableDirectories: $0.writableDirectories, readableFiles: $0.readableFiles + files,
                    readOnlyProjects: $0.readOnlyProjects)
            }
            #if TD_HOST_ACCOUNT_BRIDGE
            var currentHostLeases: [UUID] = []
            if BackendHOSTMixedLeaseRoute.hosted {
                if let browser { currentHostLeases.append(browser.id) }
                if let project { currentHostLeases.append(project.id) }
                if let agsPrepared { currentHostLeases.append(agsPrepared.hostLeaseID) }
            }
            guard context.hostMachineID.isEmpty || context.hostMachineID == hostMachineID else {
                throw BackendSessionFailure.invalidInput("This launch transaction belongs to a different actual machine.")
            }
            #else
            let currentHostLeases = context.hostLeaseIDs
            let hostMachineID = context.hostMachineID
            #endif
            let composed = BackendLaunchContext(deviceBoundary: boundary, appFenceID: context.appFenceID,
                extraArguments: context.extraArguments + browserArguments + (project?.arguments ?? []),
                rememberTab: context.rememberTab, environmentOverrides: environment,
                removeEnvironment: context.removeEnvironment, isAppComposed: context.isAppComposed,
                beforeExposure: context.beforeExposure, requiresInAppOwner: context.requiresInAppOwner || browser != nil || project != nil || agsPrepared != nil, hostLeaseIDs: currentHostLeases, hostMachineID: hostMachineID)
            var launchContext = composed
            if let agsPrepared, let agsBinding {
                var generated: NativeRPCValue = .object([])
                if let browser { generated = try await sessionTools.agentSettingsConfiguration(browser.id) }
                if let project {
                    let projectConfig = try await projectTools.agentSettingsConfiguration(project.id)
                    for field in projectConfig.fields ?? [] {
                        guard generated[field.key].isNullish else { throw BackendSessionFailure.invalidInput("Native MCP server names conflict.") }
                        generated = generated.setting(field.key, field.value)
                    }
                }
                launchContext = try await agsBinding.stage(agsPrepared, generatedServers: generated, context: composed, originalInput: originalInput)
            }
            let finalContext = launchContext
            let finalInput = resolvedInput
            await gate.enter(); gated = true
            guard !stopped else { throw BackendSessionFailure.closed }
            try Task.checkCancellation()
            let session = try await BackendAGSLaunchScope.$prepared.withValue(agsPrepared) {
                try await launcher.create(finalInput, context: finalContext)
            }
            created = session
            if let browser {
                #if TD_HOST_ACCOUNT_BRIDGE
                try await sessionTools.bind(browser.id, sessionID: session.id, machineID: hostMachineID)
                #else
                try await sessionTools.bind(browser.id, sessionID: session.id)
                #endif
            }
            if let project { try await projectTools.bind(project.id, sessionID: session.id) }
            if let agsPrepared, let agsBinding {
                try await agsBinding.bind(agsPrepared, session: session)
                if let tab = session.tabKey {
                    let held = Set(launcher.manager.list().compactMap(\.tabKey)).union(agsTabs.values).union([tab])
                        .union(await agsSavedTabs?() ?? [])
                    try await agsChoices?.save(tabKey: tab, settings: agsPrepared.settings, keeping: held)
                    agsTabs[session.id] = tab
                }
            }
            gated = false; gate.leave()
            var implementations: Set<BackendMCPImplementation> = []
            if let browser { implementations.insert(browser.implementation) }
            if let project { implementations.insert(project.implementation) }
            // host-core.ts noVerbs: an ordinary session that got no browser tools says why.
            if browser == nil, !context.isAppComposed, context.extraArguments.isEmpty, let verbs {
                let reason: BackendAppSessionNoVerbsReason = forDevice && !hostWindows && !deviceWindows ? .device
                    : provider.id != "claude" ? .provider : .endpoint
                await verbs.note(session.id, reason: reason)
            }
            let current = launcher.manager.list().first { $0.id == session.id } ?? session
            return Result(session: current, notices: notices, browserTools: browser != nil,
                projectTools: project != nil, implementations: implementations)
        } catch {
            if let agsPrepared, let agsBinding { await agsBinding.abandon(agsPrepared) }
            if let browser { await sessionTools.abandon(browser.id) }
            if let project { await projectTools.abandon(project.id) }
            if let created { launcher.manager.kill(created.id); await launcher.removed(created.id, reason: .stopped) }
            throw error
        }
    }

    public func processExited(_ id: String) async {
        await gate.enter(); defer { gate.leave() }
        await sessionTools.release(sessionID: id); await projectTools.release(sessionID: id)
        await launcher.processExited(id)
    }
    public func removed(_ id: String, reason: BackendRemovalReason) async {
        await gate.enter(); defer { gate.leave() }
        // Revoke immediately even when it is a replacement. The replacement's
        // new token/key is independent, while its tab/conversation ids persist.
        await sessionTools.release(sessionID: id); await projectTools.release(sessionID: id)
        await verbs?.forget(id)
        if let tab = agsTabs.removeValue(forKey: id), reason != .replaced,
           !agsTabs.values.contains(tab) { try? await agsChoices?.remove(tabKey: tab) }
        await launcher.removed(id, reason: reason)
    }
    public func stop() async -> Bool {
        await gate.enter(); defer { gate.leave() }
        stopped = true
        let ids = launcher.manager.list().map(\.id)
        launcher.manager.beginShutdown()
        await sessionTools.stop(); await projectTools.stop()
        let drained = await launcher.manager.drain()
        if drained { for id in ids { await launcher.processExited(id) } }
        return drained
    }


    private static func safeError(_ error: any Error) -> String {
        (error as? BackendSessionFailure)?.localizedDescription ?? "The registered project tool source could not complete launch composition."
    }
}
