import Foundation
import TerminalDeckNativeCore

/// The app's one authoritative Store (state.json): opened exclusively before
/// the native graph is assembled, handed to it, and closed only after the
/// graph has drained, so the final ledger save always lands.
actor NativeStateService {
    static let shared = NativeStateService()
    private var stateFile: URL?
    private var state: NativeStateStore?

    /// Reusing the same live Store is safe; changing data roots is refused.
    func start(stateFile: URL, ownership: NativeStateStore.Ownership = .exclusive,
               failurePolicy: NativeStateStore.PersistencePolicy = .throwAndRollback) throws {
        let file = stateFile.standardizedFileURL
        if state != nil {
            guard self.stateFile == file else { throw NativeRPCError(code: "state-root-conflict", message: "The native Store already owns another data directory") }
            return
        }
        guard ownership == .exclusive || ownership == .memory else { throw NativeRPCError(code: "store-read-only", message: "The authoritative Store requires exclusive ownership") }
        state = try NativeStateStore(file: file, ownership: ownership, failurePolicy: failurePolicy)
        self.stateFile = file
    }

    func authoritativeStore() throws -> NativeStateStore {
        guard let state else { throw NativeRPCError(code: "state-unavailable", message: "The native Store is not open") }
        return state
    }

    func stop() async {
        await state?.close(); state = nil
        stateFile = nil
    }
}
