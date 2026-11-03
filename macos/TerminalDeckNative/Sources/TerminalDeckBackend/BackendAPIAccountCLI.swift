import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendAPIAccountCLI {
    /// `revision`: the key revision this executable logged in with (18 Oct, #521); nil until a login has worked.
    struct Receipt: Codable, Equatable { let executable: String; var revision: Int? = nil }
    static let receiptName = "api-cli-owner.json"
    static func receipt(_ record: BackendAPIAccountRecord) -> Receipt? {
        guard let data = try? BackendAccountFiles.boundedRead(record.home.appendingPathComponent(receiptName), maximum: 4096) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }
    private static func quoted(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    public static func configure(_ record: BackendAPIAccountRecord) throws {
        switch record.provider {
        case "codex":
            var config = "cli_auth_credentials_store = \"keyring\"\n"
            if record.requiresKey { config += "forced_login_method = \"api\"\n" }
            if let model = record.model { config += "model = " + (try quoted(model)) + "\n" }
            if [.compatible, .compatibleLocal].contains(record.kind) {
                config += "model_provider = \"terminal_deck_api\"\n[model_providers.terminal_deck_api]\nname = \"API account\"\nbase_url = " + (try quoted(record.baseURL))
                config += "\nwire_api = \"responses\"\n"
                if record.requiresKey { config += "env_key = \"" + BackendAPIAccountRecord.customKeyVariable + "\"\n" }
            }
            config += "\n[shell_environment_policy]\nexclude = [\"*KEY*\", \"*TOKEN*\", \"*SECRET*\"]\n"
            try BackendAccountFiles.writeAtomic(Data(config.utf8), to: record.home.appendingPathComponent("config.toml"))
        case "gemini":
            let settings = ["security": ["auth": ["selectedType": "gemini-api-key"]]]
            try BackendAccountFiles.writeAtomic(JSONSerialization.data(withJSONObject: settings),
                to: record.home.appendingPathComponent(".gemini/settings.json"))
        default: break
        }
    }
    public static func prepare(_ record: BackendAPIAccountRecord, path: String, inherited: [String: String]) async throws {
        guard record.provider == "codex", record.requiresKey else { return }
        guard !FileManager.default.fileExists(atPath: record.home.appendingPathComponent("auth.json").path) else {
            throw BackendAccountFailure("This API account contains a file-backed Codex login. Keychain-only authentication is required.")
        }
        guard let binary = path.split(separator: ":").map({ URL(fileURLWithPath: String($0)).appendingPathComponent("codex") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw BackendAccountFailure("Install Codex before launching this API account.") }
        // 18 Oct (#521): this Codex already logged in with this key: no second login, no Keychain rewrite at every start.
        if let done = receipt(record), done.executable == binary.path, done.revision == record.credentialRevision { return }
        let key = try BackendAPIAccountKeychain.read(record)
        // Record only the executable, before creating its own Keychain login, so removal can log it out.
        try BackendAccountFiles.writeAtomic(JSONEncoder().encode(Receipt(executable: binary.path)),
            to: record.home.appendingPathComponent(receiptName))
        var environment = BackendAPIAccountEnvironment.clean(BackendSessionEnvironment.stripInherited(inherited))
        environment["PATH"] = path; environment["CODEX_HOME"] = record.configDirectory
        let ok = try await command(binary.path, arguments: ["login", "--with-api-key", "-c", "cli_auth_credentials_store=\"keyring\""],
            environment: environment, input: Data((key + "\n").utf8), keychainOnly: true)
        guard ok else { throw BackendAccountFailure("Codex could not save this account's API login in Keychain. No file fallback was used.") }
        try BackendAccountFiles.writeAtomic(JSONEncoder().encode(Receipt(executable: binary.path, revision: record.credentialRevision)),
            to: record.home.appendingPathComponent(receiptName))
    }
    public static func removeLogin(_ record: BackendAPIAccountRecord, inherited: [String: String]) async throws {
        guard record.provider == "codex", let data = try BackendAccountFiles.boundedRead(record.home.appendingPathComponent(receiptName), maximum: 4096) else { return }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard URL(fileURLWithPath: receipt.executable).lastPathComponent == "codex", FileManager.default.isExecutableFile(atPath: receipt.executable) else {
            throw BackendAccountFailure("The account's Codex executable is unavailable; its Keychain login was kept.")
        }
        var environment = BackendAPIAccountEnvironment.clean(BackendSessionEnvironment.stripInherited(inherited))
        environment["CODEX_HOME"] = record.configDirectory
        guard try await command(receipt.executable, arguments: ["logout", "-c", "cli_auth_credentials_store=\"keyring\""], environment: environment, input: nil) else {
            throw BackendAccountFailure("Codex could not remove this account's own Keychain login.")
        }
        try FileManager.default.removeItem(at: record.home.appendingPathComponent(receiptName))
    }
    /// Through the standard child runner: ten seconds, then its whole group (a helper Codex started too) is killed.
    private static func command(_ executable: String, arguments: [String], environment: [String: String], input: Data?, keychainOnly: Bool = false) async throws -> Bool {
        // Even a managed CLI policy cannot make this auth command write a plaintext fallback.
        let spec: NativeChild.Spec = keychainOnly
            ? .init("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)(deny file-write*)(allow file-write-data (literal \"/dev/null\"))", executable] + arguments,
                    environment: environment, output: .discard, errors: .discard)
            : .init(URL(fileURLWithPath: executable).path, arguments, environment: environment, output: .discard, errors: .discard)
        // Auth commands can echo credential fragments. Their output is never retained or returned; without
        // input its standard input is /dev/null.
        return try await NativeChild.run(spec, input: input, timeoutMilliseconds: 10_000).succeeded
    }
}
