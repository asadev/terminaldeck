import Foundation
import SwiftUI

/// The existing numeric fields keep their locale-aware formatting and provisional
/// input (for example a minus sign), while using the same guarded native text client.
struct NativeSessionNumberField: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private let title: String
    private let prompt: Text?
    private let read: () -> String
    private let write: (String) -> Bool
    /// SP-2: drawn without the field's own bezel (the Settings kit's quiet field draws its fill).
    private var quiet = false
    func quietField() -> Self { var copy = self; copy.quiet = true; return copy }

    init(_ title: String, value: Binding<Int>, format: IntegerFormatStyle<Int> = .number, prompt: Text? = nil) {
        self.title = title
        self.prompt = prompt
        read = { format.format(value.wrappedValue) }
        write = { raw in
            guard let parsed = try? format.parseStrategy.parse(raw) else { return false }
            value.wrappedValue = parsed
            return true
        }
    }
    init(_ title: String, value: Binding<Int?>, format: IntegerFormatStyle<Int> = .number, prompt: Text? = nil) {
        self.title = title
        self.prompt = prompt
        read = { value.wrappedValue.map { format.format($0) } ?? "" }
        write = { raw in
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.wrappedValue = nil
                return true
            }
            guard let parsed = try? format.parseStrategy.parse(raw) else { return false }
            value.wrappedValue = parsed
            return true
        }
    }
    init(_ title: String, value: Binding<Double>, format: FloatingPointFormatStyle<Double> = .number, prompt: Text? = nil) {
        self.title = title
        self.prompt = prompt
        read = { format.format(value.wrappedValue) }
        write = { raw in
            guard let parsed = try? format.parseStrategy.parse(raw), parsed.isFinite else { return false }
            value.wrappedValue = parsed
            return true
        }
    }
    init(_ title: String, value: Binding<Double?>, format: FloatingPointFormatStyle<Double> = .number, prompt: Text? = nil) {
        self.title = title
        self.prompt = prompt
        read = { value.wrappedValue.map { format.format($0) } ?? "" }
        write = { raw in
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value.wrappedValue = nil
                return true
            }
            guard let parsed = try? format.parseStrategy.parse(raw), parsed.isFinite else { return false }
            value.wrappedValue = parsed
            return true
        }
    }
    var body: some View {
        nativeSessionOwnedInput(NativeSessionNumberFieldContent(title: title, prompt: prompt, read: read, write: write, quiet: quiet), owner: scope)
    }
}
private struct NativeSessionNumberFieldContent: View {
    let title: String
    let prompt: Text?
    let read: () -> String
    let write: (String) -> Bool
    var quiet = false
    @State private var draft: String?
    @State private var ownValue: String?
    @FocusState private var focused: Bool

    var body: some View {
        let value = read()
        let field = NativeSessionTextField(title, text: Binding(get: { draft ?? read() }, set: { raw in
            draft = raw
            if write(raw) { ownValue = read() }
        }), prompt: prompt)
        .sessionFocused($focused)
        .onSubmit { draft = nil }
        return (quiet ? field.textFieldStyle(.plain) : field.textFieldStyle(.roundedBorder))
        .onChange(of: focused) { _, now in if !now { draft = nil } }
        .onChange(of: value) { _, next in
            if !focused || next != ownValue { draft = nil }
        }
    }
}
