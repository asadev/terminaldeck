import Foundation
import TerminalDeckNativeCore

/// Explicit file selections supplied by the existing SSH resolver. Never a home scan.
public struct BackendCloudSecretsSSHSelection: Sendable {
    public enum Kind: String, Codable, Sendable { case configuration, privateKey, publicKey, hostTrust }
    public let id: String
    public let file: URL
    public let kind: Kind
    public init(id: String, file: URL, kind: Kind) { self.id = id; self.file = file; self.kind = kind }
}
public struct BackendCloudSecretsSSHValue: Codable, Equatable, Sendable {
    public let kind: BackendCloudSecretsSSHSelection.Kind
    public let bytes: Data
    public init(kind: BackendCloudSecretsSSHSelection.Kind, bytes: Data) { self.kind = kind; self.bytes = bytes }
}
/// The server owner receives records into its encrypted managed import area.
/// Only explicit local selections can receive absent files; existing files stay.
public actor BackendCloudSecretsSSHStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I14"
    public nonisolated let domain = CloudSecretsDomain.ssh
    private let selections: @Sendable () async throws -> [BackendCloudSecretsSSHSelection]
    private let read: @Sendable (BackendCloudSecretsSSHSelection) async throws -> Data
    private let importRecord: @Sendable (String, BackendCloudSecretsSSHValue) async throws -> CloudApplyStatus
    private let additionalRecords: @Sendable () async throws -> [String: BackendCloudSecretsSSHValue]
    private let readImported: @Sendable (String) async throws -> BackendCloudSecretsSSHValue?
    public init(sourceId: String, selections: @escaping @Sendable () async throws -> [BackendCloudSecretsSSHSelection],
                read: @escaping @Sendable (BackendCloudSecretsSSHSelection) async throws -> Data,
                importRecord: @escaping @Sendable (String, BackendCloudSecretsSSHValue) async throws -> CloudApplyStatus,
                readImported: @escaping @Sendable (String) async throws -> BackendCloudSecretsSSHValue?,
                additionalRecords: @escaping @Sendable () async throws -> [String: BackendCloudSecretsSSHValue] = { [:] }) {
        self.sourceId = sourceId; self.selections = selections; self.read = read
        self.importRecord = importRecord; self.readImported = readImported; self.additionalRecords = additionalRecords
    }
    /// Physical callbacks use the server credential owner and its current local
    /// protected key. Unmapped records remain inert and encrypted.
    public static func bound(sourceId: String, owner: BackendServersCredentials,
                             selections: @escaping @Sendable () async throws -> [BackendCloudSecretsSSHSelection]) -> BackendCloudSecretsSSHStore {
        @Sendable func local(_ id: String) async throws -> BackendCloudSecretsSSHValue? {
            let chosen = try await selections().filter { $0.id == id }
            guard chosen.count <= 1 else { throw CloudFailure.idReused }
            guard let selection = chosen.first,
                  let bytes = try BackendAccountFiles.boundedRead(selection.file, maximum: CloudWire.maximumPlainChunkBytes) else { return nil }
            return .init(kind: selection.kind, bytes: bytes)
        }
        return .init(sourceId: sourceId, selections: {
            try await selections().filter { FileManager.default.fileExists(atPath: $0.file.path) }
        }, read: { selection in
            guard let bytes = try BackendAccountFiles.boundedRead(selection.file, maximum: CloudWire.maximumPlainChunkBytes) else { throw CloudFailure.unavailable }
            return bytes
        }, importRecord: { id, incoming in
            if let current = try await local(id) { return current == incoming ? .alreadyPresent : .keptBoth }
            let held = try owner.cloudSSHMerge(id, value: incoming)
            guard held != .keptBoth else { return held }
            let destinations = try await selections().filter { $0.id == id }
            guard destinations.count <= 1 else { throw CloudFailure.idReused }
            if let destination = destinations.first {
                // A referenced file can itself be passphrase-encrypted. Restoring
                // its authenticated bytes must not try to unlock or connect it.
                // The existing connection owner validates a key when it is used.
                return try owner.cloudSSHMaterialize(destination, value: incoming)
            }
            // No cloud-controlled path: unmapped records stay encrypted in the
            // owner's managed area until the person chooses a destination.
            return held
        }, readImported: { id in
            if let current = try await local(id) { return current }
            return try owner.cloudSSHRead(id)
        }, additionalRecords: { try owner.cloudSSHRecords() })
    }
    public func capture() async throws -> [CloudSecretRecord] {
        var output: [CloudSecretRecord] = []
        for file in try await selections() {
            let bytes = try await read(file)
            guard bytes.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.invalidRequest }
            output.append(try BackendCloudSecretsRecords.record(sourceId, file.id, domain, BackendCloudSecretsSSHValue(kind: file.kind, bytes: bytes)))
        }
        let localIds = Set(output.map(\.recordId))
        for (id, value) in try await additionalRecords() where !localIds.contains(id) {
            output.append(try BackendCloudSecretsRecords.record(sourceId, id, domain, value))
        }
        guard Set(output.map(\.recordId)).count == output.count else { throw CloudFailure.idReused }
        return output
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsSSHValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsSSHValue.self, record, source: sourceId, domain: domain)
        guard (value.kind == .configuration || value.kind == .hostTrust || !value.bytes.isEmpty), value.bytes.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { try await importRecord(record.recordId, value(record)) }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let local = try await readImported(record.recordId)
        return outcome == .keptBoth ? local != nil : local == (try value(record))
    }
}
