import Foundation
import TerminalDeckNativeCore

/// Supplied by the EXISTING session-tool lease owner. A settings-only lease
/// owns a directory but issues no caller token. It is never decoded from RPC.
public struct BackendAGSLaunchFileLease: Sendable {
    public let id: UUID, directory: URL
    public let write: @Sendable ([String: Data]) async throws -> Void
    public let bind: @Sendable (String) async throws -> Void
    public let abandon: @Sendable () async -> Void
    public init(id: UUID, directory: URL, write: @escaping @Sendable ([String: Data]) async throws -> Void,
                bind: @escaping @Sendable (String) async throws -> Void, abandon: @escaping @Sendable () async -> Void) {
        self.id = id; self.directory = directory; self.write = write; self.bind = bind; self.abandon = abandon
    }
}
public struct BackendAGSPreparedLaunch: Sendable {
    fileprivate let lease: BackendAGSLaunchFileLease, facts: BackendAGSSelectedAccountFacts.Snapshot
    public let settings: AGSAgentSettings, input: BackendCreateSessionInput
    fileprivate let requestedSettings: AGSAgentSettings
    fileprivate let plan: BackendAGSLaunchPlan
    fileprivate let nativeServerNames: Set<String>
    public var hostLeaseID: UUID { lease.id }
    public var readableFiles: [String] { plan.privateFiles.keys.sorted().map { lease.directory.appendingPathComponent($0).path } }
}
/// Two phases: measured selected-account facts and policy BEFORE caller tokens;
/// private files AFTER generated native servers are known. No new account home.
public struct BackendAGSLaunchBinding: Sendable {
    private let facts: BackendAGSSelectedAccountFacts
    private let reserve: @Sendable () async throws -> BackendAGSLaunchFileLease
    private let authorize: @Sendable (BackendCreateSessionInput, AGSAgentSettings) async throws -> Void
    public init(facts: BackendAGSSelectedAccountFacts, reserve: @escaping @Sendable () async throws -> BackendAGSLaunchFileLease,
                authorize: @escaping @Sendable (BackendCreateSessionInput, AGSAgentSettings) async throws -> Void) {
        self.facts = facts; self.reserve = reserve; self.authorize = authorize
    }
    public func prepare(_ input: BackendCreateSessionInput, settings: AGSAgentSettings,
                        context: BackendLaunchContext, nativeServerNames: Set<String>) async throws -> BackendAGSPreparedLaunch {
        try BackendAGSValidation.check(settings); try await authorize(input, settings)
        let measured = try await facts.capture(input, context: context)
        guard measured.provider.id == settings.provider else { throw BackendAGSSelectedAccountFacts.unavailable("The saved agent settings belong to a different selected CLI.") }
        let lease = try await reserve()
        do {
            var checked = settings
            // What the person asked to be off (their per-server choices, or "Add-ons off"), as opposed to what the
            // launch marks off itself because the account already has it off.
            let requestedOff = Self.requestedOff(settings, serverNames: measured.serverNames.union(nativeServerNames), ownSavedChoice: BackendAGSLaunchScope.ownSavedChoice)
            if checked.efficiency?.addonsOff == true {
                for name in measured.serverNames.union(nativeServerNames) where name != "deck-control" { checked.mcpServers[name] = false }
            }
            // TRUTH-B: the MCP page's switches (server, tool, Claude Code, this agent) hold under agent settings too.
            BackendMcpPolicy.applyToAgentSettings(&checked, accountServers: measured.serverNames, agentID: input.agentProfileID ?? input.agentInstructions)
            // Never turn on an unknown or owner-disabled account server as a side effect.
            for name in measured.serverNames where measured.servers[name]["enabled"].bool == false {
                guard checked.mcpServers[name] != true else { throw BackendAGSSelectedAccountFacts.unavailable("That selected-account MCP server is disabled. Enable it in its own configuration first.") }
                checked.mcpServers[name] = false
            }
            if checked.provider == "claude", let allowed = checked.allowedTools {
                for name in measured.serverNames {
                    let group = "mcp__" + name
                    if allowed.contains(group) { continue }
                    if allowed.contains(where: { $0.hasPrefix(group + "__") }) { throw BackendAGSSelectedAccountFacts.unavailable("Claude needs a verified tool-filter proxy for a partial allow list on an external MCP server. No broader server was exposed.") }
                    checked.mcpServers[name] = false
                }
            }
            let plan = try BackendAGSLaunch.plan(checked, privateDirectory: lease.directory, installedHelp: measured.installedHelp,
                knownServers: measured.serverNames.union(nativeServerNames), overridable: measured.codexConfigured.map { $0.union(nativeServerNames) }, requestedOff: requestedOff)
            var launched = input
            launched.provider = measured.provider.id
            // Default Claude can resolve to a saved login during the authorized profile read. The
            // keeper's later reservation has no profile-read receipt, so resolving the default again
            // can return the system login instead. Carry the measured choice through that boundary.
            launched.profileId = measured.loginID
            // AGS owns these scalar argv now; legacy instructions must not emit a second copy.
            launched.model = nil; launched.allowedTools = nil
            launched.deniedTools = nil; launched.permissionMode = nil
            if launched.cwd.isEmpty, let folder = checked.workingFolder { launched.cwd = folder }
            return .init(lease: lease, facts: measured, settings: checked, input: launched, requestedSettings: settings, plan: plan, nativeServerNames: nativeServerNames)
        } catch { await lease.abandon(); throw error }
    }
    /// What the person asked to be off. A tab relaunched from its own saved settings asks for nothing new: its "off"
    /// entries include servers the first launch turned off itself (off in Codex's own list, the MCP page's switches,
    /// "Add-ons off"), so a plugin server among them is left as Codex has it instead of refusing the relaunch.
    static func requestedOff(_ settings: AGSAgentSettings, serverNames: Set<String>, ownSavedChoice: Bool) -> Set<String> {
        guard !ownSavedChoice else { return [] }
        var off = Set(settings.mcpServers.filter { $0.value == false }.map(\.key))
        if settings.efficiency?.addonsOff == true { off.formUnion(serverNames.subtracting(["deck-control"])) }
        return off
    }
    /// Applied before existing ordinary/project lease prepare(): deny/off wins.
    public static func grant(_ proposed: Set<String>, server: String, settings: AGSAgentSettings) -> Set<String> {
        guard settings.mcpServers[server] != false, settings.efficiency?.addonsOff != true || server == "deck-control" else { return [] }
        return BackendTAGToolPolicy.filter(proposed, server: server, allowed: settings.allowedTools, denied: settings.deniedTools)
    }
    /// generatedServers are parsed ONLY from the actual backend-owned lease files/specs,
    /// never a renderer inventory or names posing as configured endpoints.
    public func stage(_ prepared: BackendAGSPreparedLaunch, generatedServers: NativeRPCValue,
                      context: BackendLaunchContext, originalInput: BackendCreateSessionInput) async throws -> BackendLaunchContext {
        do {
            // Recheck the original authorized choice. Account-disabled servers are added to
            // prepared.settings during preparation; those restrictions are not a changed user choice.
            try await authorize(originalInput, prepared.requestedSettings)
            try await facts.recheck(prepared.facts, input: prepared.input, context: context)
            guard let generated = generatedServers.fields, generated.allSatisfy({ BackendAGSSelectedAccountFacts.validName($0.key) && $0.value.fields != nil }) else {
                throw BackendAGSSelectedAccountFacts.unavailable("The generated native MCP configuration is incomplete.")
            }
            guard Set(generated.map(\.key)).isDisjoint(with: prepared.facts.serverNames) else { throw BackendAGSSelectedAccountFacts.unavailable("A native MCP server conflicts with the selected account configuration.") }
            let expected = prepared.facts.serverNames.union(prepared.nativeServerNames)
            guard Set(generated.map(\.key)).isSubset(of: prepared.nativeServerNames) else { throw BackendAGSSelectedAccountFacts.unavailable("An unexpected generated MCP server appeared during launch.") }
            guard Set(prepared.settings.mcpServers.keys).isSubset(of: expected) else { throw BackendAGSSelectedAccountFacts.unavailable("An agent MCP override has no actual configured server.") }
            var files = prepared.plan.privateFiles, args = Self.removingScalarOverrides(context.extraArguments, provider: prepared.settings.provider), environment = context.environmentOverrides
            if prepared.settings.provider == "claude" {
                var servers = prepared.facts.servers
                for field in generated {
                    guard servers[field.key].isNullish else { throw BackendAGSSelectedAccountFacts.unavailable("A native MCP server conflicts with the selected account's server of the same name.") }
                    servers = servers.setting(field.key, field.value)
                }
                servers = .object((servers.fields ?? []).filter { prepared.settings.mcpServers[$0.key] != false }.map { .init($0.key, $0.value.removing("enabled")) })
                let name = "ags-complete-mcp.json"
                files[name] = try NativeRPCValue.object([.init("mcpServers", servers)]).encodedJSON(pretty: true)
                args = Self.removingMCPConfigs(args)
                args += ["--mcp-config", prepared.lease.directory.appendingPathComponent(name).path]
                if !prepared.plan.arguments.contains("--strict-mcp-config") { args.append("--strict-mcp-config") }
            } else if prepared.settings.provider == "gemini" {
                let name = "ags-gemini-settings.json"
                guard let bytes = files[name] else { throw BackendAGSSelectedAccountFacts.unavailable("The private Gemini settings file is missing.") }
                let local = try NativeRPCValue.parseJSON(bytes)
                let system = prepared.facts.geminiSystemSettings ?? .object([])
                for field in local.fields ?? [] where !system[field.key].isNullish && system[field.key] != field.value {
                    throw BackendAGSSelectedAccountFacts.unavailable("The requested Gemini settings conflict with existing system policy. No requested option was silently ignored.")
                }
                // Existing system policy is always higher than the requested private fields.
                var merged = BackendAGSSelectedAccountFacts.merge(local, system)
                let restrictions = local["mcp"]
                merged = merged.setting("mcp", BackendAGSSelectedAccountFacts.merge(restrictions, system["mcp"].isNullish ? .object([]) : system["mcp"]))
                var servers = prepared.facts.servers
                for field in generated {
                    guard servers[field.key].isNullish else { throw BackendAGSSelectedAccountFacts.unavailable("A generated Gemini MCP server name conflicts with the account configuration.") }
                    // L8 (11 Oct): Gemini's streamable-HTTP field is httpUrl (`url` alone means SSE); a task session trusts it.
                    servers = servers.setting(field.key, BackendSessionAppTools.geminiForm(field.value, taskSession: originalInput.taskID != nil))
                }
                // Preserve native endpoints AND per-tool include/exclude filters from the plan.
                servers = BackendAGSSelectedAccountFacts.merge(servers, local["mcpServers"].isNullish ? .object([]) : local["mcpServers"])
                merged = merged.setting("mcpServers", servers)
                files[name] = try merged.encodedJSON(pretty: true)
            }
            args += prepared.plan.arguments
            environment.merge(prepared.plan.environment) { _, next in next }
            try await prepared.lease.write(files)
            try Task.checkCancellation()
            let allFiles = files.keys.sorted().map { prepared.lease.directory.appendingPathComponent($0).path }
            let boundary = context.deviceBoundary.map { BackendDeviceBoundary(deviceKey: $0.deviceKey, folder: $0.folder, writableDirectories: $0.writableDirectories, readableFiles: $0.readableFiles + allFiles, readOnlyProjects: $0.readOnlyProjects) }
            return BackendLaunchContext(deviceBoundary: boundary, appFenceID: context.appFenceID, extraArguments: args,
                rememberTab: context.rememberTab, environmentOverrides: environment, removeEnvironment: context.removeEnvironment,
                isAppComposed: context.isAppComposed, beforeExposure: context.beforeExposure, requiresInAppOwner: true, hostLeaseIDs: context.hostLeaseIDs, hostMachineID: context.hostMachineID)
        } catch { await prepared.lease.abandon(); throw error }
    }
    public func bind(_ prepared: BackendAGSPreparedLaunch, session: BackendSessionMeta) async throws {
        try await prepared.lease.bind(session.id)
    }
    public func abandon(_ prepared: BackendAGSPreparedLaunch) async { await prepared.lease.abandon() }
    /// A changed selection needs a fresh authorized plan and fresh leases, never a weaker final check.
    /// Callers unwind their failed transaction before this makes one more attempt.
    public static func retryingSelection<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch is SelectionChanged {
            try Task.checkCancellation()
            return try await operation()
        }
    }
    struct SelectionChanged: LocalizedError {
        var errorDescription: String? { "The selected provider or login changed after agent settings preparation." }
    }
    /// The launcher calls this after resolving the real account/seat and before spawn.
    public static func requireAccount(_ prepared: BackendAGSPreparedLaunch, actual: BackendAccountLaunch, provider: BackendProviderSpec) throws {
        guard provider.command == prepared.facts.provider.command, provider.id == prepared.facts.provider.id,
              actual.profile == nil || actual.profile?.id == prepared.facts.loginID else { throw SelectionChanged() }
        let key = BackendAccountProfile.configEnvironment(prepared.settings.provider)
        let effective = key.flatMap { actual.environment[$0] ?? prepared.facts.environment[$0] }
        if let effective, URL(fileURLWithPath: effective).standardizedFileURL.path != URL(fileURLWithPath: prepared.facts.account.configDir).standardizedFileURL.path {
            throw BackendAGSSelectedAccountFacts.unavailable("The selected account changed after agent settings preparation. No session was started.")
        }
    }
    static func removingScalarOverrides(_ args: [String], provider: String? = nil) -> [String] {
        BackendTAGLaunchArguments.removingOverrides(args, provider: provider, scalars: true)
    }
    static func removingMCPConfigs(_ args: [String]) -> [String] {
        var result: [String] = [], i = 0
        while i < args.count {
            if args[i] == "--mcp-config" { i += 2; continue }
            if args[i].hasPrefix("--mcp-config=") { i += 1; continue }
            result.append(args[i]); i += 1
        }; return result
    }
}

/// Backend-only scope keeps the measured account proof through the existing
/// coordinator/launcher await chain. Nothing from RPC can construct PreparedLaunch.
public enum BackendAGSLaunchScope {
    @TaskLocal public static var prepared: BackendAGSPreparedLaunch?
    @TaskLocal public static var restoring = false
    /// FIXRESTART (16 Oct): true only while a restore relaunches a tab from ITS OWN saved private settings
    /// (BackendAGSSessionChoices, read by the app, never caller-supplied). That record is what the session already
    /// ran with (including the bypass a fresh start gets, and servers the launch itself turned off), so it is not a
    /// key asking to broaden its owner and not the person asking to turn a Codex plugin server off.
    @TaskLocal public static var ownSavedChoice = false
    /// 2 Nov (web v1): the paired device whose own New chat / New session start this is. Set only by the remote
    /// host's start paths, after they checked the device's level, offered folders and folder boundary; never decoded
    /// from a message. Lets a start that resolves saved agent settings pass the launch gate as the Mac's own dialog does.
    @TaskLocal public static var deviceStart: String?
}
