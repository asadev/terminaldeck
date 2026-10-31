import Foundation
import TerminalDeckNativeCore

/// SRV2: the app definition's options, saved as `options` in the app's server
/// record (BackendAppsStore). Single-file storage content is saved next to it
/// in `files/` (protected folder); a password is kept only as a bcrypt hash.
/// Callers hold the app lock for every change.
public struct BackendAppsSRV2Definition: Sendable {
    public let store: BackendAppsStore
    public let runtime: BackendAppsRuntime
    public init(store: BackendAppsStore, runtime: BackendAppsRuntime) { self.store = store; self.runtime = runtime }

    public static func options(_ record: NativeRPCValue) throws -> NativeAppsOptions {
        do { return try NativeAppsOptions.from(record["options"]) }
        catch { throw NativeRPCError(code: "state-failed", message: "The app's saved options are damaged.") }
    }

    /// Saved options with file contents filled in; `public` drops the password hash.
    public func read(_ serverID: String, _ appID: String, includeContent: Bool = true) async throws -> NativeAppsOptions {
        let record = try await store.read(serverID, appID)
        var options = try Self.options(record)
        if includeContent {
            for index in options.storage.indices where options.storage[index].kind == .file {
                let id = options.storage[index].source
                guard id.range(of: #"^f-[a-f0-9]{16}$"#, options: .regularExpression) != nil else { continue }
                if let data = try await store.readFile(serverID, path: try store.directory(appID) + "/files/" + id) {
                    options.storage[index].content = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return options
    }

    /// Replaces the options. A new plain password is hashed here; an unchanged
    /// user name with no new password keeps the saved hash. Files are saved by
    /// content, and files no longer used are removed.
    public func apply(_ serverID: String, _ appID: String, _ requested: NativeAppsOptions,
                      hasher: @Sendable (String) throws -> String = { try BackendAppsSRV2Bcrypt.hash($0) }) async throws -> (record: NativeRPCValue, options: NativeAppsOptions) {
        try requested.validate()
        let record = try await store.read(serverID, appID)
        guard record["kind"].string == "app" else { throw NativeRPCError.invalidArguments("Only apps have these options; databases keep their own settings.") }
        let saved = try Self.options(record)
        var next = requested
        if let password = requested.web.password {
            if let plain = password.password {
                next.web.password = .init(username: password.username, hash: try hasher(plain))
            } else if let hash = saved.web.password?.hash, saved.web.password?.username == password.username {
                next.web.password = .init(username: password.username, hash: hash)
            } else if let hash = password.hash, NativeAppsOptions.isBcrypt(hash) {
                next.web.password = .init(username: password.username, hash: hash)
            } else {
                throw NativeRPCError.invalidArguments("Enter a password for \(password.username).")
            }
        }
        let directory = try store.directory(appID)
        var keep = Set<String>()
        for index in next.storage.indices where next.storage[index].kind == .file {
            var mount = next.storage[index]
            if let content = mount.content {
                let id = "f-" + String(BackendAppsSRV2Recipe.sha256Hex(appID + "\n" + mount.path + "\n" + content).prefix(16))
                var exists = mount.source == id
                if exists { exists = try await store.readFile(serverID, path: directory + "/files/" + id) != nil }
                if !exists {
                    try await store.writeFile(serverID, path: directory + "/files/" + id, contents: Data(content.utf8))
                }
                mount.source = id
            } else {
                guard saved.storage.contains(where: { $0.kind == .file && $0.source == mount.source && !mount.source.isEmpty }) else {
                    throw NativeRPCError.invalidArguments("Add the text for the file at \(mount.path).")
                }
            }
            mount.content = nil
            keep.insert(mount.source)
            next.storage[index] = mount
        }
        try next.validate()
        var stored = next
        stored.web.password = next.web.password.map { .init(username: $0.username, hash: $0.hash) }
        let updated = record.setting("options", try stored.value()).setting("updatedAt", .number(runtime.now()))
        try await store.write(serverID, appID, updated)
        // A running deploy may still mount the earlier files; they go at the next save.
        if record["pendingDeploymentId"].isNullish { try await pruneFiles(serverID, directory: directory, keep: keep) }
        return (updated, stored)
    }

    func pruneFiles(_ serverID: String, directory: String, keep: Set<String>) async throws {
        let q = BackendAppsRuntime.quote
        let keepList = keep.sorted().map { "! -name " + q($0) }.joined(separator: " ")
        let script = "test -d \(q(directory + "/files")) || exit 0; test ! -L \(q(directory + "/files")) || exit 45; find \(q(directory + "/files")) -maxdepth 1 -type f -name 'f-*' \(keepList) -delete"
        let result = try await runtime.run(serverID, script, timeoutMS: 15_000, maximumBytes: 4096)
        guard result.code == 0 else { throw NativeRPCError(code: "state-failed", message: "Old storage files could not be cleaned up. The new options were saved.") }
    }

    /// The plain object accepted by apps:options:apply (validated again in apply).
    public static func requested(_ value: NativeRPCValue) throws -> NativeAppsOptions {
        guard value.fields != nil else { throw NativeRPCError.invalidArguments("options must be an object.") }
        let allowedTop: Set<String> = ["version", "build", "steps", "health", "web", "storage"]
        guard (value.fields ?? []).allSatisfy({ allowedTop.contains($0.key) }) else { throw NativeRPCError.invalidArguments("options has unsupported fields.") }
        var options = try NativeAppsOptions.from(value)
        if value["version"].isNullish { options.version = NativeAppsOptions.currentVersion }
        return options
    }
}
