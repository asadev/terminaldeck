import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// RETRY, safe by default (11 Oct, after the Context-handoff defect: a self-pressing "Try again"
/// asked Hoot again and undid Stop). A retry control never presses itself unless its call site
/// says `autoRetry: true`, and an allowed one presses once on the "lines are back" signal:
/// never on a timer, never twice. Real views in a window that is never the person's; no app
/// launch, no engine, no AI.
@MainActor
final class FORKL3RetryTests: XCTestCase {
    private final class Count { var presses = 0 }

    private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: 360, height: 240))
        window.orderFrontRegardless() // far off every screen; the views need a shown window to run their tasks
        return window
    }
    private func wait(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    /// An old signal, so "it just fired" is not what lets anything press.
    private let longAgo = Date().addingTimeInterval(-3600)

    func testADefaultButtonNeverPressesItself() {
        let count = Count()
        DeckReconnect.shared.linesBackForChecks(now: longAgo)
        let window = host(DeckRetryButton("Try Again", file: "FORKL3RetryTests", line: 1) { count.presses += 1 })
        wait(3.5)
        XCTAssertEqual(count.presses, 0, "not on appearing, not on a timer")
        DeckReconnect.shared.linesBackForChecks()
        wait(1.5)
        XCTAssertEqual(count.presses, 0, "and not on the signal either: only the person presses a default button")
        window.orderOut(nil); window.contentView = nil
    }

    func testAnAllowedButtonPressesOnceOnTheSignalAndNeverOnATimer() {
        let count = Count()
        DeckReconnect.shared.linesBackForChecks(now: longAgo)
        let window = host(DeckRetryButton("Try Again", autoRetry: true, file: "FORKL3RetryTests", line: 2) { count.presses += 1 })
        wait(3.5)
        XCTAssertEqual(count.presses, 0, "appearing by itself presses nothing, however long it waits")
        DeckReconnect.shared.linesBackForChecks()
        wait(1.5)
        XCTAssertEqual(count.presses, 1, "the lines came back: one press")
        wait(3.0)
        XCTAssertEqual(count.presses, 1, "never twice for one signal")
        DeckReconnect.shared.linesBackForChecks()
        wait(1.5)
        XCTAssertEqual(count.presses, 2, "the next signal earns one more")
        window.orderOut(nil); window.contentView = nil
    }

    func testAnAllowedButtonThatAppearsInTheSameMomentAsTheSignalPressesOnce() {
        let count = Count()
        DeckReconnect.shared.linesBackForChecks() // the helper was just lost; the page's read fails a moment later
        let window = host(DeckRetryButton("Try Again", autoRetry: true, file: "FORKL3RetryTests", line: 3) { count.presses += 1 })
        wait(1.5)
        XCTAssertEqual(count.presses, 1)
        wait(3.0)
        XCTAssertEqual(count.presses, 1)
        window.orderOut(nil); window.contentView = nil
    }

    func testASwitchedOffAllowedButtonIsNeverPressedForThePage() {
        let count = Count()
        let window = host(DeckRetryButton("Try Again", autoRetry: true, file: "FORKL3RetryTests", line: 4) { count.presses += 1 }.disabled(true))
        DeckReconnect.shared.linesBackForChecks()
        wait(1.5)
        XCTAssertEqual(count.presses, 0)
        window.orderOut(nil); window.contentView = nil
    }

    func testTheSharedErrorAndEmptyStatesAreSafeByDefaultToo() {
        let plainError = Count(), plainEmpty = Count(), allowedEmpty = Count()
        DeckReconnect.shared.linesBackForChecks(now: longAgo)
        let first = host(DeckError(message: "Could not read this.", retry: { plainError.presses += 1 }, file: "FORKL3RetryTests", line: 5))
        let second = host(NativePageEmpty(symbol: "checklist", title: "Could not be read",
            action: PageEmptyAction(label: "Try again", file: "FORKL3RetryTests", line: 6, perform: { plainEmpty.presses += 1 })))
        let third = host(NativePageEmpty(symbol: "checklist", title: "Tasks could not be read",
            action: PageEmptyAction(label: "Try again", autoRetry: true, file: "FORKL3RetryTests", line: 7, perform: { allowedEmpty.presses += 1 })))
        wait(3.0)
        XCTAssertEqual([plainError.presses, plainEmpty.presses, allowedEmpty.presses], [0, 0, 0], "nothing presses itself on appearing")
        DeckReconnect.shared.linesBackForChecks()
        wait(1.5)
        XCTAssertEqual([plainError.presses, plainEmpty.presses, allowedEmpty.presses], [0, 0, 1], "only the allowed one, once, on the signal")
        for window in [first, second, third] { window.orderOut(nil); window.contentView = nil }
    }
}
