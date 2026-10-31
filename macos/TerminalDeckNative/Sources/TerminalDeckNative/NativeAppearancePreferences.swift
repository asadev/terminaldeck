import Foundation
import TerminalDeckNativeCore

/// App-wide preferences binding. It lives independently of the Settings window
/// and uses the committed prefs event for writes from MCP, phones and native UI.
@MainActor
final class NativeAppearancePreferences {
    private let bridge: EngineBridge
    private let apply: (AppAppearance) -> Void
    private var subscription: EngineSubscription?
    private var revision = 0
    private var generation = 0

    init(bridge: EngineBridge, apply: @escaping (AppAppearance) -> Void) {
        self.bridge = bridge
        self.apply = apply
    }

    func start() {
        guard subscription == nil else { return }
        generation += 1
        let lifetime = generation
        subscription = bridge.on("prefs:changed") { [weak self] arguments in
            guard let self, self.generation == lifetime, self.subscription != nil else { return }
            self.revision += 1
            self.receive(arguments.first)
        }
    }

    /// After a bridge connects, the persisted preference wins over last launch's
    /// cached appearance. A newer event must win over an in-flight initial read.
    func synchronize() async {
        guard subscription != nil, bridge.isReady else { return }
        revision += 1
        let mine = revision
        guard let preferences = try? await bridge.invoke("prefs:get"),
              subscription != nil, mine == revision else { return }
        receive(preferences)
    }

    func stop() {
        revision += 1
        generation += 1
        subscription?.cancel()
        subscription = nil
    }

    private func receive(_ preferences: Any?) {
        guard let preferences = preferences as? [String: Any],
              let appearance = AppAppearance(preference: preferences["theme"] as? String, resolved: nil) else { return }
        apply(appearance)
    }
}
