import Foundation
import TerminalDeckNativeCore

/// agents-area-args.ts intentionally trims strings; catalogue.ts does not.
public enum BackendDeckToolsSessionsRules {
    public static func str(_ args: NativeRPCValue, _ key: String) throws -> String {
        try BackendDeckToolsArgs.str(args, key).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        guard let value = try BackendDeckToolsArgs.optStr(args, key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, _ allowed: [String], fallback: String? = nil) throws -> String {
        let value = args[key]
        if (value.isNullish || value.string == ""), let fallback { return fallback }
        if let string = value.string, allowed.contains(string) { return string }
        throw BackendDeckToolsArgs.bad("\(key) must be one of: \(allowed.joined(separator: ", "))")
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
        guard let list = value.elements, list.allSatisfy({ $0.string != nil }) else { throw BackendDeckToolsArgs.bad("\(key) must be a list of strings") }
        return list.compactMap(\.string)
    }
    public static func withoutSecrets(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        if depth > 8 { return value }
        if let elements = value.elements { return .array(elements.map { withoutSecrets($0, depth: depth + 1) }) }
        guard let fields = value.fields else { return value }
        return .object(fields.map { field in
            let secret = field.key.range(of: #"^key$|token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer|private"#, options: [.regularExpression, .caseInsensitive]) != nil
            return .init(field.key, secret && field.value.string != nil ? .string("[withheld]") : withoutSecrets(field.value, depth: depth + 1))
        })
    }
    public static func chooseAccount(_ accounts: [NativeRPCValue], wanted: String, provider: String?) throws -> NativeRPCValue {
        let exact = accounts.filter { $0["id"].string == wanted }
        let folded = wanted.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = accounts.filter { ($0["name"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded }
        let found = exact.count == 1 ? exact : named
        let names = accounts.map { "\($0["name"].string ?? "") (\($0["provider"].string ?? ""))" }.joined(separator: ", ")
        guard !found.isEmpty else { throw BackendDeckToolsArgs.bad("there is no account called \"\(wanted)\". The accounts are: \(names.isEmpty ? "none" : names).") }
        guard found.count == 1 else { throw BackendDeckToolsArgs.bad("more than one account is called \"\(wanted)\"; name it by id instead. The accounts are: \(names).") }
        let account = found[0]
        if let provider, provider != account["provider"].string {
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
        let id = session["id"].string, start = session["createdAt"].number ?? 0
        let others = sessionsInFolder.filter { $0["id"].string != id && writesTranscripts($0["provider"].string) }.compactMap { $0["id"].string }
        func answer(_ path: String?, _ basis: String, _ ambiguous: Bool, _ note: String?) -> NativeRPCValue {
            BackendDeckToolsSupport.object([("path", path.map(NativeRPCValue.string) ?? .null), ("basis", .string(basis)), ("ambiguous", .bool(ambiguous)), ("otherSessions", .array(others.map(NativeRPCValue.string))), ("note", note.map(NativeRPCValue.string) ?? .null)])
        }
        guard writesTranscripts(session["provider"].string) else { return answer(nil, "none", false, "A \(session["provider"].string ?? "session") session writes no transcript, so nothing in this folder is its conversation.") }
        let conversations = files.filter { ($0["bytes"].number ?? 0) > 0 }
        guard !conversations.isEmpty else { return answer(nil, "none", false, nil) }
        func newest(_ files: [NativeRPCValue]) -> NativeRPCValue { files.dropFirst().reduce(files[0]) { ($1["modifiedAt"].number ?? 0) > ($0["modifiedAt"].number ?? 0) ? $1 : $0 } }
        if others.isEmpty { return answer(newest(conversations)["path"].string, conversations.count == 1 ? "only-one" : "newest", false, conversations.count == 1 ? nil : "Several conversations in this folder; this is the most recent, and no other session is running here.") }
        if session["resumed"].bool == true { return answer(newest(conversations)["path"].string, "newest", true, "This is the most recently written conversation in the folder rather than certainly this session's — it was resumed, so its conversation began before it did. Treat what it says as possibly another session's.") }
        let born = conversations.filter { let at = $0["createdAt"].number ?? 0; return at >= start - toleranceMilliseconds && at <= start + toleranceMilliseconds }
        if born.isEmpty { return answer(nil, "none", false, "Every conversation in this folder began before this session started, so none of them is its. It has not written one yet.") }
        // Source includes every non-resumed claimant, even a non-transcript provider.
        let claimants = sessionsInFolder.filter { $0["resumed"].bool != true }
        let mine = born.filter { file in
            let birth = file["createdAt"].number ?? 0
            let nearest = claimants.min { a, b in
                let aGap = abs(birth - (a["createdAt"].number ?? 0)), bGap = abs(birth - (b["createdAt"].number ?? 0))
                if aGap != bGap { return aGap < bGap }
                return Array((a["id"].string ?? "").utf16).lexicographicallyPrecedes(Array((b["id"].string ?? "").utf16))
            }
            return nearest?["id"].string == id
        }
        if mine.isEmpty { return answer(nil, "none", false, "Every conversation in this folder began nearer to another session's start than to this one's, so none of them is its.") }
        if mine.count == 1 { return answer(mine[0]["path"].string, "started-together", true, "\(others.count) other session\(others.count == 1 ? "" : "s") share this folder; this file is the one that began nearest to when this session did.") }
        let closest = mine.dropFirst().reduce(mine[0]) { abs(($1["createdAt"].number ?? 0) - start) < abs(($0["createdAt"].number ?? 0) - start) ? $1 : $0 }
        return answer(closest["path"].string, "nearest-start", true, "\(mine.count) conversations here began nearest to this session; this is the closest of them. Treat what it says as possibly another session's.")
    }
}

public enum BackendDeckToolsSessionsTyping {
    public static let keyGapMilliseconds = 50, escapeGapMilliseconds = 150, maximumKeys = 24
    public struct Key: Sendable, Equatable { public let name: String, label: String, bytes: String }
    private static let table: [(String, String, String)] = [
        ("enter", "Enter", "\r"), ("escape", "Escape", "\u{1b}"), ("tab", "Tab", "\t"), ("shift-tab", "Shift-Tab", "\u{1b}[Z"),
        ("backspace", "Backspace", "\u{7f}"), ("delete", "Delete", "\u{1b}[3~"), ("space", "Space", " "),
        ("up", "Up", "\u{1b}[A"), ("down", "Down", "\u{1b}[B"), ("right", "Right", "\u{1b}[C"), ("left", "Left", "\u{1b}[D"),
        ("home", "Home", "\u{1b}[H"), ("end", "End", "\u{1b}[F"), ("page-up", "Page Up", "\u{1b}[5~"), ("page-down", "Page Down", "\u{1b}[6~"),
        ("ctrl-c", "Ctrl-C", "\u{3}"), ("ctrl-d", "Ctrl-D", "\u{4}"), ("ctrl-l", "Ctrl-L", "\u{c}"), ("ctrl-u", "Ctrl-U", "\u{15}"),
        ("ctrl-r", "Ctrl-R", "\u{12}"), ("ctrl-o", "Ctrl-O", "\u{f}"), ("ctrl-t", "Ctrl-T", "\u{14}"), ("ctrl-a", "Ctrl-A", "\u{1}"), ("ctrl-e", "Ctrl-E", "\u{5}"),
    ]
    public static func resolveKey(_ raw: NativeRPCValue) throws -> Key {
        guard let string = raw.string, !string.isEmpty else { throw BackendDeckToolsArgs.bad("each key must be a non-empty string") }
        if string.unicodeScalars.count == 1, let scalar = string.unicodeScalars.first {
            guard scalar.value >= 0x20 && scalar.value != 0x7f && !(0x80...0x9f).contains(scalar.value) else { throw BackendDeckToolsArgs.bad("a single-character key must be printable; name control keys instead, e.g. \"ctrl-c\"") }
            return Key(name: "char:" + string, label: string == " " ? "Space" : "“\(string)”", bytes: string)
        }
        let folded = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: #"[+_\s]"#, with: "-", options: .regularExpression)
        let aliases = ["return":"enter", "esc":"escape", "arrow-up":"up", "arrow-down":"down", "arrow-left":"left", "arrow-right":"right", "pageup":"page-up", "pagedown":"page-down", "shifttab":"shift-tab", "shift+tab":"shift-tab"]
        let name = aliases[folded] ?? folded
        guard let key = table.first(where: { $0.0 == name }) else { throw BackendDeckToolsArgs.bad("there is no key called \"\(string)\". Name one of: \(table.map(\.0).joined(separator: ", ")) — or give a single printable character such as \"y\" or \"2\".") }
        return Key(name: name, label: key.1, bytes: key.2)
    }
    public static func resolveKeys(_ raw: NativeRPCValue) throws -> [Key] {
        guard let list = raw.elements, !list.isEmpty else { throw BackendDeckToolsArgs.bad("keys must be a non-empty list") }
        guard list.count <= maximumKeys else { throw BackendDeckToolsArgs.bad("at most 24 keys in one call; got \(list.count)") }
        return try list.map(resolveKey)
    }
    public static func typeLine(write: @Sendable (String) async throws -> Void, text: String, submit: Bool,
                                sleep: @Sendable (Int) async throws -> Void = realSleep) async throws {
        try await write(submit && text.contains("@") ? text + " " : text)
        if submit { try await sleep(keyGapMilliseconds); try await write("\r") }
    }
    public static func pressKeys(write: @Sendable (String) async throws -> Void, keys: [Key],
                                 sleep: @Sendable (Int) async throws -> Void = realSleep) async throws {
        for (index, key) in keys.enumerated() {
            try await write(key.bytes)
            if index < keys.count - 1 { try await sleep(key.bytes == "\u{1b}" ? escapeGapMilliseconds : keyGapMilliseconds) }
        }
    }
    public static func realSleep(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
}

extension BackendDeckToolsSessionsTyping {
    /// catalogue.ts; used by paired-machine and SSH-shell tools too.
    public static func sanitizeSendText(_ raw: String) throws -> String {
        guard !raw.isEmpty else { throw BackendDeckToolsArgs.bad("text must not be empty") }
        guard raw.utf16.count <= 4_000 else { throw BackendDeckToolsArgs.bad("text must be 4000 characters or fewer; got \(raw.utf16.count)") }
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f { throw BackendDeckToolsArgs.bad("text may only contain printable characters — no newlines, tabs, escape sequences or control keys. Set submit: true to send the line rather than embedding a newline.") }
            if (0x80...0x9f).contains(scalar.value) { throw BackendDeckToolsArgs.bad("text may not contain control characters") }
        }
        return raw
    }
}
