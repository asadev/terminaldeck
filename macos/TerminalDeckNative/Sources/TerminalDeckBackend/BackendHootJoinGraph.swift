import Foundation
import TerminalDeckNativeCore

/// Request 8: the concrete `BackendHootRegistrationGraphJoins`. It derives each
/// join capability from the actual retained owners (object identity, the
/// runtime's installed records supplier, the driver's spawn hook, the app's
/// installed transcript scopes), never from settings or declared readiness.
/// Construction is inert: no writer, watcher, probe or process starts.
public final class BackendHootJoinGraph: BackendHootRegistrationGraphJoins, @unchecked Sendable {
    /// Read-only evidence closures the composition root supplies from the
    /// actual installed owners. Each names the exact expression in
    /// hoot-HANDOFF.md ("Request 8 joins"); a nil/false answer leaves that
    /// capability missing and registration refuses with its name.
    public struct Evidence: Sendable {
        /// The deck-core action log's own raw sink (after O1-R1: `{ actionLog.rawSink }`).
        public let toolSink: @Sendable () async -> (any BackendHootJoinRawActionSink)?
        /// The desk driver's launches hide at spawn (`{ driver.hidesAtSpawn }`, true after O1-R2).
        public let hidesAtSpawn: @Sendable () -> Bool
        /// The account adapter keeps the managed login under the records fence
        /// (after O1-R3: `{ BackendAccountLaunchAdapter.recordsFenceKeepsManagedLogin }`).
        public let managedRecordsAccount: @Sendable () -> Bool
        /// Home scopes actually installed on the app's transcript readers/watchers.
        public let transcriptHomeScopes: @Sendable () async -> [NativeTranscriptHomeScope]
        /// Stops paired-device Hoot: `{ await frames.stop(); await runs.stopAll() }`.
        public let stopPhoneRuns: (@Sendable () async -> Void)?
        /// The deck-core consent owner's window-detach (it calls `approverGone()`
        /// only when this window was the attached approver).
        public let windowGone: (@Sendable (NativeRPCContext) async throws -> Void)?
        public init(toolSink: @escaping @Sendable () async -> (any BackendHootJoinRawActionSink)?,
                    hidesAtSpawn: @escaping @Sendable () -> Bool,
                    managedRecordsAccount: @escaping @Sendable () -> Bool,
                    transcriptHomeScopes: @escaping @Sendable () async -> [NativeTranscriptHomeScope],
                    stopPhoneRuns: (@Sendable () async -> Void)?,
                    windowGone: (@Sendable (NativeRPCContext) async throws -> Void)?) {
            self.toolSink = toolSink; self.hidesAtSpawn = hidesAtSpawn; self.managedRecordsAccount = managedRecordsAccount
            self.transcriptHomeScopes = transcriptHomeScopes; self.stopPhoneRuns = stopPhoneRuns; self.windowGone = windowGone
        }
    }

    public let runtime: BackendCopilotSessionRuntime
    public let manager: BackendPTYManager
    public let mcpDoor: BackendCopilotSessionMCPDoor
    public let actionLog: BackendDeckCoreSecurityActionLog
    public let sink: BackendHootJoinRawSink
    public let boundary: BackendHootJoinSpawnBoundary
    public let homeScope: NativeTranscriptHomeScope
    private let authority: BackendHootJoinSourceAuthority?
    private let evidence: Evidence

    public init(dataRoot: URL, storageRoot: URL, runtime: BackendCopilotSessionRuntime, manager: BackendPTYManager,
                mcpDoor: BackendCopilotSessionMCPDoor, actionLog: BackendDeckCoreSecurityActionLog,
                boundary: BackendHootJoinSpawnBoundary, authority: BackendHootJoinSourceAuthority? = nil,
                evidence: Evidence) throws {
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), dataRoot.path != "/",
              storageRoot.isFileURL, storageRoot.path.hasPrefix("/"), storageRoot.path != "/" else {
            throw NativeRPCError.invalidArguments("Hoot's joins need the app's absolute data and storage folders.")
        }
        // The same process-wide sink Home's appendAction already writes through.
        sink = try BackendHootJoinRawSink.shared(directory: dataRoot.standardizedFileURL.appendingPathComponent("copilot-log", isDirectory: true))
        homeScope = BackendCopilotSessionRuntime.homeScope(userData: dataRoot.standardizedFileURL.path, storageDir: storageRoot.standardizedFileURL.path)
        self.runtime = runtime; self.manager = manager; self.mcpDoor = mcpDoor; self.actionLog = actionLog
        self.boundary = boundary; self.authority = authority; self.evidence = evidence
    }

    /// The single per-start hidden-at-spawn hook to pass to
    /// `BackendCopilotSessionNativeDriver(..., exposure:)`.
    public var exposureHook: @Sendable (String) -> Void { boundary.exposureHook }

    public func installed() async throws -> BackendHootJoinReceipt {
        var capabilities = Set<BackendHootJoinCapability>()
        let tool = await evidence.toolSink()
        if let tool, ObjectIdentifier(tool) == ObjectIdentifier(sink),
           actionLog.file.standardizedFileURL.path == sink.file.standardizedFileURL.path {
            capabilities.insert(.sharedRawWriter)
        }
        if evidence.hidesAtSpawn() { capabilities.insert(.hiddenBeforeSpawn) }
        if runtime.installedRecords is BackendHootJoinRecords { capabilities.insert(.measuredRecordsWrapper) }
        if evidence.managedRecordsAccount() { capabilities.insert(.managedRecordsAccount) }
        let scopes = await evidence.transcriptHomeScopes()
        if scopes.contains(where: { $0.home == homeScope.home && $0.folder == homeScope.folder }) {
            capabilities.insert(.bootTranscriptScope)
        }
        if evidence.stopPhoneRuns != nil { capabilities.insert(.quiescentShutdown) }
        return BackendHootJoinReceipt(runtime: runtime, manager: manager, mcpDoor: mcpDoor, actionLog: actionLog,
            homeSink: sink, toolSink: tool ?? sink, hidden: boundary.hidden, homeScope: homeScope,
            capabilities: capabilities)
    }

    public func quiesceAndStopHoot() async throws {
        guard let stopPhoneRuns = evidence.stopPhoneRuns else {
            throw NativeRPCError(code: "unavailable", message: "Paired-device Hoot cannot be stopped by this graph.")
        }
        authority?.revoke()
        // Phone runs first: their frames stop accepting starts, then runs end.
        await stopPhoneRuns()
        _ = try await runtime.quiesceAndStop()
        guard await runtime.isClosing else {
            throw NativeRPCError(code: "unavailable", message: "Hoot could still start after shutdown.")
        }
    }

    public func windowGone(_ context: NativeRPCContext) async throws {
        guard let windowGone = evidence.windowGone else {
            throw NativeRPCError(code: "unavailable", message: "The confirmation owner for this window is unavailable.")
        }
        try await windowGone(context)
    }
}
