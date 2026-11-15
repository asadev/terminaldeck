import Foundation
import Security
import TerminalDeckNativeCore

/// Uses the instance's existing protected-store owner, scoped to Cloud identity
/// and device. It never creates or reads a legacy vault key itself.
public actor BackendCloudSecretsProtectedStore: CloudSecretsLocalKeyPort, CloudSecretsHandOverBookPort, CloudSecretsLocalKeyForgetPort {
    private let subject: CloudSubject
    private let deviceId: String
    private let readValue: @Sendable () async throws -> Data?
    private let writeValue: @Sendable (Data) async throws -> Void
    private let archiveWrite: @Sendable (Int, Data) async throws -> Void
    private let archiveRead: @Sendable (Int) async throws -> Data?
    private let seenRead: @Sendable () async throws -> Data?
    private let seenWrite: @Sendable (Data) async throws -> Void
    private let bookRead: @Sendable () async throws -> Data?
    private let bookWrite: @Sendable (Data) async throws -> Void
    /// Design B4 only (signed out by another device): removes the slot, one older generation's item, the seen mark and the
    /// book. Not wired = the forget throws and nothing is removed.
    private let removeKeys: @Sendable (_ archiveEpochs: [Int]) async throws -> Void
    /// `archiveWrite`/`archiveRead`: one item per older epoch beside the slot.
    /// Without them an older key cannot be kept, so a newer one is refused.
    public init(subject: CloudSubject, deviceId: String,
                read: @escaping @Sendable () async throws -> Data?,
                write: @escaping @Sendable (Data) async throws -> Void,
                archiveWrite: @escaping @Sendable (Int, Data) async throws -> Void = { _, _ in throw CloudFailure.unavailable },
                archiveRead: @escaping @Sendable (Int) async throws -> Data? = { _ in throw CloudFailure.unavailable },
                seenRead: @escaping @Sendable () async throws -> Data? = { nil },
                seenWrite: @escaping @Sendable (Data) async throws -> Void = { _ in },
                bookRead: @escaping @Sendable () async throws -> Data? = { throw CloudFailure.unavailable },
                bookWrite: @escaping @Sendable (Data) async throws -> Void = { _ in throw CloudFailure.unavailable },
                removeKeys: @escaping @Sendable ([Int]) async throws -> Void = { _ in throw CloudFailure.unavailable }) {
        self.removeKeys = removeKeys
        self.subject = subject; self.deviceId = deviceId; readValue = read; writeValue = write
        self.archiveWrite = archiveWrite; self.archiveRead = archiveRead; self.seenRead = seenRead; self.seenWrite = seenWrite
        self.bookRead = bookRead; self.bookWrite = bookWrite
    }
    public func seenCloudEpoch() async throws -> Int? {
        guard let bytes = try await seenRead() else { return nil }
        guard let value = Int(String(decoding: bytes, as: UTF8.self)), value > 0 else { throw CloudFailure.invalidRequest }
        return value
    }
    public func saveSeenCloudEpoch(_ epoch: Int) async throws {
        guard epoch > 0 else { throw CloudFailure.invalidRequest }
        try await seenWrite(Data(String(epoch).utf8))
    }
    public func archive(_ key: CloudSecretsLocalKey) async throws {
        guard key.subject == subject, key.deviceId == deviceId, key.root.count == 32, key.epoch > 0 else { throw CloudFailure.invalidRequest }
        try await archiveWrite(key.epoch, JSONEncoder().encode(key))
    }
    public func archived(epoch: Int) async throws -> CloudSecretsLocalKey? {
        guard epoch > 0, let bytes = try await archiveRead(epoch) else { return nil }
        let key = try CloudWire.decode(CloudSecretsLocalKey.self, from: bytes, maximumBytes: 4096)
        guard key.subject == subject, key.deviceId == deviceId, key.epoch == epoch, key.root.count == 32 else { throw CloudFailure.secretsLocked }
        return key
    }
    public func read() async throws -> CloudSecretsLocalKey? {
        guard let bytes = try await readValue() else { return nil }
        let key = try CloudWire.decode(CloudSecretsLocalKey.self, from: bytes, maximumBytes: 4096)
        guard key.subject == subject, key.deviceId == deviceId, key.root.count == 32,
              key.epoch > 0, key.version > .zero else { throw CloudFailure.secretsLocked }
        return key
    }
    /// The one slot name for this account on this device. Signing out and in
    /// again (a new device id) or switching accounts gets a fresh slot, so a key
    /// left by an earlier device id never blocks setup, words or approval.
    public static func slot(subject: CloudSubject, deviceId: String) -> String {
        CloudSecretsCrypto.hash(Data("TD-CLOUD-SECRETS-SLOT-1\n\(subject.issuer)\n\(subject.sub)\n\(deviceId)".utf8))
    }
    /// Production adapter for lane A: the login Keychain, service
    /// "<appName> Cloud Secrets", one item per account and device id. The dev
    /// copy uses the same Keychain under its own app name ("Terminal Deck Dev"),
    /// never a plain file another program running as this user could read
    /// (round-4 review S7). Read returns "nothing saved" only for
    /// errSecItemNotFound and throws on every other status (item 4, S09); it
    /// never shows a dialog.
    public static func keychain(appName: String, subject: CloudSubject, deviceId: String) -> BackendCloudSecretsProtectedStore {
        let account = Self.slot(subject: subject, deviceId: deviceId)
        let item = BackendCloudSecretsKeychainItem(service: appName + " Cloud Secrets", account: account)
        @Sendable func archive(_ epoch: Int) -> BackendCloudSecretsKeychainItem {
            .init(service: appName + " Cloud Secrets Archive", account: account + ".epoch-" + String(epoch))
        }
        let seen = BackendCloudSecretsKeychainItem(service: appName + " Cloud Secrets", account: account + ".cloud-epoch")
        // The hand-over book: its own small item beside the slot (never a file a deletion could reset).
        let book = BackendCloudSecretsKeychainItem(service: appName + " Cloud Secrets", account: account + ".hand-over")
        return .init(subject: subject, deviceId: deviceId, read: { try item.read() }, write: { try item.write($0) },
                     archiveWrite: { try archive($0).write($1) }, archiveRead: { try archive($0).read() },
                     seenRead: { try seen.read() }, seenWrite: { try seen.write($0) },
                     bookRead: { try book.read() }, bookWrite: { try book.write($0) },
                     removeKeys: { epochs in
                         for epoch in epochs { try archive(epoch).remove() }
                         try book.remove(); try seen.remove(); try item.remove()
                     })
    }
    /// Design B4: this device id was signed out by ANOTHER device. Its Cloud keys go (the current one, every older
    /// generation up to the highest this Mac knew, the seen mark, the book); never any data of his. An unreadable slot is
    /// removed too (it can never be opened by this device id again: a new sign-in gets a new id and a new slot).
    public func forgetAfterRemoteSignOut() async throws {
        let own = (try? await read())?.epoch ?? 0
        let seen = (try? await seenCloudEpoch()) ?? 0
        let highest = min(max(own, seen), 10_000)
        try await removeKeys(Array(1...max(highest, 1)))
    }
    public func handOverBook() async throws -> CloudSecretsHandOverBook? {
        guard let bytes = try await bookRead() else { return nil }
        return try CloudWire.decode(CloudSecretsHandOverBook.self, from: bytes, maximumBytes: 32_768)
    }
    public func saveHandOverBook(_ book: CloudSecretsHandOverBook) async throws {
        let bytes = try JSONEncoder().encode(book)
        guard bytes.count <= 32_768 else { throw CloudFailure.invalidRequest }
        try await bookWrite(bytes)
        // Read back: a book that did not land is not "written" (condition a).
        guard try await handOverBook() == book else { throw CloudFailure.checksumMismatch }
    }
    public func saveVerified(_ key: CloudSecretsLocalKey) async throws {
        guard key.subject == subject, key.deviceId == deviceId, key.root.count == 32 else { throw CloudFailure.invalidRequest }
        try await writeValue(JSONEncoder().encode(key))
    }
}

/// One generic-password item. No dev-file fallback, no interaction.
struct BackendCloudSecretsKeychainItem: Sendable {
    let service: String
    let account: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data, !data.isEmpty else {
            throw BackendCloudSecretsKeyBlocked(status: status)
        }
        return data
    }
    /// Design B4 only. "Not there" is done; any other answer throws (nothing claimed removed that was not).
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudFailure.unavailable }
    }
    func write(_ data: Data) throws {
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw CloudFailure.unavailable }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw CloudFailure.unavailable }
    }
}

/// This Mac's saved-password key exists but cannot be opened (a locked
/// keychain, or an app whose code signature changed since it saved the key,
/// such as a rebuilt dev copy). Nothing is deleted or replaced. Recovery words
/// or approval cannot write over it in place: the save path must read the
/// current key first (it refuses an older epoch over a newer one), macOS lets
/// a different signature neither read nor delete the item without a dialog,
/// and a second item for the same account and device would leave two copies,
/// one unreadable and possibly newer, with no safe rule for which is current.
/// Signing out of Cloud and in again gives a new device id and an empty slot.
public struct BackendCloudSecretsKeyBlocked: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        "This Mac can't open its saved-password key right now (Keychain status \(status)). Nothing was deleted. "
            + "If your Mac's keychain is locked, unlock it. Otherwise sign out of Cloud on this Mac and sign in again, "
            + "then let another of your devices open them here."
    }
}
