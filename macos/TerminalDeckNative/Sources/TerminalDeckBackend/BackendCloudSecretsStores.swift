import Foundation
import TerminalDeckNativeCore

/// Bytes supplied only by the existing store owner. Tests inject memory stores.
public protocol BackendCloudSecretsAPICredentials: Sendable {
    func read(_ record: BackendAPIAccountRecord) throws -> String?
    func addAbsent(_ key: String, record: BackendAPIAccountRecord) throws
}
public struct BackendCloudSecretsAPIKeychain: BackendCloudSecretsAPICredentials {
    private let trustedExecutables: [URL]
    public init(trustedExecutables: [URL]) { self.trustedExecutables = trustedExecutables }
    public func read(_ record: BackendAPIAccountRecord) throws -> String? { try BackendAPIAccountKeychain.cloudRead(record) }
    public func addAbsent(_ key: String, record: BackendAPIAccountRecord) throws {
        try BackendAPIAccountKeychain.write(key, record: record, trustedExecutables: trustedExecutables, onlyIfAbsent: true)
    }
}
public struct BackendCloudSecretsAPIValue: Codable, Equatable, Sendable {
    public let provider: String, kind: String, baseURL: String, key: String
    public let model: String?, workspaceID: String?
    public init(record: BackendAPIAccountRecord, key: String) {
        provider = record.provider; kind = record.kind.rawValue; baseURL = record.baseURL
        model = record.model; workspaceID = record.workspaceID; self.key = key
    }
    func matches(_ record: BackendAPIAccountRecord) -> Bool {
        provider == record.provider && kind == record.kind.rawValue && baseURL == record.baseURL && workspaceID == record.workspaceID
    }
}
public actor BackendCloudSecretsAPIStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I13"
    public nonisolated let domain = CloudSecretsDomain.apiKey
    private let records: @Sendable () async throws -> [BackendAPIAccountRecord]
    private let credentials: any BackendCloudSecretsAPICredentials
    public init(sourceId: String, records: @escaping @Sendable () async throws -> [BackendAPIAccountRecord], credentials: any BackendCloudSecretsAPICredentials) {
        self.sourceId = sourceId; self.records = records; self.credentials = credentials
    }
    public func capture() async throws -> [CloudSecretRecord] {
        var output: [CloudSecretRecord] = []
        for record in try await records() where record.requiresKey {
            guard BackendAPIAccountRecord.isAPIAccountID(record.accountID) else { throw CloudFailure.invalidRequest }
            guard let key = try credentials.read(record) else { continue }
            output.append(try BackendCloudSecretsRecords.record(sourceId, record.accountID, domain, BackendCloudSecretsAPIValue(record: record, key: key)))
        }
        return output
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsAPIValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsAPIValue.self, record, source: sourceId, domain: domain)
        guard BackendAPIAccountRecord.isAPIAccountID(record.recordId), let kind = BackendAPIAccountRecord.Kind(rawValue: value.kind), kind.provider == value.provider, kind != .compatibleLocal,
              let parts = URLComponents(string: value.baseURL), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.host != nil,
              parts.scheme == "https" || parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(parts.host ?? "") else { throw CloudFailure.invalidRequest }
        try BackendAPIAccountKeychain.validate(value.key)
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let value = try value(record)
        guard let destination = try await records().first(where: { $0.accountID == record.recordId }) else { throw CloudFailure.unavailable }
        guard value.matches(destination) else { return .keptBoth }
        if let existing = try credentials.read(destination) { return existing == value.key ? .alreadyPresent : .keptBoth }
        do { try credentials.addAbsent(value.key, record: destination) }
        catch {
            // A simultaneous local save wins; access errors still fail closed.
            guard let existing = try credentials.read(destination) else { throw CloudFailure.unavailable }
            return existing == value.key ? .alreadyPresent : .keptBoth
        }
        guard try credentials.read(destination) == value.key else { throw CloudFailure.checksumMismatch }
        return .applied
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let value = try value(record)
        guard let destination = try await records().first(where: { $0.accountID == record.recordId }) else { return false }
        if outcome == .keptBoth, !value.matches(destination) { return true }
        let saved = try credentials.read(destination)
        return outcome == .keptBoth ? saved != nil : value.matches(destination) && saved == value.key
    }
}

public enum BackendCloudSecretsRecords {
    public static func record<T: Encodable>(_ source: String, _ id: String, _ domain: CloudSecretsDomain, _ value: T) throws -> CloudSecretRecord {
        .init(sourceId: source, recordId: id, domain: domain.rawValue, payload: .init(try NativeRPCValue.parseJSON(JSONEncoder().encode(value))))
    }
    public static func decode<T: Codable>(_ type: T.Type, _ record: CloudSecretRecord, source: String, domain: CloudSecretsDomain) throws -> T {
        guard record.sourceId == source, record.domain == domain.rawValue, !record.recordId.isEmpty else { throw CloudFailure.invalidRequest }
        let result = try CloudWire.decode(type, from: CloudSecretsCanonical.encode(record.payload), maximumBytes: CloudWire.maximumPlainChunkBytes)
        guard try CloudSecretsCanonical.encode(result) == CloudSecretsCanonical.encode(record.payload) else { throw CloudFailure.invalidRequest }
        return result
    }
}
/// The server a saved sign-in belongs to, carried INSIDE the sealed record so another Mac can keep the sign-in
/// under the same server. Only what a person types when adding a server, plus the host's pinned key. Never a
/// permission of one Mac: AI app access, window driving and shown apps are decided on each device and never travel.
public struct BackendCloudSecretsServerDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let address: String
    public let port: Int
    public let username: String
    public let projectId: String?
    /// Only ever true or absent: Look only is carried, never lowered.
    public let lookOnly: Bool?
    public let hostKeyAlgorithm: String?
    public let hostKeyFingerprint: String?
    init(_ server: BackendServersStoredServer) {
        name = server.name; address = server.address; port = server.port; username = server.username
        projectId = server.projectIdInferred ? nil : server.projectId
        lookOnly = server.isLookOnly ? true : nil
        hostKeyAlgorithm = server.hostKey?.algorithm; hostKeyFingerprint = server.hostKey?.fingerprint
    }
    /// The same rules the server list applies to what a person types; anything else is refused before any writer.
    var valid: Bool {
        let texts = [name, address, username, projectId ?? "", hostKeyAlgorithm ?? "", hostKeyFingerprint ?? ""]
        guard texts.allSatisfy({ text in !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) else { return false }
        guard BackendServersStore.addressProblem(address) == nil, address == BackendServersStore.normaliseAddress(address),
              !username.isEmpty, username.utf16.count <= 64, !name.isEmpty, name.utf16.count <= 64,
              (1...65535).contains(port), lookOnly != false else { return false }
        guard (hostKeyFingerprint == nil) == (hostKeyAlgorithm == nil) else { return false }
        if let hostKeyFingerprint, !(hostKeyFingerprint.hasPrefix("SHA256:") && hostKeyFingerprint.utf16.count <= 128) { return false }
        if let hostKeyAlgorithm, hostKeyAlgorithm.utf16.count > 64 { return false }
        if let projectId, projectId.isEmpty || projectId.utf16.count > 200 { return false }
        return true
    }
}
public struct BackendCloudSecretsServerValue: Codable, Equatable, Sendable {
    public let kind: String
    public let password: String?
    public let privateKey: String?
    public let passphrase: String?
    /// The server this sign-in belongs to. Absent in records made before this field, and for a sign-in whose
    /// server is not in the list.
    public let server: BackendCloudSecretsServerDefinition?
    public init(credential: BackendServersCredential, server: BackendCloudSecretsServerDefinition? = nil) throws {
        self.server = server
        switch credential {
        case .password(let value): kind = "password"; password = value; privateKey = nil; passphrase = nil
        case .key(let value, let phrase): kind = "key"; password = nil; privateKey = value; passphrase = phrase
        case .sshConfig: throw CloudFailure.unsupportedFormat
        }
    }
    public func credential() throws -> BackendServersCredential {
        if kind == "password", let password, !password.isEmpty, privateKey == nil, passphrase == nil { return .password(password) }
        if kind == "key", let privateKey, !privateKey.isEmpty, password == nil { return .key(privateKey: privateKey, passphrase: passphrase) }
        throw CloudFailure.invalidRequest
    }
}
public actor BackendCloudSecretsServerStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I14"
    public nonisolated let domain = CloudSecretsDomain.server
    private let store: BackendServersCredentials
    private let exists: @Sendable (String) async throws -> Bool
    /// The live server list, when this store was made by the Servers owner's own port. With it a record carries
    /// its server, and a server that is not on this Mac yet is added (add-only) before its sign-in.
    private let servers: BackendServersStore?
    public init(sourceId: String, store: BackendServersCredentials, serverExists: @escaping @Sendable (String) async throws -> Bool) {
        self.sourceId = sourceId; self.store = store; self.exists = serverExists; servers = nil
    }
    init(sourceId: String, store: BackendServersCredentials, servers: BackendServersStore) {
        self.sourceId = sourceId; self.store = store; self.servers = servers
        exists = { id in try servers.get(id) != nil }
    }
    public func capture() async throws -> [CloudSecretRecord] {
        var output: [CloudSecretRecord] = []
        for (id, credential) in try store.cloudRecords().sorted(by: { $0.key < $1.key }) {
            var definition: BackendCloudSecretsServerDefinition?
            if let servers, let server = try servers.get(id) {
                let candidate = BackendCloudSecretsServerDefinition(server)
                if candidate.valid { definition = candidate }
            }
            output.append(try BackendCloudSecretsRecords.record(sourceId, id, domain,
                BackendCloudSecretsServerValue(credential: credential, server: definition)))
        }
        return output
    }
    private func decoded(_ record: CloudSecretRecord) throws -> BackendCloudSecretsServerValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsServerValue.self, record, source: sourceId, domain: domain)
        if let server = value.server, !server.valid { throw CloudFailure.invalidRequest }
        return value
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendServersCredential { try decoded(record).credential() }
    public func validate(_ record: CloudSecretRecord) async throws {
        if case .key(let key, let phrase) = try value(record), try await store.keyProblem(key, passphrase: phrase) != nil { throw CloudFailure.invalidRequest }
    }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        try await validate(record)
        let incoming = try decoded(record), credential = try incoming.credential()
        if !(try await exists(record.recordId)) {
            // The server itself is not on this Mac. With its definition (saved by the other Mac inside this sealed
            // record) it is added first, under the same id, add-only, with this Mac's own permissions closed.
            // Without one the sign-in has nowhere to go and waits.
            guard let servers, let definition = incoming.server else { throw CloudFailure.unavailable }
            try servers.cloudAddIfAbsent(id: record.recordId, name: definition.name, address: definition.address, port: definition.port,
                username: definition.username, projectId: definition.projectId, lookOnly: definition.lookOnly == true,
                hostKey: definition.hostKeyFingerprint.map { (algorithm: definition.hostKeyAlgorithm ?? "", fingerprint: $0) })
        }
        let outcome = try store.cloudMerge(record.recordId, credential: credential)
        // The list's own note of which kind of sign-in is saved, as the app writes it after a save by hand.
        if outcome == .applied, let servers { _ = try? servers.setCredentialKind(record.recordId, credential: credential.kind) }
        return outcome
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let local = try store.read(record.recordId)
        return outcome == .keptBoth ? local != nil : local == (try value(record))
    }
}

/// What the Servers owner hands to Cloud's saved passwords (`BackendServersFeature.cloudSecrets(sourceId:)`): lane
/// V's logical store over its ONE live credentials object and server list. The object itself never leaves this
/// module; the app can only pass this value on.
public struct BackendCloudSecretsServerPort: Sendable {
    public let store: BackendCloudSecretsServerStore
    let credentials: BackendServersCredentials
    init(sourceId: String, credentials: BackendServersCredentials, servers: BackendServersStore) {
        self.credentials = credentials
        store = BackendCloudSecretsServerStore(sourceId: sourceId, store: credentials, servers: servers)
    }
    /// Told after each saved or forgotten sign-in, never under the owner's lock; nil stops it.
    public func observe(_ changed: (@Sendable () -> Void)?) { credentials.cloudObserve(changed) }
}
public extension BackendCloudRecoveryLocalStores {
    /// The hosted app in the lean first version: the Servers owner's own port and the voice service; no account
    /// vault (the session host helper is its one writer), no browser store, no Receiver, and no store switch:
    /// `recoverAfterVerifiedCloudUnlock()` only checks that this Mac's stores open and refuses with the truth
    /// (`BackendCloudRecoveryBlocked`, `BackendCloudRecoveryKeyLost`) when they do not.
    static func lean(configuration: BackendAccountConfiguration, keys: BackendCloudRecoveryLocalKeyOwner, policy: CloudSecretsPolicy,
                     servers: BackendCloudSecretsServerPort?, voice: BackendOSVoiceService?,
                     requireWriter: @escaping @Sendable () throws -> Void) -> BackendCloudRecoveryLocalStores {
        BackendCloudRecoveryLocalStores(configuration: configuration, keys: keys, policy: policy, vault: nil, passwords: nil,
            servers: servers?.credentials, voice: voice, receiver: nil, requireReceiverInert: {}, requireWriter: requireWriter,
            adoptsLostKeyStores: false)
    }
}

/// Existing connected-task token writer, scoped to an explicit connection list.
public actor BackendCloudSecretsTaskStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I16"
    public nonisolated let domain = CloudSecretsDomain.taskConnection
    private let tokens: any BackendConnectedTasksSecrets
    private let connectionIds: @Sendable () async throws -> [String]
    /// Owner holds its write lease across compare+write; no race with settings saves.
    private let insert: @Sendable (String, String) async throws -> CloudApplyStatus
    /// Keys travel (15 Nov): the connection's name rides beside its token, so the Bin and his phones show it by name.
    /// Never part of the comparison (a rename is not a different token).
    private let names: @Sendable () async throws -> [String: String]
    struct Value: Codable { let token: String; let name: String? }
    public init(sourceId: String, tokens: any BackendConnectedTasksSecrets,
                connectionIds: @escaping @Sendable () async throws -> [String],
                insertIfAbsent: @escaping @Sendable (String, String) async throws -> CloudApplyStatus,
                names: @escaping @Sendable () async throws -> [String: String] = { [:] }) {
        self.sourceId = sourceId; self.tokens = tokens; self.connectionIds = connectionIds; insert = insertIfAbsent; self.names = names
    }
    public func capture() async throws -> [CloudSecretRecord] {
        let named = (try? await names()) ?? [:]
        return try await connectionIds().compactMap { id in
            guard let token = try tokens.read(id) else { return nil }
            return try BackendCloudSecretsRecords.record(sourceId, id, domain, Value(token: token, name: named[id]))
        }
    }
    private func value(_ record: CloudSecretRecord) throws -> Value {
        let result = try BackendCloudSecretsRecords.decode(Value.self, record, source: sourceId, domain: domain)
        guard !result.token.isEmpty, (result.name?.count ?? 0) <= 200 else { throw CloudFailure.invalidRequest }
        return result
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let value = try value(record)
        guard try await connectionIds().contains(record.recordId) else { throw CloudFailure.unavailable }
        return try await insert(record.recordId, value.token)
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let local = try tokens.read(record.recordId)
        return outcome == .keptBoth ? local != nil : local == (try value(record).token)
    }
}
