import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The account service for reach, over this Mac's Cloud sign-in (service: td-reach-service lane/reach-service,
/// cloud/worker/src/reach.ts). Every reach route is a signed device request exactly like the sync core's
/// (`TD-CLOUD-1` proof with this Mac's P-256 device sign key, bearer access token); `/capabilities` takes the bearer
/// only. Nothing here keeps a token: each call asks the account for its current one.
public struct BackendReachAccountHTTPService: BackendReachAccountService {
    public struct Account: Sendable {
        /// The signed-in `sub`, nil when signed out.
        public let subject: @Sendable () async -> String?
        /// The current access token (`force`: the service refused the last one).
        public let accessToken: @Sendable (_ force: Bool) async throws -> String
        /// This Mac's Cloud device id.
        public let deviceId: @Sendable () async -> String?
        /// Raw 64-byte P-256 signature (r||s) with this Mac's device sign key, only for `deviceId`.
        public let sign: @Sendable (_ bytes: Data, _ deviceId: String) async throws -> Data
        public init(subject: @escaping @Sendable () async -> String?, accessToken: @escaping @Sendable (Bool) async throws -> String,
                    deviceId: @escaping @Sendable () async -> String?, sign: @escaping @Sendable (Data, String) async throws -> Data) {
            self.subject = subject; self.accessToken = accessToken; self.deviceId = deviceId; self.sign = sign
        }
        /// The Mac's real Cloud identity.
        public static func live(_ identity: BackendCloudAccountIdentity) -> Account {
            .init(subject: { (try? await identity.existing())?.user.id },
                  accessToken: { force in try await identity.credentials(force: force).accessToken },
                  deviceId: { try? await identity.deviceRegistration().deviceId },
                  sign: { bytes, id in try await identity.signDevicePayload(bytes, deviceId: id) })
        }
    }

    let base: URL
    let http: any BackendCloudAccountHTTP
    let account: Account
    let now: @Sendable () -> Int64

    /// `base` is the Cloud's `/v1` address (the same one sync uses).
    public init(base: URL, http: any BackendCloudAccountHTTP, account: Account, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.base = base; self.http = http; self.account = account; self.now = now
    }

    public func signedInAccount() async -> String? { await account.subject() }
    public func machineDeviceId() async -> String? { await account.deviceId() }

    public func reachEntitled() async throws -> Bool {
        let value = try await call("GET", "/capabilities", body: nil, signed: false)
        return (value["features"].elements ?? []).contains { $0.string == "reach" }
    }

    public func roster() async throws -> BackendReachRoster {
        try BackendReachWire.roster(try await call("GET", "/reach/devices", body: nil))
    }

    public func relayToken() async throws -> BackendReachRelayToken {
        let value = try await call("POST", "/reach/token", body: Data("{}".utf8))
        guard let token = value["token"].string, token.split(separator: ".").count == 3, let expires = value["expiresAt"].number else {
            throw BackendReachFailure.refused(.unavailable)
        }
        return .init(token: token, expiresAtMs: expires, scope: value["scope"].string ?? "reach")
    }

    public func publish(_ presence: BackendReachPresenceRecord) async throws {
        guard let id = await account.deviceId(), id == presence.deviceId else { throw BackendReachFailure.refused(.unavailable) }
        let signedAt = now()
        let sig = BackendReachWire.base64url(try await account.sign(Data(BackendReachWire.presenceMessage(presence, signedAt: signedAt).utf8), id))
        _ = try await call("PUT", "/reach/presence", body: Data(BackendReachWire.presenceBody(presence, signedAt: signedAt, sig: sig).utf8))
    }

    public func withdraw(deviceId: String) async throws {
        _ = try await call("DELETE", "/reach/presence", body: Data(BackendReachWire.canonicalObject([("deviceId", BackendReachWire.jsonString(deviceId))]).utf8))
    }

    public func removeDevice(_ deviceId: String) async throws {
        guard BackendReachWire.validDeviceId(deviceId) else { throw BackendReachFailure.refused(.unknownDevice) }
        _ = try await call("POST", "/reach/devices/remove", body: Data(BackendReachWire.canonicalObject([("deviceId", BackendReachWire.jsonString(deviceId))]).utf8))
    }

    /// The device proof the service checks (cloud/worker/src/user.ts): over method, path, time, request id and the
    /// body's SHA-256 (hex; the empty body's for GET).
    static func proofText(method: String, path: String, time: Int64, requestId: String, body: Data) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "TD-CLOUD-1\n\(method)\n\(path)\n\(time)\n\(requestId)\n\(hash)"
    }

    func request(_ method: String, _ path: String, body: Data?, signed: Bool, force: Bool) async throws -> BackendCloudAccountRequest {
        guard let url = URL(string: base.absoluteString + path) else { throw BackendReachFailure.refused(.unavailable) }
        let bytes = body ?? Data()
        var headers = ["authorization": "Bearer " + (try await account.accessToken(force)), "cache-control": "no-store"]
        if signed {
            guard let id = await account.deviceId() else { throw BackendReachFailure.refused(.signedOut) }
            let time = now(), requestId = UUID().uuidString.lowercased()
            let text = Self.proofText(method: method, path: url.path, time: time, requestId: requestId, body: bytes)
            headers["x-td-device"] = id
            headers["x-td-time"] = String(time)
            headers["x-td-request"] = requestId
            headers["x-td-signature"] = BackendReachWire.base64url(try await account.sign(Data(text.utf8), id))
            headers["content-type"] = "application/json"
        } else {
            headers["x-td-request"] = UUID().uuidString.lowercased()
        }
        return .init(url: url, method: method, headers: headers, body: bytes)
    }

    func call(_ method: String, _ path: String, body: Data?, signed: Bool = true) async throws -> NativeRPCValue {
        var answer = try await http.send(try await request(method, path, body: body, signed: signed, force: false))
        if answer.status == 401 { answer = try await http.send(try await request(method, path, body: body, signed: signed, force: true)) }
        guard (200...299).contains(answer.status) else {
            let code = (try? NativeRPCValue.parseJSON(answer.body, maximumBytes: 16_384))?["error"]["code"].string ?? "unavailable"
            throw CloudFailure.remote(.init(code: code, message: "Cloud could not finish this reach request.", retryable: answer.status >= 500 || answer.status == 429, requestId: ""))
        }
        return try NativeRPCValue.parseJSON(answer.body, maximumBytes: 262_144)
    }
}
