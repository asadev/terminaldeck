import Foundation

public struct CloudAccountConfiguration: Sendable {
    public enum Environment: Sendable { case production, fixture }
    public let baseURL: URL
    public let issuer: String
    public let websiteStartURL: URL
    public let storeAuthURL: URL
    public let publishableKey: String
    public let deviceLabel: String
    public let appVersion: String
    public let environment: Environment
    public static func isPublicStoreKey(_ value: String) -> Bool {
        if value.hasPrefix("sb_publishable_"), value.utf8.count > 15, value.utf8.count <= 8192 { return true }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return false }
        var payload = String(fields[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload), bytes.count <= 4096, let claims = try? NativeRPCValue.parseJSON(bytes) else { return false }
        return claims["role"].string == "anon"
    }
    public init(baseURL: URL, issuer: String, websiteStartURL: URL, storeAuthURL: URL,
                publishableKey: String, deviceLabel: String, appVersion: String, environment: Environment) throws {
        let urls = [baseURL, websiteStartURL, storeAuthURL]
        guard urls.allSatisfy({ $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil && $0.fragment == nil }),
              baseURL.path == "/v1", !issuer.isEmpty, !deviceLabel.isEmpty, deviceLabel.count <= 80 else { throw CloudFailure.unsafeConfiguration }
        if case .fixture = environment {
            guard urls.allSatisfy({ !($0.host ?? "").hasSuffix("terminaldeck.dev") }),
                  issuer != CloudWire.issuer else { throw CloudFailure.unsafeConfiguration }
        }
        self.baseURL = baseURL
        self.issuer = issuer
        self.websiteStartURL = websiteStartURL
        self.storeAuthURL = storeAuthURL
        self.publishableKey = publishableKey
        self.deviceLabel = deviceLabel
        self.appVersion = appVersion
        self.environment = environment
    }
}

/// One row of Settings → Cloud → Devices (device trust design 5.4, lean scope item 4). State for the screen and for
/// `cloud.devices`; nothing here can give trust. `signKey` is the key the code was computed from: the trust sheet
/// captures the row when it is drawn and that captured key is the only one a click can store (R1).
public struct CloudDeviceTrustRow: Sendable, Equatable, Identifiable {
    public enum Standing: String, Sendable {
        /// This Mac's current sign-in.
        case thisMac
        /// On this Mac's trusted list (the person's click, or an earlier sign-in of this Mac).
        case trusted
        /// The service lists it; this Mac does not trust it. Its changes wait.
        case new
    }
    public let deviceId: String
    /// The name the device gives itself. Display only.
    public let name: String
    public let standing: Standing
    /// 80 bits as `XXXX XXXX XXXX XXXX XXXX`; nil when the device's key cannot be read (it cannot be trusted then).
    public let code: String?
    public let keyId: String?
    public let signKey: CloudPublicJWK?
    /// When this Mac began trusting it (this Mac's clock, ms); nil for a new device.
    public let knownSince: Int64?
    /// When the service says it was added (ms); reported, not checked.
    public let addedAt: Int64?
    /// Changes from it that wait on this Mac, as the sync core reports them.
    public let waiting: Int
    /// Another device shows the same code: neither can be trusted from a sheet.
    public let sameCode: Bool
    /// Another device uses the very same signing key: a signature could not tell the two apart, so neither can be
    /// trusted (sync trust core review, hand-back 2).
    public let sameKey: Bool
    /// Cloud reports this device as removed from the account (security review S5). It is shown as such and no sheet
    /// offers Trust for it.
    public let removed: Bool
    /// Automatic trust (owner, 13 Nov): this Mac put the device on its list because the account lists it, with no press.
    public let byAccount: Bool
    /// Automatic trust: the device is on this Mac's list, but Cloud now reports ANOTHER key for it. It is not
    /// re-trusted by itself: its changes wait until the person presses the one button on the Cloud page.
    public let keyChanged: Bool
    /// Two-Mac proof (13 Nov): an earlier entry of a device that signed in again (same name and kind, never seen
    /// since the newer entry was added, another key). Never trusted automatically, never offered, not shown.
    public let stale: Bool
    /// The kind of device the service reports, given only while it reports the very key this Mac stored (or the
    /// device is new). Kept with the key on the trusted list (PASSWORDS-2 review blocker 1). Not shown.
    public let platform: CloudPlatform?
    public var id: String { deviceId }
    public init(deviceId: String, name: String, standing: Standing, code: String?, keyId: String?, signKey: CloudPublicJWK?,
                knownSince: Int64? = nil, addedAt: Int64? = nil, waiting: Int = 0, sameCode: Bool = false, sameKey: Bool = false,
                removed: Bool = false, byAccount: Bool = false, keyChanged: Bool = false, stale: Bool = false,
                platform: CloudPlatform? = nil) {
        self.stale = stale
        self.platform = platform
        self.byAccount = byAccount
        self.keyChanged = keyChanged
        self.deviceId = deviceId
        self.name = name
        self.standing = standing
        self.code = code
        self.keyId = keyId
        self.signKey = signKey
        self.knownSince = knownSince
        self.addedAt = addedAt
        self.waiting = waiting
        self.sameCode = sameCode
        self.sameKey = sameKey
        self.removed = removed
    }
    /// A sheet may offer Trust only for a new device whose key was read, whose code no other device shows, whose
    /// key no other device uses and which Cloud does not report as removed.
    public var canBeTrusted: Bool { standing == .new && code != nil && signKey != nil && !sameCode && !sameKey && !removed && !stale }
}

public struct CloudAccountSnapshot: Sendable, Equatable {
    public enum Phase: String, Sendable { case signedOut, signingIn, signedIn, paused, needsSignIn, dormant }
    public let phase: Phase
    public var subscription: CloudSubscriptionSnapshot = .init()
    public let gate: CloudGate
    public let displayName: String?
    public let devices: [CloudDevice]
    public let coverage: [CloudCoverage]
    public let waitingRecords: Int
    public let blockedRecords: Int
    public let problem: String?
    /// The Devices section: every device the service lists, with this Mac's own view of it.
    public let trust: [CloudDeviceTrustRow]
    /// Changes that wait on this Mac because their device is not trusted here (as the service reports them).
    public let heldChanges: Int
    /// Packs from Cloud this Mac could not check and did not use. "Check again" judges them afresh.
    public let refusedPacks: Int
    /// One plain line for the Devices section when this Mac's own trust state is not what it should be: its list of
    /// trusted devices cannot be read, or Cloud lists another key for this Mac (security review M2).
    public let trustNotice: String?
    /// This Mac's first save, while it is still going up; nil once done.
    public let baseline: CloudBaselineProgress?
    /// The newest position of the account's feed, as the service said in its last answer; nil before any answer.
    public let cloudHead: CloudSequence?
    /// How far this Mac has read that feed; nil before any answer.
    public let fetched: CloudSequence?
    public init(phase: Phase, gate: CloudGate, displayName: String? = nil, devices: [CloudDevice] = [],
                coverage: [CloudCoverage] = [], waitingRecords: Int = 0, blockedRecords: Int = 0, problem: String? = nil,
                trust: [CloudDeviceTrustRow] = [], heldChanges: Int = 0, refusedPacks: Int = 0, trustNotice: String? = nil,
                baseline: CloudBaselineProgress? = nil, cloudHead: CloudSequence? = nil, fetched: CloudSequence? = nil) {
        self.phase = phase
        self.gate = gate
        self.displayName = displayName
        self.devices = devices
        self.coverage = coverage
        self.waitingRecords = waitingRecords
        self.blockedRecords = blockedRecords
        self.problem = problem
        self.trust = trust
        self.heldChanges = heldChanges
        self.refusedPacks = refusedPacks
        self.trustNotice = trustNotice
        self.baseline = baseline
        self.cloudHead = cloudHead
        self.fetched = fetched
    }
    /// Is this Mac still reading what the Cloud holds? true = catching up, false = level with the Cloud, nil = not
    /// known yet (no answer from the service in this run). Changes that wait for a device not yet trusted do not
    /// count here: the feed is read past them and they are listed on their own.
    public var catchingUp: Bool? {
        guard let cloudHead, let fetched else { return nil }
        return fetched < cloudHead
    }
    /// How many positions of the feed this Mac has still to read; nil when not known.
    public var behindBy: Int? {
        guard let cloudHead, let fetched, let head = UInt64(cloudHead.rawValue), let mine = UInt64(fetched.rawValue) else { return nil }
        return head > mine ? Int(clamping: head - mine) : 0
    }
    /// The same state under another phase and problem line; everything else is carried over unchanged.
    public func carried(phase: Phase, problem: String?) -> Self {
        var copy = Self(phase: phase, gate: gate, displayName: displayName, devices: devices, coverage: coverage, waitingRecords: waitingRecords,
             blockedRecords: blockedRecords, problem: problem, trust: trust, heldChanges: heldChanges, refusedPacks: refusedPacks,
             trustNotice: trustNotice, baseline: baseline, cloudHead: cloudHead, fetched: fetched)
        copy.subscription = subscription
        return copy
    }
    /// The same state with the saved sign-in's name, when it had none yet (a launch whose first status read got no
    /// answer still knows who is signed in on this Mac: 13 Nov).
    public func named(_ name: String?) -> Self {
        guard displayName == nil, let name else { return self }
        var copy = Self(phase: phase, gate: gate, displayName: name, devices: devices, coverage: coverage, waitingRecords: waitingRecords,
                    blockedRecords: blockedRecords, problem: problem, trust: trust, heldChanges: heldChanges, refusedPacks: refusedPacks,
                    trustNotice: trustNotice, baseline: baseline, cloudHead: cloudHead, fetched: fetched)
        copy.subscription = subscription
        return copy
    }
    /// Proof 3 (13 Nov): the same state with this Mac's own progress read again (no request to the service): what
    /// is queued or held, the first copy's progress and how far this Mac has read the feed. A Mac that read past the
    /// last head it was told is level with what it knows.
    public func withLocalProgress(coverage: [CloudCoverage], waitingRecords: Int, blockedRecords: Int, baseline: CloudBaselineProgress?,
                                  fetched: CloudSequence) -> Self {
        let head = cloudHead.map { $0 < fetched ? fetched : $0 }
        var copy = Self(phase: phase, gate: gate, displayName: displayName, devices: devices, coverage: coverage, waitingRecords: waitingRecords,
                    blockedRecords: blockedRecords, problem: problem, trust: trust, heldChanges: heldChanges, refusedPacks: refusedPacks,
                    trustNotice: trustNotice, baseline: baseline, cloudHead: head, fetched: cloudHead == nil ? self.fetched : fetched)
        copy.subscription = subscription
        return copy
    }
    public static let signedOut = Self(phase: .signedOut, gate: .closed)
    /// Visible while the server's LAST EXPLICIT decision allows Cloud (N2/N3). Time and network failures never close it;
    /// `now` is kept for source compatibility and is not used.
    public func visible(at now: Int64) -> Bool { gate.entitlesCloud && (phase == .signedIn || phase == .paused) }
    public var offersCloudServices: Bool { subscription.allowsCloudServices }
    public var offersCloudTools: Bool { subscription.offers(.cloudTools, existing: visible(at: 0)) }
    private var firstSaveWire: NativeRPCValue {
        guard let baseline else { return .null }
        let reason: NativeRPCValue = baseline.reason.map(NativeRPCValue.string) ?? .null
        return .object([.init("saved", .number(Double(baseline.sent))), .init("total", .number(Double(baseline.total))),
                        .init("filesWaiting", .number(Double(baseline.filesWaiting))), .init("reason", reason)])
    }
    /// Explicit safe projection; never encode an identity/credential storage object to tools.
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [
            .init("phase", .string(phase.rawValue)), .init("displayName", displayName.map(NativeRPCValue.string) ?? .null),
            .init("devices", .array(devices.map { device -> NativeRPCValue in
                // State only (design 2.3): whether THIS Mac trusts the device. No tool can change it.
                let row = trust.first { $0.deviceId == device.deviceId }
                // The name is the filtered one-line form when this Mac built a row for the device (security review S12):
                // an untrusted device's own text never reaches an agent raw.
                return .object([.init("deviceId", .string(device.deviceId)), .init("label", .string(row?.name ?? "")),
                    .init("platform", .string(device.platform.rawValue)), .init("status", .string(device.status.rawValue)), .init("secretsApproved", .bool(device.secretsApproved)),
                    .init("trustedOnThisMac", .bool(row != nil && row?.standing != .new)),
                    // Owner, 13 Nov: no device code in any tool's answer; names, dates and states only.
                    .init("addedAt", device.registeredAt.map { NativeRPCValue.number(Double($0)) } ?? .null),
                    .init("lastSeenAt", .number(Double(device.lastSeenAt))),
                    .init("changesWaiting", .number(Double(row?.waiting ?? 0)))])
            })),
            .init("coverage", .array(coverage.map { .object([.init("sourceId", .string($0.sourceId)), .init("inventoryRow", .string($0.inventoryRow)),
                .init("complete", .bool($0.complete)), .init("items", .number(Double($0.items))), .init("bytes", .number(Double($0.bytes))),
                .init("blockedReasons", .array($0.blockedReasons.map(NativeRPCValue.string))),
                .init("exclusions", .array($0.exclusions.map(NativeRPCValue.string)))]) })),
            .init("waitingRecords", .number(Double(waitingRecords))), .init("blockedRecords", .number(Double(blockedRecords))),
            .init("changesWaitingForTrust", .number(Double(heldChanges))), .init("changesNotUsed", .number(Double(refusedPacks))),
            // Whether this Mac has everything the Cloud holds (null: not known yet), and how far its first save is.
            .init("catchingUp", catchingUp.map(NativeRPCValue.bool) ?? .null),
            .init("firstSave", firstSaveWire),
            .init("problem", problem.map(NativeRPCValue.string) ?? .null)
        ]
        if subscription.showsSubscription { fields.append(.init("subscription", subscription.wireValue)) }
        return .object(fields)
    }
}

public enum CloudAccountCallback {
    public struct Value: Sendable, Equatable { public let code: String; public let state: String }
    public static func parse(_ data: Data, callback: CloudHandoffCallback) throws -> Value {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") else { throw CloudFailure.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", first[1].hasPrefix("/") else { throw CloudFailure.invalidRequest }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(callback.port)",
              let u = URLComponents(string: "http://127.0.0.1" + String(first[1])),
              u.path == "/cloud/callback/" + callback.pathToken else { throw CloudFailure.invalidRequest }
        let query = u.queryItems ?? []
        guard Set(query.map(\.name)).count == query.count, Set(query.map(\.name)) == ["code", "state"],
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count <= 256,
              let state = query.first(where: { $0.name == "state" })?.value, !state.isEmpty, state.count <= 256 else { throw CloudFailure.invalidRequest }
        return .init(code: code, state: state)
    }
}
