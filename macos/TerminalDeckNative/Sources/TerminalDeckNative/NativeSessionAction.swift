import SwiftUI

/// Only a UI action is gated here. Calling the underlying model or MCP operation
/// remains an explicitly addressed action, including while its screen is hidden.
struct NativeSessionButton<Content: View>: View {
    @Environment(\.nativeSessionInputScope) private var scope
    private let role: ButtonRole?
    private let action: () -> Void
    private let label: Content

    init(role: ButtonRole? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.role = role
        self.action = action
        self.label = label()
    }

    var body: some View {
        NativeSessionButtonContent(role: role, action: action, label: label)
            .id(scope?.identity)
    }
}

private struct NativeSessionButtonContent<Content: View>: View {
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @State private var inputRule = NativeSessionInputRule()
    let role: ButtonRole?
    let action: () -> Void
    let label: Content

    var body: some View {
        inputRule.bind(to: scope)
        inputRule.update(active: scope == nil ? active : true, enabled: enabled)
        return Button(role: role, action: {
            // Asked when the action runs: is this button's OWNER on screen right now? With a
            // scope, `acceptsFocus` reads the owner scope's live state. It never depends on this
            // button's own view: a menu or a confirmation dialog closes, and may report its items
            // gone, before AppKit runs the picked item, which must still run for a visible owner.
            guard inputRule.acceptsFocus else { return }
            action()
        }, label: { label })
        .disabled(!inputRule.acceptsFocus)
    }
}

extension NativeSessionButton where Content == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

extension NativeSessionButton where Content == Label<Text, Image> {
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Label(title, systemImage: systemImage) }
    }
}
