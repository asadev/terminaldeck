import Foundation
import TerminalDeckNativeCore

/// agents-area-args.ts intentionally trims strings; catalogue.ts does not.
public enum BackendDeckToolsSessionsRules {
    public static func str(_ args: NativeRPCValue, _ key: String) throws -> String { try BackendDeckToolsArgs.parsed { try BackendDeckCoreArguments.trimmedString(args, key) } }
    public static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? { try BackendDeckToolsArgs.parsed { try BackendDeckCoreArguments.optionalTrimmedString(args, key) } }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, _ allowed: [String], fallback: String? = nil) throws -> String {
        try BackendDeckToolsArgs.parsed { try BackendDeckCoreArguments.oneOf(args, key, allowed: allowed, fallback: fallback) }
    }
    public static func optNumber(_ args: NativeRPCValue, _ key: String) throws -> Double? {
        if args[key].isNullish { return nil }
        guard let number = args[key].number else { throw BackendDeckToolsArgs.bad("\(key) must be a number") }
        return number
    }
    public static func optRecord(_ args: NativeRPCValue, _ key: String) throws -> NativeRPCValue? {
        if args[key].isNullish { return nil }
        return try BackendDeckToolsArgs.record(args, key)
    }
    public static func optStrings(_ args: NativeRPCValue, _ key: String) throws -> [String]? {
        let value = args[key]
        if value.isNullish { return nil }
        if let string = value.string { return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [string] }
        return try BackendDeckToolsArgs.strList(args, key)
    }
    public static func withoutSecrets(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue { BackendSharedRedact.withoutSecrets(value, depth: depth) }
    /// `crossAI` (13 Oct): another AI's account may take the session over (plan and switch); a same-name login of
    /// the session's own AI is still preferred.
    public static func chooseAccount(_ accounts: [NativeRPCValue], wanted: String, provider: String?, crossAI: Bool = false) throws -> NativeRPCValue {
        let exact = accounts.filter { $0["id"].string == wanted }
        let folded = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = accounts.filter { ($0["name"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded }
        var found = exact.count == 1 ? exact : named
        if crossAI, found.count > 1, let provider, found.filter({ $0["provider"].string == provider }).count == 1 { found = found.filter { $0["provider"].string == provider } }
        let names = accounts.map { "\($0["name"].string ?? "") (\($0["provider"].string ?? ""))" }.joined(separator: ", ")
        guard !found.isEmpty else { throw BackendDeckToolsArgs.bad("there is no account called \"\(wanted)\". The accounts are: \(names.isEmpty ? "none" : names).") }
        guard found.count == 1 else { throw BackendDeckToolsArgs.bad("more than one account is called \"\(wanted)\"; name it by id instead. The accounts are: \(names).") }
        let account = found[0]
        if !crossAI, let provider, provider != account["provider"].string {
            throw BackendDeckToolsArgs.bad("\(account["name"].string ?? "") is a \(account["provider"].string ?? "") login, so it cannot run a \(provider) session")
        }
        return account
    }
    public static func title(_ args: NativeRPCValue) throws -> String {
        guard let raw = args["title"].string else { throw BackendDeckToolsArgs.bad("title is required and must be a string (\"\" resets it)") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines), count = text.utf16.count
        guard count <= 120 else { throw BackendDeckToolsArgs.bad("title must be 120 characters or fewer; got \(count)") }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || (0x80...0x9f).contains($0.value) }) else { throw BackendDeckToolsArgs.bad("title must be one line of printable text") }
        return text
    }
    public static func capScreen(_ raw: String) -> (text: String, partial: Bool) {
        let text = raw.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return (BackendDeckToolsSupport.slice(text, max(0, text.utf16.count - 8_000)), text.utf16.count > 8_000)
    }
    public static func trimInsights(_ raw: NativeRPCValue) -> NativeRPCValue {
        guard let fields = raw.fields else { return raw }
        return .object(fields.compactMap { field in
            if field.key == "timeline" || field.key == "contextSeries" { return nil }
            if let array = field.value.elements {
                if field.key == "heaviest" { return .init(field.key, .array(Array(array.prefix(5)))) }
                if field.key == "tools" { return .init(field.key, .array(Array(array.prefix(15)))) }
                if field.key == "compactions" { return .init(field.key, .number(Double(array.count))) }
            }
            return field
        })
    }
    public static func displayID(_ raw: NativeRPCValue, view: NativeRPCValue) throws -> Double? {
        if raw.isNullish || raw.string == "" { return nil }
        let displays = view["displays"].elements ?? []
        if let number = raw.number {
            if displays.contains(where: { $0["id"].number == number }) { return number }
            throw BackendDeckToolsArgs.bad("there is no display with id \(number.formatted(.number.grouping(.never))); windows.list names the ones there are")
        }
        if let string = raw.string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let number = Double(trimmed), number.isFinite, displays.contains(where: { $0["id"].number == number }) { return number }
            let wanted = trimmed.lowercased()
            if wanted == "main" || wanted == "primary", let primary = displays.first(where: { $0["primary"].bool == true }) { return primary["id"].number }
            let found = displays.filter { $0["label"].string?.lowercased() == wanted }
            if found.count == 1 { return found[0]["id"].number }
            throw BackendDeckToolsArgs.bad(found.isEmpty ? "no display is called “\(string)”; windows.list names the ones there are" : "two displays are called “\(string)”; pass its id from windows.list instead")
        }
        throw BackendDeckToolsArgs.bad("display must be a display id or name from windows.list")
    }
}

/// transcript-match.ts uses UTF-16 IDs for deterministic ties, and millisecond dates.
public enum BackendDeckToolsSessionsTranscriptMatch {
    public static let startToleranceMilliseconds = 120_000.0
    public static func writesTranscripts(_ provider: String?) -> Bool { provider == nil || provider == "claude" }
    public static func match(session: NativeRPCValue, files: [NativeRPCValue], sessionsInFolder: [NativeRPCValue], toleranceMilliseconds: Double = startToleranceMilliseconds) -> NativeRPCValue {
        BackendDeckCoreReports.matchTranscript(session: session, files: files, sessionsInFolder: sessionsInFolder, toleranceMs: toleranceMilliseconds)
    }
}

public enum BackendDeckToolsSessionsTyping {
    public static let keyGapMilliseconds = Int(BackendDeckCoreTyping.gapMs)
    public static let escapeGapMilliseconds = Int(BackendDeckCoreTyping.escapeGapMs)
    public static let maximumKeys = BackendDeckCoreTyping.maxKeys
    public static let submitGapMilliseconds = Int(BackendDeckCoreTyping.submitGapMs)
    public typealias Key = BackendDeckCoreTyping.Key
    public static func resolveKey(_ raw: NativeRPCValue) throws -> Key { try BackendDeckToolsArgs.parsed { try BackendDeckCoreTyping.resolveKey(raw) } }
    public static func resolveKeys(_ raw: NativeRPCValue) throws -> [Key] { try BackendDeckToolsArgs.parsed { try BackendDeckCoreTyping.resolveKeys(raw) } }
    public static func typeLine(write: @Sendable (String) async throws -> Void, text: String, submit: Bool,
                                sleep: @escaping @Sendable (Int) async throws -> Void = realSleep) async throws {
        try await BackendDeckCoreTyping.typeLine(write: write, text: text, submit: submit, clock: .init(now: BackendDeckCoreBriefClock.real.now, sleep: { try await sleep(Int($0)) }))
    }
    public static func pressKeys(write: @Sendable (String) async throws -> Void, keys: [Key],
                                 sleep: @escaping @Sendable (Int) async throws -> Void = realSleep) async throws {
        try await BackendDeckCoreTyping.pressKeys(write: write, keys: keys, clock: .init(now: BackendDeckCoreBriefClock.real.now, sleep: { try await sleep(Int($0)) }))
    }
    public static func realSleep(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    public static func sanitizeSendText(_ raw: String) throws -> String { try BackendDeckToolsArgs.parsed { try BackendDeckCoreCatalogueRules.sanitizeSendText(raw) } }
}
