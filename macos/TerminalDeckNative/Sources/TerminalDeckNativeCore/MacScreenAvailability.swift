import Foundation

/// Wake permission follows one screen request, including its child capture task. Reads never grant it.
public enum MacScreenAvailability {
    @TaskLocal public static var mayWake = false
    @TaskLocal public static var progress: @Sendable (String) async -> Void = { _ in }
    public enum State: String, Sendable { case awake, asleep, locked, unknown }
    public static let locked = "Your Mac is locked. Unlock it to see its screen."
    public static let waking = "Your Mac's screen is asleep — waking it…"
    public static let asleep = "Your Mac's screen is asleep. Try again to wake it."
    public static let wakeRefused = "Your Mac's screen is asleep. Waking it needs your own device or Full access."
    public static let unavailable = "Your Mac isn't making its screen available right now. Try again."
    public struct Failure: Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// One bounded retry. An empty capture list alone never proves a monitor was unplugged.
    @MainActor public static func capture<Value>(
        mayWake: Bool, state: () -> State, helperApproved: () -> Bool = { false },
        read: () async throws -> Value, isEmpty: (Value) -> Bool,
        wake: () -> Bool, wait: () async throws -> Void,
        progress: (String) async -> Void = { _ in }
    ) async throws -> Value {
        guard state() != .unknown else { throw Failure(unavailable) }
        let sleeping = state() == .asleep
        if !sleeping {
            do {
                let value = try await read()
                if !isEmpty(value) { return value }
            } catch {
                if error is CancellationError { throw error }
                guard state() == .locked || state() == .asleep else { throw error }
            }
        }
        // Lock state is a hint, not proof capture is unavailable. Always try the picture first.
        if sleeping || state() == .asleep || state() == .locked {
            if mayWake {
                await progress(waking)
                try Task.checkCancellation()
                if !wake(), state() != .locked { throw Failure(asleep) }
            } else if state() == .asleep { throw Failure(wakeRefused) }
        }
        try await wait()
        do {
            let retried = try await read()
            if !isEmpty(retried) { return retried }
        } catch {
            if error is CancellationError { throw error }
            guard state() == .locked || state() == .asleep else { throw error }
        }
        throw Failure(state() == .locked && !helperApproved() ? locked : state() == .asleep ? asleep : unavailable)
    }
}
