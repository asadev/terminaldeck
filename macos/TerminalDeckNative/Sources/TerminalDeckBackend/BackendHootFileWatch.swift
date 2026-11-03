import Foundation
import Darwin

/// Watches a few named files without polling (#26, 3 Nov: Hoot's island re-read Claude's settings on every app event).
/// The kernel says when a watched file is written, replaced, removed or created: one vnode source per file that exists
/// and one per nearest existing folder above each file (a folder event catches a file created later or replaced by a
/// rename). A burst of events is folded into one check `debounce` seconds after the last one. The check compares each
/// file's stamp (device, inode, size, modified and changed times) with the one it saw before and reports only the files
/// that really moved, so a busy folder costs one `stat` per watched file per burst, and the app's own events cost nothing.
public final class BackendHootFileWatch: @unchecked Sendable {
    public struct Stamp: Equatable, Sendable {
        let device: Int64, inode: UInt64, size: Int64
        let modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
    }
    public static func stamp(_ path: String) -> Stamp? {
        // A settings file can be a link (dotfiles): stamp the file it points to, as `open` watches that one.
        let resolved = realpath(path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) } ?? path
        var info = stat()
        guard lstat(resolved, &info) == 0 else { return nil }
        return Stamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                     modified: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                     changed: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }

    public let files: [String]
    private let debounce: DispatchTimeInterval
    private let queue = DispatchQueue(label: "dev.terminaldeck.hoot.file-watch", qos: .utility)
    private let changed: @Sendable (Set<String>) -> Void
    // Only touched on `queue`.
    private var stamps: [String: Stamp] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    private var stopped = false

    /// Takes each file's stamp now, so a change from this moment on is reported (a caller reads the files after this).
    public init(files: [URL], debounce: TimeInterval = 0.25, changed: @escaping @Sendable (Set<String>) -> Void) {
        self.files = Array(Set(files.map { $0.standardizedFileURL.path })).sorted()
        self.debounce = .milliseconds(max(0, Int(debounce * 1000)))
        self.changed = changed
        queue.sync {
            for file in self.files { self.stamps[file] = Self.stamp(file) }
            self.arm()
        }
    }
    deinit { for source in sources.values { source.cancel() } }

    public func stop() {
        queue.sync {
            stopped = true; pending?.cancel(); pending = nil
            for source in sources.values { source.cancel() }
            sources = [:]
        }
    }

    /// One source per existing file and per nearest existing folder above each file; gone ones are dropped.
    private func arm() {
        var wanted: Set<String> = []
        for file in files {
            if stamps[file] != nil { wanted.insert(file) }
            wanted.insert(Self.nearestFolder(above: file))
        }
        for (path, source) in sources where !wanted.contains(path) { source.cancel(); sources[path] = nil }
        for path in wanted where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                self.event(path, source.data)
            }
            source.setCancelHandler { close(descriptor) }
            sources[path] = source
            source.resume()
        }
    }
    private func event(_ path: String, _ flags: DispatchSource.FileSystemEvent) {
        guard !stopped else { return }
        // Removed, renamed or replaced: this source watches the old file now; the check opens the new one.
        if !flags.isDisjoint(with: [.delete, .rename, .revoke]) { sources[path]?.cancel(); sources[path] = nil }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
    private func check() {
        guard !stopped else { return }
        pending = nil
        var moved: Set<String> = []
        for file in files {
            let now = Self.stamp(file)
            if stamps[file] != now { stamps[file] = now; moved.insert(file) }
        }
        arm()
        if !moved.isEmpty { changed(moved) }
    }
    static func nearestFolder(above file: String) -> String {
        var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
        var isFolder: ObjCBool = false
        while folder.path != "/" && !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue) {
            folder.deleteLastPathComponent()
        }
        return folder.path
    }
}

/// A change number many owners can bump from any thread (a watcher's queue, a settings listener) and read without a
/// hop: whoever cached something compares the number it cached under with the current one.
public final class BackendHootChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    public init() {}
    public var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    public func bump() { lock.lock(); value &+= 1; lock.unlock() }
}
