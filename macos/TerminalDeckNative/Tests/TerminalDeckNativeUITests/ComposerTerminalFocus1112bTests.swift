import AppKit
@preconcurrency import SwiftTerm
import XCTest
@testable import TerminalDeckNative

/// Exercises real AppKit keyboard ownership without starting the app, a session,
/// a provider or a session host. These windows never appear on the screen.
@MainActor final class ComposerLeak1112bTerminalFocusTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        var coveringSheet: NSWindow?
        override var isKeyWindow: Bool { keyboardActive }
        override var attachedSheet: NSWindow? { coveringSheet }
    }

    @MainActor final class Input: TerminalViewDelegate {
        var bytes = [UInt8]()
        var text: String { String(decoding: bytes, as: UTF8.self) }
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { bytes += data }
        }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func terminal() -> (DeckTerminalContainer, Input) {
        let view = DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240),
                                    font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let input = Input()
        view.eventDelegate = input
        return (DeckTerminalContainer(terminal: view), input)
    }

    private func window(_ content: NSView, key: Bool = true) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.keyboardActive = key
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func close(_ windows: ScratchWindow...) {
        for window in windows {
            window.coveringSheet = nil
            window.contentView = nil
            window.close()
        }
    }

    private func settle(_ view: NSView) {
        // Drain only the one-turn AppKit/SwiftUI handoff; no app or process is launched.
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func type(_ text: String, into terminal: DeckTerminalView) {
        terminal.insertText(text, replacementRange: .init(location: NSNotFound, length: 0))
    }

    private func assertKeyboard(_ terminal: DeckTerminalView, in window: NSWindow,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.firstResponder === terminal,
                      "The selected terminal must own the real first responder", file: file, line: line)
        XCTAssertTrue(terminal.acceptsUserInput,
                      "Keyboard ownership must immediately permit typing", file: file, line: line)
    }

    func testFirstAttachmentOwnsKeyboardAndAcceptsTypingWithoutManualFocus() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container)
        let window = self.window(slot)
        defer { close(window) }

        assertKeyboard(container.terminal, in: window)
        type("first launch", into: container.terminal)
        XCTAssertEqual(input.text, "first launch")
    }

    func testRestoredSelectionBeforeWindowAttachmentOwnsKeyboard() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container, active: false)
        // Restore knows the selected session before AppKit attaches its window.
        slot.setActive(true)
        let window = self.window(slot)
        defer { close(window) }

        assertKeyboard(container.terminal, in: window)
        type("restored session", into: container.terminal)
        XCTAssertEqual(input.text, "restored session")
    }

    func testReturningFromHiddenSessionRestoresActualKeyboardImmediately() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container)
        let window = self.window(slot)
        defer { close(window) }
        slot.setActive(false)
        XCTAssertFalse(window.firstResponder === container.terminal)
        XCTAssertNil(container.terminal.window)

        slot.setActive(true)
        assertKeyboard(container.terminal, in: window)
        type("back in this session", into: container.terminal)
        XCTAssertEqual(input.text, "back in this session")
    }

    func testRapidSessionSwitchesKeepOnlyTheSelectedTerminalLive() {
        let (first, firstInput) = self.terminal()
        let (second, secondInput) = self.terminal()
        let firstSlot = DeckTerminalSlot(container: first)
        let secondSlot = DeckTerminalSlot(container: second, active: false)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 300))
        root.addSubview(firstSlot)
        root.addSubview(secondSlot)
        let window = self.window(root)
        defer { close(window) }

        for index in 0..<8 {
            // Both callback orderings occur while SwiftUI updates warm screens.
            if index.isMultiple(of: 2) {
                secondSlot.setActive(true)
                firstSlot.setActive(false)
            } else {
                firstSlot.setActive(false)
                secondSlot.setActive(true)
            }
            assertKeyboard(second.terminal, in: window)
            type("wrong", into: first.terminal)
            type("B", into: second.terminal)
            secondSlot.setActive(false)
            firstSlot.setActive(true)
            assertKeyboard(first.terminal, in: window)
            type("wrong", into: second.terminal)
            type("A", into: first.terminal)
        }
        XCTAssertEqual(firstInput.text, String(repeating: "A", count: 8))
        XCTAssertEqual(secondInput.text, String(repeating: "B", count: 8))
    }

    func testSplitAndSwarmSelectionMovesKeyboardWhileBothTerminalsStayVisible() {
        let (first, firstInput) = terminal()
        let (second, secondInput) = terminal()
        let firstSlot = DeckTerminalSlot(container: first, focus: true)
        let secondSlot = DeckTerminalSlot(container: second, focus: false)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 300))
        root.addSubview(firstSlot)
        root.addSubview(secondSlot)
        let window = self.window(root)
        defer { close(window) }
        assertKeyboard(first.terminal, in: window)
        // The new pane may update first, while the former pane still reports selected.
        secondSlot.show(second, active: true, focus: true)
        firstSlot.show(first, active: true, focus: false)
        assertKeyboard(second.terminal, in: window)
        type("second", into: second.terminal)
        type("wrong", into: first.terminal)
        XCTAssertEqual(firstInput.text, "")
        XCTAssertEqual(secondInput.text, "second")
        // The opposite callback order must be equally live.
        secondSlot.show(second, active: true, focus: false)
        firstSlot.show(first, active: true, focus: true)
        assertKeyboard(first.terminal, in: window)
        type("first", into: first.terminal)
        XCTAssertEqual(firstInput.text, "first")
        XCTAssertTrue(first.terminal.inputActive)
        XCTAssertTrue(second.terminal.inputActive)
    }

    func testReleaseLineSlotRebindingMovesKeyboardToItsNewContainer() {
        let (first, firstInput) = self.terminal()
        let (replacement, replacementInput) = self.terminal()
        let slot = DeckTerminalSlot(container: first)
        let window = self.window(slot)
        defer { close(window) }

        slot.show(replacement, active: true, focus: true)
        XCTAssertTrue(replacement.superview === slot)
        XCTAssertNil(first.window)
        XCTAssertFalse(first.terminal.acceptsUserInput)
        assertKeyboard(replacement.terminal, in: window)
        type("stale", into: first.terminal)
        type("replacement", into: replacement.terminal)
        XCTAssertEqual(firstInput.text, "")
        XCTAssertEqual(replacementInput.text, "replacement")
    }

    func testHiddenRebindingCannotTakeAVisibleTerminalsContainerOrKeyboard() {
        let (previous, _) = terminal()
        let (replacement, input) = terminal()
        let visible = DeckTerminalSlot(container: replacement)
        let first = window(visible)
        let hidden = DeckTerminalSlot(container: previous, active: false)
        let second = window(hidden, key: false)
        defer { close(first, second) }
        hidden.show(replacement, active: false, focus: true)
        XCTAssertTrue(replacement.superview === visible)
        XCTAssertTrue(replacement.window === first)
        assertKeyboard(replacement.terminal, in: first)
        XCTAssertNil(previous.window)
        type("still the visible owner", into: replacement.terminal)
        XCTAssertEqual(input.text, "still the visible owner")
    }

    func testPopOutAndHandBackRestoreKeyboardInTheKeyWindow() {
        let (container, input) = self.terminal()
        let original = DeckTerminalSlot(container: container)
        let popOut = DeckTerminalSlot(container: container, active: false)
        let first = self.window(original)
        let second = self.window(popOut, key: false)
        defer { close(first, second) }

        first.keyboardActive = false
        second.keyboardActive = true
        popOut.setActive(true)
        assertKeyboard(container.terminal, in: second)
        type("pop out;", into: container.terminal)

        second.keyboardActive = false
        first.keyboardActive = true
        popOut.setActive(false)
        XCTAssertTrue(container.superview === original)
        assertKeyboard(container.terminal, in: first)
        XCTAssertFalse(second.firstResponder === container.terminal)
        type("hand back", into: container.terminal)
        XCTAssertEqual(input.text, "pop out;hand back")
    }

    func testBackgroundSecondWindowCannotTakeTerminalUntilItBecomesKey() {
        let (container, input) = self.terminal()
        let original = DeckTerminalSlot(container: container)
        let first = self.window(original)
        let restored = DeckTerminalSlot(container: container)
        let second = self.window(restored, key: false)
        defer { close(first, second) }

        XCTAssertTrue(container.superview === original, "A restored background scene must not detach the key window's terminal")
        assertKeyboard(container.terminal, in: first)
        DeckTerminalSlot.restoreFocus(in: second)
        settle(restored)
        assertKeyboard(container.terminal, in: first)
        type("original;", into: container.terminal)

        first.keyboardActive = false
        second.keyboardActive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        XCTAssertTrue(container.superview === restored)
        assertKeyboard(container.terminal, in: second)
        type("second window", into: container.terminal)
        XCTAssertEqual(input.text, "original;second window")
    }

    func testCoverClosingRestoresKeyboardAfterItsResponderLeaves() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 300))
        root.addSubview(slot)
        let coverField = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(coverField)
        let window = self.window(root)
        defer { close(window) }
        slot.setActive(false)
        XCTAssertTrue(window.makeFirstResponder(coverField))

        // Visibility can return before the outgoing sheet/cover resigns its field.
        slot.setActive(true)
        XCTAssertTrue(window.firstResponder === coverField)
        XCTAssertTrue(window.makeFirstResponder(nil))
        DeckTerminalSlot.restoreFocus(in: window)
        assertKeyboard(container.terminal, in: window)
        type("after cover", into: container.terminal)
        XCTAssertEqual(input.text, "after cover")
    }

    func testPendingFocusWaitsForSheetAndUsesSheetClosedNotification() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container, active: false)
        let window = self.window(slot)
        let sheet = ScratchWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { close(window, sheet) }
        // Represent the cover entirely in the scratch window; never open a sheet on screen.
        window.coveringSheet = sheet
        slot.setActive(true)
        DeckTerminalSlot.requestFocus(for: container.terminal)
        XCTAssertFalse(window.firstResponder === container.terminal)

        window.coveringSheet = nil
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        assertKeyboard(container.terminal, in: window)
        type("sheet ended", into: container.terminal)
        XCTAssertEqual(input.text, "sheet ended")
    }

    func testPendingFocusWaitsForKeyWindowAndAppActivation() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container)
        let window = self.window(slot, key: false)
        let otherField = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        let other = self.window(otherField)
        defer { close(window, other) }
        XCTAssertTrue(other.makeFirstResponder(otherField))

        DeckTerminalSlot.requestFocus(for: container.terminal)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(other.firstResponder === otherField, "A background terminal cannot take another window's field")
        XCTAssertFalse(window.firstResponder === container.terminal)
        type("wrong window", into: container.terminal)
        XCTAssertEqual(input.text, "")

        other.keyboardActive = false
        window.keyboardActive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        assertKeyboard(container.terminal, in: window)
        type("key again", into: container.terminal)
        XCTAssertEqual(input.text, "key again")
    }

    func testFocusRequestsDoNotStealFromAnotherFieldOrUnselectedSplitPane() {
        let (container, input) = self.terminal()
        let slot = DeckTerminalSlot(container: container)
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 300))
        root.addSubview(slot)
        let field = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(field)
        let window = self.window(root)
        defer { close(window) }
        XCTAssertTrue(window.makeFirstResponder(field))
        DeckTerminalSlot.requestFocus(for: container.terminal)
        DeckTerminalSlot.restoreFocus(in: window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        settle(root)
        XCTAssertTrue(window.firstResponder === field)
        type("wrong field", into: container.terminal)
        XCTAssertEqual(input.text, "")

        slot.setActive(false)
        XCTAssertTrue(window.makeFirstResponder(nil))
        slot.setActive(true, focus: false)
        DeckTerminalSlot.requestFocus(for: container.terminal)
        DeckTerminalSlot.restoreFocus(in: window)
        settle(root)
        XCTAssertFalse(window.firstResponder === container.terminal)
        XCTAssertFalse(container.terminal.acceptsUserInput)
    }

    func testHiddenTerminalRejectsEveryKeyboardRouteButKeepsExplicitSendsAndReplies() throws {
        let (container, input) = self.terminal()
        let terminal = container.terminal
        let slot = DeckTerminalSlot(container: container)
        let window = self.window(slot)
        defer { close(window) }
        assertKeyboard(terminal, in: window)
        terminal.setMarkedText("unfinished", selectedRange: .init(location: 0, length: 0),
                               replacementRange: .init(location: NSNotFound, length: 0))
        slot.setActive(false)
        input.bytes = []
        XCTAssertFalse(window.firstResponder === terminal)
        XCTAssertFalse(terminal.hasMarkedText(), "Hiding must discard an unfinished input-method composition")

        type("late dictation", into: terminal)
        terminal.setMarkedText("late composition", selectedRange: .init(location: 0, length: 0),
                               replacementRange: .init(location: NSNotFound, length: 0))
        terminal.unmarkText()
        terminal.paste(terminal)
        terminal.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        terminal.keyDown(with: key)
        XCTAssertFalse(terminal.performKeyEquivalent(with: key))
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertEqual(input.text, "", "Late key, paste, command and input-method callbacks must not reach the hidden session")

        terminal.sendExplicitText("addressed by session ID")
        XCTAssertEqual(input.text, "addressed by session ID")
        input.bytes = []
        terminal.feed(text: "\u{1b}[6n")
        XCTAssertFalse(input.bytes.isEmpty, "A hidden program still receives its cursor-position protocol reply")
    }
}
