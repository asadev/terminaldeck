import Foundation
import TerminalDeckNativeCore

public struct BackendCloudSecretsReceiverValue: Codable, Equatable, Sendable {
    public let receiverKey: Data
    public let secrets: [String: BackendRCVSecrets]
    public init(receiverKey: Data, secrets: [String: BackendRCVSecrets]) { self.receiverKey = receiverKey; self.secrets = secrets }
}
public actor BackendCloudSecretsReceiverStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I15"
    public nonisolated let domain = CloudSecretsDomain.receiver
    private let store: BackendRCVStore
    private let requireInert: @Sendable () async throws -> Void
    public init(sourceId: String, store: BackendRCVStore, requireInert: @escaping @Sendable () async throws -> Void) {
        self.sourceId = sourceId; self.store = store; self.requireInert = requireInert
    }
    public func capture() async throws -> [CloudSecretRecord] {
        guard !(await store.cloudIsAwaitingRestore()) else { return [] }
        let state = try await store.read()
        return [try BackendCloudSecretsRecords.record(sourceId, "receiver", domain,
            BackendCloudSecretsReceiverValue(receiverKey: state.receiverKey, secrets: state.secrets))]
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsReceiverValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsReceiverValue.self, record, source: sourceId, domain: domain)
        guard record.recordId == "receiver", value.receiverKey.count == 32 else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let incoming = try value(record)
        try await requireInert()
        let outcome: CloudApplyStatus = try await store.update { state in
            if state.receiverKey == incoming.receiverKey, state.secrets == incoming.secrets { return .alreadyPresent }
            guard state.sources.isEmpty, state.events.isEmpty, state.secrets.isEmpty else { return .keptBoth }
            state.receiverKey = incoming.receiverKey; state.secrets = incoming.secrets
            return .applied
        }
        if outcome != .keptBoth { await store.cloudDidRestore() }
        return outcome
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let state = try await store.read(), incoming = try value(record)
        return outcome == .keptBoth || state.receiverKey == incoming.receiverKey && state.secrets == incoming.secrets
    }
}
