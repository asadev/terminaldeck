import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Item 74 / review-install-24 S11: the Mac pushes a session's context reading to the phones following it when its
/// transcript moves, at most once per 2 s per session, instead of each phone asking every 10 s.
final class UsageContextPushTests: XCTestCase {
    actor Log {
        var reads: [String] = [], sends: [(UUID, BackendRemoteServerMessage)] = []
        var now = 100.0
        func read(_ id: String) -> NativeRPCValue { reads.append(id); return .object([.init("tokens", .number(1234)), .init("percent", .number(12))]) }
        func sent(_ c: UUID, _ m: BackendRemoteServerMessage) { sends.append((c, m)) }
        func advance(_ s: Double) { now += s }
        func time() -> Double { now }
    }

    func testAPhoneFollowingASessionGetsOneCoalescedPushPerTwoSeconds() async throws {
        let log = Log()
        let push = BackendRemoteServeUsagePush(clock: { 0 }, sleep: { _ in })
        await push.bind(read: { id, _ in await log.read(id) }, send: { c, m in await log.sent(c, m) })
        let phone = UUID(), other = UUID()
        let caller = NativeRPCContext(caller: .pairedDevice, ownerID: "phone", capabilities: [])
        await push.follow(connection: phone, sessionID: "s1", caller: caller)
        await push.follow(connection: other, sessionID: "s2", caller: caller)
        await push.transcriptChanged("nobody-follows")
        var reads = await log.reads
        XCTAssertTrue(reads.isEmpty, "no phone follows it: nothing is read")
        await push.transcriptChanged("s1")
        let sends = await log.sends
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.0, phone)
        let frame = try XCTUnwrap(sends.first?.1)
        XCTAssertEqual(frame.kind, .usageReading)
        XCTAssertEqual(frame.value["rid"].string, "push:context")
        XCTAssertEqual(frame.value["want"].string, "context")
        XCTAssertEqual(frame.value["id"].string, "s1")
        XCTAssertEqual(frame.value["answer"]["reading"]["tokens"].number, 1234)
        reads = await log.reads
        XCTAssertEqual(reads, ["s1"])
        await push.disconnected(phone)
        let count = await push.followerCount("s1")
        XCTAssertEqual(count, 0)
    }

    func testABurstWaitsOutTheSpacing() async throws {
        actor Waits { var total = 0.0; func add(_ s: Double) { total += s } }
        let waits = Waits(), log = Log()
        let push = BackendRemoteServeUsagePush(clock: { 10 }, sleep: { await waits.add($0) })
        await push.bind(read: { id, _ in await log.read(id) }, send: { c, m in await log.sent(c, m) })
        await push.follow(connection: UUID(), sessionID: "s1", caller: NativeRPCContext(caller: .pairedDevice, ownerID: "p", capabilities: []))
        await push.transcriptChanged("s1") // first: at once
        await push.transcriptChanged("s1") // same instant: waits the 2 s spacing first
        let waited = await waits.total
        XCTAssertEqual(waited, BackendRemoteServeUsagePush.spacing, accuracy: 0.001)
        let sends = await log.sends.count
        XCTAssertEqual(sends, 2)
    }
}
