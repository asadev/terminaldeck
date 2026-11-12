import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// Focus hand-offs once session boxes are registered with SwiftUI's focus: moving focus out of
/// a multi-line box, a sheet-deferred request that is given up, and New Task's "Add description".
/// Local fixtures and the real New Task card with a scratch context; no app model or engine.
@MainActor final class ComposerLeak1112bFocusSettleTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var cover: NSWindow?
        override var isKeyWindow: Bool { true }
        override var attachedSheet: NSWindow? { cover }
    }

    enum Target: Hashable { case description, folder, name, first, second }

    @Observable final class State {
        var active = true
        var describing = "Typed into the description"
        var folder = ""
        var name = "Task name"
        var first = "First own value"
        var second = "Second own value"
        var typingFolder = false
        var showNew = false
        var requested: Target?
    }

    /// The New Task shape: one enum focus shared by a multi-line box and one-line fields.
    private struct DescriptionThenField: View {
        @Bindable var state: State
        @FocusState private var focus: Target?
        var body: some View {
            VStack {
                NativeSessionTextField("Task name", text: $state.name).frame(height: 30)
                    .sessionFocused($focus, equals: .name)
                NativeSessionTextEditor(text: $state.describing)
                    .sessionFocused($focus, equals: .description)
                    .frame(height: 90)
                if state.typingFolder {
                    NativeSessionTextField("Full folder path", text: $state.folder).frame(height: 30)
                        .sessionFocused($focus, equals: .folder)
                }
            }
            .nativeSessionInputScope(ownerID: "focus-settle-description")
            .onChange(of: state.requested) { _, next in focus = next }
            .frame(width: 560, height: 220)
        }
    }

    /// A box that asks for focus when it appears, as "Add subtask" does.
    private struct AppearingBox: View {
        @Binding var text: String
        @FocusState private var focused: Bool
        var body: some View {
            NativeSessionTextField("New box", text: $text).frame(height: 30)
                .sessionFocused($focused)
                .onAppear { focused = true }
        }
    }

    private struct DeferredThenNew: View {
        @Bindable var state: State
        @FocusState private var focus: Target?
        var body: some View {
            VStack {
                NativeSessionTextField("First", text: $state.first).frame(height: 30)
                    .sessionFocused($focus, equals: .first)
                if state.showNew { AppearingBox(text: $state.second) }
            }
            .nativeSessionInputScope(ownerID: "focus-settle-deferred")
            .environment(\.nativeScreenActive, state.active)
            .onChange(of: state.requested) { _, next in focus = next }
            .frame(width: 560, height: 120)
        }
    }

    private func window(_ content: NSView) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 680, height: 400),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func settle(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func field(_ placeholder: String, in root: NSView) throws -> NativeSessionTextControl {
        try XCTUnwrap(descendants(root).compactMap { $0 as? NativeSessionTextControl }.first { $0.placeholderString == placeholder },
                      "Mounted field: \(placeholder)")
    }
    private func multiLineBox(in root: NSView) throws -> NativeSessionTextView {
        try XCTUnwrap(descendants(root).compactMap { $0 as? NativeSessionTextView }.first { !$0.isFieldEditor },
                      "Mounted multi-line box")
    }

    func testEnumFocusLeavingTheMultiLineBoxKeepsTheKeyboardOnTheNextField() throws {
        for next in [Target.folder, .name] {
            let state = State()
            let host = NSHostingView(rootView: DescriptionThenField(state: state))
            let window = self.window(host)
            defer { window.contentView = nil; window.close() }
            settle(host)
            let box = try multiLineBox(in: host)
            XCTAssertTrue(window.makeFirstResponder(box))
            box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
            box.insertText(" and more", replacementRange: box.selectedRange())
            settle(host)
            XCTAssertTrue(window.firstResponder === box)
            XCTAssertEqual(state.describing, "Typed into the description and more")

            // "Other folder…" shows the folder box then moves focus; a failed Create moves it to the name.
            if next == .folder { state.typingFolder = true }
            state.requested = next
            settle(host)
            let target = try field(next == .folder ? "Full folder path" : "Task name", in: host)
            let editor = try XCTUnwrap(target.currentEditor(), "Moving focus out of the multi-line box must reach \(next)")
            XCTAssertTrue(window.firstResponder === editor, "The \(next) field must hold the keyboard, not nothing")
            (editor as? NSTextView)?.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(host)
            XCTAssertTrue((next == .folder ? state.folder : state.name).hasSuffix("x"), "Typing must reach the \(next) field")
        }
    }

    func testAbandonedSheetRequestDoesNotBlockALaterBoxThatAsksForFocus() throws {
        let state = State()
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 400))
        let window = self.window(root)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let elsewhere = NSTextView(frame: .init(x: 0, y: 300, width: 300, height: 60))
        root.addSubview(elsewhere)
        let host = NSHostingView(rootView: DeferredThenNew(state: state))
        host.frame = .init(x: 0, y: 0, width: 680, height: 280)
        root.addSubview(host)
        defer { window.cover = nil; window.contentView = nil; window.close(); sheet.close() }
        settle(host)

        window.cover = sheet
        state.requested = .first
        settle(host)
        let first = try field("First", in: host)
        XCTAssertNil(first.currentEditor(), "No field takes focus behind a sheet")
        XCTAssertTrue(nativeSessionDeferredFocusField(in: window) === first, "The request waits for the sheet")

        // The sheet closes while the person is typing somewhere else: the request is given up.
        window.cover = nil
        XCTAssertTrue(window.makeFirstResponder(elsewhere))
        let coordinator = try XCTUnwrap(first.delegate as? NativeSessionFieldCoordinator)
        coordinator.fulfilFocus(first)
        XCTAssertTrue(window.firstResponder === elsewhere, "A given-up request never takes the person's keyboard")
        XCTAssertNil(nativeSessionDeferredFocusField(in: window), "A given-up request leaves no record behind")

        // A new box asks for focus with no sheet, before and as it reaches the screen.
        state.showNew = true
        settle(host)
        let newBox = try field("New box", in: host)
        let editor = try XCTUnwrap(newBox.currentEditor(), "A later box that asks for focus gets it")
        XCTAssertTrue(window.firstResponder === editor)
        // And its own coordinator path is not cancelled by any stale record.
        let newCoordinator = try XCTUnwrap(newBox.delegate as? NativeSessionFieldCoordinator)
        newCoordinator.fulfilFocus(newBox)
        XCTAssertTrue(window.firstResponder === newBox.currentEditor())
    }

    func testSheetDeferredRequestOfAHiddenSessionLeavesNoRecord() throws {
        let state = State()
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 400))
        let window = self.window(root)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DeferredThenNew(state: state))
        host.frame = root.bounds
        root.addSubview(host)
        defer { window.cover = nil; window.contentView = nil; window.close(); sheet.close() }
        settle(host)
        window.cover = sheet
        state.requested = .first
        settle(host)
        let first = try field("First", in: host)
        XCTAssertTrue(nativeSessionDeferredFocusField(in: window) === first)
        state.active = false
        settle(host)
        XCTAssertNil(nativeSessionDeferredFocusField(in: window), "Hiding the session gives up its deferred request")
        window.cover = nil
        let coordinator = try XCTUnwrap(first.delegate as? NativeSessionFieldCoordinator)
        coordinator.fulfilFocus(first)
        XCTAssertNil(first.currentEditor(), "A hidden field never takes the keyboard")
    }

    /// The real New Task card: "Add description" must put the keyboard in the new multi-line box.
    func testAddDescriptionPutsTheKeyboardInTheRealDescriptionBox() throws {
        let context = TaskCreateContext(scopeProject: { "/scratch/focus-settle" },
                                        projects: { [TaskProject(path: "/scratch/focus-settle", title: "Scratch")] },
                                        withLeadSeats: { $0 }, startStore: {})
        let card = NativeTaskCreatePopup(preset: TaskCreateEntry.newTaskButton.preset, context: context, onClose: {})
            .frame(width: 660, height: 420)
        let host = NSHostingView(rootView: card)
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        // SwiftUI publishes its accessibility elements only after an assistive client asks.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        settle(host)
        let press = NSSelectorFromString("accessibilityPerformPress")
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.value(forKey: "accessibilityChildren") as? [NSObject] : nil) ?? []
            return [object] + (children + ((object as? NSView)?.subviews ?? [])).flatMap(walk)
        }
        let button = try XCTUnwrap(walk(host).first { node in
            node.responds(to: press) && (node.responds(to: NSSelectorFromString("accessibilityLabel"))
                ? (node.value(forKey: "accessibilityLabel") as? String)?.contains("Add description") == true : false)
        }, "The card offers Add description")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(try XCTUnwrap(button.method(for: press)), to: Press.self)(button, press))
        settle(host)
        let box = try multiLineBox(in: host)
        XCTAssertTrue(window.firstResponder === box, "Add description puts the keyboard in the description box, got \(String(describing: window.firstResponder))")
        box.insertText("typed at once", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(box.string, "typed at once")
    }
}
