import Foundation
import TerminalDeckNativeCore

public struct BackendCloudSecretsVoiceValue: Codable, Equatable, Sendable {
    public let provider: String
    public let endpoint: String
    public let key: String
    public init(provider: String, endpoint: String, key: String) { self.provider = provider; self.endpoint = endpoint; self.key = key }
}
public actor BackendCloudSecretsVoiceStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I13"
    public nonisolated let domain = CloudSecretsDomain.app
    private let owner: BackendOSVoiceService
    public init(sourceId: String, owner: BackendOSVoiceService) { self.sourceId = sourceId; self.owner = owner }
    public func capture() async throws -> [CloudSecretRecord] {
        guard let value = try await owner.cloudSavedKey() else { return [] }
        return [try BackendCloudSecretsRecords.record(sourceId, "voice", .app, value)]
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsVoiceValue {
        guard record.recordId == "voice" else { throw CloudFailure.invalidRequest }
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsVoiceValue.self, record, source: sourceId, domain: .app)
        guard let provider = BackendOSVoiceRules.provider(value.provider), provider.endpoint == value.endpoint,
              !value.key.isEmpty, value.key.utf8.count <= 16_384, value.key.rangeOfCharacter(from: .controlCharacters) == nil else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { try await owner.cloudMergeKey(value(record)) }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let local = try await owner.cloudSavedKey()
        return outcome == .keptBoth ? local != nil : local == (try value(record))
    }
}
public struct BackendCloudSecretsGitHubValue: Codable, Sendable {
    public let host: String
    public let credential: CloudValue
    public init(host: String, credential: CloudValue) { self.host = host; self.credential = credential }
}
public actor BackendCloudSecretsGitHubStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I13"
    public nonisolated let domain = CloudSecretsDomain.app
    private let owner: BackendGitHubAuthenticator
    private let requireWriter: @Sendable () throws -> Void
    public init(sourceId: String, owner: BackendGitHubAuthenticator, requireWriter: @escaping @Sendable () throws -> Void) {
        self.sourceId = sourceId; self.owner = owner; self.requireWriter = requireWriter
    }
    /// Only a credential that is safe on two Macs at once travels. A GitHub App
    /// sign-in lasts eight hours and its renewal token works once: copied to a
    /// second Mac, the first renewal retires it and the other Mac is signed out
    /// (round-3 review M5). Such a sign-in stays local: "Sign in on each device".
    public static func portable(_ credential: NativeRPCValue) -> Bool {
        func absent(_ field: NativeRPCValue) -> Bool { field == .missing || field == .null || field.string?.isEmpty == true }
        return absent(credential["refreshToken"]) && absent(credential["expiresAt"]) && absent(credential["refreshExpiresAt"])
    }
    /// True when this Mac has a GitHub sign-in that does not travel.
    public func signInOnEachMac() async throws -> Bool {
        guard let value = try await owner.cloudSavedCredential() else { return false }
        return !Self.portable(value)
    }
    public func capture() async throws -> [CloudSecretRecord] {
        guard let value = try await owner.cloudSavedCredential(), Self.portable(value) else { return [] }
        return [try BackendCloudSecretsRecords.record(sourceId, "github:" + owner.host, .app,
            BackendCloudSecretsGitHubValue(host: owner.host, credential: .init(value)))]
    }
    private func value(_ record: CloudSecretRecord) throws -> BackendCloudSecretsGitHubValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsGitHubValue.self, record, source: sourceId, domain: .app)
        guard value.host == owner.host, record.recordId == "github:" + owner.host else { throw CloudFailure.invalidRequest }
        try BackendGitHubAuthenticator.cloudValidate(value.credential.raw, host: owner.host)
        guard Self.portable(value.credential.raw) else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        try await owner.cloudMergeCredential(value(record).credential.raw, requireWriter: requireWriter)
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        if outcome == .keptBoth { return try await owner.cloudHasLocalCredential() }
        guard let local = try await owner.cloudSavedCredential() else { return false }
        return try CloudSecretsCanonical.encode(CloudValue(local)) == CloudSecretsCanonical.encode(value(record).credential)
    }
}
