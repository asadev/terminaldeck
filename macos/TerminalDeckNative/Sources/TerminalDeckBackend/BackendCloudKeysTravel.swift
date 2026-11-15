import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Keys travel (owner, 15 Nov 2026: "I need every single thing in cloud ... every small thing to be synced and in
/// everywhere"). API keys of the coding AIs' API accounts, connected-task tokens, Receiver secrets and MCP servers ride
/// the saved-passwords engine that already exists: each is one more `CloudSecretsLogicalStore` (its own source and
/// domain on the lean list), sealed with the saved-passwords key, wrapped by the saved passwords' delete-rule owner
/// (`BackendProjectSecretFilesSavedDeleteOwner`: the Bin for 30 days, "Put back", an AI's removal = everywhere), and put
/// on the sealed shelf like every other saved password. No second engine, no click and no question on the other Mac.
///
/// The same rules for all four:
/// - New on another Mac: made here, and used by the feature itself (the account works, the task system is connected,
///   the Receiver accepts, the MCP server is listed).
/// - The same item on both Macs (same name, or the same value under another name here): ONE item, nothing added.
/// - A different value under the same name: never overwritten. His stays as it is; the other Mac's value is added
///   beside it, named apart by that Mac's name where the feature can hold two (API accounts, MCP servers), and kept
///   sealed in the kept-conflicts store where it cannot (one token per task connection, one secret per Receiver source).
/// - Names are shown, values never: nothing here logs, throws or returns a value; errors are fixed words.
public enum BackendCloudKeysTravel {
    /// "Name (Mac)": the other Mac's value beside his own.
    public static func apart(_ name: String, mac: String?) -> String {
        let device = (mac?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "another Mac"
        let base = String(name.prefix(max(1, BackendAccountProfile.maximumNameLength - device.count - 3)))
        return base + " (" + device + ")"
    }
    /// The Mac's name as an MCP-name suffix: letters, digits and "-" only (the MCP name rule), at most 20 characters.
    public static func slug(_ mac: String?) -> String {
        let lowered = (mac ?? "").lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" }
        let joined = String(lowered).split(separator: "-").joined(separator: "-")
        let short = String(joined.prefix(20)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return short.isEmpty ? "other-mac" : short
    }
    /// A keyed-free stable id for a copy made from one arriving record (the same arrival always names the same copy,
    /// so a retried arrival never makes a second one). Built from the record id and the sending Mac's name only.
    static func copyID(_ recordId: String, from: String?) -> String {
        let digest = SHA256.hash(data: Data(("TD-KEYS-COPY-1\n" + recordId + "\n" + (from ?? "")).utf8))
        return "api-key-" + String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

// MARK: - API accounts (source "api", domain apiKey)

/// One API account of this copy of the app, as the travelling store sees it. Never holds the key.
public struct BackendCloudKeysAPIAccount: Sendable, Equatable {
    public let record: BackendAPIAccountRecord
    public let name: String
    public init(record: BackendAPIAccountRecord, name: String) { self.record = record; self.name = name }
}

/// The API accounts' own owner (the app's `BackendAPIAccountService`; tests a memory owner).
public protocol BackendCloudKeysAPIOwner: Sendable {
    func cloudAccounts() async throws -> [BackendCloudKeysAPIAccount]
    func cloudKey(_ record: BackendAPIAccountRecord) async throws -> String?
    /// Make an API account with exactly this id (absent here), these settings and this key. Throws on any refusal.
    func cloudCreate(accountID: String, name: String, value: BackendCloudKeysAPIValue) async throws
    /// Compare-and-remove: removes the account only while its key still equals `expectingKey` and nothing runs as it.
    func cloudRemove(accountID: String, expectingKey: String) async throws -> Bool
    /// Review fix 3: compare-and-swap of the key in place (the account, its settings and name stay). false = changed here.
    func cloudReplaceKey(accountID: String, key: String, expectingKey: String) async throws -> Bool
    /// Whether the owner can answer right now (the app's service may come later than saved passwords).
    func cloudReady() async -> Bool
}

public extension BackendCloudKeysAPIOwner {
    func cloudReady() async -> Bool { true }
}

/// What travels for one API account: what a person types when adding it, and its key. Sealed; never shown whole.
public struct BackendCloudKeysAPIValue: Codable, Equatable, Sendable {
    public let name: String
    public let provider: String
    public let kind: String
    public let baseURL: String
    public let model: String?
    public let workspaceID: String?
    public let key: String
    /// The Mac that sent it (its name), for a copy named apart. Never part of "the same item".
    public let from: String?
    public init(name: String, record: BackendAPIAccountRecord, key: String, from: String?) {
        self.name = name; provider = record.provider; kind = record.kind.rawValue; baseURL = record.baseURL
        model = record.model; workspaceID = record.workspaceID; self.key = key; self.from = from
    }
    /// The same API connection with the same key (name, model and sender aside).
    func same(_ record: BackendAPIAccountRecord, key other: String?) -> Bool {
        provider == record.provider && kind == record.kind.rawValue && baseURL == record.baseURL && workspaceID == record.workspaceID && key == other
    }
    /// The same connection settings, whatever the key.
    func sameConnection(_ record: BackendAPIAccountRecord) -> Bool {
        provider == record.provider && kind == record.kind.rawValue && baseURL == record.baseURL && workspaceID == record.workspaceID
    }
    func sameValue(_ other: BackendCloudKeysAPIValue) -> Bool {
        provider == other.provider && kind == other.kind && baseURL == other.baseURL && workspaceID == other.workspaceID && key == other.key
    }
}

/// Small plain file of ids only (no name, no value): which local account is the one item another Mac names otherwise.
/// Two Macs that made the same key into two accounts agree on ONE id (the smaller), so the item is one in Cloud too.
final class BackendCloudKeysAliases: @unchecked Sendable {
    private let file: URL?
    private var map: [String: String]
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([String: String].self, from: data) { map = read } else { map = [:] }
    }
    /// Cloud id -> this Mac's account id.
    func local(_ cloudId: String) -> String { map[cloudId] ?? cloudId }
    /// The id this Mac uses in Cloud for its account `localId`: the smallest id that names it.
    func cloud(_ localId: String) -> String { ([localId] + map.filter { $0.value == localId }.map(\.key)).min() ?? localId }
    func alias(_ cloudId: String, to localId: String) {
        guard cloudId != localId, map[cloudId] != localId else { return }
        map[cloudId] = localId; save()
    }
    func forget(localId: String) {
        let before = map.count
        map = map.filter { $0.value != localId && $0.key != localId }
        if map.count != before { save() }
    }
    private func save() {
        guard let file, let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: [.atomic])
    }
}

/// The app's API-account owner, read when asked (it is made with the session host's connection, which can come later
/// than saved passwords and is made again after a reconnect). Not ready: nothing captured, arrivals wait ("locked").
public struct BackendCloudKeysLateAPIOwner: BackendCloudKeysAPIOwner {
    private let owner: @Sendable () async -> (any BackendCloudKeysAPIOwner)?
    public init(_ owner: @escaping @Sendable () async -> (any BackendCloudKeysAPIOwner)?) { self.owner = owner }
    public func cloudReady() async -> Bool { await owner() != nil }
    private func ready() async throws -> any BackendCloudKeysAPIOwner {
        guard let made = await owner() else { throw CloudFailure.secretsLocked }
        return made
    }
    public func cloudAccounts() async throws -> [BackendCloudKeysAPIAccount] {
        guard let made = await owner() else { return [] }
        return try await made.cloudAccounts()
    }
    public func cloudKey(_ record: BackendAPIAccountRecord) async throws -> String? { try await ready().cloudKey(record) }
    public func cloudCreate(accountID: String, name: String, value: BackendCloudKeysAPIValue) async throws {
        try await ready().cloudCreate(accountID: accountID, name: name, value: value)
    }
    public func cloudRemove(accountID: String, expectingKey: String) async throws -> Bool {
        try await ready().cloudRemove(accountID: accountID, expectingKey: expectingKey)
    }
    public func cloudReplaceKey(accountID: String, key: String, expectingKey: String) async throws -> Bool {
        try await ready().cloudReplaceKey(accountID: accountID, key: key, expectingKey: expectingKey)
    }
}

public actor BackendCloudKeysAPIStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I13"
    public nonisolated let domain = CloudSecretsDomain.apiKey
    private let owner: any BackendCloudKeysAPIOwner
    private let thisMac: @Sendable () async -> String?
    private let aliases: BackendCloudKeysAliases
    private let exchanged = BackendCloudKeysExchanged()
    /// `stateRoot`: where the id-only alias file lives (the saved passwords' own state folder); nil keeps it in memory.
    /// `removals`: where an app Remove finds this kind's Cloud id (the app's one box; tests their own).
    public init(sourceId: String = "api", owner: any BackendCloudKeysAPIOwner, stateRoot: URL?, thisMac: @escaping @Sendable () async -> String?,
                removals: BackendCloudKeysRemovals = .shared) {
        self.sourceId = sourceId; self.owner = owner; self.thisMac = thisMac
        let made = BackendCloudKeysAliases(file: stateRoot?.appendingPathComponent("keys-travel-api-aliases.json"))
        aliases = made
        removals.setMapper(sourceId) { made.cloud($0) }
    }
    private func keyed() async throws -> [(account: BackendCloudKeysAPIAccount, key: String)] {
        var output: [(account: BackendCloudKeysAPIAccount, key: String)] = []
        for account in try await owner.cloudAccounts() where account.record.requiresKey {
            guard BackendAPIAccountRecord.isAPIAccountID(account.record.accountID) else { continue }
            guard let key = try await owner.cloudKey(account.record) else { continue }
            output.append((account: account, key: key))
        }
        return output
    }
    public func capture() async throws -> [CloudSecretRecord] {
        // Not ready yet: "locked", never an empty list (an empty list would read as every account gone).
        guard await owner.cloudReady() else { throw CloudFailure.secretsLocked }
        let mac = await thisMac()
        var output: [CloudSecretRecord] = []
        for (account, key) in try await keyed() {
            let id = aliases.cloud(account.record.accountID)
            let fresh = BackendCloudKeysAPIValue(name: account.name, record: account.record, key: key, from: mac)
            // Review fix 3: the value is still the one last exchanged for this id: send that very record again, so
            // nothing comes back as an echo with another Mac's name inside it.
            if let last = await exchanged.last(id), let before = try? value(last), before.sameValue(fresh) { output.append(last); continue }
            output.append(try BackendCloudSecretsRecords.record(sourceId, id, domain, fresh))
        }
        return output
    }
    func value(_ record: CloudSecretRecord) throws -> BackendCloudKeysAPIValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudKeysAPIValue.self, record, source: sourceId, domain: domain)
        guard BackendAPIAccountRecord.isAPIAccountID(record.recordId), let kind = BackendAPIAccountRecord.Kind(rawValue: value.kind), kind.provider == value.provider,
              kind != .compatibleLocal, !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.name.count <= BackendAccountProfile.maximumNameLength, !value.name.contains(where: \.isNewline),
              (value.from?.count ?? 0) <= 128,
              let parts = URLComponents(string: value.baseURL), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.host != nil,
              parts.scheme == "https" || parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(parts.host ?? "") else { throw CloudFailure.invalidRequest }
        do { try BackendAPIAccountKeychain.validate(value.key) } catch { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let incoming = try value(record)
        let here = try await keyed()
        let localId = aliases.local(record.recordId)
        if let mine = here.first(where: { $0.account.record.accountID == localId }), incoming.same(mine.account.record, key: mine.key) { return .alreadyPresent }
        var mineExists = here.contains(where: { $0.account.record.accountID == localId })
        if !mineExists { mineExists = try await owner.cloudAccounts().contains(where: { $0.record.accountID == localId }) }
        // The same key under another account here: one item. Only when this id names nothing else here, the alias keeps
        // the two Macs on one id (a copy named apart never takes over the id of his own account).
        if let twin = here.first(where: { incoming.same($0.account.record, key: $0.key) }) {
            if !mineExists {
                let own = twin.account.record.accountID, before = aliases.cloud(own)
                aliases.alias(record.recordId, to: own)
                // Review fix 3: the id this Mac used in Cloud before the two Macs agreed leaves Cloud (only Cloud).
                if before != aliases.cloud(own) { await exchanged.owner?.retireFromCloud(before) }
            }
            return .alreadyPresent
        }
        if mineExists {
            // Review fix 3: unchanged here since the last value exchanged for this id: the other Mac's newer key
            // replaces it in place (one account). Both changed: his stays and the other one is added beside it.
            if let mine = here.first(where: { $0.account.record.accountID == localId }), incoming.sameConnection(mine.account.record),
               let last = await exchanged.last(record.recordId), let before = try? value(last), before.same(mine.account.record, key: mine.key) {
                let replaced: Bool
                do { replaced = try await owner.cloudReplaceKey(accountID: localId, key: incoming.key, expectingKey: mine.key) }
                catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
                catch { throw CloudFailure.unavailable }
                if replaced { return .applied }
            }
            let copy = BackendCloudKeysTravel.copyID(record.recordId, from: incoming.from)
            // A copy made earlier: the same key = one item; another = kept both (never a failure on every sync).
            if let made = here.first(where: { $0.account.record.accountID == copy }) {
                return incoming.same(made.account.record, key: made.key) ? .alreadyPresent : .keptBoth
            }
            if try await owner.cloudAccounts().contains(where: { $0.record.accountID == copy }) { return .keptBoth }
            do { try await owner.cloudCreate(accountID: copy, name: BackendCloudKeysTravel.apart(incoming.name, mac: incoming.from), value: incoming) }
            catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
            catch { throw CloudFailure.unavailable }
            return .keptBoth
        }
        do { try await owner.cloudCreate(accountID: record.recordId, name: incoming.name, value: incoming) }
        catch CloudFailure.secretsLocked { throw CloudFailure.secretsLocked }
        catch { throw CloudFailure.unavailable }
        return .applied
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let incoming = try value(record)
        let here = try await keyed()
        switch outcome {
        case .keptBoth: return try await owner.cloudAccounts().contains { $0.record.accountID == aliases.local(record.recordId) }
        default: return here.contains { incoming.same($0.account.record, key: $0.key) }
        }
    }
    /// The delete rule's compare-and-remove (through the alias: Cloud's one id may name another account here).
    func removeCompared(_ record: CloudSecretRecord) async throws -> Bool {
        let incoming = try value(record)
        let localId = aliases.local(record.recordId)
        let removed = try await owner.cloudRemove(accountID: localId, expectingKey: incoming.key)
        if removed { aliases.forget(localId: localId) }
        return removed
    }
    public nonisolated func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                           macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                           serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                           vanished: BackendCloudKeysVanished? = nil,
                                           now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        let owner = BackendProjectSecretFilesSavedDeleteOwner(store: self, stateRoot: stateRoot, gate: gate, name: { record in
            (try? BackendCloudSecretsRecords.decode(BackendCloudKeysAPIValue.self, record, source: record.sourceId, domain: .apiKey))?.name ?? "API key"
        }, remove: { record in try await self.removeCompared(record) }, macName: macName, serviceClock: serviceClock, now: now,
        sameValue: { one, other in
            guard one.recordId == other.recordId,
                  let a = try? BackendCloudSecretsRecords.decode(BackendCloudKeysAPIValue.self, one, source: one.sourceId, domain: .apiKey),
                  let b = try? BackendCloudSecretsRecords.decode(BackendCloudKeysAPIValue.self, other, source: other.sourceId, domain: .apiKey) else { return false }
            return a.provider == b.provider && a.kind == b.kind && a.baseURL == b.baseURL && a.workspaceID == b.workspaceID && a.key == b.key
        }, vanished: vanished)
        exchanged.set(owner)
        return owner
    }
}

// MARK: - Connected-task tokens (source "tasks", domain taskConnection): delete rule

public enum BackendCloudKeysTasks {
    /// The existing task-token store (tasks everywhere), under the saved passwords' delete rule. The connection itself
    /// travels with the tasks; its token travels here. Removing the token removes it only while it is still the same.
    public static func deleteRuleStore(_ store: BackendCloudSecretsTaskStore, stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                       remove: @escaping @Sendable (_ connectionId: String, _ token: String) async throws -> Bool,
                                       macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                       serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                       now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        .init(store: store, stateRoot: stateRoot, gate: gate, name: { record in
            (try? BackendCloudSecretsRecords.decode(BackendCloudSecretsTaskStore.Value.self, record, source: record.sourceId, domain: .taskConnection))?.name ?? "Task connection"
        }, remove: { record in
            let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsTaskStore.Value.self, record, source: record.sourceId, domain: .taskConnection)
            return try await remove(record.recordId, value.token)
        }, macName: macName, serviceClock: serviceClock, now: now)
    }
}

// MARK: - Receiver secrets (source "receiver", domain receiver)

/// One Receiver source with its secrets, or the Receiver's own key ("key").
public struct BackendCloudKeysReceiverValue: Codable, Equatable, Sendable {
    public let receiverKey: Data?
    public let source: RCVSource?
    public let secrets: BackendRCVSecrets?
    public init(receiverKey: Data? = nil, source: RCVSource? = nil, secrets: BackendRCVSecrets? = nil) {
        self.receiverKey = receiverKey; self.source = source; self.secrets = secrets
    }
}

/// Per source, so one source is one item (the same source on two Macs is one; removing one source is that source only).
/// The Receiver's key: taken from another Mac only while this Mac never received anything with its own (no event, no
/// delivery), so nothing here ever depends on the key it replaces; otherwise his stays (kept both).
public actor BackendCloudKeysReceiverStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I15"
    public nonisolated let domain = CloudSecretsDomain.receiver
    private let store: @Sendable () async -> BackendRCVStore?
    static let keyId = "key"
    static let prefix = "source/"
    public init(sourceId: String = "receiver", store: @escaping @Sendable () async -> BackendRCVStore?) {
        self.sourceId = sourceId; self.store = store
    }
    private func live() async throws -> BackendRCVStore {
        // Not started yet on this Mac: "locked right now", so the arrival waits and is taken when it is ready.
        guard let made = await store() else { throw CloudFailure.secretsLocked }
        return made
    }
    public func capture() async throws -> [CloudSecretRecord] {
        guard let made = await store() else { return [] }
        guard !(await made.cloudIsAwaitingRestore()) else { return [] }
        let state: BackendRCVState
        do { state = try await made.read() } catch { throw CloudFailure.unavailable }
        var output = [try BackendCloudSecretsRecords.record(sourceId, Self.keyId, domain, BackendCloudKeysReceiverValue(receiverKey: state.receiverKey))]
        for source in state.sources {
            output.append(try BackendCloudSecretsRecords.record(sourceId, Self.prefix + source.id, domain,
                BackendCloudKeysReceiverValue(source: source, secrets: state.secrets[source.id])))
        }
        return output
    }
    func value(_ record: CloudSecretRecord) throws -> BackendCloudKeysReceiverValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudKeysReceiverValue.self, record, source: sourceId, domain: domain)
        if record.recordId == Self.keyId {
            guard let key = value.receiverKey, key.count == 32, value.source == nil, value.secrets == nil else { throw CloudFailure.invalidRequest }
            return value
        }
        guard record.recordId.hasPrefix(Self.prefix), let source = value.source, value.receiverKey == nil,
              Self.prefix + source.id == record.recordId, !source.id.isEmpty, source.id.count <= 128,
              !source.id.contains(where: { $0.isNewline || $0 == "/" }) else { throw CloudFailure.invalidRequest }
        if let secrets = value.secrets, secrets.secret.isEmpty { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let incoming = try value(record)
        let made = try await live()
        let outcome: CloudApplyStatus
        do {
            outcome = try await made.update { state -> CloudApplyStatus in
                if let key = incoming.receiverKey {
                    if state.receiverKey == key { return .alreadyPresent }
                    guard state.events.isEmpty, state.deliveries.isEmpty else { return .keptBoth }
                    state.receiverKey = key
                    return .applied
                }
                guard let source = incoming.source else { return .keptBoth }
                if let index = state.sources.firstIndex(where: { $0.id == source.id }) {
                    return state.sources[index] == source && state.secrets[source.id] == incoming.secrets ? .alreadyPresent : .keptBoth
                }
                state.sources.append(source)
                if let secrets = incoming.secrets { state.secrets[source.id] = secrets }
                return .applied
            }
        } catch { throw CloudFailure.unavailable }
        if outcome != .keptBoth { await made.cloudDidRestore() }
        return outcome
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let incoming = try value(record)
        let state: BackendRCVState
        do { state = try await live().read() } catch { throw CloudFailure.unavailable }
        if let key = incoming.receiverKey { return outcome == .keptBoth || state.receiverKey == key }
        guard let source = incoming.source else { return false }
        if outcome == .keptBoth { return state.sources.contains { $0.id == source.id } }
        return state.sources.contains(source) && state.secrets[source.id] == incoming.secrets
    }
    /// The delete rule's compare-and-remove: the source and its secrets go only while they are still exactly these.
    /// The Receiver's own key is never removed (a Receiver always has one).
    func removeCompared(_ record: CloudSecretRecord) async throws -> Bool {
        let incoming = try value(record)
        guard let source = incoming.source else { return false }
        let made = try await live()
        do {
            return try await made.update { state -> Bool in
                guard let index = state.sources.firstIndex(where: { $0.id == source.id }) else { return true }
                guard state.sources[index] == source, state.secrets[source.id] == incoming.secrets else { return false }
                state.sources.remove(at: index); state.secrets[source.id] = nil
                return true
            }
        } catch { throw CloudFailure.unavailable }
    }
    public nonisolated func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                           macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                           serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                           now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        .init(store: self, stateRoot: stateRoot, gate: gate, name: { record in
            if record.recordId == Self.keyId { return "Receiver key" }
            return (try? BackendCloudSecretsRecords.decode(BackendCloudKeysReceiverValue.self, record, source: record.sourceId, domain: .receiver))?.source?.name ?? "Receiver source"
        }, remove: { record in try await self.removeCompared(record) }, macName: macName, serviceClock: serviceClock, now: now)
    }
}

// MARK: - Review fixes (15 Nov): removals pressed in the app, and the last exchanged value

/// Review fix 1 (Decker's decision): a Remove pressed IN THE APP for an API account, an MCP server, a task token or a
/// Receiver source is a removal EVERYWHERE through that kind's delete owner (Bin 30 days, no question). The app sets
/// the handler when saved passwords run; without one (saved passwords off or locked) the feature removes as before.
public final class BackendCloudKeysRemovals: @unchecked Sendable {
    public static let shared = BackendCloudKeysRemovals()
    /// (source id, Cloud id) -> true when it was removed everywhere through the delete rule.
    public typealias Handler = @Sendable (_ sourceId: String, _ cloudId: String) async throws -> Bool
    private let lock = NSLock()
    private var handler: Handler?
    private var mappers: [String: @Sendable (String) -> String] = [:]
    public init() {}
    public func set(_ handler: Handler?) { lock.withLock { self.handler = handler } }
    /// A kind whose Cloud id can differ from its own id here (API accounts' agreed id).
    public func setMapper(_ sourceId: String, _ mapper: (@Sendable (String) -> String)?) { lock.withLock { mappers[sourceId] = mapper } }
    /// false: not handled here (the caller removes the old way). Throws the delete owner's refusal.
    public func removeEverywhere(sourceId: String, id: String) async throws -> Bool {
        let (handler, mapper) = lock.withLock { (self.handler, mappers[sourceId]) }
        guard let handler else { return false }
        return try await handler(sourceId, mapper?(id) ?? id)
    }
}

/// Review fix 3: a store reaches its own delete owner's memory of the last value exchanged with Cloud.
final class BackendCloudKeysExchanged: @unchecked Sendable {
    private let lock = NSLock()
    private weak var held: BackendProjectSecretFilesSavedDeleteOwner?
    func set(_ owner: BackendProjectSecretFilesSavedDeleteOwner) { lock.withLock { held = owner } }
    var owner: BackendProjectSecretFilesSavedDeleteOwner? { lock.withLock { held } }
    func last(_ id: String) async -> CloudSecretRecord? { await owner?.lastExchanged(id) }
}
