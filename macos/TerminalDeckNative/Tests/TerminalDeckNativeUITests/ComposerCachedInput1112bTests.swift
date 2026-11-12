import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// Cached native settings and grouped form inputs. Models and preferences are
/// local values; none of the shared app, engine or stored settings are used.
@MainActor final class ComposerLeak1112bCachedInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        var cover: NSWindow?
        override var isKeyWindow: Bool { keyboardActive }
        override var attachedSheet: NSWindow? { cover }
    }

    enum Target: Hashable { case first, second }

    @Observable final class State {
        var active = true
        var count: Int? = 12
        var limit: Double? = 2.5
        var first = "First own value"
        var second = "Second own value"
        var requested: Target? = .first
        var observed: Target?
        var submissions = 0
        var exits = 0
    }

    private struct SettingsNumbers: View {
        @Bindable var state: State
        var body: some View {
            VStack {
                NativeSessionNumberField("Optional count", value: $state.count,
                                         format: .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never),
                                         prompt: Text("Inherit count"))
                NativeSessionNumberField("Optional limit", value: $state.limit,
                                         format: .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never),
                                         prompt: Text("Inherit limit"))
            }
            .nativeSessionInputScope(ownerID: "cached-settings-fixture")
            .environment(\.nativeScreenActive, state.active)
            .frame(width: 560, height: 150)
        }
    }

    private struct GroupedEnumFields: View {
        @Bindable var state: State
        @FocusState private var focus: Target?
        var body: some View {
            VStack {
                NativeSessionTextField("First", text: $state.first)
                    .font(.body).frame(height: 30)
                    .sessionFocused($focus, equals: .first)
                    .sessionOnSubmit { state.submissions += 1 }
                NativeSessionTextField("Second", text: $state.second)
                    .font(.body).frame(height: 30)
                    .sessionFocused($focus, equals: .second)
                    .sessionOnExitCommand { state.exits += 1 }
            }
            .nativeSessionInputScope(ownerID: "grouped-enum-fixture")
            .environment(\.nativeScreenActive, state.active)
            .onAppear { focus = state.requested }
            .onChange(of: state.requested) { _, next in focus = next }
            .onChange(of: focus) { _, next in state.observed = next }
            .frame(width: 560, height: 150)
        }
    }

    @MainActor @Observable final class NestedState {
        var showSession = false
        var value = "Retained presentation's own draft"
        let parentScope = NativeSessionInputScope()
        let container = DeckTerminalContainer(terminal: DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240),
                                                                         font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
    }

    private struct RetainedNestedPresentation: View {
        @Bindable var state: NestedState
        var body: some View {
            ZStack {
                NativeSessionTextField("Nested draft", text: $state.value)
                    .nativeSessionInputScope(ownerID: "retained-child")
                    .environment(\.nativeSessionInputScope, state.parentScope)
                    // A retained presentation can still hold its captured `true`.
                    .environment(\.nativeScreenActive, true)
                    .opacity(state.showSession ? 0 : 1)
                NativeTerminalHost(container: state.container)
                    .environment(\.nativeScreenActive, state.showSession)
                    .opacity(state.showSession ? 1 : 0)
            }.frame(width: 640, height: 280)
        }
    }

    private func window(_ content: NSView) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 680, height: 340),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func fields(_ root: NSView) -> [NativeSessionTextControl] {
        (root as? NativeSessionTextControl).map { [$0] } ?? root.subviews.flatMap(fields)
    }

    func testCachedOptionalNumericSettingsKeepProvisionalInputAndRejectLateHiddenEdits() throws {
        let state = State()
        let host = NSHostingView(rootView: SettingsNumbers(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let count = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Optional count" })
        let limit = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Optional limit" })
        XCTAssertEqual(count.stringValue, "12")
        XCTAssertEqual(limit.stringValue, "2.5")
        XCTAssertTrue(count.placeholderString?.isEmpty != false, "An explicit prompt suppresses the field's label placeholder")
        XCTAssertTrue(window.makeFirstResponder(count))
        let editor = try XCTUnwrap(count.currentEditor() as? NSTextView)
        editor.insertText("-", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        settle(host)
        XCTAssertEqual(state.count, 12)
        XCTAssertEqual(editor.string, "-", "An incomplete number stays editable without changing settings")
        editor.insertText("34", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        settle(host)
        XCTAssertEqual(state.count, 34)

        state.active = false
        settle(host)
        editor.insertText("99", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(state.count, 34)
        state.count = nil
        state.limit = 7.25
        settle(host)
        XCTAssertEqual(count.stringValue, "", "An explicit model clear is still rendered while hidden")
        XCTAssertEqual(limit.stringValue, "7.25")
        state.active = true
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(limit))
        let limitEditor = try XCTUnwrap(limit.currentEditor() as? NSTextView)
        limitEditor.insertText("", replacementRange: .init(location: 0, length: limitEditor.string.utf16.count))
        settle(host)
        XCTAssertNil(state.limit, "Clearing an optional numeric setting restores inheritance")
    }

    func testPendingEnumFocusCannotReviveOldRequestAfterSheetDelayedAttachment() throws {
        let state = State()
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        let window = self.window(root)
        let sheet = ScratchWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.cover = sheet
        let host = NSHostingView(rootView: GroupedEnumFields(state: state))
        host.frame = root.bounds
        root.addSubview(host)
        defer { window.cover = nil; window.contentView = nil; window.close(); sheet.close() }
        settle(host)
        state.requested = .second
        settle(host)
        let first = try XCTUnwrap(fields(host).first { $0.placeholderString == "First" })
        let second = try XCTUnwrap(fields(host).first { $0.placeholderString == "Second" })
        XCTAssertNil(first.currentEditor())
        XCTAssertNil(second.currentEditor())
        window.cover = nil
        let firstCoordinator = try XCTUnwrap(first.delegate as? NativeSessionFieldCoordinator)
        let secondCoordinator = try XCTUnwrap(second.delegate as? NativeSessionFieldCoordinator)
        // Run the actual pending-focus hooks in the adverse order. The obsolete
        // first request must never briefly take focus or rewrite the enum.
        firstCoordinator.fulfilFocus(first)
        XCTAssertNil(first.currentEditor())
        XCTAssertFalse(window.firstResponder === first.currentEditor())
        secondCoordinator.fulfilFocus(second)
        let editor = try XCTUnwrap(second.currentEditor())
        XCTAssertTrue(window.firstResponder === editor, "Only the latest enum selection may claim the keyboard")
        XCTAssertFalse(window.firstResponder === first.currentEditor())
        settle(host)
        XCTAssertEqual(state.observed, .second)
    }

    func testNestedRetainedPresentationClosesSynchronouslyWithParentAndHandsKeyboardToSession() throws {
        let state = NestedState()
        let host = NSHostingView(rootView: RetainedNestedPresentation(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let field = try XCTUnwrap(fields(host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        editor.setMarkedText("unfinished child composition", selectedRange: .init(location: 0, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        let accepted = state.value
        state.parentScope.setActive(false)
        // Check before any deferred focus cleanup or SwiftUI rerender.
        XCTAssertFalse(editor.inputRule.acceptsFocus)
        XCTAssertFalse(editor.hasMarkedText())
        editor.insertText("late retained edit", replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(state.value, accepted)
        state.showSession = true
        settle(host)
        XCTAssertTrue(window.firstResponder === state.container.terminal)
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertFalse(editor.inputRule.acceptsFocus, "The child's captured active=true cannot reopen its hidden parent")
    }

    func testSelectedTerminalRecognizesHiddenNativeSecureClientBeforeDeferredRelease() throws {
        let state = State()
        let scope = NativeSessionInputScope()
        let host = NSHostingView(rootView: NativeSessionSecureField("Secure setting", text: Binding(
            get: { state.second }, set: { state.second = $0 }))
            .environment(\.nativeSessionInputScope, scope).frame(width: 500, height: 90))
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        host.frame = root.bounds
        root.addSubview(host)
        let terminal = DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240),
                                        font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let container = DeckTerminalContainer(terminal: terminal)
        let slot = DeckTerminalSlot(container: container, active: false)
        root.addSubview(slot)
        let window = self.window(root)
        defer { _ = container; window.contentView = nil; window.close() }
        settle(host)
        func secure(_ view: NSView) -> NativeSessionSecureControl? {
            (view as? NativeSessionSecureControl) ?? view.subviews.lazy.compactMap(secure).first
        }
        let field = try XCTUnwrap(secure(host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let oldClient = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === oldClient)
        scope.setActive(false)
        slot.setActive(true)
        XCTAssertTrue(window.firstResponder === terminal, "The selected terminal must not mistake a hidden native secure editor for a visible field")
        oldClient.insertText("late secure input", replacementRange: .init(location: 0, length: oldClient.string.utf16.count))
        XCTAssertEqual(state.second, "Second own value")
    }
}
