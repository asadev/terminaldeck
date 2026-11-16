import Foundation
import CryptoKit
import Security

/// Cryptographic bytes stay inside native ports. Nothing here is an RPC result.
public enum CloudSecretsCrypto {
    public static func random(_ count: Int) throws -> Data {
        guard count > 0, count <= 4096 else { throw CloudFailure.invalidRequest }
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CloudFailure.unavailable }
        return bytes
    }
    public static func encode(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ text: String, count: Int? = nil) throws -> Data {
        guard text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              text.count % 4 != 1 else { throw CloudFailure.invalidRequest }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), encode(bytes) == text,
              count == nil || bytes.count == count else { throw CloudFailure.invalidRequest }
        return bytes
    }
    public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func uuidBytes(_ text: String) throws -> Data {
        guard let uuid = UUID(uuidString: text) else { throw CloudFailure.invalidRequest }
        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) { Data($0) }
    }
    public static func derive(_ input: Data, salt: Data, info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input), salt: salt,
                              info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    static func validateSubject(_ sub: String) throws { _ = try uuidBytes(sub) }
    public static func publicJWK(_ x963: Data) throws -> CloudPublicJWK {
        guard x963.count == 65, x963.first == 4 else { throw CloudFailure.invalidRequest }
        return .init(kty: "EC", crv: "P-256", x: encode(x963.subdata(in: 1..<33)), y: encode(x963.subdata(in: 33..<65)))
    }
    public static func x963(_ jwk: CloudPublicJWK) throws -> Data {
        guard jwk.kty == "EC", jwk.crv == "P-256", let y = jwk.y else { throw CloudFailure.invalidRequest }
        return try Data([4]) + decode(jwk.x, count: 32) + decode(y, count: 32)
    }
    public static func keyHash(_ device: CloudDeviceRegistration) throws -> String {
        struct Keys: Encodable { let signPublicJwk: CloudPublicJWK; let wrapPublicJwk: CloudPublicJWK }
        _ = try P256.Signing.PublicKey(x963Representation: x963(device.signPublicJwk))
        _ = try P256.KeyAgreement.PublicKey(x963Representation: x963(device.wrapPublicJwk))
        return try hash(CloudSecretsCanonical.encode(Keys(signPublicJwk: device.signPublicJwk, wrapPublicJwk: device.wrapPublicJwk)))
    }
    public static func verify(_ signature: String, bytes: Data, key: CloudPublicJWK) throws {
        let raw = try decode(signature, count: 64)
        if key.kty == "OKP", key.crv == "Ed25519", key.y == nil {
            guard try Curve25519.Signing.PublicKey(rawRepresentation: decode(key.x, count: 32)).isValidSignature(raw, for: bytes)
            else { throw CloudFailure.checksumMismatch }
        } else {
            let publicKey = try P256.Signing.PublicKey(x963Representation: x963(key))
            guard try publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: bytes)
            else { throw CloudFailure.checksumMismatch }
        }
    }
    struct Sealed { let nonce: String; let ciphertext: String; let tag: String }
    static func seal(_ plain: Data, key: Data, aad: Data, nonce: Data) throws -> Sealed {
        guard key.count == 32, nonce.count == 12 else { throw CloudFailure.invalidRequest }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return .init(nonce: encode(nonce), ciphertext: encode(box.ciphertext), tag: encode(box.tag))
    }
    static func open(nonce: String, ciphertext: String, tag: String, key: Data, aad: Data) throws -> Data {
        guard key.count == 32 else { throw CloudFailure.invalidRequest }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: decode(nonce, count: 12)), ciphertext: decode(ciphertext), tag: decode(tag, count: 16))
        do { return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad) }
        catch { throw CloudFailure.checksumMismatch }
    }
    static func contentAAD(_ envelope: CloudContentEnvelope, sub: String) throws -> Data {
        let raw = try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope))
            .removing("nonce").removing("ciphertext").removing("tag")
        return try Data("TD-CLOUD-CONTENT-1\n\(sub)\n".utf8) + CloudSecretsCanonical.encode(CloudValue(raw))
    }
    public static func sealContent(_ bytes: Data, root: Data, sub: String, blobId: String,
                                   purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec = .identity) throws -> CloudContentEnvelope {
        try sealContent(bytes, root: root, sub: sub, blobId: blobId, purpose: purpose, epoch: epoch, codec: codec, nonce: random(12))
    }
    static func sealContent(_ bytes: Data, root: Data, sub: String, blobId: String,
                            purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec = .identity, nonce: Data) throws -> CloudContentEnvelope {
        try validateSubject(sub)
        guard root.count == 32, epoch > 0, purpose.permits(.secrets), bytes.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.invalidRequest }
        let header = CloudContentEnvelope(v: 1, suite: "A256GCM-HKDF-SHA256", storageClass: .secrets,
            purpose: purpose, epoch: epoch, blobId: blobId, codec: codec, plainBytes: Int64(bytes.count), nonce: "", ciphertext: "", tag: "")
        let key = try derive(root, salt: uuidBytes(blobId), info: "TD-CLOUD-OBJECT-1\nsecrets\n\(epoch)")
        let box = try seal(CloudSecretsCompression.encode(bytes, codec: codec), key: key, aad: contentAAD(header, sub: sub), nonce: nonce)
        return .init(v: 1, suite: header.suite, storageClass: .secrets, purpose: purpose, epoch: epoch,
                     blobId: blobId, codec: codec, plainBytes: Int64(bytes.count), nonce: box.nonce, ciphertext: box.ciphertext, tag: box.tag)
    }
    public static func openContent(_ envelope: CloudContentEnvelope, root: Data, sub: String, epoch: Int) throws -> Data {
        try validateSubject(sub)
        guard envelope.v == 1, envelope.suite == "A256GCM-HKDF-SHA256", envelope.storageClass == .secrets,
              envelope.purpose.permits(.secrets), envelope.epoch == epoch, epoch > 0, root.count == 32,
              (0...Int64(CloudWire.maximumPlainChunkBytes)).contains(envelope.plainBytes),
              envelope.ciphertext.utf8.count <= CloudWire.maximumBlobBytes else { throw CloudFailure.unsupportedFormat }
        let key = try derive(root, salt: uuidBytes(envelope.blobId), info: "TD-CLOUD-OBJECT-1\nsecrets\n\(epoch)")
        let bytes = try open(nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: envelope.tag, key: key, aad: contentAAD(envelope, sub: sub))
        return try CloudSecretsCompression.decode(bytes, codec: envelope.codec, expected: envelope.plainBytes)
    }
    /// A second, independently displayed code binds the delivered key envelope.
    /// Both devices compute this from their own bytes; the server supplies no code.
    public static func transferCode(subject: CloudSubject, approval: CloudApproval, target: CloudDeviceRegistration,
                                    authorKey: CloudPublicJWK, envelope: CloudDeviceKeyEnvelope) throws -> String {
        // Only stable identity: the target's id and key fingerprint. Its label,
        // platform and app version are display facts that the server keeps from
        // first sign-in while the Mac's own copy changes on rename or update;
        // hashing them made honest codes differ (round-2 review, finding 1).
        struct Binding: Encodable {
            let subject: CloudSubject; let approval: CloudApproval
            let targetDeviceId: String; let targetKeyHash: String
            let authorKey: CloudPublicJWK; let epoch: Int; let envelope: CloudDeviceKeyEnvelope
        }
        let digest = hash(Data("TD-CLOUD-APPROVAL-TRANSFER-2\n".utf8) + (try CloudSecretsCanonical.encode(Binding(
            subject: subject, approval: approval, targetDeviceId: target.deviceId, targetKeyHash: try keyHash(target),
            authorKey: authorKey, epoch: envelope.epoch, envelope: envelope))))
        let code = Array(digest.prefix(20).uppercased())
        return stride(from: 0, to: code.count, by: 4).map { String(code[$0..<min($0 + 4, code.count)]) }.joined(separator: " ")
    }
    public static func matchingCode(_ approval: CloudApproval) -> String {
        // The joining device already checks these against its own registration.
        // A server controls approvalId/challenge: including them in a short SAS
        // lets it choose collisions between genuine and substituted target keys.
        // Authenticate the fixed target key fingerprint before wrapping any root.
        let bytes = Data("TD-CLOUD-APPROVAL-TARGET-2\n\(approval.targetDeviceId)\n\(approval.targetKeyHash)".utf8)
        let code = Array(hash(bytes).prefix(32).uppercased())
        return stride(from: 0, to: code.count, by: 4).map { String(code[$0..<min($0 + 4, code.count)]) }.joined(separator: " ")
    }
}

/// A's OS-protected device key adapter remains authoritative; this value is only an envelope payload.
public struct CloudSecretsUnwrapped: Codable, Sendable {
    public let epoch: Int
    public let rootKey: String
    public let recoveryVersion: CloudSequence
    public let canary: String
    public init(epoch: Int, rootKey: String, recoveryVersion: CloudSequence, canary: String) {
        self.epoch = epoch; self.rootKey = rootKey; self.recoveryVersion = recoveryVersion; self.canary = canary
    }
}
public extension CloudSecretsCrypto {
    static func deviceAAD(_ envelope: CloudDeviceKeyEnvelope) throws -> Data {
        let raw = try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope))
            .removing("ciphertext").removing("tag").removing("signature")
        return try CloudSecretsCanonical.encode(CloudValue(raw))
    }
    static func wrapDevice(root: Data, sub: String, target: CloudDeviceRegistration, epoch: Int,
                           recoveryVersion: CloudSequence, author: String,
                           sign: @Sendable (Data) async throws -> Data) async throws -> (CloudDeviceKeyEnvelope, String) {
        try await wrapDevice(root: root, sub: sub, target: target, epoch: epoch, recoveryVersion: recoveryVersion,
            author: author, ephemeral: P256.KeyAgreement.PrivateKey(), salt: random(32), nonce: random(12), canary: random(32), sign: sign)
    }
    internal static func wrapDevice(root: Data, sub: String, target: CloudDeviceRegistration, epoch: Int,
                           recoveryVersion: CloudSequence, author: String, ephemeral: P256.KeyAgreement.PrivateKey,
                           salt: Data, nonce: Data, canary: Data,
                           sign: @Sendable (Data) async throws -> Data) async throws -> (CloudDeviceKeyEnvelope, String) {
        try validateSubject(sub)
        guard root.count == 32, canary.count == 32, salt.count == 32, epoch > 0 else { throw CloudFailure.invalidRequest }
        _ = try uuidBytes(target.deviceId)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: x963(target.wrapPublicJwk))
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let key = derive(shared, salt: salt, info: "TD-CLOUD-DEVICE-1\n\(sub)\n\(target.deviceId)\n\(epoch)")
        let header = CloudDeviceKeyEnvelope(v: 1, epoch: epoch, targetDeviceId: target.deviceId,
            ephemeralPublicJwk: try publicJWK(ephemeral.publicKey.x963Representation), salt: encode(salt), nonce: encode(nonce),
            ciphertext: "", tag: "", authorDeviceId: author, signature: "")
        let aad = try deviceAAD(header)
        let body = CloudSecretsUnwrapped(epoch: epoch, rootKey: encode(root), recoveryVersion: recoveryVersion, canary: encode(canary))
        // Root-carrying plaintext: native canonical form, zeroed once sealed.
        var plain = try CloudSecretsCanonical.encode(body)
        defer { plain.resetBytes(in: 0..<plain.count) }
        let box = try seal(plain, key: key, aad: aad, nonce: nonce)
        let signature = try await sign(aad + decode(box.ciphertext) + decode(box.tag))
        guard signature.count == 64 else { throw CloudFailure.invalidRequest }
        return (.init(v: 1, epoch: epoch, targetDeviceId: target.deviceId, ephemeralPublicJwk: header.ephemeralPublicJwk,
            salt: header.salt, nonce: header.nonce, ciphertext: box.ciphertext, tag: box.tag,
            authorDeviceId: author, signature: encode(signature)), hash(canary))
    }
    static func unwrapDevice(_ envelope: CloudDeviceKeyEnvelope, sub: String, targetDeviceId: String, epoch: Int,
                             version: CloudSequence, author: String, authorKey: CloudPublicJWK,
                             keys: any CloudDeviceKeyPort) async throws -> CloudSecretsUnwrapped {
        try validateSubject(sub)
        guard envelope.v == 1, envelope.epoch == epoch, epoch > 0, envelope.targetDeviceId == targetDeviceId,
              envelope.authorDeviceId == author, envelope.ciphertext.count < 8192,
              (author == "recovery" ? authorKey.crv == "Ed25519" : authorKey.crv == "P-256") else { throw CloudFailure.invalidRequest }
        let aad = try deviceAAD(envelope)
        try verify(envelope.signature, bytes: aad + decode(envelope.ciphertext) + decode(envelope.tag, count: 16), key: authorKey)
        let shared = try await keys.deviceSharedSecret(peer: envelope.ephemeralPublicJwk)
        let key = try derive(shared, salt: decode(envelope.salt, count: 32), info: "TD-CLOUD-DEVICE-1\n\(sub)\n\(targetDeviceId)\n\(epoch)")
        var plain = try open(nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: envelope.tag, key: key, aad: aad)
        defer { plain.resetBytes(in: 0..<plain.count) }
        let body = try CloudWire.decode(CloudSecretsUnwrapped.self, from: plain)
        guard body.epoch == epoch, body.recoveryVersion == version else { throw CloudFailure.versionChanged }
        _ = try decode(body.rootKey, count: 32); _ = try decode(body.canary, count: 32)
        return body
    }
}
