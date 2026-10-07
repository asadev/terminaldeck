import Foundation
import Darwin
import Security
import TerminalDeckNativeCore

public struct BackendAccountFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct BackendAccountConfiguration: Sendable {
    public let dataDirectory: URL
    public let homeDirectory: URL
    public let appName: String
    public let appID: String
    public let helperExecutable: URL
    public let inheritedEnvironment: [String: String]
    public let homeScopes: [NativeTranscriptHomeScope]
    public init(dataDirectory: URL, homeDirectory: URL, appName: String, appID: String,
                helperExecutable: URL, inheritedEnvironment: [String: String], homeScopes: [NativeTranscriptHomeScope] = []) throws {
        guard dataDirectory.isFileURL, homeDirectory.isFileURL, helperExecutable.isFileURL,
              [dataDirectory.path, homeDirectory.path, helperExecutable.path].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              !appName.isEmpty, appID.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil else {
            throw BackendAccountFailure("Native account assembly needs absolute app/home/helper paths and a valid app identity.")
        }
        self.dataDirectory = dataDirectory.standardizedFileURL; self.homeDirectory = homeDirectory.standardizedFileURL
        self.appName = appName; self.appID = appID; self.helperExecutable = helperExecutable.standardizedFileURL
        self.inheritedEnvironment = inheritedEnvironment
        self.homeScopes = homeScopes
    }
    public var profilesRoot: URL { dataDirectory.appendingPathComponent("profiles", isDirectory: true) }
    public var socketEnvironment: String { appID.uppercased() + "_ACCOUNT_VAULT" }
    public var ticketEnvironment: String { appID.uppercased() + "_ACCOUNT_TICKET" }
    public var homeEnvironment: String { appID.uppercased() + "_ACCOUNT_HOME" }
    public var vaultVariables: Set<String> { [socketEnvironment, ticketEnvironment, homeEnvironment] }
    public func systemDirectory(_ provider: String, environment: [String: String]? = nil) -> String {
        let environment = environment ?? inheritedEnvironment
        if let key = BackendAccountProfile.configEnvironment(provider), let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        return homeDirectory.appendingPathComponent("." + provider).path
    }
}

enum BackendAccountFiles {
    static func boundedRead(_ file: URL, maximum: Int) throws -> Data? {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { if errno == ENOENT || errno == ENOTDIR { return nil }; throw BackendAccountFailure("An account file could not be opened (filesystem error \(errno)).") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maximum else { throw BackendAccountFailure("An account file is not a regular file within its size limit.") }
        var data = Data(count: Int(info.st_size))
        let length = data.count
        var position = 0
        while position < length {
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress?.advanced(by: position), length - position) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw BackendAccountFailure("An account file changed or could not be read completely.") }
            position += count
        }
        return data
    }
    static func writeAtomic(_ data: Data, to file: URL) throws {
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".account-" + UUID().uuidString + ".tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BackendAccountFailure("The encrypted account file could not be prepared (filesystem error \(errno)).") }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        var position = 0
        while position < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress?.advanced(by: position), data.count - position) }
            guard written > 0 else { throw BackendAccountFailure("The account file could not be written completely.") }
            position += written
        }
        guard fsync(fd) == 0, Darwin.rename(temporary.path, file.path) == 0 else { throw BackendAccountFailure("The account file could not be saved atomically.") }
        let directoryFD = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC)
        if directoryFD >= 0 { _ = fsync(directoryFD); Darwin.close(directoryFD) }
    }
    static func randomHex(bytes: Int) throws -> String {
        var value = [UInt8](repeating: 0, count: bytes)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes, &value) == errSecSuccess else { throw BackendAccountFailure("macOS could not mint a native account ticket.") }
        return value.map { String(format: "%02x", $0) }.joined()
    }
    static func descendant(_ path: String, root: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/")
    }
}

/// The facade acquires these only after Node has relinquished the whole store.
final class BackendAccountWriterLease: @unchecked Sendable {
    private let descriptor: Int32
    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(file.path + ".native-writer.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BackendAccountFailure("The native account writer lock could not be opened.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw BackendAccountFailure("Another native account writer owns this file.") }
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
