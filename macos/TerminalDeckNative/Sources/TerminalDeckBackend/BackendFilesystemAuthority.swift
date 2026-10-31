import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendFilesystemScope: Sendable {
    public let unrestricted: Bool
    public let readRoots: [URL]
    public let writeRoots: [URL]
    public init(readRoots: [URL], writeRoots: [URL] = [], unrestricted: Bool = false) {
        self.readRoots = readRoots; self.writeRoots = writeRoots; self.unrestricted = unrestricted
    }
    public static let local = Self(readRoots: [], writeRoots: [], unrestricted: true)
}

/// The scope provider is the authenticated host's current grant store. It is
/// re-read on every operation; a removed last folder is an empty grant, never a
/// fallback to the home directory. Constructors perform no filesystem reads.
public struct BackendFilesystemAuthority: Sendable {
    public enum Intent: Sendable, Equatable { case read, write }
    public struct Target: Sendable { public let root: URL; public let path: URL; public let relative: String }
    private let scope: @Sendable (NativeRPCContext) async throws -> BackendFilesystemScope
    public init(scope: @escaping @Sendable (NativeRPCContext) async throws -> BackendFilesystemScope) { self.scope = scope }

    public func authorize(_ absolute: String, context: NativeRPCContext, intent: Intent = .read,
                          mustExist: Bool = true) async throws -> URL {
        try Task.checkCancellation()
        guard absolute.hasPrefix("/"), !absolute.contains("\0") else { throw NativeRPCError.invalidArguments("The folder path must be absolute and contain no null byte") }
        let grants = try await scope(context)
        guard !grants.unrestricted || context.caller == .nativeApp || context.caller == .internalEngine else {
            throw NativeRPCError(code: "access-denied", message: "Remote/page filesystem scope cannot be unrestricted")
        }
        let url = try Self.canonical(URL(fileURLWithPath: absolute), mustExist: mustExist)
        if !grants.unrestricted {
            let roots = intent == .write ? grants.writeRoots : grants.readRoots + grants.writeRoots
            let admitted = roots.contains { root in
                guard let real = try? Self.canonical(root, mustExist: true) else { return false }
                return Self.within(url, real)
            }
            guard admitted else { throw NativeRPCError(code: "access-denied", message: "The path is outside this caller's current folder/device-home grant") }
        }
        try Task.checkCancellation()
        return url
    }

    public func resolve(root: String, relative: String, context: NativeRPCContext,
                        intent: Intent = .read, mustExist: Bool = true) async throws -> Target {
        guard !relative.hasPrefix("/"), !relative.contains("\0") else { throw NativeRPCError.invalidArguments("A file path must be relative to its project root") }
        let base = try await authorize(root, context: context, intent: intent)
        let lexical = base.appendingPathComponent(relative).standardizedFileURL
        guard Self.within(lexical, base) else { throw NativeRPCError(code: "path-escape", message: "The relative path leaves the project root") }
        let path = try Self.canonical(lexical, mustExist: mustExist)
        guard Self.within(path, base) else { throw NativeRPCError(code: "path-escape", message: "The symbolic link leaves the project root") }
        // Recheck after resolution so a grant removed during an await cannot
        // become a frozen permission for a later file read/mutation.
        _ = try await authorize(path.path, context: context, intent: intent, mustExist: mustExist)
        return Target(root: base, path: path, relative: Self.relative(path, to: base))
    }

    public static func canonical(_ input: URL, mustExist: Bool = true) throws -> URL {
        let path = input.standardizedFileURL.path
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
        }
        if mustExist { throw NativeRPCError(code: "filesystem", message: "The path could not be resolved (POSIX status \(errno))") }
        let parent = input.deletingLastPathComponent()
        guard parent.path != input.path else { throw NativeRPCError.invalidArguments("The destination path cannot be resolved") }
        return try canonical(parent, mustExist: true).appendingPathComponent(input.lastPathComponent).standardizedFileURL
    }
    public static func within(_ path: URL, _ root: URL) -> Bool {
        path.path == root.path || path.path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
    }
    public static func relative(_ path: URL, to root: URL) -> String {
        path.path == root.path ? "" : String(path.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
    }

    /// Open canonical path components relative to an owned root descriptor.
    /// No symlink introduced after authorization can redirect the file open.
    static func openStable(_ target: Target, directory: Bool = false) throws -> Int32 {
        var fd = open(target.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NativeRPCError(code: "filesystem", message: "The project folder could not be opened (POSIX status \(errno))") }
        let parts = target.relative.split(separator: "/").map(String.init)
        for (index, component) in parts.enumerated() {
            let last = index == parts.count - 1
            // O_NONBLOCK on the final file: opening a FIFO must never wait for a writer. Regular files are unaffected.
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (!last || directory ? O_DIRECTORY : O_NONBLOCK)
            let next = openat(fd, component, flags)
            let status = errno
            Darwin.close(fd)
            guard next >= 0 else { throw NativeRPCError(code: "filesystem", message: "The bounded file could not be opened (POSIX status \(status))") }
            fd = next
        }
        return fd
    }
}
