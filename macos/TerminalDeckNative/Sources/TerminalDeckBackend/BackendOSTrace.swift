import Foundation
import TerminalDeckNativeCore

/// ipc-trace.ts. Debug mode is checked per call. Construct once at boot, before
/// dispatch starts. Trace failure can never change a handler's result or throw.
/// Nothing secret is written (#168): values pass the one secret-hiding rule
/// (BackendSharedRedact) and what a person types or pastes is never recorded.
public actor BackendOSTrace {
    public static let setting = "advanced.debugMode"
    public static let maximumBytes = 4 * 1024 * 1024
    public static let defaultExcluded = ["browser:bounds", "browser:visible"]
    /// Their arguments and answers are keystrokes or a paste (a password typed into a terminal included).
    public static let typedChannels: Set<String> = ["session:write", "servers:shell:write", "docker:exec:write", "machines:input", "devices:type", "attach:paste"]
    public static let typedWithheld = "[typed text withheld]"
    public nonisolated let file: URL
    public nonisolated var previousFile: URL { URL(fileURLWithPath: file.path + ".1") }
    private let excluded: [String]
    private var enabled: Bool
    private var announced = false
    private var size: Int
    private let now: @Sendable () -> Date

    public init(userData: URL, enabled: Bool = false, excluded: [String] = defaultExcluded, now: @escaping @Sendable () -> Date = Date.init) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("IPC tracing needs the app's own absolute data directory.") }
        file = userData.appendingPathComponent("ipc-trace.log")
        self.enabled = enabled; self.excluded = excluded; self.now = now
        size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
        try? FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        if !enabled {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".1"))
            size = 0
        }
    }
    public func setEnabled(_ on: Bool) { if enabled != on && !on { announced = false }; enabled = on }
    /// True only when this invocation started with tracing enabled. The caller
    /// retains it so enabling Debug mode mid-call cannot record only its result.
    public func invokeStarted(channel: String, arguments: [NativeRPCValue]) -> Bool {
        guard enabled, !excluded.contains(channel) else { return false }
        write("→ \(channel)(\(Self.summarize(arguments, channel: channel)))"); return true
    }
    public func invokeReturned(channel: String, value: NativeRPCValue, started: Bool) {
        if started { write("← \(channel) ok: \(Self.typedChannels.contains(channel) ? Self.typedWithheld : Self.stringify(value, limit: 300))") }
    }
    public func invokeThrew(channel: String, error: Error, started: Bool) {
        if started { write("✗ \(channel) THREW: \(Self.prefix(BackendSharedRedact.redact(Self.cut("Error: " + error.localizedDescription, limit: 4000)), limit: 300))") }
    }
    public func sent(channel: String, arguments: [NativeRPCValue]) {
        if enabled && !excluded.contains(channel) { write("⇢ \(channel)(\(Self.summarize(arguments, channel: channel)))   [send]") }
    }
    public static func summarize(_ arguments: [NativeRPCValue], channel: String = "") -> String {
        if typedChannels.contains(channel) { return typedWithheld }
        return arguments.map { stringify($0, limit: 200) }.joined(separator: ", ")
    }
    public static func prefix(_ value: String, limit: Int) -> String { String(decoding: value.utf16.prefix(limit), as: UTF16.self) }
    /// Only what can be shown is kept, then secrets are hidden, then it is cut to length,
    /// so a huge answer is never swept whole and the cut never splits an unhidden secret.
    private static func stringify(_ value: NativeRPCValue, limit: Int) -> String {
        guard value != .missing else { return "undefined" }
        var budget = limit
        return prefix(BackendSharedRedact.redactValue(clip(value, &budget)).compact, limit: limit)
    }
    /// A text cut short loses its last partial word too: it may be the start of a secret.
    static func cut(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        let kept = prefix(text, limit: limit)
        return String(kept[..<(kept.lastIndex(where: \.isWhitespace) ?? kept.startIndex)]) + "…"
    }
    private static func clip(_ value: NativeRPCValue, _ budget: inout Int) -> NativeRPCValue {
        switch value {
        case .string(let text):
            let room = max(0, budget); budget -= text.utf16.count + 2
            return .string(cut(text, limit: room))
        case .bytes(let data): budget -= 12; return .string("<\(data.count) bytes>")
        case .array(let items):
            var kept: [NativeRPCValue] = []
            for item in items { guard budget > 0 else { break }; kept.append(clip(item, &budget)); budget -= 1 }
            return .array(kept)
        case .object(let fields):
            var kept: [NativeRPCValue.Field] = []
            for field in fields { guard budget > 0 else { break }; budget -= field.key.utf16.count + 4; kept.append(.init(field.key, clip(field.value, &budget))) }
            return .object(kept)
        default: budget -= 6; return value
        }
    }
    private func write(_ line: String) {
        guard enabled else { return }
        if !announced { announced = true; append("--- trace started, all channels except: \(excluded.joined(separator: ", ")) ---") }
        append(line)
    }
    private func append(_ line: String) {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = Data("\(formatter.string(from: now())) \(line)\n".utf8)
        do {
            if size + data.count > Self.maximumBytes {
                try? FileManager.default.removeItem(at: previousFile)
                do { try FileManager.default.moveItem(at: file, to: previousFile) }
                catch { try? FileManager.default.removeItem(at: file) }
                size = 0
            }
            if !FileManager.default.fileExists(atPath: file.path) { _ = FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); size += data.count
        } catch { /* tracing must never break the app being traced */ }
    }
}

/// One shared dispatcher lets the native UI and optional compatibility HTTP
/// bridge trace all calls without mutating another worker's registry.
public struct BackendOSTraceDispatcher: Sendable {
    public let registry: NativeChannelRegistry
    public let trace: BackendOSTrace?
    public init(registry: NativeChannelRegistry, trace: BackendOSTrace? = nil) { self.registry = registry; self.trace = trace }
    public func invoke(channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        let started = await trace?.invokeStarted(channel: channel, arguments: arguments) ?? false
        do {
            let answer = try await registry.invoke(channel, context: context, arguments: arguments)
            await trace?.invokeReturned(channel: channel, value: answer, started: started); return answer
        } catch { await trace?.invokeThrew(channel: channel, error: error, started: started); throw error }
    }
    @discardableResult public func send(channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> Bool {
        await trace?.sent(channel: channel, arguments: arguments)
        return try await registry.send(channel, context: context, arguments: arguments)
    }
}
