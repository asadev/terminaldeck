import CryptoKit
import Foundation

/// Resume tickets (13 Nov 2026, phone speed: one relay round trip less on every reconnect).
///
/// After a full hello (credential checked with scrypt, over the forward-secret sealed channel) a phone that claims
/// `resume.v1` is handed a ticket: a random id and a random 32-byte key, alive `lifetimeMs`, for that device AND the
/// static key its sealed handshake proved. On its next connection the phone seals a resume hello into the handshake's
/// first message (`SealedHandshake.start(early:)`) carrying the ticket id and an HMAC of that handshake's transcript
/// under the ticket key, so the Mac answers the handshake and the welcome together instead of one round trip apart.
///
/// Why this is not a weaker door than the credential:
///  - the first message is authenticated by the device's static key (Noise `ss`): only the device that holds the
///    paired private key can produce one, exactly as before; the ticket must name that same key;
///  - a ticket is single-use (spent on its first try, right or wrong), so the relay replaying a first message gets
///    nothing, and the proof is bound to one transcript, so it cannot be moved to another handshake;
///  - the long-lived credential never travels early (the early payload is not forward secret): a ticket read later
///    is already spent;
///  - every check the credential path makes at its end is made again: not revoked, still approved, still holds the
///    key, the credential unchanged since the ticket was issued (re-pairing or a rotated credential kills it);
///  - tickets live only in this process's memory: a restart of the app forgets them, and the phone falls back to the
///    full hello, as it does for any refusal (`resume.no`).
struct BackendRemoteResumeTicket: Sendable {
    let deviceID: String
    let key: Data
    let secret: Data
    let credentialHash: String
    let expiresAt: Double
}

public enum BackendRemoteResume {
    /// The capability a phone claims in its hello to be handed tickets.
    public static let capability = "resume.v1"
    /// How long a ticket stays usable (ms). Spent at its first use either way; a fresh one comes with every welcome.
    public static let lifetimeMs = 12.0 * 60 * 60 * 1_000
    /// At most this many tickets are held at once (oldest dropped first); one per device key normally.
    static let mostHeld = 256

    /// The proof a phone puts in its resume hello: HMAC-SHA256 under the ticket key over the ticket id and the
    /// handshake transcript hash the early payload is sealed under (`earlyBinding`). Base64.
    public static func proof(secret: Data, id: String, binding: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("td.resume.v1|\(id)|".utf8) + binding, using: SymmetricKey(data: secret))).base64EncodedString()
    }

    static func checks(_ proof: String, secret: Data, id: String, binding: Data) -> Bool {
        guard let given = Data(base64Encoded: proof), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data("td.resume.v1|\(id)|".utf8) + binding,
                                                      using: SymmetricKey(data: secret))
    }
}

extension BackendRemoteTrustStore {
    /// A ticket for a device that has just passed the full credential check on a sealed connection with `key`.
    public func issueResume(deviceID: String, key: Data) throws -> (id: String, secret: Data, ttlMs: Double) {
        try requireOpen()
        guard let device = devices.first(where: { $0.id == deviceID }), !device.revoked, device.approved, deviceHoldsKey(deviceID, key: key)
        else { throw BackendRemoteTrustFailure.denied("This device is not allowed in.") }
        let now = clock()
        resumeTickets = resumeTickets.filter { $0.value.expiresAt > now && !($0.value.deviceID == deviceID && BackendRemoteTrustStorage.equal($0.value.key, key)) }
        while resumeTickets.count >= BackendRemoteResume.mostHeld, let oldest = resumeTickets.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            resumeTickets[oldest] = nil
        }
        let id = try BackendRemoteTrustStorage.random(16).base64EncodedString()
        let secret = try BackendRemoteTrustStorage.random(32)
        resumeTickets[id] = BackendRemoteResumeTicket(deviceID: deviceID, key: key, secret: secret, credentialHash: device.credential.hash,
                                                      expiresAt: now + BackendRemoteResume.lifetimeMs)
        return (id, secret, BackendRemoteResume.lifetimeMs)
    }

    /// The device a resume hello names, or nil (unknown, spent, expired, wrong key or proof, revoked, unapproved,
    /// credential changed). The ticket is spent whatever the answer. Nil is not a failed sign-in (nothing was guessed:
    /// the handshake already proved the device key), so it counts toward no lockout; the phone sends its full hello.
    public func redeemResume(id: String, proof: String, binding: Data, key: Data) -> BackendRemoteDevice? {
        guard lease != nil, let ticket = resumeTickets.removeValue(forKey: id) else { return nil }
        let now = clock()
        guard ticket.expiresAt > now, BackendRemoteTrustStorage.equal(ticket.key, key),
              BackendRemoteResume.checks(proof, secret: ticket.secret, id: id, binding: binding),
              let index = devices.firstIndex(where: { $0.id == ticket.deviceID }),
              !devices[index].revoked, devices[index].approved, devices[index].credential.hash == ticket.credentialHash,
              deviceHoldsKey(ticket.deviceID, key: key) else { return nil }
        let previous = devices[index].lastSeenAt
        devices[index].lastSeenAt = now
        if previous == nil || now - (previous ?? 0) >= 60000 {
            do { try persist(devices) } catch { devices[index].lastSeenAt = previous }
        }
        return devices[index].publicDevice
    }

    /// For tests: how many tickets are held.
    public var resumeTicketCount: Int { resumeTickets.count }
}
