import Foundation
import CryptoKit
import Security

/// The Receiver's own key, in its own Keychain item ("<app> Receiver Key"): never
/// the Electron safe-storage item, never someone else's. Created on the first save
/// when missing; never asks the person (no Keychain prompt). A locked or denied
/// item makes only the Receiver unavailable, never the app.
public struct BackendRCVKeychainCipher: BackendAccountVaultCipher {
    public let service: String
    public init(appName: String) { service = appName + " Receiver Key" }

    public func available() -> Bool { true }
    public func prepareForWrites(existingVault: Bool) throws { _ = try key(create: true) }

    public func decrypt(_ blob: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: blob)
        return String(decoding: try AES.GCM.open(box, using: try key(create: false)), as: UTF8.self)
    }

    public func encrypt(_ text: String, existingVault: Bool) throws -> Data {
        guard let combined = try AES.GCM.seal(Data(text.utf8), using: try key(create: true)).combined else {
            throw NativeRPCErrorShim.failure("The Receiver could not encrypt its data.")
        }
        return combined
    }

    private func key(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "receiver", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess, let bytes = found as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        guard status == errSecItemNotFound, create else {
            throw NativeRPCErrorShim.failure(status == errSecItemNotFound
                ? "The Receiver's key is missing from the Keychain, so its saved data cannot be read."
                : "The Receiver's Keychain key is locked or was denied (status \(status)).")
        }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "receiver", kSecValueData as String: bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(create: false) }
        guard added == errSecSuccess else { throw NativeRPCErrorShim.failure("macOS refused to create the Receiver's Keychain key (status \(added)).") }
        return SymmetricKey(data: bytes)
    }
}

enum NativeRPCErrorShim {
    static func failure(_ message: String) -> Error { BackendAccountFailure(message) }
}
