import AppKit
import Observation
import SwiftUI
@preconcurrency import SwiftTerm
import WebKit
import XCTest
@testable import TerminalDeckNative

/// The real sealed browser wrapper, deliberately left unloaded. No content-rule store,
/// bundled resources, network navigation or model/RPC operation is started.
@MainActor final class ComposerLeak1112bSealedInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }

    @MainActor @Observable final class State {
        var showCode = false
        var active = true
        var height: CGFloat = 160
        var loading = true
        var failed = false
    }

    private struct Browser: View {
        @Bindable var state: State
        let parentScope: NativeSessionInputScope
        var body: some View {
            NativeChatSealedBrowser(source: "fixture", kind: "mcp-app", dark: false, bridge: nil,
                                    height: $state.height, loading: $state.loading, failed: $state.failed, fixtureMode: true)
                .nativeSessionInputScope(ownerID: "sealed-fixture-preview")
                .environment(\.nativeScreenActive, state.active && !state.showCode)
                .environment(\.nativeSessionInputScope, parentScope)
                .frame(width: 580, height: 200)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
    private func window(_ view: NSView, key: Bool = true) -> ScratchWindow {
        let result = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 650, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        result.keyboardActive = key
        result.isReleasedWhenClosed = false
        result.contentView = view
        return result
    }

    func testActualSealedWrapperDetachesHiddenInputAndKeepsItsDocumentWithoutTakingFocus() throws {
        let state = State()
        let scope = NativeSessionInputScope()
        let host = NSHostingView(rootView: Browser(state: state, parentScope: scope))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 300))
        host.frame = root.bounds
        root.addSubview(host)
        let other = NSTextView(frame: NSRect(x: 0, y: 230, width: 180, height: 40))
        root.addSubview(other)
        let window = self.window(root)
        defer { window.contentView = nil; window.close() }
        settle(root)
        let slot = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionWebSlot }.first)
        let page = try XCTUnwrap(slot.page)
        XCTAssertTrue(page.window === window)
        XCTAssertTrue(window.makeFirstResponder(page))
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(responder === page || responder.isDescendant(of: page))
        let navigationDelegate = page.navigationDelegate
        XCTAssertNotNil(navigationDelegate)

        state.showCode = true
        settle(root)
        XCTAssertNil(page.window, "The code toggle retires WebKit's entire private text-input subtree")
        XCTAssertFalse(window.firstResponder === responder)
        XCTAssertTrue(slot.page === page, "Keep the exact document and its interactive state alive")
        XCTAssertTrue(page.navigationDelegate === navigationDelegate)
        XCTAssertNil(page.url, "The inert fixture never starts loading its source")

        XCTAssertTrue(window.makeFirstResponder(other))
        state.showCode = false
        settle(root)
        XCTAssertTrue(page.window === window)
        XCTAssertTrue(slot.page === page)
        XCTAssertTrue(window.firstResponder === other, "Reattaching a visual cannot take another field's keyboard")
        XCTAssertTrue(window.makeFirstResponder(page))
        // Parent closure reaches the retained child without a local SwiftUI render.
        scope.setActive(false)
        XCTAssertNil(page.window)
        XCTAssertTrue(page.navigationDelegate === navigationDelegate)
        scope.setActive(true)
        settle(root)
        XCTAssertTrue(page.window === window)
        XCTAssertFalse(window.firstResponder === page, "Showing a retained page does not request first responder")
    }

    func testBackgroundSlotCannotPullSealedPageFromKeyWindowOrStealItsKeyboard() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let firstSlot = NativeSessionWebSlot(frame: NSRect(x: 0, y: 0, width: 500, height: 220))
        let nextSlot = NativeSessionWebSlot(frame: NSRect(x: 0, y: 0, width: 500, height: 220))
        let first = window(firstSlot)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 300))
        root.addSubview(nextSlot)
        let field = NSTextView(frame: NSRect(x: 0, y: 230, width: 180, height: 40))
        root.addSubview(field)
        let second = window(root, key: false)
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        firstSlot.show(page, active: true)
        XCTAssertTrue(first.makeFirstResponder(page))
        let previousResponder = first.firstResponder
        nextSlot.show(page, active: true)
        XCTAssertTrue(page.window === first)
        XCTAssertTrue(first.firstResponder === previousResponder)

        first.keyboardActive = false
        second.keyboardActive = true
        XCTAssertTrue(second.makeFirstResponder(field))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        XCTAssertTrue(page.window === second)
        XCTAssertTrue(second.firstResponder === field)
        XCTAssertNil(page.url)
    }
    func testBothVisibleSplitSelectionReleasesWebKeyboardToPendingSelectedTerminal() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        let web = NativeSessionWebSlot(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        let terminal = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 220),
                                        font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let container = DeckTerminalContainer(terminal: terminal)
        let session = DeckTerminalSlot(container: container, active: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 650, height: 300))
        root.addSubview(web)
        root.addSubview(session)
        let window = self.window(root)
        defer { _ = container; window.contentView = nil; window.close() }
        web.show(page, active: true, selected: true)
        XCTAssertTrue(window.makeFirstResponder(page))
        session.setActive(true)
        XCTAssertFalse(window.firstResponder === terminal, "The still-selected web editor initially keeps its legitimate keyboard")
        web.show(page, active: true, selected: false)
        XCTAssertTrue(page.window === window, "An unselected visible split retains its document on screen")
        XCTAssertTrue(window.firstResponder === terminal, "Releasing web focus completes the selected terminal's pending focus request")
        XCTAssertFalse(web.inputRule.acceptsFocus)
    }

}
