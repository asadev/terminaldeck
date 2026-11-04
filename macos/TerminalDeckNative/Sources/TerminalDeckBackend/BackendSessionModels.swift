import Foundation
import TerminalDeckNativeCore

public enum BackendSessionStatus: String, Codable, Sendable {
    case idle, working, waiting, input, completed, exited
}

public enum BackendSessionOrigin: String, Codable, Sendable {
    case user, copilot, app
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let origin = Self(rawValue: value == "hoot" ? "copilot" : value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown session origin")
        }
        self = origin
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public enum BackendRemovalReason: String, Codable, Sendable { case stopped, replaced }

/// Wire names match SessionMeta in src/shared/types.ts. Optional identity fields
/// stay absent when the launch did not establish them.
public struct BackendSessionMeta: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let cwd: String
    public var projectId: String?
    public var resolvedProjectID: String { PROJProjects.resolve(projectID: projectId, folder: cwd) }
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
    /// The AI runs as a chat (the structured app mode Hoot uses), not in a terminal (Asad, 13 Oct). Absent: a terminal.
    public var chat: Bool?

    public init(id: String, input: BackendCreateSessionInput, spawn: BackendSpawnSpec, now: Date = Date()) {
        self.id = id
        cwd = input.cwd
        projectId = input.projectId
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
        chat = input.chat == true ? true : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, cwd, projectId, title, provider, exitCode, createdAt, resumed, agentSessionId
        case profileId, profileName, homeProfileId, origin, originApp, originRoutineId, originRunId, tabKey, chat
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(cwd, forKey: .cwd)
        try values.encodeIfPresent(projectId, forKey: .projectId)
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
        try values.encodeIfPresent(chat, forKey: .chat)
    }
}

public struct BackendCreateSessionInput: Codable, Equatable, Sendable {
    public var cwd: String
    public var projectId: String?
    public var resolvedProjectID: String { PROJProjects.resolve(projectID: projectId, folder: cwd) }
    public var cols: Int
    public var rows: Int
    public var provider: String?
    public var resume: Bool?
    public var resumeConversationId: String?
    /// F38: resume the named conversation as a FORK (Claude `--fork-session`): a new conversation with its own ID that
    /// starts as a copy. Only meaningful with `resume` and `resumeConversationId`.
    public var forkSession: Bool?
    public var resumeSessionAt: String?
    public var pickConversation: Bool?
    public var model: String?
    /// The thinking level for this session (the CLI's own word). Set by the playbook when Hoot starts a session.
    public var effort: String?
    public var deniedTools: [String]?
    public var noSkills: Bool?
    /// The saved agent this session runs as, even without a standing instructions file.
    public var agentProfileID: String?
    public var agentInstructions: String?
    public var claudeAgent: String?
    public var allowedTools: [String]?
    public var permissionMode: String?
    public var agentSettings: AGSAgentSettings?
    /// Backend-owned task launch marker, never parsed from renderer input.
    public var taskID: String?
    public var taskProject: String?
    public var agentDefinitionsFile: String?
    public var replaces: String?
    public var profileId: String?
    public var homeProfileId: String?
    public var origin: BackendSessionOrigin?
    public var originApp: String?
    public var originRoutineId: String?
    public var originRunId: String?
    public var tabKey: String?
    /// AGT: a restored shell tab resumes the AI that was running in it (validated commands only).
    public var shellAgent: BackendShellAgentResume?
    /// Chat instead of terminal (Claude, Codex, Gemini only): the AI in its structured app mode, shown in Hoot's chat
    /// screen (Asad, 13 Oct). Nil: the person's remembered choice decides for the window's own new sessions.
    public var chat: Bool?
    /// App-owned identity of an AI-to-AI job; never reused for another job.
    public var teamJob: BackendTeamChatJob?
    /// The AIs that can run as a chat.
    public static let chatProviders: Set<String> = ["claude", "codex", "gemini"]

    public init(cwd: String, cols: Int = 100, rows: Int = 30, provider: String? = nil) {
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.provider = provider
    }
}

/// AGT: the AI conversation a restored shell tab continues: `cd <cwd> && claude --resume <id>`
/// (or codex/gemini), then the same login shell. Anything else is refused by the launcher.
public struct BackendShellAgentResume: Codable, Equatable, Sendable {
    public var provider: String
    public var conversationId: String
    public var cwd: String
    public init(provider: String, conversationId: String, cwd: String) { self.provider = provider; self.conversationId = conversationId; self.cwd = cwd }
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
    /// Only settings measured from a launcher-scrubbed login shell.
    public var loginShellEnvironment: [String: String] = [:]
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
            if key == BackendAPIAccountRecord.referenceVariable { return false }
            if ["TD_NATIVE_STATE_ENDPOINT", "TD_NATIVE_STATE_TOKEN", "TD_NATIVE_DOMAIN_ENDPOINT", "TD_NATIVE_DOMAIN_TOKEN"].contains(key) { return false }
            if ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION"].contains(key) { return false }
            return !key.hasPrefix("CLAUDE_CODE_") && !key.hasPrefix("CLAUDE_PREVIEW_")
        }
    }

    /// Session-only policy: background tools keep their own environment policy.
    public static let loginShellSettings: Set<String> = [
        "NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "PAGER", "GIT_PAGER", "GH_PAGER", "TERM",
    ]

    public static func stripLauncher(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("CODEX_") && key != "CI" && !loginShellSettings.contains(key)
        }
    }

    public static func forSession(id: String, inherited: [String: String], spawn: BackendSpawnSpec) throws -> [String: String] {
        var env = stripLauncher(stripInherited(inherited))
        env["PATH"] = spawn.path
        // Account environments can themselves contain configuration.inheritedEnvironment.
        for (name, value) in stripLauncher(spawn.env) { env[name] = value }
        for (name, value) in spawn.loginShellEnvironment where loginShellSettings.contains(name) { env[name] = value }
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
    private static let waiting = [#"(?m)^\s*[❯›*]\s*$"#, #"(?m)^\s*│\s*>\s*│?\s*$"#, #"(?m)^\s*>\s*$"#, #"(?m)^.*[%$#]\s*$"#]
    private static let input = [#"\bdo you want\b"#, #"\(y/n\)"#, #"\[y/N\]"#, #"\byes\b.*\bno\b.*\?\s*$"#, #"(?m)^\s*❯?\s*\d+\.\s"#, #"press enter to continue"#, #"overwrite\?"#]

    /// Claude Code draws a dimmed example in its EMPTY prompt (`❯ Try "create a util logging.py that..."`).
    /// The screen text has no colours, so that hint reads like typed text. L8 (10 Oct): it made every new
    /// task worker look "not ready", the brief was never typed, and the launch was stopped after 120 s.
    public static func isEmptyPromptHint(_ text: String) -> Bool {
        ["Ask Codex to do anything", "Type your message or @path/to/file"].contains(text) || text.range(of: #"^Try "[^"]*"$"#, options: .regularExpression) != nil
    }
    /// The prompt line with Claude's empty-prompt hint removed (`❯ Try "…"` reads as `❯`).
    public static func withoutPromptHint(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let mark = trimmed.first, mark == "❯" || mark == "›" || mark == ">" || mark == "*" else { return line }
        return isEmptyPromptHint(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)) ? String(mark) : line
    }

    public static func classify(viewport: String, exited: Bool = false) -> BackendSessionStatus {
        if exited { return .exited }
        // L8: real Claude Code leaves NUL cells where it skipped spaces; read them as spaces.
        let lines = viewport.replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(withoutPromptHint)
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
