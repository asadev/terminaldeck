import Foundation

/// Shared wire values only. Store ownership and protected credentials stay in their existing owners.
public struct CloudValue: Codable, Equatable, Sendable {
    public let raw: NativeRPCValue
    public init(_ raw: NativeRPCValue) { self.raw = raw }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        // The existing bridge preserves field order. JSON payload identity must not.
        if let left = try? CloudWire.canonical(lhs), let right = try? CloudWire.canonical(rhs) { return left == right }
        return lhs.raw == rhs.raw
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { raw = .null }
        else if let b = try? c.decode(Bool.self) { raw = .bool(b) }
        else if let s = try? c.decode(String.self) { raw = .string(s) }
        else if let n = try? c.decode(Double.self), n.isFinite { raw = .number(n) }
        else if let a = try? c.decode([CloudValue].self) { raw = .array(a.map(\.raw)) }
        else { raw = .object(try c.decode([String: CloudValue].self).sorted { $0.key < $1.key }.map { .init($0.key, $0.value.raw) }) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch raw {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        case .number(let n):
            guard n.isFinite else { throw CloudFailure.invalidRequest }
            try c.encode(n)
        case .array(let a): try c.encode(a.map(CloudValue.init))
        case .object(let f):
            guard Set(f.map(\.key)).count == f.count else { throw CloudFailure.invalidRequest }
            try c.encode(Dictionary(uniqueKeysWithValues: f.map { ($0.key, CloudValue($0.value)) }))
        case .bytes, .missing: throw CloudFailure.invalidRequest
        }
    }
}

public struct CloudSequence: Codable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public static let zero = CloudSequence(0)
    public init(_ value: UInt64) { rawValue = String(value) }
    public init(rawValue: String) throws {
        guard !rawValue.isEmpty, rawValue.utf8.allSatisfy({ (48...57).contains($0) }),
              rawValue == "0" || !rawValue.hasPrefix("0"), UInt64(rawValue) != nil else { throw CloudFailure.invalidRequest }
        self.rawValue = rawValue
    }
    public init(from decoder: Decoder) throws { try self.init(rawValue: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.count == rhs.rawValue.count ? lhs.rawValue < rhs.rawValue : lhs.rawValue.count < rhs.rawValue.count
    }
}

public enum CloudFailure: Error, Equatable, Sendable {
    case invalidRequest, unsupportedFormat, unsafeConfiguration, unavailable, gateClosed, storageRequired
    case checksumMismatch, idReused, versionChanged, secretsLocked, deviceRevoked, budgetPaused
    case remote(CloudErrorDetail)
}
public enum CloudStorageClass: String, Codable, Sendable { case brain, secrets }
public enum CloudPurpose: String, Codable, Sendable {
    case brain, secret, backup, artifact, database, browser
    case aiSubscription = "ai-subscription"
    public func permits(_ storageClass: CloudStorageClass) -> Bool {
        switch self {
        case .brain: return storageClass == .brain
        case .secret, .browser, .aiSubscription: return storageClass == .secrets
        case .backup, .artifact, .database: return true
        }
    }
}
public enum CloudPlatform: String, Codable, Sendable { case macos, ios, android, windows, web }
public enum CloudDeviceStatus: String, Codable, Sendable { case active, revoked }
public enum CloudVaultState: String, Codable, Sendable { case unset, ready, rotating, reset }
public enum CloudOperationKind: String, Codable, Sendable { case put, append, archive, supersede }
public enum CloudApplyStatus: String, Codable, Sendable {
    case applied, blocked
    case keptBoth = "kept_both"
    case alreadyPresent = "already_present"
}
public enum CloudContentCodec: String, Codable, Sendable { case identity, gzip }
public enum CloudConflictPolicy: String, Codable, Sendable { case keepBoth = "keep_both" }

public enum CloudWire {
    public static let version = 1
    public static let maximumPlainChunkBytes = 8 * 1024 * 1024
    public static let maximumBlobBytes = 12 * 1024 * 1024
    /// SYNC contract addition: the largest record the outbox accepts and can send. A record's canonical payload
    /// must be at most `maximumRecordPayloadBytes`; the whole canonical record at most `maximumRecordBytes`
    /// (one record must fit one live pack). Larger content goes into sealed files. Adapters read these
    /// constants; `enqueue` refuses anything larger with `CloudRecordTooLarge`.
    public static let maximumRecordPayloadBytes = 65_536
    public static let maximumRecordBytes = 179_998
    /// SYNC contract addition: the service's rule for a domain name (feed.ts:91), the one definition every lane
    /// reads: lower-case letters, digits, '/', '_' and '-', starting with a letter or digit, at most 128 bytes.
    /// `enqueue` refuses a record whose domain breaks it with `CloudDomainNameInvalid`.
    public static let domainNamePattern = "^[a-z0-9][a-z0-9/_-]*$"
    public static let maximumDomainNameBytes = 128
    public static func isValidDomainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maximumDomainNameBytes, let first = name.unicodeScalars.first else { return false }
        func allowed(_ c: Unicode.Scalar, first: Bool) -> Bool {
            ("a"..."z").contains(c) || ("0"..."9").contains(c) || (!first && (c == "/" || c == "_" || c == "-"))
        }
        return allowed(first, first: true) && name.unicodeScalars.dropFirst().allSatisfy { allowed($0, first: false) }
    }
    /// Lane A's names for the same rule (kept for its callers): one definition, SYNC's.
    public static func isValidDomain(_ name: String) -> Bool { isValidDomainName(name) }
    /// The only way to make a domain name: an invalid one cannot be constructed.
    public static func domain(_ name: String) throws -> String {
        guard isValidDomainName(name) else { throw CloudFailure.invalidRequest }
        return name
    }
    public static let issuer = "https://api.terminaldeck.dev/auth/v1"
    public static let productionBase = "https://cloud.terminaldeck.dev/v1"
    public static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        let raw = try NativeRPCValue.parseJSON(encoder.encode(value))
        return Data(try ordered(raw).compact.utf8)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, allowedKeys: Set<String>? = nil,
                                           maximumBytes: Int = 409_600) throws -> T {
        guard data.count <= maximumBytes else { throw CloudFailure.invalidRequest }
        try checkDepth(data)
        guard let raw = OrderedJSON.parse(data) else { throw CloudFailure.invalidRequest }
        try checkKeys(raw)
        if let allowedKeys, let fields = raw.fields, !Set(fields.map(\.key)).isSubset(of: allowedKeys) { throw CloudFailure.invalidRequest }
        return try JSONDecoder().decode(type, from: data)
    }
    private static func checkDepth(_ data: Data) throws {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 128 { throw CloudFailure.invalidRequest } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { throw CloudFailure.invalidRequest } }
        }
        guard depth == 0, !quoted else { throw CloudFailure.invalidRequest }
    }
    private static func checkKeys(_ value: OrderedJSON) throws {
        if let fields = value.fields {
            guard Set(fields.map(\.key)).count == fields.count else { throw CloudFailure.invalidRequest }
            for field in fields { try checkKeys(field.value) }
        }
        if let values = value.array { for child in values { try checkKeys(child) } }
    }
    private static func ordered(_ value: NativeRPCValue) throws -> OrderedJSON {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .string(let s): return .string(s)
        case .number(let n): guard n.isFinite else { throw CloudFailure.invalidRequest }; return .number(n)
        case .array(let a): return .array(try a.map(ordered))
        case .object(let fields):
            guard Set(fields.map(\.key)).count == fields.count else { throw CloudFailure.invalidRequest }
            return .object(try fields.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }.map { .init($0.key, try ordered($0.value)) })
        case .bytes, .missing: throw CloudFailure.invalidRequest
        }
    }
}

public struct CloudErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public let retryAfterMs: Int?
    public let requestId: String
    /// `403 device_revoked` of a device another device signed out (Security design A2, optional): that device's name
    /// and when (service clock, ms). Display only ("Signed out from <name> on <date>").
    public let removedByName: String?
    public let removedAt: Int64?
    public init(code: String, message: String, retryable: Bool, retryAfterMs: Int? = nil, requestId: String,
                removedByName: String? = nil, removedAt: Int64? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfterMs = retryAfterMs
        self.requestId = requestId
        self.removedByName = removedByName
        self.removedAt = removedAt
    }
}

public struct CloudSubject: Codable, Equatable, Sendable {
    public let issuer: String
    public let sub: String
    public init(issuer: String, sub: String) {
        self.issuer = issuer
        self.sub = sub
    }
}

public struct CloudPublicJWK: Codable, Equatable, Sendable {
    public let kty: String
    public let crv: String
    public let x: String
    public let y: String?
    public init(kty: String, crv: String, x: String, y: String? = nil) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
    }
}

public struct CloudGate: Codable, Equatable, Sendable {
    public let features: [String]
    public let storageEntitled: Bool?
    public let aiSubscriptionsEnabled: Bool?
    public let revision: CloudSequence?
    public let expiresAt: Int64?
    public init(features: [String], storageEntitled: Bool? = nil, aiSubscriptionsEnabled: Bool? = nil, revision: CloudSequence? = nil, expiresAt: Int64? = nil) {
        self.features = features
        self.storageEntitled = storageEntitled
        self.aiSubscriptionsEnabled = aiSubscriptionsEnabled
        self.revision = revision
        self.expiresAt = expiresAt
    }
}

public struct CloudUserIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// N4: shown on the confirm sheet as returned by the server after the code exchange. Optional, absent in older answers.
    public let email: String?
    public let provider: String?
    public init(id: String, displayName: String, email: String? = nil, provider: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.provider = provider
    }
    private enum CodingKeys: String, CodingKey { case id, displayName, email, provider }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
    }
}

public struct CloudAuthSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Int64
    public let user: CloudUserIdentity
    public let capabilities: CloudGate
    public let resetTicket: String?
    public init(accessToken: String, refreshToken: String, expiresAt: Int64, user: CloudUserIdentity, capabilities: CloudGate, resetTicket: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
        self.capabilities = capabilities
        self.resetTicket = resetTicket
    }
}

public struct CloudDevice: Codable, Equatable, Sendable {
    public let deviceId: String
    public let label: String
    public let platform: CloudPlatform
    public let appVersion: String
    public let status: CloudDeviceStatus
    public let secretsApproved: Bool
    public let lastSeenAt: Int64
    public let signPublicJwk: CloudPublicJWK
    public let wrapPublicJwk: CloudPublicJWK
    /// Additive (device trust design 2.7, lean scope item 6): when the service added this device, in milliseconds
    /// since 1970, as the service reports it. Display only ("added … (reported)"); never an input to trust.
    public let registeredAt: Int64?
    /// Additive (proof 2, 13 Nov): how far this device has read the account's feed, as the service reports it
    /// (`lastPulledSeq`). Display only ("On <device>" in the Your Cloud window); never an input to trust.
    public var lastPulledSeq: CloudSequence? = nil
    /// Additive (MAC-NEXT-7, service prod2): when the service received that position, in milliseconds since 1970.
    /// nil from an older service. Display only: a "n changes still to fetch" number is said only for a recent report.
    public var lastPulledAt: Int64? = nil
    /// Additive (lost-device service, 15 Nov small fixes item 3): a device another device signed out (and that signed
    /// in again) says who did it and when (ms). Display only ("Signed out from <device> on <date>"); nil = as before.
    public var removedByName: String? = nil
    public var removedAt: Int64? = nil
    /// Additive (MAC-NEXT-10, one row per machine): the computer's friendly name as the device last told the service
    /// (falls back to the recorded label on the service). nil from an older service. Display only.
    public var displayName: String? = nil
    /// Additive (service prod3): "peer" (a Mac or PC that holds a copy) or "viewer" (a phone or browser: reads only,
    /// holds no copy of the memory). nil from an older service.
    public var role: String? = nil
    /// Additive (service prod3, only with ?include=retired): the registration of the same machine that replaced this one.
    public var supersededBy: String? = nil
    /// Additive (lost-device review D1, until the service's own field name is in its as-built section): a new sign-in on
    /// a machine that another of his devices signed out. nil from a service that does not say it.
    public var signedOutBefore: Bool? = nil
    /// A phone or a browser: never part of sync standing ("catching up", "waiting on").
    public var isViewer: Bool { role == "viewer" || [.ios, .android, .web].contains(platform) }
    /// The name a page shows: the friendly name when the service reports one, else the recorded label.
    public var shownName: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return label
    }
    public init(deviceId: String, label: String, platform: CloudPlatform, appVersion: String, status: CloudDeviceStatus, secretsApproved: Bool, lastSeenAt: Int64, signPublicJwk: CloudPublicJWK, wrapPublicJwk: CloudPublicJWK, registeredAt: Int64? = nil) {
        self.deviceId = deviceId
        self.label = label
        self.platform = platform
        self.appVersion = appVersion
        self.status = status
        self.secretsApproved = secretsApproved
        self.lastSeenAt = lastSeenAt
        self.signPublicJwk = signPublicJwk
        self.wrapPublicJwk = wrapPublicJwk
        self.registeredAt = registeredAt
    }
}

public struct CloudDeviceRegistration: Codable, Equatable, Sendable {
    public let deviceId: String
    public let label: String
    public let platform: CloudPlatform
    public let appVersion: String
    public let signPublicJwk: CloudPublicJWK
    public let wrapPublicJwk: CloudPublicJWK
    /// Additive (MAC-NEXT-10): an opaque id that is the same for one machine within one account (a hash; never the
    /// hardware id itself), so the service keeps one row per machine. Left out of the body when nil.
    public var machineId: String? = nil
    /// Additive (MAC-NEXT-10): the computer's friendly name (at most 64 characters). Left out of the body when nil.
    public var displayName: String? = nil
    /// Additive (MAC-NEXT-11): the host name this Mac recorded for its registrations (the label it always sent, e.g.
    /// "asads-macbook-pro-21.local"), so the service can match this Mac's older registrations. Left out when nil.
    public var hostName: String? = nil
    public init(deviceId: String, label: String, platform: CloudPlatform, appVersion: String, signPublicJwk: CloudPublicJWK, wrapPublicJwk: CloudPublicJWK) {
        self.deviceId = deviceId
        self.label = label
        self.platform = platform
        self.appVersion = appVersion
        self.signPublicJwk = signPublicJwk
        self.wrapPublicJwk = wrapPublicJwk
    }
}

public struct CloudDeviceRegistrationReceipt: Codable, Equatable, Sendable {
    public let deviceId: String
    public let status: CloudDeviceStatus
    public let secretsApproved: Bool
    public let headSeq: CloudSequence
    public let vaultState: CloudVaultState
    /// Additive (MAC-NEXT-10): the friendly name the service recorded, when it echoes one (proof it took the fields).
    public var displayName: String? = nil
    public init(deviceId: String, status: CloudDeviceStatus, secretsApproved: Bool, headSeq: CloudSequence, vaultState: CloudVaultState) {
        self.deviceId = deviceId
        self.status = status
        self.secretsApproved = secretsApproved
        self.headSeq = headSeq
        self.vaultState = vaultState
    }
}

public struct CloudDeviceList: Codable, Equatable, Sendable {
    public let devices: [CloudDevice]
    public let receiverDeviceId: String?
    /// Additive (MAC-NEXT-7): the feed's newest position when the list was read; nil from an older service.
    public var headSeq: CloudSequence? = nil
    public init(devices: [CloudDevice], receiverDeviceId: String? = nil) {
        self.devices = devices
        self.receiverDeviceId = receiverDeviceId
    }
}

public struct CloudBudgetState: Codable, Equatable, Sendable {
    public let day: String
    public let requestsLeft: Int
    public let writesLeft: Int
    public let bytesLeft: Int64
    public let resumeAt: Int64?
    public init(day: String, requestsLeft: Int, writesLeft: Int, bytesLeft: Int64, resumeAt: Int64? = nil) {
        self.day = day
        self.requestsLeft = requestsLeft
        self.writesLeft = writesLeft
        self.bytesLeft = bytesLeft
        self.resumeAt = resumeAt
    }
}

public struct CloudRemoteState: Codable, Equatable, Sendable {
    public let headSeq: CloudSequence
    public let checkpoint: CloudCheckpoint?
    public let devicesVersion: CloudSequence
    public let vaultState: CloudVaultState
    public let vaultEpoch: Int
    public let vaultVersion: CloudSequence
    public let capabilities: CloudGate
    public let budget: CloudBudgetState
    public init(headSeq: CloudSequence, checkpoint: CloudCheckpoint? = nil, devicesVersion: CloudSequence, vaultState: CloudVaultState, vaultEpoch: Int, vaultVersion: CloudSequence, capabilities: CloudGate, budget: CloudBudgetState) {
        self.headSeq = headSeq
        self.checkpoint = checkpoint
        self.devicesVersion = devicesVersion
        self.vaultState = vaultState
        self.vaultEpoch = vaultEpoch
        self.vaultVersion = vaultVersion
        self.capabilities = capabilities
        self.budget = budget
    }
}

public struct CloudBlobRef: Codable, Equatable, Sendable {
    public let blobId: String
    public let sha256: String
    public let md5: String
    public let bytes: Int64
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    public let keyEpoch: Int
    enum CodingKeys: String, CodingKey {
        case blobId
        case sha256
        case md5
        case bytes
        case storageClass = "class"
        case purpose
        case keyEpoch
    }
    public init(blobId: String, sha256: String, md5: String, bytes: Int64, storageClass: CloudStorageClass, purpose: CloudPurpose, keyEpoch: Int) {
        self.blobId = blobId
        self.sha256 = sha256
        self.md5 = md5
        self.bytes = bytes
        self.storageClass = storageClass
        self.purpose = purpose
        self.keyEpoch = keyEpoch
    }
}

public struct CloudSourceReference: Codable, Equatable, Sendable {
    public let sourceId: String
    public let recordId: String
    public let offset: Int64?
    public let rawHash: String?
    public init(sourceId: String, recordId: String, offset: Int64? = nil, rawHash: String? = nil) {
        self.sourceId = sourceId
        self.recordId = recordId
        self.offset = offset
        self.rawHash = rawHash
    }
}

public struct CloudOperation: Codable, Equatable, Sendable {
    public let v: Int
    public let opId: String
    public let originDevice: String
    public let domain: String
    public let entityId: String
    public let revision: String
    public let parents: [String]
    public let kind: CloudOperationKind
    public let projectId: String?
    public let rootId: String?
    public let source: CloudSourceReference
    public let createdAt: Int64
    public let payload: CloudValue
    public let payloadHash: String
    public init(v: Int, opId: String, originDevice: String, domain: String, entityId: String, revision: String, parents: [String], kind: CloudOperationKind, projectId: String? = nil, rootId: String? = nil, source: CloudSourceReference, createdAt: Int64, payload: CloudValue, payloadHash: String) {
        self.v = v
        self.opId = opId
        self.originDevice = originDevice
        self.domain = domain
        self.entityId = entityId
        self.revision = revision
        self.parents = parents
        self.kind = kind
        self.projectId = projectId
        self.rootId = rootId
        self.source = source
        self.createdAt = createdAt
        self.payload = payload
        self.payloadHash = payloadHash
    }
}

public struct CloudSegmentDescriptor: Codable, Equatable, Sendable {
    public let segmentId: String
    public let requestId: String
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    public let domains: [String]
    public let keyEpoch: Int
    public let sha256: String
    public let bytes: Int64
    public let opCount: Int
    public let format: String
    public let signature: String
    enum CodingKeys: String, CodingKey {
        case segmentId
        case requestId
        case storageClass = "class"
        case purpose
        case domains
        case keyEpoch
        case sha256
        case bytes
        case opCount
        case format
        case signature
    }
    public init(segmentId: String, requestId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, domains: [String], keyEpoch: Int, sha256: String, bytes: Int64, opCount: Int, format: String, signature: String) {
        self.segmentId = segmentId
        self.requestId = requestId
        self.storageClass = storageClass
        self.purpose = purpose
        self.domains = domains
        self.keyEpoch = keyEpoch
        self.sha256 = sha256
        self.bytes = bytes
        self.opCount = opCount
        self.format = format
        self.signature = signature
    }
}

public struct CloudSegment: Codable, Equatable, Sendable {
    public let descriptor: CloudSegmentDescriptor
    public let ciphertext: String
    public init(descriptor: CloudSegmentDescriptor, ciphertext: String) {
        self.descriptor = descriptor
        self.ciphertext = ciphertext
    }
}

public struct CloudCommitReceipt: Codable, Equatable, Sendable {
    public let requestId: String
    public let sha256: String
    public let committedAt: Int64
    public init(requestId: String, sha256: String, committedAt: Int64) {
        self.requestId = requestId
        self.sha256 = sha256
        self.committedAt = committedAt
    }
}

public struct CloudReceipt: Codable, Equatable, Sendable {
    public let segmentId: String
    public let seq: CloudSequence
    public let headSeq: CloudSequence
    public let receipt: CloudCommitReceipt
    public init(segmentId: String, seq: CloudSequence, headSeq: CloudSequence, receipt: CloudCommitReceipt) {
        self.segmentId = segmentId
        self.seq = seq
        self.headSeq = headSeq
        self.receipt = receipt
    }
}

public struct CloudChangeEntry: Codable, Equatable, Sendable {
    public let seq: CloudSequence
    public let storageClass: CloudStorageClass
    public let locked: Bool?
    public let segmentId: String?
    public let requestId: String?
    public let purpose: CloudPurpose?
    public let domains: [String]?
    public let keyEpoch: Int?
    public let sha256: String?
    public let bytes: Int64?
    public let opCount: Int?
    public let format: String?
    public let signature: String?
    public let deviceId: String?
    public let createdAt: Int64?
    public let getUrl: URL?
    public let expiresAt: Int64?
    enum CodingKeys: String, CodingKey {
        case seq
        case storageClass = "class"
        case locked
        case segmentId
        case requestId
        case purpose
        case domains
        case keyEpoch
        case sha256
        case bytes
        case opCount
        case format
        case signature
        case deviceId
        case createdAt
        case getUrl
        case expiresAt
    }
    public init(seq: CloudSequence, storageClass: CloudStorageClass, locked: Bool? = nil, segmentId: String? = nil, requestId: String? = nil, purpose: CloudPurpose? = nil, domains: [String]? = nil, keyEpoch: Int? = nil, sha256: String? = nil, bytes: Int64? = nil, opCount: Int? = nil, format: String? = nil, signature: String? = nil, deviceId: String? = nil, createdAt: Int64? = nil, getUrl: URL? = nil, expiresAt: Int64? = nil) {
        self.seq = seq
        self.storageClass = storageClass
        self.locked = locked
        self.segmentId = segmentId
        self.requestId = requestId
        self.purpose = purpose
        self.domains = domains
        self.keyEpoch = keyEpoch
        self.sha256 = sha256
        self.bytes = bytes
        self.opCount = opCount
        self.format = format
        self.signature = signature
        self.deviceId = deviceId
        self.createdAt = createdAt
        self.getUrl = getUrl
        self.expiresAt = expiresAt
    }
}

public struct CloudChangePage: Codable, Equatable, Sendable {
    public let segments: [CloudChangeEntry]
    public let headSeq: CloudSequence
    public let nextAfter: CloudSequence
    public let hasMore: Bool
    public init(segments: [CloudChangeEntry], headSeq: CloudSequence, nextAfter: CloudSequence, hasMore: Bool) {
        self.segments = segments
        self.headSeq = headSeq
        self.nextAfter = nextAfter
        self.hasMore = hasMore
    }
}

public struct CloudCounts: Codable, Equatable, Sendable {
    public let domains: Int
    public let records: Int
    public let files: Int
    public let bytes: Int64
    public let blocked: Int
    public init(domains: Int, records: Int, files: Int, bytes: Int64, blocked: Int) {
        self.domains = domains
        self.records = records
        self.files = files
        self.bytes = bytes
        self.blocked = blocked
    }
}

public struct CloudCheckpoint: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let throughSeq: CloudSequence
    public let root: CloudBlobRef
    public let secretsRoot: CloudBlobRef?
    public let inventoryDigest: String
    public let counts: CloudCounts
    public let verifiedBy: [String]
    public init(checkpointId: String, throughSeq: CloudSequence, root: CloudBlobRef, secretsRoot: CloudBlobRef? = nil, inventoryDigest: String, counts: CloudCounts, verifiedBy: [String]) {
        self.checkpointId = checkpointId
        self.throughSeq = throughSeq
        self.root = root
        self.secretsRoot = secretsRoot
        self.inventoryDigest = inventoryDigest
        self.counts = counts
        self.verifiedBy = verifiedBy
    }
}

public struct CloudCheckpointRequest: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let throughSeq: CloudSequence
    public let root: CloudBlobRef
    public let secretsRoot: CloudBlobRef?
    public let inventoryDigest: String
    public let counts: CloudCounts
    public let parentCheckpointId: String?
    public init(checkpointId: String, throughSeq: CloudSequence, root: CloudBlobRef, secretsRoot: CloudBlobRef? = nil, inventoryDigest: String, counts: CloudCounts, parentCheckpointId: String? = nil) {
        self.checkpointId = checkpointId
        self.throughSeq = throughSeq
        self.root = root
        self.secretsRoot = secretsRoot
        self.inventoryDigest = inventoryDigest
        self.counts = counts
        self.parentCheckpointId = parentCheckpointId
    }
}

public struct CloudCheckpointReceipt: Codable, Equatable, Sendable {
    public let checkpointId: String
    public let throughSeq: CloudSequence
    public let verifiedBy: [String]
    public let published: Bool
    public init(checkpointId: String, throughSeq: CloudSequence, verifiedBy: [String], published: Bool) {
        self.checkpointId = checkpointId
        self.throughSeq = throughSeq
        self.verifiedBy = verifiedBy
        self.published = published
    }
}

public struct CloudBlobUpload: Codable, Equatable, Sendable {
    public let uploadId: String
    public let blobId: String
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    public let keyEpoch: Int
    public let bytes: Int64
    public let sha256: String
    public let md5: String
    enum CodingKeys: String, CodingKey {
        case uploadId
        case blobId
        case storageClass = "class"
        case purpose
        case keyEpoch
        case bytes
        case sha256
        case md5
    }
    public init(uploadId: String, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, keyEpoch: Int, bytes: Int64, sha256: String, md5: String) {
        self.uploadId = uploadId
        self.blobId = blobId
        self.storageClass = storageClass
        self.purpose = purpose
        self.keyEpoch = keyEpoch
        self.bytes = bytes
        self.sha256 = sha256
        self.md5 = md5
    }
}

public struct CloudBlobTicket: Codable, Equatable, Sendable {
    public let uploadId: String
    public let blobId: String
    public let putUrl: URL?
    public let headers: [String:String]
    public let ticket: String
    public let expiresAt: Int64
    public let alreadyPresent: Bool
    public init(uploadId: String, blobId: String, putUrl: URL? = nil, headers: [String:String], ticket: String, expiresAt: Int64, alreadyPresent: Bool) {
        self.uploadId = uploadId
        self.blobId = blobId
        self.putUrl = putUrl
        self.headers = headers
        self.ticket = ticket
        self.expiresAt = expiresAt
        self.alreadyPresent = alreadyPresent
    }
}

public struct CloudBlobFinalize: Codable, Equatable, Sendable {
    public let uploadId: String
    public let blobId: String
    public let ticket: String
    public init(uploadId: String, blobId: String, ticket: String) {
        self.uploadId = uploadId
        self.blobId = blobId
        self.ticket = ticket
    }
}

public struct CloudBlobResult: Codable, Equatable, Sendable {
    public let uploadId: String
    public let blob: CloudBlobRef?
    public let error: CloudBlobError?
    public init(uploadId: String, blob: CloudBlobRef? = nil, error: CloudBlobError? = nil) {
        self.uploadId = uploadId
        self.blob = blob
        self.error = error
    }
}

public struct CloudBlobError: Codable, Equatable, Sendable {
    public let code: String
    public let retryable: Bool
    public init(code: String, retryable: Bool) {
        self.code = code
        self.retryable = retryable
    }
}

public struct CloudBlobDownload: Codable, Equatable, Sendable {
    public let blob: CloudBlobRef
    public let getUrl: URL
    public let expiresAt: Int64
    public init(blob: CloudBlobRef, getUrl: URL, expiresAt: Int64) {
        self.blob = blob
        self.getUrl = getUrl
        self.expiresAt = expiresAt
    }
}

public struct CloudAppliedReceipt: Codable, Equatable, Sendable {
    public let brainSeq: CloudSequence
    public let secretsSeq: CloudSequence
    public init(brainSeq: CloudSequence, secretsSeq: CloudSequence) {
        self.brainSeq = brainSeq
        self.secretsSeq = secretsSeq
    }
}

public struct CloudLeaseRequest: Codable, Equatable, Sendable {
    public let resourceId: String
    public let expectedGeneration: CloudSequence
    public let ttlSeconds: Int
    public init(resourceId: String, expectedGeneration: CloudSequence, ttlSeconds: Int) {
        self.resourceId = resourceId
        self.expectedGeneration = expectedGeneration
        self.ttlSeconds = ttlSeconds
    }
}

public struct CloudLease: Codable, Equatable, Sendable {
    public let resourceId: String
    public let generation: CloudSequence
    public let until: Int64
    public let deviceId: String
    public init(resourceId: String, generation: CloudSequence, until: Int64, deviceId: String) {
        self.resourceId = resourceId
        self.generation = generation
        self.until = until
        self.deviceId = deviceId
    }
}

public struct CloudEvent: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String
    public let id: String
    public let payload: CloudValue
    public init(v: Int, type: String, id: String, payload: CloudValue) {
        self.v = v
        self.type = type
        self.id = id
        self.payload = payload
    }
}

public struct CloudCoverage: Codable, Equatable, Sendable {
    public let sourceId: String
    public let inventoryRow: String
    public let complete: Bool
    public let items: Int
    public let bytes: Int64
    /// GAPS: something of this source is not (yet) in Cloud. Any gap makes the source incomplete.
    public let blockedReasons: [String]
    /// INTENTIONAL EXCLUSIONS (SYNC contract addition): left out on purpose, reported only. Never makes the
    /// source incomplete and never blocks readiness. Absent in older encodings means none.
    public let exclusions: [String]
    public init(sourceId: String, inventoryRow: String, complete: Bool, items: Int, bytes: Int64, blockedReasons: [String], exclusions: [String] = []) {
        self.sourceId = sourceId
        self.inventoryRow = inventoryRow
        self.complete = complete
        self.items = items
        self.bytes = bytes
        self.blockedReasons = blockedReasons
        self.exclusions = exclusions
    }
    private enum CodingKeys: String, CodingKey { case sourceId, inventoryRow, complete, items, bytes, blockedReasons, exclusions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(String.self, forKey: .sourceId)
        inventoryRow = try c.decode(String.self, forKey: .inventoryRow)
        complete = try c.decode(Bool.self, forKey: .complete)
        items = try c.decode(Int.self, forKey: .items)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        blockedReasons = try c.decode([String].self, forKey: .blockedReasons)
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    }
}

public struct CloudSourceInventory: Codable, Equatable, Sendable {
    public let sourceId: String
    public let inventoryRow: String
    public let domain: String
    public let items: Int
    public let bytes: Int64
    public let complete: Bool
    /// GAPS, as on CloudCoverage.
    public let blockedReasons: [String]
    /// INTENTIONAL EXCLUSIONS, as on CloudCoverage: reported only, never a gap. Absent in older encodings means none.
    public let exclusions: [String]
    public init(sourceId: String, inventoryRow: String, domain: String, items: Int, bytes: Int64, complete: Bool, blockedReasons: [String], exclusions: [String] = []) {
        self.sourceId = sourceId
        self.inventoryRow = inventoryRow
        self.domain = domain
        self.items = items
        self.bytes = bytes
        self.complete = complete
        self.blockedReasons = blockedReasons
        self.exclusions = exclusions
    }
    private enum CodingKeys: String, CodingKey { case sourceId, inventoryRow, domain, items, bytes, complete, blockedReasons, exclusions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(String.self, forKey: .sourceId)
        inventoryRow = try c.decode(String.self, forKey: .inventoryRow)
        domain = try c.decode(String.self, forKey: .domain)
        items = try c.decode(Int.self, forKey: .items)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        complete = try c.decode(Bool.self, forKey: .complete)
        blockedReasons = try c.decode([String].self, forKey: .blockedReasons)
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
    }
}

public struct CloudSnapshotCut: Codable, Equatable, Sendable {
    public let snapshotId: String
    public let at: Int64
    public let watermarks: [String:String]
    public init(snapshotId: String, at: Int64, watermarks: [String:String]) {
        self.snapshotId = snapshotId
        self.at = at
        self.watermarks = watermarks
    }
}

public struct CloudLocalBlob: Codable, Equatable, Sendable {
    public let blobId: String
    public let sourceId: String
    public let localURL: URL
    public let bytes: Int64
    public let sha256: String
    public let md5: String
    public let keyEpoch: Int
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    enum CodingKeys: String, CodingKey {
        case blobId
        case sourceId
        case localURL
        case bytes
        case sha256
        case md5
        case keyEpoch
        case storageClass = "class"
        case purpose
    }
    public init(blobId: String, sourceId: String, localURL: URL, bytes: Int64, sha256: String, md5: String, keyEpoch: Int, storageClass: CloudStorageClass, purpose: CloudPurpose) {
        self.blobId = blobId
        self.sourceId = sourceId
        self.localURL = localURL
        self.bytes = bytes
        self.sha256 = sha256
        self.md5 = md5
        self.keyEpoch = keyEpoch
        self.storageClass = storageClass
        self.purpose = purpose
    }
    /// localURL holds canonical, already-sealed CloudContentEnvelope bytes only.
    /// Operations embed this exact reference before enqueue; SYNC never rewrites or re-seals it.
    public var reference: CloudBlobRef {
        .init(blobId: blobId, sha256: sha256, md5: md5, bytes: bytes, storageClass: storageClass, purpose: purpose, keyEpoch: keyEpoch)
    }
}

/// Local-only link from one operation to the sealed files it names (SPEC CORRECTION from SYNC, 12:28). Never a wire field.
public struct CloudFileAssociation: Codable, Equatable, Sendable {
    public let operationId: String
    public let blobIds: [String]
    public init(operationId: String, blobIds: [String]) { self.operationId = operationId; self.blobIds = blobIds }
}

public struct CloudDomainSnapshot: Codable, Equatable, Sendable {
    public let cut: CloudSnapshotCut
    public let operations: [CloudOperation]
    public let files: [CloudLocalBlob]
    public let coverage: [CloudCoverage]
    /// Local-only; absent in older encodings means none.
    public let associations: [CloudFileAssociation]
    public init(cut: CloudSnapshotCut, operations: [CloudOperation], files: [CloudLocalBlob], coverage: [CloudCoverage], associations: [CloudFileAssociation] = []) {
        self.cut = cut
        self.operations = operations
        self.files = files
        self.coverage = coverage
        self.associations = associations
    }
    private enum CodingKeys: String, CodingKey { case cut, operations, files, coverage, associations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cut = try c.decode(CloudSnapshotCut.self, forKey: .cut)
        operations = try c.decode([CloudOperation].self, forKey: .operations)
        files = try c.decode([CloudLocalBlob].self, forKey: .files)
        coverage = try c.decode([CloudCoverage].self, forKey: .coverage)
        associations = try c.decodeIfPresent([CloudFileAssociation].self, forKey: .associations) ?? []
    }
}

public struct CloudLocalReceipt: Codable, Equatable, Sendable {
    public let operationIds: [String]
    public let queued: Int
    public let bytes: Int64
    public let savedAt: Int64
    public init(operationIds: [String], queued: Int, bytes: Int64, savedAt: Int64) {
        self.operationIds = operationIds
        self.queued = queued
        self.bytes = bytes
        self.savedAt = savedAt
    }
}

public struct CloudPreparedImport: Codable, Equatable, Sendable {
    public let preparationId: String
    public let operations: [CloudOperation]
    public let files: [CloudLocalBlob]
    public init(preparationId: String, operations: [CloudOperation], files: [CloudLocalBlob]) {
        self.preparationId = preparationId
        self.operations = operations
        self.files = files
    }
}

public struct CloudImportOrigin: Codable, Equatable, Sendable {
    public let deviceId: String
    public let sequence: CloudSequence
    /// SYNC contract addition: when the service accepted the pack carrying these records (milliseconds since
    /// 1970, as the service reported it). Use it only to cap a version's own creation time when choosing which of
    /// two concurrent values to SHOW; never to decide which version survives (both always do). nil when the
    /// records came from an inventory (checkpoint) rather than the feed. Absent in older encodings means nil.
    public let committedAt: Int64?
    /// SYNC contract addition (device trust). Under the trusted list `deviceId` is the VERIFIED signer of the
    /// pack (the device whose stored key its signature checks under), never a field inside the pack: an
    /// operation's `originDevice` is "first written on", display text only. `late` is true when the pack is
    /// applied out of feed order: by a release after the person trusted its device, or by "check again" on a
    /// refused pack. `sequence` and `committedAt` are then still the pack's ORIGINAL position and commit time.
    /// An adapter given `late` orders by parents and treats nothing in it as a new event. Absent means false.
    public let late: Bool?
    public init(deviceId: String, sequence: CloudSequence, committedAt: Int64? = nil, late: Bool? = nil) {
        self.deviceId = deviceId
        self.sequence = sequence
        self.committedAt = committedAt
        self.late = late
    }
    private enum CodingKeys: String, CodingKey { case deviceId, sequence, committedAt, late }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        sequence = try c.decode(CloudSequence.self, forKey: .sequence)
        committedAt = try c.decodeIfPresent(Int64.self, forKey: .committedAt)
        late = try c.decodeIfPresent(Bool.self, forKey: .late)
    }
}

// MARK: Device trust (SYNC contract additions, lean first version; cloud-device-trust-design.md revision 2)

/// What this Mac decides about one incoming pack, before anything of it is downloaded or opened.
public enum CloudPackVerdict: Equatable, Sendable {
    /// The pack's signature checks under the key this Mac's own trusted list stores for `signer`.
    case apply(signer: String)
    /// The device the service names for the pack is not trusted on this Mac (unknown, or stopped). The pack
    /// waits untouched; the feed goes on.
    case held
    /// The pack cannot be the work of the trusted device it is attributed to, or it repeats or contradicts a pack
    /// this Mac already applied. `reason` is one of CloudPackVerdict.noDevice, .malformed, .badSignature, or the
    /// sync core's "repeated-pack", "pack-id-reused", "position-reused". Recorded and reported; the feed goes on.
    /// A stored key that cannot be READ is not a refusal: that device's packs wait (`held`) until the key is right.
    case refused(reason: String)
    public static let noDevice = "no-device"
    public static let malformed = "malformed"
    public static let badKey = "bad-key"
    public static let badSignature = "bad-signature"
}

/// This Mac's OWN stored trusted list as the sync core reads it. Lane A's wiring implements it over the list it
/// keeps on this Mac. The sync core asks at the moment of applying, for every pack; it stores no trust itself.
public protocol CloudDeviceTrustPort: Sendable {
    /// The signing key stored on this Mac for `deviceId`, only while that entry is trusted. nil for a device that
    /// is not on the list, for a stopped one, and when the list cannot be read (its packs then wait: fail safe).
    /// This Mac's own identities are on the list too (a pack is "own" only if it checks under such a key).
    /// The answer must come from this Mac's stored list alone, never from the service.
    func trustedSigningKey(deviceId: String) async -> CloudPublicJWK?
}

/// Per kind of content, what one waiting device has sent, as the service's feed entries report it (not verified).
public struct CloudHeldDomainCount: Codable, Equatable, Sendable {
    public let domain: String
    public let packs: Int
    public let operations: Int
    public init(domain: String, packs: Int, operations: Int) {
        self.domain = domain
        self.packs = packs
        self.operations = operations
    }
}

/// One device whose packs wait on this Mac because the person has not trusted it here. Nothing of those packs
/// was downloaded, opened, merged or shown to an adapter. Counts are for the screen only ("reported").
public struct CloudHeldDevice: Codable, Equatable, Sendable {
    public let deviceId: String
    /// Feed position of its first waiting memory pack; nil if only saved-password packs wait.
    public let firstHeldSeq: CloudSequence?
    /// Feed position of its first waiting saved-password pack; nil if none waits.
    public let firstHeldSecretsSeq: CloudSequence?
    public let packs: Int
    public let operations: Int
    public let byDomain: [CloudHeldDomainCount]
    /// This Mac's clock (milliseconds since 1970) when it first met a pack of this device.
    public let firstSeenAt: Int64
    /// True while this Mac has not read the feed to the last head it knows: the counts may still grow.
    public let counting: Bool
    public init(deviceId: String, firstHeldSeq: CloudSequence?, firstHeldSecretsSeq: CloudSequence?, packs: Int, operations: Int,
                byDomain: [CloudHeldDomainCount], firstSeenAt: Int64, counting: Bool) {
        self.deviceId = deviceId
        self.firstHeldSeq = firstHeldSeq
        self.firstHeldSecretsSeq = firstHeldSecretsSeq
        self.packs = packs
        self.operations = operations
        self.byDomain = byDomain
        self.firstSeenAt = firstSeenAt
        self.counting = counting
    }
}

/// SYNC contract addition: how far this Mac's own baseline (what setup queued) has gone up. Setup returns as soon
/// as every page is stored on this Mac; the records then travel as ordinary packs, and the upload continues by
/// itself after a pause (a slow-down) or a restart. Until it is finished the sources read "not complete".
public struct CloudBaselineProgress: Codable, Equatable, Sendable {
    /// Memory records setup queued, and how many of them the Cloud holds now.
    public let total: Int
    public let sent: Int
    /// Setup files still to go up.
    public let filesWaiting: Int
    /// When sending resumes by itself (milliseconds since 1970), if it is paused now.
    public let waitingUntil: Int64?
    /// Why it is paused, in words for the page; nil while it is running.
    public let reason: String?
    /// Mac-next 2: true while the first copy is still being prepared on this Mac (nothing sent yet); `sent` then
    /// counts the records prepared so far and `total` those the cut holds.
    public let preparing: Bool?
    public init(total: Int, sent: Int, filesWaiting: Int, waitingUntil: Int64?, reason: String?, preparing: Bool? = nil) {
        self.preparing = preparing
        self.total = total
        self.sent = sent
        self.filesWaiting = filesWaiting
        self.waitingUntil = waitingUntil
        self.reason = reason
    }
}

/// One pack this Mac refused (see CloudPackVerdict.refused). Nothing of it was fetched or applied.
public struct CloudRefusedPack: Codable, Equatable, Sendable {
    public let sequence: CloudSequence
    public let storageClass: CloudStorageClass
    /// The device the service named for the pack, if it named one.
    public let deviceId: String?
    public let reason: String
    public let firstAt: Int64
    /// How often the position was judged (1 = only when first met).
    public let checks: Int
    public init(sequence: CloudSequence, storageClass: CloudStorageClass, deviceId: String?, reason: String, firstAt: Int64, checks: Int) {
        self.sequence = sequence
        self.storageClass = storageClass
        self.deviceId = deviceId
        self.reason = reason
        self.firstAt = firstAt
        self.checks = checks
    }
}

/// SYNC contract addition: a record's read-back cloud receipt. Exists only after the pack carrying the record
/// was committed AND read back byte-for-byte (own records), or applied from the feed (other devices' records).
public struct CloudOperationReceipt: Codable, Equatable, Sendable {
    public let operationId: String
    public let sequence: CloudSequence
    /// The service's commit time of the carrying pack (see CloudImportOrigin.committedAt); nil if unknown.
    public let committedAt: Int64?
    public init(operationId: String, sequence: CloudSequence, committedAt: Int64?) {
        self.operationId = operationId
        self.sequence = sequence
        self.committedAt = committedAt
    }
}

/// SYNC contract addition (round 6 S6): a saved-password record retired on this Mac because it was sealed with an
/// older saved-password key (another device started new saved passwords). It was never uploaded and no device can
/// open it, so it may be the only copy of that change. It stays a GAP on its source, and its files stay on this
/// Mac, until its owner (lane V) re-saves the item under the new key or confirms it is no longer needed.
public struct CloudRetiredRecord: Codable, Equatable, Sendable {
    public let operationId: String
    public let domain: String
    public let sourceId: String
    /// The record's own id in its source (`CloudOperation.source.recordId`).
    public let recordId: String
    public let keyEpoch: Int
    public let reason: String
    public let retiredAt: Int64
    public init(operationId: String, domain: String, sourceId: String, recordId: String, keyEpoch: Int, reason: String, retiredAt: Int64) {
        self.operationId = operationId
        self.domain = domain
        self.sourceId = sourceId
        self.recordId = recordId
        self.keyEpoch = keyEpoch
        self.reason = reason
        self.retiredAt = retiredAt
    }
}

/// SYNC contract addition: thrown by `enqueue` for a record whose domain breaks CloudWire.domainNamePattern.
/// Nothing of the batch is queued.
public struct CloudDomainNameInvalid: Error, Equatable, Sendable {
    public let domain: String
    public init(domain: String) { self.domain = domain }
}

/// SYNC contract addition: thrown by `enqueue` for a record larger than CloudWire.maximumRecordPayloadBytes /
/// maximumRecordBytes. Nothing of the batch is queued.
public struct CloudRecordTooLarge: Error, Equatable, Sendable {
    public let operationId: String
    public let bytes: Int
    public let limit: Int
    public init(operationId: String, bytes: Int, limit: Int) {
        self.operationId = operationId
        self.bytes = bytes
        self.limit = limit
    }
}

/// SYNC contract addition (poison record). Thrown by `CloudDomainAdapter.validateIncoming` or `applyPrepared` to say
/// "these records cannot be applied here" (invalid for this Mac, unsupported, conflicting): the outbox re-applies the
/// pack one record at a time, durably parks each record that is still refused with `reason`, keeps later versions of
/// the same record waiting behind it, applies everything else and advances the feed. Empty `operationIds` means
/// every record passed in that call. Any OTHER error means "this adapter is broken or shutting down": nothing is
/// parked and the whole pack is retried later, as before. An item result with status `.blocked` and a `reason`
/// has the same meaning as this refusal for that entity.
public struct CloudRecordRefusal: Error, Equatable, Sendable {
    public let operationIds: [String]
    public let reason: String
    public init(operationIds: [String] = [], reason: String) {
        self.operationIds = operationIds
        self.reason = reason
    }
}

public struct CloudItemResult: Codable, Equatable, Sendable {
    public let entityId: String
    public let status: CloudApplyStatus
    public let reason: String?
    public init(entityId: String, status: CloudApplyStatus, reason: String? = nil) {
        self.entityId = entityId
        self.status = status
        self.reason = reason
    }
}

public struct CloudImportReceipt: Codable, Equatable, Sendable {
    public let preparationId: String
    public let inventoryRow: String
    public let results: [CloudItemResult]
    public let counts: CloudCounts
    public init(preparationId: String, inventoryRow: String, results: [CloudItemResult], counts: CloudCounts) {
        self.preparationId = preparationId
        self.inventoryRow = inventoryRow
        self.results = results
        self.counts = counts
    }
}

public struct CloudVerification: Codable, Equatable, Sendable {
    public let verified: Bool
    public let counts: CloudCounts
    public let reasons: [String]
    public init(verified: Bool, counts: CloudCounts, reasons: [String]) {
        self.verified = verified
        self.counts = counts
        self.reasons = reasons
    }
}

public struct CloudRestoreProgress: Codable, Equatable, Sendable {
    public let queued: Int
    public let applied: Int
    public let blocked: Int
    public let brainSeq: CloudSequence
    public let secretsSeq: CloudSequence
    public let coverage: [CloudCoverage]
    public init(queued: Int, applied: Int, blocked: Int, brainSeq: CloudSequence, secretsSeq: CloudSequence, coverage: [CloudCoverage]) {
        self.queued = queued
        self.applied = applied
        self.blocked = blocked
        self.brainSeq = brainSeq
        self.secretsSeq = secretsSeq
        self.coverage = coverage
    }
}

public struct CloudContextReady: Codable, Equatable, Sendable {
    public let projectId: String
    public let throughSeq: CloudSequence
    public let sourceCounts: CloudCounts
    public let verified: Bool
    public let missingSources: [String]
    public init(projectId: String, throughSeq: CloudSequence, sourceCounts: CloudCounts, verified: Bool, missingSources: [String]) {
        self.projectId = projectId
        self.throughSeq = throughSeq
        self.sourceCounts = sourceCounts
        self.verified = verified
        self.missingSources = missingSources
    }
}

public struct CloudPathMap: Codable, Equatable, Sendable {
    public let v: Int
    public let deviceId: String
    public let projectId: String
    public let rootId: String
    public let logicalRoot: String
    public let localAbsolutePath: String
    public let canonicalPath: String
    public let aliases: [String]
    public let providerHomes: [String:String]
    public let updatedAt: Int64
    public init(v: Int, deviceId: String, projectId: String, rootId: String, logicalRoot: String, localAbsolutePath: String, canonicalPath: String, aliases: [String], providerHomes: [String:String], updatedAt: Int64) {
        self.v = v
        self.deviceId = deviceId
        self.projectId = projectId
        self.rootId = rootId
        self.logicalRoot = logicalRoot
        self.localAbsolutePath = localAbsolutePath
        self.canonicalPath = canonicalPath
        self.aliases = aliases
        self.providerHomes = providerHomes
        self.updatedAt = updatedAt
    }
}

public struct CloudPathPlan: Codable, Equatable, Sendable {
    public let planId: String
    public let projectId: String
    public let rootId: String
    public let destination: String
    public let digest: String
    public let conflicts: [String]
    public init(planId: String, projectId: String, rootId: String, destination: String, digest: String, conflicts: [String]) {
        self.planId = planId
        self.projectId = projectId
        self.rootId = rootId
        self.destination = destination
        self.digest = digest
        self.conflicts = conflicts
    }
}

public struct CloudDeviceKeyEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let epoch: Int
    public let targetDeviceId: String
    public let ephemeralPublicJwk: CloudPublicJWK
    public let salt: String
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    public let authorDeviceId: String
    public let signature: String
    public init(v: Int, epoch: Int, targetDeviceId: String, ephemeralPublicJwk: CloudPublicJWK, salt: String, nonce: String, ciphertext: String, tag: String, authorDeviceId: String, signature: String) {
        self.v = v
        self.epoch = epoch
        self.targetDeviceId = targetDeviceId
        self.ephemeralPublicJwk = ephemeralPublicJwk
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.authorDeviceId = authorDeviceId
        self.signature = signature
    }
}

public struct CloudRecoveryEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let version: CloudSequence
    public let epoch: Int
    public let suite: String
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    public let publicSigningJwk: CloudPublicJWK
    public init(v: Int, version: CloudSequence, epoch: Int, suite: String, nonce: String, ciphertext: String, tag: String, publicSigningJwk: CloudPublicJWK) {
        self.v = v
        self.version = version
        self.epoch = epoch
        self.suite = suite
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.publicSigningJwk = publicSigningJwk
    }
}

public struct CloudApproval: Codable, Equatable, Sendable {
    public let approvalId: String
    public let targetDeviceId: String
    public let targetKeyHash: String
    public let challenge: String
    public let expiresAt: Int64
    public init(approvalId: String, targetDeviceId: String, targetKeyHash: String, challenge: String, expiresAt: Int64) {
        self.approvalId = approvalId
        self.targetDeviceId = targetDeviceId
        self.targetKeyHash = targetKeyHash
        self.challenge = challenge
        self.expiresAt = expiresAt
    }
}

public struct CloudSecretsStatus: Codable, Equatable, Sendable {
    public let state: CloudVaultState
    public let epoch: Int
    public let version: CloudSequence
    public let recoveryReady: Bool
    public let approvedDeviceCount: Int
    public let pendingApprovals: [CloudApproval]
    public init(state: CloudVaultState, epoch: Int, version: CloudSequence, recoveryReady: Bool, approvedDeviceCount: Int, pendingApprovals: [CloudApproval]) {
        self.state = state
        self.epoch = epoch
        self.version = version
        self.recoveryReady = recoveryReady
        self.approvedDeviceCount = approvedDeviceCount
        self.pendingApprovals = pendingApprovals
    }
}

public struct CloudSecretRecord: Codable, Equatable, Sendable {
    public let sourceId: String
    public let recordId: String
    public let domain: String
    public let payload: CloudValue
    public init(sourceId: String, recordId: String, domain: String, payload: CloudValue) {
        self.sourceId = sourceId
        self.recordId = recordId
        self.domain = domain
        self.payload = payload
    }
}

public struct CloudContentEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let suite: String
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    public let epoch: Int
    public let blobId: String
    public let codec: CloudContentCodec
    public let plainBytes: Int64
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    enum CodingKeys: String, CodingKey {
        case v
        case suite
        case storageClass = "class"
        case purpose
        case epoch
        case blobId
        case codec
        case plainBytes
        case nonce
        case ciphertext
        case tag
    }
    public init(v: Int, suite: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, blobId: String, codec: CloudContentCodec, plainBytes: Int64, nonce: String, ciphertext: String, tag: String) {
        self.v = v
        self.suite = suite
        self.storageClass = storageClass
        self.purpose = purpose
        self.epoch = epoch
        self.blobId = blobId
        self.codec = codec
        self.plainBytes = plainBytes
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public struct CloudContentState: Codable, Equatable, Sendable {
    public let available: Bool
    public let epoch: Int
    public let reason: String?
    public init(available: Bool, epoch: Int, reason: String? = nil) {
        self.available = available
        self.epoch = epoch
        self.reason = reason
    }
}

public struct CloudSecretClassification: Codable, Equatable, Sendable {
    public let storageClass: CloudStorageClass
    public let purpose: CloudPurpose
    public let rule: String
    enum CodingKeys: String, CodingKey {
        case storageClass = "class"
        case purpose
        case rule
    }
    public init(storageClass: CloudStorageClass, purpose: CloudPurpose, rule: String) {
        self.storageClass = storageClass
        self.purpose = purpose
        self.rule = rule
    }
}

public struct CloudToolDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let inputSchema: CloudValue
    public let mutates: Bool
    public let inventoryRows: [String]
    public init(id: String, title: String, description: String, inputSchema: CloudValue, mutates: Bool, inventoryRows: [String]) {
        self.id = id
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.mutates = mutates
        self.inventoryRows = inventoryRows
    }
}

public struct CloudFeatureContribution: Codable, Equatable, Sendable {
    public let owner: String
    public let tools: [CloudToolDefinition]
    public let inventoryRows: [String]
    public let actions: [String]
    public init(owner: String, tools: [CloudToolDefinition], inventoryRows: [String], actions: [String]) {
        self.owner = owner
        self.tools = tools
        self.inventoryRows = inventoryRows
        self.actions = actions
    }
}

public extension CloudGate {
    static let closed = CloudGate(features: [])
    /// The server's explicit decision alone (N3): no clock involved. The account keeps the last explicit decision.
    var entitlesCloud: Bool { features.contains("cloud") && storageEntitled == true }
    func permitsCloud(at milliseconds: Int64) -> Bool {
        guard features.contains("cloud"), storageEntitled == true, let expiresAt,
              expiresAt > milliseconds, expiresAt <= milliseconds + 300_000 else { return false }
        return true
    }
}

/// No default implementation opens a network connection or creates a store.
public protocol CloudTransportPort: Sendable {
    func capabilities() async throws -> CloudGate
    func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt
    func devices() async throws -> CloudDeviceList
    func state() async throws -> CloudRemoteState
    func commit(_ segment: CloudSegment) async throws -> CloudReceipt
    func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage
    func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket]
    func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult]
    func readBlobs(ids: [String]) async throws -> [CloudBlobDownload]
    func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt
    func checkpoint() async throws -> CloudCheckpoint?
    func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String]
    func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt
    func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease
    func releaseLease(resourceId: String, generation: CloudSequence) async throws
    func events() async -> AsyncThrowingStream<CloudEvent, Error>
    func stop() async
    /// MAC-NEXT-7 (5): the sync core's retry back-offs (a failed step, a dropped event stream) wait here, on the same
    /// clock as the transport's request pacing: real time in the app, shortened by fixture transports so tests never
    /// wait on the real clock. A requirement, so the engine reaches each transport's own version.
    func backoff(milliseconds: Int64) async throws
}
public extension CloudTransportPort {
    func backoff(milliseconds: Int64) async throws { try await Task.sleep(for: .milliseconds(max(1, milliseconds))) }
}

public protocol CloudOutboxPort: Sendable {
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt
    /// Names which sealed files belong to which operation, so a protected multi-record batch is attributable.
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation]) async throws -> CloudLocalReceipt
    func coverage(sourceId: String) async throws -> CloudCoverage
    func flush() async throws -> [CloudReceipt]
    func restoreProgress() async throws -> CloudRestoreProgress
    func contextReady(projectId: String) async throws -> CloudContextReady
    func register(adapter: any CloudDomainAdapter) async throws
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt
    func pull() async throws -> [CloudImportReceipt]
    func setPaused(_ paused: Bool) async throws
    /// X3 / MAC-NEXT-7 (2): a REQUIREMENT, so a caller holding `any CloudOutboxPort` reaches the engine's own version
    /// ("starting up", not a pause by the person). Outboxes without the distinction get the extension's default.
    func holdForStartup() async throws
    /// SYNC contract addition. Only lane A's account wiring may call this, never an adapter and never automatically.
    /// Discards a first setup that has not published a checkpoint, so a NEW snapshot id may be used. Keeps every
    /// queued record, retained file and local receipt; refused (`versionChanged`) once a checkpoint was published or
    /// imported for this account. Adapters must keep stable record ids across the old and the new cut.
    func abandonUnpublishedSetup() async throws
    /// SYNC contract addition. An adapter (or its owner) reports that it changed in a way that may let records it
    /// refused earlier apply now; parked records of these domains are retried soon. Empty means all domains.
    func retryParked(domains: Set<String>) async throws
    /// SYNC contract addition: the read-back cloud receipt of a record, or nil while it is not yet acknowledged
    /// (queued, in flight, held or parked). An adapter writes its own "already uploaded" mark only from this.
    func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt?
    /// SYNC contract addition: a stable identity of this account's local outbox (queue and receipts). It changes
    /// only if the outbox was lost or rebuilt; an adapter that keeps its own "uploaded" marks compares it.
    func outboxIdentity() async throws -> String
    /// SYNC contract addition: NARROW readiness for Continue and the context barrier: this project's named
    /// sources only. Each must be complete (intentional exclusions allowed) with nothing of this project queued,
    /// held or parked; unrelated or not-yet-built sources do not block.
    func contextReady(projectId: String, sources: Set<String>) async throws -> CloudContextReady
    /// SYNC contract addition: the service's time as best this Mac knows it (milliseconds since 1970): this Mac's
    /// clock plus the offset learned from authenticated service answers. nil until any answer was received (fall
    /// back to the local clock). Never blocks. Authors stamp their versions with it; the stamp is final.
    func serviceTime() -> Int64?
    /// SYNC contract addition (round 6 S6): saved-password records retired here (older key), oldest first, until
    /// confirmed. Each is reported as a gap on its source. Lane V reads them after a key change (and at launch).
    func retiredRecords() async throws -> [CloudRetiredRecord]
    /// SYNC contract addition (round 6 S6): lane V's final answer for retired records, after it re-saved each
    /// item under the new key (a new record) or decided it is no longer needed. Confirmed records leave the gap
    /// list and their local files are released. Unknown ids are ignored; the call is idempotent.
    func confirmRetired(operationIds: [String]) async throws
    /// SYNC contract addition (device trust): the devices whose packs wait on this Mac, one entry per device,
    /// oldest first. Waiting packs are no gap: they never block readiness, coverage or the feed.
    func heldDevices() async throws -> [CloudHeldDevice]
    /// SYNC contract addition (device trust): the person trusted `deviceId` in this Mac's own window. Call it
    /// AFTER the entry is stored on this Mac's trusted list, with the key captured when the trust sheet was drawn
    /// (never one fetched afterwards). The device's waiting packs are read again from its first waiting position
    /// and applied in original feed order as late arrivals (`CloudImportOrigin.late`); the receipts are returned.
    /// While the sync core is busy the call returns [] and the release runs first in the next pull: nothing newer
    /// of that device is applied before it. Only lane A's window code may call this, never a tool.
    /// The `versionChanged` answer (the list does not hold exactly `signKey` for the device) is a TRIPWIRE, NOT
    /// THE GATE. It stops this one call. It does not stop the release: the next pull releases whatever the list
    /// trusts, under whatever key the LIST holds, because the sync core stores no key and asks the list for every
    /// pack. The rule "the key stored is the key the person compared" is therefore enforced where the list is
    /// written, in lane A, and nowhere else. Treat `versionChanged` as an alarm about the list, never as proof
    /// that nothing will be released.
    func trustDevice(deviceId: String, signKey: CloudPublicJWK) async throws -> [CloudImportReceipt]
    /// SYNC contract addition (device trust): one release pass, in original feed order, for every named device the
    /// trusted list trusts NOW (several devices ticked together). A device the list does not trust stays waiting.
    /// Same busy rule as `trustDevice`. A release also starts by itself at the next pull, and resumes first after
    /// a restart; this call only makes it happen now.
    func releaseHeld(deviceIds: [String]) async throws -> [CloudImportReceipt]
    /// SYNC contract addition (device trust): packs this Mac refused, oldest first, at most 1,000.
    func refusedPacks() async throws -> [CloudRefusedPack]
    /// SYNC contract addition (device trust), "Check again": reads the refused position again (nil: every listed
    /// one) and judges it afresh. A pack that now passes is applied as a late arrival and leaves the list.
    func checkRefusedAgain(sequence: CloudSequence?) async throws -> [CloudImportReceipt]
    /// SYNC contract addition (device trust): waiting packs of devices past the list of 500 waiting devices. Such
    /// a device has no row in `heldDevices()`; its packs are never applied, and trusting it still releases them.
    func waitingBeyondList() async throws -> Int
    /// SYNC contract addition (device trust): refused packs past the list of 1,000. "Check again" for everything
    /// (`checkRefusedAgain(sequence: nil)`) reaches them too.
    func refusedBeyondList() async throws -> Int
    /// SYNC contract addition: this Mac's own first upload of a kind, while it is still going up as ordinary packs
    /// after setup returned. nil once everything was sent (or when no setup ran).
    func baselineProgress() async throws -> CloudBaselineProgress?
    /// Contract addition ("See what is in your Cloud"): items, versions, packs and what waits, from local state only.
    func contents(limit: Int) async throws -> CloudSyncContents
    /// Contract addition (13 Nov leftover): an adapter whose own sources changed outside a pull (a folder chosen, a
    /// file accepted) asks for the coverage the Cloud page reads to be taken again from every adapter. Sends nothing.
    func refreshCoverage() async throws
    /// 0.23.4 (fault 1): bytes of `domain`'s records still waiting on this Mac to go up, counted only until they pass
    /// `stopAfter` (asking costs a bounded walk, however long the queue is). nil = not known: the project-folders pump then
    /// holds (it protects the disk), as it does when the measure fails.
    func queuedBytes(domain: String, stopAfter: Int64) async throws -> Int64?
}
public extension CloudOutboxPort {
    /// Default for outboxes that do not measure their queue: not known.
    func queuedBytes(domain: String, stopAfter: Int64) async throws -> Int64? { nil }
    /// X3 (13 Nov): sync waits for the account to say whether the person paused it. Not a pause by the person: the
    /// log and the page say "starting up". Implementations without the distinction pause.
    func holdForStartup() async throws { try await setPaused(true) }
    /// "Sync now": one attempt whatever block is stored, then fetch and send.
    func syncNow() async throws { _ = try? await pull(); _ = try await flush() }
    /// Default for outboxes without the contents read: nothing is known.
    func contents(limit: Int) async throws -> CloudSyncContents { .empty }
    func refreshCoverage() async throws {}
    func waitingBeyondList() async throws -> Int { 0 }
    func refusedBeyondList() async throws -> Int { 0 }
    func baselineProgress() async throws -> CloudBaselineProgress? { nil }
    /// Defaults for outboxes without device trust: nothing waits or is refused; the actions are not supported
    /// (never a silent success: a forwarding outbox must forward all five).
    func heldDevices() async throws -> [CloudHeldDevice] { [] }
    func trustDevice(deviceId: String, signKey: CloudPublicJWK) async throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
    func releaseHeld(deviceIds: [String]) async throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
    func refusedPacks() async throws -> [CloudRefusedPack] { [] }
    func checkRefusedAgain(sequence: CloudSequence?) async throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
    /// Default for outboxes without these additions: setup cannot be abandoned; nothing is parked to retry.
    func abandonUnpublishedSetup() async throws { throw CloudFailure.unsupportedFormat }
    func retryParked(domains: Set<String>) async throws {}
    func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt? { nil }
    func outboxIdentity() async throws -> String { throw CloudFailure.unsupportedFormat }
    func contextReady(projectId: String, sources: Set<String>) async throws -> CloudContextReady { try await contextReady(projectId: projectId) }
    func serviceTime() -> Int64? { nil }
    func retiredRecords() async throws -> [CloudRetiredRecord] { [] }
    func confirmRetired(operationIds: [String]) async throws {}
    func enqueue(_ operations: [CloudOperation]) async throws -> CloudLocalReceipt { try await enqueue(operations, files: []) }
    /// Default for outboxes without association support: an empty list is the ordinary call; any association is refused
    /// with nothing queued, never dropped silently.
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation]) async throws -> CloudLocalReceipt {
        guard associations.isEmpty else { throw CloudFailure.unsupportedFormat }
        return try await enqueue(operations, files: files)
    }
}

public protocol CloudDomainAdapter: Sendable {
    var inventoryRows: [String] { get }
    func sourceInventory() async throws -> [CloudSourceInventory]
    func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot
    func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error>
    func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error>
    func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport
    func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt
    func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification
}

/// An adapter that owns its domains even while it has no source to list (13 Nov two-copy proof: boot files on a Mac
/// whose project folder is chosen after sign-in).
public protocol CloudDomainDeclaring {
    var declaredDomains: Set<String> { get }
}

/// An adapter whose domains are never part of a first saved copy (boot files): its records travel as ordinary packs
/// only, so no verified snapshot will ever speak for its sources. Their coverage is this Mac's own statement alone
/// (13 Nov leftover: the Boot files row read "Waiting for your Cloud to confirm this part" for ever).
public protocol CloudDomainWithoutSetup: CloudDomainDeclaring {}

/// Mac-next 2: an adapter that can say how many records its first saved copy will hold, so the Cloud page can say
/// "Preparing the first copy: 2,300 of 7,556" while it is built. Nil when it cannot tell.
public protocol CloudDomainSetupEstimating {
    func setupEstimate(cut: CloudSnapshotCut) async -> Int?
}

public protocol CloudContentPort: Sendable {
    func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose,
              epoch: Int, codec: CloudContentCodec) async throws -> CloudContentEnvelope
    func open(_ envelope: CloudContentEnvelope) async throws -> Data
    func state(storageClass: CloudStorageClass) async -> CloudContentState
}

public protocol CloudSecretsPort: Sendable {
    func status() async throws -> CloudSecretsStatus
    func beginSetup() async throws
    func requestApproval() async throws -> CloudApproval
    func openApproval(id: String) async throws
    func beginRecovery() async throws
    func beginReset() async throws
    func exportLogical(source: String) async throws -> [CloudSecretRecord]
    func importLogical(_ records: [CloudSecretRecord], conflictPolicy: CloudConflictPolicy) async throws -> CloudVerification
    func classify(relativePath: String, sourceId: String) async throws -> CloudSecretClassification
    func protectProjectSettings(projectId: String, rootId: String, bytes: Data) async throws -> CloudSecretRecord
}

public protocol CloudPathPort: Sendable {
    func map(projectId: String, rootId: String, deviceId: String) async throws -> CloudPathMap?
    func planMapping(projectId: String, rootId: String, destination: String) async throws -> CloudPathPlan
    func commitMapping(planDigest: String, receipt: CloudVerification) async throws -> CloudPathMap
}

/// Readiness is an explicit record, never inferred from an open socket.
public enum CloudFixtureSchema {
    public static let version = 1
    public static let inventoryRows = (1...30).map { String(format: "I%02d", $0) }
    public static let requiredOperationKeys: Set<String> = ["v", "opId", "originDevice", "domain", "entityId", "revision", "parents", "kind", "projectId", "rootId", "source", "createdAt", "payload", "payloadHash"]
    public static let forbiddenSourceTables: Set<String> = ["search", "search_map", "embeddings", "embed_queue"]
}

public struct CloudApprovalProof: Codable, Equatable, Sendable {
    public let signerDeviceId: String
    public let signature: String
    public init(signerDeviceId: String, signature: String) {
        self.signerDeviceId = signerDeviceId
        self.signature = signature
    }
}

public struct CloudSecretsInitializeRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let expectedVersion: CloudSequence
    public let recoveryEnvelope: CloudRecoveryEnvelope
    public let deviceEnvelope: CloudDeviceKeyEnvelope
    public let canaryHash: String
    public let confirmation: Bool
    public init(requestId: String, expectedVersion: CloudSequence, recoveryEnvelope: CloudRecoveryEnvelope, deviceEnvelope: CloudDeviceKeyEnvelope, canaryHash: String, confirmation: Bool) {
        self.requestId = requestId
        self.expectedVersion = expectedVersion
        self.recoveryEnvelope = recoveryEnvelope
        self.deviceEnvelope = deviceEnvelope
        self.canaryHash = canaryHash
        self.confirmation = confirmation
    }
}

public struct CloudApprovalRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let targetDeviceId: String
    public let targetKeyHash: String
    public init(requestId: String, targetDeviceId: String, targetKeyHash: String) {
        self.requestId = requestId
        self.targetDeviceId = targetDeviceId
        self.targetKeyHash = targetKeyHash
    }
}

public struct CloudApprovalAnswer: Codable, Equatable, Sendable {
    public let requestId: String
    public let approvalId: String
    public let allow: Bool
    public let expectedVersion: CloudSequence
    public let deviceEnvelope: CloudDeviceKeyEnvelope?
    public let canaryHash: String?
    public let proof: CloudApprovalProof
    public init(requestId: String, approvalId: String, allow: Bool, expectedVersion: CloudSequence, deviceEnvelope: CloudDeviceKeyEnvelope? = nil, canaryHash: String? = nil, proof: CloudApprovalProof) {
        self.requestId = requestId
        self.approvalId = approvalId
        self.allow = allow
        self.expectedVersion = expectedVersion
        self.deviceEnvelope = deviceEnvelope
        self.canaryHash = canaryHash
        self.proof = proof
    }
}

public struct CloudPossessionRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let expectedVersion: CloudSequence
    public let canary: String
    public let signature: String
    public init(requestId: String, expectedVersion: CloudSequence, canary: String, signature: String) {
        self.requestId = requestId
        self.expectedVersion = expectedVersion
        self.canary = canary
        self.signature = signature
    }
}

public struct CloudRecoveryChallengeRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let targetKeyHash: String
    public init(requestId: String, targetKeyHash: String) {
        self.requestId = requestId
        self.targetKeyHash = targetKeyHash
    }
}

public struct CloudRecoveryChallenge: Codable, Equatable, Sendable {
    public let challengeId: String
    public let challenge: String
    public let expiresAt: Int64
    public let epoch: Int
    public let version: CloudSequence
    public let recoveryEnvelope: CloudRecoveryEnvelope
    public init(challengeId: String, challenge: String, expiresAt: Int64, epoch: Int, version: CloudSequence, recoveryEnvelope: CloudRecoveryEnvelope) {
        self.challengeId = challengeId
        self.challenge = challenge
        self.expiresAt = expiresAt
        self.epoch = epoch
        self.version = version
        self.recoveryEnvelope = recoveryEnvelope
    }
}

public struct CloudRecoveryCompleteRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let challengeId: String
    public let targetKeyHash: String
    public let expectedVersion: CloudSequence
    public let deviceEnvelope: CloudDeviceKeyEnvelope
    public let signature: String
    public init(requestId: String, challengeId: String, targetKeyHash: String, expectedVersion: CloudSequence, deviceEnvelope: CloudDeviceKeyEnvelope, signature: String) {
        self.requestId = requestId
        self.challengeId = challengeId
        self.targetKeyHash = targetKeyHash
        self.expectedVersion = expectedVersion
        self.deviceEnvelope = deviceEnvelope
        self.signature = signature
    }
}

public struct CloudSecretsResetRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public let expectedVersion: CloudSequence
    /// nil (left out of the body) = "Start again" when nobody can open the copy: the service takes it only from a
    /// computer while no device holds the current key (td-cloud 2fb865f1).
    public let resetTicket: String?
    public let newRecoveryEnvelope: CloudRecoveryEnvelope
    public let newDeviceEnvelope: CloudDeviceKeyEnvelope
    public let canaryHash: String
    public let confirmation: Bool
    public init(requestId: String, expectedVersion: CloudSequence, resetTicket: String?, newRecoveryEnvelope: CloudRecoveryEnvelope, newDeviceEnvelope: CloudDeviceKeyEnvelope, canaryHash: String, confirmation: Bool) {
        self.requestId = requestId
        self.expectedVersion = expectedVersion
        self.resetTicket = resetTicket
        self.newRecoveryEnvelope = newRecoveryEnvelope
        self.newDeviceEnvelope = newDeviceEnvelope
        self.canaryHash = canaryHash
        self.confirmation = confirmation
    }
}

public struct CloudHandoffCallback: Codable, Equatable, Sendable {
    /// The loopback port (kind "loopback"); 0 for the app callback.
    public let port: Int
    public let pathToken: String
    /// 13 Nov (owner): "app" = the browser comes back through the official website to `terminaldeck://cloud/return/<token>`;
    /// nil = the loopback callback, encoded exactly as before ({port, pathToken}).
    public let kind: String?
    /// The app callback's platform ("macos"); nil for loopback.
    public let platform: String?
    public init(port: Int, pathToken: String) {
        self.port = port
        self.pathToken = pathToken
        self.kind = nil
        self.platform = nil
    }
    /// The app callback (the same object the phones send: {kind:"app", platform, pathToken}).
    public static func app(platform: String, pathToken: String) -> Self { Self(app: platform, pathToken: pathToken) }
    private init(app platform: String, pathToken: String) {
        self.port = 0; self.pathToken = pathToken; self.kind = "app"; self.platform = platform
    }
    public var isApp: Bool { kind == "app" }
    private enum Keys: String, CodingKey { case port, pathToken, kind, platform }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        pathToken = try c.decode(String.self, forKey: .pathToken)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if isApp {
            try c.encode("app", forKey: .kind)
            try c.encode(platform ?? "", forKey: .platform)
            try c.encode(pathToken, forKey: .pathToken)
        } else {
            try c.encode(port, forKey: .port)
            try c.encode(pathToken, forKey: .pathToken)
        }
    }
}

public struct CloudHandoffExchange: Codable, Equatable, Sendable {
    public let code: String
    public let verifier: String
    public let callback: CloudHandoffCallback
    public init(code: String, verifier: String, callback: CloudHandoffCallback) {
        self.code = code
        self.verifier = verifier
        self.callback = callback
    }
}

public struct CloudHandoffRequest: Codable, Equatable, Sendable {
    public let challenge: String
    public let stateHash: String
    public let purpose: String
    public let callback: CloudHandoffCallback
    public init(challenge: String, stateHash: String, purpose: String, callback: CloudHandoffCallback) {
        self.challenge = challenge
        self.stateHash = stateHash
        self.purpose = purpose
        self.callback = callback
    }
}

public struct CloudHandoffReceipt: Codable, Equatable, Sendable {
    public let code: String
    public let expiresAt: Int64
    public init(code: String, expiresAt: Int64) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// Implemented by lane A. SYNC receives authenticated bytes, never owns a second token store.
public protocol CloudAuthenticationPort: Sendable {
    func credentials() async throws -> CloudAuthSession
    func deviceRegistration() async throws -> CloudDeviceRegistration
    func signRequest(method: String, pathAndQuery: String, body: Data,
                     timestamp: Int64, requestId: String) async throws -> CloudRequestProof
}
public struct CloudRequestProof: Codable, Equatable, Sendable {
    public let deviceId: String
    public let time: Int64
    public let requestId: String
    public let signature: String
    public init(deviceId: String, time: Int64, requestId: String, signature: String) {
        self.deviceId = deviceId
        self.time = time
        self.requestId = requestId
        self.signature = signature
    }
    public var headers: [String: String] {
        ["X-TD-Device": deviceId, "X-TD-Time": String(time), "X-TD-Request": requestId, "X-TD-Signature": signature]
    }
}

/// Deferred implementation, frozen port only. No backup controls register before BKP is proved.
public protocol CloudBackupPort: Sendable {
    func snapshot(projectId: String, rootId: String?) async throws -> CloudDomainSnapshot
    func versions(projectId: String, cursor: String?) async throws -> [CloudValue]
    func planRestore(_ request: CloudValue) async throws -> CloudValue
    func restore(restoreId: String, planDigest: String) async throws -> CloudVerification
    func recipe(action: String, projectId: String, rootId: String, value: CloudValue?) async throws -> CloudValue
    func tools(projectId: String?) async throws -> [CloudValue]
    func install(toolId: String) async throws -> CloudValue
}

public extension CloudDomainAdapter {
    /// Small logical stores can export once. Large stores override with bounded pages;
    /// SYNC consumes each page before asking the producer for another.
    func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        let reader = CloudSingleSnapshot(adapter: self, cut: cut)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
}
private actor CloudSingleSnapshot {
    let adapter: any CloudDomainAdapter
    let cut: CloudSnapshotCut
    var consumed = false
    init(adapter: any CloudDomainAdapter, cut: CloudSnapshotCut) { self.adapter = adapter; self.cut = cut }
    func next() async throws -> CloudDomainSnapshot? {
        guard !consumed else { return nil }
        consumed = true
        return try await adapter.snapshot(cut: cut)
    }
}

/// V uses the same registered device keys as A without taking their storage ownership.
/// Results are internal cryptographic bytes, never tool/UI response values.
public protocol CloudDeviceKeyPort: Sendable {
    func signDevicePayload(_ bytes: Data) async throws -> Data
    func deviceSharedSecret(peer: CloudPublicJWK) async throws -> Data
}
