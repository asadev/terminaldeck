import AppKit
import SwiftUI

/// Presentations may retain the environment they were opened with. Their input scope
/// remains the same object, so hiding the owner closes a sheet/popover's gate immediately
/// even before SwiftUI updates that presentation. Each session gets a different scope.
@MainActor
final class NativeSessionInputScope {
    let identity = UUID()
    private(set) var active = true
    private var locallyActive = true
    private weak var parent: NativeSessionInputScope?
    private let clients = NSHashTable<NativeSessionInputRule>.weakObjects()
    private let children = NSHashTable<NativeSessionInputScope>.weakObjects()

    func register(_ rule: NativeSessionInputRule) { clients.add(rule) }
    func unregister(_ rule: NativeSessionInputRule) { clients.remove(rule) }

    func setActive(_ next: Bool) {
        locallyActive = next
        refreshAvailability()
    }

    func bind(to parent: NativeSessionInputScope?) {
        guard self.parent !== parent else { return }
        self.parent?.children.remove(self)
        self.parent = parent
        parent?.children.add(self)
        refreshAvailability()
    }

    private func refreshAvailability() {
        let next = locallyActive && parent?.active != false
        guard active != next else { return }
        active = next
        if !next {
            // Composition belongs to the outgoing screen even if it is shown again before
            // the deferred focus pass. This phase never changes SwiftUI focus bindings.
            for rule in clients.allObjects { rule.scopeWillDeactivate(self) }
        }
        // A retained child presentation must close with its owner even if SwiftUI has
        // not updated the child's captured environment yet.
        for child in children.allObjects { child.refreshAvailability() }
        // Close the gate synchronously. Release AppKit focus after the SwiftUI update
        // rather than changing a FocusState binding while its body is being evaluated.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active == next else { return }
            for rule in self.clients.allObjects { rule.scopeDidChange(self) }
        }
    }
}

private struct NativeSessionInputScopeKey: EnvironmentKey {
    static let defaultValue: NativeSessionInputScope? = nil
}
extension EnvironmentValues {
    var nativeSessionInputScope: NativeSessionInputScope? {
        get { self[NativeSessionInputScopeKey.self] }
        set { self[NativeSessionInputScopeKey.self] = newValue }
    }
}

@MainActor
private final class NativeSessionScopeOwner {
    private var id: String?
    private var current = NativeSessionInputScope()

    func scope(for id: String, active: Bool, parent: NativeSessionInputScope?) -> NativeSessionInputScope {
        if self.id != id {
            current.setActive(false)
            current = NativeSessionInputScope()
            self.id = id
        }
        current.bind(to: parent)
        current.setActive(active)
        return current
    }
}

private struct NativeSessionInputScopeModifier: ViewModifier {
    let ownerID: String
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.nativeSessionInputScope) private var parentScope
    @State private var owner = NativeSessionScopeOwner()

    func body(content: Content) -> some View {
        let scope = owner.scope(for: ownerID, active: active, parent: parentScope)
        return content.environment(\.nativeSessionInputScope, scope)
            .onAppear { scope.setActive(active) }
            .onDisappear { scope.setActive(false) }
    }
}

extension View {
    func nativeSessionInputScope(ownerID: String) -> some View {
        modifier(NativeSessionInputScopeModifier(ownerID: ownerID))
    }
}
