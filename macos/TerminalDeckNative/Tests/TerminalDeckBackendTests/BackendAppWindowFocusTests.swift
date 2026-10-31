import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendAppWindowFocusTests: XCTestCase {
    @MainActor private final class Counter { var count = 0; func focus() { count += 1 } }
    @MainActor func testEveryWindowFocusAndIdempotentDetach() {
        let center = NotificationCenter(), counter = Counter()
        let subscription = BackendAppWindowFocus.subscribe(center: center) { counter.focus() }
        center.post(name: BackendAppWindowFocus.event, object: "main")
        center.post(name: BackendAppWindowFocus.event, object: "popout")
        XCTAssertEqual(counter.count, 2)
        subscription.cancel(); subscription.cancel()
        center.post(name: BackendAppWindowFocus.event, object: "main")
        XCTAssertEqual(counter.count, 2)
    }
    @MainActor func testNoEmitterIsSafeAndDoesNotInventFocus() {
        let counter = Counter(), subscription = BackendAppWindowFocus.subscribe(center: nil) { counter.focus() }
        subscription.cancel(); XCTAssertEqual(counter.count, 0)
    }
    @MainActor func testReleasingHandleDetachesObserver() {
        let center = NotificationCenter(), counter = Counter()
        var subscription: BackendAppWindowFocusSubscription? = BackendAppWindowFocus.subscribe(center: center) { counter.focus() }
        center.post(name: BackendAppWindowFocus.event, object: nil); XCTAssertEqual(counter.count, 1)
        subscription = nil
        center.post(name: BackendAppWindowFocus.event, object: nil); XCTAssertEqual(counter.count, 1)
        XCTAssertNil(subscription)
    }
}
