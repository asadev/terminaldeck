import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendArtifactScope: String, Sendable { case project, all }
/// What a source found, and what it could not read on the way. A folder or a session history that
/// cannot be read is left out and named here; it is never a reason for the whole list to fail.
public struct BackendArtifactsListing: Sendable {
    public var files: [NativeTranscriptFile]
    public var skipped: [String]
    public init(files: [NativeTranscriptFile], skipped: [String] = []) { self.files = files; self.skipped = skipped }
}
public protocol BackendArtifactsTranscriptSource: Sendable {
    func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile]
    func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String
    /// `transcripts`, with what was skipped. A source that cannot tell reports nothing skipped.
    func listing(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> BackendArtifactsListing
}
public extension BackendArtifactsTranscriptSource {
    func listing(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> BackendArtifactsListing {
        BackendArtifactsListing(files: try await transcripts(project: project, scope: scope, context: context))
    }
}

/// Account/device/home-scoped transcript discovery uses the shared native path
/// guard. The actual scope provider is required; this module never invents a
/// user's config/home directory or scans another account by default.
public struct BackendArtifactsNativeTranscriptSource: BackendArtifactsTranscriptSource, Sendable {
    private let scopes: @Sendable (String, BackendArtifactScope, NativeRPCContext) async throws -> [NativeTranscriptScope]
    public init(scopes: @escaping @Sendable (String, BackendArtifactScope, NativeRPCContext) async throws -> [NativeTranscriptScope]) { self.scopes = scopes }
    public func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] {
        try await listing(project: project, scope: scope, context: context).files
    }
    public func listing(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> BackendArtifactsListing {
        let granted = try await scopes(project, scope, context)
        let task = Task.detached(priority: .utility) {
            var files: [String: NativeTranscriptFile] = [:], skipped: [String] = []
            for grant in granted {
                try Task.checkCancellation()
                var directories = try NativeTranscriptPaths.projectDirectories(project, scope: grant)
                if scope == .all {
                    directories = []
                    var roots = Set<String>()
                    for config in try NativeTranscriptPaths.configDirectories(grant) {
                        if let bound = grant.homeScopes.first(where: { NativeTranscriptPaths.canonical(URL(fileURLWithPath: $0.home).appendingPathComponent(".claude").path) == NativeTranscriptPaths.canonical(config) }) {
                            let restricted = NativeTranscriptScope(configDirectory: config, homeScopes: [bound], maximumDirectoryEntries: grant.maximumDirectoryEntries)
                            directories += try NativeTranscriptPaths.projectDirectories(bound.folder, scope: restricted)
                        } else {
                            // A second account's history folder is usually a LINK to the shared one. Listing the link
                            // itself fails ("Not a directory"), and that one failure used to fail every project's list.
                            // The folder is read where it really is (the place `approvedRoots` approves), once however
                            // many accounts point at it; one that cannot be read is skipped and named.
                            let root = NativeTranscriptPaths.canonical(URL(fileURLWithPath: config).appendingPathComponent("projects").path)
                            var isDirectory: ObjCBool = false
                            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue, roots.insert(root).inserted else { continue }
                            do {
                                let entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                guard entries.count <= grant.maximumDirectoryEntries else { throw NativeTranscriptPaths.Failure.directoryBudget }
                                directories += entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false }.map(\.path)
                            } catch { skipped.append(root) }
                        }
                    }
                }
                for directory in directories {
                    try Task.checkCancellation()
                    do { for file in try NativeTranscriptPaths.listTranscripts(directory, scope: grant) { files[file.path] = file } }
                    catch { skipped.append(directory) }
                }
            }
            return BackendArtifactsListing(files: files.values.sorted { $0.modifiedAt > $1.modifiedAt }, skipped: Array(Set(skipped)).sorted())
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
    /// Keep only what the Artifacts page calls an artifact (`ArtifactRules.isArtifact`: pages, pictures,
    /// PDFs, recordings), decided before `maxArtifacts` is taken, so notes and source never crowd them out.
    public var onlyArtifacts = false
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
    private var projectResolver: @Sendable (String) async throws -> String = { PROJProjects.resolve(projectID: nil, folder: $0) }
    private var sessionProjectResolver: @Sendable (String, String) async throws -> String? = { _, _ in nil }
    public func bindProjectResolver(_ resolver: @escaping @Sendable (String) async throws -> String) { projectResolver = resolver }
    /// Current transcript discovery and tool-use decoding are Claude-only.
    /// The owner may return a trusted explicit project for this provider and
    /// conversation id; an absent or ambiguous match uses file ownership.
    public func bindSessionProjectResolver(_ resolver: @escaping @Sendable (String, String) async throws -> String?) { sessionProjectResolver = resolver }
    /// Paths already named in the log as unreadable, so a page that re-reads does not repeat them.
    private var loggedSkips = Set<String>()
    /// A short stable mark for a path (FNV-1a), to count one unreadable history once without sending its path.
    static func mark(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }
    private var registeredFolders: @Sendable () async throws -> [String] = { [] }
    /// The folders of the app's registered projects, read from the projects registry each time it is asked.
    /// The Artifacts page lists a registered project's work whether or not a session is open in its folder.
    public func bindRegisteredFolders(_ folders: @escaping @Sendable () async throws -> [String]) { registeredFolders = folders }
    /// Whether this is exactly one of a registered project's own folders (not a folder inside or above one).
    /// It admits the artifacts scan only; every other file door keeps asking for an open folder.
    public func isRegisteredFolder(_ path: String) async -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let asked = PROJProjects.normalize(path), supplier = registeredFolders
        guard !asked.isEmpty, asked != "/", let folders = try? await supplier() else { return false }
        return folders.contains { PROJProjects.normalize($0) == asked }
    }
    /// The person's home folder, only to word where an outside file is ("Downloads"); never read or scanned.
    private let home: String
    public init(source: any BackendArtifactsTranscriptSource, authority: BackendFilesystemAuthority, home: String = NSHomeDirectory()) {
        self.source = source; self.authority = authority; self.home = home
    }
    public func list(project: String, options: BackendArtifactScanOptions = BackendArtifactScanOptions(), context: NativeRPCContext) async throws -> NativeRPCValue {
        try await begin(project: project, relative: nil, options: options, context: context)
    }
    public func history(project: String, relative: String, options: BackendArtifactScanOptions = BackendArtifactScanOptions(), context: NativeRPCContext) async throws -> NativeRPCValue {
        // An outside row is named by its recorded absolute path; only an artifact file can be one.
        if relative.hasPrefix("/") {
            guard !relative.contains("\0"), ArtifactRules.isArtifact(relative), Self.relative(root: project, recorded: relative) == nil else { throw NativeRPCError.invalidArguments("An artifact file must stay relative to its project") }
            return try await begin(project: project, relative: URL(fileURLWithPath: relative).standardizedFileURL.path, options: options, context: context)
        }
        guard let normalized = Self.relative(root: project, recorded: URL(fileURLWithPath: project).appendingPathComponent(relative).standardizedFileURL.path), !relative.hasPrefix("/"), !relative.contains("\0") else { throw NativeRPCError.invalidArguments("An artifact file must stay relative to its project") }
        return try await begin(project: project, relative: normalized, options: options, context: context)
    }
    public func cancel(ownerID: String) {
        for key in Array(slots.keys) where key.hasPrefix(ownerID + "\0") { slots.removeValue(forKey: key)?.task.cancel() }
    }
    public func stop() { slots.values.forEach { $0.task.cancel() }; slots.removeAll() }
    private func begin(project: String, relative: String?, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue {
        // The engine owns the whole request's budget, including discovery, grants and identity lookup.
        try await withThrowingTaskGroup(of: NativeRPCValue.self) { group in
            group.addTask { try await self.read(project: project, relative: relative, options: options, context: context) }
            group.addTask {
                try await Task.sleep(for: .milliseconds(min(max(options.timeBudgetMilliseconds, 1), 120_000)))
                throw NativeRPCError(code: "artifacts-timeout", message: "History reading reached its time limit. Try a smaller scope.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func read(project: String, relative: String?, options: BackendArtifactScanOptions, context: NativeRPCContext) async throws -> NativeRPCValue {
        _ = try await authority.authorize(project, context: context)
        let key = context.ownerID + "\0" + (relative == nil ? "list" : "changes"), id = UUID()
        let started = options.clock()
        slots[key]?.task.cancel()
        let source = source, sessionResolver = sessionProjectResolver, home = home
        var sessionProjects: [String: String] = [:]
        let task = Task<NativeRPCValue, any Error> {
            let listing = try await source.listing(project: project, scope: options.scope, context: context)
            let files = listing.files
            var skipped = listing.skipped
            let cutoff = options.maxAgeMilliseconds == 0 ? 0 : started.timeIntervalSince1970 * 1_000 - max(options.maxAgeMilliseconds, 1)
            var eligible = files.filter { $0.modifiedAt >= cutoff }.sorted { $0.modifiedAt > $1.modifiedAt }
            // Every session on the Mac is far more than one scan reads. The project's own sessions go first,
            // so a busy neighbour cannot push them past the session and time budgets.
            if options.scope == .all { eligible = Self.ownFirst(eligible, project: project) }
            let selected = eligible.prefix(min(max(options.maxSessions, 1), 400))
            var granted: [NativeTranscriptFile] = []
            for file in selected {
                // One history that is no longer approved is left out (it is not read); the rest are listed.
                do { _ = try await source.authorizedPath(file, project: project, scope: options.scope, context: context); granted.append(file) }
                catch is CancellationError { throw CancellationError() }
                catch { skipped.append(file.path) }
            }
            let initialTruncation = eligible.count > selected.count, unread = skipped
            let work = Task.detached(priority: .utility) { try Self.scan(project: project, relative: relative, files: granted, options: options, started: started, initialTruncation: initialTruncation, home: home, skipped: unread) }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        slots[key] = Slot(id: id, task: task)
        defer { if slots[key]?.id == id { slots[key] = nil } }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        _ = try await authority.authorize(project, context: context)
        // The scan only reports conversation ids from authorized transcripts.
        for id in value["sessionIds"].elements?.compactMap(\.string) ?? [] {
            try Task.checkCancellation()
            if let explicit = try await sessionResolver("claude", id), PROJProjects.isValidID(explicit) { sessionProjects[id] = explicit }
        }
        let identities = sessionProjects, resolveFolder = projectResolver
        let root = value["root"].string ?? project
        // An outside row's `relPath` is already the recorded absolute path.
        func path(_ relative: String) -> String { ArtifactRules.isOutside(relative) ? relative : URL(fileURLWithPath: root).appendingPathComponent(relative).standardizedFileURL.path }
        func folder(_ relative: String) -> String { URL(fileURLWithPath: path(relative)).deletingLastPathComponent().path }
        // Which project owns a folder is asked only for folders inside this one. A file a session made
        // outside it belongs to the project that session was working in: this one.
        func owner(_ relative: String) -> String { ArtifactRules.isOutside(relative) ? root : folder(relative) }
        var folders = Set<String>([root])
        for row in value["artifacts"].elements ?? [] { folders.insert(owner(row["relPath"].string ?? "")) }
        if let relative = value["relPath"].string { folders.insert(owner(relative)) }
        for row in value["sessions"].elements ?? [] {
            for relative in row["relPaths"].elements?.compactMap(\.string) ?? [] { folders.insert(owner(relative)) }
        }
        var resolved: [String: String] = [:]
        for folder in folders { try Task.checkCancellation(); resolved[folder] = try await resolveFolder(folder) }
        // Resolve once per folder, then project rows synchronously from immutable
        // values. Large transcripts need no actor hop per touched file.
        let folderProjects = resolved
        func owned(_ row: NativeRPCValue, relative: String, writer: String?) -> NativeRPCValue {
            let folder = folder(relative)
            let explicit = writer.flatMap { identities[$0] }
            let id = explicit ?? folderProjects[owner(relative)] ?? PROJProjects.independentID
            return row.setting("projectId", .string(id)).setting("projectIdInferred", .bool(explicit == nil))
                .setting("folder", .string(folder)).setting("root", .string(root))
        }
        // What could not be read is named in the log, once; the answer carries how many and a short mark for
        // each (so a page reading several folders counts one history once), never the paths themselves.
        let unreadable = value["skippedPaths"].elements?.compactMap(\.string) ?? []
        for path in unreadable where loggedSkips.insert(path).inserted { NSLog("[artifacts] skipped, could not be read: %@", path) }
        var output = value.removing("sessionIds").removing("skippedPaths").setting("projectId", .string(folderProjects[root] ?? PROJProjects.independentID))
        if !unreadable.isEmpty {
            output = output.setting("sessionsSkipped", .number(Double(unreadable.count))).setting("skippedKeys", .array(unreadable.map { .string(Self.mark($0)) }))
        }
        if let rows = value["artifacts"].elements {
            var artifacts: [NativeRPCValue] = []
            for row in rows {
                try Task.checkCancellation()
                artifacts.append(owned(row, relative: row["relPath"].string ?? "", writer: row["sessionIds"].elements?.first?.string))
            }
            output = output.setting("artifacts", .array(artifacts))
        }
        if let rows = value["changes"].elements {
            var changes: [NativeRPCValue] = []
            let relative = value["relPath"].string ?? ""
            for row in rows { changes.append(owned(row, relative: relative, writer: row["sessionId"].string)) }
            output = output.setting("changes", .array(changes))
            let id: String
            if let first = changes.first?["projectId"].string { id = first }
            else { id = folderProjects[owner(relative)] ?? PROJProjects.independentID }
            output = output.setting("projectId", .string(id)).setting("projectIds", .array(Array(Set(changes.compactMap { $0["projectId"].string })).sorted().map(NativeRPCValue.string)))
        }
        if let rows = value["sessions"].elements {
            var sessions: [NativeRPCValue] = []
            for row in rows {
                var groups: [String: [String]] = [:], folders: [String: String] = [:]
                let explicit = row["sessionId"].string.flatMap { identities[$0] }
                for relative in row["relPaths"].elements?.compactMap(\.string) ?? [] {
                    let folder = folder(relative)
                    let id = explicit ?? folderProjects[owner(relative)] ?? PROJProjects.independentID
                    groups[id, default: []].append(relative); folders[id] = folder
                }
                for id in groups.keys.sorted() {
                    sessions.append(row.removing("relPaths").setting("files", .number(Double(groups[id]!.count)))
                        .setting("projectId", .string(id)).setting("projectIdInferred", .bool(explicit == nil))
                        .setting("folder", .string(folders[id]!)).setting("root", .string(root)))
                }
            }
            output = output.setting("sessions", .array(sessions))
        }
        return output
    }
    public struct Touch: Sendable {
        public let path: String; public let action: String; public let at: Double; public let before: String; public let after: String; public let replaceAll: Bool; public let tool: String
        /// The folder the session was working in when it made this call ("" where the line carries none).
        public let cwd: String
        /// Handed over or saved whole without the Write tool (`action` is then "handoff"): a published page, a sent file, a screenshot.
        public var isHandoff: Bool { action == "handoff" }
    }
    /// artifacts.ts `mayCarryFileWrite`: the cheap gate in front of parsing a transcript line.
    public static func mayCarryFileWrite(_ line: String) -> Bool {
        line.contains("\"tool_use\"") && (line.contains("\"file_path\"") || line.contains("\"notebook_path\""))
    }
    /// What the writing tools did to files on this line: Write, Edit and NotebookEdit, nothing else.
    public static func touches(_ line: String) -> [Touch] {
        guard mayCarryFileWrite(line) else { return [] }
        return records(line).filter { !$0.isHandoff }
    }
    /// Everything a line records about files a session made: the writing tools, and the artifact files a
    /// tool handed over or saved whole without them (`ArtifactRules.handedOver`). Shell commands are not read.
    public static func records(_ line: String) -> [Touch] {
        guard line.contains("\"tool_use\""),
              let value = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: 16 * 1024 * 1024), let blocks = value["message"]["content"].elements else { return [] }
        let at: Double
        if let timestamp = value["timestamp"].string {
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            at = (fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp))?.timeIntervalSince1970.mapMilliseconds ?? 0
        } else { at = 0 }
        let cwd = value["cwd"].string ?? ""
        var found: [Touch] = []
        for block in blocks {
            guard block["type"].string == "tool_use", let tool = block["name"].string else { continue }
            let input = block["input"]
            guard ["Write", "Edit", "NotebookEdit"].contains(tool) else {
                for path in ArtifactRules.handedOver(tool: tool, string: { input[$0].string }, strings: { input[$0].elements?.compactMap(\.string) ?? [] }) {
                    found.append(Touch(path: path, action: "handoff", at: at, before: "", after: "", replaceAll: false, tool: tool, cwd: cwd))
                }
                continue
            }
            let path = input[tool == "NotebookEdit" ? "notebook_path" : "file_path"].string ?? ""
            guard path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil else { continue }
            found.append(Touch(path: path, action: tool == "Write" ? "write" : "edit", at: at,
                before: tool == "Edit" ? input["old_string"].string ?? "" : "",
                after: input[tool == "Write" ? "content" : tool == "NotebookEdit" ? "new_source" : "new_string"].string ?? "",
                replaceAll: input["replace_all"].bool == true, tool: tool, cwd: cwd))
        }
        return found
    }
    public static func relative(root: String, recorded: String) -> String? {
        guard recorded.hasPrefix("/") else { return nil } // Foreign Windows absolute paths are not invented under this Mac root.
        let root = URL(fileURLWithPath: root).standardizedFileURL, path = URL(fileURLWithPath: recorded).standardizedFileURL
        guard path != root, BackendFilesystemAuthority.within(path, root) else { return nil }
        return BackendFilesystemAuthority.relative(path, to: root)
    }
    /// Whether the session was this project's when it made the call: it was working inside the project
    /// folder. A line that carries no folder (older transcripts) counts only when the transcripts being
    /// read are the project's own.
    public static func isOwn(cwd: String, root: String, scope: BackendArtifactScope) -> Bool {
        guard !cwd.isEmpty else { return scope == .project }
        guard cwd.hasPrefix("/") else { return false }
        return BackendFilesystemAuthority.within(URL(fileURLWithPath: cwd).standardizedFileURL, URL(fileURLWithPath: root).standardizedFileURL)
    }
    /// The recorded path of an artifact file this project's own session made **outside** the project
    /// folder, or nil. Notes, source and data outside the folder stay dropped, and so does anything
    /// another project's session made elsewhere.
    public static func outsideArtifact(root: String, recorded: String, cwd: String, scope: BackendArtifactScope) -> String? {
        guard recorded.hasPrefix("/"), !recorded.contains("\0"), ArtifactRules.isArtifact(recorded),
              isOwn(cwd: cwd, root: root, scope: scope), relative(root: root, recorded: recorded) == nil else { return nil }
        let path = URL(fileURLWithPath: recorded).standardizedFileURL.path
        return path == "/" || path == URL(fileURLWithPath: root).standardizedFileURL.path ? nil : path
    }
    /// The regular file at exactly a recorded outside path, or nil when it is gone, is a folder, or has
    /// been replaced by a link to somewhere else. Folders above it may be the system's own links
    /// (/tmp is /private/tmp); the file itself may not be one.
    public static func exactFile(_ recorded: String) -> URL? {
        guard recorded.hasPrefix("/"), !recorded.contains("\0") else { return nil }
        var info = stat()
        guard lstat(recorded, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? BackendFilesystemAuthority.canonical(URL(fileURLWithPath: recorded))
    }
    /// The project's own transcripts first, then its subfolders', then everyone else's; newest first within each.
    /// The folder name Claude files a session under is a lossy spelling of its path, so this only orders
    /// the reading. Which project a file belongs to is still decided from each line's own folder.
    static func ownFirst(_ files: [NativeTranscriptFile], project: String) -> [NativeTranscriptFile] {
        let names = Set(NativeTranscriptPaths.projectSpellings(project).map(NativeTranscriptPaths.encodeProjectPath))
        func rank(_ file: NativeTranscriptFile) -> Int {
            let directory = URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
            if names.contains(directory) { return 0 }
            return names.contains(where: { directory.hasPrefix($0 + "-") }) ? 1 : 2
        }
        // Three typed steps: as one chain the compiler could not type-check it in reasonable time.
        let ranked: [(rank: Int, offset: Int, file: NativeTranscriptFile)] = files.enumerated().map { entry in
            (rank: rank(entry.element), offset: entry.offset, file: entry.element)
        }
        let ordered: [(rank: Int, offset: Int, file: NativeTranscriptFile)] = ranked.sorted { (a, b) -> Bool in
            if a.rank == b.rank { return a.offset < b.offset }
            return a.rank < b.rank
        }
        return ordered.map { $0.file }
    }
    private struct Built {
        var first: Double; var last = 0.0; var changed = 0.0; var writes = 0; var edits = 0; var handoffs = 0; var chars = 0; var tool: String
        var own = false; var sessions: [String: Double] = [:]
    }
    /// Lower-cased artifact extensions packed last byte first, so a line can be asked "does any path here
    /// end in one?" by looking back from each closing quote without building a string.
    private static let packedArtifactExtensions: Set<UInt64> = Set(ArtifactRules.artifactExtensions.map { ext in
        ext.utf8.reversed().enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
    })
    /// Whether a transcript line names a file with an artifact extension anywhere (`….html"`, `….PNG"`).
    /// A line that does not cannot add an artifact row, so it is never parsed in an artifacts-only scan.
    static func mentionsArtifactFile(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress, line.count > 3 else { return false }
        var offset = 0
        while offset < line.count, let hit = memchr(base + offset, 0x22, line.count - offset) {
            let quote = base.distance(to: UnsafeRawPointer(hit))
            var key: UInt64 = 0, length = 0, index = quote - 1
            while index >= 0, length <= 5 {
                var byte = line[index]
                if byte == 0x2E { if length > 0, packedArtifactExtensions.contains(key) { return true }; break }
                if byte >= 0x41, byte <= 0x5A { byte += 0x20 }
                guard (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) else { break }
                // Packed in the order read (last character first), the same way the table was.
                key |= UInt64(byte) << UInt64(8 * length); length += 1; index -= 1
            }
            offset = quote + 1
        }
        return false
    }
    private static func holds(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }
    /// The byte-level form of the gates: a tool call that names a file to write, or hands one over.
    static func mayRecordFile(_ line: UnsafeRawBufferPointer) -> Bool {
        guard holds(line, "\"tool_use\"") else { return false }
        return holds(line, "\"file_path\"") || holds(line, "\"notebook_path\"") || holds(line, "\"SendUserFile\"")
            || holds(line, "\"file_paths\"") || holds(line, "creenshot")
    }
    private static func scan(project: String, relative: String?, files: [NativeTranscriptFile], options: BackendArtifactScanOptions, started: Date, initialTruncation: Bool, home: String, skipped listed: [String] = []) throws -> NativeRPCValue {
        let root = URL(fileURLWithPath: project).standardizedFileURL.path
        let maxSessions = min(max(options.maxSessions, 1), 400), maxArtifacts = min(max(options.maxArtifacts, 1), 2_000), maxChanges = min(max(options.maxChanges, 1), 500)
        let deadline = started.addingTimeInterval(Double(min(max(options.timeBudgetMilliseconds, 1), 120_000)) / 1_000)
        let cutoff = options.maxAgeMilliseconds == 0 ? 0 : started.timeIntervalSince1970 * 1_000 - max(options.maxAgeMilliseconds, 1)
        let available = files.filter { $0.modifiedAt >= cutoff }, selected = available.prefix(maxSessions)
        var truncated = initialTruncation || available.count > selected.count, scanned = 0, outside = 0, built: [String: Built] = [:], sessions: [String: (at: Double, paths: Set<String>)] = [:]
        var changes: [NativeRPCValue] = [], totalChanges = 0
        // Only lines that name an artifact file can matter to an artifacts-only list; one file's history reads them all.
        let artifactsOnly = options.onlyArtifacts && relative == nil
        var skipped = listed
        for file in selected {
            try Task.checkCancellation()
            if options.clock() > deadline { truncated = true; break }
            // One history that cannot be opened or read is skipped and named; everything else is still listed.
            do {
            let path = URL(fileURLWithPath: file.path)
            let target = BackendFilesystemAuthority.Target(root: path.deletingLastPathComponent(), path: path, relative: path.lastPathComponent)
            let descriptor = try BackendFilesystemAuthority.openStable(target)
            defer { Darwin.close(descriptor) }
            var openedName = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &openedName) == 0,
                  URL(fileURLWithPath: String(cString: openedName)).standardizedFileURL.path == path.standardizedFileURL.path else {
                throw NativeTranscriptPaths.Failure.outsideStore
            }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024), pending = Data(), lineCount = 0, budgetEnded = false, dropping = false
            func consume(_ bytes: UnsafeRawBufferPointer) throws {
                lineCount += 1
                if lineCount % 512 == 0 { try Task.checkCancellation(); if options.clock() > deadline { budgetEnded = true; return } }
                guard mayRecordFile(bytes), !artifactsOnly || mentionsArtifactFile(bytes),
                      let line = String(bytes: bytes, encoding: .utf8) else { return }
                for parsed in records(line) {
                    let at = parsed.at > 0 ? parsed.at : file.modifiedAt
                    let key: String
                    if let rel = Self.relative(root: root, recorded: parsed.path) {
                        // A handed-over note or archive is a file, not an artifact; it adds no row of its own.
                        if (parsed.isHandoff || artifactsOnly) && !ArtifactRules.isArtifact(rel) { continue }
                        key = rel
                    } else if let kept = Self.outsideArtifact(root: root, recorded: parsed.path, cwd: parsed.cwd, scope: options.scope) {
                        key = kept
                    } else { if !parsed.isHandoff { outside += 1 }; continue }
                    if let relative {
                        // A file's history is what was written into it; handing it over changed nothing.
                        guard key == relative, !parsed.isHandoff else { continue }; totalChanges += 1
                        let before = String(decoding: parsed.before.utf16.prefix(24_000), as: UTF16.self), after = String(decoding: parsed.after.utf16.prefix(24_000), as: UTF16.self)
                        changes.append(.object([.init("at", .number(at)), .init("sessionId", .string(file.sessionID)), .init("action", .string(parsed.action)), .init("tool", .string(parsed.tool)),
                            .init("before", .string(before)), .init("after", .string(after)), .init("replaceAll", .bool(parsed.replaceAll)), .init("clipped", .bool(parsed.before.utf16.count > 24_000 || parsed.after.utf16.count > 24_000))]))
                        if changes.count > maxChanges * 2 { changes.sort { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }; changes = Array(changes.prefix(maxChanges)) }
                    } else {
                        var entry = built[key] ?? Built(first: at, tool: parsed.tool)
                        if parsed.isHandoff {
                            entry.handoffs += 1
                            if entry.writes + entry.edits == 0 { entry.tool = parsed.tool }
                        } else {
                            if parsed.action == "write" { entry.writes += 1 } else { entry.edits += 1 }
                            if at >= entry.changed { entry.changed = at; entry.chars = parsed.after.utf16.count; entry.tool = parsed.tool }
                        }
                        if at < entry.first || entry.first == 0 { entry.first = at }
                        if at >= entry.last { entry.last = at }
                        if Self.isOwn(cwd: parsed.cwd, root: root, scope: options.scope) { entry.own = true }
                        entry.sessions[file.sessionID] = max(entry.sessions[file.sessionID] ?? 0, at); built[key] = entry
                        var session = sessions[file.sessionID] ?? (0, Set<String>()); session.paths.insert(key); session.at = max(session.at, at); sessions[file.sessionID] = session
                    }
                }
            }
            while !budgetEnded {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count == 0 { if !pending.isEmpty && !dropping { try pending.withUnsafeBytes { try consume($0) } }; break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeRPCError(code: "artifacts", message: "An approved transcript could not be read") }
                // Lines are cut at the newline with memchr; only a line that straddles two reads is copied.
                try buffer.withUnsafeBytes { raw in
                    var start = 0
                    while start < count, !budgetEnded {
                        guard let hit = memchr(raw.baseAddress! + start, 10, count - start) else {
                            if !dropping {
                                pending.append((raw.baseAddress! + start).assumingMemoryBound(to: UInt8.self), count: count - start)
                                if pending.count > 16 * 1024 * 1024 { dropping = true; pending.removeAll(keepingCapacity: false); truncated = true }
                            }
                            break
                        }
                        let end = raw.baseAddress!.distance(to: UnsafeRawPointer(hit))
                        if dropping { dropping = false }
                        else if pending.isEmpty { try consume(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
                        else {
                            pending.append((raw.baseAddress! + start).assumingMemoryBound(to: UInt8.self), count: end - start)
                            if pending.count > 16 * 1024 * 1024 { truncated = true } else { try pending.withUnsafeBytes { try consume($0) } }
                        }
                        pending.removeAll(keepingCapacity: true)
                        start = end + 1
                    }
                }
                if options.clock() > deadline { budgetEnded = true }
            }
            scanned += 1
            if budgetEnded { truncated = true; break }
            } catch is CancellationError { throw CancellationError() }
            catch { skipped.append(file.path) }
        }
        let unread = Array(Set(skipped)).sorted().map(NativeRPCValue.string)
        let elapsed = options.clock().timeIntervalSince(started) * 1_000
        if let relative {
            changes.sort { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }
            return .object([.init("root", .string(root)), .init("relPath", .string(relative)), .init("changes", .array(Array(changes.prefix(maxChanges)))),
                .init("sessionIds", .array(Array(Set(changes.compactMap { $0["sessionId"].string })).sorted().map(NativeRPCValue.string))),
                .init("totalChanges", .number(Double(totalChanges))), .init("truncated", .bool(truncated || totalChanges > maxChanges)), .init("cancelled", .bool(false)), .init("tookMs", .number(elapsed)), .init("skippedPaths", .array(unread))])
        }
        let ordered = built.sorted { $0.value.last == $1.value.last ? $0.key < $1.key : $0.value.last > $1.value.last }, kept = ordered.prefix(maxArtifacts)
        var artifacts: [NativeRPCValue] = []
        for (index, pair) in kept.enumerated() {
            try Task.checkCancellation()
            let (path, value) = pair; var disk = NativeRPCValue.null
            let isOutside = ArtifactRules.isOutside(path)
            if index < 600 {
                let real: URL?
                if isOutside { real = Self.exactFile(path) }
                else {
                    let file = URL(fileURLWithPath: root).appendingPathComponent(path)
                    real = (try? BackendFilesystemAuthority.canonical(file)).flatMap { BackendFilesystemAuthority.within($0, URL(fileURLWithPath: root)) ? $0 : nil }
                }
                if let real, let info = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), info.isRegularFile == true,
                   let bytes = info.fileSize, let date = info.contentModificationDate { disk = .object([.init("bytes", .number(Double(bytes))), .init("modifiedAt", .number(date.timeIntervalSince1970 * 1_000))]) }
            }
            // A file only ever handed over (published, sent, saved as a screenshot) was still made whole by the session.
            let writes = value.writes + value.edits == 0 && value.handoffs > 0 ? 1 : value.writes
            var row = NativeRPCValue.object([.init("relPath", .string(path)), .init("name", .string(URL(fileURLWithPath: path).lastPathComponent)), .init("firstAt", .number(value.first)), .init("lastAt", .number(value.last)),
                .init("writes", .number(Double(writes))), .init("edits", .number(Double(value.edits))), .init("lastChars", .number(Double(value.chars))), .init("lastTool", .string(value.tool)),
                .init("sessionIds", .array(value.sessions.sorted { $0.value > $1.value }.map { .string($0.key) })), .init("onDisk", disk)])
            // Additive facts a reader may ignore: made by this project's own session; how often it was handed
            // over; and, for a file outside the folder, that it is one and a short word for where.
            if value.own { row = row.setting("own", .bool(true)) }
            if value.handoffs > 0 { row = row.setting("handoffs", .number(Double(value.handoffs))) }
            if isOutside { row = row.setting("outside", .bool(true)).setting("location", .string(ArtifactRules.outsideLocation(path, home: home))) }
            artifacts.append(row)
        }
        let sessionRows = sessions.sorted { $0.value.at > $1.value.at }.map { id, value in NativeRPCValue.object([.init("sessionId", .string(id)), .init("at", .number(value.at)), .init("files", .number(Double(value.paths.count))), .init("relPaths", .array(value.paths.sorted().map(NativeRPCValue.string)))]) }
        return .object([.init("root", .string(root)), .init("scope", .string(options.scope.rawValue)), .init("artifacts", .array(artifacts)), .init("sessions", .array(sessionRows)),
            .init("sessionIds", .array(sessions.keys.sorted().map(NativeRPCValue.string))),
            .init("sessionsScanned", .number(Double(scanned))), .init("outsideProject", .number(Double(outside))), .init("truncated", .bool(truncated || ordered.count > kept.count)), .init("cancelled", .bool(false)), .init("tookMs", .number(elapsed)), .init("skippedPaths", .array(unread))])
    }
}

private extension TimeInterval { var mapMilliseconds: Double { self * 1_000 } }
