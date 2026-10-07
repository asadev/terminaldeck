import Foundation
import Darwin
import TerminalDeckNativeCore

/// Uses existing native parsers and account-approved transcript scopes. Scope
/// providers are privileged composition inputs; tool arguments cannot widen them.
public struct BackendDeckCoreNativeEvidence: BackendDeckCoreEvidenceReader, Sendable {
    public let scopeForProject: @Sendable (String) async throws -> NativeTranscriptScope
    public let scopeForPath: @Sendable (String) async throws -> NativeTranscriptScope
    public init(scopeForProject: @escaping @Sendable (String) async throws -> NativeTranscriptScope,
                scopeForPath: @escaping @Sendable (String) async throws -> NativeTranscriptScope) {
        self.scopeForProject = scopeForProject; self.scopeForPath = scopeForPath
    }
    public func transcriptsIn(cwd: String) async throws -> [NativeRPCValue] {
        let scope = try await scopeForProject(cwd)
        var files: [NativeRPCValue] = []
        for directory in try NativeTranscriptPaths.projectDirectories(cwd, scope: scope) {
            for file in try NativeTranscriptPaths.listTranscripts(directory, scope: scope) {
                files.append(.object([.init("path", .string(file.path)), .init("sessionId", .string(file.sessionID)),
                    .init("createdAt", .number(file.createdAt)), .init("modifiedAt", .number(file.modifiedAt)), .init("bytes", .number(Double(file.bytes)))]))
            }
        }
        return files
    }
    public func transcriptBytes(path: String) async throws -> Double {
        let scope = try await scopeForPath(path), approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        do {
            let (fd, info) = try BackendUsageIO.openChecked(approved, roots: NativeTranscriptPaths.approvedRoots(scope)); Darwin.close(fd)
            return Double(info.st_size)
        } catch let error as POSIXError where error.code == .ENOENT { return 0 }
    }
    public func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue] {
        let scope = try await scopeForPath(path), approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        guard fromByte.isFinite, fromByte >= 0, fromByte < Double(Int64.max) else { throw NativeRPCError.invalidArguments("Transcript offset is outside the byte range.") }
        let reader = NativeChatTranscriptReader(path: approved, startAt: Int64(fromByte), allowedRoots: try NativeTranscriptPaths.approvedRoots(scope))
        let read = try await reader.readAll(wholeConversation: true)
        return read.messages.map { .object([.init("id", .string($0.id)), .init("role", .string($0.role.rawValue)), .init("at", .number($0.at)), .init("text", .string($0.text)), .init("truncated", .bool(false))]) }
    }
    public func readToolTrail(path: String, windowBytes: Int) async throws -> BackendDeckCoreReportTrail {
        let scope = try await scopeForPath(path), approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        var transcript = BackendCostTranscript(path: approved, sessionID: URL(fileURLWithPath: approved).deletingPathExtension().lastPathComponent, cwd: "")
        let fd: Int32, info: stat
        do { (fd, info) = try BackendUsageIO.openChecked(approved, roots: NativeTranscriptPaths.approvedRoots(scope)) }
        catch let error as POSIXError where error.code == .ENOENT {
            return .init(transcript: transcript, fileBytes: 0, fromByte: 0)
        }
        defer { Darwin.close(fd) }
        let size = max(0, Int(info.st_size)), from = max(0, size - max(0, windowBytes))
        guard lseek(fd, off_t(from), SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        var bytes = Data(count: size - from), readCount = 0
        try bytes.withUnsafeMutableBytes { raw in
            while readCount < raw.count {
                try Task.checkCancellation()
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: readCount), raw.count - readCount)
                if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; readCount += n
            }
        }
        bytes.count = readCount
        // The whole bounded trail is needed around a compaction; the general
        // cost reader intentionally retains only 1,000 calls. Keep these source
        // facts in the existing native transcript/call types without that cap.
        transcript = try Self.parseToolTrail(String(decoding: bytes, as: UTF8.self), path: approved)
        transcript.readBytes = readCount
        return .init(transcript: transcript, fileBytes: Double(size), fromByte: Double(from))
    }
    static func parseToolTrail(_ text: String, path: String) throws -> BackendCostTranscript {
        var transcript = BackendCostTranscript(path: path, sessionID: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, cwd: "")
        var failures: [String: Bool] = [:]
        for line in text.components(separatedBy: "\n") {
            try Task.checkCancellation()
            guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: BackendUsageIO.maximumLineBytes), raw.fields != nil,
                  raw["type"].string != nil else { continue }
            let at = BackendUsageIO.timestamp(raw["timestamp"])
            if raw["type"].string == "system", raw["subtype"].string == "compact_boundary" {
                // Reuse the native compaction normalizer; its other summary
                // fields are not read by the progress port.
                var compact = BackendCostTranscript(path: path, sessionID: transcript.sessionID, cwd: "")
                try compact.consume(line); transcript.compactions += compact.compactions
                continue
            }
            for block in raw["message"]["content"].elements ?? [] {
                if block["type"].string == "tool_use", let id = block["id"].string, !id.isEmpty, let name = block["name"].string, !name.isEmpty {
                    transcript.toolTrail.append(.init(id: id, name: name, at: at, failed: nil))
                } else if block["type"].string == "tool_result", let id = block["tool_use_id"].string, !id.isEmpty {
                    failures[id] = block["is_error"].bool == true
                }
            }
        }
        for index in transcript.toolTrail.indices { transcript.toolTrail[index].failed = failures[transcript.toolTrail[index].id] }
        return transcript
    }
    public func transcriptTotals(path: String) async throws -> NativeRPCValue? {
        let scope = try await scopeForPath(path)
        do { return try await BackendCostTranscript.read(path: path, scope: scope).summary }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
    public func fileModifiedAt(path: String) async throws -> Double? {
        do {
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            return values.isRegularFile == true ? values.contentModificationDate.map { $0.timeIntervalSince1970 * 1000 } : nil
        } catch { return nil }
    }
}

/// alerts.ts `collectAlertInput`/`deriveAlerts` as the deck-control surface
/// reads them. The panel's own BackendAlertsService is the real reader (and the
/// default below); the protocol only lets the evidence adapter be held without
/// the whole metrics graph (S1i: live-surface.test.ts git cases).
public protocol BackendDeckCoreProjectAlertsReading: Sendable {
    func deckCoreProjectAlerts(_ projectPath: String, context: NativeRPCContext) async throws -> NativeRPCValue
}
extension BackendAlertsService: BackendDeckCoreProjectAlertsReading {
    public func deckCoreProjectAlerts(_ projectPath: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        try await project(projectPath, context: context)
    }
}

public struct BackendDeckCoreNativeProjectEvidence: BackendDeckCoreProjectEvidence, Sendable {
    private let git: BackendGitService
    private let alertsService: any BackendDeckCoreProjectAlertsReading
    private let context: @Sendable () -> NativeRPCContext
    private let attributedDiff: (@Sendable ([NativeRPCValue], String, String?, Int) async throws -> NativeRPCValue)?
    public init(git: BackendGitService, alerts: BackendAlertsService, context: @escaping @Sendable () -> NativeRPCContext,
                attributedDiff: (@Sendable ([NativeRPCValue], String, String?, Int) async throws -> NativeRPCValue)? = nil) {
        self.init(git: git, alertsReader: alerts, context: context, attributedDiff: attributedDiff)
    }
    /// The same adapter over any alerts reader (additive; the init above passes
    /// the real BackendAlertsService, unchanged).
    public init(git: BackendGitService, alertsReader: any BackendDeckCoreProjectAlertsReading, context: @escaping @Sendable () -> NativeRPCContext,
                attributedDiff: (@Sendable ([NativeRPCValue], String, String?, Int) async throws -> NativeRPCValue)? = nil) {
        self.git = git; alertsService = alertsReader; self.context = context; self.attributedDiff = attributedDiff
    }
    public func gitStatus(cwd: String) async throws -> NativeRPCValue { try await git.status(cwd: cwd, context: context()) }
    public func alerts(projectPath: String) async throws -> NativeRPCValue { try await alertsService.deckCoreProjectAlerts(projectPath, context: context()) }
    public func collectFolderDiff(sessions: [NativeRPCValue], cwd: String, path: String?, maxFiles: Int) async throws -> NativeRPCValue {
        if let attributedDiff { return try await attributedDiff(sessions, cwd, path, maxFiles) }
        let review = BackendGitReview(git: git, sessionViews: { sessions })
        return try await BackendDeckToolsFleetDiff.collect(review: review, cwd: cwd, path: path, maxFiles: maxFiles, context: context())
    }
}
