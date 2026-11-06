import Foundation
import TerminalDeckNativeCore

/// Only the operations catalogue.ts actually needs. Composition supplies the
/// existing state/session/browser/report owners; this is not a second owner.
public protocol BackendDeckCoreCatalogueSurface: Sendable {
    func listSessions() -> [NativeRPCValue]
    func listProjects() -> [NativeRPCValue]
    func taskWorkspaceFolders() -> [String]
    func sessionStatus(_ sessionID: String) -> NativeRPCValue
    func appStateRoot() -> String
    func copilotRoot() -> String
    func accounts() -> [NativeRPCValue]?
    var hasAsyncAccountChoices: Bool { get }
    func accountsForSessionStart() async throws -> [NativeRPCValue]?
    func withSessionStartContext(_ context: BackendDeckCoreSecurityCallContext, operation: @escaping @Sendable () async throws -> BackendDeckCoreSecurityToolOutput) async throws -> BackendDeckCoreSecurityToolOutput
    func deviceFolders(_ deviceID: String) -> [String]?
    /// Each row has a `slot` (B1 etc.) and a `description` from the binding owner.
    func windows(sessionID: String) -> [NativeRPCValue]
    /// { settings, preferences }; never infer missing stores from an empty object.
    func readSettings() -> NativeRPCValue
    func snapshotSettings() throws -> NativeRPCValue
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue
    func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue
    func applyToWindow(scope: String, values: NativeRPCValue) -> Bool

    /// { path: string|null, basis, ambiguous, otherSessions, note: string|null }.
    func transcriptFor(session: NativeRPCValue) async throws -> NativeRPCValue
    func transcriptBytes(path: String) async throws -> Double
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue]
    /// A Codex or Gemini session's own conversation record (BackendDeckCoreAgentRecords); nil for every other session.
    func agentRecord(session: NativeRPCValue, windowBytes: Int) async -> BackendDeckCoreAgentRecord?
    func sessionScreen(_ sessionID: String) async throws -> String?
    /// forDevice is mandatory for a remote caller; owner credentials must never substitute.
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue
    func sendChat(_ sessionID: String, text: String) async throws
    func writeToSession(_ sessionID: String, data: String) async throws
    func killSession(_ sessionID: String) async throws
    func reportOnSession(session: NativeRPCValue) async throws -> NativeRPCValue
    func reportOnFleet(sessions: [NativeRPCValue], since: Double?, limit: Int, now: Double) async throws -> NativeRPCValue
    func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue
    func gitStatus(cwd: String) async throws -> NativeRPCValue
    func alerts(projectPath: String) async throws -> NativeRPCValue
    /// The app's existing brief writer receives explicit state ownership at composition.
    func writeSpec(directory: String, input: NativeRPCValue) throws -> NativeRPCValue
    func deliverBrief(_ sessionID: String, line: String) async throws -> NativeRPCValue
}

public extension BackendDeckCoreCatalogueSurface {
    // Optional TS operations have the same absence semantics. Required data
    // reads have no default; callers must supply real authoritative snapshots.
    func taskWorkspaceFolders() -> [String] { [] }
    func accounts() -> [NativeRPCValue]? { nil }
    var hasAsyncAccountChoices: Bool { false }
    func accountsForSessionStart() async throws -> [NativeRPCValue]? { accounts() }
    func withSessionStartContext(_ context: BackendDeckCoreSecurityCallContext, operation: @escaping @Sendable () async throws -> BackendDeckCoreSecurityToolOutput) async throws -> BackendDeckCoreSecurityToolOutput { try await operation() }
    func deviceFolders(_ deviceID: String) -> [String]? { nil }
    func applyToWindow(scope: String, values: NativeRPCValue) -> Bool { false }
    func snapshotSettings() throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("settings snapshot") }
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("settings write") }
    func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("preferences write") }
    func transcriptFor(session: NativeRPCValue) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("session transcript matching") }
    func transcriptBytes(path: String) async throws -> Double { throw BackendSessionFailure.missingCapability("transcript byte count") }
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue] { throw BackendSessionFailure.missingCapability("bounded transcript reader") }
    func agentRecord(session: NativeRPCValue, windowBytes: Int) async -> BackendDeckCoreAgentRecord? { nil }
    func sessionScreen(_ sessionID: String) async throws -> String? { throw BackendSessionFailure.missingCapability("session screen") }
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("native session start") }
    func sendChat(_ sessionID: String, text: String) async throws { throw BackendSessionFailure.missingCapability("confirmed chat delivery") }
    func writeToSession(_ sessionID: String, data: String) async throws { throw BackendSessionFailure.missingCapability("native session input") }
    func killSession(_ sessionID: String) async throws { throw BackendSessionFailure.missingCapability("native session stop") }
    func reportOnSession(session: NativeRPCValue) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("session evidence report") }
    func reportOnFleet(sessions: [NativeRPCValue], since: Double?, limit: Int, now: Double) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("fleet evidence report") }
    func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("attributed folder diff") }
    func gitStatus(cwd: String) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("Git status") }
    func alerts(projectPath: String) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("project alerts") }
    func writeSpec(directory: String, input: NativeRPCValue) throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("brief file writer") }
    func deliverBrief(_ sessionID: String, line: String) async throws -> NativeRPCValue { throw BackendSessionFailure.missingCapability("brief delivery") }
}
