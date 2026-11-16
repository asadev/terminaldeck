import Foundation
import CryptoKit

// PASSWORDS-2 slice 2 (owner, 13-14 Nov): "no recovery words ... a PASSKEY is the spare key". Design:
// notes/cloud-everything-20261114/PASSKEY-SPARE-KEY.md. The passkey's WebAuthn PRF output (32 bytes only his
// authenticator can produce, after Touch ID / Face ID) wraps a copy of the saved-passwords key. The service stores
// that wrapped copy and the passkey's public key; it can never open the copy (the PRF bytes never leave his device,
// and a WebAuthn assertion does not carry them).

/// One spare: the saved-passwords key of one generation, sealed under a key derived from a passkey's PRF output.
public struct CloudSecretsSpare: Codable, Equatable, Sendable {
    public let v: Int
    /// "passkey" (an older account's words copy stays the separate recovery copy).
    public let kind: String
    /// The passkey's credential id (base64url), so a device asks for exactly that passkey.
    public let credentialId: String
    public let epoch: Int
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    public let createdAt: Int64
    /// The device it was made on, as that device wrote it. Never shown and never an input to trust: the page names
    /// the maker from the service's own record (`CloudSecretsStatusFacts.spare`).
    public let deviceName: String
    public init(v: Int, kind: String, credentialId: String, epoch: Int, nonce: String, ciphertext: String, tag: String,
                createdAt: Int64, deviceName: String) {
        self.v = v; self.kind = kind; self.credentialId = credentialId; self.epoch = epoch; self.nonce = nonce
        self.ciphertext = ciphertext; self.tag = tag; self.createdAt = createdAt; self.deviceName = deviceName
    }
}

public enum CloudSecretsSpareCrypto {
    /// The fixed PRF input for this account (the same every time, so the passkey always gives the same 32 bytes).
    public static func prfSalt(sub: String) -> Data { Data(SHA256.hash(data: Data(("TD-SPARE-1\n" + sub).utf8))) }
    static func wrapKey(prf: Data, sub: String, credentialId: String) throws -> Data {
        guard prf.count == 32 else { throw CloudFailure.invalidRequest }
        return CloudSecretsCrypto.derive(prf, salt: Data("TD-SPARE-WRAP-1".utf8), info: "TD-SPARE-WRAP-1|\(sub)|\(credentialId)")
    }
    static func aad(sub: String, credentialId: String, epoch: Int) -> Data {
        Data("TD-SPARE-1\n\(sub)\n\(credentialId)\n\(epoch)".utf8)
    }
    /// Seals `root` (32 bytes) for one passkey and one key generation.
    public static func seal(root: Data, prf: Data, sub: String, credentialId: String, epoch: Int, createdAt: Int64,
                            deviceName: String) throws -> CloudSecretsSpare {
        guard root.count == 32, epoch > 0, !credentialId.isEmpty else { throw CloudFailure.invalidRequest }
        var key = try wrapKey(prf: prf, sub: sub, credentialId: credentialId)
        defer { key.resetBytes(in: 0..<key.count) }
        let box = try CloudSecretsCrypto.seal(root, key: key, aad: aad(sub: sub, credentialId: credentialId, epoch: epoch),
                                              nonce: CloudSecretsCrypto.random(12))
        return .init(v: 1, kind: "passkey", credentialId: credentialId, epoch: epoch, nonce: box.nonce, ciphertext: box.ciphertext,
                     tag: box.tag, createdAt: createdAt, deviceName: String(deviceName.prefix(80)))
    }
    /// Opens a spare with the PRF output of its own passkey. Any other passkey, account or generation fails.
    public static func open(_ spare: CloudSecretsSpare, prf: Data, sub: String) throws -> Data {
        guard spare.v == 1, spare.kind == "passkey", spare.epoch > 0 else { throw CloudFailure.unsupportedFormat }
        var key = try wrapKey(prf: prf, sub: sub, credentialId: spare.credentialId)
        defer { key.resetBytes(in: 0..<key.count) }
        let root = try CloudSecretsCrypto.open(nonce: spare.nonce, ciphertext: spare.ciphertext, tag: spare.tag, key: key,
                                               aad: aad(sub: sub, credentialId: spare.credentialId, epoch: spare.epoch))
        guard root.count == 32 else { throw CloudFailure.checksumMismatch }
        return root
    }
}

/// The platform's passkey with the WebAuthn PRF extension (the app: AuthenticationServices, macOS 15+; tests: a
/// fixture). Every call shows only the system's own sheet (Touch ID / Face ID).
public protocol CloudSecretsPasskeyPort: Sendable {
    /// Whether this Mac can make and use such a passkey at all (the system, the app's associated domain).
    func available() async -> Bool
    /// Makes the passkey and returns its id, the registration the service verifies, and the PRF output for `salt`.
    /// Throws `CloudFailure.unsupportedFormat` when the passkey gives no PRF (it is then never used).
    /// PASSWORDS-5 point 5: `excluded` are the credential ids of spares already on file; the system itself then refuses
    /// to make a second passkey on a device that holds one of them (ASAuthorizationError 1006), so it cannot silently
    /// replace the spare's passkey.
    func create(challenge: Data, userId: Data, userName: String, salt: Data, excluded: [Data]) async throws -> CloudSecretsPasskeyCreated
    /// Uses one of the given passkeys: the assertion the service verifies, and the PRF output for `salt`.
    func use(challenge: Data, allowed: [Data], salt: Data) async throws -> CloudSecretsPasskeyUsed
    /// PASSWORDS-5 point 1: withdraws this app's own open passkey sheet (the system's cancel). The waiting call then
    /// throws `CancellationError`. Nothing open: nothing happens.
    func cancel() async
}
extension CloudSecretsPasskeyPort {
    public func cancel() async {}
}
public struct CloudSecretsPasskeyCreated: Sendable {
    public let credentialId: Data
    public let attestationObject: Data
    public let clientDataJSON: Data
    public let prf: Data
    public init(credentialId: Data, attestationObject: Data, clientDataJSON: Data, prf: Data) {
        self.credentialId = credentialId; self.attestationObject = attestationObject; self.clientDataJSON = clientDataJSON; self.prf = prf
    }
}
public struct CloudSecretsPasskeyUsed: Sendable {
    public let credentialId: Data
    public let authenticatorData: Data
    public let clientDataJSON: Data
    public let signature: Data
    public let prf: Data
    public init(credentialId: Data, authenticatorData: Data, clientDataJSON: Data, signature: Data, prf: Data) {
        self.credentialId = credentialId; self.authenticatorData = authenticatorData; self.clientDataJSON = clientDataJSON
        self.signature = signature; self.prf = prf
    }
}

/// What the service hands out for the spare key (service b51a46424): a one-time WebAuthn challenge, this generation's
/// spare (at most ONE: one spare per key generation) and the user handle its passkeys are made for. Each call is a
/// receipt row on the service, so one challenge is asked once and reused.
public struct CloudSecretsSpareChallenge: Codable, Equatable, Sendable {
    public let challengeId: String
    public let challenge: String
    public let userId: String
    public let expiresAt: Int64
    public let spares: [CloudSecretsSpare]
    public init(challengeId: String, challenge: String, userId: String, expiresAt: Int64, spares: [CloudSecretsSpare]) {
        self.challengeId = challengeId; self.challenge = challenge; self.userId = userId; self.expiresAt = expiresAt; self.spares = spares
    }
}
/// `POST /secrets/spare/add`: the registration (the service verifies it and keeps the passkey's public key) and the
/// sealed copy. Only an approved computer holding the current key can add one, and only with `signature`: this device's
/// own signing key over `CloudSecretsProof.spare` (service 7ff81baac; extra fields are refused there).
public struct CloudSecretsSpareAddRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let challengeId: String
    public let credentialId: String
    public let attestationObject: String
    public let clientDataJSON: String
    public let spare: CloudSecretsSpare
    public let signature: String
}
/// `POST /secrets/spare/open`: the assertion (the service verifies it with the passkey's stored public key, over its
/// one-time challenge) and this device's own envelope, sealed and signed by itself (as at set-up). The service then
/// keeps the envelope; possession follows exactly as after an approval.
public struct CloudSecretsSpareOpenRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let challengeId: String
    public let credentialId: String
    public let authenticatorData: String
    public let clientDataJSON: String
    public let signature: String
    public let expectedVersion: CloudSequence
    public let deviceEnvelope: CloudDeviceKeyEnvelope
    public let canaryHash: String
}
/// `POST /secrets/spare/replace` (service 7750c816e): as the add, plus `replaces` (the stored spare's credential id).
public struct CloudSecretsSpareReplaceRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let challengeId: String
    public let credentialId: String
    public let attestationObject: String
    public let clientDataJSON: String
    public let spare: CloudSecretsSpare
    public let signature: String
    public let replaces: String
}
/// The system refused to make the passkey because one of the excluded passkeys is on this device (ASAuthorizationError
/// 1006): the spare sealed for it still opens.
public struct CloudSecretsPasskeyExcluded: Error, Sendable, Equatable { public init() {} }
/// The replace route. A control port that does not conform cannot repair a spare (the page then shows no control).
public protocol CloudSecretsSpareReplacePort: Sendable {
    /// Returns the replaced credential id the service answered (`replaced`).
    func replaceSpare(_ request: CloudSecretsSpareReplaceRequest) async throws -> String
}
public protocol CloudSecretsSparePort: Sendable {
    func spareChallenge(requestId: String) async throws -> CloudSecretsSpareChallenge
    func addSpare(_ request: CloudSecretsSpareAddRequest) async throws
    func openWithSpare(_ request: CloudSecretsSpareOpenRequest) async throws -> CloudSecretsEnvelopeReceipt
}

/// PASSWORDS-5 point 6: the ONE source of device names in the saved-passwords log and page: the account's own device
/// list, by its friendly name ("Studio Mac mini", as the device told the service; the recorded label only when the
/// service has none). `holdsKey`: the list says the device is active and approved for saved passwords. Display only,
/// never an input to trust (trust stays with the signing keys pinned here).
public struct CloudSecretsDeviceName: Sendable, Equatable {
    public let deviceId: String
    public let name: String
    public let holdsKey: Bool
    /// D1 (lost-device review, 15 Nov): the account marks this row as a new sign-in on a machine another of his
    /// devices signed out (`signedOutBefore`). Its key then waits for his "Yes, it's mine".
    public let signedOutBefore: Bool
    public init(deviceId: String, name: String, holdsKey: Bool, signedOutBefore: Bool = false) {
        self.deviceId = deviceId; self.name = name; self.holdsKey = holdsKey; self.signedOutBefore = signedOutBefore
    }
}
public protocol CloudSecretsDeviceNamesPort: Sendable {
    func deviceNames() async throws -> [CloudSecretsDeviceName]
}
