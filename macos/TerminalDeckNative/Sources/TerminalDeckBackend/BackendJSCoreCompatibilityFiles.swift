import Foundation
import Darwin
import JavaScriptCore
import TerminalDeckNativeCore

public struct BackendJSCoreCompatibilityFailure: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

/// Filesystem primitives inside the separately sandboxed JSCore helper. This
/// does not grant projects, credentials or domain capabilities. The original
/// BackendPluginsSandbox remains the OS authority; these bounds are additional
/// resource/path checks before exposing a synchronous filesystem primitive.
public final class BackendJSCoreCompatibilityFiles {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumEntries = 5000
    public let configuration: BackendJSCoreRuntimeConfiguration
    private let reads: [String]
    private let data: String
    public init(configuration: BackendJSCoreRuntimeConfiguration) {
        self.configuration = configuration
        data = configuration.dataURL.standardizedFileURL.resolvingSymlinksInPath().path
        let runtime = CommandLine.arguments.first.flatMap { $0.hasPrefix("/") ? BackendPluginsSandbox.runtimeRoot($0) : nil }
        reads = [configuration.folderURL.standardizedFileURL.resolvingSymlinksInPath().path, data] + BackendMacConfinement.systemReadRoots + (runtime.map { [$0] } ?? [])
    }
    public func checked(_ path: String, writing: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4096 else {
            throw BackendJSCoreCompatibilityFailure("EINVAL", "Invalid filesystem path")
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : configuration.folderURL.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        let roots = writing ? [data] : reads
        guard roots.contains(where: { Self.within(url.path, $0) }) else {
            throw BackendJSCoreCompatibilityFailure("EPERM", "Operation not permitted outside this plugin’s \(writing ? "data" : "readable") folders: \(path)")
        }
        return url
    }
    /// lstat/unlink/rm/rename operate on the directory entry, not its target.
    /// Resolve the parent and check the lexical leaf; the OS fence still checks
    /// the actual operation. A data symlink may be removed without following it.
    public func checkedEntry(_ path: String, writing: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 4096 else { throw BackendJSCoreCompatibilityFailure("EINVAL", "Invalid filesystem path") }
        let absolute = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : configuration.folderURL.appendingPathComponent(path)).standardizedFileURL
        let parent = absolute.deletingLastPathComponent().resolvingSymlinksInPath()
        let entry = parent.appendingPathComponent(absolute.lastPathComponent)
        guard (writing ? [data] : reads).contains(where: { Self.within(entry.path, $0) }) else {
            throw BackendJSCoreCompatibilityFailure("EPERM", "Operation not permitted outside this plugin’s \(writing ? "data" : "readable") folders: \(path)")
        }
        return entry
    }
    private func mode(_ value: NativeRPCValue, default fallback: Int32) throws -> Int32 {
        if value == .missing { return fallback }
        guard let number = value.number, number.isFinite, number.rounded(.towardZero) == number, (0...Double(0o7777)).contains(number) else {
            throw BackendJSCoreCompatibilityFailure("ERR_INVALID_ARG_VALUE", "fs mode must be an integer from 0 through 4095")
        }
        return Int32(number)
    }
    public func read(_ path: String) throws -> Data {
        let url = try checked(path)
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posix("open", path) }; defer { Darwin.close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw posix("stat", path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw BackendJSCoreCompatibilityFailure("EISDIR", "Illegal operation on a directory: \(path)") }
        guard info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "readFile exceeds the \(Self.maximumBytes)-byte JSCore plugin resource limit")
        }
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &opened) >= 0 else { throw posix("resolve opened file", path) }
        _ = try checked(String(cString: opened))
        var bytes = Data(), chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw posix("read", path) }
            if count == 0 { return bytes }
            guard bytes.count + count <= Self.maximumBytes else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "readFile exceeds the JSCore plugin resource limit") }
            bytes.append(contentsOf: chunk.prefix(count))
        }
    }
    private func write(_ path: String, bytes: Data, append: Bool, exclusive: Bool, mode: Int32) throws {
        let url = try checked(path, writing: true)
        guard bytes.count <= Self.maximumBytes else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "writeFile exceeds the JSCore plugin resource limit") }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC) | (exclusive ? O_EXCL : 0)
        let fd = Darwin.open(url.path, flags, mode_t(mode))
        guard fd >= 0 else { throw posix("open", path) }; defer { Darwin.close(fd) }
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &opened) >= 0 else { throw posix("resolve opened file", path) }
        _ = try checked(String(cString: opened), writing: true)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posix("write", path) }; offset += count
            }
        }
    }
    public func perform(_ method: String, params: NativeRPCValue) throws -> NativeRPCValue {
        let path = params["path"].string ?? ""
        switch method {
        case "readFile": return .string(try read(path).base64EncodedString())
        case "writeFile", "appendFile":
            guard let raw = params["data"].string, let bytes = Data(base64Encoded: raw) else { throw BackendJSCoreCompatibilityFailure("EINVAL", "writeFile requires encoded bytes") }
            let flag = params["flag"].string ?? (method == "appendFile" ? "a" : "w")
            guard ["w", "wx", "a", "ax"].contains(flag) else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Unsupported fs write flag: \(flag)") }
            try write(path, bytes: bytes, append: flag.hasPrefix("a"), exclusive: flag.hasSuffix("x"), mode: try mode(params["mode"], default: 0o666)); return .null
        case "exists": return .bool(FileManager.default.fileExists(atPath: try checked(path).path))
        case "realpath":
            let file = try checked(path)
            guard FileManager.default.fileExists(atPath: file.path) else { throw BackendJSCoreCompatibilityFailure("ENOENT", "No such file or directory: \(path)") }
            return .string(file.path)
        case "stat", "lstat":
            let file: URL
            if method == "lstat" { file = try checkedEntry(path) } else { file = try checked(path) }
            var info = stat()
            let result = method == "lstat" ? Darwin.lstat(file.path, &info) : stat(file.path, &info)
            guard result == 0 else { throw posix(method, path) }
            return .object([.init("size", .number(Double(info.st_size))), .init("mode", .number(Double(info.st_mode))),
                .init("dev", .number(Double(info.st_dev))), .init("ino", .number(Double(info.st_ino))), .init("nlink", .number(Double(info.st_nlink))),
                .init("uid", .number(Double(info.st_uid))), .init("gid", .number(Double(info.st_gid))), .init("blksize", .number(Double(info.st_blksize))), .init("blocks", .number(Double(info.st_blocks))),
                .init("atimeMs", .number(Double(info.st_atimespec.tv_sec) * 1000 + Double(info.st_atimespec.tv_nsec) / 1_000_000)),
                .init("mtimeMs", .number(Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000)),
                .init("ctimeMs", .number(Double(info.st_ctimespec.tv_sec) * 1000 + Double(info.st_ctimespec.tv_nsec) / 1_000_000)),
                .init("birthtimeMs", .number(Double(info.st_birthtimespec.tv_sec) * 1000 + Double(info.st_birthtimespec.tv_nsec) / 1_000_000)),
                .init("isFile", .bool(info.st_mode & S_IFMT == S_IFREG)), .init("isDirectory", .bool(info.st_mode & S_IFMT == S_IFDIR)),
                .init("isSymbolicLink", .bool(info.st_mode & S_IFMT == S_IFLNK)), .init("isBlockDevice", .bool(info.st_mode & S_IFMT == S_IFBLK)),
                .init("isCharacterDevice", .bool(info.st_mode & S_IFMT == S_IFCHR)), .init("isFIFO", .bool(info.st_mode & S_IFMT == S_IFIFO)), .init("isSocket", .bool(info.st_mode & S_IFMT == S_IFSOCK))])
        case "readdir":
            let directory = try checked(path)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants]) else { throw BackendJSCoreCompatibilityFailure("ENOENT", "Directory cannot be read: \(path)") }
            var entries: [NativeRPCValue] = []
            for case let file as URL in enumerator {
                guard entries.count < Self.maximumEntries else { throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_RESOURCE_LIMIT", "readdir exceeds the \(Self.maximumEntries)-entry JSCore plugin limit") }
                entries.append(.string(file.lastPathComponent))
            }
            return .array(entries)
        case "mkdir":
            let directory = try checked(path, writing: true)
            if params["recursive"].bool != true, FileManager.default.fileExists(atPath: directory.path) { throw BackendJSCoreCompatibilityFailure("EEXIST", "File already exists: \(path)") }
            var parent = directory, firstCreated: String?
            if params["recursive"].bool == true {
                while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" { firstCreated = parent.path; parent.deleteLastPathComponent() }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: params["recursive"].bool == true,
                attributes: [.posixPermissions: Int(try mode(params["mode"], default: 0o777))])
            return firstCreated.map(NativeRPCValue.string) ?? .missing
        case "unlink", "rm":
            let file = try checkedEntry(path, writing: true)
            guard file.path != data else { throw BackendJSCoreCompatibilityFailure("EPERM", "The plugin data root cannot be removed") }
            var entry = stat()
            let exists = Darwin.lstat(file.path, &entry) == 0
            if !exists, params["force"].bool == true, errno == ENOENT { return .null }
            if method == "unlink" { guard Darwin.unlink(file.path) == 0 else { throw posix("unlink", path) } }
            else {
                guard exists else { throw posix("rm", path) }
                if entry.st_mode & S_IFMT == S_IFDIR && params["recursive"].bool != true {
                    throw BackendJSCoreCompatibilityFailure("EISDIR", "rm of a directory requires recursive:true")
                }
                try FileManager.default.removeItem(at: file)
            }
            return .null
        case "rename":
            let from = try checkedEntry(path, writing: true), to = try checkedEntry(params["to"].string ?? "", writing: true)
            guard from.path != data, to.path != data else { throw BackendJSCoreCompatibilityFailure("EPERM", "The plugin data root cannot be moved") }
            guard Darwin.rename(from.path, to.path) == 0 else { throw posix("rename", path) }; return .null
        case "copyFile":
            let bytes = try read(path); try write(params["to"].string ?? "", bytes: bytes, append: false, exclusive: params["exclusive"].bool == true, mode: 0o666); return .null
        default: throw BackendJSCoreCompatibilityFailure("ERR_JSCORE_UNSUPPORTED", "Node fs.\(method) is not implemented by the JSCore plugin runtime")
        }
    }
    public func response(_ method: String, json: String) -> String {
        do {
            let params = try NativeRPCValue.parseJSON(Data(json.utf8), maximumBytes: Self.maximumBytes * 2)
            return NativeRPCValue.object([.init("ok", .bool(true)), .init("value", try perform(method, params: params))]).compact
        } catch {
            let failure = (error as? BackendJSCoreCompatibilityFailure) ?? Self.cocoa(error)
            return NativeRPCValue.object([.init("ok", .bool(false)), .init("error", .object([.init("code", .string(failure.code)), .init("message", .string(failure.message))]))]).compact
        }
    }
    private static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    private func posix(_ operation: String, _ path: String) -> BackendJSCoreCompatibilityFailure {
        let status = errno
        let name: String
        switch status {
        case EPERM: name = "EPERM"; case EACCES: name = "EACCES"; case ENOENT: name = "ENOENT"
        case ENOTDIR: name = "ENOTDIR"; case EISDIR: name = "EISDIR"; case EEXIST: name = "EEXIST"
        case ELOOP: name = "ELOOP"; case ENOSPC: name = "ENOSPC"; default: name = "EIO"
        }
        return .init(name, "\(operation): \(String(cString: strerror(status))), \(path)")
    }
    private static func cocoa(_ error: Error) -> BackendJSCoreCompatibilityFailure {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain {
            return .init(value.code == Int(ENOENT) ? "ENOENT" : value.code == Int(EPERM) ? "EPERM" : "EIO", value.localizedDescription)
        }
        return .init(value.code == NSFileNoSuchFileError ? "ENOENT" : value.code == NSFileReadNoPermissionError || value.code == NSFileWriteNoPermissionError ? "EPERM" : "EIO", value.localizedDescription)
    }
}
