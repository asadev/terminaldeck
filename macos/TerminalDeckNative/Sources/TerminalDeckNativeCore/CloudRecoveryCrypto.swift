import Foundation
import CryptoKit

/// The codec is an audited dependency. No local word list or mnemonic algorithm.
public protocol CloudRecoveryWordsCodec: Sendable {
    func words(entropy: Data) async throws -> [String]
    func entropy(words: [String]) async throws -> Data
}
public struct CloudRecoveryKeys: Sendable {
    let encryption: Data
    let signing: Curve25519.Signing.PrivateKey
    public let publicKey: CloudPublicJWK
    public init(entropy: Data, sub: String) throws {
        guard entropy.count == 32 else { throw CloudFailure.invalidRequest }
        let salt = try CloudSecretsCrypto.uuidBytes(sub)
        encryption = CloudSecretsCrypto.derive(entropy, salt: salt, info: "TD-CLOUD-RECOVERY-ENC-1")
        signing = try Curve25519.Signing.PrivateKey(rawRepresentation:
            CloudSecretsCrypto.derive(entropy, salt: salt, info: "TD-CLOUD-RECOVERY-SIGN-1"))
        publicKey = .init(kty: "OKP", crv: "Ed25519", x: CloudSecretsCrypto.encode(signing.publicKey.rawRepresentation))
    }
    public func sign(_ bytes: Data) throws -> Data { try signing.signature(for: bytes) }
    private struct Body: Codable { let epoch: Int; let rootKey: String }
    private func aad(sub: String, version: CloudSequence, epoch: Int) -> Data {
        Data("TD-CLOUD-RECOVERY-1\n\(sub)\n\(version.rawValue)\n\(epoch)".utf8)
    }
    public func seal(root: Data, sub: String, version: CloudSequence, epoch: Int) throws -> CloudRecoveryEnvelope {
        try seal(root: root, sub: sub, version: version, epoch: epoch, nonce: CloudSecretsCrypto.random(12))
    }
    func seal(root: Data, sub: String, version: CloudSequence, epoch: Int, nonce: Data) throws -> CloudRecoveryEnvelope {
        guard root.count == 32, epoch > 0, version > .zero else { throw CloudFailure.invalidRequest }
        // Root-carrying plaintext: native canonical form, zeroed once sealed.
        var plain = try CloudSecretsCanonical.encode(Body(epoch: epoch, rootKey: CloudSecretsCrypto.encode(root)))
        defer { plain.resetBytes(in: 0..<plain.count) }
        let box = try CloudSecretsCrypto.seal(plain, key: encryption, aad: aad(sub: sub, version: version, epoch: epoch), nonce: nonce)
        return .init(v: 1, version: version, epoch: epoch, suite: "A256GCM", nonce: box.nonce,
                     ciphertext: box.ciphertext, tag: box.tag, publicSigningJwk: publicKey)
    }
    public func open(_ envelope: CloudRecoveryEnvelope, sub: String, epoch: Int, version: CloudSequence) throws -> Data {
        guard envelope.v == 1, envelope.suite == "A256GCM", envelope.epoch == epoch, epoch > 0,
              envelope.version == version, envelope.publicSigningJwk == publicKey, envelope.ciphertext.count < 4096
        else { throw CloudFailure.checksumMismatch }
        var plain = try CloudSecretsCrypto.open(nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: envelope.tag,
                                               key: encryption, aad: aad(sub: sub, version: version, epoch: epoch))
        defer { plain.resetBytes(in: 0..<plain.count) }
        let body = try CloudWire.decode(Body.self, from: plain)
        guard body.epoch == epoch else { throw CloudFailure.versionChanged }
        return try CloudSecretsCrypto.decode(body.rootKey, count: 32)
    }
}
