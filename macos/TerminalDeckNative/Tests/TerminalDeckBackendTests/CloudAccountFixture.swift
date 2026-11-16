import Foundation
import CryptoKit
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Test module only: no fixture server, key or identity can enter production composition.
final class CloudAccountFixtureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var count = 0
    var failWrites = false
    var failRemoval = false
    func value() -> String? { lock.withLock { text } }
    func writes() -> Int { lock.withLock { count } }
    func port() -> BackendCloudAccountProtectedStore {
        .init(read: { self.value() }, write: { value in
            try self.lock.withLock { if self.failWrites { throw CloudFailure.unavailable }; self.text = value; self.count += 1 }
        }, remove: { try self.lock.withLock { if self.failRemoval { throw CloudFailure.unavailable }; self.text = nil } })
    }
}
/// This Mac's trusted-device list in memory: no fixture ever opens the Keychain.
final class CloudTrustFixtureSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var count = 0
    private var broken = false
    func bytes() -> Data? { lock.withLock { data } }
    func put(_ value: Data?) { lock.withLock { data = value } }
    func writes() -> Int { lock.withLock { count } }
    func breakReads(_ value: Bool) { lock.withLock { broken = value } }
    func port() -> BackendCloudTrustSlot {
        .init(read: { () throws -> Data? in
            try self.lock.withLock { () throws -> Data? in
                if self.broken { throw BackendCloudTrustRefusal.unreadable }
                return self.data
            }
        }, write: { value in self.lock.withLock { self.data = value; self.count += 1 } })
    }
}
final class CloudAccountFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Int64(Date().timeIntervalSince1970 * 1000)
    func now() -> Int64 { lock.withLock { time } }
    func advance(_ delta: Int64) { lock.withLock { time += delta } }
    /// Fixture monotonic clock (ns) that moves with `advance`, independent of the wall value's meaning.
    func monotonic() -> UInt64 { UInt64(max(0, now())) &* 1_000_000 }
}
final class CloudTrustFixturePress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ refused: Bool) { lock.withLock { value = refused } }
    func refused() -> Bool { lock.withLock { value } }
}
actor CloudAccountFixtureServer: BackendCloudAccountHTTP {
    let user = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let clock: CloudAccountFixtureClock
    let signer = P256.Signing.PrivateKey()
    let issuer = "https://issuer.example.invalid/auth/v1"
    var challenge = ""
    var used = false
    var calls = 0
    var refreshes = 0
    var logouts = 0
    var wrongIssuer = false
    var shortLife = false
    var gateEnabled = true
    var registered: CloudDeviceRegistration?
    var rejectRegistration = false
    var refuseRefresh = false
    /// The token endpoint cannot be reached at all (no network), as opposed to refusing.
    var tokenOffline = false
    var refusalCode = "session_not_found"
    func setRefusalCode(_ code: String) { refusalCode = code }
    var staleExpiry = false
    var noEntitlementValue = false
    init(clock: CloudAccountFixtureClock) { self.clock = clock }
    func set(_ name: String, _ value: Bool) {
        switch name { case "wrongIssuer": wrongIssuer = value; case "shortLife": shortLife = value; case "gate": gateEnabled = value; case "registration": rejectRegistration = value; case "refuseRefresh": refuseRefresh = value; case "tokenOffline": tokenOffline = value; case "staleExpiry": staleExpiry = value; case "noEntitlementValue": noEntitlementValue = value; default: break }
    }
    func authorize(_ url: URL) throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        challenge = items.first { $0.name == "challenge" }!.value!
        used = false
    }
    func gate() -> CloudGate { .init(features: gateEnabled ? ["cloud"] : [], storageEntitled: noEntitlementValue ? nil : true, aiSubscriptionsEnabled: false, revision: CloudSequence(1), expiresAt: staleExpiry ? clock.now() - 3_600_000 : clock.now() + 300_000) }
    func session() throws -> CloudAuthSession {
        let seconds = clock.now() / 1000
        let duration: Int64 = shortLife ? 59 : 3600
        let head = try CloudWire.canonical(CloudValue(.object([.init("alg", .string("ES256")), .init("kid", .string("fixture"))])))
        let body = try CloudWire.canonical(CloudValue(.object([.init("iss", .string(wrongIssuer ? "https://wrong.example.invalid/auth/v1" : issuer)), .init("sub", .string(user)), .init("aud", .string("authenticated")), .init("role", .string("authenticated")), .init("iat", .number(Double(seconds))), .init("exp", .number(Double(seconds + duration))), .init("session_id", .string("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))])))
        let encoded = BackendCloudAccountIdentity.base64(head) + "." + BackendCloudAccountIdentity.base64(body)
        let signature = try signer.signature(for: Data(encoded.utf8)).rawRepresentation
        return .init(accessToken: encoded + "." + BackendCloudAccountIdentity.base64(signature), refreshToken: "fixture-refresh-\(refreshes)", expiresAt: (seconds + duration) * 1000, user: .init(id: user, displayName: "Fixture person", email: "person@example.invalid", provider: "google"), capabilities: gate())
    }
    func send(_ input: BackendCloudAccountRequest) async throws -> BackendCloudAccountResponse {
        guard input.url.host?.hasSuffix("example.invalid") == true else { throw CloudFailure.unsafeConfiguration }
        calls += 1
        if input.url.path == "/v1/auth/exchange" {
            let request = try CloudWire.decode(CloudHandoffExchange.self, from: input.body)
            guard !used, request.code == "fixture-code", BackendCloudAccountIdentity.base64(Data(SHA256.hash(data: Data(request.verifier.utf8)))) == challenge else { throw CloudFailure.invalidRequest }
            used = true
            return .init(status: 200, body: try CloudWire.canonical(session()))
        }
        if input.url.path.hasSuffix("/token") {
            if tokenOffline { throw URLError(.notConnectedToInternet) }
            // The Store's real refusal shape (store/cloudflare/src/auth.ts:288): {code, error_code, msg}.
            if refuseRefresh { return .init(status: 400, body: Data(#"{"code":400,"error_code":"\#(refusalCode)","msg":"Invalid Refresh Token: Session Not Found"}"#.utf8)) }
            refreshes += 1
            try await Task.sleep(for: .milliseconds(20))
            shortLife = false
            let next = try session()
            return .init(status: 200, body: try CloudWire.canonical(CloudValue(.object([.init("access_token", .string(next.accessToken)), .init("refresh_token", .string(next.refreshToken)), .init("expires_at", .number(Double(next.expiresAt / 1000))), .init("user", .object([.init("id", .string(user))]))]))))
        }
        if input.url.path.hasSuffix("/logout") { logouts += 1; return .init(status: 204, body: Data()) }
        if input.url.path == "/v1/devices/leave" { return try leave(input.body) }
        throw CloudFailure.invalidRequest
    }
    /// Lost-device review finding 4: the registration answers "revoked" for this device id.
    var answerRevoked = false
    func setAnswerRevoked(_ value: Bool) { answerRevoked = value }
    func register(_ value: CloudDeviceRegistration, identity: BackendCloudAccountIdentity) async throws -> CloudDeviceRegistrationReceipt {
        guard !rejectRegistration else { throw CloudFailure.deviceRevoked }
        registrationBodies.append(value)
        if machineService == .refuses && (value.machineId != nil || value.displayName != nil) || machineService == .noHost && value.hostName != nil {
            throw CloudFailure.remote(.init(code: "invalid_request", message: "fixture", retryable: false, requestId: "fixture"))
        }
        let credentials = try await identity.credentials()
        let pieces = credentials.accessToken.split(separator: ".").map(String.init)
        guard pieces.count == 3, let signature = BackendCloudAccountIdentity.unbase64(pieces[2]),
              signer.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data((pieces[0] + "." + pieces[1]).utf8)) else { throw CloudFailure.invalidRequest }
        let body = try CloudWire.canonical(value)
        let proof = try await identity.signRequest(method: "POST", pathAndQuery: "/v1/devices", body: body, timestamp: clock.now(), requestId: UUID().uuidString)
        let x = BackendCloudAccountIdentity.unbase64(value.signPublicJwk.x)!
        let y = BackendCloudAccountIdentity.unbase64(value.signPublicJwk.y!)!
        let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let signed = Data("TD-CLOUD-1\nPOST\n/v1/devices\n\(proof.time)\n\(proof.requestId)\n\(hash)".utf8)
        guard key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: BackendCloudAccountIdentity.unbase64(proof.signature)!), for: signed) else { throw CloudFailure.invalidRequest }
        if let earlier = registered, earlier.deviceId != value.deviceId {
            self.earlier.append(.init(deviceId: earlier.deviceId, label: earlier.label, platform: .macos, appVersion: "fixture",
                                      status: ownRemoved ? .revoked : .active, secretsApproved: false, lastSeenAt: ownSeenAt,
                                      signPublicJwk: earlier.signPublicJwk, wrapPublicJwk: earlier.wrapPublicJwk, registeredAt: ownRegisteredAt))
        }
        registered = value
        ownRemoved = false; ownRegisteredAt = clock.now(); ownSeenAt = clock.now()
        let knows = machineService == .knows || machineService == .noHost
        if knows { ownDisplayName = value.displayName }
        var receipt = CloudDeviceRegistrationReceipt(deviceId: value.deviceId, status: answerRevoked ? .revoked : .active, secretsApproved: false, headSeq: .zero, vaultState: .unset)
        if knows { receipt.displayName = value.displayName }
        return receipt
    }
    /// MAC-NEXT-10: how the service treats machineId/displayName: knows them (echoes), ignores them, or refuses
    /// unknown fields with 400 invalid_request.
    enum MachineService: Sendable { case knows, ignores, refuses, noHost }
    var machineService: MachineService = .ignores
    func setMachineService(_ value: MachineService) { machineService = value }
    var registrationBodies: [CloudDeviceRegistration] = []
    var describeCalls: [(label: String, machineId: String, displayName: String, hostName: String?)] = []
    var ownDisplayName: String?
    func forgetDisplayName() { ownDisplayName = nil }
    func describe(label: String, machineId: String, displayName: String, hostName: String?) throws -> String? {
        describeCalls.append((label, machineId, displayName, hostName))
        switch machineService {
        case .noHost:
            if hostName != nil { throw CloudFailure.remote(.init(code: "invalid_request", message: "fixture", retryable: false, requestId: "fixture")) }
            ownDisplayName = displayName; return displayName
        case .refuses: throw CloudFailure.remote(.init(code: "invalid_request", message: "fixture", retryable: false, requestId: "fixture"))
        case .ignores: return nil
        case .knows: ownDisplayName = displayName; return displayName
        }
    }
    /// Other devices of the account, as the service would list them (device trust tests).
    var others: [CloudDevice] = []
    func setOthers(_ devices: [CloudDevice]) { others = devices }
    /// Settings → Devices "Sign out this device" (14 Nov): the other devices this Mac signed out, with the version sent;
    /// the refusals the next removals answer, in order (the service's codes).
    var signedOut: [(id: String, version: CloudSequence)] = []
    var signOutRefusals: [String] = []
    func refuseSignOut(_ codes: [String]) { signOutRefusals = codes }
    func removeOther(_ deviceId: String, version: CloudSequence) throws {
        if !signOutRefusals.isEmpty {
            throw CloudFailure.remote(.init(code: signOutRefusals.removeFirst(), message: "fixture", retryable: false, requestId: "fixture"))
        }
        signedOut.append((deviceId, version))
        others = others.map { $0.deviceId != deviceId ? $0 : .init(deviceId: $0.deviceId, label: $0.label, platform: $0.platform, appVersion: $0.appVersion, status: .revoked, secretsApproved: false, lastSeenAt: $0.lastSeenAt, signPublicJwk: $0.signPublicJwk, wrapPublicJwk: $0.wrapPublicJwk, registeredAt: $0.registeredAt) }
    }
    /// Whether the service says this Mac is approved for saved passwords (sign-out guard tests).
    var ownApproved = false
    func setOwnApproved(_ value: Bool) { ownApproved = value }
    /// A dishonest service: the key it lists under this Mac's own id (nil = the key this Mac registered).
    var ownKeyShown: CloudPublicJWK?
    func setOwnKeyShown(_ key: CloudPublicJWK?) { ownKeyShown = key }
    /// Sign-out's self-removal (two-Mac proof): earlier registrations of this Mac stay listed, as the service keeps them.
    var earlier: [CloudDevice] = []
    var ownRemoved = false
    var ownRegisteredAt: Int64 = 0
    var ownSeenAt: Int64 = 0
    var removals = 0
    var refuseRemoval = false
    func setRefuseRemoval(_ value: Bool) { refuseRemoval = value }
    /// Proof 2: the removal (and, separately, the leave route) cannot be reached at all.
    var removalOffline = false
    func setRemovalOffline(_ value: Bool) { removalOffline = value }
    var leaveOffline = false
    func setLeaveOffline(_ value: Bool) { leaveOffline = value }
    /// The old service: no leave route yet (answers like any unsigned request, 401).
    var leaveUnknown = false
    func setLeaveUnknown(_ value: Bool) { leaveUnknown = value }
    /// A service that answers "not found" for the leave route.
    var leaveNotFound = false
    func setLeaveNotFound(_ value: Bool) { leaveNotFound = value }
    var leaveCalls = 0
    var leaveTaken: [String] = []
    var lastRemovalVersion: CloudSequence??
    func leave(_ body: Data) throws -> BackendCloudAccountResponse {
        leaveCalls += 1
        if leaveOffline { throw URLError(.notConnectedToInternet) }
        if leaveNotFound { return .init(status: 404, body: Data(#"{"error":{"code":"not_found","message":"x","retryable":false}}"#.utf8)) }
        if leaveUnknown { return .init(status: 401, body: Data(#"{"error":{"code":"sign_in_required","message":"x","retryable":false}}"#.utf8)) }
        let note = try CloudWire.decode(BackendCloudLeaveNote.self, from: body)
        let jwk = registered?.deviceId == note.deviceId ? registered?.signPublicJwk : earlier.first { $0.deviceId == note.deviceId }?.signPublicJwk
        guard let jwk, let x = BackendCloudAccountIdentity.unbase64(jwk.x), let y = jwk.y.flatMap(BackendCloudAccountIdentity.unbase64) else {
            return .init(status: 404, body: Data(#"{"error":{"code":"not_found","message":"x","retryable":false}}"#.utf8))
        }
        let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        guard note.sub == user, let raw = BackendCloudAccountIdentity.unbase64(note.signature),
              key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: Data(BackendCloudLeaveNote.text(sub: note.sub, deviceId: note.deviceId, signedAt: note.signedAt).utf8)) else {
            return .init(status: 401, body: Data(#"{"error":{"code":"bad_device_proof","message":"x","retryable":false}}"#.utf8))
        }
        if registered?.deviceId == note.deviceId { ownRemoved = true }
        earlier = earlier.map { $0.deviceId != note.deviceId ? $0 : .init(deviceId: $0.deviceId, label: $0.label, platform: $0.platform, appVersion: $0.appVersion, status: .revoked, secretsApproved: false, lastSeenAt: $0.lastSeenAt, signPublicJwk: $0.signPublicJwk, wrapPublicJwk: $0.wrapPublicJwk, registeredAt: $0.registeredAt) }
        if !leaveTaken.contains(note.deviceId) { leaveTaken.append(note.deviceId) }
        return .init(status: 200, body: Data(#"{"deviceId":"\#(note.deviceId)","status":"revoked"}"#.utf8))
    }
    func removeOwn(version: CloudSequence? = nil) throws {
        lastRemovalVersion = .some(version)
        if removalOffline { throw URLError(.notConnectedToInternet) }
        if refuseRemoval { throw CloudFailure.remote(.init(code: "rotation_required", message: "fixture", retryable: false, requestId: "fixture")) }
        removals += 1; ownRemoved = true
    }
    func devices() -> CloudDeviceList {
        if registered != nil, !ownRemoved { ownSeenAt = clock.now() }
        var own: [CloudDevice] = registered.map { [.init(deviceId: $0.deviceId, label: $0.label, platform: .macos, appVersion: "fixture", status: ownRemoved ? .revoked : .active, secretsApproved: ownApproved, lastSeenAt: ownSeenAt, signPublicJwk: ownKeyShown ?? $0.signPublicJwk, wrapPublicJwk: $0.wrapPublicJwk, registeredAt: ownRegisteredAt)] } ?? []
        if machineService == .knows || machineService == .noHost, !own.isEmpty { own[0].displayName = ownDisplayName }
        return .init(devices: earlier + own + others, receiverDeviceId: nil)
    }
}
actor CloudAccountFixtureTransport: CloudTransportPort {
  /// MAC-NEXT-7 (5): retry back-offs on the fixture clock (100 times faster), never the real one.
  func backoff(milliseconds: Int64) async throws { try await Task.sleep(for: .milliseconds(max(1, milliseconds / 100))) }
    let identity: BackendCloudAccountIdentity
    let server: CloudAccountFixtureServer
    var stopped = false
    var stateCalls = 0
    var offline = false
    func setOffline(_ value: Bool) { offline = value }
    /// Cloud's own refusals, in the service's error shape, answered by the next state calls in order.
    var stateFailures: [String] = []
    var registrations = 0
    func failState(_ codes: [String]) { stateFailures = codes }
    /// Lost-device design A2: one refusal with the whole service detail (e.g. device_revoked with removedByName).
    var stateDetail: CloudErrorDetail?
    func failState(detail: CloudErrorDetail) { stateDetail = detail }
    /// Any other failure of the next state call (a timeout, an empty or undecodable answer).
    var stateError: (any Error)?
    func failState(error: any Error) { stateError = error }
    init(identity: BackendCloudAccountIdentity, server: CloudAccountFixtureServer) { self.identity = identity; self.server = server }
    func capabilities() async throws -> CloudGate { await server.gate() }
    func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt { registrations += 1; return try await server.register(request, identity: identity) }
    var deviceListOffline = false
    func setDeviceListOffline(_ value: Bool) { deviceListOffline = value }
    /// How often the device list was asked (device watch tests).
    var deviceCalls = 0
    /// Cloud's refusals of the device list, in order (MAC-NEXT-12b).
    var deviceFailures: [String] = []
    func failDevices(_ codes: [String]) { deviceFailures = codes }
    /// One refusal of the device list with the whole service detail (the "removed by" form of device_revoked).
    var deviceDetail: CloudErrorDetail?
    func failDevices(detail: CloudErrorDetail) { deviceDetail = detail }
    func devices() async throws -> CloudDeviceList {
        deviceCalls += 1
        if deviceListOffline { throw URLError(.notConnectedToInternet) }
        if let detail = deviceDetail { deviceDetail = nil; throw CloudFailure.remote(detail) }
        if !deviceFailures.isEmpty {
            throw CloudFailure.remote(.init(code: deviceFailures.removeFirst(), message: "fixture", retryable: false, requestId: "fixture"))
        }
        return await server.devices()
    }
    func state() async throws -> CloudRemoteState {
        stateCalls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        if let detail = stateDetail { stateDetail = nil; throw CloudFailure.remote(detail) }
        if let failure = stateError { stateError = nil; throw failure }
        if !stateFailures.isEmpty {
            let code = stateFailures.removeFirst()
            throw CloudFailure.remote(.init(code: code, message: "fixture", retryable: false, requestId: "fixture"))
        }
        return .init(headSeq: head, devicesVersion: CloudSequence(1), vaultState: .unset, vaultEpoch: 0, vaultVersion: .zero, capabilities: await server.gate(), budget: .init(day: "fixture", requestsLeft: 10, writesLeft: 10, bytesLeft: 1000))
    }
    /// The newest position of the account's feed, as the fixture service reports it.
    var head: CloudSequence = .zero
    func setHead(_ value: CloudSequence) { head = value }
    func commit(_ segment: CloudSegment) async throws -> CloudReceipt { throw CloudFailure.unsupportedFormat }
    func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage { throw CloudFailure.unsupportedFormat }
    func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] { throw CloudFailure.unsupportedFormat }
    func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] { throw CloudFailure.unsupportedFormat }
    func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] { throw CloudFailure.unsupportedFormat }
    func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func checkpoint() async throws -> CloudCheckpoint? { nil }
    func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] { throw CloudFailure.unsupportedFormat }
    func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt { .init(brainSeq: brainSeq, secretsSeq: secretsSeq) }
    func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { throw CloudFailure.unsupportedFormat }
    func releaseLease(resourceId: String, generation: CloudSequence) async throws { throw CloudFailure.unsupportedFormat }
    func events() async -> AsyncThrowingStream<CloudEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func stop() async { stopped = true }
}
extension CloudAccountFixtureTransport: BackendCloudDeviceSignOut {
    func removeDevice(deviceId: String, expectedVaultVersion: CloudSequence) async throws { try await server.removeOther(deviceId, version: expectedVaultVersion) }
}
extension CloudAccountFixtureTransport: BackendCloudDeviceSelfRemoval {
    func removeOwnDevice(expectedVaultVersion: CloudSequence?) async throws { try await server.removeOwn(version: expectedVaultVersion) }
}
extension CloudAccountFixtureTransport: BackendCloudDeviceSelfDescription {
    func describeOwnDevice(label: String, machineId: String, displayName: String, hostName: String?) async throws -> String? {
        try await server.describe(label: label, machineId: machineId, displayName: displayName, hostName: hostName)
    }
}
actor CloudAccountFixtureOutbox: CloudOutboxPort {
    var paused = false
    var flushes = 0
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt { throw CloudFailure.unsupportedFormat }
    func coverage(sourceId: String) async throws -> CloudCoverage { .init(sourceId: sourceId, inventoryRow: "I01", complete: true, items: 3, bytes: 20, blockedReasons: []) }
    func flush() async throws -> [CloudReceipt] { flushes += 1; return [] }
    func restoreProgress() async throws -> CloudRestoreProgress { .init(queued: 2, applied: 3, blocked: 0, brainSeq: fetched, secretsSeq: .zero, coverage: [try await coverage(sourceId: "fixture-source")]) }
    /// How far this Mac has read the feed, and how often it was asked to fetch.
    var fetched: CloudSequence = .zero
    var pulls = 0
    func setFetched(_ value: CloudSequence) { fetched = value }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
    func register(adapter: any CloudDomainAdapter) async throws { throw CloudFailure.unsupportedFormat }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func pull() async throws -> [CloudImportReceipt] { pulls += 1; throw CloudFailure.unsupportedFormat }
    func setPaused(_ value: Bool) async throws { paused = value }
    // Device trust: what the sync core would hold, and what lane A's wiring told it.
    var held: [CloudHeldDevice] = []
    var refused: [CloudRefusedPack] = []
    var trustedKeys: [String: CloudPublicJWK] = [:]
    /// Whether this Mac's list already held that key when the core was told (it must).
    var storedWhenTold: [String: Bool] = [:]
    var released: [[String]] = []
    var checkCalls = 0
    var checkedEverything = false
    var probe: (@Sendable (String) async -> CloudPublicJWK?)?
    func setHeld(_ devices: [CloudHeldDevice]) { held = devices }
    func setRefused(_ packs: [CloudRefusedPack]) { refused = packs }
    func setProbe(_ value: @escaping @Sendable (String) async -> CloudPublicJWK?) { probe = value }
    func heldDevices() async throws -> [CloudHeldDevice] { held }
    /// The sync core's tripwire: this Mac's list did not hold exactly the key it was told (sync trust review S8).
    var listAlarm = false
    func setListAlarm(_ value: Bool) { listAlarm = value }
    func trustDevice(deviceId: String, signKey: CloudPublicJWK) async throws -> [CloudImportReceipt] {
        if listAlarm { throw CloudFailure.versionChanged }
        trustedKeys[deviceId] = signKey
        if let probe { storedWhenTold[deviceId] = await probe(deviceId) == signKey }
        held.removeAll { $0.deviceId == deviceId }
        return []
    }
    func releaseHeld(deviceIds: [String]) async throws -> [CloudImportReceipt] {
        released.append(deviceIds)
        held.removeAll { deviceIds.contains($0.deviceId) }
        return []
    }
    func refusedPacks() async throws -> [CloudRefusedPack] { refused }
    var baseline: CloudBaselineProgress?
    func setBaseline(_ value: CloudBaselineProgress?) { baseline = value }
    func baselineProgress() async throws -> CloudBaselineProgress? { baseline }
    func checkRefusedAgain(sequence: CloudSequence?) async throws -> [CloudImportReceipt] {
        checkCalls += 1
        checkedEverything = sequence == nil
        refused = []
        return []
    }
}
struct CloudAccountFixture: Sendable {
    let clock: CloudAccountFixtureClock
    let store: CloudAccountFixtureStore
    let server: CloudAccountFixtureServer
    let identity: BackendCloudAccountIdentity
    let transport: CloudAccountFixtureTransport
    let outbox: CloudAccountFixtureOutbox
    let account: BackendCloudAccount
    let trustSlot: CloudTrustFixtureSlot
    let trust: BackendCloudTrustStore
    /// R3 fixture: true while the app's own remote-input path "posted just now".
    let remoteInput: CloudTrustFixturePress
    static func make() throws -> Self {
        let clock = CloudAccountFixtureClock(), store = CloudAccountFixtureStore()
        let server = CloudAccountFixtureServer(clock: clock)
        let config = try CloudAccountConfiguration(baseURL: URL(string: "https://cloud.example.invalid/v1")!, issuer: "https://issuer.example.invalid/auth/v1", websiteStartURL: URL(string: "https://site.example.invalid/api/store/cloud/start")!, storeAuthURL: URL(string: "https://issuer.example.invalid/auth/v1")!, publishableKey: "fixture-public", deviceLabel: "Fixture Mac", appVersion: "fixture", environment: .fixture)
        let identity = BackendCloudAccountIdentity(configuration: config, store: store.port(), http: server, clock: { clock.now() })
        let transport = CloudAccountFixtureTransport(identity: identity, server: server), outbox = CloudAccountFixtureOutbox()
        // The fixture server's one user (`CloudAccountFixtureServer.user`).
        let trustSlot = CloudTrustFixtureSlot(), remoteInput = CloudTrustFixturePress()
        let trust = BackendCloudTrustStore(subject: .init(issuer: config.issuer, sub: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), slot: trustSlot.port(),
                                           now: { clock.now() }, pressRefused: { remoteInput.refused() })
        let account = BackendCloudAccount(configuration: config, identity: identity, http: server, transport: transport, outbox: outbox, trust: trust, clock: { clock.now() }, monotonic: { clock.monotonic() })
        return .init(clock: clock, store: store, server: server, identity: identity, transport: transport, outbox: outbox, account: account,
                     trustSlot: trustSlot, trust: trust, remoteInput: remoteInput)
    }
    /// Owner, 13 Nov: there is no "Sign in to Cloud as …?" sheet any more; kept so older tests read as before.
    func confirmAll() async {}
    func signin() async throws -> URL {
        await confirmAll()
        let callback = CloudHandoffCallback(port: 49555, pathToken: String(repeating: "a", count: 32))
        let url = try await account.beginSignIn(callback: callback, provider: "google")
        try await server.authorize(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        try await account.finishSignIn(code: "fixture-code", state: state, callback: callback)
        return url
    }
}
