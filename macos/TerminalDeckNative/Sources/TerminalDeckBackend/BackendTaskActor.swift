import Foundation

/// task-actor.ts's one async context. Child tasks inherit this value; unrelated
/// calls cannot borrow an AI app's name from mutable global state.
public enum BackendTaskActor {
    @TaskLocal public static var current: String = "me"
    public static func withActor<T: Sendable>(_ actor: String, operation: @Sendable () async throws -> T) async rethrows -> T {
        try await $current.withValue(actor, operation: operation)
    }
    public static func appActor(_ keyName: String) -> String { "app:" + keyName }
    public static func appActorName(_ id: String) -> String? { id.hasPrefix("app:") ? String(id.dropFirst(4)) + " (AI app)" : nil }
    /// A paired phone or tablet acting through its own panels: named by the device itself, e.g. "Asad's iPhone"
    /// (27 Oct walk, f: a phone's changes read "AI app (AI app)" in the task's activity).
    public static func deviceActor(_ deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
        return "device:" + String((name.isEmpty ? "Phone" : name).prefix(64))
    }
    public static func deviceActorName(_ id: String) -> String? { id.hasPrefix("device:") && id.count > 7 ? String(id.dropFirst(7)) : nil }
    /// How an actor from outside the Mac is named on screen: an AI app by its key's name, a device by its own.
    public static func outsideActorName(_ id: String) -> String? { appActorName(id) ?? deviceActorName(id) }
}
