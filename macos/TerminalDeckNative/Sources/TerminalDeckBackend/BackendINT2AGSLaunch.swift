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
    public let taskChoices: (@Sendable (String) async throws -> NativeRPCValue)?
    public init(store: BackendAGSStore, configuration: BackendTaskConfiguration,
                defaultProvider: @escaping @Sendable () async -> String,
                taskProfile: @escaping @Sendable (String) async throws -> String?,
                taskChoices: (@Sendable (String) async throws -> NativeRPCValue)? = nil) {
        self.store = store; self.configuration = configuration; self.defaultProvider = defaultProvider; self.taskProfile = taskProfile; self.taskChoices = taskChoices
    }
    public func resolve(_ input: BackendCreateSessionInput, context: BackendLaunchContext) async throws -> BackendCreateSessionInput {
        let profileID: String?
        if let task = input.taskID { profileID = try await taskProfile(task) }
        else { profileID = input.agentProfileID ?? input.agentInstructions }
        // PLAYBOOK-SEATS: the task's playbook row (decided by the task engine) comes first, then the agent's own
        // profile, then the app defaults; the task's own model/effort stay on top.
        var task: NativeRPCValue?
        if let taskID = input.taskID, let taskChoices { task = try await taskChoices(taskID) }
        var playbook = task.flatMap { BackendPlaybookLayer(wire: $0["playbook"]) }
        // A switched tab keeps its own AI, including after restoration. Its task/profile still
        // owns identity and restrictions, but must not pin the outgoing AI's scalar settings.
        let sessionProviderChoice = input.provider != nil && (input.replaces != nil || BackendAGSLaunchScope.restoring)
        if sessionProviderChoice, let provider = input.provider {
            var previousProvider = playbook?.provider
            if previousProvider == nil, let profileID {
                if let saved = try await store.profile(profileID) { previousProvider = saved.provider }
                else if let row = try await configuration.agent(profileID) { previousProvider = row["provider"].string }
            }
            if let previousProvider, previousProvider != provider {
                playbook?.provider = provider; playbook?.model = nil; playbook?.effort = nil
                task = task?.setting("model", .null).setting("effort", .null)
            }
        }
        var settings = try await BackendAGSSettingsResolution.resolve(input: input, store: store, configuration: configuration,
            defaultProvider: await defaultProvider(), taskProfile: profileID, requested: input.agentSettings, playbook: playbook,
            sessionProviderChoice: sessionProviderChoice)
        if let task, let current = settings { settings = try BackendAGOPTEfficiencyPolicy.taskChoices(current, task: task) }
        // A permission picked in the owner's New session dialog also wins over private profile defaults.
        if context.fromWindow, let permission = input.permissionMode, var current = settings {
            current.permissionMode = permission
            settings = current
        }
        // SETTINGS-TRUTH row 60: a session a paired device starts cannot take this Mac's private agent-settings plan.
        // Saved defaults (Settings › Agents) never stop it starting: it starts with each AI's own defaults. Only
        // settings the device itself asked for are refused, so nothing it asked for is silently dropped.
        if context.deviceBoundary != nil, settings != nil {
            if input.agentSettings != nil { throw unavailable(context) }
            settings = nil
        }
        var resolved = input; resolved.agentSettings = settings
        if resolved.cwd.isEmpty, let folder = settings?.workingFolder { resolved.cwd = folder }
        return resolved
    }
    private func unavailable(_ context: BackendLaunchContext) -> NativeRPCError {
        .init(code: "unavailable", message: context.deviceBoundary != nil
            ? "This remote transport has not negotiated agent settings. The session was not started with ignored overrides."
            : "The selected account's installed CLI help, complete MCP configuration and private session lease are not connected to agent settings yet. The saved settings were kept; this session was not started with ignored overrides.")
    }
}
