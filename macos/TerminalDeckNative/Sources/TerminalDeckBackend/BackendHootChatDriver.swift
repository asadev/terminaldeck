import Foundation
import TerminalDeckNativeCore

/// Reuses the app's account, records fence and MCP composition without a PTY.
public actor BackendHootChatDriver: BackendCopilotSessionDriving, BackendHootChatToolRequirementsReceiving, BackendHOOTSIMConversationOptions {
    private let providers: BackendNativeProviders
    private let sessions: BackendCompositionSessions
    private let confinement: BackendMacConfinement?
    private let chat: BackendHootChatStore
    private let readyDefaults: BackendHootReadyDefaults?
    private let launchBinding: BackendAGSLaunchBinding?
    private let defaultProjectPath: String?
    private let exposure: @Sendable (String) -> Void
    private let policy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])?
    private let taskID: String?
    private var liveID: String?
    private var expectedTools: Set<String> = []
    private var preparedTools: BackendCopilotSessionTools?
    private var livePrepared: BackendAGSPreparedLaunch?
    private var liveProfileID: String?
    /// The account Hoot's running AI was launched with (item 74: its plan limits are that account's); nil while stopped.
    public var liveAccountID: String? { liveID == nil ? nil : liveProfileID }
    private var liveSettings: AGSAgentSettings?
    private var liveProjectPath: String?
    private let ownerContext: (@Sendable () throws -> NativeRPCContext)?
    private var changingOptions = false
    public nonisolated let hidesAtSpawn = true
    public init(providers: BackendNativeProviders, sessions: BackendCompositionSessions,
                confinement: BackendMacConfinement?, chat: BackendHootChatStore,
                exposure: @escaping @Sendable (String) -> Void,
                policy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])? = nil,
                readyDefaults: BackendHootReadyDefaults? = nil,
                launchBinding: BackendAGSLaunchBinding? = nil, defaultProjectPath: String? = nil,
                ownerContext: (@Sendable () throws -> NativeRPCContext)? = nil, taskID: String? = nil) {
        self.taskID = taskID
        self.ownerContext = ownerContext
        self.providers = providers; self.sessions = sessions; self.confinement = confinement
        self.chat = chat; self.exposure = exposure
        self.policy = policy
        self.readyDefaults = readyDefaults
        self.launchBinding = launchBinding; self.defaultProjectPath = defaultProjectPath
    }
    /// HOOTFIX: Hoot's own profile/sign-in reads run under the caller's
    /// original request context; with none (phone frame, task brief, idle
    /// liveness) under the app owner context supplied by composition.
    private nonisolated func scoped<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        #if TD_HOST_ACCOUNT_BRIDGE
        guard BackendHOSTProfileScope.context == nil, NativeCompositionCallContext.rpc == nil,
              let owner = try? ownerContext?() else { return try await operation() }
        return try await BackendHOSTProfileScope.withContext(owner, operation: operation)
        #else
        return try await operation()
        #endif
    }
    public func hasClaude() async throws -> Bool { try await scoped { try await self.hasClaudeScoped() } }
    private func hasClaudeScoped() async throws -> Bool {
        if let folder = liveProjectPath ?? defaultProjectPath,
           let selected = try await readySelection(projectPath: folder), !selected.ready {
            throw NativeRPCError(code: "sign-in-required", message: HootReadyDefaults.signInLine + " Open settings")
        }
        let path = try await providers.loginPath()
        return await providers.resolveBinary(chat.provider.rawValue, path: path).runnable != nil
    }
    public func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        try await scoped { try await self.resolveProfileScoped(projectPath: projectPath) }
    }
    private func resolveProfileScoped(projectPath: String) async throws -> BackendAccountProfile {
        if let selection = try await readySelection(projectPath: projectPath) {
            guard selection.ready, let profile = selection.profile else {
                throw NativeRPCError(code: "sign-in-required", message: HootReadyDefaults.signInLine + " Open settings")
            }
            return profile
        }
        // ACCOUNTS: Hoot's own row (seat "orchestrator"), not just the project's account.
        return try await BackendHootAccountSeat.resolve(sessions: sessions, projectPath: projectPath, provider: chat.provider.rawValue)
    }
    public func toolRequirements(_ tools: BackendCopilotSessionTools?) async {
        expectedTools = Set(tools?.tools.map(\.wire) ?? [])
        preparedTools = tools
    }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) {
        let answer = try await scoped { try await self.signInScoped(profile: profile) }
        return (answer.state, answer.account, answer.plan)
    }
    private struct SignInAnswer: Sendable { let state: String, account: String?, plan: String? }
    private func signInScoped(profile: BackendAccountProfile) async throws -> SignInAnswer {
        #if TD_HOST_ACCOUNT_BRIDGE
        let original = try BackendHOSTProfileScope.requireCurrent()
        let result = try await sessions.signIn.invoke("profiles:signin", args: [.string(profile.id)], context: original)
        return .init(state: try result["state"].requireString("original sign-in state"), account: result["account"].string, plan: result["plan"].string)
        #else
        let result = await sessions.signIn.read(profile)
        return .init(state: result.state, account: result.account, plan: result.plan)
        #endif
    }
    public func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        try await scoped {
            try await BackendAGSLaunchBinding.retryingSelection {
                try await self.startUnscoped(input, fence: fence, extraArguments: extraArguments)
            }
        }
    }
    private func startUnscoped(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        #if TD_HOST_ACCOUNT_BRIDGE
        let taskHost = await sessions.chatHost
        let hostedTask = taskID != nil && taskHost?.hello.chatService == 1
        return try await BackendHOSTMixedLeaseRoute.$hosted.withValue(hostedTask) {
            try await startRouted(input, fence: fence, extraArguments: extraArguments)
        }
        #else
        return try await startRouted(input, fence: fence, extraArguments: extraArguments)
        #endif
    }
    private func startRouted(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        try Task.checkCancellation()
        guard !changingOptions else { throw NativeRPCError(code: "busy", message: "Hoot is changing this chat's options. Keep the draft and send again.") }
        var launchInput = input
        var context = BackendLaunchContext(appFenceID: fence?.id, extraArguments: extraArguments,
            rememberTab: false, isAppComposed: true, requiresInAppOwner: true)
        var prepared: BackendAGSPreparedLaunch?
        var reservedAccount: BackendAccountLaunch?
        var selectedSettings: AGSAgentSettings?
        var selectedSystemProfile = true
        do {
            if HootReadyDefaults.enabled(), let readyDefaults {
                let selected = try await readyDefaults.read(projectPath: input.cwd, forConversation: true)
                guard selected.ready, selected.provider == chat.provider, let profile = selected.profile,
                      input.profileId == profile.id else {
                    throw NativeRPCError(code: "conflict", message: "Hoot's selected AI or account changed. Keep the draft and try again.")
                }
                selectedSettings = selected.launchSettings
                await chat.setPermissionPolicy(selected.permissionPolicy)
                selectedSystemProfile = profile.system
                launchInput.provider = selected.provider.rawValue; launchInput.profileId = profile.id
                // Blank settings retain the CLI defaults and the original Hoot
                // MCP/layer path; no extra help/config probe is needed then.
                let chosen = selected.launchSettings
                // SETTINGS-TRUTH line 75: Fast mode alone (model, effort and permission on defaults) changes the launch too.
                if chosen.model != nil || chosen.effort != nil || chosen.permissionMode != nil || chosen.fastMode != nil {
                    guard let launchBinding else { throw BackendSessionFailure.missingCapability("Hoot's selected-account private launch binding") }
                    let generated: NativeRPCValue
                    if let tools = preparedTools {
                        guard let bytes = try BackendAccountFiles.boundedRead(URL(fileURLWithPath: tools.configPath), maximum: 2 * 1024 * 1024) else {
                            throw NativeRPCError(code: "unavailable", message: "Hoot's actual prepared MCP configuration is missing.")
                        }
                        generated = try NativeRPCValue.parseJSON(bytes)["mcpServers"].requireObject("Hoot MCP servers")
                    } else {
                        guard expectedTools.isEmpty else { throw NativeRPCError(code: "unavailable", message: "Hoot's required tools have no prepared lease.") }
                        generated = .object([])
                    }
                    // Account facts are measured before applying the separate
                    // records fence. The final launch still receives that fence.
                    let measuredContext = BackendLaunchContext(extraArguments: extraArguments, rememberTab: false,
                        isAppComposed: true, requiresInAppOwner: true)
                    let settings = selected.launchSettings
                    let ready = try await launchBinding.prepare(launchInput, settings: settings, context: measuredContext,
                        nativeServerNames: Set(generated.fields?.map(\.key) ?? []))
                    prepared = ready
                    let staged = try await launchBinding.stage(ready, generatedServers: generated,
                        context: measuredContext, originalInput: launchInput)
                    launchInput = ready.input
                    context = BackendLaunchContext(appFenceID: fence?.id, extraArguments: staged.extraArguments,
                        rememberTab: false, environmentOverrides: staged.environmentOverrides,
                        removeEnvironment: staged.removeEnvironment, isAppComposed: true, requiresInAppOwner: true)
                }
            }
            let path = try await providers.loginPath(), provider = try await providers.resolve(launchInput, loginPath: path)
            guard let policy else { throw BackendSessionFailure.missingCapability("the shared headless model/tool/permission policy resolver") }
            var policyArguments = try await policy(launchInput, provider, context)
            if selectedSettings != nil { policyArguments = Self.withoutReadyScalars(policyArguments) }
            let account = try await sessions.accounts.resolve(launchInput, provider: provider, loginPath: path, context: context)
            reservedAccount = account
            if let prepared { try BackendAGSLaunchBinding.requireAccount(prepared, actual: account, provider: provider) }
            let id = chat.conversationID
            try Task.checkCancellation()
            let contextAccount = account.profile?.id ?? (selectedSystemProfile ? "system" : launchInput.profileId ?? "system")
            try await chat.requireContext(contextAccount + ":" + URL(fileURLWithPath: launchInput.cwd).standardizedFileURL.path)
            let cliID = await chat.cliSessionID
            let plan = try BackendHootChatLaunchPlan(provider: chat.provider, cwd: launchInput.cwd, sessionID: cliID,
                extra: policyArguments + context.extraArguments, expectedTools: expectedTools,
                pageServers: BackendMcpPolicy.hootServers(provider: chat.provider.rawValue, cwd: launchInput.cwd))
            let arguments = plan.arguments
            let confined: BackendConfinedLaunch
            if let confinement {
                do { confined = try await confinement.resolve(command: provider.command, args: arguments, input: launchInput, account: account, context: context) }
                catch let failure as BackendSessionFailure where fence != nil {
                    switch failure {
                    case .unsupported, .missingCapability: throw BackendCopilotSessionFenceLost(reason: failure.localizedDescription)
                    default: throw failure
                    }
                }
            } else {
                guard fence == nil else { throw BackendCopilotSessionFenceLost(reason: "The records fence launcher is unavailable.") }
                confined = .init(command: provider.command, args: arguments)
            }
            if fence != nil && !confined.enforcedBoundary { throw BackendCopilotSessionFenceLost(reason: "The records fence was not held by the headless launch.") }
            var environment = ProcessInfo.processInfo.environment
            for key in account.removeEnvironment.union(confined.removeEnvironment) { environment[key] = nil }
            environment.merge(account.environment) { _, next in next }; environment.merge(confined.environment) { _, next in next }
            environment.merge(context.environmentOverrides) { _, next in next }
            for key in context.removeEnvironment { environment[key] = nil }
            environment["PATH"] = account.path
            environment["CLAUDECODE"] = nil
            let spawn = BackendSpawnSpec(provider: provider.id, command: confined.command, args: confined.args,
                path: account.path, env: environment, profile: account.profile, homeProfileId: account.homeProfileID,
                agentSessionId: cliID, resumed: cliID != nil, hostCwd: confined.hostCwd)
            let meta = BackendSessionMeta(id: id, input: launchInput, spawn: spawn)
            let currentTaskHost = await sessions.chatHost
            if taskID == nil || currentTaskHost == nil {
                if let prepared, let launchBinding { try await launchBinding.bind(prepared, session: meta) }
            }
            // The MCP lease is bound by the existing runtime before any user input.
            exposure(id)
            try Task.checkCancellation()
            if let taskID, let host = await sessions.chatHost, host.hello.chatService == 1 {
                launchInput.chat = true; launchInput.origin = .copilot; launchInput.originRunId = taskID
                launchInput.agentSettings = selectedSettings; launchInput.permissionMode = selectedSettings?.permissionMode
                launchInput.teamJob = .init(fromID: "tasks", fromName: "Tasks", agentID: "hoot", agentName: "Hoot", title: "Task " + taskID, taskID: taskID)
                var launch = try BackendHOSTProtocol.Launch(id: id, input: launchInput, spawn: spawn, inheritedEnvironment: environment, context: context)
                launch.preparedChat = true; launch.chatSetup = plan.setup; launch.ownerIndependent = false
                launch.scope?.hostedTask = true
                launch.accountHandle = account.reservationID
                launch.mcpLeaseIDs = (preparedTools.map { [$0.leaseID] } ?? []) + (prepared.map { [$0.hostLeaseID] } ?? [])
                let hostedMeta = try host.create(launch)
                if let prepared, let launchBinding { try await launchBinding.bind(prepared, session: hostedMeta) }
                try await chat.connectHosted(host, sessionID: hostedMeta.id)
                liveID = hostedMeta.id; livePrepared = prepared; liveProfileID = input.profileId
                liveSettings = selectedSettings; liveProjectPath = input.cwd
                return hostedMeta
            }
            try await chat.attach(.init(command: confined.command, arguments: confined.args, cwd: confined.hostCwd ?? launchInput.cwd, environment: environment, setup: plan.setup))
            try await chat.initialize()
            try Task.checkCancellation()
            #if TD_HOST_ACCOUNT_BRIDGE
            if let external = sessions.accounts as? any BackendHOSTExternalAccountBinding {
                guard let pid = await chat.processPID else { throw BackendSessionFailure.closed }
                try await external.bindExternal(account, session: meta, pid: pid)
            } else { try await sessions.accounts.bind(account, session: meta) }
            #else
            try await sessions.accounts.bind(account, session: meta)
            #endif
            liveID = id; livePrepared = prepared; liveProfileID = input.profileId
            liveSettings = selectedSettings; liveProjectPath = input.cwd
            return meta
        } catch {
            await chat.stop()
            if let reservedAccount { await sessions.accounts.abandon(reservedAccount) }
            if let prepared, let launchBinding { await launchBinding.abandon(prepared) }
            throw error
        }
    }
    public func isAlive(_ sessionID: String) async -> Bool {
        (try? await scoped { await self.isAliveScoped(sessionID) }) ?? false
    }
    private func isAliveScoped(_ sessionID: String) async -> Bool {
        guard liveID == sessionID else { return false }
        // #26: asked on every app event the island hears; the kept answer is read again only when Hoot's choices,
        // this chat's options or the account file change (BackendHootReadyDefaults.liveCheck).
        if HootReadyDefaults.enabled(), let readyDefaults, let folder = liveProjectPath,
           let selected = try? await readyDefaults.liveCheck(projectPath: folder),
           Self.deliberateChange(selected, provider: chat.provider, profileID: liveProfileID, settings: liveSettings) {
            // Model, effort, context or permission with the same AI and account: applied silently,
            // folded into the next message (prepareForSend). A different AI/account switches now.
            if selected.provider == chat.provider, selected.preferences.profileID == nil || selected.preferences.profileID == liveProfileID {
                relaunchOnNextSend = true
                return await chat.alive
            }
            await chat.noteEndReason("Hoot's AI, account or model choice changed, so it restarts with the new choice.")
            // Current turns keep their original owner. Only idle changes may
            // stop/rebind the child, and that never sends/resumes a new message.
            if await chat.isBusy { return await chat.alive }
            do {
                if selected.provider != chat.provider { _ = try await readySelection(projectPath: folder) }
                else { try await stop(sessionID) }
            } catch { return await chat.alive }
            return false
        }
        if await chat.alive { return true }
        await releaseLive(sessionID); return false
    }
    /// Only the person's own choices (a chosen AI, account or model/effort) stop a live
    /// Hoot. An automatic pick that moved because a sign-in check was slow or failed
    /// (heavy load, a timeout) must never silently stop or swap Hoot.
    static func deliberateChange(_ selected: BackendHootReadySelection, provider: HootChatProvider,
                                 profileID: String?, settings: AGSAgentSettings?) -> Bool {
        if let chosen = selected.preferences.provider, chosen != provider { return true }
        if let account = selected.preferences.profileID, account != profileID { return true }
        // Hoot's row in Who uses what (also written by the popover's account list) names another account, and that
        // account is the one the selection really chose (signed in): the person's own change. An account picked only
        // because the named one is not signed in right now is never a reason to restart.
        if selected.provider == provider, let seat = selected.seatAccountID, selected.profile?.id == seat, seat != profileID { return true }
        // Same AI and account as the live Hoot: a different saved choice is the person's own, even if this
        // moment's sign-in check was slow (the release build checks through the account bridge).
        guard selected.provider == provider, selected.profile?.id == profileID else { return false }
        return selected.launchSettings != settings
    }
    private var relaunchOnNextSend = false
    public func prepareForSend() async {
        try? await scoped { await self.prepareForSendScoped() }
    }
    private func prepareForSendScoped() async {
        guard relaunchOnNextSend, let current = liveID, !(await chat.isBusy) else { return }
        relaunchOnNextSend = false
        // Still a real change? Then replace the idle child; the next launch resumes this conversation.
        guard HootReadyDefaults.enabled(), let readyDefaults, let folder = liveProjectPath,
              let selected = try? await readyDefaults.read(projectPath: folder, forConversation: true),
              Self.deliberateChange(selected, provider: chat.provider, profileID: liveProfileID, settings: liveSettings) else { return }
        try? await stop(current)
    }
    public func stop(_ sessionID: String) async throws {
        guard liveID == sessionID else { return }
        await chat.stop(); await releaseLive(sessionID)
    }
    private func readySelection(projectPath: String) async throws -> BackendHootReadySelection? {
        guard HootReadyDefaults.enabled(), let readyDefaults else { return nil }
        let selected = try await readyDefaults.read(projectPath: projectPath, forConversation: true)
        if selected.provider != chat.provider {
            let previous = liveID
            try await chat.rebindProvider(selected.provider)
            if let previous { await releaseLive(previous) }
        }
        return selected
    }
    public func conversationOptions(_ patch: NativeRPCValue?) async throws -> NativeRPCValue {
        try await scoped { try await self.conversationOptionsScoped(patch) }
    }
    private func conversationOptionsScoped(_ patch: NativeRPCValue?) async throws -> NativeRPCValue {
        guard let readyDefaults, let folder = liveProjectPath ?? defaultProjectPath else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's conversation options are unavailable.")
        }
        guard let patch else { return try await readyDefaults.chatOptions(projectPath: folder) }
        // A permission-only change applies mid-turn: no stop; prompts follow the new mode at once.
        if await chat.isBusy, !changingOptions, Set(patch.fields?.map(\.key) ?? []) == ["permissionMode"] {
            let result = try await readyDefaults.setChatOptions(patch, projectPath: folder)
            let live = try await readyDefaults.read(projectPath: folder, forConversation: true)
            // The installed control protocol accepts default, not the old manual alias.
            let wanted = live.launchSettings.permissionMode ?? "default"
            await chat.applyPermissionPolicyNow(live.permissionPolicy, cliMode: wanted)
            return result
        }
        guard !changingOptions, !(await chat.isBusy) else { throw NativeRPCError(code: "busy", message: "Finish or stop Hoot's answer before changing its options.") }
        changingOptions = true
        defer { changingOptions = false }
        let checkpoint = await readyDefaults.checkpointChatOptions(), previousProvider = chat.provider
        do {
            let result = try await readyDefaults.setChatOptions(patch, projectPath: folder)
            if let current = liveID { try await stop(current) }
            _ = try await readySelection(projectPath: folder)
            return result
        } catch {
            try await rollbackOptions(checkpoint, provider: previousProvider)
            throw error
        }
    }
    public func resetConversationOptions() async throws {
        try await scoped { try await self.resetConversationOptionsScoped() }
    }
    private func resetConversationOptionsScoped() async throws {
        guard let readyDefaults, let folder = liveProjectPath ?? defaultProjectPath,
              !changingOptions, !(await chat.isBusy) else { throw NativeRPCError(code: "busy", message: "Hoot is still answering.") }
        changingOptions = true
        defer { changingOptions = false }
        let checkpoint = await readyDefaults.checkpointChatOptions(), previousProvider = chat.provider
        do {
            if let current = liveID { try await stop(current) }
            await readyDefaults.resetChatOptions()
            _ = try await readySelection(projectPath: folder)
        } catch {
            try await rollbackOptions(checkpoint, provider: previousProvider)
            throw error
        }
    }
    public func checkpointConversationOptions() async throws -> NativeRPCValue {
        guard let readyDefaults, !changingOptions, !(await chat.isBusy) else {
            throw NativeRPCError(code: "busy", message: "Finish or stop Hoot before changing this chat.")
        }
        return .object([.init("version", .number(1)), .init("provider", .string(chat.provider.rawValue)),
                        .init("options", await readyDefaults.checkpointChatOptions())])
    }
    public func restoreConversationOptions(_ checkpoint: NativeRPCValue) async throws {
        _ = try checkpoint.requireObject("conversation checkpoint")
        guard Set(checkpoint.fields?.map(\.key) ?? []) == ["version", "provider", "options"],
              checkpoint["version"].number == 1, try checkpoint.encodedJSON().count <= 8192,
              let provider = checkpoint["provider"].string.flatMap(HootChatProvider.init(rawValue:)),
              !changingOptions else { throw NativeRPCError.invalidArguments("The conversation checkpoint is invalid or still changing.") }
        changingOptions = true
        defer { changingOptions = false }
        try await rollbackOptions(checkpoint["options"], provider: provider)
    }
    private func rollbackOptions(_ checkpoint: NativeRPCValue, provider: HootChatProvider) async throws {
        guard let readyDefaults else { throw BackendSessionFailure.missingCapability("Hoot's conversation options owner") }
        try await readyDefaults.restoreChatOptions(checkpoint)
        // A cancelled caller still restores its memory/provider. This task only
        // stops/rebinds the same store; it never starts a CLI or sends a message.
        let restore = Task { [chat] in try await chat.rebindProvider(provider) }
        try await restore.value
    }
    private func releaseLive(_ id: String) async {
        if let livePrepared, let launchBinding { await launchBinding.abandon(livePrepared) }
        livePrepared = nil; liveProfileID = nil; liveSettings = nil
        await sessions.accounts.exited(sessionID: id); liveID = nil
    }
    private static func withoutReadyScalars(_ arguments: [String]) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            let item = arguments[index]
            if ["--model", "-m", "--effort"].contains(item) { index += 2; continue }
            if ["--model=", "--effort="].contains(where: item.hasPrefix) { index += 1; continue }
            // 18 Oct (#526): Ultracode may now share the one --settings with hooks and Fast mode; only it is dropped.
            if item == "--settings", index + 1 < arguments.count {
                if let rest = BackendAGSLaunch.removingUltracode(arguments[index + 1]) { result += [item, rest] }
                index += 2; continue
            }
            if ["-c", "--config"].contains(item), index + 1 < arguments.count,
               ["model=", "model_reasoning_effort="].contains(where: arguments[index + 1].hasPrefix) { index += 2; continue }
            result.append(item); index += 1
        }
        return result
    }
}
