import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// R3: a trust or approval press that follows the app's own remote input is refused.
@Suite("Cloud remote-input guard — a press that follows Mac reach input is not the person's")
struct CloudRemoteInputGuardTests {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var last: UInt64?
        private var time: UInt64 = 100_000_000_000
        private var broken = false
        func post() { lock.withLock { last = time } }
        func advance(_ nanoseconds: UInt64) { lock.withLock { time += nanoseconds } }
        func setLast(_ value: UInt64?) { lock.withLock { last = value } }
        func breakReads() { lock.withLock { broken = true } }
        func guarded() -> BackendRemoteInputGuard {
            .init(lastPost: { () throws -> UInt64? in
                try self.lock.withLock { () throws -> UInt64? in
                    if self.broken { throw CloudFailure.unavailable }
                    return self.last
                }
            }, now: { self.lock.withLock { self.time } })
        }
    }

    @Test func aPressWithinTwoSecondsOfRemoteInputIsRefused() {
        let record = Record(), remote = record.guarded()
        #expect(!remote.refusesPress()) // nothing was ever posted
        record.post()
        #expect(remote.refusesPress()) // the press IS the posted event
        record.advance(1_999_000_000)
        #expect(remote.refusesPress())
        record.advance(1_000_000)
        #expect(!remote.refusesPress()) // two seconds have passed
        // A mark later than "now" is treated as just now, never as long ago.
        record.setLast(900_000_000_000)
        #expect(remote.refusesPress())
        #expect(BackendRemoteInputGuard.pressWindow == 2_000_000_000)
    }
    @Test func aRecordThatCannotBeReadRefuses() {
        let record = Record()
        record.breakReads()
        #expect(record.guarded().refusesPress())
        #expect(record.guarded().remoteControlActive())
    }
    @Test func remoteControlCountsAsGoingOnUntilItHasBeenQuiet() {
        let record = Record(), remote = record.guarded()
        #expect(!remote.remoteControlActive())
        record.post()
        #expect(remote.remoteControlActive())
        record.advance(BackendRemoteInputGuard.sessionWindow - 1)
        #expect(remote.remoteControlActive())
        record.advance(1)
        #expect(!remote.remoteControlActive())
    }
    @Test func theMacReachPathRecordsEveryPost() async throws {
        // `.rotate` and `.button` post no event on a Mac, so nothing moves or clicks here; the record is still made,
        // because it is taken before the event is chosen. (In a test process the record has a name of its own, S15.)
        let before = BackendRemoteInputMark.now()
        BackendMacReachInput.postNow(.rotate, bounds: .zero)
        let first = BackendRemoteInputMark.inProcessMark()
        #expect(first >= before)
        let seen = try #require(try BackendRemoteInputMark.lastPost())
        #expect(seen >= first)
        #expect(BackendRemoteInputGuard.system.refusesPress())
        #expect(BackendRemoteInputGuard.system.remoteControlActive())
        try await Task.sleep(for: .milliseconds(5))
        await BackendMacReachInput.post(.button("fixture"), bounds: .zero)
        // The in-process mark moves with EVERY post, also inside the tenth of a second in which the system-wide
        // record is not written again (S8).
        let second = BackendRemoteInputMark.inProcessMark()
        #expect(second > first)
    }
    @Test func aPressIsJudgedByItsOwnTimeNotByWhenItWasHandled_S1() {
        let record = Record(), remote = record.guarded()
        let posted: UInt64 = 100_000_000_000
        // The phone clicked at 100 s. The app was busy and got round to that click three seconds later.
        record.post()
        record.advance(3_000_000_000)
        // Judged by "now" alone the click has aged past the two seconds: this is the hole.
        #expect(!remote.refusesPress())
        // Judged by the press's own time it is what it is: a press made as the remote input was posted.
        #expect(remote.refusesPress(at: posted))
        #expect(remote.refusesPress(at: posted + 500_000_000))
        // The person's own press, made well after the remote input, is taken even when it is handled late.
        #expect(!remote.refusesPress(at: posted + 2_500_000_000))
        // An event time that cannot be right is not used and now decides: later than now, or over a minute old.
        #expect(!remote.refusesPress(at: 900_000_000_000))
        record.advance(120_000_000_000)
        #expect(!remote.refusesPress(at: posted))
        #expect(BackendRemoteInputGuard.pressEventMaxAge == 60_000_000_000)
    }
    @Test func theSystemWideRecordIsWrittenAtMostTenTimesASecond_S8() {
        let mark = BackendRemoteInputLocalMark()
        let interval = BackendRemoteInputMark.sharedWriteInterval
        #expect(interval == 100_000_000)
        // The first post writes both records.
        var at: UInt64 = 1_000_000_000
        let firstWrite = mark.set(at, sharedEvery: interval)
        #expect(firstWrite)
        // A phone sending 120 events in one second: the in-process mark moves every time …
        var written = 0
        var moved = 0
        for _ in 0..<120 {
            at += 8_333_333
            if mark.set(at, sharedEvery: interval) { written += 1 }
            if mark.get() == at { moved += 1 }
        }
        #expect(moved == 120)
        // … and the system-wide record (one message to the system's notify service) about nine times, not 120.
        #expect(written >= 9)
        #expect(written <= 10)
        // A reader allows for the interval, so a refusal can only last longer; a cleared record stays cleared.
        #expect(BackendRemoteInputMark.allowingForWriteInterval(0) == 0)
        #expect(BackendRemoteInputMark.allowingForWriteInterval(5_000) == 5_000 + interval)
    }
    @Test func aTestRunNeverWritesTheRecordAnInstalledAppReads_S15() {
        #expect(BackendRemoteInputMark.inTestProcess())
        #expect(BackendRemoteInputMark.name != BackendRemoteInputMark.realName)
        #expect(BackendRemoteInputMark.name.hasPrefix(BackendRemoteInputMark.realName + ".test."))
        #expect(BackendRemoteInputMark.recordName(testProcess: false, pid: 77) == "dev.terminaldeck.reach.input-posted")
        #expect(BackendRemoteInputMark.recordName(testProcess: true, pid: 77) == "dev.terminaldeck.reach.input-posted.test.77")
    }
    @Test func aClearedSystemWideRecordLeavesTheInProcessMarkStanding() {
        // Any program on this Mac can clear or set the system-wide record; nothing outside the app can touch the
        // in-process mark. The guard takes the later of the two, so clearing the one never hides the other.
        #expect(BackendRemoteInputMark.latest(shared: 0, inProcess: 0) == nil)
        #expect(BackendRemoteInputMark.latest(shared: 0, inProcess: 5_000) == 5_000)
        #expect(BackendRemoteInputMark.latest(shared: 7_000, inProcess: 5_000) == 7_000)
        #expect(BackendRemoteInputMark.latest(shared: 3_000, inProcess: 5_000) == 5_000)
        // The app's own posting path sets the in-process mark, and only ever forward.
        let before = BackendRemoteInputMark.inProcessMark()
        BackendMacReachInput.postNow(.rotate, bounds: .zero)
        let after = BackendRemoteInputMark.inProcessMark()
        #expect(after > before)
        #expect(after >= BackendRemoteInputMark.now() - 5_000_000_000)
    }
    @Test func aTrustPressThatFollowsRemoteInputStoresNothing() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        let jwk = CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])), y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
        let id = "10000000-0000-4000-8000-00000000000a"
        await f.server.setOthers([.init(deviceId: id, label: "MacBook Air", platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                                        lastSeenAt: 0, signPublicJwk: jwk, wrapPublicJwk: jwk)])
        try await f.account.refresh()
        let rows = await f.account.state().trust
        let row = try #require(rows.first(where: { $0.deviceId == id }))
        let drawn = try #require(BackendCloudTrustCapture(row: row))
        let before = try await f.trust.list()
        // The phone pressed the button: refused, by the account and by the list itself, whoever calls.
        f.remoteInput.set(true)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.account.trustDevices([drawn]) }
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.account.trustDevices([drawn], restore: true) }
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.trust.trust([drawn], restore: false, latest: nil) }
        // It is decided before Cloud is asked anything: an unreachable device list does not turn it into a yes.
        await f.transport.setDeviceListOffline(true)
        await #expect(throws: BackendCloudTrustRefusal.remoteInput) { try await f.account.trustDevices([drawn]) }
        await f.transport.setDeviceListOffline(false)
        let after = try await f.trust.list()
        #expect(after == before)
        // The person presses it later, with no remote input: trusted.
        f.remoteInput.set(false)
        try await f.account.trustDevices([drawn])
        let trusted = try await f.trust.list()
        #expect(trusted.devices.contains(where: { $0.deviceId == id && $0.how == "click" }))
    }
}
