import Foundation
import TerminalDeckNativeCore

/// Backend-only launch callback for the assistant process itself, never a
/// renderer input/origin heuristic. Uses the existing shared hidden register;
/// it remembers only the IDs it hid itself, so it never releases a per-device
/// run or another owner's hidden session. No PTY, no TTL.
public final class BackendHootJoinSpawnBoundary: @unchecked Sendable {
    public let hidden: BackendRemoteServeSessionHidden
    private let lock = NSLock()
    private var own = Set<String>()
    public init(hidden: BackendRemoteServeSessionHidden = .shared) { self.hidden = hidden }
    /// The PTY manager calls this through `BackendSpawnSpec.beforeExposure`
    /// after allocating the actual ID and spawning, before map insertion,
    /// process.start, any data/exit event, list, attach replay or announce.
    public func beforeExposure(_ actualSessionID: String) {
        guard !actualSessionID.isEmpty else { return }
        lock.withLock { _ = own.insert(actualSessionID) }
        hidden.hide(actualSessionID)
    }
    /// The launch hook as the launcher's context carries it.
    public var exposureHook: @Sendable (String) -> Void { { [self] id in beforeExposure(id) } }
    /// Valid only when no child can accept input or after its real reaped exit.
    /// Never release on a UI disconnect or on a pre-reap .removed event.
    public func failedBeforeSpawn(_ actualSessionID: String) { releaseOwn(actualSessionID) }
    public func processReaped(_ actualSessionID: String) { releaseOwn(actualSessionID) }
    public func hid(_ id: String) -> Bool { lock.withLock { own.contains(id) } }
    public func isHidden(_ id: String, runtime: BackendCopilotSessionRuntime) -> Bool {
        hidden.contains(id) || runtime.isCopilotSession(id)
    }
    private func releaseOwn(_ id: String) {
        let mine = lock.withLock { own.remove(id) != nil }
        if mine { hidden.release(id) }
    }
}

/// The canonical resolver is already public. Actual measurement remains an
/// explicit required supplier over the existing Mac confinement owner's proof.
public struct BackendHootJoinRecords: BackendCopilotSessionRecordsProviding {
    private let dataRoot: URL
    private let prove: @Sendable () async throws -> BackendCopilotSessionFence
    public init(dataRoot: URL, prove: @escaping @Sendable () async throws -> BackendCopilotSessionFence) throws {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), dataRoot.path != "/" else {
            throw NativeRPCError.invalidArguments("Hoot's records join needs its actual app data directory.")
        }
        self.dataRoot = dataRoot.standardizedFileURL; self.prove = prove
    }
    public func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        guard URL(fileURLWithPath: userData).standardizedFileURL.path == dataRoot.path else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's records resolver belongs to another data directory.")
        }
        return try .init(paths: BackendMacConfinement.recordsFencePaths(dataRoot))
    }
    public func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement {
        do {
            _ = try await paths(userData: userData)
            let fence = try await prove()
            guard fence.id == BackendMacConfinement.recordsFenceID, fence.kind == "seatbelt" else {
                throw NativeRPCError(code: "unavailable", message: "The measured Hoot records fence is unavailable.")
            }
            return .init(fence: fence, reason: nil)
        } catch {
            return .init(fence: nil, reason: "This app’s own routines and action log could not be held against Hoot on this machine: " + error.localizedDescription)
        }
    }
}
