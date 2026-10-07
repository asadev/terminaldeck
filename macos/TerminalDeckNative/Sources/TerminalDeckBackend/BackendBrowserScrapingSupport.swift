import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// The integration layer supplies this from an authenticated RPC/MCP caller.
/// A tool argument can never choose the lease holder or its session identity.
public struct BackendBrowserScrapingCaller: Sendable {
    public let ownerID: String
    public let sessionID: String?
    public let machineID: String?
    public let attended: Bool
    public let remote: Bool
    public let rpc: NativeRPCContext?
    public init(ownerID: String, sessionID: String? = nil, machineID: String? = nil,
                attended: Bool, remote: Bool, rpc: NativeRPCContext? = nil) {
        self.ownerID = ownerID; self.sessionID = sessionID; self.machineID = machineID
        self.attended = attended; self.remote = remote; self.rpc = rpc
    }
    public var holder: String {
        // Include the machine: equal session IDs on two hosts are different owners.
        [machineID ?? "local", sessionID ?? ownerID].joined(separator: ":")
    }
    public static func native(_ context: NativeRPCContext) -> Self {
        .init(ownerID: context.ownerID, attended: context.caller == .nativeApp,
              remote: context.caller == .pairedDevice, rpc: context)
    }
}

public typealias BackendBrowserScrapingAuthorize = @Sendable
    (BackendBrowserScrapingCaller, String, String?, URL?, NativeRPCValue) async throws -> Void

public enum BackendBrowserScrapingError {
    public static func unsupported(_ message: String) -> NativeRPCError {
        .init(code: "webkit-unavailable", message: message)
    }
    public static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }
    public static func denied(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }
}

/// Constructors perform no disk reads or directory creation. Callers must pass
/// the app's explicit data root, never discover a home directory in this lane.
public struct BackendBrowserScrapingPaths: Sendable {
    public let dataRoot: URL
    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }
    public static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 80, !value.hasPrefix("."),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) || $0 == "." }) else {
            throw BackendBrowserScrapingError.invalid("A profile/run ID must be one safe path component, at most 80 characters.")
        }
        return value
    }
    public func run(_ id: String) throws -> URL {
        dataRoot.appendingPathComponent("scrape/runs", isDirectory: true).appendingPathComponent(try Self.component(id), isDirectory: true)
    }
    public func capture(_ profileID: String, _ runID: String? = nil) throws -> URL {
        let root = dataRoot.appendingPathComponent("browser-captures", isDirectory: true)
            .appendingPathComponent(try Self.component(profileID), isDirectory: true)
        return try runID.map { root.appendingPathComponent(try Self.component($0), isDirectory: true) } ?? root
    }
    public func blocks(_ profileID: String) throws -> URL {
        dataRoot.appendingPathComponent("scrape/blocks", isDirectory: true).appendingPathComponent(try Self.component(profileID), isDirectory: true)
    }
    /// Refuse symlinks at every existing component before I/O. New paths must
    /// remain lexically within the root; no identifier can sanitize to another.
    public func checked(_ url: URL, createParent: Bool = false) throws -> URL {
        // `standardized`: `standardizedFileURL` strips an existing /private prefix on Darwin, turning /private/var into the /var symlink.
        let root = dataRoot.standardized, path = url.standardized
        guard root.isFileURL, path.isFileURL, root.path != "/",
              path.path == root.path || path.path.hasPrefix(root.path + "/") else {
            throw BackendBrowserScrapingError.denied("Browser records must stay inside the explicit app data root.")
        }
        try Self.rejectSymlinks(path, below: root)
        if createParent { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return path
    }
    /// macOS's own top-level aliases (/var, /tmp, /etc -> /private/...). They sit above every
    /// data root and are not store content, so they are not "symbolic links inside the store".
    private static let systemAliases: Set<String> = ["/var", "/tmp", "/etc"]
    public static func rejectSymlinks(_ url: URL, below root: URL? = nil) throws {
        // `standardized`, not `standardizedFileURL`: on Darwin the latter strips
        // an existing "/private" prefix, turning a real /private/var path back
        // into /var and then refusing the /var symlink it introduced itself.
        var item = url.standardized
        while item.path != "/" {
            if let root, item.path == root.path { return }
            if systemAliases.contains(item.path) { item.deleteLastPathComponent(); continue }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: item.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw BackendBrowserScrapingError.denied("Browser file operations do not follow symbolic links.")
            }
            item.deleteLastPathComponent()
        }
    }
}

enum BackendBrowserScrapingIO {
    static func value<T: Encodable>(_ value: T) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(JSONEncoder().encode(value))
    }
    static func read(_ url: URL, maxBytes: Int = 128 * 1_024 * 1_024) throws -> Data {
        try BackendBrowserScrapingPaths.rejectSymlinks(url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value <= Int64(maxBytes) else {
            throw BackendBrowserScrapingError.invalid("Browser record is not a regular file within the read limit.")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    static func write(_ value: NativeRPCValue, to url: URL, paths: BackendBrowserScrapingPaths) throws {
        let path = try paths.checked(url, createParent: true)
        try value.encodedJSON(pretty: true).write(to: path, options: .atomic)
    }
    static func append(_ value: NativeRPCValue, to url: URL, paths: BackendBrowserScrapingPaths) throws {
        let path = try paths.checked(url, createParent: true)
        if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path, options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: value.encodedJSON() + Data([10]))
    }
    static func lines(_ url: URL) throws -> [NativeRPCValue] {
        let data = try read(url)
        guard let text = String(data: data, encoding: .utf8) else { throw BackendBrowserScrapingError.invalid("Browser record is not UTF-8.") }
        let rows = text.split(separator: "\n")
        guard rows.count <= 200_000 else { throw BackendBrowserScrapingError.invalid("Browser record exceeds the 200000 row read limit; narrow the run before reading it.") }
        return rows.compactMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) }
    }
    static func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fingerprint(_ url: URL) throws -> (bytes: Int64, digest: String) {
        try BackendBrowserScrapingPaths.rejectSymlinks(url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw BackendBrowserScrapingError.invalid("An asset must be a regular file.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let part = try handle.read(upToCount: 256 * 1_024) ?? Data()
            if part.isEmpty { break }
            bytes += Int64(part.count); hash.update(data: part)
        }
        return (bytes, "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func httpURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            throw BackendBrowserScrapingError.invalid("An asset URL must be an HTTP(S) URL without embedded credentials.")
        }
        return url
    }
    static func integer(_ value: NativeRPCValue, default fallback: Int, min: Int = 0, max: Int) -> Int {
        guard let number = value.number else { return fallback }
        return Int(Swift.min(Swift.max(number.rounded(.towardZero), Double(min)), Double(max)))
    }
    static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }
}
