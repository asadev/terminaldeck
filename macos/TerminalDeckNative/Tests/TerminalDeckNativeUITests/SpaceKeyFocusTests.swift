import AppKit
import WebKit
import XCTest
import TerminalDeckNativeCore
@preconcurrency import SwiftTerm
@testable import TerminalDeckNative

@MainActor final class SpaceKeyFocusTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    private final class Sink: TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func space(_ window: NSWindow, up: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: [],
                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }
    func testAttachedBrowserAndCachedChartDoNotEatTerminalSpace() throws {
        let window = window()
        defer { window.close() }
        let terminal = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 450, height: 500),
                                        font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let sink = Sink(); terminal.terminalDelegate = sink
        let browser = NativeBrowserTab(record: BrowserTabRecord(isolated: true), owner: .shared)
        XCTAssertFalse(browser.handleKey(space(window)), "The browser shortcut handler must pass plain Space through")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = NativeBrowserWebView(frame: NSRect(x: 450, y: 0, width: 450, height: 500), configuration: configuration)
        let chart = ORGCanvasInput.InputView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(page)
        window.contentView!.addSubview(chart)
        window.contentView!.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        defer { chart.stop() }
        // Even a visible chart must respect terminal focus; then repeat with the cached chart.
        for active in [true, false] {
            chart.active = active
            let event = try XCTUnwrap(chart.filter(space(window)))
            XCTAssertTrue(window.firstResponder === terminal)
            // Let the whole window offer the key to its views before normal terminal delivery.
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        }
        XCTAssertEqual(sink.bytes, [32, 32], "Spaces must reach the terminal's real outgoing byte path")
    }
    func testTextFieldAndWebContentKeepTheirSpace() throws {
        let window = window(); defer { window.close() }
        let chart = ORGCanvasInput.InputView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(chart); defer { chart.stop() }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView!.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        window.sendEvent(try XCTUnwrap(chart.filter(space(window))))
        XCTAssertEqual(field.string, " ")
        let page = WKWebView(frame: field.frame)
        let content = NSView(frame: field.bounds)
        page.addSubview(content)
        XCTAssertTrue(NativeKeyboardFocus.isTyping(page))
        XCTAssertTrue(NativeKeyboardFocus.isTyping(content), "WebKit's internal responder is below WKWebView")
    }
    func testHiddenChartPassesSpaceEvenWithoutATextResponder() {
        let window = window(); defer { window.close() }
        let chart = ORGCanvasInput.InputView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(chart); defer { chart.stop() }
        window.makeFirstResponder(nil)
        chart.active = false
        XCTAssertNotNil(chart.filter(space(window)))
    }
    func testVisibleChartStillPansAndReleasesSpaceWhenItLeaves() {
        let window = window(); defer { window.close() }
        let chart = ORGCanvasInput.InputView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(chart); defer { chart.stop() }
        window.makeFirstResponder(nil)
        var held: [Bool] = []; chart.space = { held.append($0) }
        XCTAssertNil(chart.filter(space(window)))
        chart.active = false
        XCTAssertEqual(held, [true, false])
        XCTAssertNotNil(chart.filter(space(window, up: true)))
    }
    func testTourOnlyTakesPlaybackKeysInItsOwnPanel() {
        let session = window(), panel = window()
        defer { session.close(); panel.close() }
        XCTAssertFalse(NativeKeyboardFocus.tourMayTakeKey(space(session), panel: panel))
        XCTAssertFalse(NativeKeyboardFocus.tourMayTakeKey(space(session), panel: nil))
        panel.makeFirstResponder(nil)
        XCTAssertTrue(NativeKeyboardFocus.tourMayTakeKey(space(panel), panel: panel))
        let field = NSTextView(frame: panel.contentView!.bounds)
        panel.contentView!.addSubview(field); panel.makeFirstResponder(field)
        XCTAssertFalse(NativeKeyboardFocus.tourMayTakeKey(space(panel), panel: panel))
    }
}
