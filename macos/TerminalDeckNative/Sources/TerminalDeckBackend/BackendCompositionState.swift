import Foundation
import TerminalDeckNativeCore

/// Actor-backed native settings mutations. Synchronous fixture implementations
/// of the original core surface remain usable; production awaits the disk owner.
public protocol BackendCompositionSettingsWriting: Sendable {
    func snapshotSettingsAsync() async throws -> NativeRPCValue
    func writeSettingsAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue
    func writePreferencesAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue
}

/// A synchronous view of the actors' own committed values. The actors seed and
/// update it in their serial mutation boundary, rather than through detached
/// tasks or polling. This object has no files, independent cache reload or writer.
public final class BackendCompositionState: BackendDeckCoreLiveState, BackendCompositionSettingsWriting, @unchecked Sendable {
    public let store: NativeStateStore
    public let settings: BackendAppSettingsStore
    public let dataRoot: URL
    private let lock = NSLock()
    private var stateValue: NativeRPCValue = .missing
    private var settingsValue: NativeRPCValue = .missing
    private var subscriptions: [NativeRPCSubscription] = []
    private let selectedCopilotRoot: @Sendable (NativeRPCValue) -> String
    private let registry: NativeChannelRegistry
    private init(store: NativeStateStore, settings: BackendAppSettingsStore, dataRoot: URL,
                 registry: NativeChannelRegistry, copilotRoot: @escaping @Sendable (NativeRPCValue) -> String) {
        self.store = store; self.settings = settings; self.dataRoot = dataRoot; self.registry = registry
        selectedCopilotRoot = copilotRoot
    }
    public static func make(store: NativeStateStore, settings: BackendAppSettingsStore,
                            dataRoot: URL, registry: NativeChannelRegistry,
                            copilotRoot: @escaping @Sendable (NativeRPCValue) -> String) async -> BackendCompositionState {
        let projection = BackendCompositionState(store: store, settings: settings, dataRoot: dataRoot,
            registry: registry, copilotRoot: copilotRoot)
        let stateLease = await store.observeSnapshot { [weak projection] value in
            projection?.lock.withLock { projection?.stateValue = value }
        }
        let settingsLease = await settings.observeSnapshot { [weak projection] value in
            projection?.lock.withLock { projection?.settingsValue = value }
        }
        projection.lock.withLock { projection.subscriptions = [stateLease, settingsLease] }
        return projection
    }
    public func state() -> NativeRPCValue { lock.withLock { stateValue } }
    public func settingsEnvelope() -> NativeRPCValue { lock.withLock { settingsValue } }
    public func listProjects() -> [NativeRPCValue] {
        NativeStateStore.sortedProjects(state()["projects"].elements ?? [])
    }
    public func appStateRoot() -> String { dataRoot.path }
    public func copilotRoot() -> String { selectedCopilotRoot(settingsEnvelope()["values"]) }
    public func readSettings() -> NativeRPCValue {
        .object([.init("settings", settingsEnvelope()["values"]), .init("preferences", state()["preferences"])])
    }
    public func snapshotSettings(reason: String) throws -> NativeRPCValue { throw asyncWriteRequired() }
    public func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue { throw asyncWriteRequired() }
    public func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue { throw asyncWriteRequired() }
    private func asyncWriteRequired() -> NativeRPCError {
        .init(code: "unavailable", message: "The native settings owner requires its awaited mutation path.")
    }
    public func snapshotSettingsAsync() async throws -> NativeRPCValue {
        try await settings.snapshot(preferences: await store.getPreferences(), reason: "Hoot settings.write")
    }
    public func writeSettingsAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue {
        let saved = try await settings.patch(patch)
        try await registry.publish("settings:changed", arguments: [saved])
        return saved["values"]
    }
    public func writePreferencesAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue {
        let saved = try await store.setPreferences(patch)
        // index.ts prefs:set / live-surface writePreferences: serverSettings.noteChanged()
        // after every preference write, whichever surface made it (the patch is partial,
        // so "did a server-owned one change" has a wrong answer available).
        for listener in lock.withLock({ Array(preferenceListeners.values) }) { listener(patch) }
        try await registry.publish("prefs:changed", arguments: [saved])
        return saved
    }
    private var preferenceListeners: [UUID: @Sendable (NativeRPCValue) -> Void] = [:]
    /// Told after every committed preference write (host-core.ts onChanged), with the patch.
    public func observePreferenceWrites(_ listener: @escaping @Sendable (NativeRPCValue) -> Void) -> NativeRPCSubscription {
        let id = UUID()
        lock.withLock { preferenceListeners[id] = listener }
        return NativeRPCSubscription(id: id) { [weak self] in self?.lock.withLock { _ = self?.preferenceListeners.removeValue(forKey: id) } }
    }
    public func stop() async {
        let held = lock.withLock { let held = subscriptions; subscriptions = []; return held }
        for lease in held { await lease.cancelAndWait() }
    }
}
