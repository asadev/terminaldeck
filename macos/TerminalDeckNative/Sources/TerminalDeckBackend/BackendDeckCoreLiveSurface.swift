import Foundation
import TerminalDeckNativeCore

/// Authoritative snapshots/writes supplied by the native Store composition.
/// This object forwards the Store; it must never persist a separate cache.
public protocol BackendDeckCoreLiveState: Sendable {
    func listProjects() -> [NativeRPCValue]
    func appStateRoot() -> String
    func copilotRoot() -> String
    func readSettings() -> NativeRPCValue
    func snapshotSettings(reason: String) throws -> NativeRPCValue
    func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue
    func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue
}
public protocol BackendDeckCoreEvidenceReader: Sendable {
    func transcriptsIn(cwd: String) async throws -> [NativeRPCValue]
    func transcriptBytes(path: String) async throws -> Double
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue]
    func readToolTrail(path: String, windowBytes: Int) async throws -> BackendDeckCoreReportTrail
    func transcriptTotals(path: String) async throws -> NativeRPCValue?
    func fileModifiedAt(path: String) async throws -> Double?
}
public protocol BackendDeckCoreProjectEvidence: Sendable {
    func gitStatus(cwd: String) async throws -> NativeRPCValue
    func alerts(projectPath: String) async throws -> NativeRPCValue
    func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue
}

/// surface.ts/live-surface.ts: the tools and app reach the same owners.
public struct BackendDeckCoreLiveSurface: BackendDeckCoreCatalogueSurface, BackendDeckCoreReportSurface, BackendDeckCoreBriefSurface, BackendCompositionSettingsWriting, Sendable {
    private let manager: BackendPTYManager
    private let state: any BackendDeckCoreLiveState
    private let evidence: any BackendDeckCoreEvidenceReader
    private let projectEvidence: any BackendDeckCoreProjectEvidence
    private let ownership: NativeStateStore.Ownership
    private let start: @Sendable (NativeRPCValue) async throws -> NativeRPCValue
    private let input: @Sendable (String, String) async throws -> Void
    private let close: @Sendable (String) async throws -> Void
    private let status: @Sendable (String) -> NativeRPCValue
    private let bindingWindows: @Sendable (String) -> [NativeRPCValue]
    private let profileChoices: (@Sendable () -> [NativeRPCValue])?
    private let workspaceFolders: (@Sendable () -> [String])?
    private let remoteFolders: (@Sendable (String) -> [String])?
    private let remoteStart: (@Sendable (NativeRPCValue, String) async throws -> NativeRPCValue)?
    private let tellWindow: (@Sendable (String, NativeRPCValue) -> Bool)?
    private let noteServerSettingsChanged: (@Sendable () -> Void)?
    private let readSessions: (@Sendable () -> [NativeRPCValue])?
    private let readScreen: (@Sendable (String) -> String?)?
    private let readScrollback: (@Sendable (String) -> String)?

    public init(manager: BackendPTYManager, state: any BackendDeckCoreLiveState,
                evidence: any BackendDeckCoreEvidenceReader, projectEvidence: any BackendDeckCoreProjectEvidence,
                ownership: NativeStateStore.Ownership,
                startSession: @escaping @Sendable (NativeRPCValue) async throws -> NativeRPCValue,
                writeToSession: @escaping @Sendable (String, String) async throws -> Void,
                closeSession: @escaping @Sendable (String) async throws -> Void,
                sessionStatus: @escaping @Sendable (String) -> NativeRPCValue,
                windows: @escaping @Sendable (String) -> [NativeRPCValue],
                accounts: (@Sendable () -> [NativeRPCValue])? = nil,
                taskWorkspaceFolders: (@Sendable () -> [String])? = nil,
                deviceFolders: (@Sendable (String) -> [String])? = nil,
                deviceStartSession: (@Sendable (NativeRPCValue, String) async throws -> NativeRPCValue)? = nil,
                tellWindow: (@Sendable (String, NativeRPCValue) -> Bool)? = nil,
                noteServerSettingsChanged: (@Sendable () -> Void)? = nil,
                readSessions: (@Sendable () -> [NativeRPCValue])? = nil,
                readScreen: (@Sendable (String) -> String?)? = nil,
                readScrollback: (@Sendable (String) -> String)? = nil) throws {
        guard (deviceFolders == nil) == (deviceStartSession == nil) else {
            throw NativeRPCError.invalidArguments("Device folder grants and the device-aware session starter must be supplied together.")
        }
        self.manager = manager; self.state = state; self.evidence = evidence; self.projectEvidence = projectEvidence; self.ownership = ownership
        start = startSession; input = writeToSession; close = closeSession; status = sessionStatus; bindingWindows = windows
        profileChoices = accounts; workspaceFolders = taskWorkspaceFolders; remoteFolders = deviceFolders; remoteStart = deviceStartSession
        self.tellWindow = tellWindow; self.noteServerSettingsChanged = noteServerSettingsChanged
        self.readSessions = readSessions; self.readScreen = readScreen; self.readScrollback = readScrollback
    }
    public func listSessions() -> [NativeRPCValue] {
        if let readSessions { return readSessions() }
        return manager.list().map { meta in
            // BackendSessionMeta's encoder owns the exact source field names.
            (try? NativeRPCValue.parseJSON(JSONEncoder().encode(meta))) ?? .object([.init("id", .string(meta.id)), .init("cwd", .string(meta.cwd)),
                .init("title", .string(meta.title)), .init("provider", .string(meta.provider)), .init("exitCode", meta.exitCode.map { .number(Double($0)) } ?? .null),
                .init("createdAt", .number(meta.createdAt)), .init("resumed", .bool(meta.resumed))])
        }
    }
    public func listProjects() -> [NativeRPCValue] { state.listProjects() }
    public func appStateRoot() -> String { state.appStateRoot() }
    public func copilotRoot() -> String { state.copilotRoot() }
    public func sessionStatus(_ sessionID: String) -> NativeRPCValue { let value = status(sessionID); return value == .missing ? .null : value }
    public func windows(sessionID: String) -> [NativeRPCValue] { bindingWindows(sessionID) }
    public func accounts() -> [NativeRPCValue]? { profileChoices?() }
    public func taskWorkspaceFolders() -> [String] { workspaceFolders?() ?? [] }
    public func deviceFolders(_ deviceID: String) -> [String]? { remoteFolders?(deviceID) }
    public func readSettings() -> NativeRPCValue { state.readSettings() }
    public func snapshotSettings() throws -> NativeRPCValue { try state.snapshotSettings(reason: "Hoot settings.write") }
    public func writeSettings(_ patch: NativeRPCValue) throws -> NativeRPCValue { try state.writeSettings(patch) }
    public func writePreferences(_ patch: NativeRPCValue) throws -> NativeRPCValue {
        let value = try state.writePreferences(patch); noteServerSettingsChanged?(); return value
    }
    public func snapshotSettingsAsync() async throws -> NativeRPCValue {
        if let writer = state as? any BackendCompositionSettingsWriting { return try await writer.snapshotSettingsAsync() }
        return try snapshotSettings()
    }
    public func writeSettingsAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue {
        if let writer = state as? any BackendCompositionSettingsWriting { return try await writer.writeSettingsAsync(patch) }
        return try writeSettings(patch)
    }
    public func writePreferencesAsync(_ patch: NativeRPCValue) async throws -> NativeRPCValue {
        if let writer = state as? any BackendCompositionSettingsWriting {
            let saved = try await writer.writePreferencesAsync(patch); noteServerSettingsChanged?(); return saved
        }
        return try writePreferences(patch)
    }
    public func applyToWindow(scope: String, values: NativeRPCValue) -> Bool {
        tellWindow?(scope == "settings" ? "settings:changed" : "prefs:changed", values) ?? false
    }
    public func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue {
        if let device = forDevice {
            guard let remoteStart else { throw BackendSessionFailure.missingCapability("the device-aware session starter") }
            return try await remoteStart(input, device)
        }
        return try await start(input)
    }
    public func writeToSession(_ sessionID: String, data: String) async throws { try await input(sessionID, data) }
    public func writeToSession(id: String, data: String) async throws { try await input(id, data) }
    public func killSession(_ sessionID: String) async throws { try await close(sessionID) }
    public func sessionScreen(_ sessionID: String) async throws -> String? { if let readScreen { return readScreen(sessionID) }; return manager.screen(sessionID) }
    public func sessionScreen(id: String) async throws -> String? { if let readScreen { return readScreen(id) }; return manager.screen(id) }
    public func sessionScrollback(_ sessionID: String) -> String { readScrollback?(sessionID) ?? manager.scrollback(sessionID) }
    public func transcriptsIn(cwd: String) async throws -> [NativeRPCValue] { try await evidence.transcriptsIn(cwd: cwd) }
    public func transcriptBytes(path: String) async throws -> Double { try await evidence.transcriptBytes(path: path) }
    public func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue] { try await evidence.readTranscriptFrom(path: path, fromByte: fromByte) }
    public func readToolTrail(path: String, windowBytes: Int) async throws -> BackendDeckCoreReportTrail { try await evidence.readToolTrail(path: path, windowBytes: windowBytes) }
    public func transcriptTotals(path: String) async throws -> NativeRPCValue? { try await evidence.transcriptTotals(path: path) }
    public func fileModifiedAt(path: String) async throws -> Double? { try await evidence.fileModifiedAt(path: path) }
    public func transcriptFor(session: NativeRPCValue) async throws -> NativeRPCValue { try await BackendDeckCoreReports.transcriptFor(surface: self, session: session) }
    public func reportOnSession(session: NativeRPCValue) async throws -> NativeRPCValue { try await BackendDeckCoreReports.session(surface: self, session: session) }
    public func reportOnFleet(sessions: [NativeRPCValue], since: Double?, limit: Int, now: Double) async throws -> NativeRPCValue {
        try await BackendDeckCoreReports.fleet(surface: self, sessions: sessions, since: since, limit: limit, now: now)
    }
    public func gitStatus(cwd: String) async throws -> NativeRPCValue { try await projectEvidence.gitStatus(cwd: cwd) }
    public func alerts(projectPath: String) async throws -> NativeRPCValue { try await projectEvidence.alerts(projectPath: projectPath) }
    public func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue {
        try await projectEvidence.collectFolderDiff(sessions: sessions, cwd: cwd, path: path, maxFiles: maxFiles)
    }
    public func gitChanges(cwd: String) async throws -> NativeRPCValue { Self.flattenStatus(try await gitStatus(cwd: cwd)) }
    public static func flattenStatus(_ status: NativeRPCValue) -> NativeRPCValue {
        guard status["repo"].bool == true else {
            return .object([.init("repo", .bool(false)), .init("root", .null), .init("branch", .null), .init("ahead", .number(0)), .init("behind", .number(0)),
                .init("files", .array([])), .init("reason", status["message"])])
        }
        let rows: [NativeRPCValue] = ["conflicted", "staged", "unstaged", "untracked"].flatMap { group in
            (status[group].elements ?? []).map { file in NativeRPCValue.object([.init("path", file["path"]), .init("group", .string(group)), .init("kind", file["kind"]),
                .init("insertions", file["insertions"]), .init("deletions", file["deletions"]), .init("binary", file["binary"])]) }
        }
        return .object([.init("repo", .bool(true)), .init("root", status["root"]), .init("branch", status["branch"]["name"]), .init("ahead", status["branch"]["ahead"]),
            .init("behind", status["branch"]["behind"]), .init("files", .array(rows)), .init("reason", .null)])
    }
    public func writeSpec(directory: String, input: NativeRPCValue) throws -> NativeRPCValue {
        try BackendDeckCoreBrief.writeSpec(directory: URL(fileURLWithPath: directory, isDirectory: true), input: input, ownership: ownership)
    }
    public func deliverBrief(_ sessionID: String, line: String) async throws -> NativeRPCValue {
        try await BackendDeckCoreBrief.deliver(surface: self, sessionID: sessionID, line: line)
    }
}
