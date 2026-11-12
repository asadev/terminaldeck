import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// The actual task rich editor, using offscreen windows and a private clipboard.
/// No task model, app, engine, provider hook or real attachment is opened.
@MainActor final class ComposerLeak1112bTaskRichTextTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        var cover: NSWindow?
        override var isKeyWindow: Bool { keyboardActive }
        override var attachedSheet: NSWindow? { cover }
    }

    @Observable final class State {
        var active = true
        var editable = true
        var text = "Task's own draft"
        var insertion: TaskTextInsertion?
        var escaped = 0
        var submitted = 0
        var clicked = 0
        var attached: [URL] = []
    }

    private struct Editor: View {
        @Bindable var state: State
        var autoFocus = false
        var body: some View {
            TaskRichText(text: $state.text, editable: state.editable,
                         onEscape: { state.escaped += 1 }, onSubmit: { state.submitted += 1 },
                         onClickText: { state.clicked += 1; state.editable = true },
                         autoFocus: autoFocus, insertion: $state.insertion)
                .nativeSessionInputScope(ownerID: "task-fixture")
                .environment(\.taskFileDoor, TaskFileDoor(attach: { state.attached += $0 }))
                .environment(\.nativeScreenActive, state.active)
                .opacity(state.active ? 1 : 0)
                .frame(width: 560, height: 180)
        }
    }

    @Observable final class Owners {
        var selected = "first"
        var first = "First task's draft"
        var second = "Second task's draft"
    }

    private struct OwnedEditor: View {
        @Bindable var owners: Owners
        var body: some View {
            TaskRichText(text: Binding(get: { owners.selected == "first" ? owners.first : owners.second }, set: {
                if owners.selected == "first" { owners.first = $0 } else { owners.second = $0 }
            }), editable: true, insertion: .constant(nil))
                .nativeSessionInputScope(ownerID: owners.selected)
                .frame(width: 560, height: 180)
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

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func editors(_ root: NSView) -> [TaskRichText.RichTextView] {
        (root as? TaskRichText.RichTextView).map { [$0] } ?? root.subviews.flatMap(editors)
    }

    func testActualTaskRichEditorRejectsHiddenEditsAndCommandsButAcceptsExplicitUpdates() throws {
        let state = State()
        let host = NSHostingView(rootView: Editor(state: state))
        let window = self.window(host)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); window.contentView = nil; window.close() }
        settle(host)
        let editor = try XCTUnwrap(editors(host).first)
        editor.board = board
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
        editor.insertText(" accepted", replacementRange: editor.selectedRange())
        settle(host)
        let accepted = state.text
        XCTAssertTrue(accepted.hasSuffix(" accepted"))
        editor.setMarkedText("unfinished composition", selectedRange: .init(location: 0, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(state.text, accepted, "Provisional composition must not enter the saved task draft")

        state.active = false
        settle(host)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertEqual(editor.string, accepted, "Hiding discards outstanding composition")
        XCTAssertTrue(board.setString("hidden clipboard", forType: .string))
        editor.insertText("hidden dictation", replacementRange: .init(location: NSNotFound, length: 0))
        editor.setMarkedText("hidden composition", selectedRange: .init(location: 0, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        editor.unmarkText()
        editor.paste(editor)
        XCTAssertFalse(editor.readSelection(from: board))
        editor.setAccessibilityValue("hidden accessibility change")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.coordinator?.textDidChange(.init(name: NSText.didChangeNotification, object: editor))
        XCTAssertEqual(state.text, accepted)
        XCTAssertEqual(editor.string, accepted)
        XCTAssertEqual(state.escaped, 0)
        XCTAssertEqual(state.submitted, 0)

        state.text = "Explicit model update"
        settle(host)
        XCTAssertEqual(editor.string, "Explicit model update")
        state.insertion = .mention(start: 0, name: "Tool")
        settle(host)
        XCTAssertTrue(state.text.contains("@Tool "), "Explicit insertion is allowed without the keyboard")
        state.insertion = .file("inert-file")
        settle(host)
        XCTAssertTrue(state.text.contains(CrmText.fileToken("inert-file")))
        XCTAssertEqual(state.attached, [], "Rendering an explicit file token must not attach or open a real file")
    }

    func testTaskOwnerChangeReplacesTheActualClientAndRetiresOldCallbacks() throws {
        let owners = Owners()
        let host = NSHostingView(rootView: OwnedEditor(owners: owners))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let old = try XCTUnwrap(editors(host).first)
        XCTAssertTrue(window.makeFirstResponder(old))
        old.setMarkedText("old unfinished title", selectedRange: .init(location: 0, length: 0),
                          replacementRange: .init(location: NSNotFound, length: 0))
        owners.selected = "second"
        settle(host)
        let current = try XCTUnwrap(editors(host).first)
        XCTAssertFalse(current === old)
        XCTAssertFalse(old.hasMarkedText())
        old.insertText("late old edit", replacementRange: .init(location: NSNotFound, length: 0))
        old.coordinator?.textDidChange(.init(name: NSText.didChangeNotification, object: old))
        XCTAssertEqual(owners.first, "First task's draft")
        XCTAssertEqual(owners.second, "Second task's draft")
        XCTAssertEqual(current.string, "Second task's draft")
    }

    func testVisibleReadonlyRichTextKeepsClickToEditAndHiddenFilePasteCannotAttach() throws {
        let state = State()
        state.editable = false
        let host = NSHostingView(rootView: Editor(state: state, autoFocus: true))
        let window = self.window(host)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); window.contentView = nil; window.close() }
        settle(host)
        let editor = try XCTUnwrap(editors(host).first)
        editor.board = board
        XCTAssertFalse(editor.isEditable)
        let point = editor.convert(NSPoint(x: 12, y: 8), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        editor.mouseDown(with: click)
        settle(host)
        XCTAssertEqual(state.clicked, 1)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(window.firstResponder === editor, "Clicking a visible readonly title still opens its editor")
        let file = URL(fileURLWithPath: "/inert-task-fixture/not-read.txt")
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        editor.paste(editor)
        XCTAssertEqual(state.attached, [file])

        state.active = false
        settle(host)
        editor.paste(editor)
        editor.mouseDown(with: click)
        XCTAssertEqual(state.attached, [file], "A retained hidden file door cannot attach files to the old task")
        XCTAssertEqual(state.clicked, 1)
    }

    func testTaskAutofocusWaitsForSheetAndPreservesAnotherVisibleField() throws {
        let state = State()
        let host = NSHostingView(rootView: Editor(state: state, autoFocus: true))
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        let other = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(other)
        let window = self.window(root)
        let sheet = ScratchWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.cover = nil; window.contentView = nil; window.close(); sheet.close() }
        XCTAssertTrue(window.makeFirstResponder(other))
        host.frame = root.bounds
        root.addSubview(host)
        settle(root)
        let editor = try XCTUnwrap(editors(host).first)
        XCTAssertTrue(window.firstResponder === other)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === other)
        XCTAssertTrue(window.makeFirstResponder(nil))
        window.cover = sheet
        editor.coordinator?.focusIfNeeded(editor)
        XCTAssertFalse(window.firstResponder === editor)
        window.cover = nil
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        XCTAssertTrue(window.firstResponder === editor)
    }
}
