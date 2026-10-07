import Foundation
import Darwin
import TerminalDeckNativeCore

/// Final JSONL bytes, after each source writer's own row construction/redaction.
/// One synchronous sink serves both writers; completion preserves append order
/// and durability before their caller returns. No Task-based logging adapter.
public protocol BackendHootJoinRawActionSink: AnyObject, Sendable {
    var file: URL { get }
    func append(_ bytes: Data, policy: BackendHootJoinRawPolicy) throws
}
public enum BackendHootJoinRawPolicy: Sendable {
    /// copilot-home: rotate the existing file at >=4 MiB, not projected size.
    case home(limit: Int)
    /// action-log: rotate projected size >limit; its caller already scrubbed
    /// large args/results and applies its own permanent failed-writer latch.
    case tool(limit: Int, keep: Int)
}
public final class BackendHootJoinRawSink: BackendHootJoinRawActionSink, @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()
    /// The one sink per canonical actions file in this process. Both Home's
    /// `appendAction` and deck-core's action log obtain theirs here, so the
    /// same file can never have two locks/rotators. Construct-only; no I/O.
    public static func shared(directory: URL) throws -> BackendHootJoinRawSink {
        let candidate = try BackendHootJoinRawSink(directory: directory)
        return BackendHootJoinRawSinkTable.table.claim(candidate)
    }
    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/", !directory.path.contains("\0") else {
            throw NativeRPCError.invalidArguments("The shared Hoot action sink needs the app's absolute log directory.")
        }
        file = directory.standardizedFileURL.appendingPathComponent(BackendDeckCoreSecurityActionLog.fileName)
    }
    public func append(_ bytes: Data, policy: BackendHootJoinRawPolicy) throws {
        try lock.withLock {
            // Bytes are never parsed/re-encoded here: Home rows omit v/tool and
            // tool rows retain all source confirmation/actor/redaction fields.
            let directory = file.deletingLastPathComponent()
            try BackendCopilotStorageIO.mkdir(directory.path)
            let size = BackendCopilotStorageIO.bytes(file.path) ?? 0
            let noFollow: Int32
            switch policy {
            case .home(let limit):
                guard limit > 0 else { throw NativeRPCError.invalidArguments("The Home action rotation limit is invalid.") }
                if size >= limit { try BackendCopilotStorageIO.rename(file.path, file.path + ".1") }
                noFollow = 0 // Preserve source Home's mode/follow behavior.
            case .tool(let limit, let keep):
                guard limit > 0, keep >= 0 else { throw NativeRPCError.invalidArguments("The tool action rotation policy is invalid.") }
                if bytes.count > limit || size > limit - bytes.count { rotateTool(keep: keep) }
                noFollow = O_NOFOLLOW
            }
            let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | noFollow, 0o600)
            guard fd >= 0 else { throw BackendCopilotStorageIO.error("open", file.path) }
            defer { Darwin.close(fd) }
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BackendCopilotStorageIO.error("write", file.path) }
                offset += count
            }
        }
    }
    /// Home formatting/omission rules, useful to the existing async folder log
    /// supplier. Existing Home.appendAction should pass the same final bytes.
    public func home(_ entry: BackendCopilotAction, now: Date = Date()) throws {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row = NativeRPCValue.object([.init("at", .string(formatter.string(from: now))), .init("action", .string(entry.action))])
        if let detail = entry.detail { row = row.setting("detail", .string(detail)) }
        if let id = entry.sessionId { row = row.setting("sessionId", .string(id)) }
        try append(try row.encodedJSON() + Data([10]), policy: .home(limit: BackendCopilotHome.logLimitBytes))
    }
    private func rotateTool(keep: Int) {
        let fm = FileManager.default
        func generation(_ n: Int) -> URL { URL(fileURLWithPath: file.path + ".\(n)") }
        do {
            if keep == 0 { if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }; return }
            if fm.fileExists(atPath: generation(keep).path) { try fm.removeItem(at: generation(keep)) }
            if keep > 1 {
                for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: generation(n).path) {
                    try fm.moveItem(at: generation(n), to: generation(n + 1))
                }
            }
            if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: generation(1)) }
        } catch { /* Source tool writer prefers an oversized file to a lost row. */ }
    }
}

/// Process-wide identity table for `BackendHootJoinRawSink.shared`.
private final class BackendHootJoinRawSinkTable: @unchecked Sendable {
    static let table = BackendHootJoinRawSinkTable()
    private let lock = NSLock()
    private var sinks: [String: BackendHootJoinRawSink] = [:]
    func claim(_ candidate: BackendHootJoinRawSink) -> BackendHootJoinRawSink {
        lock.withLock {
            let key = candidate.file.standardizedFileURL.path
            if let existing = sinks[key] { return existing }
            sinks[key] = candidate; return candidate
        }
    }
}
