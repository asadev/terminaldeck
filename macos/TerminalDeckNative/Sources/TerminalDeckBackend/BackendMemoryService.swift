import Foundation
import CoreServices
import TerminalDeckNativeCore

public protocol BackendMemoryEnvironment: Sendable {
    func sources() async throws -> BackendMemorySources
    func trash(_ path: String) async throws
    /// Optional exactly as hootPaths in TS. The logger reports its own writable state and never throws.
    func hootActionLogger() async -> BackendMemoryActionLogger?
}
public struct BackendMemoryActionLogger: Sendable {
    public let append: @Sendable (String, String) async -> Void
    public init(append: @escaping @Sendable (String, String) async -> Void) { self.append = append }
}
public extension BackendMemoryEnvironment {
    func trash(_ path: String) async throws { throw NativeRPCError(code: "unavailable", message: "Moving memory to the Trash is unavailable.") }
    func hootActionLogger() async -> BackendMemoryActionLogger? { nil }
}

/// The one lazy actor shared by the screen and scoped agent tools. Construction reads nothing.
public actor BackendMemoryService {
    public static let maxNotes = 2000, maxNoteBytes = 256 * 1024, maxProvenanceConversations = 60
    private final class Index {
        var space: BackendMemoryFoundSpace; var entries: [String: Entry] = [:]; var graph: MemoryGraph?; var watcher: (any BackendMemoryWatching)?
        init(_ space: BackendMemoryFoundSpace) { self.space = space }
    }
    private struct Entry {
        let row: NativeRPCValue; let parsed: BackendMemoryParsing.Note; let linkable: BackendMemoryParsing.Linkable
    }
    private let environment: any BackendMemoryEnvironment
    private let watch: Bool; private let onChanged: @Sendable (String) async -> Void
    private let onError: @Sendable (String) -> Void
    private let watchFactory: BackendMemoryWatchFactory
    private let debounceClock: any BackendMemoryDebounceClock
    private var found: [BackendMemoryFoundSpace]?, discovery: Task<[BackendMemoryFoundSpace], Error>?
    private var indexes: [String: Index] = [:], textIndex = BackendMemoryTextIndex()
    private var announcements: [String: Task<Void, Never>] = [:]; private var closed = false
    public init(environment: any BackendMemoryEnvironment, watch: Bool = true,
                onChanged: @escaping @Sendable (String) async -> Void = { _ in }, onError: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
                watchFactory: BackendMemoryWatchFactory? = nil, debounceClock: any BackendMemoryDebounceClock = BackendMemorySystemDebounceClock()) {
        self.environment = environment; self.watch = watch; self.onChanged = onChanged; self.onError = onError
        self.watchFactory = watchFactory ?? { root, event in try BackendMemoryEventStream(root: root, event: event) }
        self.debounceClock = debounceClock
    }
    public func spaces(refresh: Bool = false) async throws -> [BackendMemoryFoundSpace] {
        if !refresh, let found { return found }
        if let discovery { return try await discovery.value }
        let environment = environment
        let task = Task { BackendMemorySpaces.discover(try await environment.sources()) }; discovery = task
        defer { discovery = nil }
        let spaces = try await task.value; found = spaces
        for id in Array(indexes.keys) {
            if let space = spaces.first(where: { $0.id == id }) { indexes[id]?.space = space }
            else { drop(id) }
        }
        return spaces
    }
    public func space(_ id: String) async throws -> BackendMemoryFoundSpace {
        guard let space = try await spaces().first(where: { $0.id == id }) else { throw Self.refusal("That memory is not on this machine any more.") }; return space
    }
    public func claudeSpaceFor(configDir: String, cwd: String) async throws -> BackendMemoryFoundSpace? {
        let roots = NativeTranscriptPaths.projectSpellings(cwd).compactMap { BackendMemorySpaces.realDir(BackendMemorySpaces.joined(configDir, "projects/" + NativeTranscriptPaths.encodeProjectPath($0) + "/memory")) }
        guard !roots.isEmpty else { return nil }
        if let match = try await spaces().first(where: { $0.space.kind == .claudeProject && roots.contains($0.root) }) { return match }
        return try await spaces(refresh: true).first { $0.space.kind == .claudeProject && roots.contains($0.root) }
    }
    public func codexSpaceFor(configDir: String) async throws -> BackendMemoryFoundSpace? {
        guard let root = BackendMemorySpaces.realDir(BackendMemorySpaces.joined(configDir, "memories")) else { return nil }
        if let match = try await spaces().first(where: { $0.space.kind == .codex && $0.root == root }) { return match }
        return try await spaces(refresh: true).first { $0.space.kind == .codex && $0.root == root }
    }
    public func spacesForProject(_ project: String) async throws -> [BackendMemoryFoundSpace] {
        let spellings = Set(NativeTranscriptPaths.projectSpellings(project))
        return try await spaces().filter { space in
            if space.space.kind == .knowledge { return space.space.project.map(spellings.contains) == true }
            return space.space.kind == .claudeProject && space.members.contains { $0.project.map(spellings.contains) == true }
        }
    }
    public func hootSpace() async throws -> BackendMemoryFoundSpace? { try await spaces().first { $0.space.kind == .hoot } }
    public static func notePath(root: String, path: NativeRPCValue) throws -> String {
        guard let path = path.string, !BackendMemoryParsing.trim(path).isEmpty, !path.contains("\0") else { throw refusal("That is not a note in this memory.") }
        let written = path.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") || written.hasPrefix("/") || !BackendMemoryParsing.matches(#"^[A-Za-z]:"#, written).isEmpty {
            throw refusal("A note is named by its place inside the memory folder, not by a path on the disk.")
        }
        let normal = BackendMemoryParsing.normalize(written)
        if normal == ".." || normal.hasPrefix("../") || normal.components(separatedBy: "/").contains("..") { throw refusal("That path leaves the memory folder.") }
        if !normal.lowercased().hasSuffix(".md") { throw refusal("Only Markdown notes can be opened here.") }
        guard let real = try? BackendFilesystemAuthority.canonical(URL(fileURLWithPath: root).appendingPathComponent(normal)) else {
            throw refusal("That note is no longer there — it may have been deleted while this was open.")
        }
        guard BackendFilesystemAuthority.within(real, URL(fileURLWithPath: root)) else { throw refusal("That note is a link to a file outside the memory folder.") }
        return real.path
    }
    public static func listNoteFiles(root: String) -> [String] {
        var found: [String] = []
        func walk(_ directory: String, depth: Int) {
            for name in BackendMemorySpaces.directory(directory).sorted(by: { $0.localizedCompare($1) == .orderedAscending }) {
                if found.count >= maxNotes { return }; if name.hasPrefix(".") { continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
                if values.isDirectory == true, values.isSymbolicLink != true { if depth < 4 { walk(url.path, depth: depth + 1) }; continue }
                guard name.lowercased().hasSuffix(".md"), let real = try? BackendFilesystemAuthority.canonical(url), BackendFilesystemAuthority.within(real, URL(fileURLWithPath: root)),
                      (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                found.append(BackendFilesystemAuthority.relative(url, to: URL(fileURLWithPath: root)))
            }
        }
        walk(root, depth: 1); return found
    }
    public func notes(_ id: String) async throws -> [NativeRPCValue] {
        let index = try await indexOf(id)
        return index.entries.values.map(\.row).sorted {
            let a = $0["modifiedAt"].number ?? 0, b = $1["modifiedAt"].number ?? 0
            return a == b ? ($0["path"].string ?? "").localizedCompare($1["path"].string ?? "") == .orderedAscending : a > b
        }
    }
    public func graph(_ id: String) async throws -> MemoryGraph { graphOf(try await indexOf(id)) }
    public func read(_ id: String, path: NativeRPCValue) async -> NativeRPCValue {
        do {
            let index = try await indexOf(id), real = try Self.notePath(root: index.space.root, path: path)
            let relative = BackendFilesystemAuthority.relative(URL(fileURLWithPath: real), to: URL(fileURLWithPath: index.space.root))
            let info = try BackendMemoryFiles.info(real); guard info.file else { throw Self.refusal("That is not a note in this memory.") }
            let head = try BackendMemoryFiles.head(real, limit: Self.maxNoteBytes)
            note(index, relative: relative, text: head.text, info: info)
            let entry = index.entries[relative]!, graph = graphOf(index), resolver = BackendMemoryParsing.Resolver(index.entries.values.map(\.linkable))
            return BackendMemoryParsing.object([("ok", .bool(true)), ("spaceId", .string(id)), ("path", .string(relative)), ("text", .string(head.text)),
                ("truncated", .bool(head.truncated)), ("version", BackendMemoryFiles.version(info)), ("note", entry.row),
                ("front", .object(entry.parsed.front.keys.sorted().map { .init($0, .string(entry.parsed.front[$0]!)) })),
                ("links", .array(entry.linkable.links.map { BackendMemoryParsing.object([("target", .string($0)), ("to", BackendMemoryParsing.optional(resolver.resolve(from: relative, target: $0)))]) })),
                ("backlinks", BackendMemoryParsing.strings(BackendMemoryParsing.unique(graph.edges.filter { $0.to == relative }.map(\.from)).sorted())),
                ("indexed", .bool(!indexLines(index, relative: relative).isEmpty))])
        } catch { return Self.failure(error) }
    }
    public func searchIn(_ query: String, spaceIDs: [String], limit: Int = 20) async -> [NativeRPCValue] {
        var allowed = Set<String>()
        for id in spaceIDs { if (try? await indexOf(id)) != nil { allowed.insert(id) } }
        return textIndex.search(query, limit: limit, filter: { allowed.contains($0.components(separatedBy: "\0")[0]) }).map { hit in
            let parts = hit.id.components(separatedBy: "\0"), id = parts[0], path = parts[1]
            return BackendMemoryParsing.object([("spaceId", .string(id)), ("path", .string(path)), ("title", indexes[id]?.entries[path]?.row["title"] ?? .string(path)), ("score", .number(hit.score)), ("snippet", .string(hit.snippet))])
        }
    }
    public func save(_ id: String, path: NativeRPCValue, text: NativeRPCValue, version: NativeRPCValue) async -> NativeRPCValue {
        do {
            let index = try await indexOf(id)
            guard let text = text.string else { throw Self.refusal("Nothing was supplied to save.") }
            guard text.utf8.count <= Self.maxNoteBytes else { throw Self.refusal("A note cannot be larger than 256 KB.") }
            let real = try Self.notePath(root: index.space.root, path: path), info = try BackendMemoryFiles.info(real)
            guard info.file else { throw Self.refusal("That is not a note in this memory.") }
            guard version["modifiedAt"].number == info.modified * 1000, version["bytes"].number == info.bytes else {
                throw Self.refusal("This note changed after you opened it, so nothing was saved. Open it again to see what is there now.")
            }
            try BackendAccountFiles.writeAtomic(Data(text.utf8), to: URL(fileURLWithPath: real))
            let after = try BackendMemoryFiles.info(real), relative = BackendFilesystemAuthority.relative(URL(fileURLWithPath: real), to: URL(fileURLWithPath: index.space.root))
            note(index, relative: relative, text: text, info: after)
            if index.space.space.kind == .hoot, let logger = await environment.hootActionLogger() { await logger.append("memory.edited", "you edited memory/\(relative) from the Memory page") }
            return Self.change(version: BackendMemoryFiles.version(after), removed: false)
        } catch { return Self.failure(error) }
    }
    public func remove(_ id: String, path: NativeRPCValue, indexLine: Bool = false) async -> NativeRPCValue {
        do {
            let index = try await indexOf(id), real = try Self.notePath(root: index.space.root, path: path)
            guard try BackendMemoryFiles.info(real).file else { throw Self.refusal("That is not a note in this memory.") }
            let relative = BackendFilesystemAuthority.relative(URL(fileURLWithPath: real), to: URL(fileURLWithPath: index.space.root))
            let lines = indexLine ? indexLines(index, relative: relative) : []
            try await environment.trash(real)
            index.entries[relative] = nil; textIndex.remove(id + "\0" + relative); index.graph = nil
            var removed = false
            if !lines.isEmpty, let indexPath = indexNote(index) {
                let file = try Self.notePath(root: index.space.root, path: .string(indexPath)), text = try BackendMemoryFiles.text(file)
                let next = text.components(separatedBy: "\n").enumerated().filter { !lines.contains($0.offset) }.map(\.element).joined(separator: "\n")
                if next != text { try BackendAccountFiles.writeAtomic(Data(next.utf8), to: URL(fileURLWithPath: file)); note(index, relative: indexPath, text: next, info: try BackendMemoryFiles.info(file)); removed = true }
            }
            if index.space.space.kind == .hoot, let logger = await environment.hootActionLogger() { await logger.append("memory.deleted", "you moved memory/\(relative) to the Trash from the Memory page") }
            return Self.change(version: .null, removed: removed)
        } catch { return Self.failure(error) }
    }
    public func provenance(_ id: String, path: NativeRPCValue) async -> NativeRPCValue {
        do {
            let space = try await space(id)
            guard space.space.kind == .claudeProject else { throw Self.refusal("Only Claude Code memory is written by conversations this app can read back.") }
            let real = try Self.notePath(root: space.root, path: path), target = URL(fileURLWithPath: real).lastPathComponent, targetDir = URL(fileURLWithPath: real).deletingLastPathComponent().path
            var folders: [String: String] = [:], folderOrder: [String] = []
            for projects in space.projectsDirs { for member in space.members {
                let path = BackendMemorySpaces.joined(projects, member.folder), dir = BackendMemorySpaces.realDir(path) ?? path
                if folders[dir] == nil { folderOrder.append(dir); folders[dir] = member.project ?? member.folder }
            } }
            var files: [(NativeTranscriptFile, String)] = []
            for dir in folderOrder {
                let projects = space.projectsDirs.first { dir.hasPrefix($0 + "/") } ?? space.projectsDirs.first ?? ""
                files += BackendMemorySpaces.transcriptFiles(dir, projectsDir: projects).map { ($0, folders[dir]!) }
            }
            files.sort { $0.0.modifiedAt > $1.0.modifiedAt }
            let chosen = Array(files.prefix(Self.maxProvenanceConversations)), deadline = Date().addingTimeInterval(8)
            var truncated = chosen.count < files.count, read = 0, writes: [NativeRPCValue] = [], dirs: [String: String] = [:]
            for (file, folder) in chosen {
                try Task.checkCancellation(); if Date() > deadline { truncated = true; break }
                let stopped = try Self.streamLines(file.path, deadline: deadline) { line in
                    guard line.contains(target) else { return }
                    for touch in BackendArtifactsIndex.touches(line) {
                        let url = URL(fileURLWithPath: touch.path); guard url.lastPathComponent == target else { continue }
                        let dir = url.deletingLastPathComponent().path
                        if dirs[dir] == nil { dirs[dir] = BackendMemorySpaces.realDir(dir) ?? "" }
                        guard dirs[dir] == targetDir else { continue }
                        writes.append(BackendMemoryParsing.object([("conversationId", .string(file.sessionID)), ("folder", .string(folder)), ("at", .number(touch.at > 0 ? touch.at : file.modifiedAt)), ("tool", .string(touch.tool)), ("action", .string(touch.action))]))
                    }
                }
                read += 1; if stopped { truncated = true }
            }
            writes.sort { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }
            return BackendMemoryParsing.object([("ok", .bool(true)), ("writes", .array(Array(writes.prefix(50)))), ("conversationsRead", .number(Double(read))), ("truncated", .bool(truncated))])
        } catch { return Self.failure(error is CancellationError ? Self.refusal("Stopped.") : error) }
    }
    private static func streamLines(_ path: String, deadline: Date, consume: (String) -> Void) throws -> Bool {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
        var pending = Data(), count = 0
        func line(_ bytes: Data) throws -> Bool {
            count += 1; try Task.checkCancellation()
            if count % 512 == 0, Date() > deadline { return true }
            consume(String(decoding: bytes, as: UTF8.self)); return false
        }
        while let bytes = try file.read(upToCount: 64 * 1024), !bytes.isEmpty {
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                if try line(pending[..<newline]) { return true }; pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { return try line(pending) }; return false
    }
    public func close() {
        closed = true; discovery?.cancel(); announcements.values.forEach { $0.cancel() }; announcements.removeAll()
        for id in Array(indexes.keys) { drop(id) }
    }
    private func indexOf(_ id: String) async throws -> Index {
        if let index = indexes[id] { return index }
        let space = try await space(id)
        if let index = indexes[id] { return index }
        let index = Index(space); indexes[id] = index
        for relative in Self.listNoteFiles(root: space.root) { refresh(index, relative: relative) }
        if watch, !closed {
            do { index.watcher = try watchFactory(space.root) { [weak self] paths, rescan in Task { await self?.changed(id, paths: paths, rescan: rescan) } } }
            catch { onError("[memory] a memory folder could not be watched: " + error.localizedDescription) }
        }
        return index
    }
    private func changed(_ id: String, paths: [String], rescan: Bool) {
        guard !closed, let index = indexes[id] else { return }
        var changed = false
        if rescan || paths.contains(index.space.root) {
            let listed = Set(Self.listNoteFiles(root: index.space.root))
            for relative in listed.union(index.entries.keys) { refresh(index, relative: relative) }
            changed = true
        }
        for path in paths {
            guard path.hasPrefix(index.space.root + "/") else { continue }
            let relative = String(path.dropFirst(index.space.root.count + 1)), parts = relative.components(separatedBy: "/")
            guard !parts.contains(where: { $0.hasPrefix(".") }), parts.count <= 4 else { continue }
            if relative.lowercased().hasSuffix(".md") { refresh(index, relative: relative); changed = true }
            else if BackendMemorySpaces.realDir(path) != nil {
                for notePath in Self.listNoteFiles(root: index.space.root) where notePath.hasPrefix(relative + "/") { refresh(index, relative: notePath); changed = true }
            } else {
                for notePath in Array(index.entries.keys) where notePath.hasPrefix(relative + "/") { refresh(index, relative: notePath); changed = true }
            }
        }
        guard changed else { return }
        announcements[id]?.cancel()
        let clock = debounceClock
        announcements[id] = Task { [weak self] in
            do { try await clock.wait(milliseconds: 150); await self?.announce(id) } catch {}
        }
    }
    private func announce(_ id: String) async { announcements[id] = nil; if !closed { await onChanged(id) } }
    private func refresh(_ index: Index, relative: String) {
        do {
            let real = try Self.notePath(root: index.space.root, path: .string(relative)), info = try BackendMemoryFiles.info(real)
            guard info.file else { throw Self.refusal("not a note") }
            note(index, relative: relative, text: try BackendMemoryFiles.head(real, limit: Self.maxNoteBytes).text, info: info)
        } catch { index.entries[relative] = nil; textIndex.remove(index.space.id + "\0" + relative); index.graph = nil }
    }
    private func note(_ index: Index, relative: String, text: String, info: (modified: Double, bytes: Double, file: Bool)) {
        let parsed = BackendMemoryParsing.parseNote(text, file: relative), front = parsed.front, links = BackendMemoryParsing.noteLinks(parsed.body)
        let labels: [NativeRPCValue] = ["type", "kind", "status", "source", "verified"].compactMap { key in
            guard let value = front[key], !value.isEmpty else { return nil }
            let shown = key == "verified" && !BackendMemoryParsing.matches(#"^\d{12,}$"#, value).isEmpty ? BackendKnowledgeFormat.day(Double(value) ?? 0) : value
            return BackendMemoryParsing.object([("key", .string(key)), ("value", .string(shown))])
        }
        let row = BackendMemoryParsing.object([("spaceId", .string(index.space.id)), ("path", .string(relative)), ("title", .string(parsed.title)),
            ("name", BackendMemoryParsing.optional(parsed.name)), ("description", BackendMemoryParsing.optional(front["description"])),
            ("type", BackendMemoryParsing.optional(front["type"] ?? front["kind"])), ("links", BackendMemoryParsing.strings(links)),
            ("modifiedAt", .number(info.modified * 1000)), ("bytes", .number(info.bytes)), ("labels", .array(labels))])
        index.entries[relative] = Entry(row: row, parsed: parsed, linkable: .init(path: relative, name: parsed.name, links: links)); index.graph = nil
        textIndex.put(id: index.space.id + "\0" + relative, title: parsed.title + (front["description"].map { " " + $0 } ?? ""), body: parsed.body)
    }
    private func graphOf(_ index: Index) -> MemoryGraph {
        if let graph = index.graph { return graph }; let graph = BackendMemoryParsing.graph(index.entries.values.map(\.linkable)); index.graph = graph; return graph
    }
    private func indexNote(_ index: Index) -> String? { index.entries.keys.first { $0.lowercased() == "memory.md" } }
    private func indexLines(_ index: Index, relative: String) -> [Int] {
        guard let indexPath = indexNote(index), indexPath != relative, let file = try? Self.notePath(root: index.space.root, path: .string(indexPath)), let text = try? BackendMemoryFiles.text(file) else { return [] }
        let resolver = BackendMemoryParsing.Resolver(index.entries.values.map(\.linkable))
        return text.components(separatedBy: "\n").enumerated().compactMap { at, line in BackendMemoryParsing.noteLinks(line).contains { resolver.resolve(from: indexPath, target: $0) == relative } ? at : nil }
    }
    private func drop(_ id: String) {
        guard let index = indexes.removeValue(forKey: id) else { return }; index.watcher?.stop()
        for relative in index.entries.keys { textIndex.remove(id + "\0" + relative) }
    }
    static func refusal(_ message: String) -> NativeRPCError { .init(code: "memory", message: message) }
    static func failure(_ error: Error) -> NativeRPCValue { BackendMemoryParsing.object([("ok", .bool(false)), ("error", .string(error.localizedDescription))]) }
    static func change(version: NativeRPCValue, removed: Bool) -> NativeRPCValue { BackendMemoryParsing.object([("ok", .bool(true)), ("version", version), ("indexLineRemoved", .bool(removed))]) }
}

private final class BackendMemoryEventStream: BackendMemoryWatching, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let event: @Sendable ([String], Bool) -> Void; init(_ event: @escaping @Sendable ([String], Bool) -> Void) { self.event = event }
    }
    private let queue = DispatchQueue(label: "dev.terminaldeck.memory-events", qos: .utility)
    private var reference: FSEventStreamRef?; private let box: Box
    init(root: String, event: @escaping @Sendable ([String], Bool) -> Void) throws {
        box = Box(event)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            guard let pointer else { return nil }; _ = Unmanaged<Box>.fromOpaque(pointer).retain(); return pointer
        }, release: { pointer in if let pointer { Unmanaged<Box>.fromOpaque(pointer).release() } }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }; let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let broad = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            let rescan = (0..<count).contains { flags[$0] & broad != 0 }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().event((0..<count).map { String(cString: values[$0]) }, rescan)
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { throw NativeRPCError(code: "memory-watch", message: "The memory event stream could not be created.") }
        reference = stream; FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { stop(); throw NativeRPCError(code: "memory-watch", message: "The memory event stream could not be started.") }
    }
    func stop() { guard let reference else { return }; self.reference = nil; FSEventStreamStop(reference); FSEventStreamInvalidate(reference); FSEventStreamRelease(reference) }
    deinit { stop() }
}
