import Foundation

/// Values at the native backend seam. Missing is JavaScript's undefined, and
/// remains different from null until ordinary JSON serialization requires it.
public indirect enum NativeRPCValue: Equatable, Sendable {
    case missing, null
    case bool(Bool), number(Double), string(String), bytes(Data)
    case array([NativeRPCValue]), object([Field])

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: NativeRPCValue
        public init(_ key: String, _ value: NativeRPCValue) { self.key = key; self.value = value }
    }

    public subscript(_ key: String) -> NativeRPCValue {
        fields?.last(where: { $0.key == key })?.value ?? .missing
    }
    public var fields: [Field]? { if case .object(let value) = self { value } else { nil } }
    public var elements: [NativeRPCValue]? { if case .array(let value) = self { value } else { nil } }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self, value.isFinite { value } else { nil } }
    public var isNullish: Bool { self == .missing || self == .null }
    public func has(_ key: String) -> Bool { fields?.contains(where: { $0.key == key && $0.value != .missing }) == true }

    public func setting(_ key: String, _ value: NativeRPCValue) -> NativeRPCValue {
        var result = fields ?? []
        if let index = result.firstIndex(where: { $0.key == key }) {
            result[index] = Field(key, value)
            result = result.enumerated().filter { $0.offset == index || $0.element.key != key }.map(\.element)
        } else { result.append(Field(key, value)) }
        return .object(result)
    }

    public func removing(_ key: String) -> NativeRPCValue { .object((fields ?? []).filter { $0.key != key }) }

    /// Object spread preserves existing key positions and appends new keys.
    public func merging(_ patch: NativeRPCValue) -> NativeRPCValue {
        var result = NativeRPCValue.object(spreadFields)
        for field in patch.spreadFields { result = result.setting(field.key, field.value) }
        return result
    }

    public var spreadFields: [Field] {
        switch self {
        case .object(let fields): return fields
        case .array(let elements): return elements.enumerated().map { Field(String($0.offset), $0.element) }
        case .string(let text): return text.enumerated().map { Field(String($0.offset), .string(String($0.element))) }
        default: return []
        }
    }

    public func requireString(_ label: String, nonempty: Bool = false) throws -> String {
        guard let value = string, !nonempty || !value.isEmpty else { throw NativeRPCError.invalidArguments("\(label) must be \(nonempty ? "a nonempty" : "a") string") }
        return value
    }
    public func requireObject(_ label: String) throws -> NativeRPCValue {
        guard fields != nil else { throw NativeRPCError.invalidArguments("\(label) must be an object") }
        return self
    }
    public func requireArray(_ label: String) throws -> [NativeRPCValue] {
        guard let elements else { throw NativeRPCError.invalidArguments("\(label) must be an array") }
        return elements
    }

    public var foundation: Any? {
        switch self {
        case .missing: return nil
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): if value.isFinite { return value }; return NSNull()
        case .string(let value): return value
        case .bytes(let value): return value
        case .array(let value): return value.map { $0.foundation ?? NSNull() }
        case .object(let value):
            var result: [String: Any] = [:]
            for field in value where field.value != .missing { result[field.key] = field.value.foundation }
            return result
        }
    }

    public static func fromFoundation(_ value: Any?) throws -> NativeRPCValue {
        guard let value else { return .missing }
        if value is NSNull { return .null }
        if let bytes = value as? Data { return .bytes(bytes) }
        if let string = value as? String { return .string(string) }
        if let date = value as? Date { return .string(ISO8601DateFormatter().string(from: date)) }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        }
        if let array = value as? [Any] { return .array(try array.map { try fromFoundation($0) }) }
        if let dictionary = value as? [String: Any] {
            // Foundation dictionaries have already lost source order. Callers
            // that require it must use parseJSON on the original bytes.
            return .object(try dictionary.keys.sorted().map { Field($0, try fromFoundation(dictionary[$0])) })
        }
        if let error = value as? Error {
            // TS wire.ts:36: an ordinary Error travels as `{ name, message }`; an RPC error keeps its own shape.
            if let rpc = error as? NativeRPCError { return rpc.wireValue }
            return .object([.init("name", .string("Error")), .init("message", .string(error.localizedDescription))])
        }
        throw NativeRPCError.invalidArguments("Unsupported native value type: \(String(describing: type(of: value)))")
    }

    public static func parseJSON(_ data: Data, decodeBytes: Bool = false, maximumBytes: Int = 67_108_864) throws -> NativeRPCValue {
        guard data.count <= maximumBytes else { throw NativeRPCError.malformed("JSON body is too large") }
        // OrderedJSON deliberately tolerates some display-only input. Foundation
        // validates strict JSON syntax before its ordered parser is used here.
        guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil,
              let ordered = OrderedJSON.parse(data) else { throw NativeRPCError.malformed("Invalid JSON") }
        return try convert(ordered, decodeBytes: decodeBytes, depth: 0)
    }

    public func encodedJSON(pretty: Bool = false) throws -> Data {
        let ordered = try ordered(depth: 0, inArray: false)
        return Data((pretty ? ordered.pretty : ordered.compact).utf8)
    }

    public var compact: String { (try? ordered(depth: 0, inArray: false).compact) ?? "null" }

    private static func convert(_ value: OrderedJSON, decodeBytes: Bool, depth: Int) throws -> NativeRPCValue {
        guard depth <= 64 else { throw NativeRPCError.malformed("JSON nesting exceeds 64 levels") }
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value):
            guard value.isFinite else { throw NativeRPCError.malformed("JSON number is not finite") }
            return .number(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(try value.map { try convert($0, decodeBytes: decodeBytes, depth: depth + 1) })
        case .object(let fields):
            if decodeBytes, fields.count == 1, fields[0].key == "$bytes", let text = fields[0].value.string {
                guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else {
                    throw NativeRPCError.malformed("Invalid $bytes envelope")
                }
                return .bytes(bytes)
            }
            var result = NativeRPCValue.object([])
            for field in fields where !decodeBytes || field.key != "__proto__" {
                result = result.setting(field.key, try convert(field.value, decodeBytes: decodeBytes, depth: depth + 1))
            }
            return result
        }
    }

    private func ordered(depth: Int, inArray: Bool) throws -> OrderedJSON {
        guard depth <= 64 else { throw NativeRPCError.malformed("Value nesting exceeds 64 levels") }
        switch self {
        case .missing, .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return value.isFinite ? .number(value) : .null
        case .string(let value): return .string(value)
        case .bytes(let value): return .object([.init("$bytes", .string(value.base64EncodedString()))])
        case .array(let value): return .array(try value.map { try $0.ordered(depth: depth + 1, inArray: true) })
        case .object(let value):
            return .object(try value.filter { $0.value != .missing }.map { .init($0.key, try $0.value.ordered(depth: depth + 1, inArray: false)) })
        }
    }
}

public struct NativeRPCError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: NativeRPCValue
    public init(code: String, message: String, details: NativeRPCValue = .missing) {
        self.code = code; self.message = message; self.details = details
    }
    public var errorDescription: String? { message }
    public var wireValue: NativeRPCValue {
        .object([.init("name", .string("Error")), .init("code", .string(code)), .init("message", .string(message)), .init("details", details)])
    }
    public static func invalidArguments(_ message: String) -> Self { .init(code: "invalid-arguments", message: message) }
    public static func malformed(_ message: String) -> Self { .init(code: "malformed", message: message) }
    public static func wrapping(_ error: Error) -> Self {
        error as? Self ?? .init(code: error is CancellationError ? "cancelled" : "internal", message: error.localizedDescription)
    }
}

public struct NativeRPCContext: Sendable {
    public enum Caller: String, Sendable { case nativeApp, internalEngine, page, pairedDevice }
    public let caller: Caller
    public let ownerID: String
    public let requestID: UUID
    public let origin: URL?
    public let capabilities: Set<String>

    public init(caller: Caller, ownerID: String, requestID: UUID = UUID(), origin: URL? = nil, capabilities: Set<String> = []) {
        self.caller = caller; self.ownerID = ownerID; self.requestID = requestID; self.origin = origin; self.capabilities = capabilities
    }
    public func require(_ capability: String) throws {
        guard caller == .nativeApp || caller == .internalEngine || capabilities.contains(capability) else {
            throw NativeRPCError(code: "access-denied", message: "The caller does not have \(capability) access")
        }
    }
    public func argument(_ index: Int, in values: [NativeRPCValue]) -> NativeRPCValue {
        values.indices.contains(index) ? values[index] : .missing
    }
    public func requireCount(_ values: [NativeRPCValue], _ range: ClosedRange<Int>) throws {
        guard range.contains(values.count) else { throw NativeRPCError.invalidArguments("Expected \(range.lowerBound)...\(range.upperBound) arguments, got \(values.count)") }
    }
}

public struct NativeRPCRequest: Sendable {
    public let channel: String
    public let arguments: [NativeRPCValue]
    public init(data: Data) throws {
        let body = try NativeRPCValue.parseJSON(data, decodeBytes: true)
        channel = try body["channel"].requireString("channel", nonempty: true)
        arguments = try body["args"].requireArray("args")
    }
}
