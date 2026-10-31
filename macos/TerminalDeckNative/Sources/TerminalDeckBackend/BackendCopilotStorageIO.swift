import Foundation
import Darwin
import TerminalDeckNativeCore

/// Small synchronous POSIX writes match the source's wx/O_APPEND semantics.
/// Construction has no effects. Every caller supplies an explicit data root.
enum BackendCopilotStorageIO {
    static func join(_ root: String, _ name: String) -> String {
        normalize([root, name].filter { !$0.isEmpty }.joined(separator: "/"))
    }
    /// Node path.normalize on macOS, including relative paths and trailing '/'.
    static func normalize(_ input: String) -> String {
        let absolute = input.hasPrefix("/"), trailing = input.hasSuffix("/")
        var parts: [String] = []
        for part in input.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." { parts.removeLast() }
                else if !absolute { parts.append(part) }
            } else { parts.append(part) }
        }
        var value = (absolute ? "/" : "") + parts.joined(separator: "/")
        if value.isEmpty { value = "." }
        if trailing && value != "/" { value += "/" }
        return value
    }
    static func error(_ operation: String, _ path: String, _ code: Int32 = errno) -> NativeRPCError {
        .init(code: "filesystem", message: "\(operation) '\(path)': \(String(cString: strerror(code)))")
    }
    static func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }
    static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError)
            || (e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT))
    }
    @discardableResult static func mkdir(_ path: String, mode: mode_t = 0o700) throws -> Bool {
        guard !path.contains("\0") else { throw error("mkdir", path, EINVAL) }
        if Darwin.mkdir(path, mode) == 0 { return true }
        let status = errno
        if status == EEXIST {
            guard directory(path) else { throw error("mkdir", path, ENOTDIR) }
            return false
        }
        guard status == ENOENT else { throw error("mkdir", path, status) }
        let rawParent = (path as NSString).deletingLastPathComponent
        let parent = rawParent.isEmpty ? "." : rawParent
        guard parent != path else { throw error("mkdir", path, status) }
        let madeParent = try mkdir(parent, mode: mode)
        if Darwin.mkdir(path, mode) == 0 { return true }
        let after = errno
        if after == EEXIST && directory(path) { return madeParent }
        throw error("mkdir", path, after)
    }
    @discardableResult static func write(_ path: String, _ text: String, exclusive: Bool = false,
                                         append: Bool = false, mode: mode_t = 0o600) throws -> Bool {
        guard !path.contains("\0") else { throw error("open", path, EINVAL) }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (exclusive ? O_EXCL : 0) | (append ? O_APPEND : O_TRUNC), mode)
        if fd < 0 {
            if exclusive && errno == EEXIST { return false }
            throw error("open", path)
        }
        defer { Darwin.close(fd) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var at = 0
            while at < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: at), bytes.count - at)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error("write", path) }
                at += count
            }
        }
        return true
    }
    static func exists(_ path: String) -> Bool { var s = stat(); return !path.contains("\0") && stat(path, &s) == 0 }
    static func regularFile(_ path: String) -> Bool { var s = stat(); return !path.contains("\0") && stat(path, &s) == 0 && s.st_mode & S_IFMT == S_IFREG }
    static func directory(_ path: String) -> Bool { var s = stat(); return !path.contains("\0") && stat(path, &s) == 0 && s.st_mode & S_IFMT == S_IFDIR }
    static func rename(_ from: String, _ to: String) throws {
        guard !from.contains("\0"), !to.contains("\0") else { throw error("rename", from, EINVAL) }
        guard Darwin.rename(from, to) == 0 else { throw error("rename", from) }
    }
    static func bytes(_ path: String, regularOnly: Bool = false) -> Int? {
        guard !path.contains("\0") else { return nil }
        var s = stat()
        guard stat(path, &s) == 0, !regularOnly || s.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(s.st_size)
    }
    static func resolved(_ path: String) -> String {
        guard !path.contains("\0") else { return path }
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
    static func optional(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func optional(_ value: Int?) -> NativeRPCValue { value.map { .number(Double($0)) } ?? .null }
    static func optional(_ value: Double?) -> NativeRPCValue { value.map(NativeRPCValue.number) ?? .null }
}
