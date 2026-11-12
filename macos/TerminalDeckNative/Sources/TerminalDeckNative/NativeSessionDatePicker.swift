import AppKit
import SwiftUI

/// The native date control shares the session editor rule and owner identity. Model
/// changes render while hidden; retained user clients cannot edit or keep the keyboard.
struct NativeSessionDatePicker: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private let title: String
    @Binding private var selection: Date
    private let components: DatePickerComponents
    private var lowerBound: Date?
    private var upperBound: Date?
    private var graphical = false

    init(_ title: String = "Pick a time", selection: Binding<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.title = title
        _selection = selection
        components = displayedComponents
    }

    init(_ title: String = "Pick a time", selection: Binding<Date>, in range: PartialRangeFrom<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
        lowerBound = range.lowerBound
    }

    init(_ title: String = "Pick a time", selection: Binding<Date>, in range: PartialRangeThrough<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
        upperBound = range.upperBound
    }

    init(_ title: String = "Pick a time", selection: Binding<Date>, in range: ClosedRange<Date>,
         displayedComponents: DatePickerComponents = [.date, .hourAndMinute]) {
        self.init(title, selection: selection, displayedComponents: displayedComponents)
        lowerBound = range.lowerBound
        upperBound = range.upperBound
    }

    func datePickerStyle<S: DatePickerStyle>(_ style: S) -> Self {
        var copy = self
        copy.graphical = style is GraphicalDatePickerStyle
        return copy
    }

    var body: some View {
        NativeSessionDatePickerContent(title: title, selection: $selection, components: components,
                                       lowerBound: lowerBound, upperBound: upperBound, graphical: graphical)
            .id(scope?.identity)
    }
}

private struct NativeSessionDatePickerContent: NSViewRepresentable {
    let title: String
    @Binding var selection: Date
    let components: DatePickerComponents
    let lowerBound: Date?
    let upperBound: Date?
    let graphical: Bool
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NativeSessionDateControl {
        let picker = NativeSessionDateControl(frame: .zero)
        picker.datePickerMode = .single
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        updateNSView(picker, context: context)
        return picker
    }

    func updateNSView(_ picker: NativeSessionDateControl, context: Context) {
        context.coordinator.parent = self
        picker.inputRule.bind(to: scope)
        picker.updateInput(active: scope == nil ? active : true, enabled: enabled)
        picker.inputRule.withExplicitUpdate {
            picker.datePickerStyle = graphical ? .clockAndCalendar : .textFieldAndStepper
            var elements = picker.datePickerElements
            elements = []
            if components.contains(.date) { elements.formUnion(.yearMonthDay) }
            if components.contains(.hourAndMinute) { elements.formUnion(.hourMinute) }
            picker.datePickerElements = elements
            picker.minDate = lowerBound
            picker.maxDate = upperBound
            picker.dateValue = selection
            picker.setAccessibilityLabel(title)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: NativeSessionDatePickerContent
        init(_ parent: NativeSessionDatePickerContent) { self.parent = parent }
        @objc func changed(_ sender: NativeSessionDateControl) {
            guard sender.acceptsDateInput,
                  parent.lowerBound.map({ sender.dateValue >= $0 }) != false,
                  parent.upperBound.map({ sender.dateValue <= $0 }) != false else { return }
            parent.selection = sender.dateValue
        }
    }
}

final class NativeSessionDateControl: NSDatePicker, NativeSessionInputProtected {
    let inputRule = NativeSessionInputRule()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inputRule.owner = self
    }
    required init?(coder: NSCoder) { nil }

    var acceptsDateInput: Bool {
        guard inputRule.acceptsFocus, let window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil || NSApp.modalWindow === window else { return false }
        let ownsFieldEditor = currentEditor().map { window.firstResponder === $0 } ?? false
        if window.firstResponder === self || ownsFieldEditor { return true }
        return (window.firstResponder as? NSView)?.isDescendant(of: self) == true
    }

    override var acceptsFirstResponder: Bool { inputRule.acceptsFocus && super.acceptsFirstResponder }
    override var dateValue: Date {
        get { super.dateValue }
        set {
            guard inputRule.isExplicitUpdate || acceptsDateInput else { return }
            if !inputRule.isExplicitUpdate {
                guard minDate.map({ newValue >= $0 }) != false, maxDate.map({ newValue <= $0 }) != false else { return }
            }
            super.dateValue = newValue
        }
    }

    func updateInput(active: Bool, enabled: Bool) {
        inputRule.onScopeWillDeactivate = { [weak self] in
            guard let self else { return }
            (self.currentEditor() as? NSTextView)?.inputContext?.discardMarkedText()
            // NSDatePicker owns a private text client, rather than a SwiftUI focus
            // binding. Release it now so the incoming session sees no stale client.
            self.releaseKeyboard()
        }
        inputRule.onScopeChanged = { [weak self] in
            guard let self else { return }
            self.updateInput(active: self.inputRule.requestedActive, enabled: self.inputRule.enabled)
        }
        inputRule.update(active: active, enabled: enabled)
        isEnabled = inputRule.acceptsFocus
        if !inputRule.acceptsFocus { releaseKeyboard() }
    }

    private func releaseKeyboard() {
        guard let window else { return }
        let ownsFieldEditor = currentEditor().map { window.firstResponder === $0 } ?? false
        if window.firstResponder === self || ownsFieldEditor
            || (window.firstResponder as? NSView)?.isDescendant(of: self) == true {
            window.makeFirstResponder(nil)
        }
        abortEditing()
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard acceptsDateInput else { return }
        super.setAccessibilityValue(accessibilityValue)
    }

    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard acceptsDateInput else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
}
