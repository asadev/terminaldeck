import Foundation

/// A JSON value that keeps its keys in the order they were written.
///
/// The MCP inspector lays a tool's arguments out in the order its schema lists
/// them and prints results and schemas as `JSON.stringify(value, null, 2)` does
/// — both depend on key order, which `JSONSerialization` throws away. So the
/// MCP screens read the engine's answer with this parser, and print with
/// ``pretty``, which matches JavaScript's output character for character for
/// everything a tool can send.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OrderedJSON])
    case object([Field])

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: OrderedJSON
        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    // MARK: Reading

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let fields) = self else { return nil }
        return fields.last(where: { $0.key == key })?.value
    }

    public var fields: [Field]? { if case .object(let f) = self { return f }; return nil }
    public var array: [OrderedJSON]? { if case .array(let a) = self { return a }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var number: Double? { if case .number(let n) = self, n.isFinite { return n }; return nil }
    public var isObject: Bool { fields != nil }
    public var isTrue: Bool { bool == true }

    /// `typeof x === 'string' && x !== ''`.
    public var text: String? { string.flatMap { $0.isEmpty ? nil : $0 } }

    /// Whether `key in object` (JavaScript's `'const' in raw`).
    public func has(_ key: String) -> Bool { fields?.contains(where: { $0.key == key }) ?? false }

    /// The same object with one key set (replaced in place, or added last).
    public func setting(_ key: String, _ value: OrderedJSON) -> OrderedJSON {
        var list = fields ?? []
        if let index = list.firstIndex(where: { $0.key == key }) { list[index] = Field(key, value) } else { list.append(Field(key, value)) }
        return .object(list)
    }

    /// The same object without a key.
    public func removing(_ key: String) -> OrderedJSON {
        .object((fields ?? []).filter { $0.key != key })
    }

    // MARK: Writing

    /// `JSON.stringify(value, null, 2)`.
    public var pretty: String { Self.write(self, indent: 0, pretty: true) }

    /// `JSON.stringify(value)`.
    public var compact: String { Self.write(self, indent: 0, pretty: false) }

    /// For sending back through the engine bridge.
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { return Int(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let f):
            var map: [String: Any] = [:]
            for field in f { map[field.key] = field.value.foundation }
            return map
        }
    }

    private static func write(_ value: OrderedJSON, indent: Int, pretty: Bool) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return jsNumber(n)
        case .string(let s): return quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if !pretty { return "[" + items.map { write($0, indent: 0, pretty: false) }.joined(separator: ",") + "]" }
            let pad = String(repeating: "  ", count: indent + 1)
            let body = items.map { pad + write($0, indent: indent + 1, pretty: true) }.joined(separator: ",\n")
            return "[\n\(body)\n\(String(repeating: "  ", count: indent))]"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            if !pretty { return "{" + fields.map { quote($0.key) + ":" + write($0.value, indent: 0, pretty: false) }.joined(separator: ",") + "}" }
            let pad = String(repeating: "  ", count: indent + 1)
            let body = fields.map { pad + quote($0.key) + ": " + write($0.value, indent: indent + 1, pretty: true) }.joined(separator: ",\n")
            return "{\n\(body)\n\(String(repeating: "  ", count: indent))}"
        }
    }

    /// JavaScript's number to string: integers without a decimal point, `NaN`/`Infinity` as `null`.
    public static func jsNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n.rounded() == n, abs(n) < 1e21 {
            if n == 0 { return "0" }
            return String(format: "%.0f", n)
        }
        var text = "\(n)"
        if text.hasSuffix(".0") { text.removeLast(2) }
        if let e = text.range(of: "e") {
            // Swift writes 1e-07; JavaScript writes 1e-7 and 1e+21.
            let mantissa = text[..<e.lowerBound]
            var exponent = String(text[e.upperBound...])
            let negative = exponent.hasPrefix("-")
            exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            while exponent.hasPrefix("0"), exponent.count > 1 { exponent.removeFirst() }
            text = "\(mantissa)e\(negative ? "-" : "+")\(exponent)"
        }
        return text
    }

    public static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    /// Parse JSON text, keeping key order. Nil when it is not JSON.
    public static func parse(_ text: String) -> OrderedJSON? {
        parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) -> OrderedJSON? {
        var parser = Parser(bytes: [UInt8](data))
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        return parser.atEnd ? value : nil
    }

    /// An invoke answer (`{ok:true, value}` / `{ok:false, error}`), read with order kept.
    public static func invokeResult(_ data: Data) -> Result<OrderedJSON, EngineWireError> {
        guard let answer = parse(data), answer.isObject else { return .failure(.malformed) }
        if answer["ok"]?.isTrue == true { return .success(decodeBytes(answer["value"] ?? .null)) }
        return .failure(.refused(answer["error"]?.string ?? "the engine refused the call"))
    }

    /// `{"$bytes": …}` stays as is (the MCP screens never receive bytes); everything else passes through.
    private static func decodeBytes(_ value: OrderedJSON) -> OrderedJSON { value }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0
        var atEnd: Bool { at >= bytes.count }

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[at]) { at += 1 }
        }

        mutating func value() -> OrderedJSON? {
            skipSpace()
            guard at < bytes.count else { return nil }
            switch bytes[at] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return list()
            case UInt8(ascii: "\""): return string().map(OrderedJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ result: OrderedJSON) -> OrderedJSON? {
            let w = Array(word.utf8)
            guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { return nil }
            at += w.count
            return result
        }

        mutating func number() -> OrderedJSON? {
            let start = at
            while at < bytes.count, "+-0123456789.eE".utf8.contains(bytes[at]) { at += 1 }
            guard at > start, let text = String(bytes: bytes[start..<at], encoding: .utf8), let n = Double(text) else { return nil }
            return .number(n)
        }

        mutating func string() -> String? {
            guard bytes[at] == UInt8(ascii: "\"") else { return nil }
            at += 1
            var out = [UInt8]()
            while at < bytes.count {
                let byte = bytes[at]
                at += 1
                if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
                if byte != UInt8(ascii: "\\") { out.append(byte); continue }
                guard at < bytes.count else { return nil }
                let escape = bytes[at]
                at += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let first = hex4() else { return nil }
                    var scalar = first
                    if (0xD800...0xDBFF).contains(first), at + 1 < bytes.count,
                       bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                        at += 2
                        guard let second = hex4() else { return nil }
                        scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    }
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                default: return nil
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard at + 4 <= bytes.count, let text = String(bytes: bytes[at..<at + 4], encoding: .utf8),
                  let value = UInt32(text, radix: 16) else { return nil }
            at += 4
            return value
        }

        mutating func list() -> OrderedJSON? {
            at += 1
            var items: [OrderedJSON] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                return nil
            }
        }

        mutating func object() -> OrderedJSON? {
            at += 1
            var fields: [Field] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(fields) }
            while true {
                skipSpace()
                guard at < bytes.count, let key = string() else { return nil }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
                at += 1
                guard let item = value() else { return nil }
                fields.append(Field(key, item))
                skipSpace()
                guard at < bytes.count else { return nil }
                if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(fields) }
                return nil
            }
        }
    }
}
