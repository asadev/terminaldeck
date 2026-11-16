import Foundation

public struct CloudSecretsEnvelopeReceipt: Codable, Sendable {
    public let epoch: Int
    public let version: CloudSequence
    public let deviceEnvelope: CloudDeviceKeyEnvelope
    public let secretsApproved: Bool?
    public init(epoch: Int, version: CloudSequence, deviceEnvelope: CloudDeviceKeyEnvelope, secretsApproved: Bool? = nil) {
        self.epoch = epoch; self.version = version; self.deviceEnvelope = deviceEnvelope; self.secretsApproved = secretsApproved
    }
}
/// §6.5 reset commits a new epoch, but deliberately returns no envelope.
public struct CloudSecretsResetReceipt: Codable, Sendable {
    public let epoch: Int
    public let version: CloudSequence
    public let state: CloudVaultState
    public let preservedArchiveId: String
    public let secretsApproved: Bool
    public init(epoch: Int, version: CloudSequence, state: CloudVaultState, preservedArchiveId: String, secretsApproved: Bool) {
        self.epoch = epoch; self.version = version; self.state = state
        self.preservedArchiveId = preservedArchiveId; self.secretsApproved = secretsApproved
    }
}
public struct CloudSecretsPossessionReceipt: Codable, Sendable {
    public let secretsApproved: Bool
    public let epoch: Int
    public let version: CloudSequence
    public init(secretsApproved: Bool, epoch: Int, version: CloudSequence) {
        self.secretsApproved = secretsApproved; self.epoch = epoch; self.version = version
    }
}
public struct CloudSecretsAnswerReceipt: Codable, Sendable {
    public let approvalId: String
    public let state: String
    public init(approvalId: String, state: String) { self.approvalId = approvalId; self.state = state }
}
/// Control messages use SYNC's authenticated transport and budget. No URLSession in V.
public protocol CloudSecretsControlPort: Sendable {
    func status() async throws -> CloudSecretsStatus
    func initialize(_ request: CloudSecretsInitializeRequest) async throws -> CloudSecretsEnvelopeReceipt
    func requestApproval(_ request: CloudApprovalRequest) async throws -> CloudApproval
    func answerApproval(_ request: CloudApprovalAnswer) async throws -> CloudSecretsAnswerReceipt
    func envelope() async throws -> CloudSecretsEnvelopeReceipt
    func possession(_ request: CloudPossessionRequest) async throws -> CloudSecretsPossessionReceipt
    func recoveryChallenge(_ request: CloudRecoveryChallengeRequest) async throws -> CloudRecoveryChallenge
    func recover(_ request: CloudRecoveryCompleteRequest) async throws -> CloudSecretsEnvelopeReceipt
    func reset(_ request: CloudSecretsResetRequest) async throws -> CloudSecretsResetReceipt
    func registeredDevice(_ deviceId: String) async throws -> CloudDeviceRegistration
}

/// Scoped to subject + freshly registered device by A's protected-store adapter.
/// There is deliberately no remove/replace-old-vault operation in this port.
public struct CloudSecretsLocalKey: Codable, Sendable {
    public let subject: CloudSubject
    public let deviceId: String
    public let epoch: Int
    public let version: CloudSequence
    public let root: Data
    public let recoveryPublicKey: CloudPublicJWK
    /// false: saved after "Codes match" but the cloud has not confirmed this
    /// Mac's acknowledgement yet. nil (older saves) and true: confirmed.
    public let acknowledged: Bool?
    /// false: this account was set up with no recovery words (silent set-up, 14 Nov). nil (older saves) and true:
    /// words exist.
    public let recoveryWords: Bool?
    public init(subject: CloudSubject, deviceId: String, epoch: Int, version: CloudSequence, root: Data, recoveryPublicKey: CloudPublicJWK,
                acknowledged: Bool? = nil, recoveryWords: Bool? = nil) {
        self.subject = subject; self.deviceId = deviceId; self.epoch = epoch; self.version = version
        self.root = root; self.recoveryPublicKey = recoveryPublicKey; self.acknowledged = acknowledged; self.recoveryWords = recoveryWords
    }
}
public protocol CloudSecretsLocalKeyPort: Sendable {
    func read() async throws -> CloudSecretsLocalKey?
    func saveVerified(_ key: CloudSecretsLocalKey) async throws
    /// Keeps an older epoch's key as the archive key for that epoch (Decker's
    /// decision, round 6): never discarded, never used to seal, only to open
    /// that epoch's preserved archive. Must be readable back before the current
    /// key is replaced.
    func archive(_ key: CloudSecretsLocalKey) async throws
    func archived(epoch: Int) async throws -> CloudSecretsLocalKey?
    /// The cloud's latest secrets epoch, in its OWN small item beside the slot
    /// (round-8 R8-2): bookkeeping never rewrites the key item, which only the
    /// person-checked paths (setup, reset, approval, words) write.
    func seenCloudEpoch() async throws -> Int?
    func saveSeenCloudEpoch(_ epoch: Int) async throws
    // Deliberately no remove: sign-out never deletes this Mac's key slot
    // (round-5 review M1). Revisit only when the service can record that a
    // device has left and no longer holds the key.
}
public struct CloudRecoveryConfirmation: Sendable {
    public let keptWords: Bool
    /// Position is zero based internally; the sheet presents positions starting at one.
    public let answers: [Int: String]
    public init(keptWords: Bool, answers: [Int: String]) { self.keptWords = keptWords; self.answers = answers }
}
public struct CloudSecretsApprovalDisplay: Sendable {
    public let deviceName: String
    public let platform: CloudPlatform
    public let matchingCode: String
    public init(deviceName: String, platform: CloudPlatform, matchingCode: String) {
        self.deviceName = String(deviceName.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(80))
        self.platform = platform; self.matchingCode = matchingCode
    }
    /// 15 Nov small fixes item 4: the asking device is a Mac another device signed out and that signed in again (the
    /// account marks it `signedOutBefore`). The sheet then asks "Is this your <name>?" with "Yes, it's mine". `signedOutBy`
    /// / `signedOutAt` (ms): who and when, when the account says it. Display only; set by the coordinator.
    public var signedOutBefore = false
    public var signedOutBy: String? = nil
    public var signedOutAt: Int64? = nil
}
/// Native person-only boundary: tools can open these flows, never fill their answers.
public protocol CloudSecretsInteractionPort: Sendable {
    func confirmWords(_ words: [String], positions: [Int]) async throws -> CloudRecoveryConfirmation
    func finishWords(succeeded: Bool) async
    func recoveryWords() async throws -> [String]
    func allowDevice(_ display: CloudSecretsApprovalDisplay) async throws -> Bool
    func showMatchingCode(_ display: CloudSecretsApprovalDisplay) async throws
    func showTransferCode(_ display: CloudSecretsApprovalDisplay) async throws
    func confirmTransferCode(_ display: CloudSecretsApprovalDisplay) async throws -> Bool
    func dismiss() async
    func finishApproval() async
    func confirmReset() async throws -> Bool
}

public enum CloudSecretsProof {
    public static func approval(_ approval: CloudApproval, allow: Bool, version: CloudSequence,
                                envelope: CloudDeviceKeyEnvelope?, canaryHash: String?) throws -> Data {
        struct Body: Encodable {
            let approvalId: String; let allow: Bool; let targetKeyHash: String; let challenge: String
            let expiresAt: Int64; let expectedVersion: CloudSequence; let deviceEnvelopeHash: String?; let canaryHash: String?
        }
        return try CloudSecretsCanonical.encode(Body(approvalId: approval.approvalId, allow: allow,
            targetKeyHash: approval.targetKeyHash, challenge: approval.challenge, expiresAt: approval.expiresAt,
            expectedVersion: version, deviceEnvelopeHash: envelope.map { try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode($0)) }, canaryHash: canaryHash))
    }
    public static func recovery(_ challenge: CloudRecoveryChallenge, target: CloudDeviceRegistration,
                                envelope: CloudDeviceKeyEnvelope) throws -> Data {
        struct Body: Encodable {
            let challengeId: String; let challenge: String; let targetDeviceId: String; let targetKeyHash: String
            let epoch: Int; let expectedVersion: CloudSequence; let deviceEnvelopeHash: String
        }
        return try CloudSecretsCanonical.encode(Body(challengeId: challenge.challengeId, challenge: challenge.challenge,
            targetDeviceId: target.deviceId, targetKeyHash: CloudSecretsCrypto.keyHash(target), epoch: challenge.epoch,
            expectedVersion: challenge.version, deviceEnvelopeHash: CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(envelope))))
    }
    public static func possession(sub: String, deviceId: String, version: CloudSequence, canary: String) -> Data {
        Data("TD-CLOUD-POSSESSION-1\n\(sub)\n\(deviceId)\n\(version.rawValue)\n\(canary)".utf8)
    }
}

// MARK: a lost Mac signed out from another device (Security design sign-out-lost-mac-design.md, 15 Nov)

/// `rotationDue: true` of `/secrets/status`: a device that held the saved-passwords key was signed out by another
/// device, so the key must change. `holders`: the active devices the account lists as holding the key (the signed-out
/// one is no longer active). The service can only NARROW who gets a copy: each Mac seals only to holders it trusts
/// itself. `since`, `removedDeviceId`, `removedName`: optional extras (0 / empty when the service does not say them).
public struct CloudSecretsRotationDue: Sendable, Equatable {
    public let since: Int64
    public let removedDeviceId: String
    public let removedName: String
    public let holders: [String]
    public init(since: Int64, removedDeviceId: String, removedName: String, holders: [String]) {
        self.since = since; self.removedDeviceId = removedDeviceId; self.removedName = removedName; self.holders = holders
    }
}
/// One copy of the new key, sealed by the rotating Mac for one device it already trusts.
public struct CloudSecretsRotateCopy: Codable, Equatable, Sendable {
    public let targetDeviceId: String
    public let envelope: CloudDeviceKeyEnvelope
    public let canaryHash: String
    public init(targetDeviceId: String, envelope: CloudDeviceKeyEnvelope, canaryHash: String) {
        self.targetDeviceId = targetDeviceId; self.envelope = envelope; self.canaryHash = canaryHash
    }
}
/// `POST /secrets/rotate` (design A5): the reset's fields plus the copies, no ticket. Only while `rotationDue`.
public struct CloudSecretsRotateRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let expectedVersion: CloudSequence
    public let newRecoveryEnvelope: CloudRecoveryEnvelope
    public let newDeviceEnvelope: CloudDeviceKeyEnvelope
    public let canaryHash: String
    public let copies: [CloudSecretsRotateCopy]
    public init(requestId: String, expectedVersion: CloudSequence, newRecoveryEnvelope: CloudRecoveryEnvelope,
                newDeviceEnvelope: CloudDeviceKeyEnvelope, canaryHash: String, copies: [CloudSecretsRotateCopy]) {
        self.requestId = requestId; self.expectedVersion = expectedVersion; self.newRecoveryEnvelope = newRecoveryEnvelope
        self.newDeviceEnvelope = newDeviceEnvelope; self.canaryHash = canaryHash; self.copies = copies
    }
}
/// The rotate answer: reset's shape plus, from service 68cd59435, the copies it could not take (that device asks again).
public struct CloudSecretsRotateReceipt: Codable, Sendable {
    public struct Refused: Codable, Sendable, Equatable {
        public let targetDeviceId: String
        public let code: String
        public init(targetDeviceId: String, code: String) { self.targetDeviceId = targetDeviceId; self.code = code }
    }
    public let epoch: Int
    public let version: CloudSequence
    public let state: CloudVaultState
    public let preservedArchiveId: String
    public let secretsApproved: Bool
    public let refusedCopies: [Refused]?
    public init(epoch: Int, version: CloudSequence, state: CloudVaultState, preservedArchiveId: String, secretsApproved: Bool,
                refusedCopies: [Refused]? = nil) {
        self.epoch = epoch; self.version = version; self.state = state; self.preservedArchiveId = preservedArchiveId
        self.secretsApproved = secretsApproved; self.refusedCopies = refusedCopies
    }
}
/// D1 (service 68cd59435): the requests the account marks `signedOutBefore` (a new sign-in on a machine another of his
/// devices signed out), by approval id, and his "Yes, it's mine" (`POST /devices/confirm-mine {deviceId}`).
public protocol CloudSecretsSignedOutBeforePort: Sendable {
    func signedOutBeforeRequests() async throws -> Set<String>
    func confirmMine(deviceId: String) async throws
}
/// The key change's route and its due flag. A service without it: the port is absent or `rotationDue` throws/nil, and
/// nothing changes on this Mac.
public protocol CloudSecretsRotationPort: Sendable {
    func rotationDue() async throws -> CloudSecretsRotationDue?
    func rotate(_ request: CloudSecretsRotateRequest) async throws -> CloudSecretsRotateReceipt
}
/// Design B4: this Mac was signed out by ANOTHER device. Removes this device id's Cloud keys only (the saved-passwords
/// key, its older generations, the seen-generation mark and the hand-over book). Never any data: a new sign-in gets a new
/// device id and a fresh slot, so nothing removed here could ever be used again on this Mac.
public protocol CloudSecretsLocalKeyForgetPort: Sendable {
    func forgetAfterRemoteSignOut() async throws
}

/// What the sign-out guard may rely on (see `CloudRecoveryCoordinator.signOutState()`).
public struct CloudSecretsSignOutState: Sendable, Equatable {
    public let keyOnThisMac: Bool
    public let recoveryWordsOnFile: Bool?
    /// This account has no recovery words (set up silently): nothing for the person to confirm before signing out;
    /// the last-device warning says only the Cloud copy is lost.
    public let withoutWords: Bool
    public init(keyOnThisMac: Bool, recoveryWordsOnFile: Bool?, withoutWords: Bool = false) {
        self.keyOnThisMac = keyOnThisMac; self.recoveryWordsOnFile = recoveryWordsOnFile; self.withoutWords = withoutWords
    }
}

/// What this Mac can truthfully say about its saved passwords.
public enum CloudSecretsProtection: String, Sendable {
    case locked
    /// The key is saved here but the cloud has not confirmed this Mac yet.
    case waitingForCloud = "waiting-for-cloud"
    case protected
    /// Shown with `.waitingForCloud`, with two buttons: "Ask another device
    /// again" (request_device) and "Use recovery words" (recover).
    public static let waitingAdvice = "Saved on this Mac, waiting for Cloud to confirm it. If it stays like this, ask another device again."
}
