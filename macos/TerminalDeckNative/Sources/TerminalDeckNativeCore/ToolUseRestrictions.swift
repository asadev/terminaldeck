import Foundation

/// Additional limits on named Deck tools. Other tools retain their original
/// grants. Exact full objects deliberately refuse every extra argument.
public struct ToolUseRestrictions: Codable, Equatable, Sendable {
    public struct Rule: Equatable, Sendable {
        public let service: String
        public let tool: String
        public let cases: [NativeRPCValue]
    }
    public let raw: NativeRPCValue
    public let rules: [Rule]
    public init(_ raw: NativeRPCValue) throws {
        func keys(_ value: NativeRPCValue, _ allowed: Set<String>) throws {
            guard let fields = value.fields, fields.count == Set(fields.map(\.key)).count,
                  Set(fields.map(\.key)).isSubset(of: allowed) else { throw Self.invalid() }
        }
        guard (try raw.encodedJSON()).count <= 65536 else { throw Self.invalid() }
        try keys(raw, ["version", "tools"])
        guard raw["version"] == .number(1), let list = raw["tools"].elements, list.count <= 100 else { throw Self.invalid() }
        var rules: [Rule] = [], seen = Set<String>()
        for entry in list {
            try keys(entry, ["service", "tool", "cases"])
            if entry["tool"].string == "tools.run" {
                throw NativeRPCError(code: "tool-use-rules-invalid", message: "Choose the actual inner canonical tool, not tools.run. The wrapper is not a restriction target; invalid saved rules hold all Deck tool use.")
            }
            guard let tool = entry["tool"].string, tool.utf8.count <= 160,
                  tool.range(of: #"^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+$"#, options: .regularExpression) != nil,
                  let service = entry["service"].string, service == tool.split(separator: ".").dropLast().joined(separator: "."),
                  seen.insert(tool).inserted, let cases = entry["cases"].elements, cases.count <= 50 else { throw Self.invalid() }
            for item in cases {
                try keys(item, ["arguments", "action"])
                guard item["arguments"].fields != nil else { throw Self.invalid() }
                try Self.checkJSON(item["arguments"], depth: 0)
                if item.has("action") {
                    let action = item["action"]
                    try keys(action, ["path", "value"])
                    guard let path = action["path"].elements, !path.isEmpty, path.count <= 8,
                          path.allSatisfy({ $0.string.map { !$0.isEmpty && $0.utf8.count <= 80 && !$0.contains("\0") && $0 != "*" } == true }),
                          action.has("value"), action["value"].fields == nil, action["value"].elements == nil,
                          action["value"] != .missing else { throw Self.invalid() }
                    let selected = Self.at(item["arguments"], path: path.compactMap(\.string))
                    guard selected != .missing, Self.equal(selected, action["value"]) else { throw Self.invalid() }
                }
            }
            rules.append(.init(service: service, tool: tool, cases: cases))
        }
        self.raw = raw; self.rules = rules
    }
    public init(from decoder: any Decoder) throws { try self.init(ToolUseJSON(from: decoder).value) }
    public func encode(to encoder: any Encoder) throws { try ToolUseJSON(value: raw).encode(to: encoder) }
    public func permits(tool: String, arguments: NativeRPCValue) -> Bool {
        guard let rule = rules.first(where: { $0.tool == tool }) else { return true }
        return rule.cases.contains { Self.equal($0["arguments"], arguments) }
    }
    public static func require(_ raw: NativeRPCValue, tool: String, arguments: NativeRPCValue) throws {
        if raw.isNullish { return }
        guard try ToolUseRestrictions(raw).permits(tool: tool, arguments: arguments) else {
            throw NativeRPCError(code: "tool-use-restricted", message: "This agent's Deck tool rule does not allow these arguments.")
        }
    }
    public static func validateChange(_ next: NativeRPCValue, previous: NativeRPCValue) throws {
        if equal(next, previous) || next.isNullish { return }
        _ = try ToolUseRestrictions(next)
    }
    public static func isNarrowing(_ next: NativeRPCValue, previous: NativeRPCValue) -> Bool {
        if equal(next, previous) || next.isNullish && previous.isNullish { return true }
        guard !next.isNullish, let newer = try? ToolUseRestrictions(next) else { return false }
        if previous.isNullish { return true }
        guard let old = try? ToolUseRestrictions(previous) else { return false }
        return old.rules.allSatisfy { before in
            guard let after = newer.rules.first(where: { $0.tool == before.tool }) else { return false }
            return after.cases.allSatisfy { candidate in before.cases.contains { equal(candidate, $0) } }
        }
    }
    public static func problem(_ raw: NativeRPCValue?) -> String? {
        guard let raw, !raw.isNullish else { return nil }
        do { _ = try ToolUseRestrictions(raw); return nil } catch { return "Invalid Deck tool rules: all Deck tool use for this profile is held until the owner repairs them." }
    }
    public static func equal(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        if let left = a.fields {
            guard let right = b.fields, left.count == right.count, Set(left.map(\.key)).count == left.count, Set(right.map(\.key)).count == right.count else { return false }
            return left.allSatisfy { field in right.contains { $0.key == field.key && equal($0.value, field.value) } }
        }
        if let left = a.elements { guard let right = b.elements, left.count == right.count else { return false }; return zip(left, right).allSatisfy { equal($0, $1) } }
        return a == b
    }
    private static func at(_ value: NativeRPCValue, path: [String]) -> NativeRPCValue { path.reduce(value) { $0[$1] } }
    private static func checkJSON(_ value: NativeRPCValue, depth: Int) throws {
        guard depth <= 12, value != .missing else { throw invalid() }
        if let fields = value.fields {
            guard Set(fields.map(\.key)).count == fields.count else { throw invalid() }
            for field in fields { guard !field.key.contains("\0") else { throw invalid() }; try checkJSON(field.value, depth: depth + 1) }
        } else if let array = value.elements { for item in array { try checkJSON(item, depth: depth + 1) } }
        else if case .number(let number) = value, !number.isFinite { throw invalid() }
        else if case .bytes = value { throw invalid() }
    }
    private static func invalid() -> NativeRPCError { .init(code: "tool-use-rules-invalid", message: "Deck tool rules need version 1, exact canonical service/tool names and full argument-object cases. Invalid rules deny all Deck tool use.") }
}

private struct ToolUseJSON: Codable {
    let value: NativeRPCValue
    init(value: NativeRPCValue) { self.value = value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if try c.decodeNil() { value = .null }
        else if let v = try? c.decode(Bool.self) { value = .bool(v) }
        else if let v = try? c.decode(String.self) { value = .string(v) }
        else if let v = try? c.decode(Double.self) { value = .number(v) }
        else if let v = try? c.decode([ToolUseJSON].self) { value = .array(v.map(\.value)) }
        else { value = .object(try c.decode([String: ToolUseJSON].self).map { .init($0.key, $0.value.value) }) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v.map { ToolUseJSON(value: $0) })
        case .object(let v): try c.encode(Dictionary(uniqueKeysWithValues: v.map { ($0.key, ToolUseJSON(value: $0.value)) }))
        default: throw NativeRPCError.invalidArguments("Rules contain a non-JSON value.")
        }
    }
}
