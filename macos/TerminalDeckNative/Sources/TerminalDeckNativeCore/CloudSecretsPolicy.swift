import Foundation
import CryptoKit

public enum CloudSecretsStage: String, CaseIterable, Sendable { case capture, export, upload, download, importRecords, launch }
public enum CloudSecretsDomain: String, Codable, CaseIterable, Sendable {
    case apiKey = "api-key", server, ssh, mcp, taskConnection = "task-connection", receiver, browserCookies = "browser-cookies"
    case browserPassword = "browser-password", project, app, aiSubscription = "ai-subscription"
    public var purpose: CloudPurpose {
        switch self { case .aiSubscription: .aiSubscription; case .browserCookies, .browserPassword: .browser; default: .secret }
    }
}
/// Gates are read at every boundary, including before asking an adapter for bytes.
public struct CloudSecretsPolicy: Sendable {
    public let capabilities: @Sendable () async throws -> CloudGate
    public let now: @Sendable () -> Int64
    public init(capabilities: @escaping @Sendable () async throws -> CloudGate,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.capabilities = capabilities; self.now = now
    }
    public func require(_ purpose: CloudPurpose, stage: CloudSecretsStage) async throws {
        let gate = try await capabilities()
        guard gate.permitsCloud(at: now()) else { throw CloudFailure.gateClosed }
        guard purpose != .aiSubscription || gate.aiSubscriptionsEnabled == true else { throw CloudFailure.gateClosed }
    }
    public static func classify(relativePath: String, sourceId: String) -> CloudSecretClassification {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/").lowercased()
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let source = sourceId.lowercased()
        if source.contains("subscription") || source.contains("account-vault") || name == "auth.json" || name == ".credentials.json"
            || name == "oauth_creds.json" || name == "credentials.json" || path.contains("keychain:claude")
            || path.contains("gemini") && (name.contains("oauth") || name.contains("token")) {
            return .init(storageClass: .secrets, purpose: .aiSubscription, rule: "provider-auth")
        }
        if name == ".env" || name.hasPrefix(".env.") || ["pem", "key", "p12", "pfx", "crt", "cer"].contains((name as NSString).pathExtension)
            || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa")
            || name.contains("credential") || name.contains("secret") || name.contains("token") || name == ".npmrc" || name == ".netrc" {
            return .init(storageClass: .secrets, purpose: .secret, rule: "secret-file")
        }
        return .init(storageClass: .brain, purpose: .brain, rule: "ordinary-work")
    }
}

public actor CloudSecretsContent: CloudContentPort {
    private let subject: CloudSubject
    private let deviceId: String
    private let local: any CloudSecretsLocalKeyPort
    private let policy: CloudSecretsPolicy
    /// Retry sends the already sealed outbox bytes. Re-encryption always uses a new id.
    private var sealedIds: Set<String> = []
    /// The newest epoch the cloud has reported. While it is newer than this
    /// Mac's key (saved passwords were started anew on another device), this Mac
    /// seals and opens nothing: anything it queued under the old key could not
    /// be opened in the new epoch (round-6 review R6-2). `state(.secrets)`
    /// reports unavailable with that reason; that is the signal the sync core
    /// uses to retire older-epoch items.
    private var cloudEpoch = 0
    private var cloudEpochKnown = false
    /// From status calls and A's vault notice. The latest report wins, so a
    /// single false "newer" report clears as soon as the cloud again reports
    /// this key's own epoch (round-8 S-2). Remembered across restarts in its own
    /// small protected item, never by rewriting the key item (R8-2).
    public func noteCloudEpoch(_ epoch: Int) async {
        guard epoch > 0 else { return }
        cloudEpoch = epoch; cloudEpochKnown = true
        try? await local.saveSeenCloudEpoch(epoch)
    }
    private func cloudAhead(of key: CloudSecretsLocalKey) async -> Int {
        if !cloudEpochKnown {
            cloudEpoch = (try? await local.seenCloudEpoch()).flatMap { $0 } ?? 0
            cloudEpochKnown = true
        }
        return cloudEpoch
    }
    public init(subject: CloudSubject, deviceId: String, local: any CloudSecretsLocalKeyPort, policy: CloudSecretsPolicy) {
        self.subject = subject; self.deviceId = deviceId; self.local = local; self.policy = policy
    }
    private func key(_ purpose: CloudPurpose, stage: CloudSecretsStage, epoch: Int? = nil) async throws -> CloudSecretsLocalKey {
        try await policy.require(purpose, stage: stage)
        // A key still waiting for the cloud's confirmation seals nothing: the
        // service would refuse those uploads and they would pile up queued.
        guard let key = try await local.read(), key.subject == subject, key.deviceId == deviceId,
              key.root.count == 32, key.epoch > 0, key.version > .zero, key.acknowledged != false,
              epoch == nil || key.epoch == epoch else { throw CloudFailure.secretsLocked }
        guard key.epoch >= (await cloudAhead(of: key)) else { throw CloudFailure.secretsLocked }
        return key
    }
    public func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) async throws -> CloudContentEnvelope {
        guard storageClass == .secrets, purpose.permits(.secrets) else { throw CloudFailure.unsupportedFormat }
        let key = try await key(purpose, stage: .upload, epoch: epoch)
        let canonicalId = try CloudSecretsCrypto.uuidBytes(blobId)
        let identity = CloudSecretsCrypto.encode(canonicalId)
        guard sealedIds.insert(identity).inserted else { throw CloudFailure.idReused }
        return try CloudSecretsCrypto.sealContent(bytes, root: key.root, sub: subject.sub, blobId: blobId, purpose: purpose, epoch: epoch, codec: codec)
    }
    public func open(_ envelope: CloudContentEnvelope) async throws -> Data {
        let key = try await key(envelope.purpose, stage: .download, epoch: envelope.epoch)
        return try CloudSecretsCrypto.openContent(envelope, root: key.root, sub: subject.sub, epoch: key.epoch)
    }
    /// Keyed fingerprints for "already uploaded" checks (L7). Derived from the
    /// root per device id, source and epoch, so a fingerprint kept on disk is
    /// no oracle for guessing a short password, and marks written under an
    /// earlier device id (sign out and in again) never match: items that device
    /// queued but could not send upload again (round-4 review N2).
    public func fingerprinter(label: String, epoch: Int) async throws -> CloudSecretsFingerprinter {
        let key = try await key(.secret, stage: .capture, epoch: epoch)
        return .init(key: SymmetricKey(data: CloudSecretsCrypto.derive(key.root, salt: Data(),
            info: "TD-CLOUD-FINGERPRINT-2\n\(deviceId)\n\(label)\n\(epoch)")))
    }
    public func state(storageClass: CloudStorageClass) async -> CloudContentState {
        guard storageClass == .secrets, let key = try? await key(.secret, stage: .download) else {
            let held = try? await local.read()
            var ahead = cloudEpoch
            if let held { ahead = await cloudAhead(of: held) }
            let newer = held.map { $0.epoch < ahead } ?? false
            // The sync core reads the cloud's current epoch here to retire
            // queued items of an older key (SYNC -> V, signal 4).
            return .init(available: false, epoch: newer ? ahead : 0, reason: newer
                ? "Saved passwords were started anew on another device. Allow this Mac again or use the new recovery words."
                : "Unlock saved passwords")
        }
        return .init(available: true, epoch: key.epoch)
    }
    /// Project secret files (14 Nov): keys a store needs beyond sealing. `shared` is the SAME on every device holding
    /// this generation's key (no device id in it), so two Macs name one file with one opaque record id and compare
    /// versions without either side showing the service a path or a fingerprint it could guess from. `local` is this
    /// device's own key for what it keeps waiting on its disk (never sent).
    /// The sealed shelf (15 Nov): the confirmed key of `epoch`, under the same checks as every seal (policy, confirmed,
    /// not behind the Cloud). Only `shelfSealer(epoch:)` uses it, and derives the shelf root from it at once.
    func shelfKey(epoch: Int) async throws -> CloudSecretsLocalKey { try await key(.secret, stage: .upload, epoch: epoch) }
    public func storeKeys(label: String, epoch: Int) async throws -> CloudSecretsStoreKeys {
        let key = try await key(.secret, stage: .capture, epoch: epoch)
        let shared = SymmetricKey(data: CloudSecretsCrypto.derive(key.root, salt: Data(), info: "TD-CLOUD-SHARED-ID-1\n\(label)\n\(epoch)"))
        let local = SymmetricKey(data: CloudSecretsCrypto.derive(key.root, salt: Data(), info: "TD-CLOUD-DEVICE-HOLD-1\n\(deviceId)\n\(label)\n\(epoch)"))
        return .init(epoch: epoch, shared: .init(key: shared), local: local)
    }
}

/// See `CloudSecretsContent.storeKeys`. Handed to a `CloudSecretsKeyedStore` by its adapter before every capture and
/// every look at arriving records; never written anywhere.
public struct CloudSecretsStoreKeys: Sendable {
    public let epoch: Int
    public let shared: CloudSecretsFingerprinter
    public let local: SymmetricKey
    init(epoch: Int, shared: CloudSecretsFingerprinter, local: SymmetricKey) { self.epoch = epoch; self.shared = shared; self.local = local }
    /// Fixtures: two "Macs" of one account pass the same `sharedKey` and their own `local`.
    public init(epoch: Int, sharedKey: SymmetricKey, local: SymmetricKey) { self.init(epoch: epoch, shared: .init(key: sharedKey), local: local) }
}
/// A store whose record ids or local holdings need the account's keys (project secret files).
public protocol CloudSecretsKeyedStore: Sendable {
    func use(keys: CloudSecretsStoreKeys?) async
}

/// HMAC-SHA256 under a root-derived key; hex. Holds no plaintext.
public struct CloudSecretsFingerprinter: Sendable {
    let key: SymmetricKey
    public func callAsFunction(_ bytes: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: bytes, using: key).map { String(format: "%02x", $0) }.joined()
    }
}
/// Durable "already uploaded" fingerprints per keyed slot (device, source) and
/// epoch: keyed record ids to keyed record fingerprints only. Neither a record,
/// its id nor the source name is stored in clear (the slot is keyed too).
/// `pending`: items queued but not yet confirmed by the cloud, as operation id
/// to "keyed id\nkeyed record" (round-7 S-2), so an app start does not queue
/// them again; they are confirmed by receipt or dropped with the epoch/queue.
public protocol CloudSecretsKnownStore: Sendable {
    func load(slot: String, epoch: Int) async throws -> (entries: [String: String], pending: [String: String])
    func save(slot: String, epoch: Int, entries: [String: String], pending: [String: String]) async throws
}
