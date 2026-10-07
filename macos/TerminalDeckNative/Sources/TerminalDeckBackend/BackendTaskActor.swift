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
}
