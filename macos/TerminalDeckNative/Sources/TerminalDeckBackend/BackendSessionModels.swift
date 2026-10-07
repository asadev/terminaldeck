import Foundation

public enum BackendSessionStatus: String, Codable, Sendable {
    case idle, working, waiting, input, completed, exited
}

public enum BackendSessionOrigin: String, Codable, Sendable { case user, copilot, app }
public enum BackendRemovalReason: String, Codable, Sendable { case stopped, replaced }

/// Wire names match SessionMeta in src/shared/types.ts. Optional identity fields
/// stay absent when the launch did not establish them.
public struct BackendSessionMeta: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let cwd: String
    public var title: String
    public let provider: String
    public var exitCode: Int?
    public let createdAt: Double
    public let resumed: Bool
    public var agentSessionId: String?
    public var profileId: String?
    public var profileName: String?
    public var homeProfileId: String?
    public let origin: BackendSessionOrigin?
    public let originApp: String?
    public let originRoutineId: String?
    public let originRunId: String?
    public let tabKey: String?

    public init(id: String, input: BackendCreateSessionInput, spawn: BackendSpawnSpec, now: Date = Date()) {
        self.id = id
        cwd = input.cwd
        let folder = URL(fileURLWithPath: input.cwd).lastPathComponent
        title = folder.isEmpty ? input.cwd : folder
        provider = spawn.provider
        exitCode = nil
        createdAt = now.timeIntervalSince1970 * 1_000
        resumed = spawn.resumed
        agentSessionId = spawn.agentSessionId
        profileId = spawn.profile?.id
        profileName = spawn.profile?.name
        homeProfileId = spawn.homeProfileId
        origin = input.origin
        originApp = input.originApp
        originRoutineId = input.originRoutineId
        originRunId = input.originRunId
        tabKey = spawn.tabKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, cwd, title, provider, exitCode, createdAt, resumed, agentSessionId
        case profileId, profileName, homeProfileId, origin, originApp, originRoutineId, originRunId, tabKey
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(cwd, forKey: .cwd)
        try values.encode(title, forKey: .title); try values.encode(provider, forKey: .provider)
        // SessionMeta's live process sentinel is JSON null, not a missing key.
        try values.encode(exitCode, forKey: .exitCode)
        try values.encode(createdAt, forKey: .createdAt); try values.encode(resumed, forKey: .resumed)
        try values.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try values.encodeIfPresent(profileId, forKey: .profileId); try values.encodeIfPresent(profileName, forKey: .profileName)
        try values.encodeIfPresent(homeProfileId, forKey: .homeProfileId)
        try values.encodeIfPresent(origin, forKey: .origin); try values.encodeIfPresent(originApp, forKey: .originApp)
        try values.encodeIfPresent(originRoutineId, forKey: .originRoutineId)
        try values.encodeIfPresent(originRunId, forKey: .originRunId); try values.encodeIfPresent(tabKey, forKey: .tabKey)
    }
}

public struct BackendCreateSessionInput: Codable, Equatable, Sendable {
    public var cwd: String
    public var cols: Int
    public var rows: Int
    public var provider: String?
    public var resume: Bool?
    public var resumeConversationId: String?
    public var pickConversation: Bool?
    public var model: String?
    public var deniedTools: [String]?
    public var noSkills: Bool?
    public var agentInstructions: String?
    public var replaces: String?
    public var profileId: String?
    public var homeProfileId: String?
    public var origin: BackendSessionOrigin?
    public var originApp: String?
    public var originRoutineId: String?
    public var originRunId: String?
    public var tabKey: String?

    public init(cwd: String, cols: Int = 100, rows: Int = 30, provider: String? = nil) {
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.provider = provider
    }
}

public struct BackendAccountIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// Fully resolved, privileged launch instruction. The app's launch service
/// constructs this; renderer input can never supply command, argv or env.
public struct BackendSpawnSpec: Sendable {
    public var provider: String
    public var command: String
    public var args: [String]
    public var path: String
    public var env: [String: String]
    public var removeEnv: Set<String>
    public var profile: BackendAccountIdentity?
    public var homeProfileId: String?
    public var agentSessionId: String?
    public var resumed: Bool
    public var hostCwd: String?
    public var tabKey: String?
    /// Backend-only launch callback (Hoot's hidden-at-spawn boundary): the PTY
    /// manager calls it with the actual ID before the session is listed,
    /// started or announced. Never renderer supplied.
    public var beforeExposure: (@Sendable (String) -> Void)? = nil

    public init(provider: String, command: String, args: [String], path: String,
                env: [String: String] = [:], removeEnv: Set<String> = [],
                profile: BackendAccountIdentity? = nil, homeProfileId: String? = nil,
                agentSessionId: String? = nil, resumed: Bool = false,
                hostCwd: String? = nil, tabKey: String? = nil) {
        self.provider = provider; self.command = command; self.args = args; self.path = path
        self.env = env; self.removeEnv = removeEnv; self.profile = profile
        self.homeProfileId = homeProfileId; self.agentSessionId = agentSessionId
        self.resumed = resumed; self.hostCwd = hostCwd; self.tabKey = tabKey
    }
}

public enum BackendSessionEvent: Sendable {
    case data(id: String, text: String)
    case exit(id: String, exitCode: Int)
    case status(id: String, status: BackendSessionStatus)
    case removed(id: String, reason: BackendRemovalReason)
}

public enum BackendSessionFailure: Error, LocalizedError, Sendable {
    case invalidInput(String), missingSession, exitedSession, closed
    case operatingSystem(operation: String, code: Int32)
    case launch(provider: String, cwd: String, command: String, processCwd: String, cause: String?)
    case missingCapability(String), providerMismatch, conversationHeld, unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): detail
        case .missingSession: "There is no session with that id."
        case .exitedSession: "The session process has exited. Its output is still available."
        case .closed: "The native session manager is shutting down."
        case let .operatingSystem(operation, code): "macOS could not \(operation) (POSIX status \(code))."
        case let .launch(provider, cwd, command, processCwd, cause):
            "could not start \(provider) in \(cwd): \(command) would not run from \(processCwd)"
                + ((cause?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? "")
        case .missingCapability(let name): "The native session launcher is unavailable: \(name) has not been fully connected."
        case .providerMismatch: "The requested agent could not be launched. No substitute shell was started."
        case .conversationHeld: "That exact conversation is already open; the saved tab was kept instead of starting a new conversation."
        case .unsupported(let detail): detail
        }
    }
}

/// Match the POSIX inherited-session scrub in session-env.ts. User API keys
/// and base URLs remain configuration; parent run identities and vault tickets
/// never flow into a new session unless the account adapter assigns them.
public enum BackendSessionEnvironment {
    public static let sessionVariable = "TERMINALDECK_SESSION_ID"
    public static let vaultVariables: Set<String> = [
        "TERMINALDECK_ACCOUNT_VAULT", "TERMINALDECK_ACCOUNT_TICKET", "TERMINALDECK_ACCOUNT_HOME",
    ]

    public static func stripInherited(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { key, _ in
            if key == "CLAUDE_CONFIG_DIR" { return true }
            if key == sessionVariable || vaultVariables.contains(key) { return false }
            if ["TD_NATIVE_STATE_ENDPOINT", "TD_NATIVE_STATE_TOKEN", "TD_NATIVE_DOMAIN_ENDPOINT", "TD_NATIVE_DOMAIN_TOKEN"].contains(key) { return false }
            if ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION"].contains(key) { return false }
            return !key.hasPrefix("CLAUDE_CODE_") && !key.hasPrefix("CLAUDE_PREVIEW_")
        }
    }

    public static func forSession(id: String, inherited: [String: String], spawn: BackendSpawnSpec) throws -> [String: String] {
        var env = stripInherited(inherited)
        env["PATH"] = spawn.path
        for (name, value) in spawn.env { env[name] = value }
        env[sessionVariable] = id
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Removals are last and are case-sensitive on macOS.
        for name in spawn.removeEnv { env.removeValue(forKey: name) }
        guard env.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw BackendSessionFailure.invalidInput("A session environment entry contains an invalid name or value.")
        }
        return env
    }
}

/// The status comes from SwiftTerm's current viewport, never old output chunks.
public enum BackendSessionClassifier {
    private static let working = [#"esc to interrupt"#, #"\btokens?\b.*\besc\b"#, #"(?m)^\s*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]"#, #"thinking[.…]"#]
    private static let waiting = [#"(?m)^\s*❯\s*$"#, #"(?m)^\s*│\s*>\s*│?\s*$"#, #"(?m)^\s*>\s*$"#, #"(?m)^.*[%$#]\s*$"#]
    private static let input = [#"\bdo you want\b"#, #"\(y/n\)"#, #"\[y/N\]"#, #"\byes\b.*\bno\b.*\?\s*$"#, #"(?m)^\s*❯?\s*\d+\.\s"#, #"press enter to continue"#, #"overwrite\?"#]

    public static func classify(viewport: String, exited: Bool = false) -> BackendSessionStatus {
        if exited { return .exited }
        let lines = viewport.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func matches(_ patterns: [String], _ count: Int) -> Bool {
            let tail = lines.suffix(count).joined(separator: "\n")
            return patterns.contains { tail.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        if matches(working, 12) { return .working }
        if matches(waiting, 6) { return .waiting }
        if matches(input, 10) { return .input }
        return .idle
    }
}
