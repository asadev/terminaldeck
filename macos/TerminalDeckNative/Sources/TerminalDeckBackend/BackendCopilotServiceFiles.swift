import Foundation
import Darwin

/// Exact Node-like UTF-8 file reads and non-atomic mode-preserving writes used
/// only by the Hoot ports. This does not own the user-data or session graph.
public enum BackendCopilotServiceFiles {
    public struct Information: Sendable {
        public let regular: Bool
        public let bytes: Double
        public let modifiedAt: Double
    }
    public static func stat(_ path: String) throws -> Information {
        var info = Darwin.stat()
        guard backendCopilotPOSIXStat(path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return .init(regular: (info.st_mode & S_IFMT) == S_IFREG, bytes: Double(info.st_size),
            modifiedAt: Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000)
    }
    public static func missing(_ error: Error) -> Bool { BackendCopilotStorageIO.isMissing(error) }
    public static func readText(_ path: String) throws -> String { try BackendCopilotStorageIO.read(path) }
    public static func writeText(_ text: String, path: String) throws { try BackendCopilotStorageIO.write(path, text) }
}

/// File-scope POSIX stat: inside `BackendCopilotServiceFiles` the unqualified
/// name finds its own `static func stat`, and Swift 6.4 resolves `Darwin.stat(…)`
/// to the struct. Same call, valid on Swift 6.3 and 6.4.
private func backendCopilotPOSIXStat(_ path: String, _ buffer: inout stat) -> Int32 { stat(path, &buffer) }
