import Foundation
import Darwin

/// Unix paths are checked lexically before filesystem access. Existing parents
/// are then confined with POSIX realpath, which does not change with URL flags.
enum DKTUnixSocketPath {
    static var temporaryRoot: String {
        // The UUID directory and socket add 51 bytes. Prefer a real, short root
        // rather than assuming /private/tmp exists under every runner.
        physicalTemporaryRoots.first { $0.utf8.count + 51 < socketPathCapacity } ?? "/tmp"
    }

    static func validateLexical(_ path: String) throws -> (parent: String, leaf: String) {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        let roots = temporaryRootSpellings + physicalTemporaryRoots
        guard path.hasPrefix("/"), path.utf8.count < socketPathCapacity,
              !path.utf8.contains(where: { $0 < 32 || $0 == 127 }), !path.contains("\\"),
              pieces.count >= 2,
              pieces.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              roots.contains(where: { $0 != "/" && path.hasPrefix($0 + "/") }),
              let slash = path.lastIndex(of: "/") else { throw DKTHTTPServerError.invalidSocketPath }
        let parent = slash == path.startIndex ? "/" : String(path[..<slash])
        return (parent, String(path[path.index(after: slash)...]))
    }

    static func validateExistingParent(of path: String) throws {
        let parts = try validateLexical(path)
        guard let parent = physicalPath(parts.parent),
              physicalTemporaryRoots.contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }) else {
            throw DKTHTTPServerError.invalidSocketPath
        }
        var information = stat()
        guard lstat(parent, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw DKTHTTPServerError.invalidSocketPath
        }
    }

    private static var socketPathCapacity: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) }
    private static var temporaryRootSpellings: [String] {
        var systemRoot = FileManager.default.temporaryDirectory.path
        while systemRoot.count > 1, systemRoot.hasSuffix("/") { systemRoot.removeLast() }
        return ["/tmp", "/private/tmp", systemRoot]
    }
    private static var physicalTemporaryRoots: [String] {
        var roots: [String] = []
        for candidate in temporaryRootSpellings {
            guard let root = physicalPath(candidate), root != "/", !roots.contains(root) else { continue }
            var information = stat()
            guard lstat(root, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else { continue }
            roots.append(root)
        }
        return roots
    }
    private static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Test-only HTTP values shared by the independent Docker and Caddy fakes.
struct DKTHTTPRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    init(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }

    var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]) }
    var query: [String: String] {
        (URLComponents(string: target)?.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value ?? "" }
    }

    /// Docker's negotiated API prefix is separate from the endpoint path.
    var enginePath: String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first,
              String(first).range(of: #"^v[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return path }
        return "/" + components.dropFirst().joined(separator: "/")
    }
}

struct DKTHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let streamChunks: [Data]
    let holdOpen: Bool

    init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data(),
         streamChunks: [Data] = [], holdOpen: Bool = false) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.streamChunks = streamChunks
        self.holdOpen = holdOpen
    }

    static func json(_ value: Any, statusCode: Int = 200) -> Self {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else {
            return .init(statusCode: 500, headers: ["Content-Type": "application/json"],
                         body: Data(#"{"message":"The test fixture could not encode JSON"}"#.utf8))
        }
        return .init(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: bytes)
    }
}

enum DKTHTTPServerError: Error, Sendable, CustomStringConvertible {
    case invalidSocketPath
    case alreadyStarted
    case systemCall(String, Int32)
    case invalidRequest(Int)
    case disconnected
    case timedOut

    var description: String {
        switch self {
        case .invalidSocketPath: "The test socket must be a new, short absolute path inside a temporary directory"
        case .alreadyStarted: "This test server has already been started"
        case let .systemCall(name, number): "Test socket \(name) failed (errno \(number))"
        case let .invalidRequest(status): "Malformed or oversized test HTTP request (\(status))"
        case .disconnected: "The test HTTP peer disconnected"
        case .timedOut: "The test HTTP peer exceeded the bounded request deadline"
        }
    }
}
