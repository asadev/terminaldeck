import Foundation
import Darwin

/// Launch-only migration. Call after claiming the app's exclusive data owner,
/// before constructing any Hoot/routine/action-log readers or writers. Failure
/// must stop those owners; it must not silently open an empty Hoot directory.
/// Archives are never automatically deleted, including after a read receipt.
public struct RNMHootDataMigration {
    public enum Checkpoint: Equatable, Sendable {
        case journalWritten
        case directoryRenamed(RNMHootPaths.Folder)
        case filePublished(RNMHootPaths.Folder, String)
        case beforeArchive(RNMHootPaths.Folder)
        case archiveMoved(RNMHootPaths.Folder)
        case folderCompleted(RNMHootPaths.Folder)
    }
    public struct Event: Codable, Equatable, Sendable {
        public let event: String
        public let folder: RNMHootPaths.Folder?
        public let at: Date
        public let launchID: UUID
        public let copied: Int
        public let collisions: Int
    }
    public struct Archive: Equatable, Sendable {
        public let folder: RNMHootPaths.Folder
        public let url: URL
        public let copied: Int
        public let collisionPaths: [String]
        /// Advisory only. No deletion operation exists in this migration.
        public let readOnSubsequentLaunch: Bool
    }
    public struct Launch: Equatable, Sendable {
        public let paths: RNMHootPaths
        public let id: UUID
        public let archives: [Archive]
    }

    public let paths: RNMHootPaths
    public init(paths: RNMHootPaths) { self.paths = paths }
    public init(dataRoot: URL) { self.init(paths: RNMHootPaths(dataRoot: dataRoot)) }

    /// The injected checkpoint is for temporary-folder interruption tests.
    /// Lock contention fails promptly; a second app must never race this launch.
    public func prepareForLaunch(
        id: UUID = UUID(), now: Date = Date(),
        report: (Event) -> Void = { _ in },
        checkpoint: (Checkpoint) throws -> Void = { _ in }
    ) throws -> Launch {
        try validateRoot()
        let lock = try Lease(paths.migrationLock)
        defer { lock.release() }
        var journal = try loadJournal()
        journal.activeLaunchID = id
        try save(journal)
        try checkpoint(.journalWritten)
        try log("launch", folder: nil, id: id, now: now, report: report)
        do {
            for folder in RNMHootPaths.Folder.allCases {
                let old = paths.legacyDirectory(folder), new = paths.directory(folder)
                if let index = journal.entries.firstIndex(where: { $0.folder == folder && !$0.completed }) {
                    try finish(index: index, journal: &journal, id: id, now: now, report: report, checkpoint: checkpoint)
                }
                // Another old writer may have recreated a legacy folder after a
                // previous completed migration. Treat that as a new transaction.
                if try kind(old) != nil {
                    try requireDirectory(old)
                    try validateTree(old)
                    let newKind = try kind(new)
                    if newKind != nil { try requireDirectory(new); try validateTree(new) }
                    let token = UUID()
                    let timestamp = Self.timestamp(now)
                    let archive = newKind == nil ? nil : "\(folder.legacyName).migrated-\(timestamp)-\(token.uuidString.lowercased())"
                    journal.entries.append(Entry(folder: folder, token: token, archiveName: archive))
                    try save(journal)
                    try checkpoint(.journalWritten)
                    try finish(index: journal.entries.count - 1, journal: &journal, id: id, now: now, report: report, checkpoint: checkpoint)
                } else if try kind(new) != nil {
                    try requireDirectory(new)
                }
            }
            return launch(journal, id: id)
        } catch {
            // The journal and the original bytes are retained on every failure.
            // Do not put the underlying file's contents or filenames in the log.
            try? log("failed", folder: nil, id: id, now: now, report: report)
            throw error
        }
    }

    /// Call only after the real readers successfully consume the new folder.
    /// A same-launch scaffold/write is not a read receipt. If another process
    /// has since launched, a stale receipt is refused and all archives remain.
    @discardableResult
    public func confirmRead(
        _ folders: Set<RNMHootPaths.Folder>, on launch: Launch,
        now: Date = Date(), report: (Event) -> Void = { _ in }
    ) throws -> Launch {
        guard launch.paths == paths else { throw failure("The Hoot migration read belongs to another data folder.") }
        try validateRoot()
        let lock = try Lease(paths.migrationLock)
        defer { lock.release() }
        var journal = try loadJournal()
        guard journal.activeLaunchID == launch.id else { throw failure("The Hoot migration read belongs to an earlier launch.") }
        for index in journal.entries.indices where folders.contains(journal.entries[index].folder) {
            let entry = journal.entries[index]
            guard entry.completed, entry.completedLaunchID != launch.id, entry.archiveName != nil else { continue }
            try requireDirectory(paths.directory(entry.folder))
            journal.entries[index].readLaunchID = launch.id
            try save(journal)
            try log("subsequent-launch-read", folder: entry.folder, id: launch.id, now: now, copied: entry.copiedPaths.count, collisions: entry.collisionPaths.count, report: report)
        }
        return self.launch(journal, id: launch.id)
    }

    private struct Journal: Codable {
        var version = 1
        var activeLaunchID: UUID?
        var entries: [Entry] = []
    }
    private struct Entry: Codable {
        let folder: RNMHootPaths.Folder
        let token: UUID
        let archiveName: String?
        var copiedPaths: [String] = []
        var collisionPaths: [String] = []
        var completed = false
        var completedLaunchID: UUID?
        var readLaunchID: UUID?
    }
    private func finish(
        index: Int, journal: inout Journal, id: UUID, now: Date,
        report: (Event) -> Void, checkpoint: (Checkpoint) throws -> Void
    ) throws {
        var entry = journal.entries[index]
        let old = paths.legacyDirectory(entry.folder), new = paths.directory(entry.folder)
        if let archiveName = entry.archiveName {
            let archive = paths.dataRoot.appendingPathComponent(archiveName, isDirectory: true)
            let stage = paths.dataRoot.appendingPathComponent(".hoot-migration-stage-\(entry.token.uuidString.lowercased())", isDirectory: true)
            if try kind(old) != nil {
                try requireDirectory(old); try requireDirectory(new)
                try validateTree(old); try validateTree(new)
                guard try kind(archive) == nil else { throw failure("The Hoot recovery archive already exists; the old folder was retained.") }
                if try kind(stage) == nil { try makeDirectory(stage) }
                try requireDirectory(stage); try validateTree(stage)
                try merge(old, into: new, relative: "", stage: stage, entry: &entry) { updated, published in
                    journal.entries[index] = updated
                    try save(journal)
                    try checkpoint(.filePublished(updated.folder, published))
                }
                journal.entries[index] = entry
                try save(journal)
                try checkpoint(.beforeArchive(entry.folder))
                try moveExclusive(old, to: archive)
                try syncDirectory(paths.dataRoot)
                try checkpoint(.archiveMoved(entry.folder))
            } else {
                // A process may have died after atomic archive publication but
                // before committing the completed journal record.
                try requireDirectory(archive); try requireDirectory(new)
            }
            // Also clean on recovery after archive publication. Only this
            // journal token's safe staging tree is eligible; it contains no
            // original data. A replaced/symlinked tree is refused, not followed.
            if try kind(stage) != nil {
                try requireDirectory(stage); try validateTree(stage)
                try FileManager.default.removeItem(at: stage)
                try syncDirectory(paths.dataRoot)
            }
        } else {
            if try kind(old) != nil {
                try requireDirectory(old); try validateTree(old)
                guard try kind(new) == nil else { throw failure("Hoot's destination appeared during recovery; neither folder was overwritten.") }
                try moveExclusive(old, to: new)
                try syncDirectory(paths.dataRoot)
                try checkpoint(.directoryRenamed(entry.folder))
            } else {
                // The atomic move succeeded before the process stopped.
                try requireDirectory(new)
            }
        }
        entry.completed = true
        entry.completedLaunchID = id
        journal.entries[index] = entry
        try save(journal)
        try log(entry.archiveName == nil ? "renamed" : "merged-and-archived", folder: entry.folder, id: id, now: now, copied: entry.copiedPaths.count, collisions: entry.collisionPaths.count, report: report)
        try checkpoint(.folderCompleted(entry.folder))
    }

    private func merge(
        _ source: URL, into destination: URL, relative: String, stage: URL,
        entry: inout Entry, published: (Entry, String) throws -> Void
    ) throws {
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
            let target = destination.appendingPathComponent(child.lastPathComponent)
            guard let sourceKind = try kind(child) else { throw failure("A Hoot source entry disappeared during migration.") }
            let targetKind = try kind(target)
            if sourceKind == .directory, targetKind == nil || targetKind == .directory {
                if targetKind == nil { try makeDirectory(target) }
                try merge(child, into: target, relative: name, stage: stage, entry: &entry, published: published)
            } else if targetKind != nil {
                // Both identical bytes and conflicting bytes are preserved in
                // the old archive. A file/directory mismatch is a collision too.
                if !entry.copiedPaths.contains(name), !entry.collisionPaths.contains(name) { entry.collisionPaths.append(name) }
            } else {
                guard sourceKind == .file else { throw failure("A Hoot source entry is not a regular file.") }
                let temporary = stage.appendingPathComponent(UUID().uuidString.lowercased())
                try FileManager.default.copyItem(at: child, to: temporary)
                try syncFile(temporary)
                // Publication cannot replace even a destination created between
                // the existence check and this atomic filesystem operation.
                do { try moveExclusive(temporary, to: target) }
                catch {
                    if try kind(target) != nil {
                        if !entry.collisionPaths.contains(name) { entry.collisionPaths.append(name) }
                        try FileManager.default.removeItem(at: temporary)
                        continue
                    }
                    throw error
                }
                try syncDirectory(destination)
                if !entry.copiedPaths.contains(name) { entry.copiedPaths.append(name) }
                try published(entry, name)
            }
        }
    }

    private enum Kind: Equatable { case file, directory }
    private func kind(_ url: URL) throws -> Kind? {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw failure("A Hoot migration path could not be inspected.")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: throw failure("Hoot migration refuses symbolic links and special files; all source data was retained.")
        }
    }
    private func requireDirectory(_ url: URL) throws {
        guard try kind(url) == .directory else { throw failure("A required Hoot migration folder is missing or is a file.") }
    }
    private func validateRoot() throws {
        guard paths.dataRoot.isFileURL, paths.dataRoot.path.hasPrefix("/"), paths.dataRoot.path != "/",
              !paths.dataRoot.path.contains("\0"),
              !paths.dataRoot.pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            throw failure("Hoot migration needs an absolute data folder without traversal components.")
        }
        // Check each existing ancestor without resolving through a symlink.
        // Callers using macOS /tmp or /var aliases should pass the explicit
        // kernel path (/private/tmp or /private/var), as the tests do.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in paths.dataRoot.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if try kind(current) == nil { try makeDirectory(current) }
            try requireDirectory(current)
        }
    }
    private func validateTree(_ directory: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if try kind(child) == .directory { try validateTree(child) }
        }
    }
    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func moveExclusive(_ source: URL, to destination: URL) throws {
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw failure("A Hoot migration move could not be published without replacing data.") }
    }
    private func loadJournal() throws -> Journal {
        guard try kind(paths.migrationJournal) != nil else { return Journal() }
        guard try kind(paths.migrationJournal) == .file else { throw failure("Hoot's migration journal is not a regular file.") }
        let data = try Data(contentsOf: paths.migrationJournal)
        guard data.count <= 16_777_216 else { throw failure("Hoot's migration journal is too large to recover safely.") }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: data) }
        catch { throw failure("Hoot's migration journal is unreadable; source folders were retained.") }
        guard journal.version == 1, journal.entries.allSatisfy({ entry in
            (entry.archiveName == nil || (entry.archiveName!.hasPrefix(entry.folder.legacyName + ".migrated-") && !entry.archiveName!.contains("/") && !entry.archiveName!.contains("\0"))) &&
            (!entry.completed || entry.completedLaunchID != nil) &&
            (entry.copiedPaths + entry.collisionPaths).allSatisfy { !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") && !$0.contains("\0") }
        }) else { throw failure("Hoot's migration journal has invalid recovery paths; source folders were retained.") }
        return journal
    }
    private func save(_ journal: Journal) throws {
        if try kind(paths.migrationJournal) != nil, try kind(paths.migrationJournal) != .file { throw failure("Hoot's migration journal cannot be replaced safely.") }
        let data = try JSONEncoder().encode(journal)
        let temporary = paths.dataRoot.appendingPathComponent(".hoot-migration-journal-\(UUID().uuidString.lowercased()).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Hoot's migration journal could not be staged.") }
        defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
        try write(data, fd: fd)
        guard Darwin.fsync(fd) == 0, Darwin.rename(temporary.path, paths.migrationJournal.path) == 0 else { throw failure("Hoot's migration journal could not be saved atomically.") }
        try syncDirectory(paths.dataRoot)
    }
    private func log(_ event: String, folder: RNMHootPaths.Folder?, id: UUID, now: Date, copied: Int = 0, collisions: Int = 0, report: (Event) -> Void) throws {
        let value = Event(event: event, folder: folder, at: now, launchID: id, copied: copied, collisions: collisions)
        var data = try JSONEncoder().encode(value); data.append(0x0a)
        if try kind(paths.migrationLog) != nil, try kind(paths.migrationLog) != .file { throw failure("Hoot's migration log is not a regular file.") }
        let fd = Darwin.open(paths.migrationLog.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Hoot's migration log could not be opened.") }
        defer { Darwin.close(fd) }
        try write(data, fd: fd)
        guard Darwin.fsync(fd) == 0 else { throw failure("Hoot's migration log could not be saved.") }
        report(value)
    }
    private func write(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("Hoot's migration record could not be written.") }
                offset += count
            }
        }
    }
    private func syncFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("A Hoot migration copy could not be opened for verification.") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw failure("A Hoot migration copy could not be flushed.") }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("A Hoot migration folder could not be opened for verification.") }
        defer { Darwin.close(fd) }
        guard Darwin.fsync(fd) == 0 else { throw failure("A Hoot migration folder could not be flushed.") }
    }
    private func launch(_ journal: Journal, id: UUID) -> Launch {
        Launch(paths: paths, id: id, archives: journal.entries.compactMap { entry in
            guard entry.completed, let name = entry.archiveName else { return nil }
            return Archive(folder: entry.folder, url: paths.dataRoot.appendingPathComponent(name, isDirectory: true), copied: entry.copiedPaths.count, collisionPaths: entry.collisionPaths, readOnSubsequentLaunch: entry.readLaunchID != nil)
        })
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter.string(from: date)
    }
    private func failure(_ message: String) -> NativeRPCError { .init(code: "hoot-migration", message: message) }

    private final class Lease {
        private var descriptor: Int32
        init(_ file: URL) throws {
            let fd = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw NativeRPCError(code: "hoot-migration", message: "Hoot's migration lock could not be opened.") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(fd)
                throw NativeRPCError(code: "hoot-migration", message: "Hoot's migration lock is not a regular file.")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                throw NativeRPCError(code: "hoot-migration-busy", message: "Another launch is migrating Hoot's data. Close that copy and try again.")
            }
            descriptor = fd
        }
        func release() {
            if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 }
        }
        deinit { release() }
    }
}
