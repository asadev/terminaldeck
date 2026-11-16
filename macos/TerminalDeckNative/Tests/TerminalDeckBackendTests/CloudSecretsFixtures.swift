import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// TEST TARGET ONLY. No URL, credential, production configuration or filesystem defaults.
struct CloudSecretsFixtureKeys: CloudDeviceKeyPort, Sendable {
    let signing: P256.Signing.PrivateKey
    let wrapping: P256.KeyAgreement.PrivateKey
    init() { signing = .init(); wrapping = .init() }
    init(sign: Data, wrap: Data) throws {
        signing = try .init(rawRepresentation: sign); wrapping = try .init(rawRepresentation: wrap)
    }
    func registration(_ id: String) throws -> CloudDeviceRegistration {
        .init(deviceId: id, label: "Fixture Mac", platform: .macos, appVersion: "fixture",
              signPublicJwk: try CloudSecretsCrypto.publicJWK(signing.publicKey.x963Representation),
              wrapPublicJwk: try CloudSecretsCrypto.publicJWK(wrapping.publicKey.x963Representation))
    }
    func signDevicePayload(_ bytes: Data) async throws -> Data { try signing.signature(for: bytes).rawRepresentation }
    func deviceSharedSecret(peer: CloudPublicJWK) async throws -> Data {
        try wrapping.sharedSecretFromKeyAgreement(with: .init(x963Representation: CloudSecretsCrypto.x963(peer))).withUnsafeBytes { Data($0) }
    }
}
actor CloudSecretsFixtureLocal: CloudSecretsLocalKeyPort, CloudSecretsHandOverBookPort {
    var value: CloudSecretsLocalKey?
    var saves = 0
    var failSave = false
    var failRead = false
    func read() throws -> CloudSecretsLocalKey? {
        if failRead { throw CloudFailure.unavailable } // e.g. a transient protected-store failure
        return value
    }
    func rejectReads() { failRead = true }
    func allowReads() { failRead = false }
    func saveVerified(_ key: CloudSecretsLocalKey) throws {
        if failSave { throw CloudFailure.unavailable }
        value = key; saves += 1
    }
    func loseKey() { value = nil }
    func rejectWrites() { failSave = true }
    var archives: [Int: CloudSecretsLocalKey] = [:]
    func archive(_ key: CloudSecretsLocalKey) { archives[key.epoch] = key }
    func archived(epoch: Int) -> CloudSecretsLocalKey? { archives[epoch] }
    var seenEpoch: Int?
    func seenCloudEpoch() -> Int? { seenEpoch }
    func saveSeenCloudEpoch(_ epoch: Int) { seenEpoch = epoch }
    func acceptWrites() { failSave = false }
    /// The hand-over book beside the key (PASSWORDS-2): survives anything that only deletes files.
    var book: CloudSecretsHandOverBook?
    var failBook = false
    func handOverBook() throws -> CloudSecretsHandOverBook? { if failBook { throw CloudFailure.unavailable }; return book }
    func saveHandOverBook(_ value: CloudSecretsHandOverBook) throws { if failBook { throw CloudFailure.unavailable }; book = value }
    func breakBook(_ broken: Bool) { failBook = broken }
}
actor CloudSecretsFixtureUI: CloudSecretsInteractionPort {
    var phrase: [String] = []
    var entered: [String]?
    var confirm = true
    var allow = true
    var resetAllowed = true
    var expectedTransferCode: String?
    var transferConfirmation = true
    var confirmationCount = 0
    /// Second codes the joining person was asked to compare; dismiss() keeps it.
    var transferPrompts: [String] = []
    var finished: Bool?
    var dismissals = 0
    var displays: [CloudSecretsApprovalDisplay] = []
    var whileConfirming: (@Sendable () async throws -> Void)?
    func confirmWords(_ words: [String], positions: [Int]) async throws -> CloudRecoveryConfirmation {
        phrase = words; confirmationCount += 1
        if let whileConfirming { try await whileConfirming() }
        return .init(keptWords: confirm, answers: confirm ? Dictionary(uniqueKeysWithValues: positions.map { ($0, words[$0]) }) : [:])
    }
    func finishWords(succeeded: Bool) { finished = succeeded }
    func recoveryWords() -> [String] { entered ?? phrase }
    func allowDevice(_ display: CloudSecretsApprovalDisplay) async throws -> Bool {
        displays.append(display)
        if let whileConfirming { try await whileConfirming() }
        return allow
    }
    func showMatchingCode(_ display: CloudSecretsApprovalDisplay) { displays.append(display) }
    func showTransferCode(_ display: CloudSecretsApprovalDisplay) { displays.append(display) }
    func confirmTransferCode(_ display: CloudSecretsApprovalDisplay) -> Bool {
        displays.append(display); transferPrompts.append(display.matchingCode)
        return transferConfirmation && (expectedTransferCode == nil || expectedTransferCode == display.matchingCode)
    }
    func matchTransferCode(_ code: String) { expectedTransferCode = code }
    func denyTransferConfirmation() { transferConfirmation = false }
    func allowTransferConfirmation() { transferConfirmation = true }
    func dismiss() { phrase = []; entered = nil; displays = []; dismissals += 1 }
    func finishApproval() {}
    func confirmReset() -> Bool { resetAllowed }
    func setConfirmation(_ value: Bool) { confirm = value }
    func setAllow(_ value: Bool) { allow = value }
    func setWords(_ value: [String]) { entered = value }
    func onConfirmation(_ action: @escaping @Sendable () async throws -> Void) { whileConfirming = action }
}
actor CloudSecretsFixtureGate {
    let clock: Int64
    var enabled = false
    var allowed = true
    init(clock: Int64) { self.clock = clock }
    func value() -> CloudGate { .init(features: allowed ? ["cloud"] : [], storageEntitled: true, aiSubscriptionsEnabled: enabled, expiresAt: clock + 300_000) }
    func disableCloud() { allowed = false }
}

actor CloudSecretsFixtureServer {
    static let sub = "11111111-1111-4111-8111-111111111111"
    static let now: Int64 = 1_800_000_000_000
    static let resetTicket = CloudSecretsCrypto.encode(Data(repeating: 0x42, count: 32))
    var devices: [String: CloudDeviceRegistration] = [:]
    var approved: Set<String> = []
    var envelopes: [String: CloudDeviceKeyEnvelope] = [:]
    var hashes: [String: String] = [:]
    var approvals: [String: CloudApproval] = [:]
    var usedApprovals: Set<String> = []
    var challenges: [String: (String, CloudRecoveryChallenge)] = [:]
    var usedChallenges: Set<String> = []
    var recovery: CloudRecoveryEnvelope?
    var epoch = 0
    var version: UInt64 = 0
    var bodies: [Data] = []
    var checkedBodies = 0
    var completedRecoveries = 0
    var archivedRecovery: [CloudRecoveryEnvelope] = []
    var archivedEnvelopes: [[String: CloudDeviceKeyEnvelope]] = []
    var archives: Int { archivedRecovery.count }
    var responses: [String: (String, Data)] = [:]
    var failAt: String?
    var replacement: CloudDeviceRegistration?
    var capturedAnswer: CloudApprovalAnswer?
    /// Review of 6e8f1d50 (point 2): the requesting device's own signature, kept with its approval and returned
    /// unchanged in `pendingApprovals` (the service change in PASSWORDS-SERVICE-CHANGE.md).
    var requestSignatures: [String: String] = [:]
    /// The service follow-up for the stricter setting: kept per account, newest `at` wins, handed back unchanged.
    var askPolicy: CloudSecretsAskPolicy?
    /// Leave `askPolicy` out of the status (a service without the route).
    var policyRoute = true
    /// "Start again" with no ticket taken (td-cloud 2fb865f1).
    var resetsWithoutTicket = 0
    /// Slice 2 (service follow-up): the passkey spares, each passkey's public key, the one-time challenges.
    var spares: [CloudSecretsSpare] = []
    var passkeyKeys: [String: CloudPublicJWK] = [:]
    var spareChallenges: [String: String] = [:]
    /// The service's own record of who added this generation's spare (7ff81baac), and when.
    var spareAdded: (by: String, at: Int64)?
    /// How many spare challenges were handed out (each is a receipt row on the real service).
    var spareChallengeCount = 0
    /// The new service's optional status facts (72959fbbd, 7ff81baac): `nobodyCanOpen`, `askPolicy` only while ON,
    /// `askPolicyTurnedOff {by, byName, changedAt}` when OFF, `spare {addedBy, addedByName, addedAt}`. Off = today's
    /// live service, which sends none of them.
    var serviceFacts = false
    var policyChangedAt: Int64 = 0
    func useServiceFacts(_ value: Bool = true) { serviceFacts = value }
    func setAskPolicy(_ value: CloudSecretsAskPolicy?, changedAt: Int64 = CloudSecretsFixtureServer.now) { askPolicy = value; policyChangedAt = changedAt }
    /// Like the service: the spare and policy routes answer only to a computer (a Mac or a Windows PC).
    func computer(_ caller: String) -> Bool { devices[caller].map { [CloudPlatform.macos, .windows].contains($0.platform) } ?? false }
    func notComputer(_ requestId: String) -> CloudFailure {
        .remote(.init(code: "not_approved", message: "fixture", retryable: false, requestId: requestId))
    }
    func registerPasskey(_ credentialId: String, key: CloudPublicJWK) { passkeyKeys[credentialId] = key }
    /// PASSWORDS-5 repair (service 7750c816e): the last replace of this generation's spare, every replace request,
    /// and per-caller frozen status answers (a Mac reading its kept answer inside the 60-s notice floor).
    var spareReplacedBy: (by: String, at: Int64)?
    var replaceRequests: [CloudSecretsSpareReplaceRequest] = []
    var frozenStatus: [String: Data] = [:]
    var freezing: Set<String> = []
    func freezeStatus(for caller: String) { freezing.insert(caller) }
    func refused(_ code: String, _ requestId: String) -> CloudFailure {
        .remote(.init(code: code, message: "fixture", retryable: false, requestId: requestId))
    }
    /// PASSWORDS-5 point 6: the account's device list by friendly name (off = a control without the names port).
    var friendlyNames: [String: String] = [:]
    var namesRoute = false
    func useFriendlyNames(_ names: [String: String]) { friendlyNames = names; namesRoute = true }
    func deviceNames() throws -> [CloudSecretsDeviceName] {
        guard namesRoute else { throw CloudFailure.unavailable }
        return devices.values.map { .init(deviceId: $0.deviceId, name: friendlyNames[$0.deviceId] ?? $0.label, holdsKey: approved.contains($0.deviceId)) }
    }
    /// A hostile service rewrites what it hands out (the wrapping-key swap test).
    func forgeApprovalHash(_ approvalId: String, _ hash: String) {
        guard let a = approvals[approvalId] else { return }
        approvals[approvalId] = CloudApproval(approvalId: a.approvalId, targetDeviceId: a.targetDeviceId, targetKeyHash: hash,
                                              challenge: a.challenge, expiresAt: a.expiresAt)
    }
    var capturedRecovery: CloudRecoveryCompleteRequest?
    var lastResetReply: Data?
    let roster = ["seat-1", "seat-2", "seat-3"]
    var sequence: CloudSequence { CloudSequence(version) }
    /// Lost-device design A2/A5: a device holding the key was signed out from another device; the change is due.
    var rotationDue: (since: Int64, removed: String, name: String)?
    var rotations = 0
    var rotateRequests: [CloudSecretsRotateRequest] = []
    var lastRefusedCopies: [CloudSecretsRotateReceipt.Refused] = []
    /// Copies the service will not take although it lists the device (a phone answered but not proven, phones switch).
    var refuseCopiesFor: Set<String> = []
    func refuseCopy(for id: String) { refuseCopiesFor.insert(id) }
    /// A service that swaps a device's wrapping key (review finding 2).
    func swapWrapKey(_ id: String, to wrap: CloudPublicJWK) {
        guard let d = devices[id] else { return }
        devices[id] = CloudDeviceRegistration(deviceId: d.deviceId, label: d.label, platform: d.platform, appVersion: d.appVersion,
                                              signPublicJwk: d.signPublicJwk, wrapPublicJwk: wrap)
    }
    /// A1/A2: another device signs `id` out while it holds the key: revoked (gone from the list), its copy dropped, due.
    func signOutKeyHolder(_ id: String, name: String) {
        devices[id] = nil; approved.remove(id); envelopes[id] = nil; hashes[id] = nil
        if rotationDue == nil { rotationDue = (Self.now + Int64(rotations), id, name) }
    }
    /// The devices the service lists as holding the CURRENT key (68cd59435: approved AND an envelope of this epoch).
    var holders: [String] { approved.filter { envelopes[$0]?.epoch == epoch }.sorted() }
    /// D1 (68cd59435): new sign-ins on a machine another device signed out, until his "Yes, it's mine".
    var signedOutBefore: Set<String> = []
    var confirmedMine: [String] = []
    func markSignedOutBefore(_ id: String) { signedOutBefore.insert(id) }
    func rotate(_ caller: String, _ request: CloudSecretsRotateRequest) throws -> CloudSecretsResetReceipt {
        try capture(request, at: "rotate")
        // As built: a stale version first (a race loser always gets it), then the caller holding the key, then "due".
        guard computer(caller) else { throw refused("not_approved", request.requestId) }
        guard request.expectedVersion == sequence else { throw refused("version_changed", request.requestId) }
        guard approved.contains(caller), envelopes[caller]?.epoch == epoch else { throw refused("not_approved", request.requestId) }
        guard let due = rotationDue else { throw refused("not_due", request.requestId) }
        guard request.newRecoveryEnvelope.epoch == epoch + 1, let previousRecovery = recovery,
              request.newRecoveryEnvelope.version == CloudSequence(UInt64(previousRecovery.version.rawValue)! + 1),
              request.newDeviceEnvelope.epoch == epoch + 1, let device = devices[caller] else { throw CloudFailure.invalidRequest }
        try envelopeSignature(request.newDeviceEnvelope, author: device.signPublicJwk, target: caller)
        // 68cd59435: a copy the service cannot take fails ONLY that copy (named in refusedCopies); the switch goes on.
        var taken: [CloudSecretsRotateCopy] = []
        lastRefusedCopies = []
        for copy in request.copies {
            let fine = !refuseCopiesFor.contains(copy.targetDeviceId) && copy.targetDeviceId != due.removed && devices[copy.targetDeviceId] != nil && holders.contains(copy.targetDeviceId)
                && copy.envelope.epoch == epoch + 1 && copy.envelope.authorDeviceId == caller && copy.envelope.targetDeviceId == copy.targetDeviceId
                && (try? envelopeSignature(copy.envelope, author: device.signPublicJwk, target: copy.targetDeviceId)) != nil
            if fine { taken.append(copy) } else { lastRefusedCopies.append(.init(targetDeviceId: copy.targetDeviceId, code: "not_approved")) }
        }
        rotateRequests.append(request)
        archivedRecovery.append(previousRecovery); archivedEnvelopes.append(envelopes)
        epoch += 1; version += 1; recovery = request.newRecoveryEnvelope; rotations += 1
        // Deviation 1: the caller and each target get their envelope NOT approved; each proves it with possession.
        approved = []
        envelopes = [caller: request.newDeviceEnvelope]; hashes = [caller: request.canaryHash]
        for copy in taken { envelopes[copy.targetDeviceId] = copy.envelope; hashes[copy.targetDeviceId] = copy.canaryHash }
        rotationDue = nil
        return .init(epoch: epoch, version: sequence, state: .ready, preservedArchiveId: UUID().uuidString.lowercased(), secretsApproved: false)
    }
    func register(_ registration: CloudDeviceRegistration) { devices[registration.deviceId] = registration }
    /// Real server behaviour: re-registration keeps the first label/app version,
    /// and /devices/rename changes the label. Keys stay the same.
    func relabel(_ id: String, label: String, appVersion: String) throws {
        guard let old = devices[id] else { throw CloudFailure.invalidRequest }
        devices[id] = .init(deviceId: id, label: label, platform: old.platform, appVersion: appVersion,
                            signPublicJwk: old.signPublicJwk, wrapPublicJwk: old.wrapPublicJwk)
    }
    func replayArchivedVault() throws {
        guard let old = archivedRecovery.first, let devices = archivedEnvelopes.first else { throw CloudFailure.invalidRequest }
        recovery = old; epoch = old.epoch; version += 1; envelopes = devices; approved = []; hashes = [:]
    }
    func installForgedEnvelope(_ envelope: CloudDeviceKeyEnvelope, canaryHash: String, author: CloudDeviceRegistration) {
        devices[author.deviceId] = author; envelopes[envelope.targetDeviceId] = envelope; hashes[envelope.targetDeviceId] = canaryHash
    }
    func fault(_ stage: String?) { failAt = stage }
    // Holds the next possession request until released (a real task cancel test).
    var holdPossession = false
    var holding = false
    private var release: CheckedContinuation<Void, Never>?
    func holdNextPossession() { holdPossession = true }
    func gatePossession() async {
        guard holdPossession else { return }
        holding = true
        await withCheckedContinuation { release = $0 }
    }
    func releasePossession() { holdPossession = false; release?.resume(); release = nil }
    func removeEnvelope(_ id: String) -> (CloudDeviceKeyEnvelope, String)? {
        guard let envelope = envelopes[id], let hash = hashes[id] else { return nil }
        envelopes[id] = nil; hashes[id] = nil
        return (envelope, hash)
    }
    func restoreEnvelope(_ value: (CloudDeviceKeyEnvelope, String), for id: String) { envelopes[id] = value.0; hashes[id] = value.1 }
    func substitute(_ registration: CloudDeviceRegistration?) { replacement = registration }
    func capture<T: Encodable>(_ value: T, at point: String) throws {
        if failAt == "cancelAfterWords", point == "initialize" { throw CancellationError() }
        if failAt == "cancelAtPossession", point == "possession" { throw CancellationError() }
        let body = try CloudSecretsCanonical.encode(value)
        let raw = try NativeRPCValue.parseJSON(body)
        func safe(_ value: NativeRPCValue) -> Bool {
            if let fields = value.fields {
                if fields.contains(where: { ["rootKey", "root", "words", "entropy", "privateKey", "seed", "d"].contains($0.key) }) { return false }
                return fields.allSatisfy { safe($0.value) }
            }
            return value.elements?.allSatisfy(safe) ?? true
        }
        guard body.count <= 131_072, safe(raw) else { throw CloudFailure.invalidRequest }
        checkedBodies += 1; bodies.append(body)
        if failAt == point { throw CloudFailure.unavailable }
    }
    func envelopeSignature(_ envelope: CloudDeviceKeyEnvelope, author: CloudPublicJWK, target: String) throws {
        guard envelope.targetDeviceId == target, devices[target] != nil else { throw CloudFailure.invalidRequest }
        let aad = try CloudSecretsCrypto.deviceAAD(envelope)
        try CloudSecretsCrypto.verify(envelope.signature,
            bytes: aad + CloudSecretsCrypto.decode(envelope.ciphertext) + CloudSecretsCrypto.decode(envelope.tag, count: 16), key: author)
    }
    func status(_ caller: String) throws -> CloudSecretsStatus {
        try capture([String: String](), at: "status")
        return .init(state: epoch == 0 ? .unset : .ready, epoch: epoch, version: sequence,
                     recoveryReady: recovery != nil, approvedDeviceCount: approved.count,
                     pendingApprovals: approved.contains(caller) ? approvals.values.filter { !usedApprovals.contains($0.approvalId) } : [])
    }
    func initialize(_ caller: String, _ request: CloudSecretsInitializeRequest) throws -> CloudSecretsEnvelopeReceipt {
        try capture(request, at: "initialize")
        guard epoch == 0, request.expectedVersion == .zero, request.confirmation, let device = devices[caller],
              request.deviceEnvelope.authorDeviceId == caller, request.recoveryEnvelope.version == CloudSequence(1) else { throw CloudFailure.invalidRequest }
        try envelopeSignature(request.deviceEnvelope, author: device.signPublicJwk, target: caller)
        epoch = 1; version = 1; recovery = request.recoveryEnvelope
        envelopes[caller] = request.deviceEnvelope; hashes[caller] = request.canaryHash
        return .init(epoch: epoch, version: sequence, deviceEnvelope: request.deviceEnvelope, secretsApproved: false)
    }
    func request(_ caller: String, _ request: CloudApprovalRequest) throws -> CloudApproval {
        try capture(request, at: "approvalRequest")
        guard request.targetDeviceId == caller, let device = devices[caller], request.targetKeyHash == (try CloudSecretsCrypto.keyHash(device)) else { throw CloudFailure.invalidRequest }
        let approval = CloudApproval(approvalId: UUID().uuidString.lowercased(), targetDeviceId: caller, targetKeyHash: request.targetKeyHash,
            challenge: CloudSecretsCrypto.encode(try CloudSecretsCrypto.random(32)), expiresAt: Self.now + 600_000)
        approvals[approval.approvalId] = approval
        return approval
    }
    func answer(_ caller: String, _ request: CloudApprovalAnswer) throws -> CloudSecretsAnswerReceipt {
        try capture(request, at: "answer")
        guard let approval = approvals[request.approvalId], approval.expiresAt > Self.now, !usedApprovals.contains(request.approvalId),
              approved.contains(caller), caller != approval.targetDeviceId, request.proof.signerDeviceId == caller,
              request.expectedVersion == sequence, let author = devices[caller], let target = devices[approval.targetDeviceId],
              try CloudSecretsCrypto.keyHash(target) == approval.targetKeyHash else { throw CloudFailure.invalidRequest }
        let proof = try CloudSecretsProof.approval(approval, allow: request.allow, version: sequence,
                                                 envelope: request.deviceEnvelope, canaryHash: request.canaryHash)
        try CloudSecretsCrypto.verify(request.proof.signature, bytes: proof, key: author.signPublicJwk)
        if request.allow {
            guard let envelope = request.deviceEnvelope, let hash = request.canaryHash, envelope.authorDeviceId == caller,
                  envelope.epoch == epoch else { throw CloudFailure.invalidRequest }
            try envelopeSignature(envelope, author: author.signPublicJwk, target: approval.targetDeviceId)
            envelopes[approval.targetDeviceId] = envelope; hashes[approval.targetDeviceId] = hash
        } else { guard request.deviceEnvelope == nil, request.canaryHash == nil else { throw CloudFailure.invalidRequest } }
        usedApprovals.insert(request.approvalId); version += 1; capturedAnswer = request
        return .init(approvalId: request.approvalId, state: request.allow ? "approved" : "denied")
    }
    func envelope(_ caller: String) throws -> CloudSecretsEnvelopeReceipt {
        try capture([String: String](), at: "envelope")
        guard let envelope = envelopes[caller] else { throw CloudFailure.secretsLocked }
        return .init(epoch: epoch, version: sequence, deviceEnvelope: envelope)
    }
    func possession(_ caller: String, _ request: CloudPossessionRequest) throws -> CloudSecretsPossessionReceipt {
        try capture(request, at: "possession")
        // Real server (secrets.ts possession): an approved device is refused.
        if approved.contains(caller) {
            throw CloudFailure.remote(.init(code: "secrets_locked", message: "fixture", retryable: false, requestId: request.requestId))
        }
        guard request.expectedVersion == sequence, let device = devices[caller],
              hashes[caller] == CloudSecretsCrypto.hash(try CloudSecretsCrypto.decode(request.canary, count: 32)) else { throw CloudFailure.invalidRequest }
        try CloudSecretsCrypto.verify(request.signature, bytes: CloudSecretsProof.possession(sub: Self.sub, deviceId: caller,
            version: sequence, canary: request.canary), key: device.signPublicJwk)
        approved.insert(caller); version += 1
        return .init(secretsApproved: true, epoch: epoch, version: sequence)
    }
    func challenge(_ caller: String, _ request: CloudRecoveryChallengeRequest) throws -> CloudRecoveryChallenge {
        try capture(request, at: "recoveryReadback")
        guard let recovery, let device = devices[caller], request.targetKeyHash == (try CloudSecretsCrypto.keyHash(device)) else { throw CloudFailure.invalidRequest }
        let challenge = CloudRecoveryChallenge(challengeId: UUID().uuidString.lowercased(), challenge: CloudSecretsCrypto.encode(try CloudSecretsCrypto.random(32)),
            expiresAt: Self.now + 300_000, epoch: epoch, version: sequence, recoveryEnvelope: recovery)
        challenges[challenge.challengeId] = (caller, challenge)
        return challenge
    }
    func recover(_ caller: String, _ request: CloudRecoveryCompleteRequest) throws -> CloudSecretsEnvelopeReceipt {
        try capture(request, at: "recover")
        guard let (owner, challenge) = challenges[request.challengeId], challenge.expiresAt > Self.now, owner == caller, !usedChallenges.contains(request.challengeId),
              request.expectedVersion == sequence, challenge.version == sequence, let device = devices[caller], let recovery,
              request.targetKeyHash == (try CloudSecretsCrypto.keyHash(device)), request.deviceEnvelope.authorDeviceId == "recovery" else { throw CloudFailure.invalidRequest }
        try envelopeSignature(request.deviceEnvelope, author: recovery.publicSigningJwk, target: caller)
        try CloudSecretsCrypto.verify(request.signature, bytes: CloudSecretsProof.recovery(challenge, target: device, envelope: request.deviceEnvelope), key: recovery.publicSigningJwk)
        usedChallenges.insert(request.challengeId); envelopes[caller] = request.deviceEnvelope; approved.insert(caller)
        version += 1; completedRecoveries += 1; capturedRecovery = request
        return .init(epoch: epoch, version: sequence, deviceEnvelope: request.deviceEnvelope, secretsApproved: true)
    }
    func reset(_ caller: String, _ request: CloudSecretsResetRequest) throws -> CloudSecretsResetReceipt {
        try capture(request, at: "reset")
        // No ticket: taken only from a computer while nobody can open the copy: no device holds an envelope of this
        // generation (confirmed or not) and the recovery copy is the placeholder (secrets.ts `nobodyCanOpen`).
        if request.resetTicket == nil {
            guard devices[caller]?.platform == .macos, approved.isEmpty, envelopes.isEmpty, recovery?.isPlaceholder == true else {
                throw CloudFailure.remote(.init(code: "not_approved", message: "fixture", retryable: false, requestId: request.requestId))
            }
            resetsWithoutTicket += 1
        }
        guard request.expectedVersion == sequence, request.confirmation, request.resetTicket == nil || request.resetTicket == Self.resetTicket,
              request.newRecoveryEnvelope.epoch == epoch + 1, let previousRecovery = recovery,
              request.newRecoveryEnvelope.version == CloudSequence(UInt64(previousRecovery.version.rawValue)! + 1),
              let device = devices[caller] else { throw CloudFailure.invalidRequest }
        try envelopeSignature(request.newDeviceEnvelope, author: device.signPublicJwk, target: caller)
        archivedRecovery.append(previousRecovery); archivedEnvelopes.append(envelopes)
        epoch += 1; version += 1; recovery = request.newRecoveryEnvelope
        approved.removeAll(); envelopes = [caller: request.newDeviceEnvelope]; hashes = [caller: request.canaryHash]
        return .init(epoch: epoch, version: sequence, state: .ready, preservedArchiveId: UUID().uuidString.lowercased(), secretsApproved: false)
    }
    /// Every request a device sent to this service (PASSWORDS-3 fix 1 counts them).
    var requestCount = 0
    func handle(caller: String, method: String, path: String, body: Data, requestId: String) throws -> Data {
        requestCount += 1
        if method == "GET" {
            guard body.isEmpty else { throw CloudFailure.invalidRequest }
            if path == "/secrets/status" {
                if freezing.contains(caller), let kept = frozenStatus[caller] { return kept }
                let answer = try statusAnswer(caller)
                frozenStatus[caller] = answer
                return answer
            }
            if path == "/secrets/envelope" { return try CloudSecretsCanonical.encode(envelope(caller)) }
            throw CloudFailure.invalidRequest
        }
        return try post(caller: caller, method: method, path: path, body: body, requestId: requestId)
    }
    private func statusAnswer(_ caller: String) throws -> Data {
                var plain = try CloudSecretsCanonical.encode(status(caller))
                if serviceFacts {
                    // The new service's shapes, exactly (secrets.ts askPolicyField / spareField / nobodyCanOpen).
                    var extra: [NativeRPCValue.Field] = [.init("nobodyCanOpen", .bool(epoch > 0 && approved.isEmpty
                        && !envelopes.values.contains { $0.epoch == epoch }))]
                    if policyRoute, let askPolicy {
                        let name = NativeRPCValue.string(devices[askPolicy.by]?.label ?? "")
                        if askPolicy.askOnNewDevice {
                            extra.append(.init("askPolicy", .object([.init("askOnNewDevice", .bool(true)), .init("at", .number(Double(askPolicy.at))),
                                .init("by", .string(askPolicy.by)), .init("signature", .string(askPolicy.signature)), .init("byName", name),
                                .init("changedAt", .number(Double(policyChangedAt)))])))
                        } else {
                            extra.append(.init("askPolicyTurnedOff", .object([.init("by", .string(askPolicy.by)), .init("byName", name),
                                .init("changedAt", .number(Double(policyChangedAt)))])))
                        }
                    }
                    if let spareAdded, let current = spares.first(where: { $0.epoch == epoch }) {
                        var fields: [NativeRPCValue.Field] = [.init("addedBy", .string(spareAdded.by)),
                            .init("addedByName", .string(devices[spareAdded.by]?.label ?? "")), .init("addedAt", .number(Double(spareAdded.at))),
                            .init("credentialId", .string(current.credentialId))]
                        if let replaced = spareReplacedBy {
                            fields += [.init("replacedBy", .string(replaced.by)), .init("replacedByName", .string(devices[replaced.by]?.label ?? "")),
                                       .init("replacedAt", .number(Double(replaced.at)))]
                        }
                        extra.append(.init("spare", .object(fields)))
                    }
                    let raw = try NativeRPCValue.parseJSON(plain)
                    plain = try NativeRPCValue.object((raw.fields ?? []) + extra).encodedJSON()
                } else if policyRoute, let askPolicy {
                    let raw = try NativeRPCValue.parseJSON(plain)
                    let value = try NativeRPCValue.parseJSON(CloudSecretsCanonical.encode(askPolicy))
                    plain = try NativeRPCValue.object((raw.fields ?? []) + [.init("askPolicy", value)]).encodedJSON()
                }
                if computer(caller), let due = rotationDue {
                    // As built (d0c902d76): the object, computers only, only while due.
                    let raw = try NativeRPCValue.parseJSON(plain)
                    let field = NativeRPCValue.object([.init("since", .number(Double(due.since))), .init("removedDeviceId", .string(due.removed)),
                        .init("removedName", .string(due.name)), .init("holders", .array(holders.filter { $0 != due.removed }.map { .string($0) }))])
                    plain = try NativeRPCValue.object((raw.fields ?? []) + [.init("rotationDue", field)]).encodedJSON()
                }
                if !signedOutBefore.isEmpty {
                    // D1 (68cd59435): the flag on each pending request of such a device.
                    let raw = try NativeRPCValue.parseJSON(plain)
                    plain = try NativeRPCValue.object((raw.fields ?? []).map { field in
                        guard field.key == "pendingApprovals" else { return field }
                        return .init("pendingApprovals", .array((field.value.elements ?? []).map { item in
                            guard let target = item["targetDeviceId"].string, signedOutBefore.contains(target) else { return item }
                            return .object((item.fields ?? []) + [.init("signedOutBefore", .bool(true))])
                        }))
                    }).encodedJSON()
                }
                guard !requestSignatures.isEmpty else { return plain }
                // The service change: each pending approval carries `targetSignature` when its device signed it.
                let raw = try NativeRPCValue.parseJSON(plain)
                let fields: [NativeRPCValue.Field] = (raw.fields ?? []).map { field in
                    guard field.key == "pendingApprovals" else { return field }
                    return .init("pendingApprovals", .array((field.value.elements ?? []).map { item in
                        guard let id = item["approvalId"].string, let signature = requestSignatures[id] else { return item }
                        return .object((item.fields ?? []) + [.init("targetSignature", .string(signature))])
                    }))
                }
                return try NativeRPCValue.object(fields).encodedJSON()
    }
    private func post(caller: String, method: String, path: String, body: Data, requestId: String) throws -> Data {
        func input<T: Codable>(_ type: T.Type) throws -> T {
            guard method == "POST", body.count <= 131_072 else { throw CloudFailure.invalidRequest }
            let raw = try NativeRPCValue.parseJSON(body)
            guard raw["requestId"].string == requestId else { throw CloudFailure.invalidRequest }
            let decoded = try CloudWire.decode(type, from: body, maximumBytes: 131_072)
            guard try CloudSecretsCanonical.encode(decoded) == body else { throw CloudFailure.invalidRequest }
            return decoded
        }
        _ = try CloudSecretsCrypto.uuidBytes(requestId)
        guard requestId == UUID(uuidString: requestId)?.uuidString.lowercased() else { throw CloudFailure.invalidRequest }
        let fingerprint = CloudSecretsCrypto.hash(Data((caller + method + path).utf8) + body)
        try capture(CloudValue(NativeRPCValue.parseJSON(body)), at: "wire")
        if let cached = responses[requestId] {
            guard cached.0 == fingerprint else { throw CloudFailure.idReused }
            return cached.1
        }
        let result: Data
        switch path {
        case "/secrets/initialize": result = try CloudSecretsCanonical.encode(initialize(caller, input(CloudSecretsInitializeRequest.self)))
        case "/secrets/approval/request":
            let approval = try request(caller, input(CloudApprovalRequest.self))
            result = try CloudSecretsCanonical.encode(CloudValue(.object([.init("approvalId", .string(approval.approvalId)),
                .init("challenge", .string(approval.challenge)), .init("expiresAt", .number(Double(approval.expiresAt)))])))
        case "/secrets/approval/answer": result = try CloudSecretsCanonical.encode(answer(caller, input(CloudApprovalAnswer.self)))
        case "/secrets/approval/sign":
            struct Sign: Codable { let requestId: String; let approvalId: String; let signature: String }
            let body = try input(Sign.self)
            // Only the approval's own device may sign it, with its registered signing key.
            guard let approval = approvals[body.approvalId], approval.targetDeviceId == caller, let device = devices[caller] else { throw CloudFailure.invalidRequest }
            try CloudSecretsCrypto.verify(body.signature, bytes: CloudSecretsProof.request(sub: Self.sub, approval: approval,
                wrapPublicJwk: device.wrapPublicJwk, epoch: epoch), key: device.signPublicJwk)
            requestSignatures[body.approvalId] = body.signature
            result = try CloudSecretsCanonical.encode(["approvalId": body.approvalId])
        case "/secrets/policy":
            guard policyRoute else { throw CloudFailure.remote(.init(code: "not_found", message: "fixture", retryable: false, requestId: requestId)) }
            struct Policy: Codable { let requestId: String; let askPolicy: CloudSecretsAskPolicy }
            let body = try input(Policy.self)
            guard computer(caller) else { throw notComputer(requestId) }
            guard let device = devices[caller] , body.askPolicy.by == caller else { throw CloudFailure.invalidRequest }
            try CloudSecretsCrypto.verify(body.askPolicy.signature, bytes: CloudSecretsProof.askPolicy(sub: Self.sub,
                askOnNewDevice: body.askPolicy.askOnNewDevice, at: body.askPolicy.at, by: caller), key: device.signPublicJwk)
            if body.askPolicy.at > askPolicy?.at ?? 0 { askPolicy = body.askPolicy; policyChangedAt = body.askPolicy.at }   // the fixture's clock stands still
            result = try CloudSecretsCanonical.encode(["at": askPolicy?.at ?? body.askPolicy.at])
        case "/secrets/spare/challenge":
            struct Ask: Codable { let requestId: String }
            _ = try input(Ask.self)
            guard computer(caller) else { throw notComputer(requestId) }
            spareChallengeCount += 1
            let id = UUID().uuidString.lowercased(), challenge = CloudSecretsCrypto.encode(try CloudSecretsCrypto.random(32))
            spareChallenges[id] = challenge
            result = try CloudSecretsCanonical.encode(CloudSecretsSpareChallenge(challengeId: id, challenge: challenge,
                userId: CloudSecretsCrypto.encode(Data(Self.sub.utf8)), expiresAt: Self.now + 300_000, spares: spares.filter { $0.epoch == epoch }))
        case "/secrets/spare/add":
            let body = try input(CloudSecretsSpareAddRequest.self)
            // Only an approved computer of the current generation; the registration names the passkey it seals for; ONE
            // spare per generation; the adding device's own signature over the spare (TD-PASSWORDS-SPARE-1, 7ff81baac).
            guard computer(caller) else { throw notComputer(requestId) }
            guard approved.contains(caller), let device = devices[caller], spareChallenges.removeValue(forKey: body.challengeId) != nil,
                  body.spare.credentialId == body.credentialId, body.spare.epoch == epoch, passkeyKeys[body.credentialId] != nil
            else { throw CloudFailure.invalidRequest }
            // Like secrets.ts spareAdd (7750c816e): a second spare of this generation is `spare_exists` (409).
            guard spares.filter({ $0.epoch == epoch }).isEmpty else { throw refused("spare_exists", requestId) }
            try CloudSecretsCrypto.verify(body.signature, bytes: CloudSecretsProof.spare(sub: Self.sub, by: caller, epoch: epoch,
                credentialId: body.credentialId, spare: body.spare), key: device.signPublicJwk)
            spares.append(body.spare); spareAdded = (caller, Self.now)
            result = try CloudSecretsCanonical.encode(["credentialId": body.credentialId])
        case "/secrets/spare/replace":
            // As secrets.ts spareReplace (7750c816e): approved computer; the stored spare named by `replaces`; at most 3
            // replaces an hour; the new passkey's registration; a different passkey; this device's own signature.
            let body = try input(CloudSecretsSpareReplaceRequest.self)
            guard computer(caller) else { throw notComputer(requestId) }
            guard approved.contains(caller), let device = devices[caller] else { throw refused("not_approved", requestId) }
            guard let old = spares.first(where: { $0.epoch == epoch }) else { throw refused("no_spare", requestId) }
            guard old.credentialId == body.replaces else { throw refused("spare_changed", requestId) }
            guard replaceRequests.count < 3 else { throw refused("rate_limited", requestId) }
            guard spareChallenges.removeValue(forKey: body.challengeId) != nil else { throw refused("approval_expired", requestId) }
            guard body.spare.credentialId == body.credentialId, body.spare.epoch == epoch, passkeyKeys[body.credentialId] != nil
            else { throw refused("passkey_credential", requestId) }
            guard body.credentialId != body.replaces else { throw refused("spare_unchanged", requestId) }
            do {
                try CloudSecretsCrypto.verify(body.signature, bytes: CloudSecretsProof.spareReplace(sub: Self.sub, by: caller, epoch: epoch,
                    credentialId: body.credentialId, spare: body.spare, replaces: body.replaces), key: device.signPublicJwk)
            } catch { throw refused("spare_signature", requestId) }
            spares = spares.filter { $0.epoch != epoch } + [body.spare]
            spareAdded = (caller, Self.now); spareReplacedBy = (caller, Self.now)
            replaceRequests.append(body)
            result = try CloudSecretsCanonical.encode(["credentialId": body.credentialId, "replaced": body.replaces])
        case "/secrets/spare/open":
            let body = try input(CloudSecretsSpareOpenRequest.self)
            guard computer(caller) else { throw notComputer(requestId) }
            guard let challenge = spareChallenges.removeValue(forKey: body.challengeId), let key = passkeyKeys[body.credentialId],
                  let device = devices[caller], body.expectedVersion == sequence, body.deviceEnvelope.authorDeviceId == caller,
                  body.deviceEnvelope.epoch == epoch, try CloudSecretsCrypto.decode(body.clientDataJSON) == CloudSecretsCrypto.decode(challenge)
            else { throw CloudFailure.invalidRequest }
            // The passkey's assertion over its one-time challenge, with the public key kept at "add".
            try CloudSecretsCrypto.verify(body.signature, bytes: CloudSecretsCrypto.decode(body.authenticatorData) + CloudSecretsCrypto.decode(body.clientDataJSON), key: key)
            try envelopeSignature(body.deviceEnvelope, author: device.signPublicJwk, target: caller)
            envelopes[caller] = body.deviceEnvelope; hashes[caller] = body.canaryHash; version += 1
            result = try CloudSecretsCanonical.encode(CloudSecretsEnvelopeReceipt(epoch: epoch, version: sequence, deviceEnvelope: body.deviceEnvelope))
        case "/secrets/possession": result = try CloudSecretsCanonical.encode(possession(caller, input(CloudPossessionRequest.self)))
        case "/secrets/recovery/challenge": result = try CloudSecretsCanonical.encode(challenge(caller, input(CloudRecoveryChallengeRequest.self)))
        case "/secrets/recovery/complete": result = try CloudSecretsCanonical.encode(recover(caller, input(CloudRecoveryCompleteRequest.self)))
        case "/secrets/rotate":
            let receipt = try rotate(caller, input(CloudSecretsRotateRequest.self))
            var answer = try NativeRPCValue.parseJSON(Data(#"{"epoch":\#(receipt.epoch),"version":"\#(receipt.version.rawValue)","state":"ready","preservedArchiveId":"\#(receipt.preservedArchiveId)","secretsApproved":false}"#.utf8))
            if !lastRefusedCopies.isEmpty {
                answer = .object((answer.fields ?? []) + [.init("refusedCopies", .array(lastRefusedCopies.map {
                    .object([.init("targetDeviceId", .string($0.targetDeviceId)), .init("code", .string($0.code))]) }))])
            }
            result = try answer.encodedJSON()
        case "/devices/confirm-mine":
            // D1: from another of his devices only; clears the flag.
            let raw = try NativeRPCValue.parseJSON(body)
            guard let id = raw["deviceId"].string, devices[id] != nil, id != caller, !signedOutBefore.contains(caller) else {
                throw refused("not_approved", requestId)
            }
            signedOutBefore.remove(id); confirmedMine.append(id)
            result = Data(#"{"ok":true}"#.utf8)
        case "/secrets/reset":
            // Exact bytes of td-cloud-server secrets.ts reset `response`
            // (JSON.stringify field order, version as a decimal string), not
            // the Swift type re-encoded.
            let receipt = try reset(caller, input(CloudSecretsResetRequest.self))
            result = Data(#"{"epoch":\#(receipt.epoch),"version":"\#(receipt.version.rawValue)","state":"ready","preservedArchiveId":"\#(receipt.preservedArchiveId)","secretsApproved":false}"#.utf8)
            lastResetReply = result
        default: throw CloudFailure.invalidRequest
        }
        responses[requestId] = (fingerprint, result)
        if failAt == "afterInitialize", path == "/secrets/initialize" { throw CloudFailure.unavailable }
        // The server applied the acknowledgment but its answer was lost.
        if failAt == "afterPossession", path == "/secrets/possession" { throw CloudFailure.unavailable }
        return result
    }
    func registration(_ id: String) throws -> CloudDeviceRegistration {
        try capture([String: String](), at: "registration")
        if let replacement, replacement.deviceId == id { return replacement }
        guard let device = devices[id] else { throw CloudFailure.invalidRequest }; return device
    }

}
@MainActor
struct CloudSecretsFixtureClient {
    let keys: CloudSecretsFixtureKeys
    let device: CloudDeviceRegistration
    let local = CloudSecretsFixtureLocal()
    let ui = CloudSecretsFixtureUI()
    let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
    let coordinator: CloudRecoveryCoordinator
    let content: CloudSecretsContent
    let control: BackendCloudSecretsControl
    let policy: CloudSecretsPolicy
    init(server: CloudSecretsFixtureServer) async throws {
        keys = .init(); device = try keys.registration(UUID().uuidString.lowercased())
        let caller = device.deviceId
        control = .init(send: { method, path, body, requestId in
            if path == "/secrets/possession" { await server.gatePossession() }
            return try await server.handle(caller: caller, method: method, path: path, body: body, requestId: requestId)
        }, registeredDevice: { try await server.registration($0) }, deviceNames: { try await server.deviceNames() })
        let capabilityGate = gate
        policy = .init(capabilities: { await capabilityGate.value() }, now: { CloudSecretsFixtureServer.now })
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub)
        coordinator = .init(subject: subject, device: device, keys: keys, local: local, control: control,
            words: BackendCloudRecoveryMnemonic(), interaction: ui, policy: policy, resetTicket: { CloudSecretsFixtureServer.resetTicket })
        content = .init(subject: subject, deviceId: device.deviceId, local: local, policy: policy)
        await server.register(device)
    }
}

actor CloudSecretsFixtureJournal {
    var conflicts: [CloudOperation] = []
    func retain(_ operation: CloudOperation) { conflicts.append(operation) }
    var operations: [CloudOperation] = []
    func enqueue(_ rows: [CloudOperation]) throws -> CloudLocalReceipt {
        operations += rows
        return .init(operationIds: rows.map(\.opId), queued: rows.count, bytes: Int64(try CloudSecretsCanonical.encode(rows).count), savedAt: CloudSecretsFixtureServer.now)
    }
}

actor CloudSecretsFixtureOutbox: CloudOutboxPort {
    // The sync core's contract additions (outbox identity, read-back receipts).
    var queueName = "fixture-queue"
    var receipted: Set<String> = []
    func outboxIdentity() -> String { queueName }
    func cloudReceipt(operationId: String) -> CloudOperationReceipt? {
        receipted.contains(operationId) ? .init(operationId: operationId, sequence: CloudSequence(1), committedAt: nil) : nil
    }
    var conflicts: [CloudOperation] = []
    func retain(_ operation: CloudOperation) { conflicts.append(operation) }
    private var pullAction: (@Sendable () async throws -> Void)?
    func onPull(_ action: @escaping @Sendable () async throws -> Void) { pullAction = action }
    var preparations = 0
    func prepareSynchronization() { preparations += 1 }
    var queued: [CloudOperation] = []
    var pulls = 0
    var flushes = 0
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) throws -> CloudLocalReceipt {
        guard files.isEmpty, operations.allSatisfy({ $0.payload.raw["class"].string == "secrets" }) else { throw CloudFailure.invalidRequest }
        queued += operations
        return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: Int64(try CloudSecretsCanonical.encode(operations).count), savedAt: CloudSecretsFixtureServer.now)
    }
    func pull() async throws -> [CloudImportReceipt] { pulls += 1; try await pullAction?(); return [] }
    /// Empty means no segment receipt; read-back record receipts exist only for
    /// what this flush "sent" (everything queued so far).
    func flush() -> [CloudReceipt] { flushes += 1; receipted.formUnion(queued.map(\.opId)); return [] }
    func coverage(sourceId: String) throws -> CloudCoverage { throw CloudFailure.unavailable }
    func restoreProgress() throws -> CloudRestoreProgress { throw CloudFailure.unavailable }
    func contextReady(projectId: String) throws -> CloudContextReady { throw CloudFailure.unavailable }
    func register(adapter: any CloudDomainAdapter) throws { throw CloudFailure.unavailable }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func setPaused(_ paused: Bool) throws { throw CloudFailure.unavailable }
}

/// An outbox that cannot state the sync core's send limit or queue identity.
actor CloudSecretsFixturePlainOutbox: CloudOutboxPort {
    var queued: [CloudOperation] = []
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) throws -> CloudLocalReceipt {
        queued += operations
        return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: 0, savedAt: CloudSecretsFixtureServer.now)
    }
    func pull() -> [CloudImportReceipt] { [] }
    func flush() -> [CloudReceipt] { [] }
    func coverage(sourceId: String) throws -> CloudCoverage { throw CloudFailure.unavailable }
    func restoreProgress() throws -> CloudRestoreProgress { throw CloudFailure.unavailable }
    func contextReady(projectId: String) throws -> CloudContextReady { throw CloudFailure.unavailable }
    func register(adapter: any CloudDomainAdapter) throws { throw CloudFailure.unavailable }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func setPaused(_ paused: Bool) throws { throw CloudFailure.unavailable }
}
