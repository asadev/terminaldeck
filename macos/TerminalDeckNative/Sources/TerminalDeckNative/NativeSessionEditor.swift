import AppKit
import CoreText
import SwiftUI

/// All session editors use the same distinction: UI input needs the visible screen and its
/// actual keyboard owner; a model/tool update is an explicit operation and needs neither.
@MainActor
final class NativeSessionInputRule {
    private var viewActive = true
    private(set) var enabled = true
    private var scope: NativeSessionInputScope?
    var onScopeChanged: (() -> Void)?
    var onScopeWillDeactivate: (() -> Void)?
    private(set) var epoch: UInt64 = 0
    private var changingOwner = false
    var active: Bool { !changingOwner && viewActive && scope?.active != false }
    var requestedActive: Bool { viewActive }
    var hasScope: Bool { scope != nil }
    private var explicitDepth = 0
    weak var owner: NSView?

    var acceptsFocus: Bool { active && enabled }
    var isExplicitUpdate: Bool { explicitDepth > 0 }

    func update(active: Bool, enabled: Bool) {
        let locallyClosing = viewActive && self.enabled && (!active || !enabled)
        viewActive = active
        self.enabled = enabled
        if locallyClosing {
            epoch &+= 1
            onScopeWillDeactivate?()
        }
    }

    func bind(to scope: NativeSessionInputScope?) {
        guard self.scope !== scope else { return }
        let previous = self.scope
        previous?.unregister(self)
        if previous != nil {
            // A control retained across an owner update must not carry marked text or undo
            // into that owner. Public wrappers additionally recreate the native control.
            changingOwner = true
            epoch &+= 1
            onScopeWillDeactivate?()
            owner?.undoManager?.removeAllActions()
        }
        self.scope = scope
        changingOwner = false
        scope?.register(self)
    }

    func scopeWillDeactivate(_ source: NativeSessionInputScope) {
        guard scope === source else { return }
        epoch &+= 1
        onScopeWillDeactivate?()
    }

    func scopeDidChange(_ source: NativeSessionInputScope) {
        guard scope === source else { return }
        onScopeChanged?()
    }

    func allowsUserInput(in view: NSView) -> Bool {
        guard acceptsFocus, !view.isHiddenOrHasHiddenAncestor,
              let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window else { return false }
        if let control = owner as? NSControl {
            guard !control.isHiddenOrHasHiddenAncestor,
                  let editor = control.currentEditor() else { return false }
            return window.firstResponder === editor && (view === control || view === editor)
        }
        return window.firstResponder === view
    }

    @discardableResult
    func withExplicitUpdate<T>(_ body: () throws -> T) rethrows -> T {
        explicitDepth += 1
        defer { explicitDepth -= 1 }
        return try body()
    }
}

@MainActor
protocol NativeSessionInputProtected: AnyObject {
    var inputRule: NativeSessionInputRule { get }
}

/// A secure field keeps AppKit's native text client. Its field delegate still
/// identifies the live owner when another screen needs to reclaim the keyboard.
@MainActor
func nativeSessionInputRule(for responder: NSResponder?) -> NativeSessionInputRule? {
    if let editor = responder as? NSTextView,
       let owner = editor.delegate as? NativeSessionSecureControl {
        return owner.inputRule
    }
    var view = responder as? NSView
    while let current = view {
        if let protected = current as? any NativeSessionInputProtected { return protected.inputRule }
        view = current.superview
    }
    return nil
}

/// The app owns this editor (including each ordinary text field's field editor), so a
/// retained input-method, Services or accessibility target cannot bypass the screen rule.
class NativeSessionTextView: NSTextView, NativeSessionInputProtected {
    var inputRule = NativeSessionInputRule()
    private var compositionSnapshot: NSAttributedString?
    private var compositionSelection = NSRange(location: 0, length: 0)
    private var discardingComposition = false
    var onWindowAttachment: (() -> Void)?
    var onInputAvailabilityChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachment?()
    }

    var allowsUserInput: Bool { inputRule.allowsUserInput(in: self) }
    func isComposing(over value: String) -> Bool { hasMarkedText() && compositionSnapshot?.string == value }
    private var allowsMutation: Bool { inputRule.isExplicitUpdate || allowsUserInput }

    override var acceptsFirstResponder: Bool { inputRule.acceptsFocus && super.acceptsFirstResponder }

    func updateInput(active: Bool, enabled: Bool) {
        if !(inputRule.owner is NSControl) {
            inputRule.onScopeWillDeactivate = { [weak self] in self?.discardComposition() }
            inputRule.onScopeChanged = { [weak self] in
                guard let self else { return }
                self.updateInput(active: self.inputRule.requestedActive, enabled: self.inputRule.enabled)
            }
        }
        inputRule.update(active: active, enabled: enabled)
        if !inputRule.acceptsFocus {
            discardComposition()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        isEditable = inputRule.acceptsFocus
        onInputAvailabilityChanged?()
    }

    /// Explicit binding updates replace any in-flight composition, including when hidden.
    func applyModelText(_ value: String) {
        guard string != value else { return }
        // A render of the last committed binding must not interrupt live composition.
        if hasMarkedText(), compositionSnapshot?.string == value { return }
        discardComposition()
        inputRule.withExplicitUpdate {
            let caret = min(selectedRange().location, (value as NSString).length)
            string = value
            setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    func discardComposition() {
        guard !discardingComposition, hasMarkedText() || compositionSnapshot != nil else { return }
        let savedComposition = compositionSnapshot
        let savedSelection = compositionSelection
        discardingComposition = true
        defer { discardingComposition = false }
        inputRule.withExplicitUpdate {
            inputContext?.discardMarkedText()
            super.unmarkText()
            if let snapshot = savedComposition {
                textStorage?.setAttributedString(snapshot)
                let end = snapshot.length
                setSelectedRange(NSRange(location: min(savedSelection.location, end), length: 0))
            }
            compositionSnapshot = nil
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        allowsMutation && super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        allowsMutation && super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    override func keyDown(with event: NSEvent) {
        guard allowsUserInput else { return }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        guard allowsMutation else { return }
        super.doCommand(by: selector)
    }

    override func insertText(_ insertString: Any) {
        guard allowsMutation else { return }
        super.insertText(insertString)
        compositionSnapshot = nil
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard allowsMutation else { return }
        super.insertText(insertString, replacementRange: replacementRange)
        compositionSnapshot = nil
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard allowsMutation else { return }
        if compositionSnapshot == nil {
            // NSTextView returns its live text storage here; keep a copy, or the "before"
            // state would already contain the marked text and discarding would commit it.
            compositionSnapshot = NSAttributedString(attributedString: attributedString())
            compositionSelection = self.selectedRange()
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        guard allowsMutation else { discardComposition(); return }
        let didCompose = compositionSnapshot != nil
        super.unmarkText()
        compositionSnapshot = nil
        if didCompose && !discardingComposition { didChangeText() }
    }

    override func paste(_ sender: Any?) {
        guard allowsUserInput else { return }
        super.paste(sender)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        allowsUserInput && super.readSelection(from: pboard)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        allowsUserInput && super.readSelection(from: pboard, type: type)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        allowsUserInput ? super.draggingEntered(sender) : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        allowsUserInput ? super.draggingUpdated(sender) : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        allowsUserInput && super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        allowsUserInput && super.performDragOperation(sender)
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard allowsUserInput else { return }
        super.setAccessibilityValue(accessibilityValue)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard allowsUserInput else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

private final class NativeSessionTextFieldCell: NSTextFieldCell {
    let guardedEditor = NativeSessionTextView()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let control = controlView as? NativeSessionTextControl else { return nil }
        guardedEditor.inputRule = control.inputRule
        guardedEditor.isFieldEditor = true
        guardedEditor.isRichText = false
        guardedEditor.updateInput(active: control.inputRule.requestedActive, enabled: control.inputRule.enabled)
        return guardedEditor
    }
}

final class NativeSessionTextControl: NSTextField, NativeSessionInputProtected {
    let inputRule = NativeSessionInputRule()
    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachment?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = NativeSessionTextFieldCell(textCell: "")
        inputRule.owner = self
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { inputRule.acceptsFocus && super.acceptsFirstResponder }

    // Only code can focus a field behind a sheet (the sheet takes every click and key).
    // SwiftUI's focus state would otherwise place it there at once; the coordinator
    // keeps the request and fulfils it when the sheet ends.
    override func becomeFirstResponder() -> Bool {
        nativeSessionFieldBecomeFirstResponder(self) { super.becomeFirstResponder() }
    }

    func updateInput(active: Bool, enabled: Bool) {
        inputRule.onScopeWillDeactivate = { [weak self] in
            (self?.cell as? NativeSessionTextFieldCell)?.guardedEditor.discardComposition()
        }
        inputRule.onScopeChanged = { [weak self] in
            guard let self else { return }
            self.updateInput(active: self.inputRule.requestedActive, enabled: self.inputRule.enabled)
        }
        inputRule.update(active: active, enabled: enabled)
        (cell as? NativeSessionTextFieldCell)?.guardedEditor.updateInput(active: active, enabled: enabled)
        isEditable = inputRule.acceptsFocus
        isEnabled = enabled
        if !inputRule.acceptsFocus {
            abortEditing()
            (delegate as? NativeSessionFieldCoordinator)?.inputClosed()
        }
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard inputRule.allowsUserInput(in: self) else { return }
        super.setAccessibilityValue(accessibilityValue)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard inputRule.allowsUserInput(in: self) else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

/// AppKit normally shares its secure editor within a window. Give each secret answer its
/// own native secure editor so an old input-method target can never become another answer.
/// The factory window is never ordered, activated or used for editing.
private final class NativeSessionSecureTextFieldCell: NSSecureTextFieldCell {
    private var factoryWindow: NSWindow?
    private(set) var ownedEditor: NSTextView?

    isolated deinit { factoryWindow?.close() }

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let control = controlView as? NativeSessionSecureControl else { return nil }
        if ownedEditor == nil {
            let factory = NSWindow(contentRect: NSRect(x: -32000, y: -32000, width: 1, height: 1),
                                   styleMask: [], backing: .buffered, defer: false)
            factory.isReleasedWhenClosed = false
            factory.isExcludedFromWindowsMenu = true
            let source = NSSecureTextField(frame: .zero)
            factory.contentView = source
            if let editor = factory.fieldEditor(true, for: source) {
                ownedEditor = source.cell?.setUpFieldEditorAttributes(editor) as? NSTextView
                ownedEditor?.isFieldEditor = true
            }
            factoryWindow = factory
        }
        guard let ownedEditor else {
            // A failed native editor allocation must not fall back to a shared password box.
            control.isEditable = false
            return nil
        }
        control.protect(ownedEditor)
        return ownedEditor
    }
}

/// Keep AppKit's secure field editor: replacing it with a plain NSTextView would expose
/// passwords. Hiding aborts that private editor, and the delegate rejects its late commits.
final class NativeSessionSecureControl: NSSecureTextField, NativeSessionInputProtected, NSTextViewDelegate {
    let inputRule = NativeSessionInputRule()
    private var acceptedText = ""
    private var reverting = false

    func acceptModelText(_ value: String) { acceptedText = value }
    func isComposing(over value: String) -> Bool {
        (currentEditor() as? NSTextView)?.hasMarkedText() == true && acceptedText == value
    }

    func protect(_ editor: NSTextView) {
        editor.isEditable = inputRule.acceptsFocus
        // AppKit's secure editor requires its NSTextField owner as delegate. A generic
        // forwarding NSObject is rejected, even before editing begins during layout.
        if editor.delegate !== self { editor.delegate = self }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        inputRule.allowsUserInput(in: self)
    }

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        inputRule.allowsUserInput(in: self)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard inputRule.allowsUserInput(in: self) else { return true }
        return delegate?.control?(self, textView: textView, doCommandBy: selector) ?? false
    }

    override func textDidChange(_ notification: Notification) {
        guard !reverting, let editor = notification.object as? NSTextView else { return }
        guard inputRule.allowsUserInput(in: self) else {
            reverting = true
            editor.inputContext?.discardMarkedText()
            editor.unmarkText()
            inputRule.withExplicitUpdate { editor.string = acceptedText }
            reverting = false
            return
        }
        if !editor.hasMarkedText() {
            acceptedText = editor.string
            super.textDidChange(notification)
        }
    }

    private func discardOwnedComposition() {
        guard let editor = (cell as? NativeSessionSecureTextFieldCell)?.ownedEditor else { return }
        editor.inputContext?.discardMarkedText()
        editor.unmarkText()
        inputRule.withExplicitUpdate { editor.string = acceptedText }
    }

    var onWindowAttachment: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAttachment?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = NativeSessionSecureTextFieldCell(textCell: "")
        inputRule.owner = self
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { inputRule.acceptsFocus && super.acceptsFirstResponder }

    // Only code can focus a field behind a sheet (the sheet takes every click and key).
    // SwiftUI's focus state would otherwise place it there at once; the coordinator
    // keeps the request and fulfils it when the sheet ends.
    override func becomeFirstResponder() -> Bool {
        nativeSessionFieldBecomeFirstResponder(self) { super.becomeFirstResponder() }
    }

    func updateInput(active: Bool, enabled: Bool) {
        inputRule.onScopeWillDeactivate = { [weak self] in self?.discardOwnedComposition() }
        inputRule.onScopeChanged = { [weak self] in
            guard let self else { return }
            self.updateInput(active: self.inputRule.requestedActive, enabled: self.inputRule.enabled)
        }
        inputRule.update(active: active, enabled: enabled)
        let ownedEditor = (cell as? NativeSessionSecureTextFieldCell)?.ownedEditor
        if !inputRule.acceptsFocus {
            if let editor = ownedEditor {
                editor.inputContext?.discardMarkedText()
                editor.unmarkText()
                editor.isEditable = false
                if window?.firstResponder === editor { window?.makeFirstResponder(nil) }
            }
            abortEditing()
            (delegate as? NativeSessionFieldCoordinator)?.inputClosed()
            // abortEditing may remove AppKit's delegate. Keep our released client guarded,
            // including late callbacks that retain this exact editor after switching screens.
            if let editor = ownedEditor {
                protect(editor)
                inputRule.withExplicitUpdate { editor.string = acceptedText }
            }
        } else if let editor = ownedEditor {
            protect(editor)
        }
        isEditable = inputRule.acceptsFocus
        isEnabled = enabled
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard inputRule.allowsUserInput(in: self) else { return }
        super.setAccessibilityValue(accessibilityValue)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard inputRule.allowsUserInput(in: self) else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}

/// The newest field that asked for focus while its window had a sheet. Only that request
/// may be fulfilled when the sheet ends; an older one was replaced, not postponed.
@MainActor private let nativeSessionDeferredFocus = NSMapTable<NSWindow, NSView>.weakToWeakObjects()

/// The field whose deferred request is still open in this window (read by checks only).
@MainActor func nativeSessionDeferredFocusField(in window: NSWindow) -> NSView? {
    nativeSessionDeferredFocus.object(forKey: window)
}

@MainActor
private func nativeSessionFieldBecomeFirstResponder(_ field: NSTextField, become: () -> Bool) -> Bool {
    guard let window = field.window else { return become() }
    guard window.attachedSheet == nil else {
        nativeSessionDeferredFocus.setObject(field, forKey: window)
        (field.delegate as? NativeSessionFieldCoordinator)?.deferFocus(field)
        return false
    }
    let became = become()
    if became { nativeSessionDeferredFocus.removeObject(forKey: window) }
    return became
}

/// Changing the session owner replaces the actual input client, not just its binding.
struct NativeSessionTextField: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private var content: NativeSessionTextFieldContent
    private let prompt: Text?

    init(_ title: String, text: Binding<String>, selection: Binding<TextSelection?>? = nil,
         axis: Axis = .horizontal, prompt: Text? = nil, onSubmit: (() -> Void)? = nil) {
        content = NativeSessionTextFieldContent(title, text: text, selection: selection, axis: axis, onSubmit: onSubmit)
        content.suppressPlaceholder = prompt != nil
        self.prompt = prompt
    }

    var body: some View {
        content.id(scope?.identity).modifier(NativeSessionDeclaredFocus(binding: content.focus)).overlay(alignment: .leading) {
            if content.text.isEmpty, let prompt {
                prompt.foregroundStyle(.tertiary).padding(.horizontal, 3)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.content = content.sessionFocused(focus)
        return copy
    }
    func onSubmit(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.content = content.onSubmit(action)
        return copy
    }
    func onExitCommand(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.content = content.onExitCommand(action)
        return copy
    }
    func lineLimit(_ lines: ClosedRange<Int>) -> Self {
        var copy = self
        copy.content = content.lineLimit(lines)
        return copy
    }
    func lineLimit(_ lines: Int?) -> Self {
        var copy = self
        copy.content = content.lineLimit(lines)
        return copy
    }
    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> Self {
        var copy = self
        copy.content = content.textFieldStyle(style)
        return copy
    }
}

/// Changing the session owner replaces the actual input client, not just its binding.
struct NativeSessionSecureField: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private var content: NativeSessionSecureFieldContent
    private let prompt: Text?

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal, prompt: Text? = nil, onSubmit: (() -> Void)? = nil) {
        content = NativeSessionSecureFieldContent(title, text: text, axis: axis, onSubmit: onSubmit)
        content.suppressPlaceholder = prompt != nil
        self.prompt = prompt
    }

    var body: some View {
        content.id(scope?.identity).modifier(NativeSessionDeclaredFocus(binding: content.focus)).overlay(alignment: .leading) {
            if content.text.isEmpty, let prompt {
                prompt.foregroundStyle(.tertiary).padding(.horizontal, 3)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.content = content.sessionFocused(focus)
        return copy
    }
    func onSubmit(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.content = content.onSubmit(action)
        return copy
    }
    func onExitCommand(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.content = content.onExitCommand(action)
        return copy
    }
    func lineLimit(_ lines: ClosedRange<Int>) -> Self {
        var copy = self
        copy.content = content.lineLimit(lines)
        return copy
    }
    func lineLimit(_ lines: Int?) -> Self {
        var copy = self
        copy.content = content.lineLimit(lines)
        return copy
    }
    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> Self {
        var copy = self
        copy.content = content.textFieldStyle(style)
        return copy
    }
}

struct NativeSessionTextEditor: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private var content: NativeSessionTextEditorContent

    init(text: Binding<String>) { content = NativeSessionTextEditorContent(text: text) }
    var body: some View { content.id(scope?.identity).modifier(NativeSessionDeclaredFocus(binding: content.focus)) }
    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.content = content.sessionFocused(focus)
        return copy
    }
}

private struct NativeSessionTextFieldContent: NSViewRepresentable {
    @Environment(\.nativeSessionEditorFocus) private var environmentFocus
    @Environment(\.nativeSessionEditorSubmit) private var environmentSubmit
    @Environment(\.nativeSessionEditorExit) private var environmentExit
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.layoutDirection) private var layoutDirection
    let title: String
    @Binding var text: String
    var selection: Binding<TextSelection?>?
    let axis: Axis
    var submit: (() -> Void)?
    var exit: (() -> Void)?
    var maximumLines: Int?
    var minimumLines = 1
    var rounded = false
    var suppressPlaceholder = false
    var focus: FocusState<Bool>.Binding?

    init(_ title: String, text: Binding<String>, selection: Binding<TextSelection?>? = nil,
         axis: Axis = .horizontal, onSubmit: (() -> Void)? = nil) {
        self.title = title
        _text = text
        self.selection = selection
        self.axis = axis
        submit = onSubmit
    }

    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.focus = focus
        return copy
    }

    func onSubmit(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.submit = action
        return copy
    }

    func onExitCommand(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.exit = action
        return copy
    }

    func lineLimit(_ lines: ClosedRange<Int>) -> Self {
        var copy = self
        copy.minimumLines = lines.lowerBound
        copy.maximumLines = lines.upperBound
        return copy
    }

    func lineLimit(_ lines: Int?) -> Self {
        var copy = self
        copy.maximumLines = lines
        return copy
    }

    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> Self {
        var copy = self
        copy.rounded = style is RoundedBorderTextFieldStyle
        return copy
    }

    func makeCoordinator() -> NativeSessionFieldCoordinator { NativeSessionFieldCoordinator() }
    func makeNSView(context: Context) -> NativeSessionTextControl {
        let field = NativeSessionTextControl(frame: .zero)
        configureSessionField(field, title: title, axis: axis)
        field.delegate = context.coordinator
        field.onWindowAttachment = { [weak field, weak coordinator = context.coordinator] in
            guard let field, let coordinator else { return }
            coordinator.fulfilFocus(field)
        }
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NativeSessionTextControl, context: Context) {
        field.inputRule.bind(to: scope)
        field.placeholderString = suppressPlaceholder ? nil : title
        context.coordinator.multiline = axis == .vertical
        context.coordinator.update(field, binding: $text, active: scope == nil ? active : true, enabled: enabled,
                                   focus: focus.map(NativeSessionFocusBinding.init) ?? environmentFocus?.binding,
                                   submit: submit ?? environmentSubmit?.run,
                                   exit: exit ?? environmentExit?.run, selection: selection)
        field.font = sessionNativeFont(font, context: fontContext)
        field.alignment = sessionNativeAlignment(alignment, direction: layoutDirection)
        if let editor = field.currentEditor() { editor.font = field.font; editor.alignment = field.alignment }
        field.isBordered = rounded
        field.bezelStyle = .roundedBezel
        field.drawsBackground = rounded
        if axis == .vertical { field.maximumNumberOfLines = maximumLines ?? 0 }
        field.updateInput(active: scope == nil ? active : true, enabled: enabled)
        context.coordinator.renderAndFocus(field, value: text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeSessionTextControl, context: Context) -> CGSize? {
        sessionFieldSize(proposal, field: nsView, axis: axis, minimumLines: minimumLines, maximumLines: maximumLines)
    }
}

private struct NativeSessionSecureFieldContent: NSViewRepresentable {
    @Environment(\.nativeSessionEditorFocus) private var environmentFocus
    @Environment(\.nativeSessionEditorSubmit) private var environmentSubmit
    @Environment(\.nativeSessionEditorExit) private var environmentExit
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.layoutDirection) private var layoutDirection
    let title: String
    @Binding var text: String
    let axis: Axis
    var submit: (() -> Void)?
    var exit: (() -> Void)?
    var maximumLines: Int?
    var minimumLines = 1
    var rounded = false
    var suppressPlaceholder = false
    var focus: FocusState<Bool>.Binding?

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal, onSubmit: (() -> Void)? = nil) {
        self.title = title
        _text = text
        self.axis = axis
        submit = onSubmit
    }

    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.focus = focus
        return copy
    }

    func onSubmit(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.submit = action
        return copy
    }

    func onExitCommand(_ action: @escaping () -> Void) -> Self {
        var copy = self
        copy.exit = action
        return copy
    }

    func lineLimit(_ lines: ClosedRange<Int>) -> Self {
        var copy = self
        copy.minimumLines = lines.lowerBound
        copy.maximumLines = lines.upperBound
        return copy
    }

    func lineLimit(_ lines: Int?) -> Self {
        var copy = self
        copy.maximumLines = lines
        return copy
    }

    func textFieldStyle<S: TextFieldStyle>(_ style: S) -> Self {
        var copy = self
        copy.rounded = style is RoundedBorderTextFieldStyle
        return copy
    }

    func makeCoordinator() -> NativeSessionFieldCoordinator { NativeSessionFieldCoordinator() }
    func makeNSView(context: Context) -> NativeSessionSecureControl {
        let field = NativeSessionSecureControl(frame: .zero)
        configureSessionField(field, title: title, axis: axis)
        field.delegate = context.coordinator
        field.onWindowAttachment = { [weak field, weak coordinator = context.coordinator] in
            guard let field, let coordinator else { return }
            coordinator.fulfilFocus(field)
        }
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: NativeSessionSecureControl, context: Context) {
        field.inputRule.bind(to: scope)
        field.placeholderString = suppressPlaceholder ? nil : title
        context.coordinator.multiline = axis == .vertical
        context.coordinator.update(field, binding: $text, active: scope == nil ? active : true, enabled: enabled,
                                   focus: focus.map(NativeSessionFocusBinding.init) ?? environmentFocus?.binding,
                                   submit: submit ?? environmentSubmit?.run,
                                   exit: exit ?? environmentExit?.run)
        field.font = sessionNativeFont(font, context: fontContext)
        field.alignment = sessionNativeAlignment(alignment, direction: layoutDirection)
        if let editor = field.currentEditor() { editor.font = field.font; editor.alignment = field.alignment }
        field.isBordered = rounded
        field.bezelStyle = .roundedBezel
        field.drawsBackground = rounded
        if axis == .vertical { field.maximumNumberOfLines = maximumLines ?? 0 }
        field.updateInput(active: scope == nil ? active : true, enabled: enabled)
        context.coordinator.renderAndFocus(field, value: text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeSessionSecureControl, context: Context) -> CGSize? {
        sessionFieldSize(proposal, field: nsView, axis: axis, minimumLines: minimumLines, maximumLines: maximumLines)
    }
}

@MainActor
private func sessionNativeFont(_ font: Font?, context: Font.Context) -> NSFont {
    let resolved = (font ?? .body).resolve(in: context)
    let name = CTFontCopyPostScriptName(resolved.ctFont) as String
    if let font = NSFont(name: name, size: resolved.pointSize) { return font }
    let weight: NSFont.Weight = resolved.isBold ? .bold : .regular
    let fallback = resolved.isMonospaced
        ? NSFont.monospacedSystemFont(ofSize: resolved.pointSize, weight: weight)
        : NSFont.systemFont(ofSize: resolved.pointSize, weight: weight)
    return resolved.isItalic ? NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask) : fallback
}

private func sessionNativeAlignment(_ alignment: TextAlignment, direction: LayoutDirection) -> NSTextAlignment {
    switch alignment {
    case .center: return .center
    case .trailing: return direction == .rightToLeft ? .left : .right
    default: return direction == .rightToLeft ? .right : .left
    }
}

@MainActor
private func configureSessionField(_ field: NSTextField, title: String, axis: Axis) {
    field.placeholderString = title
    field.setAccessibilityLabel(title)
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .default
    field.lineBreakMode = axis == .vertical ? .byWordWrapping : .byClipping
    field.maximumNumberOfLines = axis == .vertical ? 0 : 1
    field.cell?.wraps = axis == .vertical
    field.cell?.isScrollable = axis != .vertical
    field.cell?.usesSingleLineMode = axis == .horizontal
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
}

@MainActor
private func sessionFieldSize(_ proposal: ProposedViewSize, field: NSTextField, axis: Axis, minimumLines: Int, maximumLines: Int?) -> CGSize {
    let width = proposal.width ?? max(120, field.intrinsicContentSize.width)
    guard axis == .vertical, let cell = field.cell else {
        return CGSize(width: width, height: max(22, field.intrinsicContentSize.height))
    }
    let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude))
    let lineHeight = ceil((field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height)
    let minimumHeight = max(22, lineHeight * CGFloat(minimumLines) + 4)
    let maximumHeight = maximumLines.map { max(minimumHeight, lineHeight * CGFloat($0) + 4) } ?? .greatestFiniteMagnitude
    return CGSize(width: width, height: min(maximumHeight, max(minimumHeight, measured.height)))
}

@MainActor
final class NativeSessionFieldCoordinator: NSObject, NSTextFieldDelegate {
    var multiline = false
    private var binding: Binding<String>?
    private var rule: NativeSessionInputRule?
    private var focus: NativeSessionFocusBinding?
    private var submit: (() -> Void)?
    private var exit: (() -> Void)?
    private var updating = false
    private var wantsFocus = false
    private var deferred = false
    private var selection: Binding<TextSelection?>?
    private var appliedSelection: (text: String, range: NSRange)?
    private var renderFollowup: DispatchWorkItem?
    private var focusObservers: [NSObjectProtocol] = []
    private weak var pendingField: NSTextField?
    private weak var deferredWindow: NSWindow?

    /// A deferred request ends (fulfilled, replaced, withdrawn or closed): drop the window's
    /// record of it, or that record would cancel every later request from another field.
    private func endDeferral() {
        deferred = false
        if let window = deferredWindow, let field = pendingField,
           nativeSessionDeferredFocus.object(forKey: window) === field {
            nativeSessionDeferredFocus.removeObject(forKey: window)
        }
        deferredWindow = nil
    }

    isolated deinit {
        renderFollowup?.cancel()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// A field cannot take focus under a sheet or in a background window, so a pending
    /// request is fulfilled when that window's sheet ends or it becomes key again — the
    /// same events the chat composer and task editor already wait for.
    private func observeFocusEvents(for field: NSTextField) {
        pendingField = field
        guard focusObservers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let notifiedWindow = (note.object as? NSWindow).map(ObjectIdentifier.init)
                let notificationName = note.name
                MainActor.assumeIsolated {
                    guard let self, self.wantsFocus,
                          let field = self.pendingField as? NSTextField & NativeSessionInputProtected,
                          let window = field.window,
                          notifiedWindow == ObjectIdentifier(window) || notificationName == NSApplication.didBecomeActiveNotification else { return }
                    self.fulfilFocus(field)
                }
            })
        }
    }

    func update(_ field: NSTextField & NativeSessionInputProtected, binding: Binding<String>, active: Bool,
                enabled: Bool, focus: NativeSessionFocusBinding?, submit: (() -> Void)?, exit: (() -> Void)?,
                selection: Binding<TextSelection?>? = nil) {
        self.binding = binding
        rule = field.inputRule
        self.focus = focus
        self.submit = submit
        self.exit = exit
        self.selection = selection
        field.inputRule.update(active: active, enabled: enabled)
        // A hidden or disabled field gives up a request it deferred under a sheet.
        if deferred, !field.inputRule.acceptsFocus { wantsFocus = false; endDeferral() }
        refreshFocusRequest()
    }

    /// The field was hidden or disabled: a request it deferred under a sheet is given up.
    func inputClosed() {
        guard deferred else { return }
        wantsFocus = false
        endDeferral()
    }

    /// SwiftUI asked to focus this field while a sheet covered it. It drops its own focus
    /// value when the field refuses, so the request is kept here until the sheet ends.
    func deferFocus(_ field: NSTextField) {
        wantsFocus = true
        deferred = true
        observeFocusEvents(for: field)
        deferredWindow = field.window
    }

    /// The focus value requests focus. A request deferred under a sheet stays pending after
    /// SwiftUI drops its own value, until it is fulfilled or an enum focus names another field.
    private func refreshFocusRequest() {
        guard let focus else { wantsFocus = false; endDeferral(); return }
        if focus.wrappedValue { wantsFocus = true }
        else if focus.isHeldByOther { wantsFocus = false; endDeferral() }
        else if !deferred { wantsFocus = false }
    }

    func renderAndFocus(_ field: NSTextField & NativeSessionInputProtected, value: String) {
        updating = true
        defer { updating = false }
        let composing = (field.currentEditor() as? NativeSessionTextView)?.isComposing(over: value) == true
            || (field as? NativeSessionSecureControl)?.isComposing(over: value) == true
        if let secure = field as? NativeSessionSecureControl { secure.acceptModelText(value) }
        field.inputRule.withExplicitUpdate {
            if !composing, field.stringValue != value {
                (field.currentEditor() as? NativeSessionTextView)?.applyModelText(value)
                field.stringValue = value
            }
        }
        fulfilFocus(field)
        renderFollowup?.cancel()
        // AppKit can synchronize the field editor after its string/font/layout update.
        // Apply the requested completion selection to that settled editor, while a real
        // edit consumes the binding and cancels any stale completion.
        guard selection?.wrappedValue != nil || wantsFocus else { return }
        let task = DispatchWorkItem { [weak self, weak field] in
            MainActor.assumeIsolated {
                guard let self, let field, self.binding?.wrappedValue == value else { return }
                self.fulfilFocus(field)
            }
        }
        renderFollowup = task
        DispatchQueue.main.async(execute: task)
    }

    func fulfilFocus(_ field: NSTextField & NativeSessionInputProtected) {
        refreshFocusRequest()
        if wantsFocus { observeFocusEvents(for: field) }
        if deferred, !field.inputRule.acceptsFocus { wantsFocus = false; endDeferral() }
        guard field.inputRule.acceptsFocus, let window = field.window,
              window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window else { return }
        // Only a request deferred under a sheet can be replaced by a newer deferred one;
        // a fresh request made with no sheet is never cancelled by that record.
        if wantsFocus, deferred, let newest = nativeSessionDeferredFocus.object(forKey: window), newest !== field {
            wantsFocus = false   // a newer field asked for focus under the same sheet
            endDeferral()
        }
        if wantsFocus, field.currentEditor() == nil {
            // A request SwiftUI dropped while it waited must not take the keyboard from a
            // field the person chose meanwhile; that choice withdraws the request instead.
            if focus?.wrappedValue == true || !NativeKeyboardFocus.isTyping(window.firstResponder) {
                window.makeFirstResponder(field)
            } else {
                wantsFocus = false
                endDeferral()
            }
        }
        if let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor {
            wantsFocus = false
            endDeferral()
            applySelection(to: editor, value: field.stringValue)
        }
    }

    private func applySelection(to editor: NSTextView, value: String) {
        guard let selection = selection?.wrappedValue, !editor.hasMarkedText() else { return }
        // TextSelection indices belong to the binding's own Swift string (UTF-8). The field's
        // stringValue is a bridged UTF-16 copy whose indices do not compare with them, so an
        // emoji made the bounds check fail and the completion was never selected.
        guard let text = binding?.wrappedValue, text == value else { return }
        let range: Range<String.Index>?
        switch selection.indices {
        case .selection(let selected): range = selected
        case .multiSelection(let selected): range = selected.ranges.first
        @unknown default: range = nil
        }
        guard let range, range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return }
        let native = NSRange(range, in: text)
        guard appliedSelection?.text != value || appliedSelection?.range != native || editor.selectedRange() != native else { return }
        editor.setSelectedRange(native)
        appliedSelection = (value, native)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, rule?.allowsUserInput(in: field) == true else { return }
        if let secure = field as? NativeSessionSecureControl, let editor = field.currentEditor() as? NSTextView {
            secure.protect(editor)
        }
        focus?.wrappedValue = true
        if let editor = field.currentEditor() as? NSTextView { applySelection(to: editor, value: field.stringValue) }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !updating, let field = obj.object as? NSTextField,
              rule?.allowsUserInput(in: field) == true,
              (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        // Completion supplies a one-use selection. A later edit must not select
        // that old suffix again during an unrelated SwiftUI render.
        selection?.wrappedValue = nil
        appliedSelection = nil
        binding?.wrappedValue = field.stringValue
        field.invalidateIntrinsicContentSize()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Hiding is not a commit. The accepted binding already contains every real edit.
        // SwiftUI resigns the old field while it is still moving its focus value to the next
        // one, so clearing it here read the old value and cleared the new field's focus too:
        // no field kept the keyboard. Clear it only once focus has settled elsewhere.
        if let field = obj.object as? NSTextField {
            DispatchQueue.main.async { [weak self, weak field] in
                MainActor.assumeIsolated {
                    guard let self, let field, let focus = self.focus, focus.wrappedValue,
                          field.currentEditor() == nil else { return }
                    focus.wrappedValue = false
                }
            }
        }
        wantsFocus = false
        endDeferral()
        guard let field = obj.object as? NSTextField, let binding else { return }
        if field.stringValue != binding.wrappedValue {
            rule?.withExplicitUpdate { field.stringValue = binding.wrappedValue }
        }
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        guard rule?.acceptsFocus == true, control.window?.isKeyWindow == true else { return false }
        if let secure = control as? NativeSessionSecureControl, let editor = fieldEditor as? NSTextView {
            secure.protect(editor)
        }
        return true
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool { true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard rule?.allowsUserInput(in: control) == true else { return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let exit {
            exit()
            return true
        }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
        if let submit { submit(); return true }
        if multiline {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        return false
    }
}

private struct NativeSessionTextEditorContent: NSViewRepresentable {
    @Environment(\.nativeSessionEditorFocus) private var environmentFocus
    @Environment(\.nativeSessionEditorSubmit) private var environmentSubmit
    @Environment(\.nativeSessionEditorExit) private var environmentExit
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var text: String
    var focus: FocusState<Bool>.Binding?
    private var effectiveFocus: NativeSessionFocusBinding? { focus.map(NativeSessionFocusBinding.init) ?? environmentFocus?.binding }

    init(text: Binding<String>) { _text = text }

    func sessionFocused(_ focus: FocusState<Bool>.Binding) -> Self {
        var copy = self
        copy.focus = focus
        return copy
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = NativeSessionTextView()
        editor.inputRule.owner = editor
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.onWindowAttachment = { [weak editor, weak coordinator = context.coordinator] in
            guard let editor, let coordinator else { return }
            coordinator.fulfilFocus(editor)
        }
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NativeSessionTextView else { return }
        context.coordinator.parent = self
        editor.font = sessionNativeFont(font, context: fontContext)
        editor.alignment = sessionNativeAlignment(alignment, direction: layoutDirection)
        editor.inputRule.bind(to: scope)
        editor.updateInput(active: scope == nil ? active : true, enabled: enabled)
        context.coordinator.updating = true
        editor.applyModelText(text)
        context.coordinator.updating = false
        context.coordinator.fulfilFocus(editor)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeSessionTextEditorContent
        var updating = false
        init(_ parent: NativeSessionTextEditorContent) { self.parent = parent }

        func fulfilFocus(_ editor: NativeSessionTextView) {
            guard parent.effectiveFocus?.wrappedValue == true, editor.inputRule.acceptsFocus,
                  let window = editor.window, window.isKeyWindow, window.attachedSheet == nil,
                  NSApp.modalWindow == nil || NSApp.modalWindow === window else { return }
            window.makeFirstResponder(editor)
        }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NativeSessionTextView,
                  editor.allowsUserInput, !editor.hasMarkedText() else { return }
            parent.text = editor.string
        }

        func textDidBeginEditing(_ notification: Notification) { parent.effectiveFocus?.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) {
            // As for one-line fields: SwiftUI resigns this box while it is still moving an
            // enum focus to the next field, so clearing now read the old value and cleared
            // the new field's request too (nothing kept the keyboard). Clear it on the next
            // turn, and only if this box no longer holds the keyboard.
            guard let editor = notification.object as? NSTextView else { return }
            DispatchQueue.main.async { [weak self, weak editor] in
                MainActor.assumeIsolated {
                    guard let self, let editor, let focus = self.parent.effectiveFocus, focus.wrappedValue,
                          editor.window?.firstResponder !== editor else { return }
                    focus.wrappedValue = false
                }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let editor = textView as? NativeSessionTextView, editor.allowsUserInput else { return true }
            if selector == #selector(NSResponder.cancelOperation(_:)), let exit = parent.environmentExit?.run {
                exit()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
               let submit = parent.environmentSubmit?.run {
                submit()
                return true
            }
            return false
        }
    }
}
