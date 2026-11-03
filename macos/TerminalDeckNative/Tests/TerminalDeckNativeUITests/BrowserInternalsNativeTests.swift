import AppKit
import Observation
import WebKit
import XCTest
@testable import TerminalDeckNative

@MainActor @Observable
final class BrowserInternalsReadyState { var ready = false }

@MainActor
final class BrowserInternalsNativeTests: XCTestCase {

    func testSignalWaitHandlesAChangeDeadlineAndCancellation() async {
        let state = BrowserInternalsReadyState()
        let waiter = Task { await NativeBrowserSignalWait.until(timeout: .seconds(2)) { state.ready } }
        await Task.yield()
        state.ready = true
        let changed = await waiter.value
        XCTAssertTrue(changed)
        state.ready = false
        let expired = await NativeBrowserSignalWait.until(timeout: .milliseconds(1)) { state.ready }
        XCTAssertFalse(expired)
        let cancelled = Task { await NativeBrowserSignalWait.until { state.ready } }
        cancelled.cancel()
        let stopped = await cancelled.value
        XCTAssertFalse(stopped)
    }

    func testCaptureHostRestoresOnlyThePageItStillOwns() {
        _ = NSApplication.shared
        let previous = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let frame = NSRect(x: 4, y: 5, width: 500, height: 300)
        let page = NSView(frame: frame)
        previous.addSubview(page)
        let capture = host()
        capture.contentView = page
        capture.releasePage(page, previousSuperview: previous, previousFrame: frame)
        XCTAssertTrue(page.superview === previous)
        XCTAssertEqual(page.frame, frame)

        let otherCapture = host(), visible = host()
        defer { visible.close() }
        otherCapture.contentView = page
        let visibleContent = NSView(frame: frame)
        visible.contentView = visibleContent
        visibleContent.addSubview(page)
        let adoptedFrame = NSRect(x: 0, y: 0, width: 200, height: 150)
        page.frame = adoptedFrame
        otherCapture.releasePage(page, previousSuperview: previous, previousFrame: frame)
        XCTAssertTrue(page.superview === visibleContent)
        XCTAssertEqual(page.frame, adoptedFrame)
    }

    func testHiddenCaptureDoesNotSignalVisibleAndKeyboardDismantleIsIdempotent() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = NativeBrowserWebView(frame: .zero, configuration: configuration)
        var shown = false
        page.windowChanged = { shown = $0 }
        let capture = host()
        capture.contentView = page
        XCTAssertFalse(shown)
        capture.contentView = nil
        capture.close()
        let visible = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 30, height: 30), styleMask: [], backing: .buffered, defer: false)
        visible.isReleasedWhenClosed = false
        visible.contentView = page
        XCTAssertTrue(shown)
        visible.contentView = nil; visible.close()
        XCTAssertFalse(shown)

        let catcher = NativeBrowserKeyCatcher.KeyCatcherView()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 30, height: 30), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = catcher
        NativeBrowserKeyCatcher.dismantleNSView(catcher, coordinator: ())
        NativeBrowserKeyCatcher.dismantleNSView(catcher, coordinator: ())
        let monitor = Mirror(reflecting: catcher).children.first { $0.label == "monitor" }?.value
        XCTAssertEqual(monitor.map { Mirror(reflecting: $0).children.count }, 0)
        window.contentView = nil; window.close()
    }

    private func host() -> NativeBrowserCaptureWindow {
        let window = NativeBrowserCaptureWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
