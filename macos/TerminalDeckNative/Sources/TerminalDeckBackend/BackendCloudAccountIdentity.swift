import Foundation
import CryptoKit
import TerminalDeckNativeCore

public struct BackendCloudAccountKeys: Codable, Sendable {
    public let deviceId: String
    public let signing: Data
    public let wrapping: Data
    public init(deviceId: String, signing: Data, wrapping: Data) {
        self.deviceId = deviceId; self.signing = signing; self.wrapping = wrapping
    }
    public static func fresh() -> Self {
        .init(deviceId: UUID().uuidString.lowercased(), signing: P256.Signing.PrivateKey().rawRepresentation,
              wrapping: P256.KeyAgreement.PrivateKey().rawRepresentation)
    }
}
private struct BackendCloudStoredIdentity: Codable, Sendable {
    let session: CloudAuthSession
    let keys: BackendCloudAccountKeys
    /// Leave notes of earlier sign-outs that could not reach Cloud yet (proof 2); kept across a new sign-in.
    var leaveNotes: [BackendCloudLeaveNote]?
}
/// What a signed-out Mac keeps: the tombstone, and leave notes still to send.
private struct BackendCloudSignedOutRecord: Codable, Sendable {
    let signedOut: Bool
    var leaveNotes: [BackendCloudLeaveNote]?
}
/// Proof 2 (13 Nov): a Mac that signed out while Cloud could not take its removal keeps ONE signed note per old
/// device: its account, its device id and the time, signed by that device's own key. Sent later to
/// `POST /v1/devices/leave` without any sign-in session (it is gone); it can only remove the device that signed it, so
/// it holds nothing secret and sending it twice changes nothing.
public struct BackendCloudLeaveNote: Codable, Sendable, Equatable {
    public let sub: String
    public let deviceId: String
    public let signedAt: String
    public let signature: String
    public static func text(sub: String, deviceId: String, signedAt: String) -> String {
        "TD-CLOUD-LEAVE-1\n\(sub)\n\(deviceId)\n\(signedAt)"
    }
    /// Notes this old are dropped unsent: the other Macs have long marked that entry stale.
    public static let keepForMilliseconds: Int64 = 30 * 86_400_000
}

public actor BackendCloudAccountIdentity: CloudAuthenticationPort, CloudDeviceKeyPort {
    public nonisolated let configuration: CloudAccountConfiguration
    private let store: BackendCloudAccountProtectedStore
    private let http: any BackendCloudAccountHTTP
    private let clock: @Sendable () -> Int64
    private let makeKeys: @Sendable () -> BackendCloudAccountKeys
    private var saved: BackendCloudStoredIdentity?
    private var pendingLeave: [BackendCloudLeaveNote] = []
    private var generation = 0
    private var loaded = false
    private var refreshing: Task<CloudAuthSession, Error>?
    public init(configuration: CloudAccountConfiguration, store: BackendCloudAccountProtectedStore,
                http: any BackendCloudAccountHTTP, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                makeKeys: @escaping @Sendable () -> BackendCloudAccountKeys = { .fresh() }) {
        self.configuration = configuration; self.store = store; self.http = http; self.clock = clock; self.makeKeys = makeKeys
    }
    private func load() throws {
        guard !loaded else { return }
        if let text = try store.read() {
            if let raw = try? CloudWire.decode(CloudValue.self, from: Data(text.utf8)), raw.raw["signedOut"].bool == true {
                pendingLeave = (try? CloudWire.decode(BackendCloudSignedOutRecord.self, from: Data(text.utf8), maximumBytes: 65_536))?.leaveNotes ?? []
                loaded = true; return
            }
            let record = try CloudWire.decode(BackendCloudStoredIdentity.self, from: Data(text.utf8), maximumBytes: 65_536)
            guard UUID(uuidString: record.keys.deviceId) != nil else { throw CloudFailure.invalidRequest }
            _ = try P256.Signing.PrivateKey(rawRepresentation: record.keys.signing)
            _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: record.keys.wrapping)
            saved = record
            pendingLeave = record.leaveNotes ?? []
        }
        loaded = true
    }
    /// TLS handoff is followed by server-verified device registration; a decoded JWT alone never opens the UI gate.
    public func install(_ session: CloudAuthSession) throws {
        try validate(session)
        try load()
        let next = BackendCloudStoredIdentity(session: session, keys: saved?.keys ?? makeKeys(), leaveNotes: pendingLeave.isEmpty ? nil : pendingLeave)
        _ = try P256.Signing.PrivateKey(rawRepresentation: next.keys.signing)
        _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: next.keys.wrapping)
        try store.write(String(decoding: CloudWire.canonical(next), as: UTF8.self))
        saved = next
        generation += 1
    }
    public func existing() throws -> CloudAuthSession? { try load(); return saved?.session }
    public func clear(leaving note: BackendCloudLeaveNote? = nil) throws {
        refreshing?.cancel(); refreshing = nil
        try? load()
        if let note { pendingLeave = Array((pendingLeave.filter { $0.deviceId != note.deviceId } + [note]).suffix(8)) }
        // A durable non-secret tombstone also protects a later restart if Keychain deletion fails. With leave notes
        // still to send, the tombstone carries them and stays.
        try writeSignedOut()
        saved = nil; loaded = true; generation += 1
        if pendingLeave.isEmpty { try? store.remove() }
    }
    private func writeSignedOut() throws {
        try store.write(String(decoding: try CloudWire.canonical(BackendCloudSignedOutRecord(signedOut: true, leaveNotes: pendingLeave.isEmpty ? nil : pendingLeave)), as: UTF8.self))
    }
    /// The leave note for the device this Mac is signed in as, signed now by its own key (before sign-out drops it).
    public func leaveNote() throws -> BackendCloudLeaveNote? {
        try load()
        guard let saved else { return nil }
        let signedAt = String(clock())
        let text = BackendCloudLeaveNote.text(sub: saved.session.user.id, deviceId: saved.keys.deviceId, signedAt: signedAt)
        let signature = try P256.Signing.PrivateKey(rawRepresentation: saved.keys.signing).signature(for: Data(text.utf8)).rawRepresentation
        return .init(sub: saved.session.user.id, deviceId: saved.keys.deviceId, signedAt: signedAt, signature: Self.base64(signature))
    }
    /// Leave notes still to send, without those past their keep time.
    public func leaveNotes() throws -> [BackendCloudLeaveNote] {
        try load()
        let now = clock()
        return pendingLeave.filter { (Int64($0.signedAt) ?? 0) + BackendCloudLeaveNote.keepForMilliseconds > now }
    }
    /// The note was taken (or can never be): forget it, keeping whatever else this Mac holds.
    public func dropLeaveNote(deviceId: String) throws {
        try load()
        let now = clock()
        let left = pendingLeave.filter { $0.deviceId != deviceId && (Int64($0.signedAt) ?? 0) + BackendCloudLeaveNote.keepForMilliseconds > now }
        guard left != pendingLeave else { return }
        pendingLeave = left
        if var record = saved {
            record.leaveNotes = left.isEmpty ? nil : left
            try store.write(String(decoding: try CloudWire.canonical(record), as: UTF8.self))
            saved = record
        } else {
            try writeSignedOut()
            if left.isEmpty { try? store.remove() }
        }
    }
    public func credentials() async throws -> CloudAuthSession { try await credentials(force: false) }
    /// `force`: the service said the access token is not accepted (sign_in_required / token_expired), so refresh it
    /// now even though this Mac's clock thinks it is still valid.
    public func credentials(force: Bool) async throws -> CloudAuthSession {
        try load()
        guard let record = saved else { throw CloudFailure.gateClosed }
        if !force, record.session.expiresAt > clock() + 60_000 { return record.session }
        if let refreshing { return try await refreshing.value }
        let version = generation
        let task = Task<CloudAuthSession, Error> { [http, configuration, clock] in
            var parts = URLComponents(url: configuration.storeAuthURL.appendingPathComponent("token"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "grant_type", value: "refresh_token")]
            let body = try CloudWire.canonical(CloudValue(.object([.init("refresh_token", .string(record.session.refreshToken))])))
            var headers = ["content-type": "application/json"]
            if !configuration.publishableKey.isEmpty { headers["apikey"] = configuration.publishableKey }
            let response = try await http.send(.init(url: parts.url!, method: "POST", headers: headers, body: body))
            let raw = try response.decoded(CloudValue.self).raw
            guard let access = raw["access_token"].string, let refresh = raw["refresh_token"].string,
                  let expiry = raw["expires_at"].number, expiry * 1000 > Double(clock()),
                  raw["user"]["id"].string == record.session.user.id else { throw CloudFailure.invalidRequest }
            let session = CloudAuthSession(accessToken: access, refreshToken: refresh, expiresAt: Int64(expiry * 1000), user: record.session.user, capabilities: .closed)
            return try await self.finishRefresh(session, generation: version, previous: record.session.refreshToken)
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }
    private func finishRefresh(_ session: CloudAuthSession, generation expected: Int, previous: String) throws -> CloudAuthSession {
        guard generation == expected, saved?.session.refreshToken == previous else { throw CloudFailure.gateClosed }
        // Every waiter receives only the token pair already committed to the protected store.
        try install(session)
        return session
    }
    private func validate(_ session: CloudAuthSession) throws {
        let now = clock()
        guard UUID(uuidString: session.user.id) != nil, !session.refreshToken.isEmpty,
              session.expiresAt > now, session.expiresAt <= now + 3_630_000 else { throw CloudFailure.invalidRequest }
        let parts = session.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let bytes = Self.unbase64(String(parts[1])) else { throw CloudFailure.invalidRequest }
        let claims = try CloudWire.decode(CloudValue.self, from: bytes, maximumBytes: 32_768).raw
        guard claims["iss"].string == configuration.issuer, claims["sub"].string == session.user.id,
              claims["role"].string == "authenticated", claims["aud"].string == "authenticated",
              let exp = claims["exp"].number, let iat = claims["iat"].number,
              exp * 1000 >= Double(now - 30_000), iat * 1000 <= Double(now + 30_000),
              exp - iat <= 3600, UUID(uuidString: claims["session_id"].string ?? "") != nil else { throw CloudFailure.invalidRequest }
    }
    public func deviceRegistration() async throws -> CloudDeviceRegistration {
        try load()
        guard let record = saved else { throw CloudFailure.gateClosed }
        let sign = try P256.Signing.PrivateKey(rawRepresentation: record.keys.signing).publicKey.x963Representation
        let wrap = try P256.KeyAgreement.PrivateKey(rawRepresentation: record.keys.wrapping).publicKey.x963Representation
        return .init(deviceId: record.keys.deviceId, label: configuration.deviceLabel, platform: .macos, appVersion: configuration.appVersion,
                     signPublicJwk: Self.jwk(sign), wrapPublicJwk: Self.jwk(wrap))
    }
    public func signDevicePayload(_ bytes: Data) async throws -> Data {
        try load()
        guard let saved else { throw CloudFailure.gateClosed }
        return try P256.Signing.PrivateKey(rawRepresentation: saved.keys.signing).signature(for: bytes).rawRepresentation
    }
    /// Signs only for the registration named by `deviceId`; a request for any other (older or foreign) registration throws.
    public func signDevicePayload(_ bytes: Data, deviceId: String) async throws -> Data {
        try load()
        guard let saved else { throw CloudFailure.gateClosed }
        guard saved.keys.deviceId == deviceId else { throw CloudFailure.unsafeConfiguration }
        return try P256.Signing.PrivateKey(rawRepresentation: saved.keys.signing).signature(for: bytes).rawRepresentation
    }
    public func deviceSharedSecret(peer: CloudPublicJWK) async throws -> Data {
        try load()
        guard let saved, peer.kty == "EC", peer.crv == "P-256", let y = peer.y,
              let xData = Self.unbase64(peer.x), let yData = Self.unbase64(y), xData.count == 32, yData.count == 32 else { throw CloudFailure.invalidRequest }
        let point = Data([4]) + xData + yData
        let key = try P256.KeyAgreement.PublicKey(x963Representation: point)
        let shared = try P256.KeyAgreement.PrivateKey(rawRepresentation: saved.keys.wrapping).sharedSecretFromKeyAgreement(with: key)
        return shared.withUnsafeBytes { Data($0) }
    }
    public func signRequest(method: String, pathAndQuery: String, body: Data, timestamp: Int64, requestId: String) async throws -> CloudRequestProof {
        guard ["GET", "POST"].contains(method), pathAndQuery.hasPrefix("/v1/"),
              !pathAndQuery.contains("\n"), !pathAndQuery.contains("\r"), UUID(uuidString: requestId) != nil,
              abs(timestamp - clock()) <= 7 * 86_400_000 else { throw CloudFailure.invalidRequest }
        // The sync transport may sign with a service-corrected time after a 400 clock_skew answer (round 5), so this Mac's
        // own clock only bounds the time loosely here; the service enforces its 60-second window.
        let registration = try await deviceRegistration()
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let bytes = Data("TD-CLOUD-1\n\(method)\n\(pathAndQuery)\n\(timestamp)\n\(requestId)\n\(hash)".utf8)
        return .init(deviceId: registration.deviceId, time: timestamp, requestId: requestId, signature: Self.base64(try await signDevicePayload(bytes)))
    }
    public static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func unbase64(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let t = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: t + String(repeating: "=", count: (4 - t.count % 4) % 4))
    }
    private static func jwk(_ point: Data) -> CloudPublicJWK {
        .init(kty: "EC", crv: "P-256", x: base64(Data(point[1..<33])), y: base64(Data(point[33..<65])))
    }
}
