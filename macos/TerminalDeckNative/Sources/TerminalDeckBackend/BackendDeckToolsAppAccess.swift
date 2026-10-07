import Foundation
import TerminalDeckNativeCore

/// Resolved from the serving caller table, never inferred from `attended`.
public struct BackendDeckToolsAppCaller: Sendable {
    public enum Kind: String, Sendable { case local, session, key, remote, other }
    public let kind: Kind
    public let sessionID: String?, machineID: String?, keyName: String?
    public init(kind: Kind, sessionID: String? = nil, machineID: String? = nil, keyName: String? = nil) {
        self.kind = kind; self.sessionID = sessionID; self.machineID = machineID; self.keyName = keyName
    }
}

/// Mandatory central consent/logging and scope seams. authorize receives only
/// redacted arguments and the source confirmation sentence; ownerMustAnswer
/// cannot be satisfied by an unattended grant or by `attended` alone.
public struct BackendDeckToolsAppAccess: Sendable {
    public let caller: @Sendable (BackendMCPCallContext) async throws -> BackendDeckToolsAppCaller
    public let knownFolder: @Sendable (BackendMCPCallContext, String) async throws -> String
    public let session: @Sendable (BackendMCPCallContext, String) async throws -> NativeRPCValue
    public let runnableProject: @Sendable (BackendMCPCallContext, String) async throws -> String
    public let rpc: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public let authorize: @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier, String, Bool) async throws -> Void
    public let record: @Sendable (BackendMCPCallContext, String, NativeRPCValue, NativeRPCValue) async throws -> Void
    public let now: @Sendable () -> Double
    public init(caller: @escaping @Sendable (BackendMCPCallContext) async throws -> BackendDeckToolsAppCaller,
                knownFolder: @escaping @Sendable (BackendMCPCallContext, String) async throws -> String,
                session: @escaping @Sendable (BackendMCPCallContext, String) async throws -> NativeRPCValue,
                runnableProject: @escaping @Sendable (BackendMCPCallContext, String) async throws -> String,
                rpc: @escaping @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext,
                authorize: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier, String, Bool) async throws -> Void,
                record: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue, NativeRPCValue) async throws -> Void,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.caller = caller; self.knownFolder = knownFolder; self.session = session; self.runnableProject = runnableProject
        self.rpc = rpc; self.authorize = authorize; self.record = record; self.now = now
    }
}

public struct BackendDeckToolsAppOutput: Sendable {
    public let value: NativeRPCValue, summary: NativeRPCValue
    public init(_ value: NativeRPCValue, _ summary: NativeRPCValue = .object([])) { self.value = value; self.summary = summary }
}

public enum BackendDeckToolsAppKit {
    public typealias Precheck = @Sendable (String, BackendMCPCallContext, NativeRPCValue) async throws -> Void
    public typealias Consent = @Sendable (String, BackendMCPCallContext, NativeRPCValue) async throws -> (BackendMCPTier, String, Bool)
    public typealias Run = @Sendable (String, BackendMCPCallContext, NativeRPCValue) async throws -> BackendDeckToolsAppOutput
    public static func definitions(module: String, access: BackendDeckToolsAppAccess,
                                   precheck: @escaping Precheck = { _, _, _ in },
                                   consent: @escaping Consent,
                                   run: @escaping Run) throws -> [BackendDeckToolsDefinition] {
        try BackendDeckToolsAppMetadata.entries().filter { $0.module == module }.map { entry in
            BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index, aliases: entry.aliases, audience: entry.audience) { context, args in
                do {
                    guard args.fields != nil else { throw BackendDeckToolsArgs.bad("arguments must be an object") }
                    if context.cancellation.isCancelled { throw CancellationError() }
                    try await precheck(entry.spec.id, context, args)
                    let (tier, sentence, ownerMustAnswer) = try await consent(entry.spec.id, context, args)
                    guard context.allowedTiers.contains(tier) else { throw refused("This caller is not permitted to use that tool.") }
                    let safeArgs = redacted(entry.spec.id, args)
                    try await access.authorize(context, entry.spec.id, safeArgs, tier, sentence, ownerMustAnswer)
                    if context.cancellation.isCancelled { throw CancellationError() }
                    let output = try await run(entry.spec.id, context, args)
                    try await access.record(context, entry.spec.id, safeArgs, output.summary)
                    return .value(output.value)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let failure = NativeRPCError.wrapping(error)
                    return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(failure.message))])],
                        structuredContent: object([("ok", .bool(false)), ("error", .string(failure.message)), ("refusal", failure.code.hasPrefix("not-") ? .string(failure.code) : .null), ("code", .string(failure.code))]), isError: true)
                }
            }
        }
    }
    public static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    public static func n(_ count: Int) -> NativeRPCValue { .number(Double(count)) }
    public static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    public static func refused(_ message: String, code: String = "not-permitted") -> NativeRPCError { .init(code: code, message: message) }
    public static func unavailable(_ operation: String) -> NativeRPCError { BackendDeckToolsSupport.unavailable(operation) }
    public static func str(_ args: NativeRPCValue, _ key: String, trimmed: Bool = false) throws -> String {
        let text = try BackendDeckToolsArgs.str(args, key)
        return trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
    public static func optStr(_ args: NativeRPCValue, _ key: String, trimmed: Bool = false) throws -> String? {
        guard let text = try BackendDeckToolsArgs.optStr(args, key) else { return nil }
        if !trimmed { return text }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    public static func browserStr(_ args: NativeRPCValue, _ key: String) throws -> String {
        do { return try str(args, key) } catch { throw refused(error.localizedDescription) }
    }
    public static func browserOptStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        do { return try optStr(args, key) } catch { throw refused(error.localizedDescription) }
    }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, _ allowed: [String], fallback: String? = nil) throws -> String {
        let value = args[key]
        if (value.isNullish || value.string == ""), let fallback { return fallback }
        guard let text = value.string, allowed.contains(text) else { throw BackendDeckToolsArgs.bad("\(key) must be one of: \(allowed.joined(separator: ", "))") }
        return text
    }
    public static func action(_ args: NativeRPCValue) throws -> String {
        if args["action"].isNullish || args["action"].string == "" { return "list" }
        guard let action = args["action"].string, ["list", "install", "remove"].contains(action) else { throw refused("action must be one of: list, install, remove") }
        return action
    }
    public static func noSession(_ caller: BackendDeckToolsAppCaller, _ tool: String) throws {
        if caller.kind == .session { throw refused("\(tool) is the browser's own settings, and a session reaches only the windows attached to it. Use browser.open, browser.read and browser.step on those.") }
    }
    public static func hereOnly(_ caller: BackendDeckToolsAppCaller, _ what: String) throws {
        guard caller.kind == .local || caller.kind == .key else { throw refused("\(what) only works for the person at this computer, Hoot (the assistant they talk to here), and AI apps they gave an access key to. A paired device cannot do it from here. Say what you would have done and let them do it.", code: "not-granted") }
    }
    public static func redacted(_ id: String, _ args: NativeRPCValue) -> NativeRPCValue {
        switch id {
        case "voice.save_key": return args.setting("key", .string("[redacted]"))
        case "voice.transcribe": return args.setting("audio", .string(args["audio"].string.map { "[\($0.utf16.count) base64 characters]" } ?? "[none]"))
        case "store.community":
            guard let values = args["values"].fields else { return args }
            return args.setting("values", .object(values.map { .init($0.key, .string($0.value.string.map { "[\($0.utf16.count) characters]" } ?? "[not text]")) }))
        default: return args
        }
    }
}
