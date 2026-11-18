import Foundation
import Security

/// Unlike the older encrypted login vault, API keys never use a file fallback, including dev copies.
public enum BackendAPIAccountKeychain {
    private static func query(_ record: BackendAPIAccountRecord) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: record.keychainService,
         kSecAttrAccount as String: record.keychainAccount, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    public enum Availability: String, Sendable, Error, LocalizedError {
        case available, missing, accessUnavailable, differentEndpoint

        public var errorDescription: String? { detail }
        public var detail: String {
            switch self {
            case .available: "API credential configured"
            case .missing: "No API key is saved for this account. Enter its key to switch."
            case .accessUnavailable: "Keychain could not check this account's API key. Unlock the login Keychain, then try again."
            case .differentEndpoint: "The saved API key belongs to this account's previous connection. Enter a key for the current endpoint."
            }
        }
    }
    /// Metadata only, without a prompt or credential bytes. Absence is not an access denial.
    public static func availability(_ record: BackendAPIAccountRecord) -> Availability {
        var lookup = query(record)
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        return availability(status: status, attributes: value as? [String: Any], record: record)
    }
    static func availability(status: OSStatus, attributes: [String: Any]?, record: BackendAPIAccountRecord) -> Availability {
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let attributes else { return .accessUnavailable }
        return attributes[kSecAttrGeneric as String] as? Data == record.credentialScope ? .available : .differentEndpoint
    }
    public static func contains(_ record: BackendAPIAccountRecord) -> Bool { availability(record) == .available }
    public static func read(_ record: BackendAPIAccountRecord) throws -> String {
        var query = query(record); query[kSecReturnData as String] = true; query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let attributes = value as? [String: Any] else {
            throw status == errSecItemNotFound ? Availability.missing : Availability.accessUnavailable
        }
        guard attributes[kSecAttrGeneric as String] as? Data == record.credentialScope else {
            throw Availability.differentEndpoint
        }
        guard
              let data = attributes[kSecValueData as String] as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw BackendAccountFailure("The saved API key could not be read. Enter its key again in this account’s secure field.")
        }
        return key
    }
    /// Cloud must distinguish a missing item from denied access; neither means an empty key.
    static func cloudRead(_ record: BackendAPIAccountRecord) throws -> String? {
        var lookup = query(record)
        lookup[kSecReturnData as String] = true; lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        let attributes = value as? [String: Any]
        let state = availability(status: status, attributes: attributes, record: record)
        guard state == .available else { throw state }
        guard let bytes = attributes?[kSecValueData as String] as? Data,
              let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
            throw BackendAccountFailure("The saved API key could not be read.")
        }
        return key
    }
    public static func validate(_ key: String) throws {
        guard (8...8192).contains(key.utf8.count), key.utf8.allSatisfy({ (0x21...0x7e).contains($0) && $0 != 34 && $0 != 92 }) else {
            throw BackendAccountFailure("Enter a plain API key or token of 8 to 8192 characters, without spaces.")
        }
    }
    public static func write(_ key: String, record: BackendAPIAccountRecord, trustedExecutables: [URL], onlyIfAbsent: Bool = false) throws {
        try validate(key)
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrGeneric as String: record.credentialScope]
        let updated = onlyIfAbsent ? errSecItemNotFound : SecItemUpdate(query(record) as CFDictionary, values as CFDictionary)
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
