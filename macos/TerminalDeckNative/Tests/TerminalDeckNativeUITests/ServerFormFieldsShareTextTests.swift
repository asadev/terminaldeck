import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// 13 Nov proof S7: the four "Add a server" boxes showed one text, so no server could be added.
/// Cause: 0.21.4 gave every session text box `.id(<screen scope or nil>)` on its outside, so all boxes
/// of one screen had the SAME identity and a grouped Form/List treated them as one row.
/// These tests click (make the box the keyboard holder) and type box after box, and check each box
/// and each value holds only its own text. Before the fix every box showed, and wrote, the first box's value.
/// Offscreen windows and fixture-only models: no app data, no host, no activation.
@MainActor final class ServerFormFieldsShareTextTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    @Observable final class Values {
        var address = ""
        var user = ""
        var port = ""
        var name = ""
        var password = ""
    }

    /// The add-server shape: four session boxes in one Section of a grouped Form, plus a password.
    private struct GroupedForm: View {
        @Bindable var values: Values
        var body: some View {
            Form {
                Section("Connection") {
                    NativeSessionTextField("Address", text: $values.address, prompt: Text("server.example.com"))
                    NativeSessionTextField("Sign in as", text: $values.user, prompt: Text("admin"))
                    NativeSessionTextField("Port", text: $values.port, prompt: Text("22"))
                    NativeSessionTextField("Name", text: $values.name, prompt: Text("Optional"))
                }
                Section("Sign-in") { NativeSessionSecureField("Password", text: $values.password) }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).frame(width: 600, height: 520)
        }
    }

    // MARK: harness

    private func mount<V: View>(_ root: V, width: CGFloat = 700, height: CGFloat = 650) -> (NSHostingView<V>, ScratchWindow) {
        let host = NSHostingView(rootView: root)
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: width, height: height),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Session boxes top to bottom as a person sees them (plain boxes, then secure if asked).
    private func boxes(_ host: NSView, secure: Bool = false) -> [NSTextField] {
        descendants(host).compactMap { $0 as? NSTextField }
            .filter { secure ? $0 is NativeSessionSecureControl : $0 is NativeSessionTextControl }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .sorted { a, b in
                let fa = a.convert(a.bounds, to: nil), fb = b.convert(b.bounds, to: nil)
                return fa.maxY == fb.maxY ? fa.minX < fb.minX : fa.maxY > fb.maxY
            }
    }

    /// What a click on a box ends in: the window makes that box the keyboard holder. (Synthetic mouse
    /// and key events do not reach even a plain SwiftUI TextField in an offscreen test window, so the
    /// click's effect is driven directly and the typing goes into the box's own field editor.)
    private func click(_ field: NSTextField, in window: NSWindow) {
        XCTAssertTrue(window.makeFirstResponder(field))
    }

    /// Typing: text inserted by the editor that holds the keyboard, as the key handler does.
    private func type(_ text: String, in window: NSWindow) {
        (window.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Click box i, type its own text, for every box in order; then each box must hold only its own.
    private func clickAndTypeEach(_ fields: [NSTextField], texts: [String], host: NSView, window: NSWindow,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for (field, text) in zip(fields, texts) {
            click(field, in: window)
            settle(host)
            XCTAssertTrue(field.currentEditor() != nil && window.firstResponder === field.currentEditor(),
                          "Clicking a box puts the keyboard in THAT box", file: file, line: line)
            type(text, in: window)
            settle(host)
        }
        XCTAssertEqual(Set(fields.map(ObjectIdentifier.init)).count, fields.count, "Every box is its own control", file: file, line: line)
        XCTAssertEqual(fields.map(\.stringValue), texts, "Each box holds only what was typed into it", file: file, line: line)
    }

    // MARK: the shared component

    func testGroupedFormBoxesEachKeepTheirOwnTextWithoutAScope() throws {
        let values = Values()
        let (host, window) = mount(GroupedForm(values: values))
        defer { window.contentView = nil; window.close() }
        let fields = boxes(host)
        XCTAssertEqual(fields.count, 4)
        clickAndTypeEach(fields, texts: ["host.example", "deploy", "2222", "Web"], host: host, window: window)
        XCTAssertEqual([values.address, values.user, values.port, values.name], ["host.example", "deploy", "2222", "Web"])
        let secret = try XCTUnwrap(boxes(host, secure: true).first)
        click(secret, in: window); settle(host)
        type("pw", in: window); settle(host)
        XCTAssertEqual(values.password, "pw")
        XCTAssertEqual([values.address, values.user, values.port, values.name], ["host.example", "deploy", "2222", "Web"],
                       "The password never lands in a plain box")
    }

    func testGroupedFormBoxesEachKeepTheirOwnTextInsideASessionScope() throws {
        let values = Values()
        let (host, window) = mount(GroupedForm(values: values).nativeSessionInputScope(ownerID: "screen-a"))
        defer { window.contentView = nil; window.close() }
        let fields = boxes(host)
        XCTAssertEqual(fields.count, 4)
        clickAndTypeEach(fields, texts: ["a.example", "root", "22", "Box"], host: host, window: window)
        XCTAssertEqual([values.address, values.user, values.port, values.name], ["a.example", "root", "22", "Box"])
    }

    /// Guard: no session input component may put an owner id on its own outside again.
    func testSessionInputsKeepTheOwnerIdentityInside() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative")
        for name in ["NativeSessionEditor.swift", "NativeSessionDatePicker.swift", "NativeSessionNumberField.swift", "NativeTaskPopupText.swift"] {
            let code = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(code.contains(".id(scope?.identity)"), "\(name): use nativeSessionOwnedInput, not a bare outside id")
            XCTAssertTrue(code.contains("nativeSessionOwnedInput("), name)
        }
    }

    // MARK: real forms

    /// The real "Add a server" sheet: Type an address, click and type every box, then the password.
    func testRealAddServerSheetBoxesEachKeepTheirOwnText() throws {
        let model = MACHINESRenderEvidence.fixtureModel()
        let (host, window) = mount(MACHINESAddServerSheet(model: model, route: .constant(.list), cancel: {},
                                                          fixtureAliases: MACHINESFixtures.aliases), width: 600, height: 550)
        defer { window.contentView = nil; window.close() }
        let picker = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSegmentedControl }.first, "Saved sign-in / Type an address")
        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        settle(host)
        let fields = boxes(host)
        XCTAssertEqual(fields.count, 4, "Address, Sign in as, Port, Name")
        clickAndTypeEach(fields, texts: ["203.0.113.9", "deploy", "2200", "Web box"], host: host, window: window)
        let secret = try XCTUnwrap(boxes(host, secure: true).first, "Password box")
        click(secret, in: window); settle(host)
        type("pw", in: window); settle(host)
        XCTAssertEqual(secret.stringValue, "pw")
        XCTAssertEqual(boxes(host).map(\.stringValue), ["203.0.113.9", "deploy", "2200", "Web box"])
    }

    /// A sign-in style form: the API account editor (name, key, base URL, workspace, model).
    func testRealAPIAccountFormBoxesEachKeepTheirOwnText() throws {
        let (host, window) = mount(NativeAPIAccountEditor(provider: "claude").frame(width: 560, height: 600), width: 560, height: 600)
        defer { window.contentView = nil; window.close() }
        let fields = boxes(host)
        XCTAssertEqual(fields.count, 4, "Account name, Base URL, Workspace ID, Default model")
        clickAndTypeEach(fields, texts: ["Work", "https://gw.example", "wrkspc_1", "model-x"], host: host, window: window)
        let key = try XCTUnwrap(boxes(host, secure: true).first, "API key box")
        click(key, in: window); settle(host)
        type("k", in: window); settle(host)
        XCTAssertEqual(key.stringValue, "k")
        XCTAssertEqual(boxes(host).map(\.stringValue), ["Work", "https://gw.example", "wrkspc_1", "model-x"])
    }

    /// The New Task card with a typed folder: task name and folder are two separate boxes.
    func testRealNewTaskCardNameAndFolderKeepTheirOwnText() throws {
        let context = TaskCreateContext(scopeProject: { "/scratch/server-form" }, projects: { [] },
                                        withLeadSeats: { $0 }, startStore: {})
        let card = NativeTaskCreatePopup(preset: TaskCreateEntry.newTaskButton.preset, context: context, onClose: {})
            .frame(width: 660, height: 420)
        let (host, window) = mount(card, width: 660, height: 420)
        defer { window.contentView = nil; window.close() }
        let fields = boxes(host)
        XCTAssertEqual(fields.count, 2, "Task name and Full folder path")
        let name = try XCTUnwrap(fields.first { $0.stringValue.isEmpty })
        let folder = try XCTUnwrap(fields.first { $0.stringValue == "/scratch/server-form" })
        click(name, in: window); settle(host)
        type("Fix it", in: window); settle(host)
        click(folder, in: window); settle(host)
        type("/x", in: window); settle(host)
        XCTAssertEqual(name.stringValue, "Fix it")
        XCTAssertTrue(folder.stringValue.contains("/x") && !folder.stringValue.contains("Fix it"), "Folder: \(folder.stringValue)")
    }
}
