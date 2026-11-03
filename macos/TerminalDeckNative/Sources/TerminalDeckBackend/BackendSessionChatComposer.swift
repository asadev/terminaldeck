import Foundation
import TerminalDeckNativeCore

/// The account's existing Claude Fast mode flag and a per-chat launch override.
enum BackendSessionChatComposer {
    static func fastMode(provider: HootChatProvider, configDir: String?, catalogue: NativeRPCValue,
                         arguments: [String], choice: String?) -> Bool? {
        guard provider == .claude else { return nil }
        var available = catalogue["fastMode"]["available"].bool == true
        var on = catalogue["fastMode"]["on"].bool == true
        if let configDir, !configDir.isEmpty {
            let folder = URL(fileURLWithPath: configDir)
            // An app-kept account must never borrow the system account's entitlement.
            if folder.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL {
                available = json(folder.appendingPathComponent(".claude.json"))["penguinModeOrgEnabled"].bool == true
            }
            on = json(folder.appendingPathComponent("settings.json"))["fastMode"].bool == true
        }
        guard available else { return nil }
        if let choice { return choice == "true" }
        for (flag, value) in zip(arguments, arguments.dropFirst()) where flag == "--settings" {
            if let fast = settings(value)?["fastMode"].bool { on = fast }
        }
        return on
    }

    /// Keep hooks and other launch settings. The merged file stays in this chat's private folder,
    /// rather than putting account settings into process arguments or editing its account.
    static func applyingFastMode(_ arguments: [String], on: Bool, directory: URL) throws -> [String] {
        var merged = NativeRPCValue.object([]), kept: [String] = [], index = 0
        while index < arguments.count {
            if arguments[index] == "--settings" {
                guard index + 1 < arguments.count, let value = settings(arguments[index + 1]), let fields = value.fields else {
                    throw NativeRPCError.invalidArguments("The chat's Claude settings could not be read.")
                }
                for field in fields { merged = merged.setting(field.key, field.value) }
                index += 2
            } else { kept.append(arguments[index]); index += 1 }
        }
        merged = merged.setting("fastMode", .bool(on))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("composer-settings.json")
        // Atomic replacement retains a private mode, including when this file already exists.
        try merged.encodedJSON().write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return kept + ["--settings", file.path]
    }

    private static func settings(_ value: String) -> NativeRPCValue? {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try? NativeRPCValue.parseJSON(Data(value.utf8))
        }
        let read = json(URL(fileURLWithPath: value))
        return read.fields == nil ? nil : read
    }
    private static func json(_ file: URL) -> NativeRPCValue {
        guard let data = try? Data(contentsOf: file), data.count <= 32 * 1_048_576 else { return .null }
        return (try? NativeRPCValue.parseJSON(data)) ?? .null
    }
}

/// The options action of sessions_chat uses the same owner as the composer.
public enum BackendSessionChatOptionsTool {
    public static var schema: NativeRPCValue {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        return .object([.init("type", .string("object")), .init("properties", .object([
            .init("permissionMode", string), .init("model", string), .init("effort", string),
            .init("fastMode", .object([.init("type", .string("boolean")),
                .init("description", .string("Apply Fast mode from the next message, when this AI account supports it."))]))
        ])), .init("additionalProperties", .bool(false))])
    }
    public static func invoke(_ chats: BackendSessionChats, id: String, patch: NativeRPCValue = .null) async throws -> NativeRPCValue {
        patch.isNullish ? try await chats.options(id) : try await chats.setOptions(id, patch.requireObject("options"))
    }
}
