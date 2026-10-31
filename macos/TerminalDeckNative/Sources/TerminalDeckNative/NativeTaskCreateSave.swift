import AppKit
import SwiftUI
import TerminalDeckNativeCore

extension NativeTaskCreatePopup {
    // MARK: Create

    func save() {
        guard !saving, hasTitle else { return }
        switch preset.input(draft, agents: agents) {
        case .failure(let refused):
            problem = refused.message
        case .success(let input):
            saving = true
            problem = nil
            Task {
                let result = await store.create(input)
                store.adopt(result)
                saving = false
                if result.ok {
                    store.problem = nil
                    onClose()
                } else {
                    problem = result.message ?? "The task was not created."
                    focus = .name
                }
            }
        }
    }
}
