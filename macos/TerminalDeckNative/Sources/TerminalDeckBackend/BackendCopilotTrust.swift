import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendCopilotTrustOutcome: String, Equatable, Sendable { case recorded, already, refused, failed }
public enum BackendCopilotTrust {
    public static func configFile(_ directory: String) -> String { BackendCopilotStorageIO.join(directory, ".claude.json") }
    public static func trustFile(overrides: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let named = BackendSharedText.trim(overrides["CLAUDE_CONFIG_DIR"] ?? environment["CLAUDE_CONFIG_DIR"] ?? "")
        return named.isEmpty ? BackendCopilotStorageIO.join(home, ".claude.json") : configFile(named)
    }
    /// Existing true and false decisions are both kept; corrupt/foreign config is never replaced.
    public static func trustFolder(file: String, folder: String) -> BackendCopilotTrustOutcome {
        let resolved = BackendCopilotStorageIO.resolved(folder)
        var config: NativeRPCValue = .object([])
        do {
            config = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: file)))
            if config.fields == nil { return .failed }
        } catch { if !BackendCopilotStorageIO.isMissing(error) { return .failed } }
        let table = config["projects"].fields == nil ? NativeRPCValue.object([]) : config["projects"]
        let existing = table[resolved].fields == nil ? NativeRPCValue.object([]) : table[resolved]
        if existing["hasTrustDialogAccepted"] == .bool(true) { return .already }
        if existing["hasTrustDialogAccepted"] == .bool(false) { return .refused }
        // A test copy leaves the person's own agent config to their running app.
        if BackendSessionHookInstallation.agentConfigReadOnly { return .failed }
        let next = config.setting("projects", table.setting(resolved, existing.setting("hasTrustDialogAccepted", .bool(true))))
        do {
            try BackendCopilotStorageIO.mkdir(URL(fileURLWithPath: file).deletingLastPathComponent().path, mode: 0o777)
            let scratch = file + ".deck-" + String(getpid())
            let text = String(decoding: try next.encodedJSON(pretty: true), as: UTF8.self) + "\n"
            // Source writeFileSync default permissions for the CLI's own file.
            try BackendCopilotStorageIO.write(scratch, text, mode: 0o666)
            try BackendCopilotStorageIO.rename(scratch, file)
            return .recorded
        } catch { return .failed }
    }
}
