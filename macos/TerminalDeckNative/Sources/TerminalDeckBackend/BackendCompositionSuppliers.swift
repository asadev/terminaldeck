import Foundation
import TerminalDeckNativeCore

/// Concrete Mac suppliers over the retained authority, prepared PTY and Store.
/// The app supplies its real window selection/browser callbacks. Remote grant
/// restoration and cross-domain cleanup remain with their actual owners.
public struct BackendCompositionSuppliers: Sendable {
    public let authority: BackendCompositionAuthority
    public let providers: BackendNativeProviders
    public let registry: NativeChannelRegistry
    public let downloads: URL
    public let ui: BackendCompositionSuppliersUI
    public init(authority: BackendCompositionAuthority, providers: BackendNativeProviders,
                registry: NativeChannelRegistry, downloads: URL, ui: BackendCompositionSuppliersUI) throws {
        guard downloads.isFileURL, downloads.path.hasPrefix("/"), downloads.path != "/" else { throw NativeRPCError.invalidArguments("Uploads need the user's actual Downloads directory") }
        self.authority = authority; self.providers = providers; self.registry = registry; self.downloads = downloads; self.ui = ui
    }

    /// The installed app's own data folder (~/Library/Application Support/terminaldeck).
    public static func primaryDataDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true).standardizedFileURL
    }
    public static func configuration(dataRoot: URL, home: URL, environment: [String: String], helper: URL) throws -> BackendAccountConfiguration {
        try BackendAccountConfiguration(dataDirectory: dataRoot, homeDirectory: home, appName: BackendSharedBrand.name,
            appID: BackendSharedBrand.id, helperExecutable: helper, inheritedEnvironment: environment)
    }
    public func taskDependencies(keyViews: @escaping @Sendable () async throws -> [NativeRPCValue],
                                 makeCRMKey: (@Sendable (String) async throws -> (id: String, key: String))? = nil) throws -> BackendTaskChannelDependencies {
        let sessions = try authority.sessions()
        let configuration = authority.configuration
        let inventory = BackendAppAgentInventoryTaskAdapter(
            reader: BackendAppAgentInventory(systemHome: configuration.homeDirectory.path),
            profiles: sessions.profiles, store: authority.state.store,
            environment: configuration.inheritedEnvironment)
        // The callback retains this adapter. The existing channel factory owns
        // tasks:inventory and its native-app guard; no extra handler is added.
        return .init(keyViews: keyViews, makeCRMKey: makeCRMKey, inventory: inventory.callback)
    }
    public func sessionDependencies(projectMCPSource: any BackendProjectMCPSource,
                                    browserReach: any BackendBrowserToolReach,
                                    cleanup: BackendSessionLifecycleCleanup, restoreContext: BackendSessionRestoreContext,
                                    excludedAppWorkingDirectories: [String],
                                    emit: @escaping @Sendable (BackendSessionLifecycleEvent) -> Void,
                                    renamed: @escaping @Sendable (String, String) async -> Void,
                                    hookAdditionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?) throws -> BackendCompositionSessions.Dependencies {
        let configuration = authority.configuration
        let remoteRoot = configuration.dataDirectory.appendingPathComponent("remote", isDirectory: true)
        let confinement = try BackendMacConfinement(storageRoot: remoteRoot, appDataRoot: configuration.dataDirectory,
            accountHome: configuration.homeDirectory.path, inheritedEnvironment: configuration.inheritedEnvironment, runner: BackendCommandRunner())
        let instructions = try BackendNativeInstructions(storageRoot: remoteRoot)
        let home = configuration.homeDirectory
        return BackendCompositionSessions.Dependencies(accounts: configuration,
            // A brand-new vault creates its key on first use (TS safeStorage), for the app's own data
            // folder only; a scratch/explicit data folder never adds an item to the person's keychain
            // and runs without a vault instead (TS wire.ts "account vault off").
            cipher: BackendAccountKeychainCipher(appName: configuration.appName,
                mayCreateForNewVault: configuration.dataDirectory.standardizedFileURL == Self.primaryDataDirectory(home: home)),
            confinement: confinement, instructions: instructions,
            projectMCPSource: projectMCPSource, browserReach: browserReach, cleanup: cleanup, restoreContext: restoreContext,
            excludedAppWorkingDirectories: excludedAppWorkingDirectories,
            authorizeRPC: { [authority] context, channel, args in try await authority.authorizeSessionRPC(context, channel: channel, arguments: args) },
            authorizeAccountMetadata: { [authority] in try authority.authorizeMetadata($0) },
            authorizeMutation: { [authority] in try authority.authorizeMutation($0) },
            createContext: { [authority] in try await authority.createContext($0, context: $1) },
            emit: { [authority] event in authority.note(event); emit(event) }, renamed: renamed,
            hookSettingsFiles: ["claude": home.appendingPathComponent(".claude/settings.json"),
                "codex": home.appendingPathComponent(".codex/hooks.json"), "gemini": home.appendingPathComponent(".gemini/settings.json")],
            hookOfferFile: home.appendingPathComponent(BackendSharedBrand.projectConfigDir + "/hook-offer.json"),
            hookAdditionalContext: hookAdditionalContext, hookOpenLink: ui.hookOpenLink)
    }

    public func filesDependencies(restoreContext: BackendSessionRestoreContext,
                                  guestGitPlan: BackendGitRunner.DevicePlanner? = nil,
                                  announcePreviewPort: (@Sendable (Int) async throws -> Void)? = nil) throws -> BackendCompositionFiles.Dependencies {
        let graph = try authority.sessions()
        let filesystem = BackendFilesystemAuthority { [authority] in try await authority.filesystemScope($0) }
        let dev = BackendDevSessionAdapter(manager: graph.manager, openShell: { [authority] folder, context in
            _ = try await filesystem.authorize(folder, context: context, intent: .write)
            let input = BackendCreateSessionInput(cwd: folder, provider: "shell")
            let launchContext = try await authority.createContext(input, context: context)
            return try await graph.lifecycle.create(input, context: launchContext).id
        }, authorizeSession: { [authority] id, context in
            try await authority.requireSessionRPC(id, context: context)
            try authority.authorizeMutation(context)
        })
        let artifactScopes: BackendCompositionFiles.ArtifactScopes = { [authority] project, scope, context in
            [try await authority.transcriptScope(project: scope == .project ? project : nil, context: context)]
        }
        return BackendCompositionFiles.Dependencies(authority: filesystem, home: authority.configuration.homeDirectory.path,
            inheritedEnvironment: authority.configuration.inheritedEnvironment, commandRunner: BackendCommandRunner(),
            liveSessions: { graph.manager.list() }, sessionViews: { [authority] in authority.sessionViews() },
            uploadsDirectory: { [downloads, authority] in downloads.appendingPathComponent(authority.configuration.appName, isDirectory: true) },
            guestGitPlan: guestGitPlan, artifactScopes: artifactScopes,
            dev: .init(sessions: dev, broadcastState: { [authority, registry] value in
                await authority.publish(ownerID: BackendCompositionRoot.appOwnerID, channel: "dev:server:state", value: value, registry: registry)
            }),
            workspace: .init(liveFolders: { graph.manager.list().filter { $0.exitCode == nil }.map(\.cwd) }, openFolder: ui.openFolder),
            boundary: { [authority] id, context in
                try await authority.requireSessionRPC(id, context: context)
                let saved = try await authority.state.store.ledgerGet(id)
                guard !saved.isNullish else { throw NativeRPCError(code: "unavailable", message: "The app-composed session's informational boundary must come from its owning domain") }
                return try await restoreContext.context(for: BackendSessionSaved(saved)).deviceBoundary
            }, pickFolder: ui.pickFolder, showProject: ui.showProject, announcePreviewPort: announcePreviewPort)
    }

    public func usageDependencies() throws -> BackendCompositionUsage.Dependencies {
        _ = try authority.sessions()
        return .init(transcriptScope: { [authority] project, context in try await authority.transcriptScope(project: project, context: context) },
            authorizeRPC: { [authority] context, channel, args in
                if context.caller == .nativeApp { try authority.requireLocalUI(context); return }
                if ["usage:read", "usage:watch", "usage:refresh", "usage:context", "plan:watch", "usage:unwatch", "plan:unwatch"].contains(channel), let id = args.first?.string {
                    try await authority.requireSessionRPC(id, context: context)
                } else { try authority.authorizeMetadata(context) }
            }, push: { [authority, registry] owner, channel, value in await authority.publish(ownerID: owner, channel: channel, value: value, registry: registry) },
            modelLabel: Self.modelLabel,
            preferredProvider: { [authority] _ in authority.state.state()["preferences"]["defaultProvider"].string },
            authorizeReadinessMutation: { [authority] in try authority.authorizeMutation($0) }, appName: authority.configuration.appName)
    }

    public func usageToolAccess() -> BackendUsageToolAccess {
        .init(rpcContext: { [authority] in try await authority.rpc($0) },
            authorize: { [authority] caller, tool, args, tier in try await authority.authorize(caller, tool: tool, arguments: args, tier: tier, sentence: "Run " + tool) },
            session: { [authority] caller, id in try await authority.requireSession(id, native: caller) },
            machineUsage: { [authority] caller in
                let context = try await authority.resolve(caller)
                guard context.caller.kind == .local || context.caller.kind == .key && context.caller.folders == nil else {
                    throw NativeRPCError(code: "access-denied", message: "Machine-wide account usage belongs to an owner caller")
                }
            })
    }
    public func appAccess() -> BackendDeckToolsAppAccess {
        .init(caller: { [authority] native in
            let context = try await authority.resolve(native)
            let kind = BackendDeckToolsAppCaller.Kind(rawValue: context.caller.kind.rawValue) ?? .other
            return .init(kind: kind, sessionID: context.caller.sessionID, machineID: context.caller.machineID, keyName: context.caller.keyName)
        }, knownFolder: { [authority] native, path in try await authority.knownFolder(path, native: native) },
            session: { [authority] native, id in Self.sessionWire(try await authority.requireSession(id, native: native)) },
            runnableProject: { [authority] native, path in try await authority.knownFolder(path, native: native) },
            rpc: { [authority] in try await authority.rpc($0) },
            authorize: { [authority] native, tool, args, tier, sentence, must in try await authority.authorize(native, tool: tool, arguments: args, tier: tier, sentence: sentence, ownerMustAnswer: must) },
            record: { [authority] native, tool, args, summary in try await authority.record(native, tool: tool, arguments: args, summary: summary) })
    }

    /// Pure projection of the actual PTY row; absent facts stay absent.
    public static func sessionWire(_ session: BackendSessionMeta) -> NativeRPCValue {
        var result = NativeRPCValue.object([.init("id", .string(session.id)), .init("cwd", .string(session.cwd)),
            .init("title", .string(session.title)), .init("provider", .string(session.provider)),
            .init("exitCode", session.exitCode.map { .number(Double($0)) } ?? .null),
            .init("createdAt", .number(session.createdAt)), .init("resumed", .bool(session.resumed))])
        for (key, value) in [("agentSessionId", session.agentSessionId), ("profileId", session.profileId),
            ("profileName", session.profileName), ("homeProfileId", session.homeProfileId), ("origin", session.origin?.rawValue),
            ("originApp", session.originApp), ("originRoutineId", session.originRoutineId), ("originRunId", session.originRunId), ("tabKey", session.tabKey)] {
            if let value { result = result.setting(key, .string(value)) }
        }
        return result
    }
    /// Source agent-controls.labelModelId, using the existing cost normalizer.
    public static func modelLabel(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines), id = BackendCostMath.normalizeModel(raw)
        guard let expression = try? NSRegularExpression(pattern: "^claude-(opus|sonnet|haiku|fable)-(\\d+(?:-\\d+)?)"),
              let match = expression.firstMatch(in: id, range: NSRange(location: 0, length: id.utf16.count)) else { return clean }
        let text = id as NSString, family = text.substring(with: match.range(at: 1)).capitalized
        let version = text.substring(with: match.range(at: 2)).replacingOccurrences(of: "-", with: ".")
        return family + " " + version + (clean.lowercased().hasSuffix("[1m]") ? " · 1M" : "")
    }
}
