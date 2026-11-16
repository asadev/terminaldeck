import Foundation
import CryptoKit
import Security
import TerminalDeckNativeCore

/// WhatsApp agents' keys (DESIGN-WHATSAPP.md section 5): each key is one of the keys that travel with saved passwords,
/// store "whatsapp" (domain `whatsapp`), one record per WhatsApp agent. On this computer a key lives only in its own
/// Keychain item; it is never written to a plain file, a log line, an error, a test output or a picture.

/// Where this computer keeps the keys. `ready` false = not open yet (the store then says "locked", never "none").
public protocol WhatsAppKeyKeeping: Sendable {
    func ready() async -> Bool
    func ids() async throws -> [String]
    func key(_ id: String) async throws -> String?
    func setKey(_ key: String, for id: String) async throws
    /// Sets only when the item is absent (an arrival never overwrites his own).
    func insertIfAbsent(_ key: String, for id: String) async throws -> Bool
    /// Removes only while the key is still `expecting` (the delete rule's compare-and-remove); true when gone.
    func remove(_ id: String, expecting: String?) async throws -> Bool
}

/// The Keychain keeper: one generic-password item per WhatsApp agent, service "<app> WhatsApp", account = the agent's id.
/// Never asks the person (no Keychain prompt); readable after the first unlock, this device only (Cloud carries it on).
public actor BackendWhatsAppKeychain: WhatsAppKeyKeeping {
    public let service: String
    public init(appName: String) { service = appName + " WhatsApp" }
    public func ready() -> Bool { true }
    private func base(_ id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }
    public func ids() throws -> [String] {
        var query = base()
        query[kSecReturnAttributes as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = found as? [[String: Any]] else { throw CloudFailure.secretsLocked }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.filter(WhatsAppAgentIDs.valid).sorted()
    }
    public func key(_ id: String) throws -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = found as? Data else { throw CloudFailure.secretsLocked }
        return String(decoding: bytes, as: UTF8.self)
    }
    public func setKey(_ key: String, for id: String) throws {
        guard WhatsAppAgentIDs.valid(id), WhatsAppAgentIDs.plausibleKey(key) else { throw WhatsAppProblem.keyRefused }
        let update = SecItemUpdate(base(id) as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw WhatsAppProblem("macOS did not let Terminal Deck keep this key in the Keychain.") }
        var add = base(id)
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw WhatsAppProblem("macOS did not let Terminal Deck keep this key in the Keychain.") }
    }
    public func insertIfAbsent(_ key: String, for id: String) throws -> Bool {
        if try self.key(id) != nil { return false }
        try setKey(key, for: id); return true
    }
    public func remove(_ id: String, expecting: String?) throws -> Bool {
        guard let current = try key(id) else { return true }
        if let expecting, current != expecting { return false }
        let status = SecItemDelete(base(id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// A keeper in memory: tests and fixtures only.
public actor WhatsAppKeysInMemory: WhatsAppKeyKeeping {
    private var keys: [String: String]
    private var isReady: Bool
    public init(_ keys: [String: String] = [:], ready: Bool = true) { self.keys = keys; isReady = ready }
    public func setReady(_ value: Bool) { isReady = value }
    public func ready() -> Bool { isReady }
    public func ids() throws -> [String] { guard isReady else { throw CloudFailure.secretsLocked }; return keys.keys.sorted() }
    public func key(_ id: String) throws -> String? { guard isReady else { throw CloudFailure.secretsLocked }; return keys[id] }
    public func setKey(_ key: String, for id: String) throws { guard isReady else { throw CloudFailure.secretsLocked }; keys[id] = key }
    public func insertIfAbsent(_ key: String, for id: String) throws -> Bool {
        guard isReady else { throw CloudFailure.secretsLocked }
        guard keys[id] == nil else { return false }
        keys[id] = key; return true
    }
    public func remove(_ id: String, expecting: String?) throws -> Bool {
        guard let current = keys[id] else { return true }
        if let expecting, current != expecting { return false }
        keys[id] = nil; return true
    }
}

public enum WhatsAppAgentIDs {
    /// The key's fingerprint in the synced record: the first 16 hex characters of its SHA-256. Not the key.
    public static func fingerprint(_ key: String) -> String {
        String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    /// "wa-" and 32 lowercase hex characters: made by the app, never from the key.
    public static func make() -> String { "wa-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    public static func valid(_ id: String) -> Bool {
        id.hasPrefix("wa-") && id.count <= 64 && id.count > 3 && id.dropFirst(3).allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" }
    }
    /// One line of printable characters, at most 4096: anything else is not a key WhatsApp gave.
    public static func plausibleKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 4096 && key.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }
}

/// What travels for one WhatsApp agent: its key and his name for it (so the arriving row is named before the synced
/// settings arrive). Never the creator, the offset or a message.
public struct WhatsAppKeyValue: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
}

/// The saved-passwords store "whatsapp", in the keys-travel stores' style with the 15 Nov fixes from the start:
/// - not ready = "locked" (an empty list would read as every key gone);
/// - capture resends the last exchanged record while the value is unchanged (no echo brings an old key back);
/// - an arrival is taken when absent; the same key is one item; a different key replaces his only while his is
///   unchanged since the last exchange (he pressed Replace key on another computer), else his stays (kept both);
/// - a removal (Remove in the app, an AI's removal) goes through the delete owner: Bin 30 days, Put back, everywhere;
///   compare-and-remove, so a key replaced meanwhile is never removed by an old removal;
/// - the record holds no computer's name, so "removed everywhere" matches exactly (keys-travel lesson);
/// - no value ever appears in a name, an error or the shelf list (the shelf shows it as a secret field).
public actor BackendWhatsAppKeysStore: CloudSecretsLogicalStore {
    public static let source = "whatsapp"
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I15"
    public nonisolated let domain = CloudSecretsDomain.whatsapp
    private let keeper: any WhatsAppKeyKeeping
    private let names: @Sendable (String) async -> String?
    private let exchanged = BackendCloudKeysExchanged()
    /// `names`: his name for an agent id (from the synced settings), nil = the default name.
    public init(sourceId: String = BackendWhatsAppKeysStore.source, keeper: any WhatsAppKeyKeeping,
                names: @escaping @Sendable (String) async -> String? = { _ in nil }) {
        self.sourceId = sourceId; self.keeper = keeper; self.names = names
    }
    public func capture() async throws -> [CloudSecretRecord] {
        guard await keeper.ready() else { throw CloudFailure.secretsLocked }
        var output: [CloudSecretRecord] = []
        for id in try await keeper.ids() where WhatsAppAgentIDs.valid(id) {
            guard let key = try await keeper.key(id) else { continue }
            if let last = await exchanged.last(id), let before = try? value(last), before.key == key { output.append(last); continue }
            let name = await names(id) ?? WhatsAppAgentsLimits.defaultName(taken: [])
            output.append(try BackendCloudSecretsRecords.record(sourceId, id, domain, WhatsAppKeyValue(key: key, name: name)))
        }
        return output
    }
    func value(_ record: CloudSecretRecord) throws -> WhatsAppKeyValue {
        let value = try BackendCloudSecretsRecords.decode(WhatsAppKeyValue.self, record, source: sourceId, domain: domain)
        guard WhatsAppAgentIDs.valid(record.recordId), WhatsAppAgentIDs.plausibleKey(value.key),
              !value.name.isEmpty, value.name.count <= WhatsAppAgentsLimits.maximumNameLength, !value.name.contains(where: \.isNewline) else {
            throw CloudFailure.invalidRequest
        }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let incoming = try value(record)
        guard await keeper.ready() else { throw CloudFailure.secretsLocked }
        do {
            guard let mine = try await keeper.key(record.recordId) else {
                return try await keeper.insertIfAbsent(incoming.key, for: record.recordId) ? .applied : .keptBoth
            }
            if mine == incoming.key { return .alreadyPresent }
            // Replace key pressed on another computer: his is still the value last exchanged here, so the newer one
            // replaces it in place. Both changed: his stays.
            if let last = await exchanged.last(record.recordId), let before = try? value(last), before.key == mine {
                try await keeper.setKey(incoming.key, for: record.recordId)
                return .applied
            }
            return .keptBoth
        } catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
        catch { throw CloudFailure.unavailable }
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let incoming = try value(record)
        let mine: String?
        do { mine = try await keeper.key(record.recordId) } catch { throw CloudFailure.unavailable }
        return outcome == .keptBoth ? mine != nil : mine == incoming.key
    }
    func removeCompared(_ record: CloudSecretRecord) async throws -> Bool {
        let incoming = try value(record)
        do { return try await keeper.remove(record.recordId, expecting: incoming.key) }
        catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
        catch { throw CloudFailure.unavailable }
    }
    public nonisolated func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                           macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                           serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                           now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        let owner = BackendProjectSecretFilesSavedDeleteOwner(store: self, stateRoot: stateRoot, gate: gate, name: { record in
            "WhatsApp · " + ((try? BackendCloudSecretsRecords.decode(WhatsAppKeyValue.self, record, source: record.sourceId, domain: .whatsapp))?.name ?? "WhatsApp agent")
        }, remove: { record in try await self.removeCompared(record) }, macName: macName, serviceClock: serviceClock, now: now,
        sameValue: { one, other in
            guard one.recordId == other.recordId,
                  let a = try? BackendCloudSecretsRecords.decode(WhatsAppKeyValue.self, one, source: one.sourceId, domain: .whatsapp),
                  let b = try? BackendCloudSecretsRecords.decode(WhatsAppKeyValue.self, other, source: other.sourceId, domain: .whatsapp) else { return false }
            return a.key == b.key
        })
        exchanged.set(owner)
        return owner
    }
}
