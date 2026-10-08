import Foundation
import TerminalDeckNativeCore

/// Reuses the app's account, records fence and MCP composition without a PTY.
public actor BackendHootChatDriver: BackendCopilotSessionDriving, BackendHootChatToolRequirementsReceiving {
    private let providers: BackendNativeProviders
    private let sessions: BackendCompositionSessions
    private let confinement: BackendMacConfinement?
    private let chat: BackendHootChatStore
    private let exposure: @Sendable (String) -> Void
    private let policy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])?
    private var liveID: String?
    private var expectedTools: Set<String> = []
    public nonisolated let hidesAtSpawn = true
    public init(providers: BackendNativeProviders, sessions: BackendCompositionSessions,
                confinement: BackendMacConfinement?, chat: BackendHootChatStore,
                exposure: @escaping @Sendable (String) -> Void,
                policy: (@Sendable (BackendCreateSessionInput, BackendProviderSpec, BackendLaunchContext) async throws -> [String])? = nil) {
        self.providers = providers; self.sessions = sessions; self.confinement = confinement
        self.chat = chat; self.exposure = exposure
        self.policy = policy
    }
    public func hasClaude() async throws -> Bool {
        let path = try await providers.loginPath()
        return await providers.resolveBinary(chat.provider.rawValue, path: path).runnable != nil
    }
    public func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        try await sessions.profiles.resolve(sessionProfileID: nil, projectPath: projectPath, provider: chat.provider.rawValue)
    }
    public func toolRequirements(_ tools: BackendCopilotSessionTools?) async {
        expectedTools = Set(tools?.tools.map(\.wire) ?? [])
    }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) {
        let result = await sessions.signIn.read(profile)
        return (result.state, result.account, result.plan)
    }
    public func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        try Task.checkCancellation()
        let path = try await providers.loginPath(), provider = try await providers.resolve(input, loginPath: path)
        let context = BackendLaunchContext(appFenceID: fence?.id, extraArguments: extraArguments, rememberTab: false, isAppComposed: true)
        guard let policy else { throw BackendSessionFailure.missingCapability("the shared headless model/tool/permission policy resolver") }
        let policyArguments = try await policy(input, provider, context)
        let account = try await sessions.accounts.resolve(input, provider: provider, loginPath: path, context: context)
        let id = chat.conversationID
        do {
            try Task.checkCancellation()
            try await chat.requireContext((account.profile?.id ?? "system") + ":" + URL(fileURLWithPath: input.cwd).standardizedFileURL.path)
            let cliID = await chat.cliSessionID
            let plan = try BackendHootChatLaunchPlan(provider: chat.provider, cwd: input.cwd, sessionID: cliID,
                extra: policyArguments + extraArguments, expectedTools: expectedTools)
            let arguments = plan.arguments
            let confined: BackendConfinedLaunch
            if let confinement {
                do { confined = try await confinement.resolve(command: provider.command, args: arguments, input: input, account: account, context: context) }
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
            environment["PATH"] = account.path
            environment["CLAUDECODE"] = nil
            let spawn = BackendSpawnSpec(provider: provider.id, command: confined.command, args: confined.args,
                path: account.path, env: environment, profile: account.profile, homeProfileId: account.homeProfileID,
                agentSessionId: cliID, resumed: cliID != nil, hostCwd: confined.hostCwd)
            let meta = BackendSessionMeta(id: id, input: input, spawn: spawn)
            // The MCP lease is bound by the existing runtime before any user input.
            exposure(id)
            try Task.checkCancellation()
            try await chat.attach(.init(command: confined.command, arguments: confined.args, cwd: confined.hostCwd ?? input.cwd, environment: environment, setup: plan.setup))
            try await chat.initialize()
            try Task.checkCancellation()
            try await sessions.accounts.bind(account, session: meta)
            liveID = id; return meta
        } catch {
            await chat.stop(); await sessions.accounts.abandon(account); throw error
        }
    }
    public func isAlive(_ sessionID: String) async -> Bool {
        guard liveID == sessionID else { return false }
        if await chat.alive { return true }
        await sessions.accounts.exited(sessionID: sessionID); liveID = nil; return false
    }
    public func stop(_ sessionID: String) async throws {
        guard liveID == sessionID else { return }
        await chat.stop(); await sessions.accounts.exited(sessionID: sessionID); liveID = nil
    }
}
