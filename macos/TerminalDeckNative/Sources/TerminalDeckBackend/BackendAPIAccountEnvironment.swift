import Foundation
import TerminalDeckNativeCore

public enum BackendAPIAccountEnvironment {
    public static let apiKeyVariables: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
        "GEMINI_API_KEY", "GOOGLE_API_KEY", BackendAPIAccountRecord.customKeyVariable]
    public static let stripped: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_ACCESS_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_GENAI_USE_GCA", BackendAPIAccountRecord.customKeyVariable]
    private static let routing: Set<String> = ["ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "OPENAI_BASE_URL", "GOOGLE_GEMINI_BASE_URL", "GOOGLE_VERTEX_BASE_URL",
        "GOOGLE_GENAI_API_VERSION", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
    public static let subprocessScrub = "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"
    /// 17 Oct: an app session ran Claude Code's own updater, which left the shared global install with no `claude`
    /// and stopped every launch on this Mac. Every process the app starts is told not to update itself.
    public static let pinnedCLI: [String: String] = ["DISABLE_AUTOUPDATER": "1"]
    public static func clean(_ environment: [String: String]) -> [String: String] {
        environment.filter { !stripped.contains($0.key) }
    }
    public static func reference(_ record: BackendAPIAccountRecord) -> [String: String] {
        var values = BackendAccountStrategies.accountEnv(provider: record.provider, account: (record.provider, record.configDirectory))
        values[BackendAPIAccountRecord.referenceVariable] = record.reference
        return values
    }
    public static func expand(_ environment: [String: String], command: String,
                              readKey: (BackendAPIAccountRecord) throws -> String = BackendAPIAccountKeychain.read) throws -> (values: [String: String], secret: String?) {
        var expanded = try expandAccount(environment, command: command, readKey: readKey)
        expanded.values.merge(pinnedCLI) { _, pinned in pinned }
        return expanded
    }
    private static func expandAccount(_ environment: [String: String], command: String,
                                      readKey: (BackendAPIAccountRecord) throws -> String) throws -> (values: [String: String], secret: String?) {
        guard let reference = environment[BackendAPIAccountRecord.referenceVariable] else {
            // Existing account-vault/OAuth redirects remain untouched; ambient API keys do not.
            return (environment.filter { !apiKeyVariables.contains($0.key) }, nil)
        }
        var values = clean(environment).filter { !routing.contains($0.key) }
        values[BackendAPIAccountRecord.referenceVariable] = nil
        let record = try BackendAPIAccountRecord.fromReference(reference)
        guard let configEnv = BackendAccountProfile.configEnvironment(record.provider),
              values[configEnv] == nil || values[configEnv] == record.configDirectory,
              [record.provider, "node", "bun", "sandbox-exec"].contains(URL(fileURLWithPath: command).lastPathComponent) else {
            throw BackendAccountFailure("This API key can only be used by its own AI account launch.")
        }
        // CODEX_HOME is deliberately stripped from generic launcher environments.
        // The authenticated account reference restores only its own home at exec.
        values[configEnv] = record.configDirectory
        if !record.requiresKey { return (values, nil) }
        let key = try readKey(record)
        switch record.kind {
        // Claude Code's own scrub keeps its Anthropic credentials out of the Bash tool, hooks and MCP children
        // (CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, read by the installed CLI 2.1.299), so `env` cannot put the key in a transcript.
        case .anthropic: values["ANTHROPIC_API_KEY"] = key; values["ANTHROPIC_BASE_URL"] = record.baseURL; values[subprocessScrub] = "1"
        case .anthropicToken: values["ANTHROPIC_AUTH_TOKEN"] = key; values["ANTHROPIC_BASE_URL"] = record.baseURL; values[subprocessScrub] = "1"
        case .openai: values["OPENAI_API_KEY"] = key; values["CODEX_API_KEY"] = key
        case .compatible: values[BackendAPIAccountRecord.customKeyVariable] = key
        case .compatibleLocal: break
        case .gemini:
            values["GEMINI_API_KEY"] = key
            values["GOOGLE_GEMINI_BASE_URL"] = try record.endpoint().deletingLastPathComponent().absoluteString
            values["GOOGLE_GENAI_API_VERSION"] = "v1beta"
        }
        // Ambient ANTHROPIC_CUSTOM_HEADERS was dropped with the other routing variables above, so this is the only value.
        if [.anthropic, .anthropicToken].contains(record.kind), let workspace = record.workspaceID { values["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + workspace }
        if let model = record.model {
            if record.provider == "claude" { values["ANTHROPIC_MODEL"] = model }
            if record.provider == "gemini" { values["GEMINI_MODEL"] = model }
        }
        return (values, key)
    }
}

/// Retain only a possible secret prefix across chunks, so normal terminal prompts are not delayed.
final class BackendAPISecretStream {
    private let secret: Data
    private var pending = Data()
    init(_ secret: String?) { self.secret = Data((secret ?? "").utf8) }
    func feed(_ bytes: Data) -> Data {
        guard !secret.isEmpty else { return bytes }
        pending.append(bytes)
        var result = Data()
        while let range = pending.range(of: secret) {
            result.append(pending[..<range.lowerBound]); result.append(Data("[redacted]".utf8))
            pending.removeSubrange(..<range.upperBound)
        }
        var kept = min(secret.count - 1, pending.count)
        while kept > 0, !secret.starts(with: pending.suffix(kept)) { kept -= 1 }
        result.append(pending.prefix(pending.count - kept)); pending = Data(pending.suffix(kept))
        return result
    }
    func finish() -> Data {
        guard !pending.isEmpty else { return Data() }
        pending = Data(); return Data("[redacted]".utf8)
    }
}
