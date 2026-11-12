import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore
import XCTest
@testable import TerminalDeckNative

/// Offscreen Cocoa controls with fixture-only models. No system clipboard, activation,
/// session host, hook configuration or app data is involved.
@MainActor final class ComposerLeak1112bEditorInputTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        var coveringSheet: NSWindow?
        override var isKeyWindow: Bool { keyboardActive }
        override var attachedSheet: NSWindow? { coveringSheet }
    }

    @Observable final class State {
        var active = true
        var enabled = true
        var field = "plain own draft"
        var secret = "secure own answer"
        var otherSecret = "other secure answer"
        var editor = "long own draft"
        var hoot = HootComposerDraft(text: "Hoot own draft")
        var secondHoot = HootComposerDraft(text: "Second chat own draft")
        var firstSelected = true
        var bothVisible = false
        var submissions = 0
        var answers = 0
    }

    private struct Controls: View {
        @Bindable var state: State
        var body: some View {
            VStack {
                NativeSessionTextField("Plain", text: $state.field, onSubmit: { state.submissions += 1 })
                NativeSessionSecureField("Secure", text: $state.secret, onSubmit: { state.submissions += 1 })
                NativeSessionTextEditor(text: $state.editor).frame(height: 90)
                HootComposer(draft: $state.hoot, microphoneAvailable: false, onSend: { _ in state.submissions += 1 }, onStop: {})
            }
            .environment(\.nativeScreenActive, state.active)
            .disabled(!state.enabled)
            .opacity(state.active ? 1 : 0)
            .frame(width: 640, height: 420)
        }
    }

    private struct MainComposers: View {
        @Bindable var state: State
        var includeOtherField = false
        var body: some View {
            VStack {
                HootComposer(draft: $state.hoot, ownerID: "first", focusWhenShown: true,
                             microphoneAvailable: false, onSend: { _ in state.submissions += 1 }, onStop: {})
                    .nativeSessionInputScope(ownerID: "first")
                    .environment(\.nativeTerminalSelected, state.firstSelected)
                    .environment(\.nativeScreenActive, state.bothVisible || state.firstSelected)
                HootComposer(draft: $state.secondHoot, ownerID: "second", focusWhenShown: true,
                             microphoneAvailable: false, onSend: { _ in state.submissions += 1 }, onStop: {})
                    .nativeSessionInputScope(ownerID: "second")
                    .environment(\.nativeTerminalSelected, !state.firstSelected)
                    .environment(\.nativeScreenActive, state.bothVisible || !state.firstSelected)
                if includeOtherField { NativeSessionTextField("Another field", text: $state.field) }
            }.frame(width: 640, height: 500)
        }
    }

    @MainActor @Observable final class Owners {
        var selected = "first"
        var first = "same committed draft"
        var second = "same committed draft"
    }
    struct OwnedField: View {
        @Bindable var owners: Owners
        var body: some View {
            NativeSessionTextField("Owner draft", text: Binding(
                get: { owners.selected == "first" ? owners.first : owners.second },
                set: { value in
                    if owners.selected == "first" { owners.first = value }
                    else { owners.second = value }
                }))
                .nativeSessionInputScope(ownerID: owners.selected)
                .frame(width: 500, height: 100)
        }
    }

    private struct Queue: View {
        @Bindable var state: State
        let model: NativeHootChatModel
        let id: String
        var body: some View {
            Group {
                if let item = model.queuedMessages.first(where: { $0.id == id }) {
                    NativeQueuedMessageRow(model: model, item: item)
                }
            }
            .environment(\.nativeScreenActive, state.active)
            .opacity(state.active ? 1 : 0)
            .frame(width: 640, height: 250)
        }
    }

    private struct Form: View {
        @Bindable var state: State
        let request: NativeRPCValue
        var body: some View {
            NativeChatElicitationCard(request: request, disabled: false, answer: { _, _ in state.answers += 1 })
                .environment(\.nativeScreenActive, state.active)
                .opacity(state.active ? 1 : 0)
                .frame(width: 640, height: 350)
        }
    }

    private func mount<V: View>(_ root: V, height: CGFloat = 650) -> (NSHostingView<V>, ScratchWindow) {
        let host = NSHostingView(rootView: root)
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 700, height: height),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        return (host, window)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func protectedFields(_ host: NSView) -> [NSTextField] {
        descendants(host).compactMap { $0 as? NSTextField }.filter { $0 is any NativeSessionInputProtected }
    }

    private func editableViews(_ host: NSView) -> [NativeSessionTextView] {
        descendants(host).compactMap { $0 as? NativeSessionTextView }.filter { !$0.isFieldEditor }
    }

    /// Each Cocoa entry point is invoked on the retained, old input client after hide.
    /// A visibility Boolean by itself cannot make these assertions pass.
    private func assertRejectsLateInput(_ editor: NativeSessionTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = editor.string
        let range = NSRange(location: NSNotFound, length: 0)
        editor.insertText("wrong session", replacementRange: range)
        XCTAssertEqual(editor.string, before, file: file, line: line)
        editor.insertText("old input client")
        XCTAssertEqual(editor.string, before, file: file, line: line)
        editor.setMarkedText("wrong composition", selectedRange: NSRange(location: 1, length: 0), replacementRange: range)
        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText(), file: file, line: line)
        XCTAssertEqual(editor.string, before, file: file, line: line)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("wrong service", forType: .string)
        XCTAssertFalse(editor.readSelection(from: board), file: file, line: line)
        XCTAssertFalse(editor.readSelection(from: board, type: .string), file: file, line: line)
        editor.setAccessibilityValue("wrong accessibility")
        editor.accessibilitySetValue("wrong legacy accessibility", forAttribute: .value)
        XCTAssertEqual(editor.string, before, file: file, line: line)
        XCTAssertFalse(editor.shouldChangeText(in: NSRange(location: 0, length: 0), replacementString: "wrong replacement"), file: file, line: line)
        XCTAssertFalse(editor.shouldChangeText(inRanges: [NSValue(range: NSRange(location: 0, length: 0))], replacementStrings: ["wrong replacement"]), file: file, line: line)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(editor.string, before, file: file, line: line)
    }

    func testRealControlsRejectHiddenServicesAccessibilityCompositionAndReturn() throws {
        let state = State()
        let (host, window) = mount(Controls(state: state))
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(protectedFields(host).first { $0 is NativeSessionTextControl })
        XCTAssertTrue(window.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(window.firstResponder === fieldEditor)
        fieldEditor.insertText(" visible", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertTrue(state.field.contains(" visible"), "The same protected control must accept real input while shown")
        let accepted = state.field
        let retained = editableViews(host) + [fieldEditor]
        XCTAssertEqual(retained.count, 3, "Actual long editor, Hoot composer and owned text-field editor")
        state.active = false
        settle(host)
        XCTAssertFalse(window.firstResponder === fieldEditor)
        for editor in retained { try assertRejectsLateInput(editor) }
        field.setAccessibilityValue("wrong control value")
        field.accessibilitySetValue("wrong old control value", forAttribute: .value)
        XCTAssertEqual(state.field, accepted)
        XCTAssertEqual(field.stringValue, accepted)
        XCTAssertEqual(state.editor, "long own draft")
        XCTAssertEqual(state.hoot.text, "Hoot own draft")
        XCTAssertEqual(state.submissions, 0)
    }

    func testVisibleEditorRequiresActualKeyboardAndKeyWindow() throws {
        let state = State()
        let (host, window) = mount(Controls(state: state))
        defer { window.contentView = nil; window.close() }
        let editors = editableViews(host)
        let editor = try XCTUnwrap(editors.first { !($0 is HootComposerTextView) })
        let other = try XCTUnwrap(editors.first { $0 is HootComposerTextView })
        XCTAssertTrue(window.makeFirstResponder(other))
        editor.insertText("wrong focus", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(state.editor, "long own draft")
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(" accepted", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        let accepted = state.editor
        XCTAssertTrue(accepted.contains(" accepted"))
        window.keyboardActive = false
        editor.insertText("wrong window", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, accepted)
        XCTAssertEqual(state.editor, accepted)
        window.keyboardActive = true
        state.enabled = false
        settle(host)
        try assertRejectsLateInput(editor)
        XCTAssertEqual(state.editor, accepted)
    }

    func testHidingDiscardsProvisionalCompositionAndToolsStillUpdateHiddenDrafts() throws {
        let state = State()
        let (host, window) = mount(Controls(state: state))
        defer { window.contentView = nil; window.close() }
        let editor = try XCTUnwrap(editableViews(host).first { !($0 is HootComposerTextView) })
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText(" provisional", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(state.editor, "long own draft", "Provisional IME text is not a committed model edit")
        state.active = false
        settle(host)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "long own draft")
        XCTAssertEqual(state.editor, "long own draft")
        state.field = "tool set plain"
        state.secret = "tool set secure"
        state.editor = "tool set long"
        state.hoot.text = "tool set Hoot"
        settle(host)
        XCTAssertEqual(editor.string, "tool set long")
        XCTAssertEqual(protectedFields(host).first { $0 is NativeSessionTextControl }?.stringValue, "tool set plain")
        XCTAssertEqual(protectedFields(host).first { $0 is NativeSessionSecureControl }?.stringValue, "tool set secure")
        XCTAssertEqual(editableViews(host).first { $0 is HootComposerTextView }?.string, "tool set Hoot")
        for view in editableViews(host) { try assertRejectsLateInput(view) }
        XCTAssertEqual(state.hoot.text, "tool set Hoot")
    }

    func testActualQueuedMessageCannotBeEditedOrReleasedByAHiddenClient() async throws {
        let state = State()
        let model = NativeHootChatModel(fixture: .object([
            .init("conversationId", .string("composer-editor-fixture")), .init("provider", .string("codex")),
            .init("events", .array([])), .init("alive", .bool(true)), .init("busy", .bool(true))
        ]), source: .session("composer-editor-fixture-" + UUID().uuidString, provider: "codex"))
        _ = try await model.queueTool("queue", id: nil, text: "queued own draft", context: .object([]))
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        model.editQueued(id, editing: true)
        model.holdQueuedMessages("Keep until the user saves")
        let (host, window) = mount(Queue(state: state, model: model, id: id))
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(protectedFields(host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(window.firstResponder === editor)
        state.active = false
        settle(host)
        try assertRejectsLateInput(editor)
        XCTAssertEqual(model.queuedText(id), "queued own draft")
        XCTAssertTrue(model.queuedMessages.first?.editing == true)
        XCTAssertTrue(model.queuedMessages.first?.held == true, "A delayed Return cannot release/send the queue")
        // Explicit tool/model changes remain independent of this field's UI visibility.
        model.setQueuedText(id, text: "explicit queued update")
        settle(host)
        XCTAssertEqual(field.stringValue, "explicit queued update")
        XCTAssertEqual(model.queuedText(id), "explicit queued update")
        XCTAssertTrue(model.queuedMessages.first?.editing == true)
    }

    private func formRequest() throws -> NativeRPCValue {
        let schema = #"{"mode":"form","message":"Answer these questions","requestedSchema":{"type":"object","properties":{"plain":{"title":"Plain answer","type":"string"},"secret":{"title":"Secure answer","type":"string","secret":true}}}}"#
        return .object([.init("subtype", .string("mcpServer/elicitation/request")),
                        .init("input", try .parseJSON(Data(schema.utf8)))])
    }

    func testActualFormAndSecureAnswerDropFocusAndRejectLateCommits() throws {
        let state = State()
        let (host, window) = mount(Form(state: state, request: try formRequest()))
        defer { window.contentView = nil; window.close() }
        let fields = protectedFields(host)
        XCTAssertEqual(fields.count, 2, "Mount the real form's plain and secure answers")
        let secure = try XCTUnwrap(fields.first { $0 is NativeSessionSecureControl })
        XCTAssertTrue(window.makeFirstResponder(secure))
        let secureEditor = try XCTUnwrap(secure.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === secureEditor)
        secureEditor.insertText("accepted secure answer", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        let before = secure.stringValue
        XCTAssertEqual(before, "accepted secure answer")
        state.active = false
        settle(host)
        XCTAssertFalse(window.firstResponder === secureEditor)
        secureEditor.insertText("wrong hidden answer", replacementRange: NSRange(location: NSNotFound, length: 0))
        secureEditor.setMarkedText("wrong marked answer", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        secure.setAccessibilityValue("wrong secure accessibility")
        secureEditor.setAccessibilityValue("wrong retained secure accessibility")
        secureEditor.accessibilitySetValue("wrong retained secure legacy accessibility", forAttribute: .value)
        settle(host)
        XCTAssertEqual(secure.stringValue, before)
        XCTAssertEqual(secureEditor.string, before, "The retained secure editor must reject/rollback late input too")
        XCTAssertFalse(secureEditor.hasMarkedText())
        XCTAssertEqual(state.answers, 0)
        for field in fields {
            XCTAssertTrue(field is any NativeSessionInputProtected)
            XCTAssertFalse(field.acceptsFirstResponder)
        }
        state.active = true
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(secure))
        let restoredEditor = try XCTUnwrap(secure.currentEditor() as? NSTextView)
        XCTAssertTrue(restoredEditor.isEditable, "Secure field resumes live input after showing again")
        restoredEditor.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
        restoredEditor.insertText(" again", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(secure.stringValue, before + " again")
    }

    func testTwoSecureAnswersNeverReuseARetainedTextInputClient() throws {
        let state = State()
        struct Pair: View {
            @Bindable var state: State
            var body: some View {
                ZStack {
                    NativeSessionSecureField("First answer", text: $state.secret)
                        .environment(\.nativeScreenActive, state.active)
                        .opacity(state.active ? 1 : 0)
                    NativeSessionSecureField("Second answer", text: $state.otherSecret)
                        .environment(\.nativeScreenActive, !state.active)
                        .opacity(state.active ? 0 : 1)
                }.frame(width: 500, height: 100)
            }
        }
        let (host, window) = mount(Pair(state: state))
        defer { window.contentView = nil; window.close() }
        let fields = protectedFields(host)
        let first = try XCTUnwrap(fields.first { $0.placeholderString == "First answer" })
        let second = try XCTUnwrap(fields.first { $0.placeholderString == "Second answer" })
        XCTAssertTrue(window.makeFirstResponder(first))
        let oldClient = try XCTUnwrap(first.currentEditor() as? NSTextView)
        state.active = false
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(second))
        let nextClient = try XCTUnwrap(second.currentEditor() as? NSTextView)
        XCTAssertFalse(oldClient === nextClient, "Each secure control owns its native masked editor")
        XCTAssertTrue(window.firstResponder === nextClient)
        oldClient.insertText("wrong old answer", replacementRange: NSRange(location: NSNotFound, length: 0))
        oldClient.setMarkedText("wrong old composition", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        oldClient.setAccessibilityValue("wrong old accessibility")
        settle(host)
        XCTAssertEqual(state.secret, "secure own answer")
        XCTAssertEqual(state.otherSecret, "other secure answer")
        XCTAssertEqual(nextClient.string, "other secure answer")
        XCTAssertEqual(oldClient.string, "secure own answer")
        XCTAssertFalse(oldClient.hasMarkedText())
        nextClient.setSelectedRange(NSRange(location: (nextClient.string as NSString).length, length: 0))
        nextClient.insertText(" accepted", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(state.otherSecret, "other secure answer accepted")
    }

    func testRemoteHootDraftsRemainWithTheirMachineWithoutStartingAConnection() {
        let model = NativeRemoteCopilotModel()
        model.selectDraft(for: "first-machine")
        model.typed = "first machine only"
        model.selectDraft(for: "second-machine")
        XCTAssertEqual(model.typed, "")
        model.typed = "second machine only"
        model.selectDraft(for: "first-machine")
        XCTAssertEqual(model.typed, "first machine only")
        model.selectDraft(for: "second-machine")
        XCTAssertEqual(model.typed, "second machine only")
    }

    func testRetainedPopoverScopeClosesInputBeforeItsEditorRendersAgain() throws {
        let state = State()
        let scope = NativeSessionInputScope()
        let content = Controls(state: state).environment(\.nativeSessionInputScope, scope)
        let (host, window) = mount(content)
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(protectedFields(host).first { $0 is NativeSessionTextControl })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        // A presentation can retain its original `nativeScreenActive == true` value.
        // Its owner's shared scope must close it even with no local SwiftUI redraw.
        scope.setActive(false)
        for retained in editableViews(host) {
            retained.insertText("wrong retained long editor", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertEqual(state.editor, "long own draft")
        XCTAssertEqual(state.hoot.text, "Hoot own draft")
        editor.insertText("wrong retained presentation", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(state.field, "plain own draft")
        XCTAssertEqual(editor.string, "plain own draft")
        settle(host)
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertFalse(editor.isEditable)
        state.field = "explicit hidden model update"
        settle(host)
        XCTAssertEqual(field.stringValue, "explicit hidden model update")
        scope.setActive(true)
        settle(host)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(editor.isEditable)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" accepted", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(state.field, "explicit hidden model update accepted")
    }

    func testScopeFastHideDiscardsCompositionBeforeReshow() throws {
        let scope = NativeSessionInputScope()
        let editor = NativeSessionTextView()
        editor.inputRule.owner = editor
        editor.inputRule.bind(to: scope)
        editor.updateInput(active: true, enabled: true)
        editor.applyModelText("committed")
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 400, height: 150),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.setMarkedText(" provisional", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let epoch = editor.inputRule.epoch
        scope.setActive(false)
        // Deliberately do not turn the run loop: discard must occur before a fast reshow.
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "committed")
        XCTAssertGreaterThan(editor.inputRule.epoch, epoch)
        scope.setActive(true)
        settle(editor)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.inputRule.acceptsFocus)
        XCTAssertEqual(editor.string, "committed")
    }

    func testScopeReopensCachedFieldAfterHiddenFieldEditorQueryWithoutViewRender() throws {
        let state = State()
        let scope = NativeSessionInputScope()
        let (host, window) = mount(Controls(state: state).environment(\.nativeSessionInputScope, scope))
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(protectedFields(host).first { $0 is NativeSessionTextControl })
        XCTAssertTrue(window.makeFirstResponder(field))
        scope.setActive(false)
        settle(host)
        XCTAssertFalse(field.isEditable)
        // AppKit may ask for a field editor during restoration while the owner is hidden.
        _ = window.fieldEditor(true, for: field)
        let rule = try XCTUnwrap((field as? NativeSessionTextControl)?.inputRule)
        XCTAssertTrue(rule.requestedActive, "Effective scoped inactivity must not overwrite the local visibility intent")
        scope.setActive(true)
        settle(host)
        XCTAssertTrue(field.isEditable, "Only the shared scope changes; the SwiftUI root stays untouched")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NativeSessionTextView)
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(" restored", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertTrue(state.field.contains(" restored"))
    }

    func testOwnerChangeReplacesNativeClientEvenWhenBothDraftsAreEqual() throws {
        let owners = Owners()
        let (host, window) = mount(OwnedField(owners: owners))
        defer { window.contentView = nil; window.close() }
        let first = try XCTUnwrap(protectedFields(host).first)
        XCTAssertTrue(window.makeFirstResponder(first))
        let oldClient = try XCTUnwrap(first.currentEditor() as? NativeSessionTextView)
        oldClient.setMarkedText("wrong owner composition", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(oldClient.hasMarkedText())
        owners.selected = "second"
        settle(host)
        let second = try XCTUnwrap(protectedFields(host).first)
        XCTAssertFalse(first === second, "The wrapper keys the actual native control to its owner scope")
        XCTAssertTrue(window.makeFirstResponder(second))
        let current = try XCTUnwrap(second.currentEditor() as? NativeSessionTextView)
        XCTAssertFalse(oldClient === current)
        XCTAssertFalse(oldClient.hasMarkedText())
        oldClient.insertText("wrong former owner", replacementRange: NSRange(location: NSNotFound, length: 0))
        oldClient.unmarkText()
        XCTAssertEqual(owners.first, "same committed draft")
        XCTAssertEqual(owners.second, "same committed draft")
        XCTAssertEqual(current.string, "same committed draft")
    }

    func testRebindingRuleIgnoresFormerScopeCallbacksAndInvalidatesEpoch() {
        let previous = NativeSessionInputScope()
        let next = NativeSessionInputScope()
        let rule = NativeSessionInputRule()
        var deactivations = 0
        var deferredChanges = 0
        rule.onScopeWillDeactivate = { deactivations += 1 }
        rule.onScopeChanged = { deferredChanges += 1 }
        rule.bind(to: previous)
        let epoch = rule.epoch
        rule.bind(to: next)
        XCTAssertGreaterThan(rule.epoch, epoch)
        XCTAssertEqual(deactivations, 1)
        previous.setActive(false)
        rule.scopeWillDeactivate(previous)
        rule.scopeDidChange(previous)
        XCTAssertEqual(deactivations, 1)
        XCTAssertEqual(deferredChanges, 0)
        XCTAssertTrue(rule.acceptsFocus)
        next.setActive(false)
        XCTAssertEqual(deactivations, 2)
        let closedEpoch = rule.epoch
        rule.update(active: false, enabled: true)
        XCTAssertGreaterThan(rule.epoch, closedEpoch)
    }

    func testMainChatComposerReturnsWithKeyboardWithoutAManualClick() throws {
        let state = State()
        let (host, window) = mount(MainComposers(state: state))
        defer { window.contentView = nil; window.close() }
        let first = try XCTUnwrap(editableViews(host).first { $0.string == "Hoot own draft" })
        let second = try XCTUnwrap(editableViews(host).first { $0.string == "Second chat own draft" })
        XCTAssertTrue(window.firstResponder === first)
        state.firstSelected = false
        settle(host)
        XCTAssertTrue(window.firstResponder === second)
        first.insertText("wrong hidden chat", replacementRange: NSRange(location: NSNotFound, length: 0))
        second.insertText(" accepted", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(host)
        XCTAssertEqual(state.hoot.text, "Hoot own draft")
        XCTAssertTrue(state.secondHoot.text.contains(" accepted"))
        state.firstSelected = true
        settle(host)
        XCTAssertTrue(window.firstResponder === first)
        XCTAssertTrue(first.allowsUserInput)
    }

    func testSplitChatSelectionMovesKeyboardWhileBothComposersRemainVisible() throws {
        let state = State()
        state.bothVisible = true
        let (host, window) = mount(MainComposers(state: state))
        defer { window.contentView = nil; window.close() }
        let first = try XCTUnwrap(editableViews(host).first { $0.string == "Hoot own draft" })
        let second = try XCTUnwrap(editableViews(host).first { $0.string == "Second chat own draft" })
        XCTAssertTrue(window.firstResponder === first)
        state.firstSelected = false
        settle(host)
        XCTAssertTrue(window.firstResponder === second)
        XCTAssertTrue(first.isEditable)
        first.insertText("unfocused old client", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(state.hoot.text, "Hoot own draft")
        state.firstSelected = true
        settle(host)
        XCTAssertTrue(window.firstResponder === first)
    }

    func testMainChatFocusNeverTakesKeyboardFromAnotherFieldOrWindow() throws {
        let state = State()
        let (host, window) = mount(MainComposers(state: state, includeOtherField: true))
        defer { window.contentView = nil; window.close() }
        let field = try XCTUnwrap(protectedFields(host).first { $0 is NativeSessionTextControl })
        XCTAssertTrue(window.makeFirstResponder(field))
        let client = try XCTUnwrap(field.currentEditor())
        state.firstSelected = false
        settle(host)
        XCTAssertTrue(window.firstResponder === client)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(window.firstResponder === client)
        window.keyboardActive = false
        XCTAssertTrue(window.makeFirstResponder(nil))
        state.firstSelected = true
        settle(host)
        XCTAssertFalse(window.firstResponder is HootComposerTextView)
        window.keyboardActive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue((window.firstResponder as? HootComposerTextView)?.string == "Hoot own draft")
    }

    func testMainChatFocusWaitsForTheCoveringSheetToClose() throws {
        let state = State()
        let (host, window) = mount(MainComposers(state: state))
        let sheet = ScratchWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.coveringSheet = nil; window.contentView = nil; window.close(); sheet.close() }
        window.coveringSheet = sheet
        XCTAssertTrue(window.makeFirstResponder(nil))
        state.firstSelected = false
        settle(host)
        XCTAssertFalse(window.firstResponder is HootComposerTextView)
        window.coveringSheet = nil
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        XCTAssertTrue((window.firstResponder as? HootComposerTextView)?.string == "Second chat own draft")
    }

    func testRuntimeWalkFindsTheSharedRuleOnActualSessionTextEntryControls() throws {
        let state = State()
        let request = try formRequest()
        let content = VStack {
            Controls(state: state)
            Form(state: state, request: request)
        }
        let (host, window) = mount(content, height: 1100)
        defer { window.contentView = nil; window.close() }
        let controls = descendants(host).filter { view in
            if let field = view as? NSTextField { return field.isEditable }
            if let editor = view as? NSTextView { return editor.isEditable }
            return false
        }
        XCTAssertGreaterThanOrEqual(controls.count, 6, "The runtime walk includes real Hoot, form, secure, plain and long editors")
        for control in controls {
            XCTAssertTrue(control is any NativeSessionInputProtected, "Unprotected session text entry: \(type(of: control))")
        }
    }
}
