import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Reach by account, R1 + R2 (Mac side, switch OFF by default): the gate, the door, presence, the HTTP client in the
/// service's real formats, the relay's open mark, the session host's `reach:` hello and the cut-offs, against fakes.
/// Design: macos/night/codex/reach-by-account-design.md ("R2 decisions").
@Suite("Reach by account — a signed-in device of the same account reaches this Mac, nobody else")
struct BackendReachAccountTests {
    static let phoneId = "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"
    static let otherId = "11111111-2222-4333-8444-555555555555"
    static let macId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    final class FakeService: BackendReachAccountService, @unchecked Sendable {
        private let lock = NSLock()
        private var _account: String? = "acct-A"
        private var _entitled = true
        private var _roster: BackendReachRoster
        private(set) var rosterFetches = 0
        private(set) var published: [BackendReachPresenceRecord] = []
        private(set) var withdrawn: [String] = []
        private(set) var removed: [String] = []
        private(set) var tokens = 0
        init(roster: BackendReachRoster) { _roster = roster }
        func set(account: String?) { lock.withLock { _account = account } }
        func set(roster: BackendReachRoster) { lock.withLock { _roster = roster } }
        func set(entitled: Bool) { lock.withLock { _entitled = entitled } }
        var publishedCount: Int { lock.withLock { published.count } }
        func signedInAccount() async -> String? { lock.withLock { _account } }
        func reachEntitled() async throws -> Bool { lock.withLock { _entitled } }
        func machineDeviceId() async -> String? { BackendReachAccountTests.macId }
        func roster() async throws -> BackendReachRoster { lock.withLock { rosterFetches += 1; return _roster } }
        func relayToken() async throws -> BackendReachRelayToken {
            lock.withLock { tokens += 1 }
            return .init(token: "a.b.c", expiresAtMs: Date().timeIntervalSince1970 * 1000 + 900_000)
        }
        func publish(_ presence: BackendReachPresenceRecord) async throws { lock.withLock { published.append(presence) } }
        func withdraw(deviceId: String) async throws { lock.withLock { withdrawn.append(deviceId) } }
        func removeDevice(_ deviceId: String) async throws { lock.withLock { removed.append(deviceId) } }
    }
    final class FakeRelay: BackendReachRelayDoor, @unchecked Sendable {
        private let lock = NSLock()
        private var _attached = false
        var attached: Bool { lock.withLock { _attached } }
        func attachAccount(_ token: BackendReachRelayToken) async throws { lock.withLock { _attached = true } }
        func detachAccount() async { lock.withLock { _attached = false } }
    }
    final class Notices: BackendReachNoticeSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [BackendReachNotice] = []
        var all: [BackendReachNotice] { lock.withLock { _all } }
        func post(_ notice: BackendReachNotice) async { lock.withLock { _all.append(notice) } }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms = 1_800_000_000_000.0
        func now() -> Double { lock.withLock { ms } }
        func advance(_ by: Double) { lock.withLock { ms += by } }
    }
    /// A remote-input record: `posted` = the remote path posted an event just now.
    static func inputGuard(posted: Bool) -> BackendRemoteInputGuard {
        .init(lastPost: { posted ? 50_000_000_000 : nil }, now: { 50_500_000_000 })
    }

    struct Rig {
        let dir: URL
        let service: FakeService
        let relay = FakeRelay()
        let notices = Notices()
        let clock = Clock()
        let gate: BackendReachAccountGate
        let host = BackendSealedIdentity.generate()
        let phone = StaticKeyPair.generate()
        init(devices: [BackendReachRosterDevice]? = nil, phoneActive: Bool = true, guardPosted: Bool = false) {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-reach-" + UUID().uuidString + ".noindex")
            let list = devices ?? [BackendReachRosterDevice(deviceId: BackendReachAccountTests.phoneId, label: "Asad's iPhone", platform: "ios", reachKey: phone.publicKey, active: phoneActive)]
            service = FakeService(roster: .init(account: "acct-A", version: "1", devices: list))
            let clock = self.clock
            gate = BackendReachAccountGate(directory: dir, service: service, notices: notices,
                                           inputGuard: BackendReachAccountTests.inputGuard(posted: guardPosted), now: { clock.now() })
        }
        func on() async throws { try await gate.setEnabled(true) }
        /// A real Noise IK first frame from `device` to this host, as the relay would carry it.
        func frame(from device: StaticKeyPair) throws -> (frame: Data, pending: PendingHandshake) {
            let start = try SealedHandshake.start(deviceStatic: device, responderStaticPublic: host.publicKey)
            return (BackendRelayPacketCodec.withSealedVersion(start.message), start.pending)
        }
        func presence() -> BackendReachPresence {
            let key = BackendReachWire.base64url(host.publicKey)
            return BackendReachPresence(gate: gate, service: service, relay: relay, host: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: key, name: "Studio Mac") })
        }
    }

    // MARK: R1 cases, on the service's formats

    @Test("Off by default: nothing published, the relay room untied, every device refused")
    func offByDefault() async throws {
        let rig = Rig()
        #expect(await rig.gate.settings() == BackendReachSettings(enabled: false, policy: .accountOnly))
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.switchOff))
        #expect(await rig.gate.candidateKeys().isEmpty)
        #expect(await rig.presence().sync() == .off)
        #expect(rig.service.publishedCount == 0)
        #expect(rig.service.tokens == 0)
        #expect(!rig.relay.attached)
        await #expect(throws: BackendReachFailure.refused(.switchOff)) {
            _ = try await BackendReachAccountDoor(gate: rig.gate).answer(identity: rig.host, frame: try rig.frame(from: rig.phone).frame)
        }
        #expect(rig.notices.all.isEmpty)
        // A damaged settings file reads as OFF too.
        try FileManager.default.createDirectory(at: rig.dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: rig.dir.appendingPathComponent(BackendReachAccountGate.fileName))
        let again = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices, inputGuard: Self.inputGuard(posted: false))
        #expect(await again.settings().enabled == false)
    }

    @Test("Devices window (13 Nov): on by default for a Mac that never chose, once; a choice and a damaged file are kept")
    func onByDefaultForAMacThatNeverChose() async throws {
        let rig = Rig()
        #expect(await rig.gate.switchOnByDefaultIfNeverChosen())
        #expect(await rig.gate.settings().enabled)
        #expect(await rig.gate.switchOnByDefaultIfNeverChosen() == false, "once only")
        try await rig.gate.setEnabled(false)
        let again = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices, inputGuard: Self.inputGuard(posted: false))
        #expect(await again.switchOnByDefaultIfNeverChosen() == false)
        #expect(await again.settings().enabled == false, "the person's off is kept")
        let damagedRig = Rig()
        try FileManager.default.createDirectory(at: damagedRig.dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: damagedRig.dir.appendingPathComponent(BackendReachAccountGate.fileName))
        let damaged = BackendReachAccountGate(directory: damagedRig.dir, service: damagedRig.service, notices: damagedRig.notices,
                                              inputGuard: Self.inputGuard(posted: false))
        #expect(await damaged.switchOnByDefaultIfNeverChosen() == false)
        #expect(await damaged.settings().enabled == false, "a damaged file still reads as OFF")
    }

    @Test("Switched on: presence is published and the relay room is tied to the account; off withdraws both")
    func presenceFollowsTheSwitch() async throws {
        let rig = Rig()
        try await rig.on()
        let presence = rig.presence()
        #expect(await presence.sync() == .published)
        #expect(rig.relay.attached)
        #expect(rig.service.published.last?.hostId == "ABCDEFGHJKLMNPQRSTUVWXYZ23")
        #expect(rig.service.published.last?.hostKey == BackendReachWire.base64url(rig.host.publicKey))
        // A second minute: published again, the 15-minute token is not asked again.
        #expect(await presence.sync() == .published)
        #expect(rig.service.tokens == 1)
        try await rig.gate.setEnabled(false)
        #expect(await presence.sync() == .off)
        #expect(!rig.relay.attached)
        #expect(rig.service.withdrawn == [Self.macId])
        rig.service.set(entitled: false)
        rig.clock.advance(BackendReachAccountGate.entitlementMaxAgeMs + 1)
        try await rig.gate.setEnabled(true)
        #expect(await presence.sync() == .notEntitled)
    }

    @Test("A device of another account is refused, at the handshake and by the gate")
    func otherAccountRefused() async throws {
        let rig = Rig()
        try await rig.on()
        let stranger = StaticKeyPair.generate()   // registered in account B, so not in A's roster
        #expect(await rig.gate.admit(key: stranger.publicKey) == .refused(.unknownDevice))
        await #expect(throws: BackendReachFailure.refused(.unknownDevice)) {
            _ = try await BackendReachAccountDoor(gate: rig.gate).answer(identity: rig.host, frame: try rig.frame(from: stranger).frame)
        }
        // This Mac signed in to account B while it still held A's list: nothing from that list is trusted.
        rig.service.set(account: "acct-B")
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.otherAccount))
        rig.service.set(account: nil)
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.signedOut))
        #expect(rig.notices.all.isEmpty)
    }

    @Test("A removed device is refused: removed in the account (removed flag or inactive), or with one click on this Mac")
    func removedRefused() async throws {
        let rig = Rig(phoneActive: false)
        try await rig.on()
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.removed))

        let flagged = StaticKeyPair.generate()
        let viaFlag = Rig(devices: [.init(deviceId: Self.phoneId, label: "iPhone", platform: "ios", reachKey: flagged.publicKey, active: true, removed: true)])
        try await viaFlag.on()
        #expect(await viaFlag.gate.admit(key: flagged.publicKey) == .refused(.removed))

        let local = Rig()
        try await local.on()
        guard case .admitted = await local.gate.admit(key: local.phone.publicKey) else { Issue.record("should be admitted"); return }
        try await local.gate.remove(deviceId: Self.phoneId)
        #expect(await local.gate.admit(key: local.phone.publicKey) == .refused(.removed))
        #expect(await local.gate.candidateKeys().isEmpty)

        // Signed out on that device: refused too.
        let signedOut = Rig(devices: [.init(deviceId: Self.phoneId, label: "iPhone", platform: "ios", reachKey: StaticKeyPair.generate().publicKey, sessionLive: false)])
        try await signedOut.on()
        #expect(await signedOut.gate.candidateKeys().isEmpty)
    }

    @Test("Missing entitlement: refused even with the switch on")
    func missingEntitlement() async throws {
        let rig = Rig()
        rig.service.set(entitled: false)
        try await rig.on()
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.notEntitled))
        #expect(await rig.presence().sync() == .notEntitled)
        #expect(!rig.relay.attached)
    }

    @Test("A new device's first connection raises the notice once, in names only; the session opens end to end")
    func firstConnectionNotice() async throws {
        let rig = Rig()
        try await rig.on()
        let door = BackendReachAccountDoor(gate: rig.gate)
        let (frame, pending) = try rig.frame(from: rig.phone)
        let opened = try await door.answer(identity: rig.host, frame: frame, marked: Self.phoneId)
        #expect(opened.admission.deviceId == Self.phoneId)
        #expect(opened.admission.firstTime)
        #expect(rig.notices.all == [.firstConnection(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios")])
        // What the person reads: the device's name and nothing else that identifies it.
        let sentence = try #require(rig.notices.all.first).sentence
        #expect(sentence == "Asad's iPhone connected to this Mac for the first time.")
        #expect(!sentence.contains(Self.phoneId) && !sentence.contains(BackendReachWire.base64url(rig.phone.publicKey)))
        // The device finishes the same sealed handshake: a frame it seals opens on this Mac.
        let client = try SealedHandshake.finish(pending: pending, reply: Data(opened.reply.dropFirst()))
        let sealed = try client.send(Data("hello".utf8))
        #expect(try await opened.transport.receive(sealed) == Data("hello".utf8))
        // Second time: no notice.
        let second = try await door.answer(identity: rig.host, frame: try rig.frame(from: rig.phone).frame)
        #expect(!second.admission.firstTime)
        #expect(rig.notices.all.count == 1)
        // The pin survives a restart of the app.
        let reopened = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices, inputGuard: Self.inputGuard(posted: false))
        guard case .admitted(let again) = await reopened.admit(key: rig.phone.publicKey) else { Issue.record("should be admitted"); return }
        #expect(!again.firstTime)
    }

    @Test("The relay's mark must name the device whose key finished the handshake")
    func wrongMarkRefused() async throws {
        let rig = Rig()
        try await rig.on()
        await #expect(throws: BackendReachFailure.refused(.wrongDevice)) {
            _ = try await BackendReachAccountDoor(gate: rig.gate).answer(identity: rig.host, frame: try rig.frame(from: rig.phone).frame, marked: Self.otherId)
        }
        #expect(rig.notices.all.isEmpty, "no pin and no notice for a channel the relay mislabelled")
    }

    @Test("The pinned key wins: the same device id with a new key is refused with a notice")
    func pinnedKey() async throws {
        let rig = Rig()
        try await rig.on()
        _ = await rig.gate.admit(key: rig.phone.publicKey)
        let swapped = StaticKeyPair.generate()
        rig.service.set(roster: .init(account: "acct-A", version: "2", devices: [.init(deviceId: Self.phoneId, label: "iPhone", platform: "ios", reachKey: swapped.publicKey)]))
        await rig.gate.rosterChanged()
        #expect(await rig.gate.admit(key: swapped.publicKey) == .refused(.keyChanged))
        #expect(rig.notices.all.last == .keyChanged(deviceId: Self.phoneId, label: "iPhone"))
    }

    @Test("Policy B: a new device waits for an approval made at this Mac")
    func policyB() async throws {
        let rig = Rig()
        try await rig.on()
        try await rig.gate.setPolicy(.approveNew)
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.notApproved))
        #expect(rig.notices.all.last == .awaitingApproval(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios"))
        try await rig.gate.approve(deviceId: Self.phoneId)
        guard case .admitted = await rig.gate.admit(key: rig.phone.publicKey) else { Issue.record("should be admitted"); return }
    }

    @Test("The remote-input guard still refuses trust presses: switching on, loosening, approving")
    func remoteInputGuard() async throws {
        let rig = Rig(guardPosted: true)
        await #expect(throws: BackendReachFailure.remoteInput) { try await rig.gate.setEnabled(true) }
        #expect(await rig.gate.settings().enabled == false)
        await #expect(throws: BackendReachFailure.remoteInput) { try await rig.gate.approve(deviceId: Self.phoneId) }
        try await rig.gate.setPolicy(.approveNew)   // stricter: taken
        await #expect(throws: BackendReachFailure.remoteInput) { try await rig.gate.setPolicy(.accountOnly) }
        #expect(await rig.gate.settings().policy == .approveNew)
        #expect(Self.inputGuard(posted: true).refusesPress())
        #expect(!Self.inputGuard(posted: false).refusesPress())
    }

    @Test("Knocking too often is refused; nothing that cannot be found out is let in")
    func limitsAndFailures() async throws {
        let rig = Rig()
        try await rig.on()
        for _ in 0..<BackendReachAccountGate.handshakesPerMinute { _ = await rig.gate.admit(key: rig.phone.publicKey) }
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.rateLimited))
        rig.clock.advance(61_000)
        guard case .admitted = await rig.gate.admit(key: rig.phone.publicKey) else { Issue.record("should be admitted"); return }
        rig.service.set(entitled: false)
        rig.clock.advance(BackendReachAccountGate.entitlementMaxAgeMs + 1)
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.notEntitled))
    }

    // MARK: The service's and the relay's formats

    @Test("Signed texts and canonical JSON are byte-for-byte the service's (reach.ts, common.ts canonical)")
    func signedTexts() {
        #expect(BackendReachWire.reachKeyMessage(deviceId: Self.phoneId, key: "AAAA") == "TD-REACH-KEY-1\n\(Self.phoneId)\nAAAA")
        #expect(BackendReachWire.approveMessage(deviceId: Self.phoneId, key: "AAAA") == "TD-REACH-APPROVE-1\n\(Self.phoneId)\nAAAA")
        let record = BackendReachPresenceRecord(deviceId: Self.macId, hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k_-K",
                                                name: "Studio \"Mac\"\\é\n\u{01}", platform: "macos", policy: .accountOnly)
        // What JSON.stringify writes for each value, keys sorted: the service signs exactly this text.
        let expected = #"{"deviceId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","hostId":"ABCDEFGHJKLMNPQRSTUVWXYZ23","hostKey":"k_-K","name":"Studio \"Mac\"\\é\n\u0001","platform":"macos","policy":"A","signedAt":1800000000123}"#
        #expect(BackendReachWire.presenceCanonical(record, signedAt: 1_800_000_000_123) == expected)
        #expect(BackendReachWire.presenceMessage(record, signedAt: 1_800_000_000_123) == "TD-REACH-PRESENCE-1\n" + expected)
        #expect(BackendReachWire.presenceBody(record, signedAt: 1, sig: "S").contains(#""policy":"A","sig":"S","signedAt":1}"#))
    }

    @Test("Keys and signatures are base64url without padding, strictly")
    func base64url() {
        let bytes = Data((0..<32).map { UInt8($0 * 7 % 256) })
        let text = BackendReachWire.base64url(bytes)
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(BackendReachWire.unbase64url(text, length: 32) == bytes)
        #expect(BackendReachWire.unbase64url(text + "=", length: 32) == nil)
        #expect(BackendReachWire.unbase64url(bytes.base64EncodedString(), length: 32) == nil || !bytes.base64EncodedString().contains(where: { "+/=".contains($0) }))
        #expect(BackendReachWire.unbase64url(text, length: 31) == nil)
    }

    @Test("The relay's open mark: empty = paired (unchanged), 0x52 0x01 + id = account, anything marked but unreadable = closed")
    func openMark() {
        #expect(BackendReachWire.openKind(Data()) == .paired)
        #expect(BackendReachWire.openKind(Data([1, 2, 3])) == .paired)
        // relay/cloudflare/src/reach.ts reachOpenPayload(deviceId)
        let marked = Data([0x52, 0x01]) + Data(Self.phoneId.utf8)
        #expect(BackendReachWire.openKind(marked) == .account(deviceId: Self.phoneId))
        #expect(BackendReachWire.openPayload(deviceId: Self.phoneId) == marked)
        #expect(BackendReachWire.openKind(Data([0x52])) == .invalid)
        #expect(BackendReachWire.openKind(Data([0x52, 0x02]) + Data(Self.phoneId.utf8)) == .invalid)
        #expect(BackendReachWire.openKind(Data([0x52, 0x01]) + Data("not-a-device".utf8)) == .invalid)
    }

    @Test("The device list answer is read as the service writes it; unreadable rows are dropped")
    func rosterParse() throws {
        let key = BackendReachWire.base64url(StaticKeyPair.generate().publicKey)
        let json = """
        {"account":"acct-A","version":"7","policy":"B","devices":[
         {"deviceId":"\(Self.phoneId)","label":"iPhone","platform":"ios","reachKey":"\(key)","active":true,"removed":false,"sessionLive":true,"expiresAtMs":null,"approved":true,"approvedBy":"\(Self.macId)","approvalSig":"c2ln"},
         {"deviceId":"\(Self.otherId)","label":"Browser","platform":"web","reachKey":"\(key)","active":false,"removed":true,"sessionLive":false,"expiresAtMs":1800000000000,"approved":false,"approvedBy":null,"approvalSig":null},
         {"deviceId":"bad","label":"x","platform":"ios","reachKey":"\(key)","active":true,"removed":false,"sessionLive":true,"expiresAtMs":null,"approved":false,"approvedBy":null,"approvalSig":null}]}
        """
        let roster = try BackendReachWire.roster(try NativeRPCValue.parseJSON(Data(json.utf8)))
        #expect(roster.account == "acct-A" && roster.version == "7" && roster.policy == .approveNew)
        #expect(roster.devices.count == 2)
        #expect(roster.devices[0].approvedBy == Self.macId && roster.devices[0].approved && roster.devices[0].expiresAtMs == nil)
        #expect(roster.devices[1].removed && roster.devices[1].expiresAtMs == 1_800_000_000_000)
        let push = try NativeRPCValue.parseJSON(Data(#"{"devicesVersion":"8","reachRemoved":["\#(Self.phoneId)","junk"]}"#.utf8))
        #expect(BackendReachWire.removedIds(push) == [Self.phoneId])
    }

    // MARK: The HTTP client

    final class FakeHTTP: BackendCloudAccountHTTP, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var sent: [BackendCloudAccountRequest] = []
        var answer: (BackendCloudAccountRequest) -> BackendCloudAccountResponse
        init(_ answer: @escaping (BackendCloudAccountRequest) -> BackendCloudAccountResponse) { self.answer = answer }
        func send(_ request: BackendCloudAccountRequest) async throws -> BackendCloudAccountResponse {
            let a = lock.withLock { sent.append(request); return answer }
            return a(request)
        }
        var all: [BackendCloudAccountRequest] { lock.withLock { sent } }
    }

    @Test("Every reach route is a signed device request the service accepts; presence carries signedAt and its own signature")
    func httpClient() async throws {
        let key = P256.Signing.PrivateKey()
        let http = FakeHTTP { request in
            switch (request.method, request.url.path) {
            case ("GET", "/v1/capabilities"): .init(status: 200, body: Data(#"{"features":["cloud","reach"],"session":"valid"}"#.utf8))
            case ("POST", "/v1/reach/token"): .init(status: 200, body: Data(#"{"token":"h.b.s","expiresAt":1800000900000,"scope":"reach-host"}"#.utf8))
            case ("GET", "/v1/reach/devices"): .init(status: 200, body: Data(#"{"account":"acct-A","version":"3","policy":"A","devices":[]}"#.utf8))
            default: .init(status: 200, body: Data("{}".utf8))
            }
        }
        let service = BackendReachAccountHTTPService(base: URL(string: "https://td-cloud-test.example.test/v1")!, http: http, account: .init(
            subject: { "acct-A" }, accessToken: { _ in "access-1" }, deviceId: { Self.macId },
            sign: { bytes, id in #expect(id == Self.macId); return try key.signature(for: bytes).rawRepresentation }),
            now: { 1_800_000_000_000 })
        #expect(try await service.reachEntitled())
        #expect(try await service.relayToken() == .init(token: "h.b.s", expiresAtMs: 1_800_000_900_000, scope: "reach-host"))
        #expect(try await service.roster().version == "3")
        let record = BackendReachPresenceRecord(deviceId: Self.macId, hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "kkk", name: "Studio Mac", policy: .accountOnly)
        try await service.publish(record)
        try await service.withdraw(deviceId: Self.macId)
        try await service.removeDevice(Self.phoneId)

        let sent = http.all
        #expect(sent.map(\.method) == ["GET", "POST", "GET", "PUT", "DELETE", "POST"])
        // /capabilities: bearer only, no device proof.
        #expect(sent[0].headers["authorization"] == "Bearer access-1" && sent[0].headers["x-td-signature"] == nil)
        for request in sent.dropFirst() {
            #expect(request.headers["authorization"] == "Bearer access-1")
            #expect(request.headers["x-td-device"] == Self.macId && request.headers["x-td-time"] == "1800000000000")
            let requestId = try #require(request.headers["x-td-request"])
            let text = BackendReachAccountHTTPService.proofText(method: request.method, path: request.url.path, time: 1_800_000_000_000, requestId: requestId, body: request.body)
            #expect(text.hasPrefix("TD-CLOUD-1\n\(request.method)\n\(request.url.path)\n1800000000000\n\(requestId)\n"))
            let sig = try #require(request.headers["x-td-signature"].flatMap { BackendReachWire.unbase64url($0, length: 64) })
            #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig), for: Data(text.utf8)))
        }
        // GET hashes the empty body.
        #expect(BackendReachAccountHTTPService.proofText(method: "GET", path: "/v1/reach/devices", time: 1, requestId: "r", body: Data())
                .hasSuffix("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        // The presence body: the seven fields + sig; the sig verifies over TD-REACH-PRESENCE-1 + canonical JSON.
        let body = try NativeRPCValue.parseJSON(sent[3].body)
        #expect(body["signedAt"].number == 1_800_000_000_000 && body["policy"].string == "A" && body["hostKey"].string == "kkk")
        let psig = try #require(body["sig"].string.flatMap { BackendReachWire.unbase64url($0, length: 64) })
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: psig),
                                               for: Data(BackendReachWire.presenceMessage(record, signedAt: 1_800_000_000_000).utf8)))
        #expect(String(decoding: sent[5].body, as: UTF8.self) == #"{"deviceId":"\#(Self.phoneId)"}"#)
    }

    @Test("A refused access token is renewed once; a service refusal becomes an error")
    func httpRefusals() async throws {
        let forced = Clock()
        let http = FakeHTTP { request in
            request.headers["authorization"] == "Bearer fresh"
                ? .init(status: 403, body: Data(#"{"error":{"code":"reach_required"}}"#.utf8))
                : .init(status: 401, body: Data(#"{"error":{"code":"sign_in_required"}}"#.utf8))
        }
        let service = BackendReachAccountHTTPService(base: URL(string: "https://td-cloud-test.example.test/v1")!, http: http, account: .init(
            subject: { "acct-A" }, accessToken: { force in if force { forced.advance(1) }; return force ? "fresh" : "stale" },
            deviceId: { Self.macId }, sign: { _, _ in Data(count: 64) }))
        await #expect(throws: (any Error).self) { _ = try await service.roster() }
        #expect(http.all.count == 2 && forced.now() == 1_800_000_000_001)
    }

    // MARK: The session host, the relay link, the coordinator

    actor Wire {
        var frames: [NativeRPCValue] = []
        var closes = 0
        func receive(_ text: String) { if let v = try? NativeRPCValue.parseJSON(Data(text.utf8)) { frames.append(v) } }
        func closed() { closes += 1 }
        var types: [String] { frames.compactMap { $0["t"].string } }
    }

    struct HostRig {
        let directory: URL
        let trust: BackendRemoteTrustStore
        let host: BackendRemoteHost
        static func make() async throws -> HostRig {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-reach-host-" + UUID().uuidString + ".noindex")
            let trust = BackendRemoteTrustStore(directory: directory)
            try await trust.open()
            let clock = INT2PhoneHostClock()
            let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
                home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
            try await host.start()
            return .init(directory: directory, trust: trust, host: host)
        }
        func finish() async { await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: directory) }
        func hello(_ token: String) -> String {
            String(decoding: (try? NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(token)),
                .init("device", .object([.init("name", .string("Asad's iPhone")), .init("platform", .string("ios"))])),
                .init("capabilities", .array([]))]).encodedJSON()) ?? Data(), as: UTF8.self)
        }
        func connect(_ wire: Wire, reach: BackendReachAdmission?, peer: Data?) async -> UUID? {
            var made = BackendRemoteHostWire(address: "reach:test", peerPublicKey: peer, send: { await wire.receive($0) }, close: { _, _ in await wire.closed() })
            made.reach = reach
            return await host.accept(made)
        }
    }

    static func admission(_ key: Data, id: String = phoneId) -> BackendReachAdmission {
        .init(deviceId: id, label: "Asad's iPhone", platform: "ios", reachKey: key, firstTime: true)
    }

    @Test("The session host takes `reach:<id>` only on a wire the door admitted, with that device's key; full access, the person's own device")
    func hostHello() async throws {
        let rig = try await HostRig.make()
        let key = StaticKeyPair.generate().publicKey
        // Admitted wire, matching hello: welcomed, full access, own device, approved only while connected.
        let ok = Wire()
        let id = try #require(await rig.connect(ok, reach: Self.admission(key), peer: key))
        await rig.host.receive(id, text: rig.hello("reach:" + Self.phoneId))
        #expect(await ok.types.contains("welcome"))
        let hostId = BackendReachAdmission.hostDeviceId(Self.phoneId)
        #expect(await rig.trust.isApproved(hostId))
        #expect(await rig.trust.phoneAccess(hostId) == .full)
        #expect(await rig.trust.kindOf(hostId) == .mine, "no folder or login questions: everything, as the person's own device")
        #expect(await rig.trust.listDevices().isEmpty, "the pairing roster is not touched")
        // `reach:` on a wire without an admission: refused.
        let plain = Wire()
        let pid = try #require(await rig.connect(plain, reach: nil, peer: key))
        await rig.host.receive(pid, text: rig.hello("reach:" + Self.phoneId))
        #expect(await !plain.types.contains("welcome"))
        // Another device's name on an admitted wire, or another key: refused.
        let wrong = Wire()
        let wid = try #require(await rig.connect(wrong, reach: Self.admission(key), peer: key))
        await rig.host.receive(wid, text: rig.hello("reach:" + Self.otherId))
        #expect(await !wrong.types.contains("welcome"))
        let swapped = Wire()
        let sid = try #require(await rig.connect(swapped, reach: Self.admission(key), peer: StaticKeyPair.generate().publicKey))
        await rig.host.receive(sid, text: rig.hello("reach:" + Self.phoneId))
        #expect(await !swapped.types.contains("welcome"))
        // A paired credential on an admitted wire: refused (an account channel never takes the pairing path).
        let mixed = Wire()
        let mid = try #require(await rig.connect(mixed, reach: Self.admission(key), peer: key))
        await rig.host.receive(mid, text: rig.hello("abcdefgh.c2VjcmV0"))
        #expect(await !mixed.types.contains("welcome"))
        await rig.finish()
    }

    @Test("Paired devices are unaffected: a paired device still pairs and says hello while reach is off")
    func pairedUnaffected() async throws {
        let rig = try await HostRig.make()
        let offer = try await rig.trust.createPairingOffer()
        let paired = try await rig.trust.redeem(offer.token, name: "Old phone", address: "test", publicKey: nil)
        try await rig.trust.approve(paired.device.id, kind: .mine)
        let wire = Wire()
        let id = try #require(await rig.connect(wire, reach: nil, peer: nil))
        await rig.host.receive(id, text: rig.hello(paired.credential))
        #expect(await wire.types.contains("welcome"))
        #expect(await rig.host.reachConnectedDeviceIds().isEmpty)
        await rig.finish()
    }

    @Test("Removal cuts a live account channel at once (a `devices` push, or Remove on this Mac); paired ones stay")
    func removalCuts() async throws {
        let rig = try await HostRig.make()
        let phone = StaticKeyPair.generate()
        let service = FakeService(roster: .init(account: "acct-A", version: "1", devices: [.init(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios", reachKey: phone.publicKey)]))
        let link = BackendReachRelayLink()
        let coordinator = BackendReachAccountCoordinator(directory: rig.directory, service: service, notices: Notices(), host: rig.host,
            card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: link, inputGuard: Self.inputGuard(posted: false))
        // A device paired before reach was switched on keeps its connection.
        let paired = try await rig.trust.redeem(try await rig.trust.createPairingOffer().token, name: "Old", address: "t", publicKey: nil)
        try await rig.trust.approve(paired.device.id, kind: .mine)
        let pairedWire = Wire()
        let pid = try #require(await rig.connect(pairedWire, reach: nil, peer: nil))
        await rig.host.receive(pid, text: rig.hello(paired.credential))
        #expect(await pairedWire.types.contains("welcome"))
        try await coordinator.setEnabled(true)
        let wire = Wire()
        let id = try #require(await rig.connect(wire, reach: Self.admission(phone.publicKey), peer: phone.publicKey))
        await rig.host.receive(id, text: rig.hello("reach:" + Self.phoneId))
        #expect(await rig.host.reachConnectedDeviceIds() == [Self.phoneId])
        // The service says it was removed.
        await coordinator.event(type: "devices", payload: try NativeRPCValue.parseJSON(Data(#"{"devicesVersion":"2","reachRemoved":["\#(Self.phoneId)"]}"#.utf8)))
        #expect(await rig.host.reachConnectedDeviceIds().isEmpty)
        #expect(await wire.closes >= 1)
        #expect(await !rig.trust.isApproved(BackendReachAdmission.hostDeviceId(Self.phoneId)))
        #expect(await pairedWire.closes == 0, "a paired device is never cut by reach")
        // Remove on this Mac: cut, refused, and the service told.
        let again = Wire()
        let aid = try #require(await rig.connect(again, reach: Self.admission(phone.publicKey), peer: phone.publicKey))
        await rig.host.receive(aid, text: rig.hello("reach:" + Self.phoneId))
        try await coordinator.remove(deviceId: Self.phoneId)
        #expect(await again.closes >= 1)
        #expect(service.removed == [Self.phoneId])
        #expect(await coordinator.gate.admit(key: phone.publicKey) == .refused(.removed))
        // Switching off cuts every account channel too.
        try await coordinator.setEnabled(false)
        #expect(await rig.host.reachConnectedDeviceIds().isEmpty)
        await coordinator.stop()
        await rig.finish()
    }

    @Test("One Remove means one thing: Reach's Remove also stops trust here; trust's Remove takes reach only while on")
    func removeDoesBoth() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-reach-" + UUID().uuidString + ".noindex")
        let phone = StaticKeyPair.generate()
        let service = FakeService(roster: .init(account: "acct-A", version: "1", devices: [.init(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios", reachKey: phone.publicKey)]))
        let coordinator = BackendReachAccountCoordinator(directory: dir, service: service, notices: Notices(), host: nil,
            card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: BackendReachRelayLink(), inputGuard: Self.inputGuard(posted: false))
        final class Stopped: @unchecked Sendable {
            private let lock = NSLock(); private var _ids: [String] = []
            var ids: [String] { lock.withLock { _ids } }
            func add(_ id: String) { lock.withLock { _ids.append(id) } }
        }
        let stopped = Stopped()
        await coordinator.setTrustLink { id in stopped.add(id) }
        // Off: the Cloud page's Remove does not touch reach (nobody reaches this Mac by account anyway).
        #expect(try await coordinator.removeIfOn(deviceId: Self.otherId) == false)
        #expect(service.removed.isEmpty)
        try await coordinator.setEnabled(true)
        // Reach's Remove: refused here, the service told, AND this Mac's trust stopped.
        try await coordinator.remove(deviceId: Self.phoneId)
        #expect(stopped.ids == [Self.phoneId])
        #expect(service.removed == [Self.phoneId])
        #expect(await coordinator.gate.admit(key: phone.publicKey) == .refused(.removed))
        // The Cloud page's Remove while reach is on: reach removed, the trust side not called back.
        #expect(try await coordinator.removeIfOn(deviceId: Self.otherId))
        #expect(service.removed == [Self.phoneId, Self.otherId])
        #expect(stopped.ids == [Self.phoneId])
        // The page says it in one plain sentence, with no key or code word.
        #expect(!BackendReachPage.removeMeans.lowercased().contains("key") && !BackendReachPage.removeMeans.lowercased().contains("code"))
        await coordinator.stop()
    }

    @Test("Reach ON: no pairing code can be made and no view offers one or a folder question; OFF: as before")
    func pairingOutOfTheWay() async throws {
        let rig = try await HostRig.make()
        let phone = StaticKeyPair.generate()
        let service = FakeService(roster: .init(account: "acct-A", version: "1", devices: [.init(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios", reachKey: phone.publicKey)]))
        let coordinator = BackendReachAccountCoordinator(directory: rig.directory, service: service, notices: Notices(), host: rig.host,
            card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: BackendReachRelayLink(), inputGuard: Self.inputGuard(posted: false))
        // Off (the default): codes as before, and every view offers pairing.
        await coordinator.sync()
        _ = try await rig.trust.createPairingOffer()
        let offStatus = await coordinator.status()
        #expect(BackendReachPage(offStatus).offersPairing && BackendReachPage(offStatus).asksFolders)
        // On: no code, nothing offers one, nothing asks about folders.
        try await coordinator.setEnabled(true)
        #expect(await rig.trust.pairingLocked())
        #expect(await !rig.trust.pairingOpen(), "a code shown before is withdrawn")
        await #expect(throws: (any Error).self) { _ = try await rig.trust.createPairingOffer() }
        let page = BackendReachPage(await coordinator.status())
        #expect(page.mode == .on && !page.offersPairing && !page.asksFolders)
        // Off again: pairing exactly as before.
        try await coordinator.setEnabled(false)
        #expect(await !rig.trust.pairingLocked())
        _ = try await rig.trust.createPairingOffer()
        await coordinator.stop()
        await rig.finish()
    }

    @Test("Presence is published while on and withdrawn when off, through the coordinator; the relay link holds the token only while on")
    func coordinatorPresence() async throws {
        let rig = try await HostRig.make()
        let service = FakeService(roster: .init(account: "acct-A", version: "1", devices: []))
        let link = BackendReachRelayLink()
        let coordinator = BackendReachAccountCoordinator(directory: rig.directory, service: service, notices: Notices(), host: rig.host,
            card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: link, inputGuard: Self.inputGuard(posted: false))
        #expect(await coordinator.sync() == .off)
        #expect(link.token == nil && service.publishedCount == 0)
        try await coordinator.setEnabled(true)
        #expect(service.publishedCount == 1 && link.token != nil)
        try await coordinator.setEnabled(false)
        #expect(link.token == nil && service.withdrawn == [Self.macId])
        await coordinator.stop()
        await rig.finish()
    }

    @Test("The page: hidden without reach, off by default, on with names and dates only; the tool reads no ids or keys")
    func pageStates() throws {
        let now = 1_800_000_000_000.0
        let signedOut = BackendReachStatus(signedIn: false, entitled: nil, enabled: false, presence: .signedOut, tied: false, devices: [], recent: [])
        #expect(BackendReachPage(signedOut, now: now).mode == .hidden)
        let noPlan = BackendReachStatus(signedIn: true, entitled: false, enabled: true, presence: .notEntitled, tied: false, devices: [], recent: [])
        #expect(BackendReachPage(noPlan, now: now).mode == .hidden)
        #expect(BackendReachPage(noPlan, now: now).offersPairing, "without the plan, pairing stays")
        let device = BackendReachStatus.Device(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios", connected: false, removed: false,
                                               addedAtMs: now - 86_400_000 * 3, lastSeenAtMs: now - 3_600_000)
        let gone = BackendReachStatus.Device(deviceId: Self.otherId, label: "Old tablet", platform: "android", connected: false, removed: true, addedAtMs: nil, lastSeenAtMs: nil)
        let off = BackendReachStatus(signedIn: true, entitled: true, enabled: false, presence: .off, tied: false, devices: [device], recent: [])
        let offPage = BackendReachPage(off, now: now)
        #expect(offPage.mode == .off && offPage.switchTitle == "Let my signed-in devices open this Mac" && offPage.offersPairing)
        let on = BackendReachStatus(signedIn: true, entitled: true, enabled: true, presence: .published, tied: true, devices: [device, gone],
            recent: [.init(deviceId: Self.phoneId, label: "Asad's iPhone", platform: "ios", atMs: now - 3_600_000, refused: nil)])
        let page = BackendReachPage(on, now: now)
        #expect(page.mode == .on && page.rows.count == 1, "a removed device is not listed")
        let row = try #require(page.rows.first)
        #expect(row.title == "Asad's iPhone" && row.canRemove)
        #expect(row.detail.hasPrefix("Added ") && row.detail.contains("Last seen "))
        let shown = ([page.explanation, row.title, row.detail] + page.recent).joined(separator: " ")
        for secret in [Self.phoneId, Self.otherId, "fingerprint", "key"] { #expect(!shown.lowercased().contains(secret.lowercased()), "\(secret) on the page") }
        let tool = String(decoding: try on.wireValue.encodedJSON(), as: UTF8.self)
        #expect(!tool.contains(Self.phoneId) && !tool.contains("reachKey") && !tool.contains("token\""))
        #expect(on.wireValue["newDevices"].string == "join by signing in" && off.wireValue["newDevices"].string == "not let in")
        #expect(try BackendReachAccountTools.definitions().map(\.id) == ["cloud.reach.status"], "one read tool; nothing switches reach on")
    }
}
