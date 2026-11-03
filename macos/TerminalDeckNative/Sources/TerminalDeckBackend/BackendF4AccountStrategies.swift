import Foundation
import TerminalDeckNativeCore

/// Port of `src/main/provider-accounts.ts`: one account strategy per agent,
/// derived from the agent catalogue so the account table and the picker's
/// table cannot drift.
///
/// `CodingAICatalog` (TerminalDeckNativeCore) carries id, label, logins and the
/// notes. The command fields `src/shared/agent-catalog.ts` also declares
/// (configEnv, credentialFile, status/sign-in/sign-out arguments) are not in
/// the Core catalogue yet, so they live in `commandFields` below, keyed by the
/// same ids — see NIGHT-REQUESTS (F4-profiles) to move them into Core.
public struct BackendAccountStrategy: Sendable, Equatable {
    public enum StatusFormat: String, Sendable { case claudeJSON = "claude-json", codexText = "codex-text", geminiLocal = "gemini-local" }
    public let provider: String
    public let label: String
    /// The variable that redirects the agent's config directory, or nil.
    public let configEnv: String?
    /// True only when setting `configEnv` was measured to move the login.
    public let movesLogin: Bool
    public let logins: CodingAIAgent.Logins
    public let credentialFile: String?
    public let statusArgs: [String]?
    public let statusFormat: StatusFormat?
    public let signInArgs: [String]?
    public let signOutArgs: [String]?
    public let signOutNote: String?
    public let reason: String?
}

public enum BackendAccountStrategies {
    private struct CommandFields: Sendable {
        let configEnv: String?
        let credentialFile: String?
        let statusArgs: [String]?
        let statusFormat: BackendAccountStrategy.StatusFormat?
        let signInArgs: [String]?
        let signOutArgs: [String]?
    }
    /// Verbatim from `src/shared/agent-catalog.ts` (claude, codex, gemini, shell).
    private static let commandFields: [String: CommandFields] = [
        "claude": .init(configEnv: "CLAUDE_CONFIG_DIR", credentialFile: ".credentials.json", statusArgs: ["auth", "status", "--json"],
                        statusFormat: .claudeJSON, signInArgs: ["auth", "login"], signOutArgs: ["auth", "logout"]),
        "codex": .init(configEnv: "CODEX_HOME", credentialFile: "auth.json", statusArgs: ["login", "status"],
                       statusFormat: .codexText, signInArgs: ["login"], signOutArgs: ["logout"]),
        "gemini": .init(configEnv: "GEMINI_CLI_HOME", credentialFile: nil, statusArgs: nil,
                        statusFormat: .geminiLocal, signInArgs: nil, signOutArgs: nil),
        "shell": .init(configEnv: nil, credentialFile: nil, statusArgs: nil, statusFormat: nil, signInArgs: nil, signOutArgs: nil),
    ]

    /// `strategyFor(provider)`: every field read from the one catalogue entry.
    public static func strategy(_ provider: String) -> BackendAccountStrategy? {
        guard let entry = CodingAICatalog.agent(provider), let fields = commandFields[provider] else { return nil }
        return BackendAccountStrategy(provider: entry.id, label: entry.label, configEnv: fields.configEnv,
            movesLogin: entry.logins == .multiple, logins: entry.logins, credentialFile: fields.credentialFile,
            statusArgs: fields.statusArgs, statusFormat: fields.statusFormat, signInArgs: fields.signInArgs,
            signOutArgs: fields.signOutArgs, signOutNote: entry.signOutNote, reason: entry.loginsNote)
    }
    /// `ACCOUNT_STRATEGIES`, in catalogue order.
    public static var all: [BackendAccountStrategy] { CodingAICatalog.all.compactMap { strategy($0.id) } }

    /// `supportsAccounts`: a config variable that was watched move a login.
    public static func supportsAccounts(_ provider: String) -> Bool {
        guard let strategy = strategy(provider) else { return false }
        return strategy.configEnv != nil && strategy.movesLogin
    }
    /// `ACCOUNT_PROVIDERS`: agents that may hold more than one account.
    public static var accountProviders: [String] { CodingAICatalog.all.filter { $0.logins == .multiple }.map(\.id) }
    /// `hasSignIn`: any login at all, the machine's own included.
    public static func hasSignIn(_ provider: String) -> Bool { CodingAICatalog.agent(provider)?.hasAnyLogin ?? false }
    /// `SIGN_IN_PROVIDERS`.
    public static var signInProviders: [String] { CodingAICatalog.all.filter(\.hasAnyLogin).map(\.id) }
    /// `unsupportedAccountReason` (the catalogue's `loginsNote`).
    public static func unsupportedReason(_ provider: String) -> String {
        CodingAICatalog.agent(provider)?.loginsNote
            ?? "This agent signs in its own way, and nothing here has verified a way to keep two of its logins apart — so a session on it uses whichever login this machine already has."
    }
    /// `accountEnv(provider, account)`: the one variable an account runs under.
    public static func accountEnv(provider: String, account: (provider: String, configDir: String)?) -> [String: String] {
        guard let account, supportsAccounts(provider), account.provider == provider,
              let key = strategy(provider)?.configEnv, !account.configDir.isEmpty else { return [:] }
        return [key: account.configDir]
    }
    /// `signInCommandLine(provider, bin)`: nil for an agent with no sign-in command.
    public static func signInCommandLine(_ provider: String, bin: String) -> String? {
        guard let args = strategy(provider)?.signInArgs else { return nil }
        return ([bin] + args).joined(separator: " ")
    }
    /// `hasSignOut`.
    public static func hasSignOut(_ provider: String) -> Bool { strategy(provider)?.signOutArgs != nil }
    /// `signOutNote`.
    public static func signOutNote(_ provider: String) -> String { CodingAICatalog.signOutNote(provider) }
    /// `signOutCommandLine(provider, bin)`: nil where the row shows a reason instead.
    public static func signOutCommandLine(_ provider: String, bin: String) -> String? {
        guard let args = strategy(provider)?.signOutArgs else { return nil }
        return ([bin] + args).joined(separator: " ")
    }
    /// The binary a person types (`PROVIDERS[provider].bin ?? provider`).
    public static func bin(_ provider: String) -> String { CodingAICatalog.agent(provider)?.bin ?? provider }
}
