import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Pump requests may join a launch already in flight. Assert its committed state, not scheduling order.
enum BackendTaskFixtureWait {
    static func running(_ id: String, in store: BackendTaskStore) async throws -> BackendTaskRecord {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            if let task = try await store.byID(id), task.sessionID != nil, task.process == "running" { return task }
            try await clock.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        throw NativeRPCError(code: "test-timeout", message: "The task did not finish launching: " + id)
    }
}
