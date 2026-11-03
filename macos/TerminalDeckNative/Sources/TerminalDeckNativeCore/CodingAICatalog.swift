import Foundation

/// The agents, as `src/shared/agent-catalog.ts` declares them.
///
/// Only the fields the Coding AI screen reads: names, where to get one, how
/// many logins it can hold, and whether it has a logout command. The order is
/// the catalogue's — Claude Code, Codex CLI, Gemini CLI, then the plain shell —
/// and every list on the screen is drawn in it.
public struct CodingAIAgent: Equatable, Sendable, Identifiable {
    public enum Logins: String, Sendable { case multiple, single, none, unmeasured }

    public let id: String
    public let label: String
    public let description: String
    /// The command it is started with; nil for the plain shell.
    public let bin: String?
    public let install: String?
    public let url: String?
    public let logins: Logins
    public let canResume: Bool
    public let hasSignOut: Bool
    public let signOutNote: String?
    public let loginsNote: String?

    public var canHaveAccounts: Bool { logins == .multiple }
    public var hasAnyLogin: Bool { logins == .multiple || logins == .single }
}

public enum CodingAICatalog {
    public static let claude = CodingAIAgent(
        id: "claude", label: "Claude Code",
        description: "Anthropic's agentic CLI. Writes transcripts, so token and context tracking work.",
        bin: "claude", install: "npm install -g @anthropic-ai/claude-code",
        url: "https://docs.anthropic.com/en/docs/claude-code",
        logins: .multiple, canResume: true, hasSignOut: true, signOutNote: nil, loginsNote: nil)

    public static let codex = CodingAIAgent(
        id: "codex", label: "Codex CLI",
        description: "OpenAI's coding agent. Sign in with a ChatGPT account.",
        bin: "codex", install: "npm install -g @openai/codex",
        url: "https://github.com/openai/codex",
        logins: .multiple, canResume: true, hasSignOut: true, signOutNote: nil, loginsNote: nil)

    public static let gemini = CodingAIAgent(
        id: "gemini", label: "Gemini CLI",
        description: "Google's coding agent.",
        bin: "gemini", install: "npm install -g @google/gemini-cli",
        url: "https://github.com/google-gemini/gemini-cli",
        logins: .single, canResume: false, hasSignOut: false,
        signOutNote: "Gemini CLI has no logout command, so this app cannot sign it out from here — its login is let go of inside Gemini’s own screen.",
        loginsNote: "Gemini keeps one login per machine, in a keychain entry that is the same for every configuration directory — so a second Gemini account here would replace the first rather than sit beside it. The one login below is the machine’s, and signing in from it signs Gemini in everywhere.")

    public static let shell = CodingAIAgent(
        id: "shell", label: "Shell",
        description: "A plain login shell. No agent, no telemetry — just a terminal.",
        bin: nil, install: nil, url: nil,
        logins: .none, canResume: false, hasSignOut: false,
        signOutNote: "A plain shell has no account to sign out of.",
        loginsNote: "A plain shell has no account to sign in to.")

    /// Every entry, catalogue order.
    public static let all: [CodingAIAgent] = [claude, codex, gemini, shell]

    /// The agents that are looked up on PATH — the three coding agents.
    public static let lookup: [CodingAIAgent] = all.filter { $0.bin != nil }

    public static func agent(_ id: String?) -> CodingAIAgent? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// `isProviderId`: a built-in agent, or one somebody added (`custom:<name>`).
    public static func isProvider(_ id: String?) -> Bool {
        guard let id else { return false }
        if agent(id) != nil { return true }
        return id.hasPrefix("custom:") && id.count > "custom:".count
    }

    public static func label(_ id: String) -> String { agent(id)?.label ?? id }

    public static func hasSignOut(_ id: String) -> Bool { agent(id)?.hasSignOut ?? false }

    /// The reason a signed-in login of this agent has no Sign out.
    public static func signOutNote(_ id: String) -> String {
        agent(id)?.signOutNote
            ?? "This agent has no command to sign it out from here, so its login is let go of inside the agent’s own screen."
    }

    /// Catalogue position, for sorting; unknown ids after every known one.
    public static func rank(_ id: String?) -> Int {
        guard let id, let at = all.firstIndex(where: { $0.id == id }) else { return all.count }
        return at
    }
}
