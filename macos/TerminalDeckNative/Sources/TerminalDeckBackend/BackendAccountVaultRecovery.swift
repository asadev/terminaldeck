import Foundation
import Security
import TerminalDeckNativeCore

/// App-only recovery. Startup never asks macOS for permission. The explicit
/// button extends the existing item's access; neither Keychain item is deleted.
public struct BackendAccountVaultRecovery: Sendable {
    public static let permissionStep = "Click Allow login store below. If the Mac asks, click Always Allow so the app and its background helper can open your saved logins."
    public let configuration: BackendAccountConfiguration
    public init(configuration: BackendAccountConfiguration) { self.configuration = configuration }
    private var file: URL { configuration.dataDirectory.appendingPathComponent("account-vault/account-vault.bin") }
    private var keychain: BackendAccountStorageKeychain { .init(appName: configuration.appName, executables: trustedExecutables) }
    private var trustedExecutables: [String] {
        var paths: [String?] = [Bundle.main.executableURL?.path, configuration.helperExecutable.path]
        if let executable = Bundle.main.executableURL {
            paths += [executable.deletingLastPathComponent().appendingPathComponent("TerminalDeckSessionHostHelper").path]
        }
        // Include the signed copies currently holding sessions. No process is
        // contacted, stopped or restarted; trust uses their code requirements.
        let root = configuration.dataDirectory.appendingPathComponent("host/agents")
        for child in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            paths.append(BackendHOSTLaunchAgent.keeperExecutable(in: child).path)
        }
        return Array(Set(paths.compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0) })).sorted()
    }
    public func status() throws -> NativeRPCValue {
        if configuration.appName == BackendDevCopy.name {
            let cipher = BackendAccountKeychainCipher(appName: configuration.appName)
            do { try cipher.prepareForWrites(existingVault: FileManager.default.fileExists(atPath: file.path)); return answer(ready: true) }
            catch { return answer(ready: false, detail: "The dev copy needs its own original store.key restored in its data folder.") }
        }
        do {
            let native = try keychain.password(account: configuration.appName, interaction: false)
            if let encoded = try BackendAccountFiles.boundedRead(file, maximum: BackendAccountVault.maximumFile) {
                _ = try BackendAccountVaultMigration.validatedPlain(encoded, password: native)
            }
            return answer(ready: true, permission: !keychain.helpersTrusted(account: configuration.appName))
        } catch { return answer(ready: false, permission: true) }
    }
    private func answer(ready: Bool, permission: Bool = false, detail: String? = nil) -> NativeRPCValue {
        .object([.init("ready", .bool(ready)), .init("needsPermission", .bool(permission)),
            .init("detail", .string(detail ?? (permission ? Self.permissionStep : "The login store is open.")))])
    }
    /// Safe to call in the app before attaching its helper. No dialog and no
    /// replacement key for an Electron upgrade. Existing decryptable legacy
    /// data is backed up before re-encryption with the existing native key.
    @discardableResult public func prepareIfFreshOrMigratable() throws -> NativeRPCValue {
        if configuration.appName == BackendDevCopy.name { return try status() }
        let storage = keychain
        if !FileManager.default.fileExists(atPath: file.path) {
            if !storage.exists(account: configuration.appName), !storage.exists(account: configuration.appName + " Key") {
                _ = try storage.createNativeKey(interaction: false)
            }
            return try status()
        }
        guard let native = try? storage.password(account: configuration.appName, interaction: false),
              let legacy = try? storage.password(account: configuration.appName + " Key", interaction: false) else { return try status() }
        _ = try BackendAccountVaultMigration.migrate(file: file, legacyPassword: legacy, nativePassword: native,
            backupRoot: backupRoot)
        return try status()
    }
    /// Beside the app's other account backups, inside its own data folder (never a folder of its own in the home folder).
    var backupRoot: URL {
        configuration.dataDirectory.appendingPathComponent("account-backups", isDirectory: true)
    }
    /// This method is reached only from the person's in-app button. The
    /// caller must enforce nativeApp ownership; no tool can authorize prompts.
    public func recover() throws -> NativeRPCValue {
        if configuration.appName == BackendDevCopy.name { return try status() }
        let storage = keychain
        let native: Data
        if storage.exists(account: configuration.appName) {
            native = try storage.password(account: configuration.appName, interaction: true)
        } else {
            // Read the original first; a denied/missing old key never produces
            // an incompatible new key for an existing vault.
            if FileManager.default.fileExists(atPath: file.path) {
                let legacy = try storage.password(account: configuration.appName + " Key", interaction: true)
                let encoded = try Data(contentsOf: file)
                _ = try BackendAccountVaultMigration.validatedPlain(encoded, password: legacy)
            }
            native = try storage.createNativeKey(interaction: true)
        }
        if FileManager.default.fileExists(atPath: file.path),
           (try? BackendAccountVaultMigration.validatedPlain(Data(contentsOf: file), password: native)) == nil {
            let legacy = try storage.password(account: configuration.appName + " Key", interaction: true)
            _ = try BackendAccountVaultMigration.migrate(file: file, legacyPassword: legacy, nativePassword: native, backupRoot: backupRoot)
        }
        try storage.allowHelpers(account: configuration.appName)
        return try status()
    }
}

/// Pure file migration with injected keys. Plaintext remains only in memory.
public enum BackendAccountVaultMigration {
    static func validatedPlain(_ encoded: Data, password: Data) throws -> String {
        guard let blob = Data(base64Encoded: String(decoding: encoded, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BackendAccountFailure("The saved login store is not valid. Restore its backup before trying again.")
        }
        let plain = try ChromiumSafeStorageCipher.decrypt(blob, password: password)
        let raw = try NativeRPCValue.parseJSON(Data(plain.utf8), maximumBytes: BackendAccountVault.maximumFile)
        guard raw["version"].number == 1, raw["entries"].elements != nil else {
            throw BackendAccountFailure("This login store uses a different format. Update Terminal Deck before opening it.")
        }
        return plain
    }
    @discardableResult public static func migrate(file: URL, legacyPassword: Data, nativePassword: Data, backupRoot: URL) throws -> URL? {
        guard let before = try BackendAccountFiles.boundedRead(file, maximum: BackendAccountVault.maximumFile) else { return nil }
        if (try? validatedPlain(before, password: nativePassword)) != nil { return nil }
        let plain = try validatedPlain(before, password: legacyPassword)
        let replacement = Data(try ChromiumSafeStorageCipher.encrypt(plain, password: nativePassword).base64EncodedString().utf8)
        _ = try validatedPlain(replacement, password: nativePassword)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = backupRoot.appendingPathComponent("account-vault-before-install18-" + stamp + "-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only the store file changes, so only it is copied. The folder also holds the helper's live socket, which
        // cannot be copied (the whole-folder copy failed while sessions ran), and each seat's own working files.
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
        guard try Data(contentsOf: backup.appendingPathComponent(file.lastPathComponent)) == before,
              try BackendAccountFiles.boundedRead(file, maximum: BackendAccountVault.maximumFile) == before else {
            throw BackendAccountFailure("The login store changed while it was being backed up. Click Allow login store to try again.")
        }
        try BackendAccountFiles.writeAtomic(replacement, to: file)
        return backup
    }
}

private struct BackendAccountStorageKeychain {
    let appName: String
    let executables: [String]
    private var service: String { appName + " Safe Storage" }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne]
    }
    private func failure(_ status: OSStatus) -> BackendAccountFailure {
        .init("macOS could not open the login store (Keychain status \(status)). " + BackendAccountVaultRecovery.permissionStep)
    }
    func exists(account: String) -> Bool {
        SecKeychainSetUserInteractionAllowed(false)
        var q = query(account); q[kSecReturnAttributes as String] = true; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(q as CFDictionary, nil) != errSecItemNotFound
    }
    func password(account: String, interaction: Bool) throws -> Data {
        SecKeychainSetUserInteractionAllowed(interaction)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        var q = query(account); q[kSecReturnData as String] = true
        q[kSecUseAuthenticationUI as String] = interaction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var found: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data, !data.isEmpty else { throw failure(status) }
        return data
    }
    private func trusted() throws -> [SecTrustedApplication] {
        try executables.map { path in
            var app: SecTrustedApplication?; let status = SecTrustedApplicationCreateFromPath(path, &app)
            guard status == errSecSuccess, let app else { throw failure(status) }; return app
        }
    }
    func createNativeKey(interaction: Bool) throws -> Data {
        SecKeychainSetUserInteractionAllowed(interaction)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw BackendAccountFailure("macOS could not prepare the login store. Try Allow login store again.") }
        let data = Data(Data(random).base64EncodedString().utf8)
        var access: SecAccess?; let status = SecAccessCreate((appName + " login store") as CFString, try trusted() as CFArray, &access)
        guard status == errSecSuccess, let access else { throw failure(status) }
        var q = query(appName); q.removeValue(forKey: kSecMatchLimit as String)
        q[kSecValueData as String] = data; q[kSecAttrAccess as String] = access
        let added = SecItemAdd(q as CFDictionary, nil)
        if added == errSecDuplicateItem { return try password(account: appName, interaction: interaction) }
        guard added == errSecSuccess else { throw failure(added) }; return data
    }
    private func item(_ account: String) throws -> SecKeychainItem {
        var q = query(account); q[kSecReturnRef as String] = true; q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &found)
        guard status == errSecSuccess, let found else { throw failure(status) }
        return unsafeBitCast(found, to: SecKeychainItem.self)
    }
    func helpersTrusted(account: String) -> Bool {
        guard let item = try? item(account) else { return false }
        var access: SecAccess?; guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access else { return false }
        var acls: CFArray?; guard SecAccessCopyACLList(access, &acls) == errSecSuccess, let acls = acls as? [SecACL] else { return false }
        let helpers = executables.filter { URL(fileURLWithPath: $0).lastPathComponent.contains("Helper") }
        guard !helpers.isEmpty else { return false }
        return acls.contains { acl in
            guard let tags = SecACLCopyAuthorizations(acl) as? [String], tags.contains(kSecACLAuthorizationDecrypt as String) else { return false }
            var apps: CFArray?, description: CFString?, selector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &selector) == errSecSuccess else { return false }
            guard let apps else { return true }
            let trusted = apps as? [SecTrustedApplication] ?? []
            return helpers.allSatisfy { path in
                var expected: SecTrustedApplication?, expectedData: CFData?
                guard SecTrustedApplicationCreateFromPath(path, &expected) == errSecSuccess, let expected,
                      SecTrustedApplicationCopyData(expected, &expectedData) == errSecSuccess, let expectedData else { return false }
                return trusted.contains { app in
                    var data: CFData?
                    return SecTrustedApplicationCopyData(app, &data) == errSecSuccess && data.map { CFEqual($0, expectedData) } == true
                }
            }
        }
    }
    func allowHelpers(account: String) throws {
        SecKeychainSetUserInteractionAllowed(true)
        defer { SecKeychainSetUserInteractionAllowed(false) }
        let item = try item(account)
        var access: SecAccess?; let status = SecKeychainItemCopyAccess(item, &access)
        guard status == errSecSuccess, let access else { throw failure(status) }
        var acls: CFArray?; let copied = SecAccessCopyACLList(access, &acls)
        guard copied == errSecSuccess, let acls = acls as? [SecACL] else { throw failure(copied) }
        let additional = try trusted()
        for acl in acls {
            guard let tags = SecACLCopyAuthorizations(acl) as? [String], tags.contains(kSecACLAuthorizationDecrypt as String) else { continue }
            var apps: CFArray?, description: CFString?, selector = SecKeychainPromptSelector()
            let read = SecACLCopyContents(acl, &apps, &description, &selector)
            guard read == errSecSuccess, let description else { throw failure(read) }
            if apps == nil { continue } // Already permits every app; preserve it.
            let combined = (apps as? [SecTrustedApplication] ?? []) + additional
            let changed = SecACLSetContents(acl, combined as CFArray, description, selector)
            guard changed == errSecSuccess else { throw failure(changed) }
        }
        let changed = SecKeychainItemSetAccess(item, access)
        guard changed == errSecSuccess else { throw failure(changed) }
    }
}
