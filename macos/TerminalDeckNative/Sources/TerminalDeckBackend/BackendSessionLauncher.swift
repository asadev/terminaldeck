import Foundation

/// Required source-domain adapters. No implementation is silently replaced
/// by an empty environment, unrestricted launch, or a shell-only fallback.
public enum BackendLaunchReadiness: Sendable, Equatable {
    case ready
    case unavailable(String)
}

public protocol BackendLaunchCapability: Sendable {
    var readiness: BackendLaunchReadiness { get }
}

public struct BackendProviderSpec: Sendable {
    public let id: String
    public let command: String
    public let args: [String]
    public let resumeArgs: [String]

    public init(id: String, command: String, args: [String], resumeArgs: [String]) {
        self.id = id; self.command = command; self.args = args; self.resumeArgs = resumeArgs
    }
}

public protocol BackendProviderLaunchResolver: BackendLaunchCapability {
    /// Port providers/loginPath/agent-binaries/customProviderSpec here. An
    /// explicit unavailable provider throws; it never resolves to "shell".
    func loginPath() async throws -> String
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec
}

public struct BackendAccountLaunch: Sendable {
    public let profile: BackendAccountIdentity?
    public let homeProfileID: String?
    public let environment: [String: String]
    public let removeEnvironment: Set<String>
    public let path: String
    /// Opaque launch allocation for a vault seat. Never expose it on the wire.
    public let reservationID: String?

    public init(profile: BackendAccountIdentity?, homeProfileID: String? = nil,
                environment: [String: String], removeEnvironment: Set<String> = [],
                path: String, reservationID: String? = nil) {
        self.profile = profile; self.homeProfileID = homeProfileID; self.environment = environment
        self.removeEnvironment = removeEnvironment; self.path = path; self.reservationID = reservationID
    }
}

public protocol BackendAccountLaunchResolver: BackendLaunchCapability {
    /// Port resolveProfile, accountEnv, keptUnavailable, splitHome, seatEnv and
    /// vaultPath here. The supplied environment must represent the established
    /// login/folder pair; unavailable managed keys are a launch error.
    func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                 loginPath: String, context: BackendLaunchContext) async throws -> BackendAccountLaunch
    /// Resolve an unnamed Claude --continue from this account folder's own
    /// transcript metadata, excluding ids already claimed by a live tab.
    func continuingConversationID(_ input: BackendCreateSessionInput, account: BackendAccountLaunch,
                                  live: [BackendSessionMeta]) async throws -> String?
    func bind(_ account: BackendAccountLaunch, session: BackendSessionMeta) async throws
    func abandon(_ account: BackendAccountLaunch) async
    func exited(sessionID: String) async
}

public struct BackendDeviceBoundary: Codable, Equatable, Sendable {
    public let deviceKey: String
    public let folder: String
    public let writableDirectories: [String]
    public let readableFiles: [String]
    public let readOnlyProjects: [String]
    public init(deviceKey: String, folder: String, writableDirectories: [String] = [],
                readableFiles: [String] = [], readOnlyProjects: [String] = []) {
        self.deviceKey = deviceKey; self.folder = folder; self.writableDirectories = writableDirectories
        self.readableFiles = readableFiles; self.readOnlyProjects = readOnlyProjects
    }
    private enum CodingKeys: String, CodingKey { case deviceKey, folder, writableDirectories, readableFiles, readOnlyProjects }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceKey = try values.decode(String.self, forKey: .deviceKey)
        folder = try values.decode(String.self, forKey: .folder)
        writableDirectories = try values.decodeIfPresent([String].self, forKey: .writableDirectories) ?? []
        readableFiles = try values.decodeIfPresent([String].self, forKey: .readableFiles) ?? []
        readOnlyProjects = try values.decodeIfPresent([String].self, forKey: .readOnlyProjects) ?? []
    }
}

public struct BackendLaunchContext: Sendable {
    public let deviceBoundary: BackendDeviceBoundary?
    /// An app-owned fence name, not sandbox source or filesystem paths supplied
    /// by the renderer. The confinement adapter resolves the actual fence.
    public let appFenceID: String?
    public let extraArguments: [String]
    public let rememberTab: Bool
    /// Backend-owned guest Git/project additions, not renderer supplied env.
    public let environmentOverrides: [String: String]
    public let removeEnvironment: Set<String>
    /// Browser/project arguments composed by this backend do not turn an
    /// ordinary local session into an app-owned launch or disable its account seat.
    public let isAppComposed: Bool
    /// Backend-only: carried into `BackendSpawnSpec.beforeExposure`.
    public let beforeExposure: (@Sendable (String) -> Void)?

    public init(deviceBoundary: BackendDeviceBoundary? = nil, appFenceID: String? = nil,
                extraArguments: [String] = [], rememberTab: Bool = true,
                environmentOverrides: [String: String] = [:], removeEnvironment: Set<String> = [],
                isAppComposed: Bool? = nil, beforeExposure: (@Sendable (String) -> Void)? = nil) {
        self.deviceBoundary = deviceBoundary; self.appFenceID = appFenceID; self.beforeExposure = beforeExposure
        self.extraArguments = extraArguments; self.rememberTab = rememberTab
        self.environmentOverrides = environmentOverrides; self.removeEnvironment = removeEnvironment
        self.isAppComposed = isAppComposed ?? (!extraArguments.isEmpty || appFenceID != nil)
    }
}

public struct BackendConfinedLaunch: Sendable {
    public let command: String
    public let args: [String]
    public let environment: [String: String]
    public let removeEnvironment: Set<String>
    public let hostCwd: String?
    public let deviceKey: String?
    public let enforcedBoundary: Bool

    public init(command: String, args: [String], environment: [String: String] = [:],
                removeEnvironment: Set<String> = [], hostCwd: String? = nil,
                deviceKey: String? = nil, enforcedBoundary: Bool = false) {
        self.command = command; self.args = args; self.environment = environment
        self.removeEnvironment = removeEnvironment; self.hostCwd = hostCwd
        self.deviceKey = deviceKey; self.enforcedBoundary = enforcedBoundary
    }
}

public protocol BackendConfinementLaunchResolver: BackendLaunchCapability {
    /// Port planFor/proveConfinement/confineSpawn, granted-home environment,
    /// guest Git removals and the app fence. A requested boundary must be
    /// enforced before exec; an empty/unavailable boundary is never accepted.
    func resolve(command: String, args: [String], input: BackendCreateSessionInput,
                 account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch
}

public protocol BackendInstructionLaunchResolver: BackendLaunchCapability {
    /// Resolve model, deniedTools, noSkills and agentInstructions from the
    /// source catalog/owned instruction store, including unsupported-provider
    /// refusals. Returns argv tokens, never a shell command string.
    func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                   context: BackendLaunchContext) async throws -> [String]
}

public protocol BackendSessionLedger: BackendLaunchCapability {
    /// This domain decides if a tab is really persisted (including the device
    /// id needed to restore confinement) and keeps a replacement's stable key.
    func tabKey(_ input: BackendCreateSessionInput, context: BackendLaunchContext,
                live: [BackendSessionMeta]) async throws -> String?
    func started(_ session: BackendSessionMeta, input: BackendCreateSessionInput,
                 context: BackendLaunchContext) async throws
    func removed(sessionID: String, reason: BackendRemovalReason) async
}

public struct BackendSessionLaunchDependencies: Sendable {
    public let providers: any BackendProviderLaunchResolver
    public let accounts: any BackendAccountLaunchResolver
    public let confinement: any BackendConfinementLaunchResolver
    public let instructions: any BackendInstructionLaunchResolver
    public let ledger: any BackendSessionLedger

    public init(providers: any BackendProviderLaunchResolver, accounts: any BackendAccountLaunchResolver,
                confinement: any BackendConfinementLaunchResolver, instructions: any BackendInstructionLaunchResolver,
                ledger: any BackendSessionLedger) throws {
        for (name, readiness) in [("provider/login environment", providers.readiness),
                                   ("account/vault environment", accounts.readiness),
                                   ("confinement", confinement.readiness),
                                   ("agent launch instructions", instructions.readiness),
                                   ("session persistence", ledger.readiness)] {
            guard readiness == .ready else {
                if case .unavailable(let why) = readiness { throw BackendSessionFailure.missingCapability("\(name): \(why)") }
                throw BackendSessionFailure.missingCapability(name)
            }
        }
        self.providers = providers; self.accounts = accounts; self.confinement = confinement
        self.instructions = instructions; self.ledger = ledger
    }
}

/// Serializes complete launch transactions (including awaits), so two concurrent
/// starts cannot both decide that a conversation is free. The manager remains
/// independently usable for a privileged fully-resolved SpawnSpec.
public actor BackendSessionLauncher {
    public let manager: BackendPTYManager
    private let dependencies: BackendSessionLaunchDependencies
    private var busy = false
    private var entrants: [CheckedContinuation<Void, Never>] = []

    public init(manager: BackendPTYManager, dependencies: BackendSessionLaunchDependencies) {
        self.manager = manager; self.dependencies = dependencies
    }

    public func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext = BackendLaunchContext()) async throws -> BackendSessionMeta {
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        guard input.cwd.hasPrefix("/"), !input.cwd.contains("\0") else { throw BackendSessionFailure.invalidInput("The session folder must be an absolute path.") }
        if context.deviceBoundary != nil && context.appFenceID != nil {
            throw BackendSessionFailure.unsupported("A device boundary and an app fence cannot be nested for one session.")
        }
        let path = try await dependencies.providers.loginPath()
        let provider = try await dependencies.providers.resolve(input, loginPath: path)
        if let requested = input.provider, requested != provider.id { throw BackendSessionFailure.providerMismatch }
        guard !provider.id.isEmpty, !provider.command.isEmpty else { throw BackendSessionFailure.providerMismatch }
        let live = manager.list()
        let instructions = try await dependencies.instructions.arguments(input, provider: provider, context: context)
        // Source withLaunchArgs composes global flags before a named resume
        // subcommand (notably Codex's -c developer_instructions).
        let additions = instructions + context.extraArguments
        let composedProvider = BackendProviderSpec(id: provider.id, command: provider.command,
            args: provider.args + additions,
            resumeArgs: provider.resumeArgs.isEmpty ? [] : provider.resumeArgs + additions)
        let selection = try BackendConversationLaunch.arguments(input, provider: composedProvider, live: live)
        // TS host-core.ts: `if (named && chosen !== resumeArgs) throw …` — before any account work.
        if selection.heldNamed { throw BackendSessionFailure.conversationHeld }
        let account = try await dependencies.accounts.resolve(input, provider: provider, loginPath: path, context: context)
        var session: BackendSessionMeta?
        do {
            let tabKey = try await dependencies.ledger.tabKey(input, context: context, live: live)
            var conversationID = selection.conversationID
            var launchArguments = selection.launchArguments
            if provider.id == "claude", selection.resumed, conversationID == nil, input.pickConversation != true {
                conversationID = try await dependencies.accounts.continuingConversationID(input, account: account, live: live)
                if let conversationID, conversationID.range(of: "^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) != nil {
                    // The recovered unclaimed account-owned id must also be
                    // what the CLI joins; --continue might otherwise pick a
                    // different newest transcript under an aliased folder.
                    // Only an id that cannot read as a flag goes on the command line.
                    launchArguments = composedProvider.args + ["--resume", conversationID]
                }
            }
            let launch = try await dependencies.confinement.resolve(command: provider.command,
                args: launchArguments,
                input: input, account: account, context: context)
            if let boundary = context.deviceBoundary {
                guard launch.enforcedBoundary, launch.deviceKey == boundary.deviceKey else {
                    throw BackendSessionFailure.missingCapability("the requested device's enforced folder boundary")
                }
            }
            if context.appFenceID != nil && !launch.enforcedBoundary {
                throw BackendSessionFailure.missingCapability("the requested app fence")
            }
            var environment = account.environment
            for (name, value) in launch.environment { environment[name] = value }
            try Task.checkCancellation()
            var spec = BackendSpawnSpec(provider: provider.id, command: launch.command, args: launch.args,
                path: account.path, env: environment, removeEnv: account.removeEnvironment.union(launch.removeEnvironment),
                profile: account.profile, homeProfileId: account.homeProfileID,
                agentSessionId: conversationID, resumed: selection.resumed,
                hostCwd: launch.hostCwd, tabKey: tabKey)
            spec.beforeExposure = context.beforeExposure
            let created = try manager.create(input, spawn: spec)
            session = created
            try await dependencies.accounts.bind(account, session: created)
            try await dependencies.ledger.started(created, input: input, context: context)
            return created
        } catch {
            if let session { manager.kill(session.id) }
            await dependencies.accounts.abandon(account)
            throw error
        }
    }

    /// The root event dispatcher calls this on the manager's process-exit event,
    /// including exits from already removed/replaced sessions.
    public func processExited(_ id: String) async {
        await enter()
        defer { leave() }
        await dependencies.accounts.exited(sessionID: id)
    }

    public func removed(_ id: String, reason: BackendRemovalReason) async {
        await enter()
        defer { leave() }
        await dependencies.ledger.removed(sessionID: id, reason: reason)
    }

    private func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { entrants.append($0) }
    }
    private func leave() {
        if entrants.isEmpty { busy = false }
        else { entrants.removeFirst().resume() }
    }
}

/// Mac argv selection, ported from one-conversation.ts and the conversation-id
/// part of host-core's startSession. A named collision is refused; an unnamed
/// continue in an already held folder starts a fresh conversation.
public enum BackendConversationLaunch {
    public struct Selection: Sendable {
        /// TS argsForSpawn's answer (host-core `chosen`): the continue/resume
        /// arguments, or the agent's plain ones.
        public let arguments: [String]
        public let resumed: Bool
        public let conversationID: String?
        /// TS host-core `declaredId`: a fresh Claude conversation this app names,
        /// so the launch appends `--session-id` (never on the resume path).
        public let declared: Bool
        /// TS host-core `named && chosen !== resumeArgs`: another live tab is on
        /// that exact conversation; the launch refuses before anything spawns.
        public let heldNamed: Bool
        public var launchArguments: [String] {
            guard declared, let conversationID else { return arguments }
            return arguments + ["--session-id", conversationID]
        }
    }

    public static func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
                                 live: [BackendSessionMeta], makeID: () -> String = { UUID().uuidString.lowercased() }) throws -> Selection {
        let picking = input.pickConversation == true && provider.id == "claude"
        let named = !picking && input.resume == true && ["claude", "codex"].contains(provider.id) && !(input.resumeConversationId ?? "").isEmpty
        let namedID = named ? input.resumeConversationId : nil
        var resumeArguments = provider.resumeArgs
        if picking { resumeArguments = provider.args + ["--resume"] }
        else if let namedID { resumeArguments = provider.args + (provider.id == "codex" ? ["resume", namedID] : ["--resume", namedID]) }
        let held: Bool
        if let namedID {
            held = live.contains { $0.exitCode == nil && $0.id != input.replaces && $0.provider == provider.id && $0.agentSessionId == namedID }
        } else {
            func folder(_ path: String) -> String {
                var value = path
                while value.hasSuffix("/") || value.hasSuffix("\\") { value.removeLast() }
                return value
            }
            held = live.contains { $0.exitCode == nil && $0.id != input.replaces && $0.provider == provider.id && folder($0.cwd) == folder(input.cwd) }
        }
        // TS one-conversation.ts argsForSpawn: a named resume another tab is on
        // answers the plain arguments; host-core then refuses (heldNamed).
        if named && held { return Selection(arguments: provider.args, resumed: false, conversationID: nil, declared: false, heldNamed: true) }
        let resumed = picking || (input.resume == true && !resumeArguments.isEmpty && !held)
        if resumed {
            return Selection(arguments: resumeArguments, resumed: true, conversationID: namedID, declared: false, heldNamed: false)
        }
        if provider.id == "claude" {
            let id = makeID()
            guard UUID(uuidString: id) != nil else { throw BackendSessionFailure.invalidInput("A fresh Claude conversation needs a valid generated id.") }
            return Selection(arguments: provider.args, resumed: false, conversationID: id, declared: true, heldNamed: false)
        }
        return Selection(arguments: provider.args, resumed: false, conversationID: nil, declared: false, heldNamed: false)
    }
}
