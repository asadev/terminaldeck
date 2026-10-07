import Foundation
import Dispatch
import Darwin
import TerminalDeckNativeCore

/// A read-only native backend for the existing readable-chat protocol. The
/// session ledger stays the sole owner of session attribution and persistence.
@MainActor
final class NativeTranscriptBackend {
    static let shared = NativeTranscriptBackend()

    private struct Request: Sendable {
        let cwd: String?
        let path: String?
        init(_ raw: Any?) {
            let value = raw as? [String: Any] ?? [:]
            let cwd = value["cwd"] as? String, path = value["transcriptPath"] as? String
            self.cwd = cwd.flatMap { $0.isEmpty ? nil : $0 }
            self.path = path.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
    private struct Watch {
        let request: Request
        let files: NativeTranscriptFileWatch
        let update: (NativeChatTranscriptRead) -> Void
        let failure: (String) -> Void
        var task: Task<Void, Never>?
        var changedAgain = false
    }

    private var scope = NativeTranscriptScope.environment()
    private var assembledHomeScopes: [String: NativeTranscriptHomeScope] = [:]
    private var readers: [String: NativeChatTranscriptReader] = [:]
    private var readerOrder: [String] = []
    private var watches: [UUID: Watch] = [:]
    private var generation = 0
    private let maximumReaders = 12
    private let maximumWatches = 12

    /// Call with the same trusted config/device-home/scoped-home paths used by
    /// engine assembly. No path configuration comes from a browser request.
    func configure(scope: NativeTranscriptScope) {
        stop()
        self.scope = includingAssembledHomes(scope)
    }
    /// Only the app composition root installs these restrictions, before Hoot
    /// starts. Later trusted Node/account scope changes must retain them.
    func installHomeScope(_ home: NativeTranscriptHomeScope, ownerID: String, scope supplied: NativeTranscriptScope? = nil) {
        assembledHomeScopes[ownerID] = home
        configure(scope: supplied ?? scope)
    }
    func removeHomeScope(ownerID: String) {
        guard let home = assembledHomeScopes.removeValue(forKey: ownerID) else { return }
        var next = scope
        next.homeScopes.removeAll { $0.home == home.home && $0.folder == home.folder }
        configure(scope: next)
    }
    var configuredHomeScopes: [NativeTranscriptHomeScope] { scope.homeScopes }
    func includingAssembledHomes(_ supplied: NativeTranscriptScope) -> NativeTranscriptScope {
        var next = supplied
        for owner in assembledHomeScopes.keys.sorted() {
            guard let home = assembledHomeScopes[owner],
                  !next.homeScopes.contains(where: { $0.home == home.home && $0.folder == home.folder }) else { continue }
            next.homeScopes.append(home)
        }
        return next
    }

    /// Native extension of the old polling contract. Callbacks may be routed
    /// as `chat:update`; errors must remain visible instead of empty replies.
    @discardableResult
    func watch(_ raw: Any, onUpdate: @escaping (NativeChatTranscriptRead) -> Void,
               onFailure: @escaping (String) -> Void) async throws -> UUID {
        guard watches.count < maximumWatches else { throw BackendFailure("Too many native transcript watchers are open. Close a chat before opening another.") }
        let request = Request(raw)
        guard request.path != nil || request.cwd != nil else { throw NativeTranscriptPaths.Failure.pathRequired }
        let paths = try await pathsToWatch(request)
        let id = UUID()
        let files = NativeTranscriptFileWatch { [weak self] in self?.schedule(id) }
        do { try files.reconcile(paths) }
        catch { files.stop(); throw error }
        watches[id] = Watch(request: request, files: files, update: onUpdate, failure: onFailure)
        schedule(id)
        return id
    }

    func unwatch(_ id: UUID) {
        guard let watch = watches.removeValue(forKey: id) else { return }
        watch.task?.cancel()
        watch.files.stop()
    }

    func stop() {
        generation += 1
        for id in Array(watches.keys) { unwatch(id) }
        readers.removeAll(); readerOrder.removeAll()
    }

    /// Native equivalents of the location helpers; these do not mutate the
    /// engine's session ledger or assign a transcript to a particular session.
    func newestTranscript(cwd: String) async throws -> NativeTranscriptFile? {
        let current = scope
        return try await Task.detached(priority: .utility) { try NativeTranscriptPaths.newest(cwd, scope: current) }.value
    }

    func listTranscripts(cwd: String) async throws -> [NativeTranscriptFile] {
        let current = scope
        return try await Task.detached(priority: .utility) {
            var found: [NativeTranscriptFile] = [], seen = Set<String>()
            for directory in try NativeTranscriptPaths.projectDirectories(cwd, scope: current) {
                for file in try NativeTranscriptPaths.listTranscripts(directory, scope: current) where seen.insert(file.path).inserted { found.append(file) }
            }
            return found.sorted { $0.modifiedAt > $1.modifiedAt }
        }.value
    }

    func readTail(path: String, from: Int64) async throws -> NativeChatTranscriptRead {
        let current = scope
        let approved = try await Task.detached(priority: .utility) {
            (try NativeTranscriptPaths.assertTranscript(path, scope: current), try NativeTranscriptPaths.approvedRoots(current))
        }.value
        let reader = NativeChatTranscriptReader(path: approved.0, startAt: max(0, from), allowedRoots: approved.1)
        return try await reader.readAll(wholeConversation: true)
    }

    private func locate(_ request: Request) async throws -> (path: String?, roots: [String]) {
        let current = scope
        return try await Task.detached(priority: .utility) {
            let roots = try NativeTranscriptPaths.approvedRoots(current)
            if let path = request.path { return (try NativeTranscriptPaths.assertTranscript(path, scope: current), roots) }
            if let cwd = request.cwd { return (try NativeTranscriptPaths.newest(cwd, scope: current)?.path, roots) }
            return (nil, roots)
        }.value
    }

    private func read(_ request: Request, whole: Bool) async throws -> NativeChatTranscriptRead {
        let stamp = generation
        let located = try await locate(request)
        guard stamp == generation else { throw CancellationError() }
        guard let path = located.path else { return .absent() }
        let known = readers[path] != nil && !whole
        if whole { readers[path] = nil; readerOrder.removeAll { $0 == path } }
        let reader: NativeChatTranscriptReader
        if let cached = readers[path] { reader = cached }
        else {
            while readers.count >= maximumReaders, let oldest = readerOrder.first {
                readers[oldest] = nil; readerOrder.removeFirst()
            }
            reader = NativeChatTranscriptReader(path: path, allowedRoots: located.roots)
            readers[path] = reader; readerOrder.append(path)
        }
        let result = try await reader.readAll(wholeConversation: whole || !known, forceReset: !whole && !known)
        guard stamp == generation else { throw CancellationError() }
        return result
    }

    private func pathsToWatch(_ request: Request) async throws -> [String] {
        let current = scope
        return try await Task.detached(priority: .utility) {
            var paths: [String] = []
            if let path = request.path {
                let approved = try NativeTranscriptPaths.assertTranscript(path, scope: current)
                paths.append(approved)
                paths.append(URL(fileURLWithPath: approved).deletingLastPathComponent().path)
            } else if let cwd = request.cwd {
                paths += try NativeTranscriptPaths.projectDirectories(cwd, scope: current)
                // Discover future device stores event-by-event: their .claude
                // directory does not exist at the instant a home is paired.
                if let root = current.deviceHomesRoot {
                    paths.append(root)
                    if let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root),
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                        guard children.count <= current.maximumDirectoryEntries else { throw NativeTranscriptPaths.Failure.directoryBudget }
                        for child in children {
                            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            if values?.isDirectory == true, values?.isSymbolicLink != true {
                                paths.append(child.appendingPathComponent(".claude/projects").path)
                            }
                        }
                    }
                }
                // Directory events signal creations, not appends inside an
                // existing file. Follow the newest file as well as its folder.
                if let newest = try NativeTranscriptPaths.newest(cwd, scope: current) { paths.append(newest.path) }
            }
            return paths
        }.value
    }

    private func schedule(_ id: UUID) {
        guard var watch = watches[id] else { return }
        if watch.task != nil { watch.changedAgain = true; watches[id] = watch; return }
        watch.task = Task { [weak self] in
            // Coalesce a burst of vnode writes; this is a one-shot debounce,
            // never an idle polling loop.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.refresh(id)
        }
        watches[id] = watch
    }

    private func refresh(_ id: UUID) async {
        guard let watch = watches[id] else { return }
        do {
            let paths = try await pathsToWatch(watch.request)
            try Task.checkCancellation()
            guard watches[id] != nil else { return }
            try watch.files.reconcile(paths)
            let result = try await read(watch.request, whole: false)
            try Task.checkCancellation()
            if watches[id] != nil { watch.update(result) }
        } catch is CancellationError { return }
        catch { if watches[id] != nil { watch.failure(error.localizedDescription) } }
        guard var current = watches[id] else { return }
        let again = current.changedAgain
        current.task = nil; current.changedAgain = false; watches[id] = current
        if again { schedule(id) }
    }

    private struct BackendFailure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Each vnode source owns one descriptor. Replacement is detected by inode,
/// and missing paths are watched at their nearest existing ancestor so a
/// first transcript can be discovered without a timer.
@MainActor
private final class NativeTranscriptFileWatch {
    private struct Source {
        let source: any DispatchSourceFileSystemObject
        let inode: UInt64
    }
    private var sources: [String: Source] = [:]
    private let changed: () -> Void
    private let maximumSources = 24
    init(changed: @escaping () -> Void) { self.changed = changed }

    func reconcile(_ requested: [String]) throws {
        var paths = Set<String>()
        for path in requested {
            var current = URL(fileURLWithPath: path).standardizedFileURL
            while !FileManager.default.fileExists(atPath: current.path), current.path != "/" { current.deleteLastPathComponent() }
            paths.insert(current.path)
        }
        guard paths.count <= maximumSources else { throw WatchFailure("The native transcript watch exceeds its descriptor budget. Select an exact transcript.") }
        for path in Array(sources.keys) where !paths.contains(path) { sources.removeValue(forKey: path)?.source.cancel() }
        for path in paths {
            let currentInode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
            if let source = sources[path], currentInode == source.inode { continue }
            sources.removeValue(forKey: path)?.source.cancel()
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw WatchFailure("A transcript path could not be monitored (filesystem error \(errno)).") }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw WatchFailure("A transcript watch could not inspect its file descriptor.") }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.changed() } }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[path] = Source(source: source, inode: UInt64(info.st_ino))
            source.resume()
        }
    }

    func stop() {
        for entry in sources.values { entry.source.cancel() }
        sources.removeAll()
    }

    private struct WatchFailure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
