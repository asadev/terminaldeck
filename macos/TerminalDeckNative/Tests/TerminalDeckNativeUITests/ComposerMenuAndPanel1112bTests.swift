import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// A guarded button inside a real Menu and a real confirmation dialog runs when AppKit performs
/// it after closing, for a visible owner, and not for a hidden one. Corrections from a system
/// panel, and an input method's commit after a brief loss of the keyboard, reach a visible box
/// and not a hidden one. Windows are never ordered in; no app model, engine or session.
@MainActor final class ComposerLeak1112bMenuAndPanelTests: XCTestCase {
    @Observable final class State {
        var active = true
        var ran = 0
        var disappeared = 0
        var dialog = false
        var notes = "Teh draft"
        var showButton = true
        var showEditor = true
        var exits = 0
        var exitAction: NativeSessionEditorAction?
    }

    /// Keeps the Escape action an editor under `sessionOnExitCommand` receives.
    private struct ExitProbe: View {
        @Environment(\.nativeSessionEditorExit) private var exit
        let state: State
        var body: some View {
            Color.clear.frame(width: 10, height: 10).onAppear { state.exitAction = exit }
        }
    }

    private struct MenuFixture: View {
        @Bindable var state: State
        var body: some View {
            VStack {
                Menu("More") {
                    NativeSessionButton("Run guarded") { state.ran += 1 }
                        .onDisappear { state.disappeared += 1 }
                }
                .accessibilityIdentifier("More guard menu")
                if state.showEditor {
                    ExitProbe(state: state).sessionOnExitCommand { state.exits += 1 }
                }
                if state.showButton {
                    NativeSessionButton("Run detached") { state.ran += 1 }
                        .onDisappear { state.disappeared += 1 }
                }
                Text("Owner").confirmationDialog("Sure?", isPresented: $state.dialog) {
                    NativeSessionButton("Confirm guarded") { state.ran += 1 }
                }
            }
            .nativeSessionInputScope(ownerID: "menu-fixture")
            .environment(\.nativeScreenActive, state.active)
            .frame(width: 400, height: 200)
        }
    }

    private struct BoxFixture: View {
        @Bindable var state: State
        var body: some View {
            NativeSessionTextEditor(text: $state.notes)
                .nativeSessionInputScope(ownerID: "panel-fixture")
                .environment(\.nativeScreenActive, state.active)
                .frame(width: 400, height: 120)
        }
    }

    final class ScratchWindow: NSWindow {
        var key = false
        var main = false
        override var isKeyWindow: Bool { key }
        override var isMainWindow: Bool { main }
    }

    private func window(_ content: NSView) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 480, height: 260),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }
    private func settle(_ view: NSView) {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func property(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(implementation, to: Getter.self)(object, selector)
    }
    private func nodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (property(object, "accessibilityChildren") as? [NSObject] ?? []) + ((object as? NSView)?.subviews ?? [])
            return [object] + children.flatMap(walk)
        }
        return walk(root)
    }

    /// The native action of the rendered guarded button, kept the way AppKit keeps a menu item's
    /// target: it stays callable after the button's own view is gone.
    private func retainPress(_ label: String, in host: NSView) throws -> () -> Void {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        settle(host)
        let press = NSSelectorFromString("accessibilityPerformPress")
        let node = try XCTUnwrap(nodes(host).first { $0.responds(to: press) && (property($0, "accessibilityLabel") as? String) == label },
                                 "The rendered button \(label)")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let call = unsafeBitCast(try XCTUnwrap(node.method(for: press)), to: Press.self)
        return { _ = call(node, press) }
    }

    /// The order a menu or dialog can produce: the item's own view is torn down (its onDisappear
    /// has run) and only then is its action performed. The guard must answer from the owner alone.
    func testGuardedActionRunsAfterItsOwnViewIsGoneForAVisibleOwnerOnly() throws {
        let state = State()
        let host = NSHostingView(rootView: MenuFixture(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let first = try retainPress("Run detached", in: host)
        state.showButton = false
        settle(host)
        XCTAssertEqual(state.disappeared, 1, "The button's view is gone and its onDisappear has run")
        first()
        settle(host)
        XCTAssertEqual(state.ran, 1, "Its action still runs while the owner is on screen")

        state.showButton = true
        settle(host)
        let second = try retainPress("Run detached", in: host)
        state.showButton = false
        state.active = false
        settle(host)
        second()
        settle(host)
        XCTAssertEqual(state.ran, 1, "With the owner hidden it does not run")
    }

    /// Escape in an editor whose view has reported itself gone (onDisappear ran) still works
    /// while its owner is on screen, and does nothing while the owner is hidden.
    func testEscapeAsksTheOwnerNotWhetherItsViewDisappeared() throws {
        let state = State()
        let host = NSHostingView(rootView: MenuFixture(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let escape = try XCTUnwrap(state.exitAction, "The editor's Escape action")
        state.showEditor = false
        settle(host)
        escape.run()
        XCTAssertEqual(state.exits, 1, "Escape still runs while the owner is on screen")

        state.showEditor = true
        settle(host)
        let again = try XCTUnwrap(state.exitAction)
        state.active = false
        settle(host)
        again.run()
        XCTAssertEqual(state.exits, 1, "Escape does nothing while the owner is hidden")
    }

    private func dialogButton(_ title: String, near window: NSWindow) -> NSButton? {
        let windows = [window.attachedSheet].compactMap { $0 } + NSApp.windows.filter { $0 !== window }
        for candidate in windows {
            guard let root = candidate.contentView else { continue }
            if let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) { return button }
        }
        return nil
    }

    func testGuardedConfirmationButtonRunsForAVisibleOwnerOnly() throws {
        let state = State()
        let host = NSHostingView(rootView: MenuFixture(state: state))
        let window = self.window(host)
        defer { state.dialog = false; window.contentView = nil; window.close() }
        settle(host)
        state.dialog = true
        settle(host)
        let button = try XCTUnwrap(dialogButton("Confirm guarded", near: window),
                                   "The dialog's button: windows \(NSApp.windows.map { String(describing: type(of: $0)) })")
        button.performClick(nil)
        settle(host)
        XCTAssertEqual(state.ran, 1, "A visible owner's dialog button runs when the dialog closes")

        state.dialog = true
        settle(host)
        let again = try XCTUnwrap(dialogButton("Confirm guarded", near: window))
        state.active = false
        settle(host)
        again.performClick(nil)
        settle(host)
        XCTAssertEqual(state.ran, 1, "A dialog button whose owner was hidden does not run")
    }

    func testSpellingAndTranslatePanelCorrectionsReachAVisibleBoxOnly() throws {
        let saved = NativeSessionInputRule.keyWindow
        defer { NativeSessionInputRule.keyWindow = saved }
        let state = State()
        let host = NSHostingView(rootView: BoxFixture(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        window.main = true
        settle(host)
        let box = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextView }.first { !$0.isFieldEditor })
        XCTAssertTrue(window.makeFirstResponder(box))
        // The Spelling (or Translate) panel is the key window; this window stays main.
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .utilityWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        NativeSessionInputRule.keyWindow = { panel }

        box.setSelectedRange(NSRange(location: 0, length: 3))
        box.changeSpelling(NSTextField(string: "The"))
        settle(host)
        XCTAssertEqual(state.notes, "The draft", "The Spelling panel's Change reaches a visible box")
        let all = NSRange(location: 0, length: (box.string as NSString).length)
        box.insertText("Le brouillon", replacementRange: all)
        settle(host)
        XCTAssertEqual(state.notes, "Le brouillon", "The Translate panel's Replace reaches a visible box")

        // Another of the app's own windows in front is not a panel serving this box.
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NativeSessionInputRule.keyWindow = { other }
        box.insertText("stale", replacementRange: NSRange(location: 0, length: 0))
        settle(host)
        XCTAssertEqual(state.notes, "Le brouillon", "Text for another window never reaches this box")

        NativeSessionInputRule.keyWindow = { panel }
        state.active = false
        settle(host)
        box.setSelectedRange(NSRange(location: 0, length: 2))
        box.changeSpelling(NSTextField(string: "La"))
        box.insertText("hidden", replacementRange: NSRange(location: 0, length: 0))
        settle(host)
        XCTAssertEqual(state.notes, "Le brouillon", "A hidden box takes no panel correction")
    }

    func testCompositionSurvivesABriefLossOfTheKeyboardButNotAHide() throws {
        let state = State()
        state.notes = "Draft "
        let host = NSHostingView(rootView: BoxFixture(state: state))
        let window = self.window(host)
        defer { window.contentView = nil; window.close() }
        window.key = true
        settle(host)
        let box = try XCTUnwrap(descendants(host).compactMap { $0 as? NativeSessionTextView }.first { !$0.isFieldEditor })
        XCTAssertTrue(window.makeFirstResponder(box))
        box.setSelectedRange(NSRange(location: (box.string as NSString).length, length: 0))
        box.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(box.hasMarkedText())

        // Another window comes forward for a moment; the input method commits what was composed.
        window.key = false
        box.unmarkText()
        settle(host)
        XCTAssertFalse(box.hasMarkedText())
        XCTAssertEqual(box.string, "Draft にほ", "The composition is kept, not discarded")
        XCTAssertEqual(state.notes, "Draft にほ", "and reaches the draft")

        // An input method that commits by inserting its text.
        window.key = true
        box.setMarkedText("ん", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.key = false
        box.insertText("ん", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(state.notes, "Draft にほん")
        // Without a composition in progress, typing still needs the keyboard.
        box.insertText(" stale", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(state.notes, "Draft にほん")

        // Hiding the session discards a composition in progress.
        window.key = true
        box.setMarkedText("ご", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        state.active = false
        settle(host)
        box.unmarkText()
        box.insertText("ご", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertFalse(box.string.contains("ご"), "A hidden box drops the composition")
        XCTAssertEqual(state.notes, "Draft にほん")
    }
}
