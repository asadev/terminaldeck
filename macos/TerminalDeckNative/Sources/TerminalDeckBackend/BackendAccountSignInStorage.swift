import Foundation

/// Accounts added while an earlier helper is still running use the AI's own
/// login store in this app-owned folder. That helper knows configDir, but only
/// calls the old profiles/ root app-kept. A current helper can adopt these.
public enum BackendAccountSignInStorage {
    /// A fallback login must be read from its own AI folder, rather than an
    /// outer session's secure-storage redirect or authentication override.
    public static func environment(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration, path: String) -> [String: String] {
        var environment = BackendAppAccountSignInParsing.accountEnvironment(profile, provider: profile.provider,
            inherited: configuration.inheritedEnvironment, path: path, vaultVariables: configuration.vaultVariables)
        for key in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                    "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY"] {
            environment[key] = nil
        }
        return environment
    }
    public static func root(_ configuration: BackendAccountConfiguration) -> URL {
        configuration.accountLoginsRoot
    }
    public static func ownsFolder(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration) -> Bool {
        let root = root(configuration).standardizedFileURL, folder = URL(fileURLWithPath: profile.configDir).standardizedFileURL
        return !profile.system && folder.deletingLastPathComponent().path == root.path
            && root.resolvingSymlinksInPath().path == root.path && folder.resolvingSymlinksInPath().path == folder.path
            && BackendAccountFiles.descendant(folder.path, root: root.path)
    }
}
