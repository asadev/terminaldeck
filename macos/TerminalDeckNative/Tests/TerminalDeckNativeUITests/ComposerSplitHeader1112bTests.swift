import AppKit
import Observation
import SwiftUI
import XCTest
@testable import TerminalDeckNative

/// The exact owner boundary used by the production split host bar, with its actual
/// rename title. Read-only decorations are omitted so no session/settings singleton runs.
@MainActor final class ComposerLeak1112bSplitHeaderTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    @Observable final class Selection {
        var id = "session-a"
        var renamed: [(String, String)] = []
    }
    private struct Header: View {
        @Bindable var selection: Selection
        var body: some View {
            let id = selection.id
            NativeSplitSessionHeader(sessionID: id) {
                NativeSessionTitle(title: id == "session-a" ? "Alpha" : "Beta", rename: { name in
                    selection.renamed.append((id, name))
                })
            }.frame(width: 600, height: 100)
        }
    }
    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    private func fields(_ view: NSView) -> [NativeSessionTextControl] {
        ((view as? NativeSessionTextControl).map { [$0] } ?? [])
            + view.subviews.flatMap(fields)
    }
    private func property(_ object: NSObject, _ key: String) -> AnyObject? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(implementation, to: Getter.self)(object, selector)
    }
    /// SwiftUI publishes its accessibility elements only after an assistive client has asked
    /// the app for them. A test process has none (no VoiceOver, no UI automation), so the walk
    /// found no buttons at all. Ask on its behalf, the way an assistive client does.
    private func enableAccessibilityTree() {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }
    private func pressRename(_ title: String, in root: NSView) throws {
        enableAccessibilityTree()
        settle(root)
        var seen = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (property(object, "accessibilityChildren") as? [NSObject] ?? [])
                + ((object as? NSView)?.subviews ?? [])
            return [object] + children.flatMap(walk)
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let button = try XCTUnwrap(walk(root).first { node in
            let label = property(node, "accessibilityLabel") as? String
            let value = property(node, "accessibilityValue") as? String
            return (label == title || value == title) && node.responds(to: selector)
        }, "The production title must offer its rename button")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = try XCTUnwrap(button.method(for: selector))
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(button, selector))
        settle(root)
    }

    func testProductionSplitHeaderRetiresAnOpenRenameWhenTheHostSessionChanges() throws {
        let selection = Selection()
        let host = NSHostingView(rootView: Header(selection: selection))
        let window = ScratchWindow(contentRect: .init(x: -32000, y: -32000, width: 640, height: 140),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        try pressRename("Alpha", in: host)
        let firstField = try XCTUnwrap(fields(host).first)
        XCTAssertTrue(window.makeFirstResponder(firstField))
        let oldClient = try XCTUnwrap(firstField.currentEditor() as? NativeSessionTextView)
        oldClient.insertText("Alpha pending draft", replacementRange: .init(location: 0, length: (oldClient.string as NSString).length))
        settle(host)
        XCTAssertEqual(firstField.stringValue, "Alpha pending draft")

        selection.id = "session-b"
        settle(host)
        XCTAssertTrue(fields(host).isEmpty, "B must start with its title, not A's open rename state")
        XCTAssertFalse(window.firstResponder === oldClient)
        oldClient.insertText("late A text", replacementRange: .init(location: NSNotFound, length: 0))
        oldClient.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle(host)
        XCTAssertFalse(selection.renamed.contains { $0.0 == "session-b" }, "A's retained editor cannot rename B")

        try pressRename("Beta", in: host)
        let secondField = try XCTUnwrap(fields(host).first)
        XCTAssertFalse(firstField === secondField)
        XCTAssertEqual(secondField.stringValue, "Beta")
        XCTAssertTrue(window.makeFirstResponder(secondField))
        let current = try XCTUnwrap(secondField.currentEditor() as? NativeSessionTextView)
        current.insertText("Beta own name", replacementRange: .init(location: 0, length: (current.string as NSString).length))
        current.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        settle(host)
        XCTAssertTrue(selection.renamed.contains { $0.0 == "session-b" && $0.1 == "Beta own name" })
    }
}
