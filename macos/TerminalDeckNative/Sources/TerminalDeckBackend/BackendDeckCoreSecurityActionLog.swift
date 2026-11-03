import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendDeckCoreSecurityActionOutcome: String, Sendable { case ok, refused, error }
public struct BackendDeckCoreSecurityConfirmation: Sendable {
    public let required: Bool
    public let granted: Bool
    public let by: String?
    public let at: Double?
    public let reason: BackendDeckCoreSecurityRefusalReason?
    public init(required: Bool, granted: Bool = false, by: String? = nil, at: Double? = nil, reason: BackendDeckCoreSecurityRefusalReason? = nil) {
        self.required = required; self.granted = granted; self.by = by; self.at = at; self.reason = reason
    }
    public var wireValue: NativeRPCValue {
        .object([.init("required", .bool(required)), .init("granted", .bool(granted)), .init("by", by.map(NativeRPCValue.string) ?? .null),
                 .init("at", at.map(NativeRPCValue.number) ?? .null), .init("reason", reason.map { .string($0.rawValue) } ?? .null)])
    }
}

/// Same JSONL path, fields, rotation and tolerated lifecycle rows as action-log.ts.
public actor BackendDeckCoreSecurityActionLog {
    public static let fileName = "actions.jsonl"
    public static let maximumString = 2000
    public static let maximumRowBytes = 32 * 1024
    public let directory: URL
    public let file: URL
    private let maximumBytes: Int
    private let keep: Int
    private let now: @Sendable () -> Double
    private var failed = false
    private var failureChanged: @Sendable (Bool) async -> Void = { _ in }
    /// The one process-wide writer for this file, shared with Hoot's Home
    /// lifecycle rows (`BackendCopilotHome.appendAction`): one lock, one rotator.
    public nonisolated let rawSink: BackendHootJoinRawSink?
    public init(directory: URL, maximumBytes: Int = 4 * 1024 * 1024, keep: Int = 1,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.directory = directory; file = directory.appendingPathComponent(Self.fileName)
        self.maximumBytes = max(maximumBytes, 4096); self.keep = max(keep, 0); self.now = now
        rawSink = try? BackendHootJoinRawSink.shared(directory: directory)
    }
    public func broken() -> Bool { failed }
    public func onFailureChanged(_ handler: @escaping @Sendable (Bool) async -> Void) async {
        failureChanged = handler
        if failed { await handler(true) }
    }
    private func setFailed(_ value: Bool) async {
        guard failed != value else { return }
        failed = value; await failureChanged(value)
    }
    public func clock() -> Double { now() }
    @discardableResult public func record(_ input: NativeRPCValue) async -> NativeRPCValue { let row = NativeRPCValue.object([.init("v", .number(1))]).merging(input); await append(row); return row }
    public func append(_ row: NativeRPCValue) async {
        do {
            var bytes = try row.encodedJSON() + Data([10])
            if bytes.count > Self.maximumRowBytes {
                let smaller = row.setting("args", .object([.init("note", .string("arguments were too large to record"))]))
                    .setting("result", .object([.init("note", .string("result summary was too large to record"))]))
                bytes = try smaller.encodedJSON() + Data([10])
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let rawSink {
                // Same projected-size rotation and O_NOFOLLOW 0600 append, under the shared lock.
                try rawSink.append(bytes, policy: .tool(limit: maximumBytes, keep: keep))
                await setFailed(false); return
            }
            // Stat on each append: the copilot lifecycle writer shares this file.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + bytes.count > maximumBytes { rotate() }
            let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw NativeRPCError(code: "log-write", message: "The action log could not be opened.") }
            defer { Darwin.close(fd) }
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }; var position = 0
                while position < buffer.count {
                    let written = Darwin.write(fd, base.advanced(by: position), buffer.count - position)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw NativeRPCError(code: "log-write", message: "The action log could not be appended.") }
                    position += written
                }
            }
            await setFailed(false)
        } catch { await setFailed(true) }
    }
    public func tail(_ count: Double = 200) -> [NativeRPCValue] {
        guard count.isFinite, count > 0 else { return [] }
        let want = count >= Double(Int.max) ? Int.max : Int(count.rounded(.down))
        var lines = readLines(file)
        if keep > 0 { for generation in 1...keep where lines.count < want { lines = readLines(generationURL(generation)) + lines } }
        return lines.suffix(want).compactMap { line in
            guard let value = try? NativeRPCValue.parseJSON(Data(line.utf8)), value.fields != nil else { return nil }; return value
        }
    }
    private func readLines(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    private func generationURL(_ number: Int) -> URL { URL(fileURLWithPath: file.path + ".\(number)") }
    private func rotate() {
        let fm = FileManager.default
        do {
            if keep == 0 { if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }; return }
            if fm.fileExists(atPath: generationURL(keep).path) { try fm.removeItem(at: generationURL(keep)) }
            if keep > 1 { for index in stride(from: keep - 1, through: 1, by: -1) {
                if fm.fileExists(atPath: generationURL(index).path) { try fm.moveItem(at: generationURL(index), to: generationURL(index + 1)) }
            } }
            if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: generationURL(1)) }
        } catch { /* An oversized log is preferable to dropping a row. */ }
    }
    public nonisolated static func scrubArguments(_ args: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        guard let fields = args.fields else { return .object([]) }
        return .object(fields.map { field in
            let key = field.key; let value = field.value
            if key.range(of: secretName, options: [.regularExpression, .caseInsensitive]) != nil { return .init(key, .string("[redacted]")) }
            switch value {
            case .string(let text):
                // Every text goes through the shared rule (a command or URL can
                // carry a key too); only prose also folds the person's name.
                let prose = key.range(of: #"^(text|prompt|message|body|note)$"#, options: [.regularExpression, .caseInsensitive]) != nil
                return .init(key, .string(cap(hideSecrets(text, keepIdentity: !prose))))
            case .null, .number, .bool: return field
            case .array(let array):
                return .init(key, depth == 0 ? .array(array.prefix(20).map(scrubValue)) : .string("[\(array.count) items]"))
            case .object: return .init(key, depth == 0 ? scrubArguments(value, depth: depth + 1) : .string("[object]"))
            default: return .init(key, .string(value == .missing ? "undefined" : value.compact))
            }
        })
    }
    private nonisolated static func scrubValue(_ value: NativeRPCValue) -> NativeRPCValue {
        switch value { case .string(let text): return .string(cap(hideSecrets(text))); case .null, .number, .bool: return value; default: return .string("[object]") }
    }
    /// A tool's own summary (what was typed into a session or a server's
    /// terminal, for one) keeps its shape; every text in it is hidden the same
    /// way as the arguments, and a text under a secret-sounding name whole.
    public nonisolated static func scrubResult(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        switch value {
        case .string(let text): return .string(hideSecrets(text))
        case .array(let values): return depth < 8 ? .array(values.map { scrubResult($0, depth: depth + 1) }) : .string("[\(values.count) items]")
        case .object(let fields):
            guard depth < 8 else { return .string("[object]") }
            return .object(fields.map { field in
                field.value.string != nil && field.key.range(of: secretName, options: [.regularExpression, .caseInsensitive]) != nil
                    ? .init(field.key, .string("[redacted]")) : .init(field.key, scrubResult(field.value, depth: depth + 1))
            })
        default: return value
        }
    }
    /// The one shared secret-hiding rule, keeping paths as written unless asked.
    public nonisolated static func hideSecrets(_ text: String, keepIdentity: Bool = true) -> String {
        BackendSharedRedact.redact(text, options: .init(home: "", keepIdentity: keepIdentity))
    }
    private static let secretName = #"(token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer)"#
    private nonisolated static func cap(_ value: String) -> String {
        value.utf16.count <= maximumString ? value : BackendDeckCoreSecurityAccessKeys.prefixUTF16(value, maximumString) + "…[\(value.utf16.count) chars]"
    }
}
