import Foundation
import TerminalDeckNativeCore

/// Selects only trusted store/profile values before MCP token issuance. Private
/// CLI overrides stay unavailable until the account's complete launch facts
/// and session-owned private-file/MCP lease supplier are actually installed.
public struct BackendINT2AGSLaunch: Sendable {
    public let store: BackendAGSStore
    public let configuration: BackendTaskConfiguration
    public let defaultProvider: @Sendable () async -> String
    public let taskProfile: @Sendable (String) async throws -> String?
    public init(store: BackendAGSStore, configuration: BackendTaskConfiguration,
                defaultProvider: @escaping @Sendable () async -> String,
                taskProfile: @escaping @Sendable (String) async throws -> String?) {
        self.store = store; self.configuration = configuration; self.defaultProvider = defaultProvider; self.taskProfile = taskProfile
    }
    public func resolve(_ input: BackendCreateSessionInput, context: BackendLaunchContext) async throws -> BackendCreateSessionInput {
        let profileID: String?
        if let task = input.taskID { profileID = try await taskProfile(task) }
        else { profileID = input.agentInstructions }
        let settings = try await BackendAGSSettingsResolution.resolve(input: input, store: store, configuration: configuration,
            defaultProvider: await defaultProvider(), taskProfile: profileID, requested: input.agentSettings)
        if context.deviceBoundary != nil, settings != nil { throw unavailable(context) }
        var resolved = input; resolved.agentSettings = settings
        if resolved.cwd.isEmpty, let folder = settings?.workingFolder { resolved.cwd = folder }
        return resolved
    }
    private func needsPrivatePlan(_ settings: AGSAgentSettings, legacyProfile: Bool) -> Bool {
        if !settings.environment.isEmpty || !settings.hooks.isEmpty || !settings.mcpServers.isEmpty { return true }
        if legacyProfile && settings.provider == "claude" { return false }
        if settings.allowedTools != nil { return true }
        return settings.model != nil || settings.effort != nil || settings.permissionMode != nil ||
            !settings.deniedTools.isEmpty || !legacyProfile && (settings.workingFolder != nil || settings.keepOpen)
    }
    private func unavailable(_ context: BackendLaunchContext) -> NativeRPCError {
        .init(code: "unavailable", message: context.deviceBoundary != nil
            ? "This remote transport has not negotiated agent settings. The session was not started with ignored overrides."
            : "The selected account's installed CLI help, complete MCP configuration and private session lease are not connected to agent settings yet. The saved settings were kept; this session was not started with ignored overrides.")
    }
}
