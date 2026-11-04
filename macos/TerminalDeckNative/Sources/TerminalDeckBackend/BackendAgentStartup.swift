import Foundation

/// Invocation-only startup settings. Never writes the person's CLI configuration.
public enum BackendAgentStartup {
    // Verified with the installed Codex 0.159.3 using a scratch HOME/CODEX_HOME:
    // --strict-config accepted it; app-server config/read returned false.
    public static let codexArguments = ["-c", "check_for_update_on_startup=false"]
}
