import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// REACH-CUT (14 Nov): a device removed from the account (`devices` push with `reachRemoved`), dropped from the
/// account's active list, or every account device when the switch goes off or this Mac signs out, loses EVERYTHING it
/// holds on this Mac at once: the relay channel, the direct link (the peer connection, even after the relay channel
/// under it closed), its sign-in here and its TURN login. A renewal afterwards is refused by this Mac itself. The
/// owner's other devices and paired devices stay. Fakes only: no network, no clock waits (a fake link engine stands
/// in for WebRTC; every wait is on a message, bounded by the suite's time limit).
@Suite("Reach cut — a removed device loses its relay channel and its direct link at once", .serialized, .timeLimit(.minutes(1)))
struct BackendReachCutTests {
    typealias R = BackendReachAccountTests
    static let browserId = "22222222-3333-4444-8555-666666666666"

    // MARK: Doubles

    /// A peer connection that opens when told to and records its close.
    final class FakeLinkConnection: BackendLinkConnection, @unchecked Sendable {
        let events: BackendLinkEvents
        private let lock = NSLock()
        private var _closed = false
        init(events: BackendLinkEvents) { self.events = events }
        var closed: Bool { lock.withLock { _closed } }
        func offer() async throws -> String {
            "v=0\r\na=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n"
        }
        func accept(answer: String) async throws {}
        func add(candidate: String, mid: String?, index: Int32) {}
        func send(_ data: Data, lane: BackendLinkLane) -> Bool { lock.withLock { !_closed } }
        func close() { lock.withLock { _closed = true } }
    }

    /// Hands out fake connections in order and records every TURN login withdrawal.
    final class FakeLinkEngine: BackendLinkEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeLinkConnection] = []
        private var waiters: [(Int, CheckedContinuation<FakeLinkConnection, Never>)] = []
        private var _released: [(device: String, force: Bool)] = []
        var released: [(device: String, force: Bool)] { lock.withLock { _released } }
        func servers(device: String) async -> (servers: [BackendPhonePeerServer], policy: String) { ([], "all") }
        func connect(servers: [BackendPhonePeerServer], policy: String, events: BackendLinkEvents) throws -> any BackendLinkConnection {
            let connection = FakeLinkConnection(events: events)
            let ready = lock.withLock { () -> [CheckedContinuation<FakeLinkConnection, Never>] in
                made.append(connection)
                let index = made.count - 1
                let due = waiters.filter { $0.0 == index }.map(\.1)
                waiters.removeAll { $0.0 == index }
                return due
            }
            for waiter in ready { waiter.resume(returning: connection) }
            return connection
        }
        /// The `index`-th connection made (0-based), once it exists.
        func connection(_ index: Int) async -> FakeLinkConnection {
            await withCheckedContinuation { waiter in
                let now = lock.withLock { () -> FakeLinkConnection? in
                    if index < made.count { return made[index] }
                    waiters.append((index, waiter)); return nil
                }
                if let now { waiter.resume(returning: now) }
            }
        }
        func release(device: String, force: Bool) async { lock.withLock { _released.append((device, force)) } }
    }

    /// The account service, whose list fetch can fail (someone blocking this Mac's way to the Cloud).
    final class FlakyService: BackendReachAccountService, @unchecked Sendable {
        private let lock = NSLock()
        private var _account: String? = "acct-A"
        private var _roster: BackendReachRoster
        private var _failing = false
        init(roster: BackendReachRoster) { _roster = roster }
        func set(account: String?) { lock.withLock { _account = account } }
        func set(roster: BackendReachRoster) { lock.withLock { _roster = roster } }
        func set(failing: Bool) { lock.withLock { _failing = failing } }
        func signedInAccount() async -> String? { lock.withLock { _account } }
        func reachEntitled() async throws -> Bool { true }
        func machineDeviceId() async -> String? { R.macId }
        func roster() async throws -> BackendReachRoster {
            try lock.withLock { if _failing { throw URLError(.notConnectedToInternet) }; return _roster }
        }
        func relayToken() async throws -> BackendReachRelayToken { .init(token: "a.b.c", expiresAtMs: 4_000_000_000_000) }
        func publish(_ presence: BackendReachPresenceRecord) async throws {}
        func withdraw(deviceId: String) async throws {}
        func removeDevice(_ deviceId: String) async throws {}
    }

    /// One relay channel as the session host sees it, with waits on the message types it carried.
    actor CutWire {
        private(set) var types: [String] = []
        private(set) var closes = 0
        private var waiting: [(String, CheckedContinuation<Void, Never>)] = []
        func receive(_ text: String) {
            guard let type = (try? NativeRPCValue.parseJSON(Data(text.utf8)))?["t"].string else { return }
            types.append(type)
            let due = waiting.filter { $0.0 == type }.map(\.1)
            waiting.removeAll { $0.0 == type }
            for waiter in due { waiter.resume() }
        }
        func closed() { closes += 1 }
        func waitFor(_ type: String) async {
            if types.contains(type) { return }
            await withCheckedContinuation { waiting.append((type, $0)) }
        }
    }

    struct Rig {
        let host: R.HostRig
        let engine = FakeLinkEngine()
        let service: FlakyService
        let clock = R.Clock()
        /// The steady clock (never goes back, counts sleep) that times the 10-minute limit.
        let steady = R.Clock()
        let coordinator: BackendReachAccountCoordinator
        let phone = StaticKeyPair.generate()
        let browser = StaticKeyPair.generate()

        static func make() async throws -> Rig {
            Rig(host: try await R.HostRig.make())
        }
        private init(host: R.HostRig) {
            self.host = host
            service = FlakyService(roster: .init(account: "acct-A", version: "1", devices: []))
            let clock = self.clock, steady = self.steady
            coordinator = BackendReachAccountCoordinator(directory: host.directory, service: service, notices: R.Notices(), host: host.host,
                card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: BackendReachRelayLink(),
                inputGuard: R.inputGuard(posted: false), now: { clock.now() }, steady: { steady.now() })
            service.set(roster: roster())
        }
        func roster(phoneActive: Bool = true, browserActive: Bool = true, phoneKey: Data? = nil, browserEndsAtMs: Double? = nil) -> BackendReachRoster {
            .init(account: "acct-A", version: "1", devices: [
                .init(deviceId: R.phoneId, label: "Asad's iPhone", platform: "ios", reachKey: phoneKey ?? phone.publicKey,
                      active: phoneActive, sessionLive: phoneActive),
                .init(deviceId: BackendReachCutTests.browserId, label: "Browser (Safari)", platform: "web", reachKey: browser.publicKey,
                      active: browserActive, sessionLive: browserActive, expiresAtMs: browserEndsAtMs)])
        }
        /// Switch on, the judgement wired, the fake WebRTC layer in.
        func on() async throws {
            await host.host.setLinkEngine(engine)
            try await coordinator.setEnabled(true)
            await coordinator.start()
        }
        func finish() async { await coordinator.stop(); await host.finish() }

        static func hello(_ token: String, platform: String, link: Bool) -> String {
            let capabilities: [NativeRPCValue] = link ? [.string(BackendRemoteHost.linkCapability), .string(BackendRemoteHost.linkOnlyCapability)] : []
            return String(decoding: (try? NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(token)),
                .init("device", .object([.init("name", .string("Device")), .init("platform", .string(platform))])),
                .init("capabilities", .array(capabilities))]).encodedJSON()) ?? Data(), as: UTF8.self)
        }

        /// An account device the door admitted, on a sealed relay channel, welcomed, its direct link open (link only),
        /// and then the relay channel under it closed: from here only the direct link carries it.
        func onDirectLink(_ deviceId: String, key: Data, platform: String, index: Int) async throws -> (id: UUID, wire: CutWire, link: FakeLinkConnection) {
            let wire = CutWire()
            var made = BackendRemoteHostWire(address: "reach:" + deviceId, peerPublicKey: key,
                send: { await wire.receive($0) }, close: { _, _ in await wire.closed() })
            made.channelBinding = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            made.reach = .init(deviceId: deviceId, label: "Device", platform: platform, reachKey: key, firstTime: false)
            let id = try #require(await host.host.accept(made))
            await host.host.receive(id, text: Self.hello("reach:" + deviceId, platform: platform, link: true))
            #expect(await wire.types.contains("welcome"))
            let link = await engine.connection(index)
            await wire.waitFor("link.peer")                // the offer went out
            link.events.open("host")
            await wire.waitFor("link.moved")               // the hand-over: everything goes on the direct link now
            // The marker crosses the relay just before the path counts as moved: wait for that, by message order only.
            while await host.host.live[id]?.link.path.hasMoved != true { await Task.yield() }
            await host.host.closed(id)                     // the relay channel goes; the link carries on (§11.4)
            #expect(await host.host.reachConnectedDeviceIds().contains(deviceId), "still connected over the direct link alone")
            #expect(!link.closed)
            return (id, wire, link)
        }

        /// A connection the door admitted just before a cut, whose hello comes after it.
        func lateHello(_ deviceId: String, key: Data) async throws -> CutWire {
            let wire = CutWire()
            var made = BackendRemoteHostWire(address: "reach:late-" + UUID().uuidString, peerPublicKey: key,
                send: { await wire.receive($0) }, close: { _, _ in await wire.closed() })
            made.channelBinding = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            made.reach = .init(deviceId: deviceId, label: "Device", platform: "web", reachKey: key, firstTime: false)
            let id = try #require(await host.host.accept(made))
            await host.host.receive(id, text: Self.hello("reach:" + deviceId, platform: "web", link: true))
            return wire
        }

        /// A device paired the old way, connected (before reach is switched on).
        func paired() async throws -> CutWire {
            let offer = try await host.trust.createPairingOffer()
            let device = try await host.trust.redeem(offer.token, name: "Old phone", address: "t", publicKey: nil)
            try await host.trust.approve(device.device.id, kind: .mine)
            let wire = CutWire()
            let made = BackendRemoteHostWire(address: "paired", send: { await wire.receive($0) }, close: { _, _ in await wire.closed() })
            let id = try #require(await host.host.accept(made))
            await host.host.receive(id, text: Self.hello(device.credential, platform: "ios", link: false))
            #expect(await wire.types.contains("welcome"))
            return wire
        }
    }

    static func removed(_ ids: [String]) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data(#"{"devicesVersion":"9","reachRemoved":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"#.utf8))
    }

    // MARK: Cases

    @Test("`reachRemoved` cuts that device's direct link at once; its renewal is refused here; the other device stays")
    func removedOnTheDirectLink() async throws {
        let rig = try await Rig.make()
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)

        await rig.coordinator.event(type: "devices", payload: try Self.removed([Self.browserId]))

        // Cut at once, whole: the peer connection closed, the connection gone, its sign-in here forgotten, its TURN
        // login withdrawn now (not after the 2-minute grace).
        #expect(browser.link.closed, "the direct link's peer connection is closed")
        #expect(await browser.wire.closes >= 1)
        #expect(await !rig.host.host.reachConnectedDeviceIds().contains(Self.browserId))
        let hostId = BackendReachAdmission.hostDeviceId(Self.browserId)
        #expect(await !rig.host.trust.isApproved(hostId))
        #expect(rig.engine.released.contains { $0.device == hostId && $0.force })
        // The other device of the account is untouched.
        #expect(!phone.link.closed)
        #expect(await phone.wire.closes == 0)
        #expect(await rig.host.host.reachConnectedDeviceIds() == [R.phoneId])
        #expect(!rig.engine.released.contains { $0.device == BackendReachAdmission.hostDeviceId(R.phoneId) })

        // A renewal is refused by this Mac itself: the gate, the door, and a handshake that raced the removal.
        #expect(await rig.coordinator.gate.admit(key: rig.browser.publicKey) == .refused(.removed))
        let identity = BackendSealedIdentity.generate()
        let start = try SealedHandshake.start(deviceStatic: rig.browser, responderStaticPublic: identity.publicKey)
        await #expect(throws: BackendReachFailure.self) {
            _ = try await BackendReachAccountDoor(gate: rig.coordinator.gate)
                .answer(identity: identity, frame: BackendRelayPacketCodec.withSealedVersion(start.message), marked: Self.browserId)
        }
        let late = try await rig.lateHello(Self.browserId, key: rig.browser.publicKey)
        #expect(await !late.types.contains("welcome"))
        #expect(await late.closes >= 1)
        #expect(await !rig.host.trust.isApproved(hostId))
        // The service's list still showing it active (not caught up yet) does not let it back.
        _ = await rig.coordinator.gate.refreshRosterNow()
        #expect(await rig.coordinator.gate.admit(key: rig.browser.publicKey) == .refused(.removed))
        // The other device still opens a new connection.
        #expect(await rig.coordinator.gate.admit(key: rig.phone.publicKey) != .refused(.removed))
        await rig.finish()
    }

    @Test("One meaning of Remove: a fresh sign-in (a new id) is let in at once; a list older than the removal never lifts it; the removal survives a restart")
    func freshSignInAndOlderList() async throws {
        let rig = R.Rig()
        try await rig.on()
        let x = R.phoneId, y = R.otherId
        rig.service.set(roster: .init(account: "acct-A", version: "1", devices: [
            .init(deviceId: x, label: "Browser", platform: "web", reachKey: rig.phone.publicKey)]))
        guard case .admitted = await rig.gate.admit(key: rig.phone.publicKey) else { Issue.record("not admitted before removal"); return }
        await rig.gate.devicesRemoved([x], version: "2")
        // A list OLDER than the removal (a lagging read) still shows it active: still refused, and kept.
        _ = await rig.gate.refreshRosterNow()
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.removed))
        #expect(await !rig.gate.stillAdmitted(deviceId: x))
        // The saved removal survives a restart (a new gate on the same file, nothing in memory).
        let restarted = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices,
                                                inputGuard: R.inputGuard(posted: false), now: { rig.clock.now() })
        #expect(await restarted.snapshot().removedHere.contains(x))
        #expect(await restarted.admit(key: rig.phone.publicKey) == .refused(.removed))
        // Five seconds later he signs in again: the Cloud gives the sign-in a NEW id (a removed id never comes back),
        // here even with the same browser key; the first list after the removal already shows it active: let in.
        rig.clock.advance(5_000)
        rig.service.set(roster: .init(account: "acct-A", version: "3", devices: [
            .init(deviceId: y, label: "Browser", platform: "web", reachKey: rig.phone.publicKey)]))
        _ = await rig.gate.refreshRosterNow()
        guard case .admitted(let back) = await rig.gate.admit(key: rig.phone.publicKey) else { Issue.record("a fresh sign-in was refused"); return }
        #expect(back.deviceId == y)
        #expect(await !rig.gate.stillAdmitted(deviceId: x), "the removed id itself stays refused for this run")
        // The list at least as new as the removal no longer lists it: forgotten in the file (bounded), the list refuses it.
        let later = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices,
                                            inputGuard: R.inputGuard(posted: false), now: { rig.clock.now() })
        #expect(await !later.snapshot().removedHere.contains(x))
        // Remove pressed on this Mac means the same: refused now, forgotten once the Cloud's newer list drops it, and
        // the next fresh sign-in comes in by itself.
        try await rig.gate.remove(deviceId: y)
        #expect(await rig.gate.admit(key: rig.phone.publicKey) == .refused(.removed))
        await rig.gate.devicesRemoved([y], version: "4")
        let fresh = StaticKeyPair.generate()
        rig.service.set(roster: .init(account: "acct-A", version: "5", devices: [
            .init(deviceId: Self.browserId, label: "Browser", platform: "web", reachKey: fresh.publicKey)]))
        _ = await rig.gate.refreshRosterNow()
        guard case .admitted = await rig.gate.admit(key: fresh.publicKey) else { Issue.record("the sign-in after a Mac Remove was refused"); return }
        #expect(await !BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices,
                                               inputGuard: R.inputGuard(posted: false)).snapshot().removedHere.contains(y))
    }

    @Test("A failed list check keeps the last good list: its expiry still cuts; another account's list is never used")
    func keptListStillCuts() async throws {
        let rig = try await Rig.make()
        rig.service.set(roster: rig.roster(browserEndsAtMs: rig.clock.now() + 300_000))
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        await rig.coordinator.sync()                       // a good list, fetched now
        // The Cloud is blocked; six minutes on, the browser's sign-in has ended by the kept list: cut. The phone stays.
        rig.service.set(failing: true)
        rig.clock.advance(360_000)
        await rig.coordinator.sync()
        #expect(browser.link.closed)
        #expect(!phone.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds() == [R.phoneId])
        // The kept list belongs to the account signed in now: another account (or none) never judges with it.
        #expect(await rig.coordinator.gate.snapshot().devices != nil)
        rig.service.set(account: "acct-B")
        _ = await rig.coordinator.gate.stillAdmitted(deviceId: R.phoneId)
        #expect(await rig.coordinator.gate.snapshot().devices == nil)
        await rig.finish()
    }

    @Test("No good list for 10 minutes cuts every account device (paired stay); they come back by themselves with the next good list")
    func tenMinutesWithoutAList() async throws {
        let rig = try await Rig.make()
        let paired = try await rig.paired()
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        await rig.coordinator.sync()
        rig.service.set(failing: true)
        rig.clock.advance(BackendReachAccountGate.listMissingCutMs - 60_000); rig.steady.advance(BackendReachAccountGate.listMissingCutMs - 60_000)
        await rig.coordinator.sync()
        #expect(!phone.link.closed && !browser.link.closed, "nine minutes without the Cloud: nobody cut yet")
        rig.clock.advance(120_000); rig.steady.advance(120_000)
        await rig.coordinator.sync()
        #expect(phone.link.closed && browser.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds().isEmpty)
        #expect(await paired.closes == 0, "a paired device is never cut by reach")
        // The Cloud is back: the next handshake fetches a good list and is let in, with no click.
        rig.service.set(failing: false)
        guard case .admitted = await rig.coordinator.gate.admit(key: rig.phone.publicKey) else { Issue.record("not back after a good list"); return }
        let again = try await rig.lateHello(R.phoneId, key: rig.phone.publicKey)
        #expect(await again.types.contains("welcome"))
        await rig.finish()
    }

    @Test("The 10 minutes run on the steady clock: the Mac's clock set back an hour still cuts every account device")
    func clockSetBackStillCuts() async throws {
        let rig = try await Rig.make()
        let paired = try await rig.paired()
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        await rig.coordinator.sync()                        // the last good list
        rig.service.set(failing: true)
        rig.clock.advance(-3_600_000)                       // the wall clock is set back an hour
        rig.steady.advance(BackendReachAccountGate.listMissingCutMs + 1_000)
        await rig.coordinator.sync()
        #expect(phone.link.closed && browser.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds().isEmpty)
        #expect(await paired.closes == 0, "a paired device is never cut by reach")
        await rig.finish()
    }

    @Test("The removal's version and the list's version are one counter; a version that is not a plain number is never new enough")
    func versionsAreStrict() {
        #expect(BackendReachAccountGate.versionAtLeast("10", "9"))
        #expect(BackendReachAccountGate.versionAtLeast("9", "9"))
        #expect(!BackendReachAccountGate.versionAtLeast("8", "9"))
        #expect(!BackendReachAccountGate.versionAtLeast("x", "9"))
        #expect(!BackendReachAccountGate.versionAtLeast("10", "x"))
        #expect(!BackendReachAccountGate.versionAtLeast("", "9"))
        #expect(!BackendReachAccountGate.versionAtLeast("-1", "0"))
    }

    @Test("A list whose version is not a plain number never forgets a removal")
    func oddListVersionKeepsTheRemoval() async throws {
        let rig = R.Rig()
        try await rig.on()
        await rig.gate.devicesRemoved([R.phoneId], version: "2")
        rig.service.set(roster: .init(account: "acct-A", version: "v99", devices: []))
        _ = await rig.gate.refreshRosterNow()
        let restarted = BackendReachAccountGate(directory: rig.dir, service: rig.service, notices: rig.notices, inputGuard: R.inputGuard(posted: false))
        #expect(await restarted.snapshot().removedHere.contains(R.phoneId))
    }

    @Test("The second hello check: a cut that lands between the first check and the welcome refuses it and forgets the device")
    func secondHelloCheck() async throws {
        let host = try await R.HostRig.make()
        final class Calls: @unchecked Sendable { private let lock = NSLock(); private var n = 0; func next() -> Int { lock.withLock { n += 1; return n } } }
        let calls = Calls()
        await host.host.setReachJudge(owner: UUID()) { _ in calls.next() == 1 }   // true at the first check, false at the second
        let key = StaticKeyPair.generate().publicKey
        let wire = CutWire()
        var made = BackendRemoteHostWire(address: "reach:x", peerPublicKey: key, send: { await wire.receive($0) }, close: { _, _ in await wire.closed() })
        made.reach = R.admission(key)
        let id = try #require(await host.host.accept(made))
        await host.host.receive(id, text: host.hello("reach:" + R.phoneId))
        #expect(await !wire.types.contains("welcome"))
        #expect(await wire.closes >= 1)
        #expect(await !host.trust.isApproved(BackendReachAdmission.hostDeviceId(R.phoneId)))
        await host.finish()
    }

    @Test("A stopped coordinator never undoes a newer one's hello check")
    func stoppedCoordinatorKeepsTheNewerCheck() async throws {
        let rig = try await Rig.make()
        let older = BackendReachAccountCoordinator(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("td-reach-old-" + UUID().uuidString + ".noindex"),
            service: rig.service, notices: R.Notices(), host: rig.host.host,
            card: { .init(hostId: "ABCDEFGHJKLMNPQRSTUVWXYZ23", hostKey: "k", name: "Mac") }, link: BackendReachRelayLink(),
            inputGuard: R.inputGuard(posted: false), now: { rig.clock.now() })
        await older.start()
        try await rig.on()                                  // the newer coordinator takes the check
        await older.stop()                                  // the old one stops late (sign-out then sign-in again)
        let wire = try await rig.lateHello(R.phoneId, key: rig.phone.publicKey)
        #expect(await wire.types.contains("welcome"), "the newer coordinator's check still answers")
        await rig.coordinator.stop()
        let after = try await rig.lateHello(Self.browserId, key: rig.browser.publicKey)
        #expect(await !after.types.contains("welcome"), "after the newer one stops, nobody of the account is welcomed")
        await rig.host.finish()
    }

    @Test("A device that leaves the account's active list is cut without `reachRemoved`; one merely offline is not removed")
    func droppedFromTheActiveList() async throws {
        let rig = try await Rig.make()
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        // A `devices` push that names nobody, with the list unchanged: nobody is cut.
        await rig.coordinator.event(type: "devices", payload: try NativeRPCValue.parseJSON(Data(#"{"devicesVersion":"10"}"#.utf8)))
        #expect(!phone.link.closed && !browser.link.closed)
        // The browser's sign-in ended on the list (no `reachRemoved`): the next push cuts it, the phone stays.
        rig.service.set(roster: rig.roster(browserActive: false))
        await rig.coordinator.event(type: "devices", payload: try NativeRPCValue.parseJSON(Data(#"{"devicesVersion":"11"}"#.utf8)))
        #expect(browser.link.closed)
        #expect(!phone.link.closed)
        // Without any push: the list ages out and the regular sync cuts the phone once it leaves the list.
        rig.service.set(roster: .init(account: "acct-A", version: "12", devices: []))
        rig.clock.advance(BackendReachAccountGate.rosterMaxAgeMs + 1)
        await rig.coordinator.sync()
        #expect(phone.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds().isEmpty)
        await rig.finish()
    }

    @Test("The switch off cuts every account device's direct link; old paired devices stay")
    func switchOffCutsAll() async throws {
        let rig = try await Rig.make()
        let paired = try await rig.paired()   // paired before reach is on (on, no pairing code can be made)
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        try await rig.coordinator.setEnabled(false)
        #expect(phone.link.closed && browser.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds().isEmpty)
        #expect(rig.engine.released.contains { $0.device == BackendReachAdmission.hostDeviceId(R.phoneId) && $0.force })
        #expect(rig.engine.released.contains { $0.device == BackendReachAdmission.hostDeviceId(Self.browserId) && $0.force })
        #expect(await paired.closes == 0, "a paired device is never cut by reach")
        // A handshake the door let through just before: refused at its hello while the switch is off.
        let late = try await rig.lateHello(R.phoneId, key: rig.phone.publicKey)
        #expect(await !late.types.contains("welcome"))
        await rig.finish()
    }

    @Test("Signing out on this Mac cuts every account device's direct link; old paired devices stay")
    func signOutCutsAll() async throws {
        let rig = try await Rig.make()
        let paired = try await rig.paired()   // paired before reach is on (on, no pairing code can be made)
        try await rig.on()
        let phone = try await rig.onDirectLink(R.phoneId, key: rig.phone.publicKey, platform: "ios", index: 0)
        let browser = try await rig.onDirectLink(Self.browserId, key: rig.browser.publicKey, platform: "web", index: 1)
        rig.service.set(account: nil)
        await rig.coordinator.signedOut()
        #expect(phone.link.closed && browser.link.closed)
        #expect(await rig.host.host.reachConnectedDeviceIds().isEmpty)
        #expect(await !rig.host.trust.isApproved(BackendReachAdmission.hostDeviceId(R.phoneId)))
        #expect(await paired.closes == 0, "a paired device is never cut by reach")
        // Nothing of the account is welcomed after the sign-out, even a handshake already through the door.
        let late = try await rig.lateHello(Self.browserId, key: rig.browser.publicKey)
        #expect(await !late.types.contains("welcome"))
        await rig.finish()
    }
}
