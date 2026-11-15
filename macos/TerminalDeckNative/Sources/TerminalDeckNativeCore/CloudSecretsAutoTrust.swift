import Foundation
import CryptoKit

/// The automatic hand-over's questions, answered by the app (owner's decision, 14 Nov; review of 6e8f1d50).
/// Everything here is THIS Mac's own knowledge, never the service's word at that moment.
public struct CloudSecretsAutoTrust: Sendable {
    /// A device on this Mac's own trusted-device list: the name and signing key stored when it was trusted.
    public struct Pinned: Sendable, Equatable {
        public let name: String
        public let signKey: CloudPublicJWK
        /// The kind of device as THIS Mac recorded it with the key (review blocker 1). nil = not recorded (an entry
        /// from before this was kept): then it is not taken for a computer.
        public let platform: CloudPlatform?
        public init(name: String, signKey: CloudPublicJWK, platform: CloudPlatform? = nil) {
            self.name = name; self.signKey = signKey; self.platform = platform
        }
        /// Review blocker 1: only a computer (a Mac or a Windows PC) is ever answered by itself or offered the click
        /// without a code. Phones and browsers do not use saved passwords.
        public var isComputer: Bool { CloudSecretsAutoTrust.isComputer(platform) }
        /// 15 Nov (owner: "every single thing in cloud ... and in everywhere"): one of his own signed-in phones, by the kind
        /// THIS Mac recorded with the key. A browser is neither (its way in is his passkey, later).
        public var isPhone: Bool { CloudSecretsAutoTrust.isPhone(platform) }
        /// 15 Nov (passwords in the browser): his own signed-in browser (the web app's key box), by the kind THIS Mac
        /// recorded with the key. Answered like a phone, but its own kind: never taken for a phone or a computer.
        public var isBrowser: Bool { CloudSecretsAutoTrust.isBrowser(platform) }
    }
    public static func isComputer(_ platform: CloudPlatform?) -> Bool { platform == .macos || platform == .windows }
    /// An iPhone or an Android phone. Phones hold the key since 15 Nov unless his setting keeps it off them.
    public static func isPhone(_ platform: CloudPlatform?) -> Bool { platform == .ios || platform == .android }
    /// A browser sign-in of his account (platform web). Holds the key unless his one switch keeps it off his phones
    /// and browsers. Inert until the service lets a browser ask (today it refuses every browser).
    public static func isBrowser(_ platform: CloudPlatform?) -> Bool { platform == .web }
    /// The three kinds that may ever hold the key. nil = unknown or not recorded: never answered, never offered.
    public enum Kind: Sendable, Equatable { case computer, phone, browser }
    public static func kind(_ platform: CloudPlatform?) -> Kind? {
        if isComputer(platform) { return .computer }
        if isPhone(platform) { return .phone }
        if isBrowser(platform) { return .browser }
        return nil
    }
    /// The kind THIS Mac recorded and the kind the account lists now are the same known kind (a pinned phone never
    /// passes as a browser or a Mac, nor the reverse). An iPhone and an Android phone are the same kind, as before.
    public static func sameKind(_ recorded: CloudPlatform?, _ listed: CloudPlatform?) -> Bool {
        guard let a = kind(recorded), let b = kind(listed) else { return false }
        return a == b
    }
    /// The automatic hand-over is allowed on this Mac at all (the app: always; a fixture can switch it off). The
    /// owner's stricter setting ("Ask me on each new device") is NOT this: the coordinator reads that from
    /// the hand-over book beside the key (`CloudSecretsHandOverBookPort`), so deleting a file cannot switch it off.
    public let on: @Sendable () async -> Bool
    /// The trusted entry for a device id; nil when unknown, stopped, or the list cannot be read.
    public let pinned: @Sendable (String) async -> Pinned?
    /// Review point 3: one automatic answer per device per key generation; later requests wait for a person. The
    /// coordinator's own record is the hand-over book beside the key (written BEFORE the answer goes out); these two
    /// are an extra record a caller may keep (fixtures). `remember` failing stops the answer.
    public let answeredBefore: @Sendable (_ deviceId: String, _ epoch: Int) async -> Bool
    public let remember: @Sendable (_ deviceId: String, _ epoch: Int) async throws -> Void
    public init(on: @escaping @Sendable () async -> Bool, pinned: @escaping @Sendable (String) async -> Pinned?,
                answeredBefore: @escaping @Sendable (String, Int) async -> Bool = { _, _ in false },
                remember: @escaping @Sendable (String, Int) async throws -> Void = { _, _ in }) {
        self.on = on; self.pinned = pinned; self.answeredBefore = answeredBefore; self.remember = remember
    }
}

/// What THIS Mac keeps about the automatic hand-over, in its own small Keychain item BESIDE the saved-passwords key
/// (review conditions a and the stricter setting): deleting a file cannot reset it. Unreadable = "answered" and
/// "ask" (fails safe: a person decides).
public struct CloudSecretsHandOverBook: Codable, Equatable, Sendable {
    /// "deviceId@epoch" for every device this Mac answered BY ITSELF, per key generation.
    public var answered: [String]
    /// The owner's stricter setting as this Mac last knew it ("Ask for my passkey on each new device"). Off by default.
    public var askOnNewDevice: Bool
    /// When that setting was last changed (milliseconds, the changing device's clock); a relayed change is taken only
    /// when newer, so an older one replayed by the service never switches it back.
    public var policyAt: Int64
    /// Earlier builds: key generations for which the passkey sheet had been shown. No longer read (it was written BEFORE
    /// the sheet, so a failed or cancelled first sheet spent the offer); kept only so older books still decode.
    public var spareOffered: [Int]?
    /// Key generations for which the service ANSWERED this Mac's "add the spare" (or already had one): never offered again.
    public var spareAdded: [Int]?
    /// When he last cancelled the passkey sheet that offered itself (this Mac's clock): it does not offer itself again for
    /// a day. His own press on "Make a passkey spare key" is never held back by it.
    public var spareCancelledAt: Int64?
    /// PASSWORDS-5 point 4: the key generation for which a passkey was made on THIS Mac after that generation's spare
    /// already existed (the service refused the add while a spare was on file). The system's new passkey for the same
    /// site and account replaces the one the spare was sealed for, so the spare may no longer open: said on the page.
    public var spareOrphaned: Int?
    /// 15 Nov: his stricter setting "Keep saved passwords and secret files off my phones" (nil and false = off, the
    /// default: his own signed-in phones get the key by themselves and the sealed shelf carries his passwords for them).
    public var phonesOff: Bool?
    /// When that setting was last changed (milliseconds, the changing device's clock); a relayed ON is taken only when newer.
    public var phonesOffAt: Int64?
    /// Review 15 Nov (finding 2): "deviceId" -> "<hash of its signing key>|<hash of its wrapping key>" for every device
    /// whose OWN signature over that wrapping key THIS Mac checked (its signed request, with the signing key pinned
    /// here), or whose key he confirmed with the matching code. A key change seals a copy only to a wrapping key found
    /// here, so a service that swaps a device's wrapping key never receives the new key. At most 256 entries.
    public var verifiedWrapKeys: [String: String]?
    public init(answered: [String] = [], askOnNewDevice: Bool = false, policyAt: Int64 = 0, spareOffered: [Int]? = nil,
                spareAdded: [Int]? = nil, spareCancelledAt: Int64? = nil, spareOrphaned: Int? = nil,
                phonesOff: Bool? = nil, phonesOffAt: Int64? = nil) {
        self.answered = answered; self.askOnNewDevice = askOnNewDevice; self.policyAt = policyAt; self.spareOffered = spareOffered
        self.spareAdded = spareAdded; self.spareCancelledAt = spareCancelledAt; self.spareOrphaned = spareOrphaned
        self.phonesOff = phonesOff; self.phonesOffAt = phonesOffAt
    }
    public static func key(_ deviceId: String, _ epoch: Int) -> String { deviceId.lowercased() + "@" + String(epoch) }
    public func hasAnswered(_ deviceId: String, epoch: Int) -> Bool { answered.contains(Self.key(deviceId, epoch)) }
    public static func wrapKeyMark(_ device: CloudDeviceRegistration) throws -> String {
        CloudSecretsCrypto.hash(try CloudSecretsCanonical.encode(device.signPublicJwk)) + "|"
            + CloudSecretsCrypto.hash(try CloudSecretsCanonical.encode(device.wrapPublicJwk))
    }
    /// The device's signature over exactly this wrapping key was checked here (see `verifiedWrapKeys`).
    public func wrapKeyVerified(_ device: CloudDeviceRegistration) -> Bool {
        guard let mark = try? Self.wrapKeyMark(device) else { return false }
        return verifiedWrapKeys?[device.deviceId.lowercased()] == mark
    }
    public mutating func noteWrapKeyVerified(_ device: CloudDeviceRegistration) {
        guard let mark = try? Self.wrapKeyMark(device) else { return }
        var kept = verifiedWrapKeys ?? [:]
        kept[device.deviceId.lowercased()] = mark
        if kept.count > 256 { kept = kept.filter { $0.key == device.deviceId.lowercased() } }
        verifiedWrapKeys = kept
    }
}

/// The hand-over book's place: a local key store that can keep it beside the key. A store that does not conform
/// keeps nothing, so nothing is ever answered by itself and the stricter setting reads "ask".
public protocol CloudSecretsHandOverBookPort: Sendable {
    /// nil = never written (a new account on this Mac: nothing answered, the setting off). Throws when unreadable.
    func handOverBook() async throws -> CloudSecretsHandOverBook?
    func saveHandOverBook(_ book: CloudSecretsHandOverBook) async throws
}

/// The owner's stricter setting, signed by the device that changed it (its device signing key), so every one of his
/// Macs checks it against the signing key IT pinned for that device: the service can carry it but never forge it.
public struct CloudSecretsAskPolicy: Codable, Equatable, Sendable {
    public let askOnNewDevice: Bool
    public let at: Int64
    public let by: String
    public let signature: String
    public init(askOnNewDevice: Bool, at: Int64, by: String, signature: String) {
        self.askOnNewDevice = askOnNewDevice; self.at = at; self.by = by; self.signature = signature
    }
}

/// How the stricter setting follows him to his other devices: `POST /secrets/policy` and an optional `askPolicy`
/// in `/secrets/status` (service follow-up, see the seat note). A control port that does not conform, or a service
/// that does not know the route, keeps the setting on this Mac only.
public protocol CloudSecretsPolicyRelayPort: Sendable {
    func publishPolicy(requestId: String, policy: CloudSecretsAskPolicy) async throws
    func publishedPolicy() async throws -> CloudSecretsAskPolicy?
}

/// 15 Nov: "Keep saved passwords and secret files off my phones", signed by the Mac where he switched it (its device
/// signing key, purpose TD-PASSWORDS-PHONES-1), so every one of his Macs checks it with the key IT pinned for that Mac.
/// Like the ask setting, a relayed record can only switch it ON on another device; OFF is his press on each device.
public struct CloudSecretsPhonesPolicy: Codable, Equatable, Sendable {
    public let phonesOff: Bool
    public let at: Int64
    public let by: String
    public let signature: String
    public init(phonesOff: Bool, at: Int64, by: String, signature: String) {
        self.phonesOff = phonesOff; self.at = at; self.by = by; self.signature = signature
    }
}
/// How the phones setting follows him to his other Macs: `POST /secrets/policy/phones {requestId, phonesPolicy}` and the
/// optional `phonesPolicy` of `/secrets/status` (Servers contract in the seat note). A control port that does not conform,
/// or a service without the route, keeps the setting on this Mac only.
public protocol CloudSecretsPhonesPolicyRelayPort: Sendable {
    func publishPhonesPolicy(requestId: String, policy: CloudSecretsPhonesPolicy) async throws
    func publishedPhonesPolicy() async throws -> CloudSecretsPhonesPolicy?
}

/// The optional facts the service (lane/cloud-secrets-policy 72959fbbd, 7ff81baac) adds to `/secrets/status`, read from
/// the SAME answer as the status itself. Today's live service sends none of them: every field is then nil and each
/// caller does exactly what it did before. None of them is signed: they are for display and for the dead-state test
/// only, and never change a setting of this Mac.
public struct CloudSecretsStatusFacts: Sendable, Equatable {
    /// Who did something and when, as the service's own record says (`by` a device id, `byName` its name there,
    /// `at` the service's clock in milliseconds). Display only.
    public struct Change: Sendable, Equatable {
        public let by: String
        public let byName: String
        public let at: Int64
        public init(by: String, byName: String, at: Int64) { self.by = by; self.byName = byName; self.at = at }
    }
    /// `askPolicy`: the stricter setting while it is ON, as the changing device signed it.
    public let askPolicy: CloudSecretsAskPolicy?
    /// `askPolicyTurnedOff {by, byName, changedAt}`: he switched it off on that device. Unsigned: shown, never adopted.
    public let turnedOff: Change?
    /// `nobodyCanOpen`: no active device holds a key copy of this generation (approved or not yet confirmed). nil =
    /// a service that does not send it yet.
    public let nobodyCanOpen: Bool?
    /// `spare {addedBy, addedByName, addedAt}`: who made this generation's passkey spare key, from the service's own row
    /// (never the name inside the sealed copy).
    public let spare: Change?
    /// PASSWORDS-5 point 5: `spare.credentialId`, the passkey this generation's spare is sealed for. Today's service does
    /// not send it (asked of the Servers seat); the spare challenge's `spares[]` carries it meanwhile.
    public let spareCredentialId: String?
    /// `spare {replacedBy, replacedByName, replacedAt}` (service 7750c816e): the last replace of this generation's spare.
    public let spareReplaced: Change?
    public init(askPolicy: CloudSecretsAskPolicy? = nil, turnedOff: Change? = nil, nobodyCanOpen: Bool? = nil, spare: Change? = nil,
                spareCredentialId: String? = nil, spareReplaced: Change? = nil) {
        self.askPolicy = askPolicy; self.turnedOff = turnedOff; self.nobodyCanOpen = nobodyCanOpen; self.spare = spare
        self.spareCredentialId = spareCredentialId; self.spareReplaced = spareReplaced
    }
    /// The service always sends `nobodyCanOpen` from 72959fbbd on: its presence tells the new service from today's.
    public var newService: Bool { nobodyCanOpen != nil }
}
/// One `/secrets/status` read giving both the status and its optional facts. A control port that does not conform
/// (fixtures, older wiring) behaves exactly as before.
public protocol CloudSecretsStatusFactsPort: Sendable {
    func statusFacts() async throws -> (status: CloudSecretsStatus, facts: CloudSecretsStatusFacts)
}

/// What the adding device signs with its own device signing key for `POST /secrets/spare/add` (service 7ff81baac:
/// `TD-PASSWORDS-SPARE-1` over {sub, by, epoch, credentialId, spareHash}, spareHash = SHA-256 hex of the canonical
/// spare exactly as sent), so a sign-in alone can never put a spare of its own in the one place per generation.
public extension CloudSecretsProof {
    static func spare(sub: String, by: String, epoch: Int, credentialId: String, spare: CloudSecretsSpare) throws -> Data {
        struct Body: Encodable { let purpose: String; let sub: String; let by: String; let epoch: Int; let credentialId: String; let spareHash: String }
        return try CloudSecretsCanonical.encode(Body(purpose: "TD-PASSWORDS-SPARE-1", sub: sub, by: by, epoch: epoch, credentialId: credentialId,
            spareHash: CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(spare))))
    }
    /// PASSWORDS-5 repair (service 7750c816e `spareReplaceMessage`): the same fields as the add plus the credential id of
    /// the spare it replaces, under its own purpose (an add's signature can never be replayed as a replace).
    static func spareReplace(sub: String, by: String, epoch: Int, credentialId: String, spare: CloudSecretsSpare, replaces: String) throws -> Data {
        struct Body: Encodable {
            let purpose: String; let sub: String; let by: String; let epoch: Int; let credentialId: String; let spareHash: String; let replaces: String
        }
        return try CloudSecretsCanonical.encode(Body(purpose: "TD-PASSWORDS-SPARE-REPLACE-1", sub: sub, by: by, epoch: epoch, credentialId: credentialId,
            spareHash: CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(spare)), replaces: replaces))
    }
}

/// The seam for the new device's signed request (review point 2). The service must keep the signature with the
/// approval and hand it back unchanged in `pendingApprovals` (notes/cloud-everything-20261114/PASSWORDS-SERVICE-CHANGE.md).
/// A control port that does not conform has no signed requests, so nothing is ever answered by itself.
public protocol CloudSecretsRequestSigningPort: Sendable {
    /// `POST /secrets/approval/sign {requestId, approvalId, signature}` by the requesting device itself.
    func signRequest(requestId: String, approvalId: String, signature: String) async throws
    /// approvalId -> the requesting device's signature, as the service returns it. Empty when none.
    func requestSignatures() async throws -> [String: String]
}

public extension CloudSecretsProof {
    /// What the requesting device signs with its own device signing key: the account, the approval, both of its
    /// keys (the wrapping key by its own hash) and the key generation. The answering Mac verifies it against the
    /// signing key IT pinned for that device, so a wrapping key swapped in by the service never matches.
    static func request(sub: String, approval: CloudApproval, wrapPublicJwk: CloudPublicJWK, epoch: Int) throws -> Data {
        struct Body: Encodable {
            let purpose: String; let sub: String; let approvalId: String; let challenge: String; let targetDeviceId: String
            let targetKeyHash: String; let wrapKeyHash: String; let epoch: Int; let expiresAt: Int64
        }
        return try CloudSecretsCanonical.encode(Body(purpose: "TD-APPROVAL-REQUEST-1", sub: sub, approvalId: approval.approvalId,
            challenge: approval.challenge, targetDeviceId: approval.targetDeviceId, targetKeyHash: approval.targetKeyHash,
            wrapKeyHash: CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(wrapPublicJwk)), epoch: epoch, expiresAt: approval.expiresAt))
    }
    /// What the changing Mac signs for the phones setting (15 Nov).
    static func phonesPolicy(sub: String, phonesOff: Bool, at: Int64, by: String) throws -> Data {
        struct Body: Encodable { let purpose: String; let sub: String; let phonesOff: Bool; let at: Int64; let by: String }
        return try CloudSecretsCanonical.encode(Body(purpose: "TD-PASSWORDS-PHONES-1", sub: sub, phonesOff: phonesOff, at: at, by: by))
    }
    /// What the changing device signs for the stricter setting.
    static func askPolicy(sub: String, askOnNewDevice: Bool, at: Int64, by: String) throws -> Data {
        struct Body: Encodable { let purpose: String; let sub: String; let askOnNewDevice: Bool; let at: Int64; let by: String }
        return try CloudSecretsCanonical.encode(Body(purpose: "TD-PASSWORDS-POLICY-1", sub: sub, askOnNewDevice: askOnNewDevice, at: at, by: by))
    }
}

/// A silent set-up has no recovery words. The service still requires a recovery copy, so it gets a PLACEHOLDER:
/// 1024 random bytes sealed under a key that is thrown away at once. It never contains the saved-passwords key, and
/// its size tells every device "this account has no recovery words" (a service that changes it only changes whether
/// "Use recovery words" is shown).
public extension CloudRecoveryKeys {
    func sealPlaceholder(sub: String, version: CloudSequence, epoch: Int) throws -> CloudRecoveryEnvelope {
        guard epoch > 0, version > .zero else { throw CloudFailure.invalidRequest }
        let throwaway = try CloudSecretsCrypto.random(32)
        let box = try CloudSecretsCrypto.seal(CloudSecretsCrypto.random(CloudRecoveryEnvelope.placeholderBytes),
            key: throwaway, aad: Data("TD-CLOUD-RECOVERY-NONE-1\n\(sub)\n\(version.rawValue)\n\(epoch)".utf8), nonce: CloudSecretsCrypto.random(12))
        return .init(v: 1, version: version, epoch: epoch, suite: "A256GCM", nonce: box.nonce,
                     ciphertext: box.ciphertext, tag: box.tag, publicSigningJwk: publicKey)
    }
}

public extension CloudRecoveryEnvelope {
    static let placeholderBytes = 1024
    /// A real recovery copy holds a few dozen bytes; the placeholder holds 1024.
    var isPlaceholder: Bool { ((try? CloudSecretsCrypto.decode(ciphertext))?.count ?? 0) >= 512 }
}
