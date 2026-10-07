import Foundation
import CoreServices
import TerminalDeckNativeCore

/// One event stream/status refresh per folder, shared by ref-counted owners.
/// No timer polls Git. File and actual Git metadata directory events debounce
/// into a single refresh, with an extra refresh only if events arrived in flight.
public actor BackendFileWatchService {
    private let files: BackendFilesystemService
    private let git: BackendGitService
    private let registry: NativeChannelRegistry
    private final class Group: @unchecked Sendable {
        let id = UUID(); let root: String
        var owners: [String: (context: NativeRPCContext, refs: Int)] = [:]
        var stream: Stream?; var refresh: Task<Void, Never>?; var dirty = false; var last: NativeRPCValue?
        init(root: String, context: NativeRPCContext) { self.root = root; owners[context.ownerID] = (context, 1) }
    }
    private var groups: [String: Group] = [:]
    private var observers: [UUID: @Sendable (String, NativeRPCValue) async -> Void] = [:]
    public init(files: BackendFilesystemService, git: BackendGitService, registry: NativeChannelRegistry) {
        self.files = files; self.git = git; self.registry = registry
    }
    public func watchGit(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let root = try await git.authority.authorize(cwd, context: context).path
        if let group = groups[root] {
            let old = group.owners[context.ownerID]
            group.owners[context.ownerID] = (context, (old?.refs ?? 0) + 1)
            return try await git.status(cwd: root, context: context)
        }
        let group = Group(root: root, context: context)
        groups[root] = group
        do {
            let first = try await git.status(cwd: root, context: context)
            let directories = try await git.metadataDirectories(cwd: root, context: context)
            guard groups[root]?.id == group.id, !group.owners.isEmpty else { return first }
            let paths = [root] + directories
            group.last = first
            group.stream = try Stream(paths: paths) { [weak self] in Task { await self?.changed(root, id: group.id) } }
            return first
        } catch { if groups[root]?.id == group.id { groups[root] = nil }; throw error }
    }
    public func unwatch(cwd: String, ownerID: String) {
        let candidates = groups.keys.filter { $0 == cwd || $0 == URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path }
        for root in candidates {
            guard let group = groups[root], var owner = group.owners[ownerID] else { continue }
            owner.refs -= 1
            if owner.refs <= 0 { group.owners[ownerID] = nil } else { group.owners[ownerID] = owner }
            if group.owners.isEmpty { group.refresh?.cancel(); group.stream?.stop(); groups[root] = nil }
        }
    }
    public func removeOwner(_ ownerID: String) async {
        for root in Array(groups.keys) {
            guard let group = groups[root] else { continue }
            group.owners[ownerID] = nil
            if group.owners.isEmpty { group.refresh?.cancel(); group.stream?.stop(); groups[root] = nil }
        }
        await files.removeOwner(ownerID)
    }
    public func observeGit(_ callback: @escaping @Sendable (String, NativeRPCValue) async -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    public func stop() {
        for group in groups.values { group.refresh?.cancel(); group.stream?.stop() }
        groups.removeAll(); observers.removeAll()
    }
    public var count: Int { groups.count }
    private func changed(_ root: String, id: UUID) {
        guard let group = groups[root], group.id == id else { return }
        group.dirty = true
        guard group.refresh == nil else { return }
        group.refresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.refresh(root, id: id)
        }
    }
    private func refresh(_ root: String, id: UUID) async {
        guard let group = groups[root], group.id == id else { return }
        group.dirty = false
        await files.invalidate(root: root)
        var status: NativeRPCValue?
        for (ownerID, owner) in group.owners {
            do {
                _ = try await git.authority.authorize(root, context: owner.context)
                if status == nil { status = try await git.status(cwd: root, context: owner.context) }
            } catch { group.owners[ownerID] = nil }
        }
        guard groups[root]?.id == id else { return }
        if group.owners.isEmpty { group.stream?.stop(); groups[root] = nil; return }
        for ownerID in group.owners.keys {
            try? await registry.publish("fs:changed", arguments: [.string(root)], ownerID: ownerID)
        }
        if let status, status != group.last {
            group.last = status
            for ownerID in group.owners.keys { try? await registry.publish("git:status-changed", arguments: [.string(root), status], ownerID: ownerID) }
            for observer in observers.values { await observer(root, status) }
        }
        group.refresh = nil
        if group.dirty { changed(root, id: id) }
    }

    private final class EventBox: @unchecked Sendable {
        let event: @Sendable () -> Void
        init(_ event: @escaping @Sendable () -> Void) { self.event = event }
    }
    private final class Stream: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.terminaldeck.native.file-events", qos: .utility)
        private var reference: FSEventStreamRef?
        private let box: EventBox
        init(paths: [String], event: @escaping @Sendable () -> Void) throws {
            box = EventBox(event)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<EventBox>.fromOpaque(pointer).retain(); return pointer
                }, release: { pointer in
                    if let pointer { Unmanaged<EventBox>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                if let info { Unmanaged<EventBox>.fromOpaque(info).takeUnretainedValue().event() }
            }
            guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
                throw NativeRPCError(code: "file-watch", message: "The native filesystem event stream could not be created")
            }
            reference = stream
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else { stop(); throw NativeRPCError(code: "file-watch", message: "The native filesystem event stream could not be started") }
        }
        func stop() {
            guard let stream = reference else { return }
            reference = nil; FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        }
        deinit { stop() }
    }
}
