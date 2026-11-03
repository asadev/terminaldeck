import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// Exact declared agent files through the existing live file authorizer. No
/// client-selected path, global store or file-status polling is introduced.
public struct BackendAGOPTProfileDocuments: Sendable {
    public static let maximumBytes = 512_000
    public let authority: BackendFilesystemAuthority
    public let access: BackendAGOPTProfileAccess
    public let currentProfile: @Sendable (String) async throws -> NativeRPCValue?
    public let managedPath: @Sendable (String) async throws -> String?
    public init(authority: BackendFilesystemAuthority, access: BackendAGOPTProfileAccess,
                currentProfile: @escaping @Sendable (String) async throws -> NativeRPCValue?,
                managedPath: @escaping @Sendable (String) async throws -> String?) {
        self.authority = authority; self.access = access; self.currentProfile = currentProfile; self.managedPath = managedPath
    }
    private func path(_ id: String, _ profile: NativeRPCValue) async throws -> String? {
        if let source = profile["sourceFile"].string { return source }
        if let file = profile["instructionsFile"].string { return file }
        return try await managedPath(id)
    }
    public func read(call: BackendAGOPTProfileCall, id: String, profile: NativeRPCValue) async throws -> NativeRPCValue {
        try await access.require(call, id, false)
        guard let path = try await path(id, profile) else {
            return .object([.init("state", .string("unconfigured")), .init("path", .null), .init("body", .null), .init("revision", .null), .init("can_save", .bool(false))])
        }
        let rpc = try await access.rpc(call)
        let target = try await authority.authorize(path, context: rpc, mustExist: false)
        var info = stat()
        if lstat(target.path, &info) != 0, errno == ENOENT {
            return .object([.init("state", .string("missing")), .init("path", .string(path)), .init("body", .null), .init("revision", .null), .init("can_save", .bool(false))])
        }
        let read = try Self.readStable(target)
        return .object([.init("state", .string("ready")), .init("path", .string(path)), .init("body", .string(read.text)), .init("revision", .string(read.hash)),
                        .init("bytes", .number(Double(read.data.count))), .init("imported", .bool(profile["sourceFile"].string != nil)),
                        .init("extra_instructions", profile["extraTaskInstructions"].isNullish && profile["sourceFile"].string != nil ? profile["instructions"] : profile["extraTaskInstructions"]),
                        .init("can_save", .bool(true))])
    }
    public func save(call: BackendAGOPTProfileCall, id: String, profile: NativeRPCValue, text: String, hash: String, keepMine: Bool) async throws -> NativeRPCValue {
        try await access.require(call, id, true)
        guard let path = try await path(id, profile) else { throw NativeRPCError(code: "unavailable", message: "This agent has no declared instructions file.") }
        guard text.utf8.count <= Self.maximumBytes, !text.contains("\0") else { throw NativeRPCError.invalidArguments("Save plain instructions under 512 KB.") }
        let rpc = try await access.rpc(call)
        let target = try await authority.authorize(path, context: rpc, intent: .write)
        let before = try Self.readStable(target)
        guard keepMine || before.hash == hash else { throw conflict() }
        let proposal = NativeRPCValue.object([.init("id", .string(id)), .init("revision", .string(before.hash)), .init("overwrite", .bool(keepMine)), .init("bytes", .number(Double(text.utf8.count)))])
        try await access.authorize(call, "agents.instructions_set", proposal, keepMine ? "Replace the current conflicting instructions file for \(id) with the reviewed text." : "Save the reviewed instructions in \(id)'s own file.")
        try await access.require(call, id, true)
        guard let current = try await currentProfile(id), try await self.path(id, current) == path else { throw conflict() }
        let approved = try await authority.authorize(path, context: rpc, intent: .write)
        guard approved == target else { throw conflict() }
        try Self.publish(Data(text.utf8), target: target, expectedHash: before.hash)
        return try await read(call: call, id: id, profile: current)
    }
    private func conflict() -> NativeRPCError { .init(code: "file-changed", message: "This file changed on disk. Use the file, or review Keep mine before saving.") }
    private struct Read { let text: String, hash: String, data: Data, mode: mode_t }
    private static func bounded(_ fd: Int32) throws -> Read {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumBytes else {
            throw NativeRPCError(code: "instructions-file-refused", message: "The agent instructions must be a regular file under 512 KB.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= maximumBytes else { throw NativeRPCError(code: "instructions-file-refused", message: "The agent instructions could not be read within their limit.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else { throw NativeRPCError.invalidArguments("The agent instructions must be plain UTF-8 text.") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Read(text: text, hash: hash, data: data, mode: info.st_mode & 0o777)
    }
    private static func readStable(_ path: URL) throws -> Read {
        let target = BackendFilesystemAuthority.Target(root: path.deletingLastPathComponent(), path: path, relative: path.lastPathComponent)
        let fd = try BackendFilesystemAuthority.openStable(target); defer { Darwin.close(fd) }
        return try bounded(fd)
    }
    /// Parent descriptor stays bound through the checked atomic replacement;
    /// replacing a path with a symlink cannot redirect this save elsewhere.
    private static func publish(_ bytes: Data, target: URL, expectedHash: String) throws {
        let folder = target.deletingLastPathComponent()
        let root = BackendFilesystemAuthority.Target(root: folder, path: folder, relative: "")
        let dir = try BackendFilesystemAuthority.openStable(root, directory: true); defer { Darwin.close(dir) }
        let name = target.lastPathComponent
        func current() throws -> Read {
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NativeRPCError(code: "file-changed", message: "The agent file changed while saving.") }
            defer { Darwin.close(fd) }; return try bounded(fd)
        }
        let old = try current()
        guard old.hash == expectedHash else { throw NativeRPCError(code: "file-changed", message: "The agent file changed after it was reviewed.") }
        let part = ".agopt-" + UUID().uuidString + ".tmp"
        let fd = openat(dir, part, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, old.mode)
        guard fd >= 0 else { throw NativeRPCError(code: "filesystem", message: "The reviewed instructions could not be prepared.") }
        guard fchmod(fd, old.mode) == 0 else { Darwin.close(fd); unlinkat(dir, part, 0); throw NativeRPCError(code: "filesystem", message: "The agent file permissions could not be preserved.") }
        defer { Darwin.close(fd); unlinkat(dir, part, 0) }
        var written = 0
        while written < bytes.count {
            try Task.checkCancellation()
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), bytes.count - written) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeRPCError(code: "filesystem", message: "The reviewed instructions could not be saved.") }; written += count
        }
        try Task.checkCancellation()
        guard fsync(fd) == 0, try current().hash == expectedHash, renameat(dir, part, dir, name) == 0 else {
            throw NativeRPCError(code: "file-changed", message: "The agent file changed, or its replacement could not be saved.")
        }
        _ = fsync(dir)
    }
}
