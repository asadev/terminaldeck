import AppKit
import Observation
import SwiftUI
@preconcurrency import SwiftTerm
import WebKit
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// Production browser input surfaces with fixture data and an unloaded,
/// nonpersistent WKWebView. No shared browser store, engine or app is started.
@MainActor final class ComposerLeak1112bBrowserInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }

    @Observable final class State {
        var active = true
        var text = "https://example.test"
        var selection: TextSelection?
        var unrelated = false
        var preparations = 0
    }

    private struct AddressCompletion: View {
        @Bindable var state: State
        var body: some View {
            NativeSessionTextField("Address", text: $state.text, selection: $state.selection)
                .nativeSessionInputScope(ownerID: "browser-address-fixture")
                .environment(\.nativeScreenActive, state.active)
                .opacity(state.unrelated ? 0.99 : 1)
                .frame(width: 560, height: 90)
        }
    }

    private struct CaptureSend: View {
        @Bindable var state: State
        var body: some View {
            NativeBrowserSendRow(placeholder: "What should change?", needsText: true,
                                 multiline: true, autofocus: false,
                                 fixture: .object([.init("sessions", .array([])), .init("targetId", .string("hoot")),
                                                   .init("note", .string("This capture's own note"))]),
                                 makeLine: { text in state.preparations += 1; return text })
                .nativeSessionInputScope(ownerID: "browser-capture-fixture")
                .environment(\.nativeScreenActive, state.active)
                .opacity(state.active ? 1 : 0)
                .frame(width: 560, height: 180)
        }
    }

    @MainActor @Observable final class CoveredPage {
        var covered = false
        var parentActive = true
        var selected = true
        var annotation = "Annotation's own note"
        let page: WKWebView
        init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = WKWebView(frame: .zero, configuration: configuration)
            DeckWebPaintHost.markPainted(page)
        }
    }

    private struct BrowserWithNativeCover: View {
        @Bindable var state: CoveredPage
        var body: some View {
            ZStack {
                // The same production boundary used for Annotate/Draw and Home.
                NativeBrowserPageHost(webView: state.page)
                    .modifier(NativeBrowserPageVisibility(covered: state.covered, selected: state.selected))
                if state.covered {
                    NativeSessionTextField("Annotation note", text: $state.annotation)
                }
            }
            .nativeSessionInputScope(ownerID: "browser-native-cover-fixture")
            .environment(\.nativeScreenActive, state.parentActive)
            .frame(width: 640, height: 280)
        }
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func window(_ content: NSView, key: Bool = true) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 680, height: 340),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.keyboardActive = key
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func fields(_ root: NSView) -> [NativeSessionTextControl] {
        (root as? NativeSessionTextControl).map { [$0] } ?? root.subviews.flatMap(fields)
    }

    func testBrowserAddressCompletionSelectsUTF16SuffixAndReplacesItOnNextInput() throws {
        let state = State()
        let host = NSHostingView(rootView: AddressCompletion(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let field = try XCTUnwrap(fields(host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let completed = "https://example.test/🦉tail"
        let start = completed.index(completed.startIndex, offsetBy: state.text.count)
        state.text = completed
        state.selection = TextSelection(range: start..<completed.endIndex)
        settle(host)

        let suffix = NSRange(start..<completed.endIndex, in: completed)
        XCTAssertEqual(editor.selectedRange(), suffix, "Inline completion selects the actual UTF-16 suffix, including emoji")
        editor.insertText("/next", replacementRange: editor.selectedRange())
        settle(host)
        XCTAssertEqual(state.text, "https://example.test/next")
        XCTAssertNil(state.selection, "A real edit consumes the old completion selection")
        let caret = editor.selectedRange()
        state.unrelated.toggle()
        settle(host)
        XCTAssertEqual(editor.selectedRange(), caret, "An unrelated render cannot reselect an old completion tail")
    }

    func testActualBrowserCaptureSendFieldRejectsRetainedHiddenInputAndSubmit() throws {
        let state = State()
        let host = NSHostingView(rootView: CaptureSend(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let field = try XCTUnwrap(fields(host).first)
        XCTAssertEqual(field.stringValue, "This capture's own note")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
        editor.insertText(" accepted", replacementRange: editor.selectedRange())
        settle(host)
        let accepted = field.stringValue
        XCTAssertTrue(accepted.hasSuffix(" accepted"))

        state.active = false
        settle(host)
        XCTAssertFalse(window.firstResponder === editor)
        editor.insertText(" hidden dictation", replacementRange: .init(location: NSNotFound, length: 0))
        editor.setMarkedText("hidden composition", selectedRange: .init(location: 0, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        editor.unmarkText()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        field.setAccessibilityValue("hidden accessibility change")
        XCTAssertEqual(field.stringValue, accepted)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(state.preparations, 0)
    }

    func testHiddenBrowserPageDetachesRealWKResponderAndReleasesSelectedSessionKeyboard() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        DeckWebPaintHost.markPainted(page)
        let browser = NativeBrowserPageSlot(frame: .init(x: 0, y: 0, width: 640, height: 280))
        let terminal = DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240),
                                        font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        // Retain the long-lived session container exactly as its real model does.
        let container = DeckTerminalContainer(terminal: terminal)
        let session = DeckTerminalSlot(container: container, active: false)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        root.addSubview(browser)
        root.addSubview(session)
        let window = self.window(root)
        defer { _ = container; window.contentView = nil; window.close() }
        browser.show(page, active: true)
        XCTAssertTrue(window.makeFirstResponder(page))
        let first = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(first === page || first.isDescendant(of: page))

        // Selection may arrive before the outgoing cached browser updates.
        session.setActive(true)
        browser.show(page, active: false)
        XCTAssertNil(page.window, "The hidden browser's private text subtree must leave the keyboard's window")
        XCTAssertTrue(window.firstResponder === terminal)
        browser.show(page, active: true)
        XCTAssertTrue(page.window === window, "Reattaching retains the same web view without navigation")
        XCTAssertTrue(window.firstResponder === terminal, "Returning the browser subtree must not steal the keyboard")
        XCTAssertNil(page.url)
    }

    func testRestoredBackgroundBrowserHostCannotTakeTheKeyWindowsPage() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        DeckWebPaintHost.markPainted(page)
        let original = NativeBrowserPageSlot(frame: .zero)
        let restored = NativeBrowserPageSlot(frame: .zero)
        let first = self.window(original)
        let second = self.window(restored, key: false)
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        original.show(page, active: true)
        restored.show(page, active: true)
        XCTAssertTrue(page.window === first)

        first.keyboardActive = false
        second.keyboardActive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        XCTAssertTrue(page.window === second)
    }

    func testBothVisibleBrowserAndSessionHandKeyboardOverWhenBrowserLosesSelection() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        DeckWebPaintHost.markPainted(page)
        let browser = NativeBrowserPageSlot(frame: .init(x: 0, y: 0, width: 320, height: 280))
        let terminal = DeckTerminalView(frame: .init(x: 0, y: 0, width: 320, height: 240),
                                        font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let container = DeckTerminalContainer(terminal: terminal)
        let session = DeckTerminalSlot(container: container, active: true, focus: false)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        root.addSubview(browser)
        root.addSubview(session)
        let window = self.window(root)
        defer { _ = container; window.contentView = nil; window.close() }
        browser.show(page, active: true, selected: true)
        XCTAssertTrue(window.makeFirstResponder(page))

        // Both panes remain visible; selection changes are not opacity changes.
        session.show(container, active: true, focus: true)
        browser.show(page, active: true, selected: false)
        XCTAssertTrue(page.window === window, "Losing selection must keep a visible browser page attached")
        XCTAssertTrue(window.firstResponder === terminal, "A visible but unselected WK client cannot hold the selected session's keyboard")
        XCTAssertTrue(terminal.acceptsUserInput)

        // Exercise the other SwiftUI update order too.
        session.show(container, active: true, focus: false)
        browser.show(page, active: true, selected: true)
        XCTAssertTrue(window.makeFirstResponder(page))
        browser.show(page, active: true, selected: false)
        session.show(container, active: true, focus: true)
        XCTAssertTrue(page.window === window)
        XCTAssertTrue(window.firstResponder === terminal)
    }

    func testNativeMarkupBoundaryDetachesPageButLeavesItsOverlayEditorLive() throws {
        let state = CoveredPage()
        let host = NSHostingView(rootView: BrowserWithNativeCover(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(state.page))
        state.covered = true
        settle(host)
        XCTAssertNil(state.page.window, "Annotate/Draw must close the page subtree even though the browser screen is active")
        let note = try XCTUnwrap(fields(host).first)
        XCTAssertTrue(window.makeFirstResponder(note))
        let editor = try XCTUnwrap(note.currentEditor() as? NSTextView)
        editor.insertText(" accepted", replacementRange: .init(location: editor.string.utf16.count, length: 0))
        settle(host)
        XCTAssertTrue(state.annotation.hasSuffix(" accepted"), "Only the covered website sleeps; the native overlay stays editable")

        state.parentActive = false
        settle(host)
        XCTAssertNil(state.page.window)
        XCTAssertFalse(window.firstResponder === editor)
        let accepted = state.annotation
        editor.insertText(" hidden", replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(state.annotation, accepted)
        state.parentActive = true
        state.covered = false
        settle(host)
        XCTAssertTrue(state.page.window === window)
        XCTAssertNil(state.page.url, "Closing markup reuses the same unloaded page without navigation")
    }

    func testLiveParentScopeDetachesWKImmediatelyWithoutHostUpdateAndRestoresSamePage() throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: .zero, configuration: configuration)
        DeckWebPaintHost.markPainted(page)
        let scope = NativeSessionInputScope()
        let browser = NativeBrowserPageSlot(frame: .init(x: 0, y: 0, width: 640, height: 280))
        let window = self.window(browser)
        defer { window.contentView = nil; window.close() }
        browser.show(page, active: true, scope: scope)
        XCTAssertTrue(window.makeFirstResponder(page))
        XCTAssertTrue(page.window === window)

        scope.setActive(false)
        // No run-loop drain, SwiftUI rerender or second show call may be needed.
        XCTAssertFalse(browser.inputRule.acceptsFocus)
        XCTAssertNil(page.window)
        if let responder = window.firstResponder as? NSView {
            XCTAssertFalse(responder === page || responder.isDescendant(of: page))
        }
        let other = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        browser.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))
        scope.setActive(true)
        settle(browser)
        XCTAssertTrue(page.window === window)
        XCTAssertTrue(window.firstResponder === other, "Scope restoration reattaches the same page without taking another field's keyboard")
        XCTAssertNil(page.url)

        browser.show(page, active: false, scope: scope)
        XCTAssertNil(page.window, "An active outer scope cannot override a local markup cover")
        browser.show(page, active: true, selected: false, scope: scope)
        XCTAssertTrue(page.window === window)
        XCTAssertFalse(browser.inputRule.enabled, "An unselected pane keeps its page while closing keyboard eligibility")
        XCTAssertTrue(window.firstResponder === other)
    }
}
