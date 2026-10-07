import Foundation
import Security
import TerminalDeckNativeCore

/// Direct Security access to the original Electron item. A read never creates
/// or replaces a key, and denied access never opens a plaintext fallback.
public struct BackendAccountKeychainCipher: Sendable {
    public let appName: String
    public let allowInteraction: Bool
    public let mayCreateForNewVault: Bool
    public init(appName: String, allowInteraction: Bool = false, mayCreateForNewVault: Bool = false) {
        self.appName = appName; self.allowInteraction = allowInteraction; self.mayCreateForNewVault = mayCreateForNewVault
    }
    private func password(create: Bool) throws -> Data {
        SecKeychainSetUserInteractionAllowed(allowInteraction)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appName + " Safe Storage", kSecAttrAccount as String: appName,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecSuccess {
            guard let bytes = found as? Data, !bytes.isEmpty else { throw BackendAccountFailure("The original safe-storage Keychain item is empty. Restore its original key.") }
            return bytes
        }
        if status == errSecItemNotFound, create, mayCreateForNewVault {
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw BackendAccountFailure("macOS could not create a secure account-vault key.") }
            let bytes = Data(Data(random).base64EncodedString().utf8)
            let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: appName + " Safe Storage", kSecAttrAccount as String: appName, kSecValueData as String: bytes]
            let created = SecItemAdd(attributes as CFDictionary, nil)
            if created == errSecDuplicateItem { return try password(create: false) }
            guard created == errSecSuccess else { throw BackendAccountFailure("macOS refused creation of the account-vault key (Keychain status \(created)).") }
            return bytes
        }
        throw BackendAccountFailure("The original account-vault encryption key is missing, locked, or denied to this signed native app (Keychain status \(status)). Existing encrypted logins were kept unchanged.")
    }
    public func prepareForWrites(existingVault: Bool) throws { _ = try password(create: !existingVault) }
    public func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password(create: false)) }
    public func encrypt(_ text: String, existingVault: Bool) throws -> Data { try ChromiumSafeStorageCipher.encrypt(text, password: password(create: !existingVault)) }
}


/// TS `VaultCipher` (src/main/account-vault/store.ts). The production cipher is
/// `BackendAccountKeychainCipher`; tests inject a fake one and never touch a Keychain.
/// `existingVault` lets the Keychain cipher create its key only for a brand-new vault.
public protocol BackendAccountVaultCipher: Sendable {
    func available() -> Bool
    func prepareForWrites(existingVault: Bool) throws
    func decrypt(_ blob: Data) throws -> String
    func encrypt(_ text: String, existingVault: Bool) throws -> Data
}

/// macOS always has a Keychain (TS electron-cipher: `safeStorage.isEncryptionAvailable()` is true on the Mac).
extension BackendAccountKeychainCipher: BackendAccountVaultCipher {
    public func available() -> Bool { true }
}

public struct BackendAccountVaultSummary: Codable, Sendable, Equatable {
    public let accountId: String
    public let provider: String
    public let held: Bool
    public let slots: [String]
    public let capturedAt: Double
    public let updatedAt: Double
    public let lastSource: String
    public let plan: String?
}

/// TS `VaultWrite`: every save outcome, never thrown. `message` never carries a value.
public struct BackendAccountVaultWrite: Sendable, Equatable {
    public let ok: Bool
    public let changed: Bool
    public let message: String
    public init(ok: Bool, changed: Bool, message: String) { self.ok = ok; self.changed = changed; self.message = message }
    static let unchanged = BackendAccountVaultWrite(ok: true, changed: false, message: "")
    static func refused(_ message: String) -> BackendAccountVaultWrite { .init(ok: false, changed: false, message: message) }
}

public enum BackendAccountVaultState: String, Sendable, Equatable { case ready, locked }

/// Port of TS `AccountVault` (src/main/account-vault/store.ts) plus the native
/// single-writer rules: writes need the exclusive state store and the writer lease.
public actor BackendAccountVault {
    /// TS VAULT_FILE / VAULT_VERSION / NO_SECURE_STORE / VAULT_LOCKED (store.ts).
    public static let fileName = "account-vault.bin"
    /// TS wire.ts VAULT_DIR.
    public static let directoryName = "account-vault"
    public static let version = 1
    public static let noSecureStore = "This computer has no secure store available, so this app cannot keep logins itself. Each agent keeps its own login instead, as it always has."
    public static let locked = "The logins this app keeps could not be unlocked just now, so nothing was changed. They are safe; quit and reopen the app to try again."
    static let providers: Set<String> = ["claude", "codex", "gemini", "shell"]
    static let sources: Set<String> = ["sign-in", "refresh", "adopted", "typed"]
    static let maximumSecret = 256 * 1024
    static let maximumFile = 8 * 1024 * 1024

    private struct Slot: Codable, Sendable { let value: String; let source: String; let updatedAt: Double }
    private struct Entry: Codable, Sendable { let accountId: String; let provider: String; let capturedAt: Double; var slots: [String: Slot] }
    private struct Disk: Codable, Sendable { let version: Int; let entries: [Entry] }
    public nonisolated let readiness: BackendLaunchReadiness
    public nonisolated let file: URL
    public nonisolated let directory: URL
    private let cipher: any BackendAccountVaultCipher
    private let now: @Sendable () -> Double
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private var lease: BackendAccountWriterLease?
    private var loaded: [String: Entry]?
    private var lockedReason: String?
    private var setAsideBeforeWrite = false
    private var listeners: [UUID: @Sendable (String) -> Void] = [:]

    /// Production assembly (unchanged signature): the original Electron safe-storage key.
    public init(configuration: BackendAccountConfiguration, stateStore: NativeStateStore,
                cipher: BackendAccountKeychainCipher) throws {
        try self.init(configuration: configuration, stateStore: stateStore, vaultCipher: cipher)
    }

    /// TS `AccountVaultOptions`: cipher, clock (ms) and writer are injectable with the real defaults.
    public init(configuration: BackendAccountConfiguration, stateStore: NativeStateStore,
                vaultCipher: any BackendAccountVaultCipher,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                writeFile: (@Sendable (Data, URL) throws -> Void)? = nil) throws {
        // TS wire.ts:148 `join(userDataDir, VAULT_DIR)` + store.ts VAULT_FILE: the vault the Node engine
        // wrote lives at <data>/account-vault/account-vault.bin, and native must open that same file.
        directory = configuration.dataDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        file = directory.appendingPathComponent(Self.fileName)
        self.cipher = vaultCipher; self.now = now
        self.writeFile = writeFile ?? { data, file in try BackendAccountFiles.writeAtomic(data, to: file) }
        let exclusive = stateStore.ownership == .exclusive && stateStore.file?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == configuration.dataDirectory.resolvingSymlinksInPath().path
        readiness = exclusive ? .ready : .unavailable("The full native facade has not taken account-vault ownership from Node.")
        if exclusive { lease = try BackendAccountWriterLease(file: file) }
    }

    // MARK: - TS AccountVault surface

    /// TS `available()`: a cipher that throws is "not available".
    public func available() -> Bool { cipher.available() }
    /// TS `state()`.
    public func state() -> BackendAccountVaultState { lockedReason == nil ? .ready : .locked }
    /// TS `open()`: load, then report. A vault that will not decrypt is never cached, so the next call tries again.
    @discardableResult
    public func openState() -> BackendAccountVaultState { _ = load(); return state() }

    /// TS store.ts `load()`.
    private func load() -> [String: Entry] {
        if let loaded { return loaded }
        var info = stat()
        if lstat(file.path, &info) != 0, errno == ENOENT || errno == ENOTDIR {
            lockedReason = nil; loaded = [:]; return [:]
        }
        let plain: String
        do {
            if (info.st_mode & S_IFMT) == S_IFREG, info.st_size > Self.maximumFile {
                setAsideBeforeWrite = true; lockedReason = nil; loaded = [:]; return [:]
            }
            guard let encoded = try BackendAccountFiles.boundedRead(file, maximum: Self.maximumFile) else { lockedReason = nil; loaded = [:]; return [:] }
            let text = String(decoding: encoded, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let blob = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw BackendAccountFailure("The existing account-vault blob is not valid base64.") }
            plain = try cipher.decrypt(blob)
        } catch {
            // Somebody's logins behind a key that is not here right now: never cached, never set aside.
            lockedReason = error.localizedDescription
            return [:]
        }
        lockedReason = nil
        guard let raw = try? NativeRPCValue.parseJSON(Data(plain.utf8), maximumBytes: Self.maximumFile) else {
            setAsideBeforeWrite = true; loaded = [:]; return [:]
        }
        // Native addition: a newer format is read as TS reads it, but kept aside before the first rewrite.
        if let version = raw["version"].number, version > Double(Self.version) { setAsideBeforeWrite = true }
        let entries = Self.readEntries(raw)
        loaded = entries
        return entries
    }

    /// TS store.ts `readEntries()`.
    private static func readEntries(_ raw: NativeRPCValue) -> [String: Entry] {
        var out: [String: Entry] = [:]
        guard raw.fields != nil else { return out }
        for row in raw["entries"].elements ?? [] {
            guard row.fields != nil, let id = row["accountId"].string, !id.isEmpty,
                  let provider = row["provider"].string, providers.contains(provider) else { continue }
            var slots: [String: Slot] = [:]
            for field in row["slots"].fields ?? [] {
                guard BackendAccountProfile.validSlot(field.key), field.value.fields != nil,
                      let value = field.value["value"].string, !value.isEmpty, value.utf16.count <= maximumSecret else { continue }
                let source = field.value["source"].string ?? "sign-in"
                slots[field.key] = Slot(value: value, source: sources.contains(source) ? source : "sign-in", updatedAt: field.value["updatedAt"].number ?? 0)
            }
            if slots.isEmpty { continue }
            out[id] = Entry(accountId: id, provider: provider, capturedAt: row["capturedAt"].number ?? 0, slots: slots)
        }
        return out
    }

    private static func planOf(_ slots: [String: Slot]) -> String? {
        for slot in slots.values {
            if let value = try? NativeRPCValue.parseJSON(Data(slot.value.utf8)), let candidate = value["claudeAiOauth"]["subscriptionType"].string,
               candidate.range(of: "^[a-z0-9_-]{1,32}$", options: [.regularExpression, .caseInsensitive]) != nil { return candidate }
        }
        return nil
    }

    private func stamp() -> String {
        let value = now()
        return value == value.rounded() && abs(value) < 9e15 ? String(Int64(value)) : String(value)
    }

    /// TS store.ts `persist()`, behind the native exclusive-writer gate.
    private func persist(_ next: [String: Entry]) -> BackendAccountVaultWrite {
        guard readiness == .ready, lease != nil else { return .refused("The native account vault is not an unlocked exclusive writer.") }
        guard available() else { return .refused(Self.noSecureStore) }
        guard lockedReason == nil else { return .refused(Self.locked) }
        let blob: Data
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let plain = try encoder.encode(Disk(version: Self.version, entries: next.values.sorted { $0.accountId < $1.accountId }))
            blob = try cipher.encrypt(String(decoding: plain, as: UTF8.self), existingVault: FileManager.default.fileExists(atPath: file.path))
        } catch {
            return .refused("The login could not be encrypted: \(error.localizedDescription)")
        }
        let encoded = Data(blob.base64EncodedString().utf8)
        guard encoded.count <= Self.maximumFile else { return .refused("The login could not be saved: the encrypted account vault exceeds its file size limit.") }
        if setAsideBeforeWrite {
            _ = Darwin.rename(file.path, file.path + ".unreadable-" + stamp())
            setAsideBeforeWrite = false
        }
        do { try writeFile(encoded, file) }
        catch { return .refused("The login could not be saved: \(error.localizedDescription)") }
        loaded = next
        return .init(ok: true, changed: true, message: "")
    }

    private func announce(_ accountID: String) { for listener in listeners.values { listener(accountID) } }
    /// TS `onChange()`: listeners hear only which account changed.
    @discardableResult
    public func onChange(_ listener: @escaping @Sendable (String) -> Void) -> UUID { let id = UUID(); listeners[id] = listener; return id }
    public func removeChangeListener(_ id: UUID) { listeners[id] = nil }

    /// TS `has()`.
    public func has(_ accountID: String) -> Bool { !(load()[accountID]?.slots.isEmpty ?? true) }
    /// TS `read()`. Internal agent handoff only. Never register this as a page/MCP RPC.
    func readSlot(_ accountID: String, slot: String) -> String? {
        guard BackendAccountProfile.validSlot(slot) else { return nil }
        return load()[accountID]?.slots[slot]?.value
    }

    /// TS `put()`.
    func write(accountID: String, provider: String, slot: String, value: String, source: String) -> BackendAccountVaultWrite {
        guard !accountID.isEmpty else { return .refused("An account id is required.") }
        guard BackendAccountProfile.validSlot(slot) else { return .refused("That is not a slot this app keeps.") }
        guard !value.isEmpty else { return .refused("There was nothing to keep.") }
        guard value.utf16.count <= Self.maximumSecret else { return .refused("That is much too long to be a login.") }
        guard Self.providers.contains(provider) else { return .refused("That is not an agent this app keeps logins for.") }
        let current = load()
        let held = current[accountID]
        if let held, held.provider == provider, held.slots[slot]?.value == value { return .unchanged }
        let at = now()
        let same = held?.provider == provider
        var entry = Entry(accountId: accountID, provider: provider, capturedAt: same ? held!.capturedAt : at, slots: same ? held!.slots : [:])
        entry.slots[slot] = Slot(value: value, source: source, updatedAt: at)
        var next = current; next[accountID] = entry
        let result = persist(next)
        if result.ok { announce(accountID) }
        return result
    }

    /// TS `drop()`.
    func dropSlot(_ accountID: String, slot: String) -> BackendAccountVaultWrite {
        let current = load()
        guard var entry = current[accountID], entry.slots[slot] != nil else { return .unchanged }
        entry.slots[slot] = nil
        var next = current; next[accountID] = entry.slots.isEmpty ? nil : entry
        let result = persist(next)
        if result.ok { announce(accountID) }
        return result
    }

    /// TS `forget()`: forgotten in memory even when the disk refuses; the result says the save failed.
    public func forgetAccount(_ accountID: String) -> BackendAccountVaultWrite {
        let current = load()
        guard current[accountID] != nil else { return .unchanged }
        var next = current; next[accountID] = nil
        let result = persist(next)
        if loaded != nil { loaded = next }
        announce(accountID)
        return result
    }

    /// TS `summary()`: slots, times and the plan, never a value.
    public func summary(_ accountID: String) -> BackendAccountVaultSummary? {
        guard let entry = load()[accountID] else { return nil }
        let newest = entry.slots.values.reduce(nil as Slot?) { best, slot in best == nil || slot.updatedAt > best!.updatedAt ? slot : best }
        return BackendAccountVaultSummary(accountId: entry.accountId, provider: entry.provider, held: !entry.slots.isEmpty,
            slots: entry.slots.keys.sorted(), capturedAt: entry.capturedAt, updatedAt: newest?.updatedAt ?? entry.capturedAt,
            lastSource: newest?.source ?? "sign-in", plan: Self.planOf(entry.slots))
    }
    /// TS `summaries()`: an empty list while locked.
    public func allSummaries() -> [BackendAccountVaultSummary] { load().keys.sorted().compactMap { summary($0) } }
    /// TS `reload()`.
    public func reload() { loaded = nil; setAsideBeforeWrite = false; lockedReason = nil }

    // MARK: - Native throwing surface (existing callers)

    public func open() throws {
        _ = load()
        if let lockedReason { throw BackendAccountFailure("The kept logins could not be unlocked: \(lockedReason) No vault data was changed.") }
    }
    public func prepareForWrites() throws {
        guard readiness == .ready, lease != nil else { throw BackendAccountFailure("Node still owns the account vault; native writes are disabled.") }
        try open()
        try cipher.prepareForWrites(existingVault: FileManager.default.fileExists(atPath: file.path))
    }
    public func isOpen() -> Bool { loaded != nil && lockedReason == nil }
    /// Internal agent handoff only. Never register this method as a page/MCP RPC.
    func read(accountID: String, slot: String) throws -> String? {
        guard BackendAccountProfile.validSlot(slot) else { return nil }
        try open(); return readSlot(accountID, slot: slot)
    }
    @discardableResult
    func put(accountID: String, provider: String, slot: String, value: String, source: String) throws -> Bool {
        guard !accountID.isEmpty, BackendAccountProfile.validSlot(slot), !value.isEmpty,
              value.utf16.count <= Self.maximumSecret, Self.providers.contains(provider) else { throw BackendAccountFailure("The account-vault write contains invalid attributes or exceeds the credential size limit.") }
        let result = write(accountID: accountID, provider: provider, slot: slot, value: value, source: source)
        guard result.ok else { throw BackendAccountFailure(result.message) }
        return result.changed
    }
    @discardableResult
    func drop(accountID: String, slot: String) throws -> Bool {
        let result = dropSlot(accountID, slot: slot)
        guard result.ok else { throw BackendAccountFailure(result.message) }
        return result.changed
    }
    public func forget(accountID: String) throws {
        let result = forgetAccount(accountID)
        guard result.ok else { throw BackendAccountFailure(result.message) }
    }
    public func summaries() throws -> [BackendAccountVaultSummary] { try open(); return allSummaries() }
    public func close() { loaded = nil; lockedReason = nil; setAsideBeforeWrite = false; lease = nil }
}
