import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// Descriptor based download writes. WebKit receives only a private staging
/// URL; a finished file is published with macOS's exclusive rename semantics.
/// No constructor opens a folder, and no downloaded bytes are transformed.
enum BackendBrowserDownloadsStorage {
    static func validPath(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/").contains("..") else {
            throw NativeRPCError.invalidArguments("A download folder must be an absolute path without control characters or parent traversal.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Each component is opened relative to the previous descriptor. A symlink
    /// anywhere in a selected path is refused instead of silently leaving it.
    static func directory(_ url: URL, create: Bool) throws -> Int32 {
        _ = try validPath(url.path)
        var held = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard held >= 0 else { throw failure("The download root could not be opened") }
        do {
            for part in url.path.split(separator: "/").map(String.init) {
                var next = openat(held, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(held, part, 0o700) == 0 || errno == EEXIST else { throw failure("The download folder could not be made") }
                    next = openat(held, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw failure("The download folder is unavailable or contains a symbolic link") }
                Darwin.close(held); held = next
            }
            return held
        } catch { Darwin.close(held); throw error }
    }

    static func exists(_ name: String, in fd: Int32) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    }

    static func candidate(_ suggested: String, in fd: Int32, taken: Set<String>) throws -> String {
        let clean = BrowserDownloadNaming.name(suggested)
        let path = URL(fileURLWithPath: clean)
        let ext = path.pathExtension
        let stem = ext.isEmpty ? clean : String(clean.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        for n in 1...BrowserDownloadNaming.maxVariants {
            let name = n == 1 ? clean : "\(stem) (\(n))\(suffix)"
            if !taken.contains(name), !exists(name, in: fd) { return name }
        }
        // Unlike the old timestamp-only fallback, even this branch checks for
        // a collision. A bounded failure never overwrites a person's file.
        for _ in 0..<32 {
            let name = "\(stem) (\(UUID().uuidString))\(suffix)"
            if !taken.contains(name), !exists(name, in: fd) { return name }
        }
        throw NativeRPCError(code: "download-destination", message: "A free download name could not be reserved.")
    }

    final class Reservation: @unchecked Sendable {
        let folder: URL
        let finalName: String
        let directoryFD: Int32
        let stageFD: Int32
        let stageName: String
        var stageURL: URL { folder.appendingPathComponent(stageName).appendingPathComponent("payload") }

        init(folder: URL, suggested: String, taken: Set<String>) throws {
            let parent = try BackendBrowserDownloadsStorage.directory(folder, create: true)
            do {
                let final = try BackendBrowserDownloadsStorage.candidate(suggested, in: parent, taken: taken)
                let stage = ".td-download-" + UUID().uuidString
                guard mkdirat(parent, stage, 0o700) == 0 else { throw BackendBrowserDownloadsStorage.failure("The private download staging folder could not be made") }
                let child = openat(parent, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { _ = unlinkat(parent, stage, AT_REMOVEDIR); throw BackendBrowserDownloadsStorage.failure("The private download staging folder could not be opened") }
                self.folder = folder; finalName = final; directoryFD = parent; stageFD = child; stageName = stage
            } catch { Darwin.close(parent); throw error }
        }
        deinit { Darwin.close(stageFD); Darwin.close(directoryFD) }

        func verifyStagePath() throws {
            let current = try BackendBrowserDownloadsStorage.directory(folder.appendingPathComponent(stageName), create: false)
            defer { Darwin.close(current) }
            var a = stat(), b = stat()
            guard fstat(current, &a) == 0, fstat(stageFD, &b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev else {
                throw NativeRPCError(code: "download-destination", message: "The download folder changed while this file was moving.")
            }
        }

        func commit(taken: Set<String>) throws -> LandedFile {
            try verifyStagePath()
            let input = openat(stageFD, "payload", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw BackendBrowserDownloadsStorage.failure("WebKit did not leave a readable download file") }
            defer { Darwin.close(input) }
            var source = stat()
            guard fstat(input, &source) == 0, (source.st_mode & S_IFMT) == S_IFREG else {
                throw NativeRPCError(code: "download-destination", message: "The download payload is not an ordinary file.")
            }
            var name = finalName
            for _ in 0..<32 {
                let receipt = try LandedFile(folder: folder, name: name, parentFD: directoryFD, identity: source)
                if renameatx_np(stageFD, "payload", directoryFD, name, UInt32(RENAME_EXCL)) == 0 {
                    var linked = stat()
                    guard fstatat(directoryFD, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                          (linked.st_mode & S_IFMT) == S_IFREG, linked.st_ino == source.st_ino, linked.st_dev == source.st_dev else {
                        _ = unlinkat(directoryFD, name, 0)
                        throw NativeRPCError(code: "download-destination", message: "The staged download changed before it could be saved.")
                    }
                    cleanup()
                    return receipt
                }
                guard errno == EEXIST else { throw BackendBrowserDownloadsStorage.failure("The completed download could not be saved") }
                name = try BackendBrowserDownloadsStorage.candidate(finalName, in: directoryFD, taken: taken)
            }
            throw NativeRPCError(code: "download-destination", message: "The download destination kept changing; the staged file was retained.")
        }

        func cleanup() {
            _ = unlinkat(stageFD, "payload", 0)
            var held = stat(), current = stat()
            if fstat(stageFD, &held) == 0, fstatat(directoryFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               (current.st_mode & S_IFMT) == S_IFDIR, held.st_ino == current.st_ino, held.st_dev == current.st_dev {
                _ = unlinkat(directoryFD, stageName, AT_REMOVEDIR)
            }
        }
    }

    final class LandedFile: @unchecked Sendable {
        let folder: URL
        let name: String
        let parentFD: Int32
        let device: dev_t
        let inode: ino_t
        let size: Int64
        var url: URL { folder.appendingPathComponent(name) }
        init(folder: URL, name: String, parentFD: Int32, identity: stat) throws {
            let copy = fcntl(parentFD, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw BackendBrowserDownloadsStorage.failure("The completed download could not be retained") }
            self.folder = folder; self.name = name; self.parentFD = copy
            device = identity.st_dev; inode = identity.st_ino; size = max(0, Int64(identity.st_size))
        }
        deinit { Darwin.close(parentFD) }
        func open() throws -> Int32 {
            let file = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw BackendBrowserDownloadsStorage.failure("The downloaded file is no longer available") }
            var info = stat()
            guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_dev == device, info.st_ino == inode else {
                Darwin.close(file)
                throw NativeRPCError(code: "download-changed", message: "The downloaded file was replaced; this operation was refused.")
            }
            return file
        }
        func removeOwnedCopy() throws {
            let file = try open(); Darwin.close(file)
            guard unlinkat(parentFD, name, 0) == 0 else { throw BackendBrowserDownloadsStorage.failure("The delivered local copy could not be removed") }
        }
        func digest() throws -> String {
            let fd = try open(); defer { Darwin.close(fd) }
            var hash = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw BackendBrowserDownloadsStorage.failure("The completed download could not be read for its digest") }
                if count == 0 { break }
                hash.update(data: Data(buffer.prefix(count)))
            }
            return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func readLedger(root: URL) throws -> Data? {
        let dir = try directory(root, create: true); defer { Darwin.close(dir) }
        let fd = openat(dir, "browser-downloads.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("The download history could not be read") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 4 * 1024 * 1024 else {
            throw NativeRPCError(code: "download-history", message: "The saved download history is not a bounded ordinary file.")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 4 * 1024 * 1024 else { throw NativeRPCError(code: "download-history", message: "The saved download history grew beyond its size limit.") }
        return bytes
    }

    static func writeLedger(_ data: Data, root: URL) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw NativeRPCError(code: "download-history", message: "The download history is too large to persist safely; clear finished rows.") }
        let dir = try directory(root, create: true); defer { Darwin.close(dir) }
        let temporary = ".browser-downloads-" + UUID().uuidString + ".tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("The download history could not be staged") }
        defer { Darwin.close(fd); _ = unlinkat(dir, temporary, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, renameat(dir, temporary, dir, "browser-downloads.json") == 0 else { throw failure("The download history could not be saved") }
        _ = fsync(dir)
    }

    static func readableFile(_ url: URL) throws -> (receipt: LandedFile, executable: Bool) {
        _ = try validPath(url.path)
        let dir = try directory(url.deletingLastPathComponent(), create: false); defer { Darwin.close(dir) }
        let fd = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("That downloaded file is not there any more") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw NativeRPCError(code: "download-file", message: "That downloaded path is not an ordinary file.")
        }
        return (try LandedFile(folder: url.deletingLastPathComponent(), name: url.lastPathComponent, parentFD: dir, identity: info), info.st_mode & 0o111 != 0)
    }

    static func failure(_ message: String) -> NativeRPCError {
        NativeRPCError(code: "download-filesystem", message: "\(message) (POSIX status \(errno)).")
    }
}
