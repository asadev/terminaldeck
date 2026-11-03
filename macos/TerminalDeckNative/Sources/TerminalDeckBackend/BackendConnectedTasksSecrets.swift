import Foundation
import Security
import TerminalDeckNativeCore

/// Where a connected task system's access token is kept. Never the settings file.
public protocol BackendConnectedTasksSecrets: Sendable {
    func read(_ connectionID: String) throws -> String?
    func write(_ connectionID: String, token: String) throws
    func remove(_ connectionID: String) throws
}

/// The app's store: one Keychain item per connection in the app's own service
/// ("<app> Connected Tasks"), readable only on this Mac after first unlock, never
/// prompting (a locked or denied item makes only that connection unavailable).
public struct BackendConnectedTasksKeychain: BackendConnectedTasksSecrets {
    public let service: String
    private let devFileName: String
    public init(appName: String) { service = appName + " Connected Tasks"; devFileName = "connected-tasks" }
    /// Another feature's own keychain service ("<app> <namespace>") and dev-copy folder, never shared with connected tasks.
    public init(appName: String, namespace: String, devFile: String) { service = appName + " " + namespace; devFileName = devFile }
    /// The dev copy keeps its tokens in owner-only files in its own data folder, never in the keychain (see BackendDevCopy).
    private var dev: BackendConnectedTasksDevFiles? {
        if let folder = BackendAccountDevKey.devFile(named: devFileName) { return .init(folder: folder) }
        return nil
    }
    private func refuseDevWithoutFolder() throws {
        if service.hasPrefix(BackendDevCopy.name + " ") {
            throw NativeRPCError(code: "unavailable", message: "The dev copy keeps its tokens in its own data folder, which is not open yet.")
        }
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    public func read(_ connectionID: String) throws -> String? {
        if let dev { return try dev.read(connectionID) }
        try refuseDevWithoutFolder()
        var query = query(connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else {
            throw NativeRPCError(code: "unavailable", message: "The saved access token could not be read from the Keychain (status \(status)).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ connectionID: String, token: String) throws {
        if let dev { return try dev.write(connectionID, token: token) }
        try refuseDevWithoutFolder()
        let data = Data(token.utf8)
        let updated = SecItemUpdate(query(connectionID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NativeRPCError(code: "unavailable", message: "macOS refused to save the access token (status \(updated)).")
        }
        var attributes = query(connectionID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw NativeRPCError(code: "unavailable", message: "macOS refused to save the access token (status \(added)).")
        }
    }

    public func remove(_ connectionID: String) throws {
        if let dev { return try dev.remove(connectionID) }
        try refuseDevWithoutFolder()
        let status = SecItemDelete(query(connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NativeRPCError(code: "unavailable", message: "The access token could not be removed from the Keychain (status \(status)).")
        }
    }
}

/// Tests and scratch runs: kept in memory only.
public final class BackendConnectedTasksMemorySecrets: BackendConnectedTasksSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func read(_ connectionID: String) throws -> String? { lock.withLock { values[connectionID] } }
    public func write(_ connectionID: String, token: String) throws { lock.withLock { values[connectionID] = token } }
    public func remove(_ connectionID: String) throws { _ = lock.withLock { values.removeValue(forKey: connectionID) } }
}
