import XCTest
@testable import TerminalDeckBackend

final class BackendHootScreenMonitorTests: XCTestCase {
    @MainActor private final class Target: BackendHootDisplayRefresh {
        var refreshes = 0
        func displaysChanged() { refreshes += 1 }
    }
    @MainActor private final class Events {
        var callbacks: [@MainActor @Sendable () -> Void] = []
        var removed = 0
    }
    @MainActor func testQueuedEventsStopAndTargetsAreNotRetained() {
        let events = Events()
        let monitor = BackendHootScreenMonitor(observe: { changed in
            events.callbacks.append(changed)
            return { events.removed += 1 }
        })
        let target = Target()
        monitor.start(bar: target)
        XCTAssertEqual(target.refreshes, 1)
        events.callbacks[0](); XCTAssertEqual(target.refreshes, 2)
        monitor.stop(); monitor.stop()
        events.callbacks[0](); XCTAssertEqual(target.refreshes, 2)
        XCTAssertEqual(events.removed, 1)
        var transient: Target? = Target()
        weak var retained = transient
        monitor.start(bar: transient!)
        transient = nil
        XCTAssertNil(retained)
        events.callbacks[1]()
        monitor.stop(); XCTAssertEqual(events.removed, 2)
    }
}
