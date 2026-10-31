import Foundation
import Security

/// Unlike the older encrypted login vault, API keys never use a file fallback, including dev copies.
public enum BackendAPIAccountKeychain {
    private static func query(_ record: BackendAPIAccountRecord) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: record.keychainService,
         kSecAttrAccount as String: record.keychainAccount, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    public static func contains(_ record: BackendAPIAccountRecord) -> Bool {
        var query = query(record); query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let attributes = value as? [String: Any] else { return false }
        return attributes[kSecAttrGeneric as String] as? Data == record.credentialScope
    }
    public static func read(_ record: BackendAPIAccountRecord) throws -> String {
        var query = query(record); query[kSecReturnData as String] = true; query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let attributes = value as? [String: Any] else {
            throw BackendAccountFailure("The API key is missing or Keychain access is unavailable (\(status)).")
        }
        guard attributes[kSecAttrGeneric as String] as? Data == record.credentialScope else {
            throw BackendAccountFailure("Enter an API key for this connection's endpoint.")
        }
        guard
              let data = attributes[kSecValueData as String] as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw BackendAccountFailure("The API key is missing or Keychain access is unavailable (\(status)).")
        }
        return key
    }
    public static func validate(_ key: String) throws {
        guard (8...8192).contains(key.utf8.count), key.utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 34 && $0 != 92 }) else {
            throw BackendAccountFailure("Enter a plain API key or token of 8 to 8192 characters, without spaces.")
        }
    }
    public static func write(_ key: String, record: BackendAPIAccountRecord, trustedExecutables: [URL]) throws {
        try validate(key)
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrGeneric as String: record.credentialScope]
        let updated = SecItemUpdate(query(record) as CFDictionary, values as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw BackendAccountFailure("Keychain could not update this API key (\(updated)).") }
        var item = query(record); item[kSecValueData as String] = Data(key.utf8); item[kSecAttrGeneric as String] = record.credentialScope
        var trusted: [SecTrustedApplication] = []
        for path in trustedExecutables {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path.path, &app) == errSecSuccess, let app { trusted.append(app) }
        }
        guard !trusted.isEmpty else { throw BackendAccountFailure("The app's signed Keychain clients are unavailable.") }
        var access: SecAccess?
        guard SecAccessCreate("AI API account" as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
            throw BackendAccountFailure("The API key's Keychain access could not be restricted to the app.")
        }
        item[kSecAttrAccess as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw BackendAccountFailure("Keychain could not save this API key (\(status)).") }
    }
    public static func remove(_ record: BackendAPIAccountRecord) throws {
        let status = SecItemDelete(query(record) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackendAccountFailure("Keychain could not remove this API key (\(status)).")
        }
    }
}
