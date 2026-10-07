import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendOSLogRules {
    static func binarySummary(_ value: NativeRPCValue) -> NativeRPCValue {
        switch value { case .bytes(let bytes): return .object([.init("binaryBytes", .number(Double(bytes.count)))]); case .array(let values): return .array(values.map(binarySummary)); case .object(let fields): return .object(fields.map { .init($0.key, binarySummary($0.value)) }); default: return value }
    }
    public static func line(at: Double, level: String, scope: String, message: String, data: NativeRPCValue = .missing) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let label = level.uppercased(), padded = label + String(repeating: " ", count: max(0, 5 - label.count))
        let value = data == .missing ? "" : " " + (data.string ?? data.compact)
        let result = "\(formatter.string(from: Date(timeIntervalSince1970: at / 1000))) \(padded) \(scope.isEmpty ? "" : "[\(scope)] ")\(message)\(value)".replacingOccurrences(of: "\\r?\\n", with: " ", options: .regularExpression)
        return result.utf16.count > 4000 ? String(decoding: result.utf16.prefix(4000), as: UTF16.self) + "… (truncated)" : result
    }
    public static func requestedLines(_ value: NativeRPCValue) -> Int { let count = value.number ?? 200; return min(2000, max(1, Int((count == 0 ? 200 : count).clamped(to: -1_000_000...1_000_000)))) }
}
private extension Double { func clamped(to range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, self)) } }

/// Source app-log.ts + app-log-ipc.ts. Uses the existing logs directory and
/// generation names. A constructor neither stats nor creates the real folder.
public actor BackendOSAppLog {
    public static let channels: Set<String> = ["log:recent", "log:status", "log:open-folder", "log:clear"]
    public nonisolated let directory: URL, file: URL
    public nonisolated let maximumBytes: Int, keep: Int
    private let redaction: BackendSharedRedactOptions
    private let openPath: @Sendable (String) async throws -> String
    private let authorize: @Sendable (NativeRPCContext, String) throws -> Void
    private let now: @Sendable () -> Double
    private var bytes: Int?, broken = false, active = false, failure: String?
    public init(directory: URL, fileName: String, maximumBytes: Int = 512 * 1024, keep: Int = 2,
                redaction: BackendSharedRedactOptions,
                openPath: @escaping @Sendable (String) async throws -> String,
                authorize: @escaping @Sendable (NativeRPCContext, String) throws -> Void,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !fileName.isEmpty, URL(fileURLWithPath: fileName).lastPathComponent == fileName, !fileName.contains("\0"), maximumBytes <= 32 * 1024 * 1024, (0...64).contains(keep) else { throw NativeRPCError.invalidArguments("App logging needs the app's own directory, a filename and bounded file/generation limits.") }
        self.directory = directory; file = directory.appendingPathComponent(fileName); self.maximumBytes = max(4096, maximumBytes); self.keep = keep
        self.redaction = redaction; self.openPath = openPath; self.authorize = authorize; self.now = now
    }
    public func activate(oldLogOwnerDisabled: Bool) throws { guard oldLogOwnerDisabled else { throw NativeRPCError(code: "unavailable", message: "The previous app-log writer must stop before native logging takes ownership.") }; active = true }
    private func generation(_ index: Int) -> URL { URL(fileURLWithPath: file.path + ".\(index)") }
    private func size(_ file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
    private func rotate() {
        do {
            if keep == 0 { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
            else {
                if FileManager.default.fileExists(atPath: generation(keep).path) { try FileManager.default.removeItem(at: generation(keep)) }
                if keep > 1 { for index in stride(from: keep - 1, through: 1, by: -1) { if FileManager.default.fileExists(atPath: generation(index).path) { try FileManager.default.moveItem(at: generation(index), to: generation(index + 1)) } } }
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: generation(1)) }
            }
            bytes = 0
        } catch { bytes = size(file) }
    }
    /// A log failure never breaks its caller; false and status.writeError retain
    /// the fact that the entry was not written. Secrets are also removed before
    /// persistence, strengthening source's output-only redaction boundary.
    @discardableResult public func write(level: String, scope: String, message: String, data: NativeRPCValue = .missing) -> Bool {
        guard active else { failure = "Native app logging has not taken writer ownership."; return false }
        guard !broken else { return false }
        var diskOptions = redaction; diskOptions.keepIdentity = true
        let safeMessage = BackendSharedRedact.redact(message, options: diskOptions), safeScope = BackendSharedRedact.redact(scope, options: diskOptions), safeData = BackendSharedRedact.redactValue(BackendOSLogRules.binarySummary(data), options: diskOptions)
        let line = Data((BackendOSLogRules.line(at: now(), level: level, scope: safeScope, message: safeMessage, data: safeData) + "\n").utf8)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if bytes == nil { bytes = size(file) }; if (bytes ?? 0) + line.count > maximumBytes { rotate() }
            let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }; defer { Darwin.close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw NativeRPCError.malformed("The app log is not a regular file.") }
            var offset = 0
            try line.withUnsafeBytes { raw in while offset < line.count { let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), line.count - offset); if written < 0 && errno == EINTR { continue }; guard written > 0 else { throw POSIXError(.EIO) }; offset += written } }
            bytes = (bytes ?? 0) + line.count; return true
        } catch { broken = true; failure = error.localizedDescription; return false }
    }
    public func tail(_ count: Int) throws -> [String] {
        guard count > 0 else { return [] }; var result: [String] = []
        for index in 0...keep {
            let path = index == 0 ? file : generation(index)
            if let data = try BackendAccountFiles.boundedRead(path, maximum: max(maximumBytes + 16_384, 1_048_576)) {
                let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }; result = lines + result
            }
            if result.count >= count { break }
        }
        return Array(result.suffix(count))
    }
    public func recent(_ count: Int = 200) throws -> NativeRPCValue {
        .object([.init("file", .string(BackendSharedRedact.redact(file.path, options: redaction))), .init("lines", .array(BackendSharedRedact.redactLines(try tail(count), options: redaction).map(NativeRPCValue.string)))])
    }
    public func status() -> NativeRPCValue {
        let files = (0...keep).compactMap { index -> NativeRPCValue? in let path = index == 0 ? file : generation(index); guard FileManager.default.fileExists(atPath: path.path) else { return nil }; return .object([.init("name", .string(path.lastPathComponent)), .init("bytes", .number(Double(size(path))))]) }
        return .object([.init("dir", .string(BackendSharedRedact.redact(directory.path, options: redaction))), .init("file", .string(BackendSharedRedact.redact(file.path, options: redaction))), .init("bytes", .number(Double(size(file)))), .init("files", .array(files)), .init("maxBytes", .number(Double(maximumBytes))), .init("keep", .number(Double(keep))), .init("writeError", failure.map { .string(BackendSharedRedact.redact($0, options: redaction)) } ?? .null)])
    }
    public func clear() throws {
        guard active else { throw NativeRPCError(code: "unavailable", message: "Native app logging has not taken writer ownership.") }
        for index in 0...keep { let path = index == 0 ? file : generation(index); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } }
        bytes = 0; broken = false; failure = nil
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw NativeRPCError(code: "unavailable", message: "The native app log channel is not registered.") }; try authorize(context, channel)
        switch channel {
        case "log:recent": return try recent(BackendOSLogRules.requestedLines(args.first ?? .missing))
        case "log:status": return status()
        case "log:clear": try clear(); return .null
        default: try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return .string(try await openPath(directory.path))
        }
    }
}
