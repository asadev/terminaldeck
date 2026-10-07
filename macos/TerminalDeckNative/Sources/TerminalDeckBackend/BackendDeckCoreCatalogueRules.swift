import Foundation
import TerminalDeckNativeCore

/// Shared source rules; validation errors stay different from consent refusals.
public enum BackendDeckCoreCatalogueRules {
    public static let maxSendChars = 4_000
    public static let maxNoteChars = 300
    public static let maxCatalogueTools = 20
    public static let maxCatalogueTokens = 8_000
    public static let estimatedCharsPerToken = 3.5
    public static let protectedPrefixes = ["remote.", "copilot.", "deckControl.", "security.", "confine."]
    public static let protectedKeys = ["browser.persistSession", "advanced.debugMode"]
    public static let writablePreferences = ["theme", "defaultProvider", "restoreSessions", "notifyOnComplete"]
    // ECMAScript trim's set excludes C1 U+0085 and includes the BOM U+FEFF.
    private static let trimCharacters = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    public static func trim(_ value: String) -> String { value.trimmingCharacters(in: trimCharacters) }
    public static func coverageWords(_ query: String) -> [String] {
        query.lowercased().components(separatedBy: trimCharacters.union(CharacterSet(charactersIn: ":._-"))).filter { $0.utf16.count > 1 }
    }

    public static func isProtectedSetting(_ key: String) -> Bool {
        protectedKeys.contains(key) || protectedPrefixes.contains { key.hasPrefix($0) }
    }
    public static func estimateTokens(_ text: String) -> Int {
        Int(ceil(Double(text.utf16.count) / estimatedCharsPerToken))
    }
    public static func sanitizeSendText(_ raw: String) throws -> String {
        let count = raw.utf16.count
        guard count > 0 else { throw NativeRPCError.invalidArguments("text must not be empty") }
        guard count <= maxSendChars else {
            throw NativeRPCError.invalidArguments("text must be \(maxSendChars) characters or fewer; got \(count)")
        }
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f {
                throw NativeRPCError.invalidArguments("text may only contain printable characters — no newlines, tabs, escape sequences or control keys. Set submit: true to send the line rather than embedding a newline.")
            }
            if (0x80...0x9f).contains(scalar.value) {
                throw NativeRPCError.invalidArguments("text may not contain control characters")
            }
        }
        return raw
    }
    public static func sanitizeNote(_ raw: String) throws -> String {
        let note = trim(raw)
        guard !note.isEmpty else { throw NativeRPCError.invalidArguments("note must not be empty") }
        guard note.utf16.count <= maxNoteChars else {
            throw NativeRPCError.invalidArguments("note must be \(maxNoteChars) characters or fewer; got \(note.utf16.count). The action log is a list somebody scans — say the one line, not the story.")
        }
        guard !note.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || (0x80...0x9f).contains($0.value) }) else {
            throw NativeRPCError.invalidArguments("note must be a single line of printable text — no newlines or control characters")
        }
        return note
    }
    public static func withEmptiness(_ value: NativeRPCValue, produced: Double, whenNone: String) -> NativeRPCValue {
        let empty = produced <= 0
        return NativeRPCValue.object(value.spreadFields).setting("empty", .bool(empty)).setting("emptyReason", .string(empty ? whenNone : ""))
    }
    public static func emptySummary(_ produced: Double) -> NativeRPCValue { .object([.init("empty", .bool(produced <= 0))]) }

    public static func string(_ args: NativeRPCValue, _ key: String) throws -> String {
        guard let value = args[key].string, !trim(value).isEmpty else {
            throw NativeRPCError.invalidArguments("\(key) is required and must be a non-empty string")
        }
        return value
    }
    public static func optionalString(_ args: NativeRPCValue, _ key: String) throws -> String? {
        let value = args[key]
        if value.isNullish || value == .string("") { return nil }
        guard let text = value.string else { throw NativeRPCError.invalidArguments("\(key) must be a string") }
        return text
    }
    public static func optionalBool(_ args: NativeRPCValue, _ key: String, fallback: Bool) throws -> Bool {
        if args[key].isNullish { return fallback }
        guard let flag = args[key].bool else { throw NativeRPCError.invalidArguments("\(key) must be true or false") }
        return flag
    }
    public static func optionalInt(_ args: NativeRPCValue, _ key: String, fallback: Int, min: Int, max: Int) throws -> Int {
        if args[key].isNullish { return fallback }
        guard let number = args[key].number else { throw NativeRPCError.invalidArguments("\(key) must be a number") }
        return Int(Swift.min(Double(max), Swift.max(Double(min), number.rounded(.towardZero))))
    }
    public static func record(_ args: NativeRPCValue, _ key: String) throws -> NativeRPCValue {
        guard args[key].fields != nil else { throw NativeRPCError.invalidArguments("\(key) must be an object") }
        return args[key]
    }
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    public static func prefix(_ text: String, _ length: Int) -> String { String(decoding: text.utf16.prefix(length), as: UTF16.self) }
    public static func suffix(_ text: String, _ length: Int) -> String { String(decoding: text.utf16.suffix(length), as: UTF16.self) }
    public static func jsString(_ value: NativeRPCValue) -> String {
        switch value {
        case .missing: return "undefined"
        case .null: return "null"
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            if number.isNaN { return "NaN" }
            if !number.isFinite { return number < 0 ? "-Infinity" : "Infinity" }
            return value.compact
        case .array(let array): return array.map { $0.isNullish ? "" : jsString($0) }.joined(separator: ",")
        default: return "[object Object]"
        }
    }
}

/// schema.ts: enforce only the vocabulary the source enforces, in the same order.
public enum BackendDeckCoreCatalogueSchema {
    public static func check(schema: NativeRPCValue, arguments args: NativeRPCValue) throws {
        guard schema.fields != nil else { return }
        let properties = schema["properties"].fields ?? []
        if schema["additionalProperties"] == .bool(false) {
            let strangers = (args.fields ?? []).filter { field in
                field.value != .missing && !properties.contains { $0.key == field.key }
            }.map(\.key)
            if !strangers.isEmpty {
                let names = properties.map(\.key)
                throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(strangers.joined(separator: ", ")) \(strangers.count == 1 ? "is not an argument" : "are not arguments") this tool takes. It takes: \(names.isEmpty ? "nothing" : names.joined(separator: ", ")).")
            }
        }
        for property in properties where args[property.key] != .missing && property.value.fields != nil {
            try checkValue(where: property.key, value: args[property.key], schema: property.value)
        }
        let missing = (schema["required"].elements ?? []).compactMap(\.string).filter { args[$0] == .missing }
        if !missing.isEmpty {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") required")
        }
    }
    public static func check(tool: BackendMCPTool, arguments: NativeRPCValue) throws { try check(schema: tool.inputSchema, arguments: arguments) }
    private static func kind(_ value: NativeRPCValue) -> String {
        switch value {
        case .missing: return "undefined"
        case .null: return "null"
        case .string: return "string"
        case .bool: return "boolean"
        case .array: return "array"
        case .number(let number): return number.isFinite && number.rounded(.towardZero) == number ? "integer" : "number"
        default: return "object"
        }
    }
    private static func matches(_ value: NativeRPCValue, _ type: String) -> Bool {
        switch type {
        case "string": return value.string != nil
        case "boolean": return value.bool != nil
        case "number": return value.number != nil
        case "integer": return value.number.map { $0.rounded(.towardZero) == $0 } ?? false
        case "array": return value.elements != nil
        case "object": return value.fields != nil
        case "null": return value == .null
        default: return true
        }
    }
    private static func checkValue(where name: String, value: NativeRPCValue, schema: NativeRPCValue) throws {
        if let type = schema["type"].string, !matches(value, type) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(name) must be \(type), not \(kind(value))")
        }
        if let types = schema["type"].elements, !types.compactMap(\.string).contains(where: { matches(value, $0) }) {
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(name) must be one of: \(types.compactMap(\.string).joined(separator: ", "))")
        }
        if let values = schema["enum"].elements, !values.contains(where: { enumEqual($0, value) }) {
            let shown: String
            if let text = value.string {
                shown = NativeRPCValue.string(BackendDeckCoreCatalogueRules.prefix(text, 40)).compact + (text.utf16.count > 40 ? "…" : "")
            } else if value.number != nil || value.bool != nil || value == .null { shown = BackendDeckCoreCatalogueRules.jsString(value) }
            else { shown = kind(value) }
            throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(name) must be one of: \(values.map(BackendDeckCoreCatalogueRules.jsString).joined(separator: ", ")) — not \(shown)")
        }
        if let array = value.elements, schema["items"].fields != nil {
            for (index, entry) in array.enumerated() { try checkValue(where: "\(name)[\(index)]", value: entry, schema: schema["items"]) }
        }
    }
    private static func enumEqual(_ lhs: NativeRPCValue, _ rhs: NativeRPCValue) -> Bool {
        // Array.includes in the source does not use structural object equality.
        if lhs.fields != nil || lhs.elements != nil || rhs.fields != nil || rhs.elements != nil { return false }
        if case .number(let a) = lhs, case .number(let b) = rhs, a.isNaN && b.isNaN { return true }
        return lhs == rhs
    }
}

public struct BackendDeckCoreCatalogueRunTarget: Sendable {
    public let name: String
    public let arguments: NativeRPCValue
    public static func parse(_ args: NativeRPCValue) throws -> Self {
        guard let raw = args["name"].string, !BackendDeckCoreCatalogueRules.trim(raw).isEmpty else {
            throw NativeRPCError.invalidArguments("name is required: the tool to run, as tools_describe lists it")
        }
        var inner = args["arguments"].isNullish ? NativeRPCValue.object([]) : args["arguments"]
        if let text = inner.string {
            let trimmed = BackendDeckCoreCatalogueRules.trim(text)
            if trimmed.isEmpty { inner = .object([]) }
            else {
                guard let decoded = try? NativeRPCValue.parseJSON(Data(text.utf8)) else {
                    throw NativeRPCError.invalidArguments("arguments must be an object of that tool’s arguments")
                }
                inner = decoded
            }
        }
        guard inner.fields != nil else { throw NativeRPCError.invalidArguments("arguments must be an object of that tool’s arguments") }
        return Self(name: BackendDeckCoreCatalogueRules.trim(raw), arguments: inner)
    }
}

public struct BackendDeckCoreCatalogueSettingProblem: Sendable, Equatable {
    public let key: String
    public let problem: String
}
public struct BackendDeckCoreCataloguePatchCheck: Sendable {
    public let problems: [BackendDeckCoreCatalogueSettingProblem]
    public let effective: NativeRPCValue
    public let adjusted: [String]
    public var problemSentence: String { problems.map(\.problem).joined(separator: " ") }
}
public enum BackendDeckCoreCatalogueSettings {
    public static func check(scope: String, patch: NativeRPCValue) -> BackendDeckCoreCataloguePatchCheck {
        var problems: [BackendDeckCoreCatalogueSettingProblem] = [], adjusted: [String] = []
        var effective = NativeRPCValue.object([])
        for field in patch.fields ?? [] {
            let key = field.key, raw = field.value
            let setting = scope == "settings" ? SettingsSchema.setting(key) : SettingsSchema.all.first { $0.prefsKey == key }
            guard let setting else {
                problems.append(.init(key: key, problem: scope == "settings" ? "there is no setting called \(key). Call settings.read to see the ones that exist." : "\(key) is not a preference this app stores."))
                continue
            }
            if raw.isNullish {
                if scope != "settings" { problems.append(.init(key: key, problem: "\(key) cannot be set to null. Send the value you want instead — \(describe(setting)).")) }
                continue
            }
            if scope == "settings", setting.store == .prefs, let preference = setting.prefsKey {
                problems.append(.init(key: key, problem: "\(key) lives in preferences, not settings — writing it here would be ignored. Use scope \"preferences\" with the key \(preference)."))
                continue
            }
            guard let value = coerce(setting, raw) else {
                problems.append(.init(key: key, problem: "\(describe(setting)); got \(raw.compact)"))
                continue
            }
            effective = effective.setting(key, value)
            if value != raw { adjusted.append(key) }
        }
        return .init(problems: problems, effective: effective, adjusted: adjusted)
    }
    private static func coerce(_ setting: SettingDefinition, _ raw: NativeRPCValue) -> NativeRPCValue? {
        switch setting.kind {
        case .toggle: return raw.bool.map(NativeRPCValue.bool)
        case .select: return raw.string.flatMap { text in setting.options.contains { $0.value == text } ? .string(text) : nil }
        case .text: return raw.string.map { .string(BackendDeckCoreCatalogueRules.prefix($0, SettingsSchema.maxTextLength)) }
        case .number:
            guard let n = raw.number, let range = setting.number else { return nil }
            let clamped = Swift.min(range.max, Swift.max(range.min, n))
            // JS Math.round is floor(x + 0.5), including its negative-half rule.
            let steps = floor((clamped - range.min) / range.step + 0.5)
            return .number(Swift.min(range.max, range.min + steps * range.step))
        }
    }
    private static func describe(_ setting: SettingDefinition) -> String {
        switch setting.kind {
        case .toggle: return "\(setting.id) is a switch: true or false"
        case .select: return "\(setting.id) accepts one of: \(setting.options.map(\.value).joined(separator: ", "))"
        case .number: return "\(setting.id) is a number between \(NativeRPCValue.number(setting.number?.min ?? 0).compact) and \(NativeRPCValue.number(setting.number?.max ?? 0).compact)"
        case .text: return "\(setting.id) is text"
        }
    }
}
