import Foundation
import CryptoKit
import TerminalDeckNativeCore

// Live use from another Mac (Sessions seat, 15 Nov 2026; plan: macos/night/codex/live-use-plan.md, steps 2-3).
// This Mac as a reach GUEST, the way the phones are one: it registers its own reach key with the account once, reads
// the account's machines, takes a 15-minute relay token and joins another machine's room with it. No pairing code and
// no question: signing in is the permission (owner, 13 Nov: "sign in once and everything follows"). The machine it
// joins still judges the join itself (its reach switch, its roster, the key it pinned for this Mac), exactly as it
// judges a phone. Nothing on the session host, the relay or the service changes for this.

/// One machine of the account as `GET /v1/reach/machines` lists it (service `cloud/worker/src/reach.ts` machineList).
public struct BackendReachMachine: Sendable, Equatable {
    public let deviceId: String
    public let hostId: String
    /// The machine's sealed-channel key (32 bytes) and its wire text (base64url, as it signed it).
    public let hostKey: Data
    public let hostKeyText: String
    public let name: String
    public let displayName: String?
    public let platform: String
    public let policy: BackendReachPolicy
    public let signedAt: Int64
    public let sig: String
    public let online: Bool
    /// The service's `self`: this very Mac.
    public let isSelf: Bool
    /// The machine's registered P-256 sign key (JWK x and y, base64url).
    public let signX: String
    public let signY: String

    public init(deviceId: String, hostId: String, hostKey: Data, hostKeyText: String, name: String, displayName: String? = nil,
                platform: String = "macos", policy: BackendReachPolicy = .accountOnly, signedAt: Int64, sig: String, online: Bool,
                isSelf: Bool = false, signX: String, signY: String) {
        self.deviceId = deviceId; self.hostId = hostId; self.hostKey = hostKey; self.hostKeyText = hostKeyText; self.name = name
        self.displayName = displayName; self.platform = platform; self.policy = policy; self.signedAt = signedAt; self.sig = sig
        self.online = online; self.isSelf = isSelf; self.signX = signX; self.signY = signY
    }

    /// What the side panel and the page call it: the friendly name, else the signed one, without ".local".
    public var shownName: String {
        let shown = Self.bare(displayName ?? "")
        return shown.isEmpty ? (Self.bare(name).isEmpty ? name : Self.bare(name)) : shown
    }
    public static func bare(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        if text.lowercased().hasSuffix(".local"), text.count > 6 { text.removeLast(6) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The relay is never trusted: the record must carry the machine's own signature before any handshake (as the
    /// phones' `ReachMessages.presenceValid`).
    public var presenceValid: Bool {
        guard let x = BackendReachWire.unbase64url(signX, length: 32), let y = BackendReachWire.unbase64url(signY, length: 32),
              let signature = BackendReachWire.unbase64url(sig, length: 64),
              let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        let record = BackendReachPresenceRecord(deviceId: deviceId, hostId: hostId, hostKey: hostKeyText, name: name, platform: platform, policy: policy)
        return key.isValidSignature(parsed, for: Data(BackendReachWire.presenceMessage(record, signedAt: signedAt).utf8))
    }

    /// `GET /v1/reach/machines`. A row that cannot be read is dropped, never trusted.
    public static func list(_ value: NativeRPCValue) -> [BackendReachMachine] {
        (value["machines"].elements ?? []).prefix(64).compactMap { row in
            guard let id = row["deviceId"].string, BackendReachWire.validDeviceId(id), let hostId = row["hostId"].string,
                  BackendRelayPacketCodec.isHostID(hostId), let keyText = row["hostKey"].string,
                  let key = BackendReachWire.unbase64url(keyText, length: 32), let name = row["name"].string,
                  let platform = row["platform"].string, let policy = row["policy"].string, ["A", "B"].contains(policy),
                  let signedAt = row["signedAt"].number, signedAt.isFinite, signedAt.rounded() == signedAt,
                  let sig = row["sig"].string, let x = row["signPublicJwk"]["x"].string, let y = row["signPublicJwk"]["y"].string,
                  row["signPublicJwk"]["kty"].string == "EC", row["signPublicJwk"]["crv"].string == "P-256" else { return nil }
            return .init(deviceId: id, hostId: hostId, hostKey: key, hostKeyText: keyText, name: name,
                         displayName: row["displayName"].string, platform: platform, policy: policy == "B" ? .approveNew : .accountOnly,
                         signedAt: Int64(signedAt), sig: sig, online: row["online"].bool == true, isSelf: row["self"].bool == true,
                         signX: x, signY: y)
        }
    }
}

/// The account service as a reach guest needs it (the phones' `PhoneReachBackend` calls, for a computer).
public protocol BackendReachGuestService: Sendable {
    /// This Mac's Cloud device id (nil while signed out or before registration).
    func machineDeviceId() async -> String?
    /// `POST /v1/devices/reach-key {deviceId, reachPublicKey, sig}`.
    func registerReachKey(deviceId: String, publicKey: String) async throws
    /// `GET /v1/reach/machines`.
    func reachMachines() async throws -> [BackendReachMachine]
    /// `POST /v1/reach/token`.
    func relayToken() async throws -> BackendReachRelayToken
}

extension BackendReachAccountHTTPService: BackendReachGuestService {
    public func registerReachKey(deviceId: String, publicKey: String) async throws {
        guard let id = await account.deviceId(), id == deviceId else { throw BackendReachFailure.refused(.signedOut) }
        let sig = BackendReachWire.base64url(try await account.sign(Data(BackendReachWire.reachKeyMessage(deviceId: id, key: publicKey).utf8), id))
        let body = BackendReachWire.canonicalObject([("deviceId", BackendReachWire.jsonString(id)), ("reachPublicKey", BackendReachWire.jsonString(publicKey)),
                                                     ("sig", BackendReachWire.jsonString(sig))])
        _ = try await call("POST", "/devices/reach-key", body: Data(body.utf8))
    }
    public func reachMachines() async throws -> [BackendReachMachine] {
        BackendReachMachine.list(try await call("GET", "/reach/machines", body: nil))
    }
}

/// This Mac's reach key as a GUEST: its own X25519 pair (never the host key it publishes, never a pairing key), kept
/// beside the host identity in the remote trust folder, owner-only (0600), with the device id the service took it for.
/// The service keeps one key per device id (`reach_key_set`), so the file is never replaced while that id lasts.
public struct BackendReachGuestKeyFile: Sendable {
    public let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("reach-guest-key.json") }
    public struct Key: Sendable { public let identity: BackendSealedIdentity; public let registeredFor: String? }

    public func read() throws -> Key? {
        // A file that cannot be read at all (damaged, too big) is moved aside as one with no key is: a new key is made
        // (the service may refuse it for this device id; then the Runs on page says so). Never a dead end that only
        // throws at every dial (first real run, 15 Nov).
        let raw: NativeRPCValue?
        do { raw = try BackendRemoteTrustStorage.read(file, maximumBytes: 4096) }
        catch { try BackendRemoteTrustStorage.quarantine(file); return nil }
        guard let raw else { return nil }
        guard let text = raw["privateKey"].string, let data = BackendRemoteTrustStorage.base64(text), data.count == 32 else {
            try BackendRemoteTrustStorage.quarantine(file); return nil
        }
        return .init(identity: try BackendSealedIdentity(privateKey: data), registeredFor: raw["registeredFor"].string)
    }
    public func write(_ key: Key) throws {
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("privateKey", .string(key.identity.privateKey.base64EncodedString())),
            .init("publicKey", .string(BackendReachWire.base64url(key.identity.publicKey))),
            .init("registeredFor", key.registeredFor.map(NativeRPCValue.string) ?? .null)]), file: file)
    }
}

/// This Mac reaching his other machines by sign-in: the key (registered once), the machine list (30 s fresh), the
/// relay token (renewed with 2 minutes left) and the secrets a `BackendRemoteGuest` dials with.
public actor BackendReachGuest {
    /// Link ids of machines reached by sign-in (paired machines keep their minted store ids).
    public static let linkPrefix = "reach-"
    public static func linkID(_ deviceId: String) -> String { linkPrefix + deviceId }
    public static func isReachLink(_ id: String) -> Bool { id.hasPrefix(linkPrefix) }
    static let renewBeforeMs: Double = 120_000
    static let listFreshMs: Double = 30_000

    private let service: any BackendReachGuestService
    private let keys: BackendReachGuestKeyFile
    public nonisolated let relayURL: String
    private let now: @Sendable () -> Double
    private var key: BackendReachGuestKeyFile.Key?
    private var token: BackendReachRelayToken?
    private var listed: (at: Double, machines: [BackendReachMachine])?
    /// The service refused this Mac's key for its device id (one key per device: `reach_key_set`, `key_in_use`), e.g.
    /// after the key file could not be read. Nothing is reached until he signs in again (a new device id, a new key).
    public private(set) var keyRefused = false
    static let refusedCodes: Set<String> = ["reach_key_set", "key_in_use"]
    /// The one line the Runs on page shows then (Reviewer, 15 Nov: said where he looks, not only in a log).
    public static let keyRefusedLine = "This Mac could not connect to your other Macs. Sign out and in again to fix it."

    public init(service: any BackendReachGuestService, directory: URL, relayURL: String,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.service = service; keys = BackendReachGuestKeyFile(directory: directory); self.relayURL = relayURL; self.now = now
    }

    /// The account's machines (cached 30 s; `fresh` reads again).
    public func machines(fresh: Bool = false) async throws -> [BackendReachMachine] {
        if !fresh, let listed, now() - listed.at < Self.listFreshMs { return listed.machines }
        let machines = try await service.reachMachines()
        listed = (now(), machines)
        return machines
    }

    /// The machines this Mac may dial now: on, not itself, a Mac or PC, and signed by their own key.
    public func reachable(fresh: Bool = false) async throws -> [BackendReachMachine] {
        try await machines(fresh: fresh).filter { $0.online && !$0.isSelf && ["macos", "windows"].contains($0.platform) && $0.presenceValid }
    }

    /// This Mac's guest key, registered for its current device id (once; a new device id gets a new key, as a phone).
    public func prepare() async throws -> (deviceId: String, identity: BackendSealedIdentity) {
        guard let deviceId = await service.machineDeviceId() else { throw BackendReachFailure.refused(.signedOut) }
        if key == nil { key = try keys.read() }
        if let key, key.registeredFor == deviceId { return (deviceId, key.identity) }
        // Never registered, or registered for an earlier device id of this Mac: a new key goes with the new id.
        let fresh = BackendReachGuestKeyFile.Key(identity: key?.registeredFor == nil ? (key?.identity ?? BackendSealedIdentity.generate()) : BackendSealedIdentity.generate(), registeredFor: nil)
        try keys.write(fresh); key = fresh
        do { try await service.registerReachKey(deviceId: deviceId, publicKey: BackendReachWire.base64url(fresh.identity.publicKey)) }
        catch {
            if let failure = error as? CloudFailure, case .remote(let detail) = failure, Self.refusedCodes.contains(detail.code) {
                keyRefused = true
                throw BackendReachFailure.refused(.keyChanged)
            }
            throw error
        }
        keyRefused = false
        let done = BackendReachGuestKeyFile.Key(identity: fresh.identity, registeredFor: deviceId)
        try keys.write(done); key = done
        return (deviceId, done.identity)
    }

    /// A relay token with at least 2 minutes left. A `reach-host` token (policy B, this Mac not approved yet) may not
    /// join anyone: refused here, the link says so and retries.
    public func relayToken() async throws -> String {
        if let token, token.expiresAtMs - now() > Self.renewBeforeMs { return token.token }
        let fresh = try await service.relayToken()
        guard fresh.scope == "reach" else { throw BackendReachFailure.refused(.notApproved) }
        token = fresh
        return fresh.token
    }

    /// What a `BackendRemoteGuest` dials that machine with: its room and key, this Mac's guest key, and the hello's
    /// `reach:<deviceId>` (a public name, never a secret; the relay token goes on the join, read at every dial).
    public func secrets(_ machine: BackendReachMachine) async throws -> BackendMachineSecrets {
        let (deviceId, identity) = try await prepare()
        return .init(hostID: machine.hostId, hostPublicKey: machine.hostKey, relayURL: relayURL, credential: "reach:" + deviceId, guestIdentity: identity)
    }

    /// Sign-out: nothing kept in memory (the key file stays for this device id; a new id replaces it).
    public func forget() { token = nil; listed = nil; key = nil; keyRefused = false }
}
