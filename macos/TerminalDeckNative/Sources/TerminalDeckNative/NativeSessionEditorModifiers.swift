import SwiftUI

@MainActor struct NativeSessionFocusBinding {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let heldByOther: () -> Bool
    var wrappedValue: Bool {
        get { read() }
        nonmutating set { write(newValue) }
    }
    /// An enum focus now naming another field: a request for this one was replaced. A cleared
    /// value is not that; SwiftUI clears it by itself when it cannot place focus yet.
    var isHeldByOther: Bool { heldByOther() }
    init(_ binding: FocusState<Bool>.Binding) {
        read = { binding.wrappedValue }
        write = { binding.wrappedValue = $0 }
        heldByOther = { false }
    }
    init<Value: Hashable>(_ binding: FocusState<Value?>.Binding, equals value: Value) {
        read = { binding.wrappedValue == value }
        heldByOther = { binding.wrappedValue.map { $0 != value } ?? false }
        write = { next in
            if next { binding.wrappedValue = value }
            else if binding.wrappedValue == value { binding.wrappedValue = nil }
        }
    }
}
@MainActor final class NativeSessionEditorFocus {
    let binding: NativeSessionFocusBinding
    init(_ binding: FocusState<Bool>.Binding) { self.binding = .init(binding) }
    init<Value: Hashable>(_ binding: FocusState<Value?>.Binding, equals value: Value) {
        self.binding = .init(binding, equals: value)
    }
}
@MainActor final class NativeSessionEditorAction {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
private struct SessionEditorFocusKey: EnvironmentKey {
    static let defaultValue: NativeSessionEditorFocus? = nil
}
private struct SessionEditorSubmitKey: EnvironmentKey {
    static let defaultValue: NativeSessionEditorAction? = nil
}
private struct SessionEditorExitKey: EnvironmentKey {
    static let defaultValue: NativeSessionEditorAction? = nil
}
extension EnvironmentValues {
    var nativeSessionEditorFocus: NativeSessionEditorFocus? {
        get { self[SessionEditorFocusKey.self] }
        set { self[SessionEditorFocusKey.self] = newValue }
    }
    var nativeSessionEditorSubmit: NativeSessionEditorAction? {
        get { self[SessionEditorSubmitKey.self] }
        set { self[SessionEditorSubmitKey.self] = newValue }
    }
    var nativeSessionEditorExit: NativeSessionEditorAction? {
        get { self[SessionEditorExitKey.self] }
        set { self[SessionEditorExitKey.self] = newValue }
    }
}
extension View {
    /// Carry focus and commands through layout/style modifiers and groups to the owned
    /// Cocoa editor. The editor still checks its live rule before invoking any action.
    /// A concrete editor's Self-returning overload keeps its native configuration chain;
    /// this fallback is used after a layout modifier or on a group.
    @_disfavoredOverload
    func sessionFocused(_ binding: FocusState<Bool>.Binding) -> some View {
        environment(\.nativeSessionEditorFocus, NativeSessionEditorFocus(binding))
            .focused(binding)
    }
    func sessionFocused<Value: Hashable>(_ binding: FocusState<Value?>.Binding, equals value: Value) -> some View {
        environment(\.nativeSessionEditorFocus, NativeSessionEditorFocus(binding, equals: value))
            .focused(binding, equals: value)
    }
    func sessionOnSubmit(_ action: @escaping () -> Void) -> some View {
        environment(\.nativeSessionEditorSubmit, NativeSessionEditorAction(action))
    }
    func sessionOnExitCommand(_ action: @escaping () -> Void) -> some View {
        modifier(NativeSessionExitCommand(action: action))
    }
}

/// Register concrete editors with SwiftUI's focus storage as well as with Cocoa.
/// Merely retaining a FocusState binding in a coordinator does not install its node.
struct NativeSessionDeclaredFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?
    @ViewBuilder func body(content: Content) -> some View {
        if let binding { content.focused(binding) }
        else { content }
    }
}

private struct NativeSessionExitCommand: ViewModifier {
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @State private var inputRule = NativeSessionInputRule()
    let action: () -> Void

    func body(content: Content) -> some View {
        inputRule.bind(to: scope)
        inputRule.update(active: scope == nil ? active : true, enabled: enabled)
        let guarded = {
            guard inputRule.acceptsFocus else { return }
            action()
        }
        return content
            .environment(\.nativeSessionEditorExit, NativeSessionEditorAction(guarded))
            .onExitCommand(perform: guarded)
            .onDisappear { inputRule.update(active: false, enabled: false) }
    }
}
