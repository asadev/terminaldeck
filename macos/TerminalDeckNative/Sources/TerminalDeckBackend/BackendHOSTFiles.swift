import Foundation
import Security
import Darwin

public struct BackendHOSTPaths: Sendable {
    public let dataDirectory: URL
    public let namespace: String?
    public let directory: URL
    public var socket: String { directory.appendingPathComponent("control.sock").path }
    public var secretFile: URL { directory.appendingPathComponent("secret") }
    public var activeFile: URL { directory.appendingPathComponent("sessions-active") }
    public init(dataDirectory: URL, namespace: String? = nil) throws {
        guard dataDirectory.isFileURL, dataDirectory.path.hasPrefix("/"), dataDirectory.path != "/",
              !dataDirectory.path.contains("\0"), namespace == nil || namespace == "agents" else { throw BackendHOSTFailure.invalid("The host needs an absolute app data folder and a supported namespace.") }
        self.dataDirectory = dataDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.namespace = namespace
        let base = self.dataDirectory.appendingPathComponent("host", isDirectory: true)
        directory = namespace.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        _ = try BackendHOSTSocket.address(socket)
    }
    public func prepare() throws {
        if namespace != nil { try BackendHOSTFiles.privateDirectory(dataDirectory.appendingPathComponent("host", isDirectory: true)) }
        try BackendHOSTFiles.privateDirectory(directory)
    }
    public func secret(create: Bool) throws -> String {
        if create {
            try prepare()
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw BackendHOSTFailure.invalid("macOS could not create the private host secret.")
            }
            let value = bytes.map { String(format: "%02x", $0) }.joined()
            let fd = Darwin.open(secretFile.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                do { try BackendHOSTFiles.write(Data(value.utf8), fd: fd); guard fsync(fd) == 0 else { throw BackendHOSTFailure.io(errno) } }
                catch { Darwin.close(fd); _ = unlink(secretFile.path); throw error }
                Darwin.close(fd)
            } else if errno != EEXIST { throw BackendHOSTFailure.io(errno) }
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o777 == 0o700 else {
            throw BackendHOSTFailure.authentication
        }
        let data = try BackendHOSTFiles.readPrivate(secretFile, maximum: 64)
        guard let value = String(data: data, encoding: .utf8), value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw BackendHOSTFailure.authentication
        }
        return value
    }
}

enum BackendHOSTFiles {
    static func privateDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw BackendHOSTFailure.invalid("The app data folder must exist before the session host starts.")
        }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw BackendHOSTFailure.io(errno) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw BackendHOSTFailure.authentication }
    }
    static func readPrivate(_ file: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_size >= 0, info.st_size <= maximum else {
            throw BackendHOSTFailure.authentication
        }
        var data = Data(count: Int(info.st_size)), offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else { throw BackendHOSTFailure.io(count == 0 ? EIO : errno) }
        }
        return data
    }
    static func write(_ data: Data, fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else { throw BackendHOSTFailure.io(errno) }
        }
    }
    static func atomicWrite(_ data: Data, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".host-" + UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        defer { Darwin.close(fd); _ = unlink(temporary.path) }
        try write(data, fd: fd)
        guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else { throw BackendHOSTFailure.io(errno) }
    }
}

/// Kernel lock, not a PID file. A dead owner releases it automatically.
final class BackendHOSTFileLock: @unchecked Sendable {
    private let fd: Int32
    init(_ path: URL, createIfMissing: Bool = true) throws {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (createIfMissing ? O_CREAT : O_NONBLOCK)
        fd = Darwin.open(path.path, flags, 0o600)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BackendHOSTFailure.unavailable }
    }
    deinit { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
}
