import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class MemoryEventRoutingTests: XCTestCase, @unchecked Sendable {
    func testJobFlowReachesIndependentRegistrySubscribersAndDisconnects() async throws {
        let registry = NativeChannelRegistry()
        let events = BackendMemoryEvents()
        events.connect(registry)
        let mac = MemoryEventCapture(), phone = MemoryEventCapture()
        let macFeed = try await registry.subscribe("job-flow:changed", ownerID: "mac") { mac.add($0) }
        let phoneFeed = try await registry.subscribeAll(ownerID: "phone") { phone.add($0) }
        let log = BackendJobFlowLog(events: events)
        await log.record(.init(at: 1, session: "session", who: "Worker", seat: "seat", kind: .rule, title: "Rule"))
        XCTAssertEqual(mac.count, 1)
        XCTAssertEqual(phone.count, 1)
        events.connect(nil)
        await log.record(.init(at: 2, session: "session", who: "Worker", seat: "seat", kind: .rule, title: "Rule"))
        XCTAssertEqual(phone.count, 1)
        await macFeed.cancelAndWait(); await phoneFeed.cancelAndWait()
    }


}

private final class MemoryEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [NativeRPCEvent] = []
    var values: [NativeRPCEvent] { lock.withLock { stored } }
    var count: Int { values.count }
    func add(_ event: NativeRPCEvent) { lock.withLock { stored.append(event) } }
}
