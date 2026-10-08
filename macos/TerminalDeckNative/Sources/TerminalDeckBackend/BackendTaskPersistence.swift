import Foundation
import Darwin
import TerminalDeckNativeCore

/// Shared private persistence for this lane. Construction is inert; the owner
/// explicitly starts services only after the original engine gives up writes.
public struct BackendTaskPersistence: Sendable {
    public let directory: URL
    public let ownership: NativeStateStore.Ownership
    public init(directory: URL, ownership: NativeStateStore.Ownership = .readOnly) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw NativeRPCError.invalidArguments("Task persistence requires the app's absolute data directory")
        }
        self.directory = directory.standardizedFileURL; self.ownership = ownership
    }
    public func writable() throws {
        guard ownership == .exclusive || ownership == .memory else {
            throw NativeRPCError(code: "read-only", message: "The original engine still owns these records; native writes are disabled")
        }
    }
    public func file(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            throw NativeRPCError.invalidArguments("Invalid private record filename")
        }
        return directory.appendingPathComponent(name)
    }
    public func read(_ name: String, maximumBytes: Int = 32 * 1024 * 1024) throws -> NativeRPCValue? {
        if ownership == .memory { return nil }
        let url = try file(name)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw posix("read record") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumBytes else {
            throw NativeRPCError(code: "record-unreadable", message: "The private record is not a supported regular file")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }; if count < 0 { if errno == EINTR { continue }; throw posix("read record") }
            guard data.count + count <= maximumBytes else { throw NativeRPCError.malformed("Private record is too large") }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try NativeRPCValue.parseJSON(data, maximumBytes: maximumBytes)
    }
    /// Exact owned bytes for a rollback; no JSON re-encoding or link traversal.
    public func readOwnedBytes(_ name: String, maximumBytes: Int = 4 * 1024 * 1024) throws -> Data? {
        if ownership == .memory { return nil }
        let target = try file(name)
        let descriptor = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT { return nil }; throw posix("read private rollback record") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= maximumBytes else {
            throw NativeRPCError(code: "record-unreadable", message: "The private rollback record is not a bounded regular file")
        }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return bytes }
            if count < 0 { if errno == EINTR { continue }; throw posix("read private rollback record") }
            guard bytes.count + count <= maximumBytes else { throw NativeRPCError.malformed("Private rollback record is too large") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }
    public func write(_ name: String, value: NativeRPCValue) throws { try writeBytes(name, data: value.encodedJSON(pretty: true)) }
    public func writeBytes(_ name: String, data: Data, replace: Bool = true) throws {
        try writable(); if ownership == .memory { return }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = try file(name), temporary = directory.appendingPathComponent(".native-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("create private record") }
        defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 { if errno == EINTR { continue }; throw posix("write private record") }
                guard count > 0 else { throw posix("write private record") }; done += count
            }
        }
        guard fsync(fd) == 0 else { throw posix("sync private record") }
        if replace {
            var existing = stat()
            if lstat(target.path, &existing) == 0, existing.st_mode & S_IFMT != S_IFREG {
                throw NativeRPCError(code: "record-unwritable", message: "A private record path is not a regular file")
            }
            guard rename(temporary.path, target.path) == 0 else { throw posix("publish private record") }
        } else {
            guard link(temporary.path, target.path) == 0 else { throw posix("create private record without replacing edits") }
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); Darwin.close(parent) }
    }
    public func remove(_ name: String) throws {
        try writable(); if ownership == .memory { return }
        let url = try file(name)
        if unlink(url.path) != 0, errno != ENOENT { throw posix("remove private record") }
    }
    public func append(_ name: String, value: NativeRPCValue) throws {
        try writable(); if ownership == .memory { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(try file(name).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("append private log") }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw posix("append private log") }
        var data = try value.encodedJSON(); data.append(10)
        try data.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: done), raw.count - done)
                if count < 0 { if errno == EINTR { continue }; throw posix("append private log") }
                guard count > 0 else { throw posix("append private log") }; done += count
            }
        }
    }
    private func posix(_ operation: String) -> NativeRPCError {
        NativeRPCError(code: "persistence-failed", message: "Could not \(operation): \(String(cString: strerror(errno)))")
    }
}

enum BackendTaskValues {
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    static func time() -> Double { BackendTaskClockContext.clock.now() }
    static func text(_ value: NativeRPCValue, _ label: String, max: Int, required: Bool = false) throws -> String? {
        if value.isNullish { if required { throw NativeRPCError.invalidArguments("\(label) cannot be empty.") }; return nil }
        guard let raw = value.string else { throw NativeRPCError.invalidArguments("\(label) has to be text.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !required || !text.isEmpty else { throw NativeRPCError.invalidArguments("\(label) cannot be empty.") }
        guard text.utf16.count <= max else { throw NativeRPCError.invalidArguments("\(label) is longer than \(max) characters.") }; return text
    }
    static func strings(_ value: NativeRPCValue, label: String, maximum: Int, length: Int) throws -> [String] {
        if value.isNullish { return [] }; var seen = Set<String>(), result: [String] = []
        for entry in try value.requireArray(label) {
            if let text = try text(entry, label, max: length, required: true), seen.insert(text).inserted { result.append(text) }
        }
        guard result.count <= maximum else { throw NativeRPCError.invalidArguments("\(label) takes at most \(maximum).") }; return result
    }
    static func whole(_ value: NativeRPCValue, label: String, min: Int, max: Int, fallback: Int) throws -> Int {
        if value.isNullish { return fallback }
        guard let number = value.number, number.rounded() == number, number >= Double(min), number <= Double(max) else {
            throw NativeRPCError.invalidArguments("\(label) has to be a whole number from \(min) to \(max).")
        }; return Int(number)
    }
}
