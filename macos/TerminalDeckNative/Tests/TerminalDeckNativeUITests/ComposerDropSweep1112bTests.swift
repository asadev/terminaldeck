import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// Drops onto the shared boxes other than the message box: the task description, a multi-line box
/// and a one-line field being edited. A drop from Finder arrives while Finder is in front, so it
/// needs the box's owner on screen, not an active window or the keyboard. A hidden owner refuses it.
/// Windows are never ordered in and never key; no app model, engine, session or real file is opened.
@MainActor final class ComposerLeak1112bDropSweepTests: XCTestCase {
    /// Only what AppKit reads during a drop from another app onto a view.
    final class Drop: NSObject, NSDraggingInfo {
        let board: NSPasteboard
        let point: NSPoint
        weak var target: NSWindow?
        init(_ board: NSPasteboard, at point: NSPoint, in window: NSWindow) {
            self.board = board
            self.point = point
            target = window
        }
        var draggingDestinationWindow: NSWindow? { target }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { point }
        var draggedImageLocation: NSPoint { point }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { board }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func textBoard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    /// The whole drop sequence AppKit runs on the view under the pointer. False when refused.
    static func drop(_ board: NSPasteboard, on view: NSView, in window: NSWindow) -> Bool {
        let point = view.convert(NSPoint(x: max(1, view.bounds.maxX - 2), y: view.bounds.midY), to: nil)
        let drag = Drop(board, at: point, in: window)
        let target = view as AnyObject
        guard let dest = target as? NSDraggingDestination,
              let entered = dest.draggingEntered?(drag), entered != [] else { return false }
        _ = dest.draggingUpdated?(drag)
        guard dest.prepareForDragOperation?(drag) ?? true, dest.performDragOperation?(drag) == true else { return false }
        dest.concludeDragOperation?(drag)
        return true
    }

    private func window(_ content: NSView) -> NSWindow {
        // Never ordered in and never key: another app is in front during the drag.
        let window = NSWindow(contentRect: .init(x: -32000, y: -32000, width: 680, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }
    private func settle(_ view: NSView) {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    // MARK: The task description

    @Observable final class TaskState {
        var active = true
        var text = "Task's own draft"
        var insertion: TaskTextInsertion?
        var attached: [URL] = []
    }

    private struct TaskEditor: View {
        @Bindable var state: TaskState
        var body: some View {
            TaskRichText(text: $state.text, editable: true, insertion: $state.insertion)
                .nativeSessionInputScope(ownerID: "drop-task-fixture")
                .environment(\.taskFileDoor, TaskFileDoor(attach: { state.attached += $0 }))
                .environment(\.nativeScreenActive, state.active)
                .frame(width: 560, height: 180)
        }
    }

    func testTaskDescriptionTakesDroppedTextAndFilesWhileShownAndRefusesThemWhileHidden() throws {
        let state = TaskState()
        let host = NSHostingView(rootView: TaskEditor(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskRichText.RichTextView }.first)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.firstResponder === editor)

        let text = Self.textBoard(" dropped")
        defer { text.releaseGlobally() }
        XCTAssertTrue(Self.drop(text, on: editor, in: window), "A shown task takes dropped text")
        settle(host)
        XCTAssertTrue(state.text.contains("dropped"), "Dropped text reaches the task's draft")

        let file = NSPasteboard.withUniqueName()
        defer { file.releaseGlobally() }
        file.clearContents()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drop-sweep-\(UUID().uuidString).txt")
        XCTAssertTrue(file.writeObjects([scratch as NSURL]))
        window.makeFirstResponder(nil)
        XCTAssertTrue(Self.drop(file, on: editor, in: window), "A shown task takes a dropped file")
        XCTAssertEqual(state.attached, [scratch], "The file goes to the task's file door")

        state.active = false
        settle(host)
        let before = state.text
        XCTAssertFalse(Self.drop(text, on: editor, in: window), "A hidden task refuses dropped text")
        XCTAssertFalse(Self.drop(file, on: editor, in: window), "A hidden task refuses a dropped file")
        settle(host)
        XCTAssertEqual(state.text, before)
        XCTAssertEqual(state.attached, [scratch])
    }

    // MARK: Multi-line box and a one-line field being edited

    @Observable final class FieldState {
        var active = true
        var notes = "Own notes"
        var name = "Own name"
    }

    private struct Fields: View {
        @Bindable var state: FieldState
        var body: some View {
            VStack {
                NativeSessionTextEditor(text: $state.notes).frame(height: 90)
                NativeSessionTextField("Name", text: $state.name).frame(height: 30)
            }
            .nativeSessionInputScope(ownerID: "drop-fields-fixture")
            .environment(\.nativeScreenActive, state.active)
            .frame(width: 560, height: 160)
        }
    }

    /// As in 0.21.3, a one-line field that does NOT have the cursor is no drop target, so a
    /// reorder drag or a Finder file released over it reaches the view behind it, and nothing is
    /// typed into the field.
    func testFieldWithoutTheCursorIsNoDropTargetSoTheViewBehindItGetsTheDrop() throws {
        let state = FieldState()
        let host = NSHostingView(rootView: Fields(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextControl }.first)
        XCTAssertNil(field.currentEditor(), "The field does not have the cursor")
        XCTAssertTrue(field.registeredDraggedTypes.isEmpty, "The field registers for no drag, so AppKit passes it over")
        let board = Self.textBoard("task-row-id-123")
        defer { board.releaseGlobally() }
        XCTAssertFalse(Self.drop(board, on: field, in: window), "The field does not take the drop")
        settle(host)
        XCTAssertEqual(state.name, "Own name", "Nothing is typed into it")
    }

    func testMultiLineBoxAndEditedFieldTakeADropWhileShownAndRefuseItWhileHidden() throws {
        let state = FieldState()
        let host = NSHostingView(rootView: Fields(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let box = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextView }.first { !$0.isFieldEditor })
        let field = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextControl }.first)
        let board = Self.textBoard(" dropped")
        defer { board.releaseGlobally() }

        XCTAssertTrue(Self.drop(board, on: box, in: window), "A shown multi-line box takes a drop")
        settle(host)
        XCTAssertTrue(state.notes.contains("dropped"), "and the text reaches its binding")

        // The person was editing the field, then went to Finder and dragged text onto it.
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(Self.drop(board, on: editor, in: window), "A shown field being edited takes a drop")
        settle(host)
        XCTAssertTrue(state.name.contains("dropped"), "and the text reaches its binding")

        state.active = false
        settle(host)
        let notes = state.notes, name = state.name
        XCTAssertFalse(Self.drop(board, on: box, in: window), "A hidden multi-line box refuses a drop")
        XCTAssertFalse(Self.drop(board, on: editor, in: window), "A hidden field's editor refuses a drop")
        settle(host)
        XCTAssertEqual(state.notes, notes)
        XCTAssertEqual(state.name, name)
    }
}
