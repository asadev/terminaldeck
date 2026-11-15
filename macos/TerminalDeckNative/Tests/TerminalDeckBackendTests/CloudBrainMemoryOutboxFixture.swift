import Foundation
import TerminalDeckNativeCore

/// Fixture-only in-memory port. It never registers in native composition or sends a request.
actor CloudBrainMemoryOutboxFixture: CloudOutboxPort {
    var operations: [String:CloudOperation] = [:]
    var fail = false
    var progress: CloudRestoreProgress?
    var context: CloudContextReady?
    func setContext(progress: CloudRestoreProgress, context: CloudContextReady) { self.progress = progress; self.context = context }
    func failNext() { fail = true }
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        if fail { fail = false; throw CloudFailure.unavailable }
        guard files.isEmpty else { throw CloudFailure.unsupportedFormat }
        for op in operations {
            if let old = self.operations[op.opId], old != op { throw CloudFailure.idReused }
            self.operations[op.opId] = op
        }
        return .init(operationIds: operations.map(\.opId), queued: self.operations.count, bytes: Int64(try CloudWire.canonical(Array(self.operations.values)).count), savedAt: 1)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
    func flush() async throws -> [CloudReceipt] { throw CloudFailure.unsupportedFormat }
    func restoreProgress() async throws -> CloudRestoreProgress { guard let progress else { throw CloudFailure.unsupportedFormat }; return progress }
    func contextReady(projectId: String) async throws -> CloudContextReady { guard let context, context.projectId == projectId else { throw CloudFailure.unsupportedFormat }; return context }
    func register(adapter: any CloudDomainAdapter) async throws { throw CloudFailure.unsupportedFormat }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func pull() async throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
    func setPaused(_ paused: Bool) async throws { throw CloudFailure.unsupportedFormat }
}
