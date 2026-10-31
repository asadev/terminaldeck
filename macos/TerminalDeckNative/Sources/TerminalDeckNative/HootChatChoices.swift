import Foundation
import Observation
import TerminalDeckNativeCore

/// The ONE live copy of Hoot's choices (model, effort, permission, Fast mode, the live model
/// lists): the latest `hoot:chat:options`. Every writer goes through it (the composer on the
/// Hoot page and in the island, the gear popover, Settings → Hoot) and every view observes it,
/// so a change made in one place shows in all of them at once. The backend keeps the saved
/// setting; this is its single in-app mirror.
@MainActor @Observable
final class HootChatChoices {
    typealias Invoke = @MainActor (String, [Any?]) async throws -> Any
    static let shared = HootChatChoices()
    /// The latest options value (nil until first read).
    private(set) var value: NativeRPCValue?
    /// Bumped on every new value, so observers can tell a fresh read from a repeat.
    private(set) var revision = 0
    @ObservationIgnored private let invoke: Invoke
    @ObservationIgnored private var observers: [UUID: @MainActor (NativeRPCValue) -> Void] = [:]
    init(invoke: @escaping Invoke = { channel, args in try await EngineBridge.shared.invoke(channel, args) }) {
        self.invoke = invoke
    }
    /// Every view that shows these choices registers here; it is told at once (if a value is
    /// known) and after every change, whoever made it.
    @discardableResult
    func addObserver(_ observer: @escaping @MainActor (NativeRPCValue) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        if let value { observer(value) }
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    /// Read the saved choices again (after a save made elsewhere, e.g. Settings' provider).
    func reload() async {
        if let raw = try? await invoke("hoot:chat:options", []), let next = try? NativeRPCValue.fromFoundation(raw) { publish(next) }
    }
    /// The one write path for model, effort, permission and Fast mode. Throws so the caller can show why.
    @discardableResult
    func change(_ patch: [String: Any]) async throws -> NativeRPCValue {
        let next = try NativeRPCValue.fromFoundation(try await invoke("hoot:chat:options", [patch]))
        publish(next)
        return next
    }
    private func publish(_ next: NativeRPCValue) {
        value = next; revision += 1
        for observer in observers.values { observer(next) }
    }
}
