import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// A person's own actions on a message box that do not come through the keyboard: a pick from the
/// @ list, the "@" button, a drop onto the box. They need the box's OWNER on screen, not the keyboard
/// (the keyboard is in the list, or another app is in front during a drop). A hidden owner refuses
/// them. The real HootComposer box serves Hoot, every session's chat and a task's comments.
/// Windows are never ordered in and never key; no app model, engine or session.
@MainActor final class ComposerLeak1112bOwnerActionTests: XCTestCase {
    @Observable final class State {
        var active = true
        var draft = HootComposerDraft(text: "ask @cri")
    }

    private struct Box: View {
        @Bindable var state: State
        var body: some View {
            HootComposer(draft: $state.draft, showMeta: false, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                .environment(\.agkitOffscreenSolid, true)
                .nativeSessionInputScope(ownerID: "owner-action-fixture")
                .environment(\.nativeScreenActive, state.active)
                .frame(width: 520, height: 200)
        }
    }

    /// Only what AppKit reads during a drop from another app onto a view.
    private final class Drop: NSObject, NSDraggingInfo {
        let board: NSPasteboard
        let point: NSPoint
        weak var target: NSWindow?
        init(_ text: String, at point: NSPoint, in window: NSWindow) {
            board = NSPasteboard.withUniqueName()
            board.clearContents()
            board.setString(text, forType: .string)
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

    private func mount(_ state: State) -> (NSWindow, NSView, HootComposerTextView) {
        let host = NSHostingView(rootView: Box(state: state))
        // Never ordered in and never key: the box does not hold the keyboard either.
        let window = NSWindow(contentRect: .init(x: -32000, y: -32000, width: 560, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        let box = boxes(host).first!
        return (window, host, box)
    }
    private func settle(_ view: NSView) {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    private func boxes(_ view: NSView) -> [HootComposerTextView] {
        ((view as? HootComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap(boxes)
    }
    private let critic = HootMention(id: "critic", kind: .agent, name: "critic", project: "Owner Action Test")

    private func pick(_ box: NSTextView, _ state: State) {
        box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
        let editor = HootComposerEditorHandle()
        editor.textView = box
        editor.insert(critic, draft: Binding(get: { state.draft }, set: { state.draft = $0 }), replaceQuery: true)
    }
    private func pressAt(_ box: NSTextView) {
        let editor = HootComposerEditorHandle()
        editor.textView = box
        editor.typeMentionSign()
    }
    private func drop(_ text: String, on box: NSTextView, in window: NSWindow) -> Bool {
        let point = box.convert(NSPoint(x: box.bounds.maxX - 2, y: box.bounds.midY), to: nil)
        let drag = Drop(text, at: point, in: window)
        defer { drag.board.releaseGlobally() }
        guard box.draggingEntered(drag) != [] else { return false }
        _ = box.draggingUpdated(drag)
        guard box.prepareForDragOperation(drag), box.performDragOperation(drag) else { return false }
        box.concludeDragOperation(drag)
        return true
    }

    func testVisibleOwnerTakesAMentionPickTheAtButtonAndADropWithoutTheKeyboard() throws {
        let state = State()
        let (window, host, box) = mount(state)
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.firstResponder === box, "The box does not hold the keyboard")
        XCTAssertEqual(box.string, "ask @cri")

        // Typing aimed at a box without the keyboard is still refused: only a stale client sends it.
        box.insertText("stale client", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(box.string, "ask @cri")
        XCTAssertEqual(state.draft.text, "ask @cri")

        // A pick from the @ list (a click can leave the list's popover as the key window).
        pick(box, state)
        settle(host)
        XCTAssertEqual(state.draft.text, "ask " + critic.marker, "The pick reaches the draft")
        XCTAssertEqual(state.draft.mentions, [critic])
        XCTAssertEqual(box.string, "ask \u{FFFC}")

        // The "@" button types "@" through the box, so its change notice updates the draft.
        window.makeFirstResponder(nil)
        box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
        pressAt(box)
        settle(host)
        // A space first: the "@" would otherwise stick to the mention before it.
        XCTAssertEqual(box.string, "ask \u{FFFC} @", "The @ button reaches the box")
        XCTAssertEqual(state.draft.text, "ask " + critic.marker + " @", "and the draft behind it")

        // A drop from another app onto the box (this window is not key, the box has no keyboard).
        window.makeFirstResponder(nil)
        XCTAssertTrue(drop(" dropped", on: box, in: window), "A visible box takes a drop")
        settle(host)
        XCTAssertTrue(box.string.contains("dropped"))
        XCTAssertTrue(state.draft.text.contains("dropped"), "The dropped text reaches the draft")
    }

    func testHiddenOwnerRefusesAMentionPickTheAtButtonAndADrop() throws {
        let state = State()
        let (window, host, box) = mount(state)
        defer { window.contentView = nil; window.close() }
        state.active = false
        settle(host)
        let before = state.draft

        pick(box, state)
        settle(host)
        pressAt(box)
        settle(host)
        XCTAssertFalse(drop(" dropped", on: box, in: window), "A hidden box takes no drop")
        settle(host)
        XCTAssertEqual(state.draft, before, "Nothing reaches a hidden session's draft")
        XCTAssertEqual(box.string, "ask @cri")
        XCTAssertFalse(window.firstResponder === box, "A hidden box never takes the keyboard")

        // Shown again, the same box takes the person's pick.
        state.active = true
        settle(host)
        pick(box, state)
        settle(host)
        XCTAssertEqual(state.draft.text, "ask " + critic.marker)
    }
}
