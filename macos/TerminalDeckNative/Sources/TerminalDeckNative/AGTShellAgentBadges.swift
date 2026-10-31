import Foundation
import Observation
import TerminalDeckNativeCore

/// AGT: which shell tabs have an AI running in them (typed by hand), for the tab's icon.
/// Read once, then again only when the engine says it changed or a session comes or goes.
@MainActor
@Observable
final class AGTShellAgentBadges {
    static let shared = AGTShellAgentBadges()
    private(set) var providers: [String: String] = [:]
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// The AI's icon for a tab, or nil to keep the tab's own.
    func symbol(for tabID: String) -> String? {
        start()
        switch providers[tabID] {
        case "claude": return "sparkle"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkles"
        default: return nil
        }
    }
    func label(for tabID: String) -> String? { providers[tabID].map(AGTDirectory.providerLabel) }

    private func start() {
        guard subscriptions.isEmpty else { return }
        for event in ["agt-shell-agents:changed", "session:created", "session:exit", "session:removed"] {
            subscriptions.append(EngineBridge.shared.on(event) { _ in Task { @MainActor in AGTShellAgentBadges.shared.reload() } })
        }
        reload()
    }

    func reload() {
        loading?.cancel()
        loading = Task { [weak self] in
            guard let raw = try? await EngineBridge.shared.invoke("agt-shell-agents:list", [Any?]()), !Task.isCancelled,
                  let value = try? NativeRPCValue.fromFoundation(raw) else { return }
            self?.providers = Dictionary((value["sessions"].fields ?? []).compactMap { field in field.value.string.map { (field.key, $0) } },
                                         uniquingKeysWith: { first, _ in first })
        }
    }
}
