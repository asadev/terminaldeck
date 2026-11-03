import Foundation
import Darwin
import TerminalDeckNativeCore

/// local-stage.ts / attach-bring-in.ts: real bounded copies, exclusive names,
/// atomic publication and cleanup on cancellation. Sources never move. No
/// directory recursion, credential handoff, or caller-selected upload directory.
public struct BackendFilesystemTransfers: Sendable {
    public static let maximumBytes = 512 * 1024 * 1024
    private let authority: BackendFilesystemAuthority
    private let uploads: @Sendable () async throws -> URL
    public init(authority: BackendFilesystemAuthority, uploadsDirectory: @escaping @Sendable () async throws -> URL) {
        self.authority = authority; uploads = uploadsDirectory
    }
    public func stage(name: String, bytes: Data) async -> NativeRPCValue {
        guard !bytes.isEmpty else { return Self.failure("There was nothing to send.") }
        guard bytes.count <= Self.maximumBytes else { return Self.failure("That is too big to send — the limit is 512 MB.") }
        do {
            let folder = try await uploads()
            let work = Task.detached(priority: .utility) { try Self.save(name: name, folder: folder, bytes: bytes) }
            let path = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            return .object([.init("ok", .bool(true)), .init("path", .string(path))])
        } catch { return Self.failure(error is CancellationError ? "The file transfer was cancelled." : "That could not be saved on this machine.") }
    }
    public func bringIn(source: String, folder: String, context: NativeRPCContext, refuseCredentials: Bool = false) async throws -> String {
        let sourceURL = try await authority.authorize(source, context: context)
        if refuseCredentials && (BackendFilesystemIgnore.credentialPath(source) || BackendFilesystemIgnore.credentialPath(sourceURL.path)) {
            throw NativeRPCError(code: "access-denied", message: "Credential-shaped files are not handed to sessions through tools")
        }
        let destination = try await authority.resolve(root: folder, relative: "Terminal Deck", context: context, intent: .write, mustExist: false)
        let base = sourceURL.deletingLastPathComponent()
        let bounded = BackendFilesystemAuthority.Target(root: base, path: sourceURL, relative: sourceURL.lastPathComponent)
        let work = Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: destination.path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let real = try BackendFilesystemAuthority.canonical(destination.path)
            guard BackendFilesystemAuthority.within(real, destination.root) else { throw NativeRPCError(code: "path-escape", message: "The session's attachment folder left its boundary") }
            let sourceFD = try BackendFilesystemAuthority.openStable(bounded)
            defer { Darwin.close(sourceFD) }
            var info = stat()
            guard fstat(sourceFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maximumBytes else {
                throw NativeRPCError.invalidArguments("Only a regular file of at most 512 MB can be brought inside a session")
            }
            return try Self.copy(name: sourceURL.lastPathComponent, folder: real, sourceFD: sourceFD)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    public static func safeName(_ proposed: String) -> String {
        let last = proposed.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "file"
        let clean = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(240))
        return clean.isEmpty || [".", ".."].contains(clean) ? "file" : clean
    }
    private static func failure(_ message: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("message", .string(message))]) }
    private static func save(name: String, folder: URL, bytes: Data) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try publish(name: name, folder: folder) { output in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let size = min(64 * 1024, bytes.count - offset)
                let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), size) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NativeRPCError(code: "filesystem", message: "The staged file write failed (POSIX status \(errno))") }
                offset += written
            }
        }
    }
    private static func copy(name: String, folder: URL, sourceFD: Int32) throws -> String {
        try publish(name: name, folder: folder) { output in
            var bytes = [UInt8](repeating: 0, count: 64 * 1024), total = 0
            while true {
                try Task.checkCancellation()
                let count = bytes.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress!, $0.count) }
                if count == 0 { return }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeRPCError(code: "filesystem", message: "The attachment source could not be read") }
                total += count
                guard total <= maximumBytes else { throw NativeRPCError.invalidArguments("The attachment grew beyond the 512 MB limit") }
                var offset = 0
                while offset < count {
                    let written = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw NativeRPCError(code: "filesystem", message: "The attachment could not be copied") }
                    offset += written
                }
            }
        }
    }
    private static func publish(name: String, folder: URL, write: (Int32) throws -> Void) throws -> String {
        let real = try BackendFilesystemAuthority.canonical(folder)
        let directoryFD = open(real.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw NativeRPCError(code: "filesystem", message: "The upload folder could not be opened") }
        defer { Darwin.close(directoryFD) }
        let temporary = ".td-upload-" + UUID().uuidString + ".part"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeRPCError(code: "filesystem", message: "The upload could not be started") }
        defer { Darwin.close(fd); unlinkat(directoryFD, temporary, 0) }
        try write(fd)
        try Task.checkCancellation()
        guard fsync(fd) == 0 else { throw NativeRPCError(code: "filesystem", message: "The upload could not be saved") }
        let safe = safeName(name), url = URL(fileURLWithPath: safe), suffix = url.pathExtension
        let stem = suffix.isEmpty ? safe : String(safe.dropLast(suffix.count + 1))
        for attempt in 1...99 {
            let candidate = attempt == 1 ? safe : stem + " (\(attempt))" + (suffix.isEmpty ? "" : "." + suffix)
            if linkat(directoryFD, temporary, directoryFD, candidate, 0) == 0 { return real.appendingPathComponent(candidate).path }
            if errno != EEXIST { throw NativeRPCError(code: "filesystem", message: "The upload could not be published (POSIX status \(errno))") }
        }
        throw NativeRPCError(code: "filesystem", message: "Every attachment name is already taken")
    }
}
