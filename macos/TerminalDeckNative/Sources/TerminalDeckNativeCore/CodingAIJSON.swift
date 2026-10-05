import Foundation

/// One JSON value from the engine, for the Coding AI settings screen.
///
/// `EngineBridge.invoke` hands back whatever `JSONSerialization` made — and
/// that turns `true` into an `NSNumber`, which `as? Bool` also accepts for `1`
/// and `as? Int` accepts for `true`. The web side narrows every field with
/// `=== true` / `typeof … === 'string'`; this keeps the same strictness, so a
/// field the engine sent as a number is never read as a yes.
public enum CodingAIJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CodingAIJSON])
    case object([String: CodingAIJSON])

    /// A Foundation value (from `JSONSerialization` or the engine bridge).
    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let text as String:
            self = .string(text)
        case let list as [Any]:
            self = .array(list.map { CodingAIJSON($0) })
        case let map as [String: Any]:
            self = .object(map.mapValues { CodingAIJSON($0) })
        case let flag as Bool:
            self = .bool(flag)
        case let int as Int:
            self = .number(Double(int))
        case let double as Double:
            self = .number(double)
        default:
            self = .null
        }
    }

    /// Parse JSON text — for fixtures and for answers read out of a page.
    public static func parse(_ text: String) -> CodingAIJSON {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
        return CodingAIJSON(any)
    }

    public subscript(key: String) -> CodingAIJSON {
        if case .object(let map) = self { return map[key] ?? .null }
        return .null
    }

    public var isObject: Bool { if case .object = self { return true }; return false }
    public var isNull: Bool { self == .null }

    public var object: [String: CodingAIJSON]? {
        if case .object(let map) = self { return map }
        return nil
    }

    public var array: [CodingAIJSON]? {
        if case .array(let list) = self { return list }
        return nil
    }

    /// The string, when this is one (empty included).
    public var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The string when it is one and not empty — the web's `typeof x === 'string' && x !== ''`.
    public var text: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }

    /// Only a real JSON boolean. `1` is not `true` here.
    public var bool: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// `=== true`.
    public var isTrue: Bool { bool == true }

    /// A finite number.
    public var number: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }

    /// Back to a Foundation value the engine bridge can send.
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return flag
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .string(let text): return text
        case .array(let list): return list.map(\.foundation)
        case .object(let map): return map.mapValues(\.foundation)
        }
    }

    /// Compact JSON text (sorted keys, so it is stable in tests and in scripts).
    public var jsonText: String {
        let value = foundation
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "null"
    }
}

/// An error from the engine, reduced to the sentence a person can read.
///
/// Mirrors `errorText` in `settings-bridge.ts`: Electron prefixes a rejected
/// invoke with the channel and handler frame, and the sentence the main process
/// actually wrote is after the last `Error:`. Never empty.
public enum CodingAIErrorText {
    public static func from(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        let parts = trimmed.components(separatedBy: "Error:")
        let tail = (parts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? trimmed : tail
    }

    public static func from(_ error: Error, fallback: String) -> String {
        if let wire = error as? EngineWireError {
            switch wire {
            case .refused(let why): return from(why, fallback: fallback)
            case .notReady: return "Terminal Deck isn't running yet."
            case .malformed, .http: return fallback
            }
        }
        return from(String(describing: error), fallback: fallback)
    }
}
