import Foundation
import Darwin
import TerminalDeckNativeCore

/// The seven AIR fixes write one top-level text file. Existing files are only
/// appended to; their contents are never returned in a preview or replaced.
struct BackendAIRFilePlan: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        init(_ value: stat) { device = UInt64(truncatingIfNeeded: value.st_dev); inode = UInt64(value.st_ino) }
    }
    struct Snapshot: Sendable, Equatable {
        let identity: Identity
        let bytes: Data
    }
    let root: String
    let rootIdentity: Identity
    let relative: String
    let before: Snapshot?
    /// Exact newly written bytes. For an existing file these are appended.
    let added: Data

    var previewChange: AIRReadinessFileChange {
        .init(path: relative, before: nil, after: String(decoding: added, as: UTF8.self),
              action: before == nil ? "Create file" : "Append these exact lines")
    }

    private static func failure(_ code: String, _ message: String) -> NativeRPCError {
        .init(code: code, message: message)
    }
    private static func rootDescriptor(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("filesystem", "The project folder could not be opened. Re-check the project before trying again.") }
        return descriptor
    }
    private static func identity(_ descriptor: Int32) throws -> Identity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw failure("filesystem", "The project file could not be inspected.") }
        return Identity(value)
    }
    private static func read(_ descriptor: Int32) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 1_048_576 else {
            throw failure("fix-unavailable", "AIR can only preview ordinary text files smaller than 1 MB with no hard links. Use the listed steps or ask an AI.")
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw failure("filesystem", "The project file could not be read.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw failure("filesystem", "The project file could not be read.") }
            if count == 0 { break }
            guard data.count + count <= 1_048_576 else { throw failure("fix-unavailable", "The project file grew beyond the preview limit. Re-check it before trying again.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    static func snapshot(root: String, relative: String) throws -> (Identity, Snapshot?) {
        guard !relative.isEmpty, !relative.contains("/"), !relative.contains("\0"), relative != ".", relative != ".." else {
            throw failure("path-escape", "AIR fixes only use the listed top-level project file.")
        }
        let folder = try rootDescriptor(root); defer { Darwin.close(folder) }
        let rootIdentity = try identity(folder)
        var info = stat()
        if fstatat(folder, relative, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw failure("filesystem", "The readiness file could not be inspected.") }
            return (rootIdentity, nil)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw failure("fix-unavailable", "The readiness file is a link, hard link or special file. Use the listed steps or ask an AI.")
        }
        let descriptor = openat(folder, relative, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("filesystem", "The readiness file could not be opened safely.") }
        defer { Darwin.close(descriptor) }
        guard try identity(descriptor) == Identity(info) else { throw failure("stale-preview", "The file changed during the preview. Re-check it and make a new preview.") }
        let bytes = try read(descriptor)
        guard String(data: bytes, encoding: .utf8) != nil else { throw failure("fix-unavailable", "The readiness file is not UTF-8 text. Use the listed steps or ask an AI.") }
        return (rootIdentity, Snapshot(identity: Identity(info), bytes: bytes))
    }

    private static func write(_ data: Data, descriptor: Int32) throws {
        var written = 0
        try data.withUnsafeBytes { buffer in
            while written < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 { if errno == EINTR { continue }; throw failure("filesystem", "The file could not be fully saved. Re-check the project before retrying.") }
                guard count > 0 else { throw failure("filesystem", "The file could not be fully saved. Re-check the project before retrying.") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw failure("filesystem", "The file was written, but saving it to disk could not be confirmed. Re-check the project.") }
    }

    /// No await occurs between the last byte/name check and the write. O_EXCL
    /// protects new files; append-only writes preserve all existing bytes.
    func apply() throws {
        try Task.checkCancellation()
        let folder = try Self.rootDescriptor(root); defer { Darwin.close(folder) }
        guard try Self.identity(folder) == rootIdentity else { throw Self.failure("stale-preview", "The project folder changed. Re-check it and make a new preview.") }
        if let before {
            let descriptor = openat(folder, relative, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.failure("stale-preview", "The file changed or is no longer writable. Make a new preview.") }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure("stale-preview", "Another operation is using this file. Make a new preview when it finishes.") }
            defer { _ = flock(descriptor, LOCK_UN) }
            var named = stat()
            guard fstatat(folder, relative, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_nlink == 1, Self.Identity(named) == before.identity, try Self.identity(descriptor) == before.identity,
                  try Self.read(descriptor) == before.bytes else {
                throw Self.failure("stale-preview", "The file changed since this preview. Your changes were kept; make a new preview.")
            }
            try Self.write(added, descriptor: descriptor)
            guard try Self.read(descriptor) == before.bytes + added,
                  fstatat(folder, relative, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  Identity(named) == before.identity else {
                throw Self.failure("filesystem", "The file changed while it was being saved. Re-check the project before doing anything else.")
            }
        } else {
            let descriptor = openat(folder, relative, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw Self.failure("stale-preview", "That file now exists or cannot be created. Nothing was overwritten; make a new preview.") }
            defer { Darwin.close(descriptor) }
            try Self.write(added, descriptor: descriptor)
        }
        guard fsync(folder) == 0 else { throw Self.failure("filesystem", "The file was written, but saving the folder could not be confirmed. Re-check the project.") }
    }
}
