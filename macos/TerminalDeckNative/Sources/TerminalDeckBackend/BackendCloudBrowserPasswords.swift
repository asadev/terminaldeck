import Foundation
import TerminalDeckNativeCore

public struct BackendCloudBrowserPassword: Codable, Equatable, Sendable {
    public let profileId: String
    public let origin: String
    public let username: String
    public let password: String
    public let updatedAt: Double
    public init(profileId: String, origin: String, username: String, password: String, updatedAt: Double) {
        self.profileId = profileId; self.origin = origin; self.username = username; self.password = password; self.updatedAt = updatedAt
    }
    public var identity: String {
        CloudSecretsCrypto.hash(Data([profileId, origin, username].map { "\($0.utf8.count):\($0)" }.joined().utf8))
    }
    public func validate() throws {
        guard BackendBrowserProfiles.validID(profileId), BackendBrowserPasswords.origin(origin) == origin,
              !password.isEmpty, updatedAt.isFinite, password.utf8.count <= 1_048_576,
              username.utf8.count <= 65_536, !password.contains("\0"), !username.contains("\0") else { throw CloudFailure.invalidRequest }
    }
}
public actor BackendCloudBrowserPasswordStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I22"
    public nonisolated let domain = CloudSecretsDomain.browserPassword
    private let profileId: String
    private let store: BackendBrowserPasswords
    public init(sourceId: String, profileId: String, store: BackendBrowserPasswords) {
        self.sourceId = sourceId; self.profileId = profileId; self.store = store
    }
    public func capture() async throws -> [CloudSecretRecord] {
        try await store.cloudExport(profileID: profileId).map {
            try BackendCloudSecretsRecords.record(sourceId, $0.identity, domain, $0)
        }
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudBrowserPassword {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudBrowserPassword.self, record, source: sourceId, domain: domain)
        try value.validate()
        guard value.profileId == profileId, value.identity == record.recordId else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { try await store.cloudMerge(value(record)) }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let incoming = try value(record)
        let existing = try await store.cloudExport(profileID: profileId).first { $0.identity == record.recordId }
        return outcome == .keptBoth ? existing != nil : existing?.password == incoming.password
    }
}
