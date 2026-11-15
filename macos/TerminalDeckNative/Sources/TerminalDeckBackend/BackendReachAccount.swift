import Foundation
import TerminalDeckNativeCore

// Reach by account (Devices seat, 13 Nov 2026; design: macos/night/codex/reach-by-account-design.md, "R2 decisions").
// A device signed in to the same Terminal Deck account reaches this machine's sessions with no pairing code.
// Everything here stays inert behind a switch that is OFF: nothing runs, publishes or accepts anything until the
// person turns "Let my signed-in devices reach this Mac" on. Today's short-code pairing is not touched.
// R1 wrote the models, gate, door and presence against fakes; R2 matches the service's real formats
// (td-reach-service lane/reach-service, cloud/worker/src/reach.ts) and the relay's (td-reach-relay lane/reach-relay,
// relay/cloudflare/src/reach.ts), adds the HTTP client and wires the door into the relay client and the host.

/// Policy A = account only (the owner's decision). Policy B = A plus one approval of each new device.
public enum BackendReachPolicy: String, Sendable, Codable, Equatable {
    case accountOnly = "A"
    case approveNew = "B"
}

/// This machine's reach settings. `enabled` is false until the person turns it on, and stays false on any read
/// failure: a missing or damaged file means OFF.
public struct BackendReachSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var policy: BackendReachPolicy
    public init(enabled: Bool = false, policy: BackendReachPolicy = .accountOnly) { self.enabled = enabled; self.policy = policy }
}

/// One device of the account as the service lists it for a machine (`GET /v1/reach/devices`, one row of `devices`).
public struct BackendReachRosterDevice: Sendable, Equatable {
    public let deviceId: String
    public let label: String
    /// macos, windows, ios, android, web.
    public let platform: String
    /// The device's X25519 reach key (32 bytes; base64url without padding on the wire), its sealed static key.
    public let reachKey: Data
    /// The device is active in the account and its reach was not removed.
    public let active: Bool
    /// Its reach was removed (final for that device id; not a Cloud removal).
    public let removed: Bool
    /// Its sign-in session is still live (a signed-out or revoked device is refused).
    public let sessionLive: Bool
    /// Browser keys end with their sign-in session (ms since 1970); nil for device keys.
    public let expiresAtMs: Double?
    /// Policy B: an already-signed-in machine approved this device.
    public let approved: Bool
    public let approvedBy: String?
    public let approvalSig: String?
    public init(deviceId: String, label: String, platform: String, reachKey: Data, active: Bool = true, removed: Bool = false,
                sessionLive: Bool = true, expiresAtMs: Double? = nil, approved: Bool = false, approvedBy: String? = nil, approvalSig: String? = nil) {
        self.deviceId = deviceId; self.label = label; self.platform = platform; self.reachKey = reachKey
        self.active = active; self.removed = removed; self.sessionLive = sessionLive; self.expiresAtMs = expiresAtMs
        self.approved = approved; self.approvedBy = approvedBy; self.approvalSig = approvalSig
    }
}

/// The account's devices, as fetched with this machine's own token.
public struct BackendReachRoster: Sendable, Equatable {
    /// The account (`sub`) the list belongs to.
    public let account: String
    /// The service's `devicesVersion` (a decimal string).
    public let version: String
    /// The account's policy as the service keeps it ("A" or "B").
    public let policy: BackendReachPolicy
    public let devices: [BackendReachRosterDevice]
    public init(account: String, version: String, policy: BackendReachPolicy = .accountOnly, devices: [BackendReachRosterDevice]) {
        self.account = account; self.version = version; self.policy = policy; self.devices = devices
    }
}

/// What a machine publishes for its account (`PUT /v1/reach/presence`). The HTTP client adds `signedAt` (ms) and
/// `sig` (this Mac's P-256 device sign key over `TD-REACH-PRESENCE-1\n` + canonical JSON of the seven fields).
public struct BackendReachPresenceRecord: Sendable, Equatable {
    public let deviceId: String
    /// The relay host id (26 characters, base32).
    public let hostId: String
    /// The machine's sealed-channel X25519 public key, base64url without padding: devices start Noise IK with it.
    public let hostKey: String
    public let name: String
    public let platform: String
    public let policy: BackendReachPolicy
    public init(deviceId: String, hostId: String, hostKey: String, name: String, platform: String = "macos", policy: BackendReachPolicy) {
        self.deviceId = deviceId; self.hostId = hostId; self.hostKey = hostKey; self.name = name; self.platform = platform; self.policy = policy
    }
}

/// A short-lived `aud=relay` token (15 minutes) from `POST /v1/reach/token`.
public struct BackendReachRelayToken: Sendable, Equatable {
    public let token: String
    public let expiresAtMs: Double
    /// "reach", or "reach-host" (policy B, this machine not approved yet: it may tie its room, never join).
    public let scope: String
    public init(token: String, expiresAtMs: Double, scope: String = "reach") { self.token = token; self.expiresAtMs = expiresAtMs; self.scope = scope }
}

/// The account service as reach needs it. Real: `BackendReachAccountHTTPService` over the Cloud account's session.
public protocol BackendReachAccountService: Sendable {
    /// The signed-in account's `sub`, or nil when this machine is signed out.
    func signedInAccount() async -> String?
    /// Whether the account holds the `reach` entitlement (`GET /v1/capabilities` → `features` contains `reach`).
    func reachEntitled() async throws -> Bool
    /// This machine's Cloud device id (nil before registration).
    func machineDeviceId() async -> String?
    /// The account's devices with reach keys.
    func roster() async throws -> BackendReachRoster
    /// A short-lived `aud=relay` token for this machine.
    func relayToken() async throws -> BackendReachRelayToken
    func publish(_ presence: BackendReachPresenceRecord) async throws
    func withdraw(deviceId: String) async throws
    /// `POST /v1/reach/devices/remove {deviceId}`: final for that device id.
    func removeDevice(_ deviceId: String) async throws
}

/// The relay as reach needs it: the machine's room is tied to its account (the relay then lets in only devices whose
/// relay token names the same account) or untied again. Real: `BackendRemoteRelayClient` (reconnects `/v1/host` with
/// or without `authorization: Bearer <relay token>`).
public protocol BackendReachRelayDoor: Sendable {
    func attachAccount(_ token: BackendReachRelayToken) async throws
    func detachAccount() async
}

/// What the person must see. Shown on the Mac (and in the page's last connections).
public enum BackendReachNotice: Sendable, Equatable {
    /// A device opened a session on this machine for the first time.
    case firstConnection(deviceId: String, label: String, platform: String)
    /// A device id came back with a different key (or a known key under another id): refused.
    case keyChanged(deviceId: String, label: String)
    /// Policy B: a device of the account asked in but is not approved yet.
    case awaitingApproval(deviceId: String, label: String, platform: String)

    /// The plain sentence for the Mac's notice.
    public var sentence: String {
        switch self {
        // Names only (owner, 13 Nov): never an id, code, fingerprint or key in what the person reads.
        case .firstConnection(_, let label, _):
            "\(label) connected to this Mac for the first time."
        case .keyChanged(_, let label):
            "\(label) tried to reach this Mac from a different install and was refused. Remove it, then sign in on it again."
        case .awaitingApproval(_, let label, _):
            "\(label) asks to reach this Mac and waits for your approval."
        }
    }
}

public protocol BackendReachNoticeSink: Sendable {
    func post(_ notice: BackendReachNotice) async
}

/// Why a reach connection was refused. Never shown to the connecting device in detail (it learns only "closed").
public enum BackendReachRefusal: String, Sendable, Equatable, Codable {
    case switchOff, signedOut, notEntitled, otherAccount, unknownDevice, removed, sessionEnded, keyChanged, notApproved, rateLimited, unavailable
    /// The relay's open mark named another device than the key that finished the handshake.
    case wrongDevice
}

public struct BackendReachAdmission: Sendable, Equatable {
    public let deviceId: String
    public let label: String
    public let platform: String
    public let reachKey: Data
    /// This device's first session on this machine (the notice was raised).
    public let firstTime: Bool
    public init(deviceId: String, label: String, platform: String, reachKey: Data, firstTime: Bool) {
        self.deviceId = deviceId; self.label = label; self.platform = platform; self.reachKey = reachKey; self.firstTime = firstTime
    }
    /// The id the session host knows this device by. Never a paired device's id: those are 16 minted characters.
    public var hostDeviceId: String { BackendReachAdmission.hostDeviceId(deviceId) }
    public static func hostDeviceId(_ deviceId: String) -> String { "reach-" + deviceId }
    /// The hello's `token` for this device: a public name, not a credential.
    public var helloToken: String { "reach:" + deviceId }
}

public enum BackendReachDecision: Sendable, Equatable {
    case admitted(BackendReachAdmission)
    case refused(BackendReachRefusal)
}

public enum BackendReachFailure: Error, Sendable, Equatable {
    /// A switch or approval press within the remote-input guard's window: not the person's own press.
    case remoteInput
    case storage
    case refused(BackendReachRefusal)
}

enum BackendReachWords {
    static func kind(_ platform: String) -> String {
        switch platform.lowercased() {
        case "ios": "iPhone"
        case "android": "Android phone"
        case "web": "Browser"
        case "macos": "Mac"
        case "windows": "Windows PC"
        default: "Device"
        }
    }
}

/// The service's and the relay's exact formats (keys and signatures base64url without padding; domain-separated
/// signed texts; canonical JSON as the service's `canonical()`; the relay's open mark).
public enum BackendReachWire {
    /// `0x52 0x01` + the token's `device_id` (ASCII) in a channel's `open` envelope = an account channel.
    public static let openMark: UInt8 = 0x52
    public static let openVersion: UInt8 = 0x01

    public enum OpenKind: Sendable, Equatable {
        /// Today's pairing path: an empty (or any unmarked) payload.
        case paired
        /// An account channel naming this device id.
        case account(deviceId: String)
        /// Marked, but not readable: closed.
        case invalid
    }

    /// Reads a channel's `open` payload. An unmarked payload is today's paired join, exactly as before.
    public static func openKind(_ payload: Data) -> OpenKind {
        let bytes = [UInt8](payload)
        guard bytes.count >= 1, bytes[0] == openMark else { return .paired }
        guard bytes.count >= 3, bytes.count <= 2 + 64, bytes[1] == openVersion,
              let id = String(bytes: bytes[2...], encoding: .ascii), validDeviceId(id) else { return .invalid }
        return .account(deviceId: id)
    }
    public static func openPayload(deviceId: String) -> Data { Data([openMark, openVersion]) + Data(deviceId.utf8) }

    /// Device ids are lowercase UUIDs (devices and browser session keys alike).
    public static func validDeviceId(_ id: String) -> Bool {
        id.utf8.count == 36 && id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    public static func base64url(_ data: Data) -> String { BackendCloudAccountIdentity.base64(data) }
    /// Strict: only the unpadded url alphabet, and it must round-trip (as the service's `unb64`).
    public static func unbase64url(_ text: String, length: Int? = nil) -> Data? {
        guard let data = BackendCloudAccountIdentity.unbase64(text), base64url(data) == text,
              length.map({ data.count == $0 }) ?? true else { return nil }
        return data
    }

    public static func reachKeyMessage(deviceId: String, key: String) -> String { "TD-REACH-KEY-1\n\(deviceId)\n\(key)" }
    public static func approveMessage(deviceId: String, key: String) -> String { "TD-REACH-APPROVE-1\n\(deviceId)\n\(key)" }
    public static func presenceMessage(_ record: BackendReachPresenceRecord, signedAt: Int64) -> String {
        "TD-REACH-PRESENCE-1\n" + presenceCanonical(record, signedAt: signedAt)
    }
    /// The seven signed fields, keys sorted, as the service's `canonical()` writes them.
    public static func presenceCanonical(_ record: BackendReachPresenceRecord, signedAt: Int64) -> String {
        canonicalObject([("deviceId", jsonString(record.deviceId)), ("hostId", jsonString(record.hostId)), ("hostKey", jsonString(record.hostKey)),
                         ("name", jsonString(record.name)), ("platform", jsonString(record.platform)), ("policy", jsonString(record.policy.rawValue)),
                         ("signedAt", String(signedAt))])
    }
    /// The PUT body: the signed fields plus `sig`.
    public static func presenceBody(_ record: BackendReachPresenceRecord, signedAt: Int64, sig: String) -> String {
        canonicalObject([("deviceId", jsonString(record.deviceId)), ("hostId", jsonString(record.hostId)), ("hostKey", jsonString(record.hostKey)),
                         ("name", jsonString(record.name)), ("platform", jsonString(record.platform)), ("policy", jsonString(record.policy.rawValue)),
                         ("sig", jsonString(sig)), ("signedAt", String(signedAt))])
    }
    static func canonicalObject(_ fields: [(String, String)]) -> String {
        // JS sorts keys by UTF-16 code units; every key here is ASCII, so byte order is the same.
        "{" + fields.sorted { $0.0 < $1.0 }.map { jsonString($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }
    /// `JSON.stringify` of a string: `"` and `\` escaped, \b \f \n \r \t short forms, other controls as \u00xx,
    /// everything else (non-ASCII included) as is.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// `GET /v1/reach/devices`. Rows with an unreadable id or key are dropped (never trusted); a missing account,
    /// version or list is an error.
    public static func roster(_ value: NativeRPCValue) throws -> BackendReachRoster {
        guard let account = value["account"].string, !account.isEmpty, let version = value["version"].string,
              let rows = value["devices"].elements else { throw BackendReachFailure.refused(.unavailable) }
        let policy: BackendReachPolicy = value["policy"].string == "B" ? .approveNew : .accountOnly
        let devices: [BackendReachRosterDevice] = rows.prefix(128).compactMap { row in
            guard let id = row["deviceId"].string, validDeviceId(id), let key = row["reachKey"].string.flatMap({ unbase64url($0, length: 32) }) else { return nil }
            return .init(deviceId: id, label: String((row["label"].string ?? "Device").prefix(80)), platform: row["platform"].string ?? "unknown",
                         reachKey: key, active: row["active"].bool == true, removed: row["removed"].bool == true,
                         sessionLive: row["sessionLive"].bool == true, expiresAtMs: row["expiresAtMs"].number,
                         approved: row["approved"].bool == true, approvedBy: row["approvedBy"].string, approvalSig: row["approvalSig"].string)
        }
        return .init(account: account, version: version, policy: policy, devices: devices)
    }

    /// A `devices` event on the account's socket: {devicesVersion, reachRemoved?: [ids]}.
    public static func removedIds(_ payload: NativeRPCValue) -> [String] {
        (payload["reachRemoved"].elements ?? []).prefix(64).compactMap { $0.string.flatMap { validDeviceId($0) ? $0 : nil } }
    }
}
