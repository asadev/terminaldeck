import Foundation
import TerminalDeckNativeCore

// L8 HOST (11 Oct 2026): closing the app must hand its kept sessions to the session host every time.

/// What must end BEFORE the app hands its kept sessions to the session host: app-owned processes that hold
/// an account lease there (Hoot's direct CLI). They die with the app in any case; ending them first is what
/// lets the host answer "safe to detach". Hosted sessions are never touched by this.
public enum BackendHOSTKeepDetachPreparation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var closers: [String: @Sendable () async -> Void] = [:]
    public static func register(_ name: String, _ close: (@Sendable () async -> Void)?) { lock.withLock { closers[name] = close } }
    public static func run() async {
        for close in lock.withLock({ closers.sorted { $0.key < $1.key }.map(\.value) }) { await close() }
    }
}

/// The host's own answer to "may the app leave you alone with the sessions?", asked a few times: an
/// app-owned process that was just ended takes a moment to be seen as gone. Bounded; no polling otherwise.
public enum BackendHOSTKeepDetachReadiness {
    public struct Answer: Sendable, Equatable {
        public var safeToDetach: Bool, claimsAdopted: Bool
        public init(safeToDetach: Bool, claimsAdopted: Bool) { self.safeToDetach = safeToDetach; self.claimsAdopted = claimsAdopted }
    }
    public static func wait(tries: Int = 25, read: () async throws -> Answer,
                            pause: (Double) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int($0 * 1000))) }) async throws {
        var answer = try await read(), left = max(0, tries - 1)
        // Claims that were not adopted do not change by waiting; an app-owned process on its way out does.
        while !answer.safeToDetach, answer.claimsAdopted, left > 0 { try await pause(0.1); left -= 1; answer = try await read() }
        guard answer.claimsAdopted else {
            throw BackendHOSTFailure.remote("The session host has not confirmed this app's task and Receiver claims, so it was not left alone with the sessions.")
        }
        guard answer.safeToDetach else {
            throw BackendHOSTFailure.remote("The session host still sees an app-owned process (such as Hoot's own CLI) holding an account, so it was not left alone with the sessions.")
        }
    }
}
