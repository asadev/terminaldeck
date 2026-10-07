import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendArtifactScope: String, Sendable { case project, all }
public protocol BackendArtifactsTranscriptSource: Sendable {
    func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile]
    func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String
}

/// Account/device/home-scoped transcript discovery uses the shared native path
/// guard. The actual scope provider is required; this module never invents a
/// user's config/home directory or scans another account by default.
public struct BackendArtifactsNativeTranscriptSource: BackendArtifactsTranscriptSource, Sendable {
    private let scopes: @Sendable (String, BackendArtifactScope, NativeRPCContext) async throws -> [NativeTranscriptScope]
    public init(scopes: @escaping @Sendable (String, BackendArtifactScope, NativeRPCContext) async throws -> [NativeTranscriptScope]) { self.scopes = scopes }
    public func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] {
        let granted = try await scopes(project, scope, context)
        let task = Task.detached(priority: .utility) {
            var files: [String: NativeTranscriptFile] = [:]
            for grant in granted {
                try Task.checkCancellation()
                var directories = try NativeTranscriptPaths.projectDirectories(project, scope: grant)
                if scope == .all {
                    directories = []
                    for config in try NativeTranscriptPaths.configDirectories(grant) {
                        if let bound = grant.homeScopes.first(where: { NativeTranscriptPaths.canonical(URL(fileURLWithPath: $0.home).appendingPathComponent(".claude").path) == NativeTranscriptPaths.canonical(config) }) {
                            let restricted = NativeTranscriptScope(configDirectory: config, homeScopes: [bound], maximumDirectoryEntries: grant.maximumDirectoryEntries)
                            directories += try NativeTranscriptPaths.projectDirectories(bound.folder, scope: restricted)
                        } else {
                            let root = URL(fileURLWithPath: config).appendingPathComponent("projects", isDirectory: true)
                            if FileManager.default.fileExists(atPath: root.path) {
                                let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                guard entries.count <= grant.maximumDirectoryEntries else { throw NativeTranscriptPaths.Failure.directoryBudget }
                                directories += entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }.map(\.path)
                            }
                        }
                    }
                }
                for directory in directories {
                    try Task.checkCancellation()
                    for file in try NativeTranscriptPaths.listTranscripts(directory, scope: grant) { files[file.path] = file }
                }
            }
            return files.values.sorted { $0.modifiedAt > $1.modifiedAt }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String {
        for grant in try await scopes(project, scope, context) { if let path = try? NativeTranscriptPaths.assertTranscript(file.path, scope: grant) { return path } }
        throw NativeTranscriptPaths.Failure.outsideStore
    }
}

public struct BackendArtifactScanOptions: Sendable {
    public var scope: BackendArtifactScope = .project
    public var maxSessions = 40; public var maxArtifacts = 400; public var maxChanges = 60
    public var maxAgeMilliseconds = 90.0 * 24 * 60 * 60 * 1_000
    public var timeBudgetMilliseconds = 8_000
    /// The scan's notion of now; a test supplies one that is already past the deadline.
    public var clock: @Sendable () -> Date = { Date() }
    public init() {}
}

/// artifacts.ts's real JSONL index/history. Streaming reads, bounded line
/// buffers, 512-line deadline checks, independent owner/channel cancellation
/// slots, chronological merging and actual on-disk checks preserve evidence.
public actor BackendArtifactsIndex {
    private let source: any BackendArtifactsTranscriptSource
    private let authority: BackendFilesystemAuthority
    private struct Slot: Sendable { let id: UUID; let task: Task<NativeRPCValue, any Error> }
    private var slots: [String: Slot] = [:]
    public init(source: any BackendArtifactsTranscriptSource, authority: BackendFilesystemAuthority) { self.source = source; self.authority = authority }
    public func list(project: String, options: BackendArtifactScanOptions = BackendArtifactScanOptions(), context: NativeRPCContext) async throws -> NativeRPCValue {
        try await begin(project: project, relative: nil, options: options, context: context)
    }
    public func history(project: String, relative: String, options: BackendArtifactScanOptions = BackendArtifactScanOptions(), context: NativeRPCContext) async throws -> NativeRPCValue {
        guard let normalized = Self.relative(root: project, recorded: URL(fileURLWithPath: project).appendingPathComponent(relative).standardizedFileURL.path), !relative.hasPrefix("/"), !relative.contains("\0") else { throw NativeRPCError.invalidArguments("An artifact file must stay relative to its project") }
        return try await begin(project: project, relative: normalized, options: options, context: context)
    }
    public func cancel(ownerID: String) {
        for key in Array(slots.keys) where key.hasPrefix(ownerID + "\0") { slots.removeValue(forKey: key)?.task.cancel() }
    }
    public func stop() { slots.values.forEach { $0.task.cancel() }; slots.removeAll() }
    private func begin(project: String, relative: String?, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue {
        _ = try await authority.authorize(project, context: context)
        let key = context.ownerID + "\0" + (relative == nil ? "list" : "changes"), id = UUID()
        let started = options.clock()
        slots[key]?.task.cancel()
        let source = source
        let task = Task<NativeRPCValue, any Error> {
            let files = try await source.transcripts(project: project, scope: options.scope, context: context)
            let cutoff = options.maxAgeMilliseconds == 0 ? 0 : started.timeIntervalSince1970 * 1_000 - max(options.maxAgeMilliseconds, 1)
            let eligible = files.filter { $0.modifiedAt >= cutoff }.sorted { $0.modifiedAt > $1.modifiedAt }
            let selected = eligible.prefix(min(max(options.maxSessions, 1), 400))
            var granted: [NativeTranscriptFile] = []
            for file in selected { _ = try await source.authorizedPath(file, project: project, scope: options.scope, context: context); granted.append(file) }
            let initialTruncation = eligible.count > selected.count
            let work = Task.detached(priority: .utility) { try Self.scan(project: project, relative: relative, files: granted, options: options, started: started, initialTruncation: initialTruncation) }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        slots[key] = Slot(id: id, task: task)
        defer { if slots[key]?.id == id { slots[key] = nil } }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        _ = try await authority.authorize(project, context: context)
        return value
    }
    public struct Touch: Sendable {
        public let path: String; public let action: String; public let at: Double; public let before: String; public let after: String; public let replaceAll: Bool; public let tool: String
    }
    /// artifacts.ts `mayCarryFileWrite`: the cheap gate in front of parsing a transcript line.
    public static func mayCarryFileWrite(_ line: String) -> Bool {
        line.contains("\"tool_use\"") && (line.contains("\"file_path\"") || line.contains("\"notebook_path\""))
    }
    public static func touches(_ line: String) -> [Touch] {
        guard mayCarryFileWrite(line),
              let value = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 16 * 1024 * 1024), let blocks = value["message"]["content"].elements else { return [] }
        let at: Double
        if let timestamp = value["timestamp"].string {
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            at = (fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp))?.timeIntervalSince1970.mapMilliseconds ?? 0
        } else { at = 0 }
        return blocks.compactMap { block in
            guard block["type"].string == "tool_use", let tool = block["name"].string, ["Write", "Edit", "NotebookEdit"].contains(tool) else { return nil }
            let input = block["input"], path = input[tool == "NotebookEdit" ? "notebook_path" : "file_path"].string ?? ""
            guard path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil else { return nil }
            return Touch(path: path, action: tool == "Write" ? "write" : "edit", at: at,
                before: tool == "Edit" ? input["old_string"].string ?? "" : "",
                after: input[tool == "Write" ? "content" : tool == "NotebookEdit" ? "new_source" : "new_string"].string ?? "",
                replaceAll: input["replace_all"].bool == true, tool: tool)
        }
    }
    public static func relative(root: String, recorded: String) -> String? {
        guard recorded.hasPrefix("/") else { return nil } // Foreign Windows absolute paths are not invented under this Mac root.
        let root = URL(fileURLWithPath: root).standardizedFileURL, path = URL(fileURLWithPath: recorded).standardizedFileURL
        guard path != root, BackendFilesystemAuthority.within(path, root) else { return nil }
        return BackendFilesystemAuthority.relative(path, to: root)
    }
    private struct Built {
        var first: Double; var last = 0.0; var writes = 0; var edits = 0; var chars = 0; var tool: String; var sessions: [String: Double] = [:]
    }
    private static func scan(project: String, relative: String?, files: [NativeTranscriptFile], options: BackendArtifactScanOptions, started: Date, initialTruncation: Bool) throws -> NativeRPCValue {
        let root = URL(fileURLWithPath: project).standardizedFileURL.path
        let maxSessions = min(max(options.maxSessions, 1), 400), maxArtifacts = min(max(options.maxArtifacts, 1), 2_000), maxChanges = min(max(options.maxChanges, 1), 500)
        let deadline = started.addingTimeInterval(Double(min(max(options.timeBudgetMilliseconds, 1), 120_000)) / 1_000)
        let cutoff = options.maxAgeMilliseconds == 0 ? 0 : started.timeIntervalSince1970 * 1_000 - max(options.maxAgeMilliseconds, 1)
        let available = files.filter { $0.modifiedAt >= cutoff }, selected = available.prefix(maxSessions)
        var truncated = initialTruncation || available.count > selected.count, scanned = 0, outside = 0, built: [String: Built] = [:], sessions: [String: (at: Double, paths: Set<String>)] = [:]
        var changes: [NativeRPCValue] = [], totalChanges = 0
        for file in selected {
            try Task.checkCancellation()
            if options.clock() > deadline { truncated = true; break }
            let path = URL(fileURLWithPath: file.path)
            let target = BackendFilesystemAuthority.Target(root: path.deletingLastPathComponent(), path: path, relative: path.lastPathComponent)
            let descriptor = try BackendFilesystemAuthority.openStable(target)
            defer { Darwin.close(descriptor) }
            var openedName = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &openedName) == 0,
                  URL(fileURLWithPath: String(cString: openedName)).standardizedFileURL.path == path.standardizedFileURL.path else {
                throw NativeTranscriptPaths.Failure.outsideStore
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024), pending = Data(), lineCount = 0, budgetEnded = false, dropping = false
            func consume(_ bytes: Data) throws {
                lineCount += 1
                if lineCount % 512 == 0 { try Task.checkCancellation(); if options.clock() > deadline { budgetEnded = true; return } }
                guard let line = String(data: bytes, encoding: .utf8) else { return }
                for parsed in touches(line) {
                    let at = parsed.at > 0 ? parsed.at : file.modifiedAt
                    guard let rel = Self.relative(root: root, recorded: parsed.path) else { outside += 1; continue }
                    if let relative {
                        guard rel == relative else { continue }; totalChanges += 1
                        let before = String(decoding: parsed.before.utf16.prefix(24_000), as: UTF16.self), after = String(decoding: parsed.after.utf16.prefix(24_000), as: UTF16.self)
                        changes.append(.object([.init("at", .number(at)), .init("sessionId", .string(file.sessionID)), .init("action", .string(parsed.action)), .init("tool", .string(parsed.tool)),
                            .init("before", .string(before)), .init("after", .string(after)), .init("replaceAll", .bool(parsed.replaceAll)), .init("clipped", .bool(parsed.before.utf16.count > 24_000 || parsed.after.utf16.count > 24_000))]))
                        if changes.count > maxChanges * 2 { changes.sort { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }; changes = Array(changes.prefix(maxChanges)) }
                    } else {
                        var entry = built[rel] ?? Built(first: at, tool: parsed.tool)
                        if parsed.action == "write" { entry.writes += 1 } else { entry.edits += 1 }
                        if at < entry.first || entry.first == 0 { entry.first = at }
                        if at >= entry.last { entry.last = at; entry.chars = parsed.after.utf16.count; entry.tool = parsed.tool }
                        entry.sessions[file.sessionID] = max(entry.sessions[file.sessionID] ?? 0, at); built[rel] = entry
                        var session = sessions[file.sessionID] ?? (0, Set<String>()); session.paths.insert(rel); session.at = max(session.at, at); sessions[file.sessionID] = session
                    }
                }
            }
            while !budgetEnded {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count == 0 { if !pending.isEmpty && !dropping { try consume(pending) }; break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeRPCError(code: "artifacts", message: "An approved transcript could not be read") }
                for byte in buffer.prefix(count) {
                    if byte == 10 { if !dropping { try consume(pending) }; pending.removeAll(keepingCapacity: true); dropping = false; if budgetEnded { break } }
                    else if !dropping {
                        pending.append(byte)
                        if pending.count > 16 * 1024 * 1024 { dropping = true; pending.removeAll(keepingCapacity: false); truncated = true }
                    }
                }
                if options.clock() > deadline { budgetEnded = true }
            }
            scanned += 1
            if budgetEnded { truncated = true; break }
        }
        let elapsed = options.clock().timeIntervalSince(started) * 1_000
        if let relative {
            changes.sort { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }
            return .object([.init("root", .string(root)), .init("relPath", .string(relative)), .init("changes", .array(Array(changes.prefix(maxChanges)))),
                .init("totalChanges", .number(Double(totalChanges))), .init("truncated", .bool(truncated || totalChanges > maxChanges)), .init("cancelled", .bool(false)), .init("tookMs", .number(elapsed))])
        }
        let ordered = built.sorted { $0.value.last > $1.value.last }, kept = ordered.prefix(maxArtifacts)
        var artifacts: [NativeRPCValue] = []
        for (index, pair) in kept.enumerated() {
            try Task.checkCancellation()
            let (path, value) = pair; var disk = NativeRPCValue.null
            if index < 600 {
                let file = URL(fileURLWithPath: root).appendingPathComponent(path)
                if let real = try? BackendFilesystemAuthority.canonical(file), BackendFilesystemAuthority.within(real, URL(fileURLWithPath: root)),
                   let info = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), info.isRegularFile == true,
                   let bytes = info.fileSize, let date = info.contentModificationDate { disk = .object([.init("bytes", .number(Double(bytes))), .init("modifiedAt", .number(date.timeIntervalSince1970 * 1_000))]) }
            }
            artifacts.append(.object([.init("relPath", .string(path)), .init("name", .string(URL(fileURLWithPath: path).lastPathComponent)), .init("firstAt", .number(value.first)), .init("lastAt", .number(value.last)),
                .init("writes", .number(Double(value.writes))), .init("edits", .number(Double(value.edits))), .init("lastChars", .number(Double(value.chars))), .init("lastTool", .string(value.tool)),
                .init("sessionIds", .array(value.sessions.sorted { $0.value > $1.value }.map { .string($0.key) })), .init("onDisk", disk)]))
        }
        let sessionRows = sessions.sorted { $0.value.at > $1.value.at }.map { id, value in NativeRPCValue.object([.init("sessionId", .string(id)), .init("at", .number(value.at)), .init("files", .number(Double(value.paths.count)))]) }
        return .object([.init("root", .string(root)), .init("scope", .string(options.scope.rawValue)), .init("artifacts", .array(artifacts)), .init("sessions", .array(sessionRows)),
            .init("sessionsScanned", .number(Double(scanned))), .init("outsideProject", .number(Double(outside))), .init("truncated", .bool(truncated || ordered.count > kept.count)), .init("cancelled", .bool(false)), .init("tookMs", .number(elapsed))])
    }
}

private extension TimeInterval { var mapMilliseconds: Double { self * 1_000 } }
