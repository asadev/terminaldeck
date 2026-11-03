import Foundation
import CryptoKit

/// The desktop's explicit Open action creates this short-lived capability.
/// It is separate from six-digit relay pairing and is never persisted.
struct BackendRemoteLocalWebPairing: Sendable {
    private struct Offer: Sendable { let hash: Data; let expiresAt: Double }
    private var offers: [Offer] = []
    private(set) var generation = UUID()

    mutating func create(now: Double) throws -> BackendRemotePairingOffer {
        offers.removeAll { now >= $0.expiresAt }
        while offers.count >= 16 { offers.removeFirst() }
        let token = BackendRemoteTrustStorage.base64URL(try BackendRemoteTrustStorage.random(32))
        let expiry = now + 60_000
        offers.append(.init(hash: Self.digest(token), expiresAt: expiry))
        return .init(token: token, expiresAt: expiry)
    }

    mutating func consume(_ token: String, now: Double) -> Bool {
        offers.removeAll { now >= $0.expiresAt }
        guard token.utf8.count == 43 else { return false }
        let digest = Self.digest(token)
        guard let index = offers.firstIndex(where: { BackendRemoteTrustStorage.equal($0.hash, digest) }) else { return false }
        offers.remove(at: index)
        return true
    }

    mutating func cancel() { offers.removeAll(); generation = UUID() }
    private static func digest(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }
}
