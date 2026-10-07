import Foundation
import TerminalDeckNativeCore

/// Evaluation is local to one call. Branches return independent failures and
/// annotations; no rejected anyOf/oneOf/not/if branch leaks its errors or marks
/// properties as evaluated in a successful sibling branch.
struct BackendMcpClientJSONSchemaCore {
    struct Result {
        var errors: [String] = []
        var properties = Set<String>() // Base64 UTF-8 keys, preserving exact spelling.
        var items = Set<Int>()
        var valid: Bool { errors.isEmpty }
        mutating func merge(_ other: Self, errors: Bool = true, annotations: Bool = true) {
            if errors { self.errors += other.errors }
            if annotations { properties.formUnion(other.properties); items.formUnion(other.items) }
        }
        mutating func fail(_ path: String, _ message: String) { errors.append("data" + path + " " + message) }
    }
    private struct Frame: Hashable { let node: Int; let path: String; let kind: String }
    let graph: BackendMcpClientJSONSchemaGraph
    private var active = Set<Frame>()
    private var steps = 0
    init(graph: BackendMcpClientJSONSchemaGraph) { self.graph = graph }

    /// Bound direct Swift fixtures as well as already-bounded wire input before
    /// any structural equality recursion. Undefined object fields are omitted
    /// just as JSON.stringify omits them; no cyclic native object can enter.
    static func requireJSON(_ value: NativeRPCValue) throws {
        var work: [(NativeRPCValue, Int)] = [(value, 0)], visited = 0
        while let (value, depth) = work.popLast() {
            visited += 1
            guard depth <= 512, visited <= 1_000_000 else { throw NativeRPCError(code: "json-schema-limit", message: "JSON Schema input exceeds the supported nesting or value limit.") }
            if visited % 128 == 0 { try Task.checkCancellation() }
            switch value {
            case .array(let children): work += children.map { ($0, depth + 1) }
            case .object(let children): work += children.filter { $0.value != .missing }.map { ($0.value, depth + 1) }
            case .number(let number) where !number.isFinite: throw NativeRPCError(code: "json-schema-value", message: "JSON Schema validation requires finite JSON numbers.")
            case .bytes, .missing: throw NativeRPCError(code: "json-schema-value", message: "JSON Schema validation requires JSON values.")
            default: break
            }
        }
    }

    static func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
    static func member(_ value: NativeRPCValue, _ key: String) -> NativeRPCValue {
        value.fields?.last(where: { exact($0.key, key) })?.value ?? .missing
    }
    /// JavaScript enumeration puts integer-index names first. Duplicate object
    /// keys retain the last value in their original insertion position.
    static func fields(_ value: NativeRPCValue) -> [NativeRPCValue.Field] {
        var fields: [NativeRPCValue.Field] = []
        for field in value.fields ?? [] where field.value != .missing {
            if let i = fields.firstIndex(where: { exact($0.key, field.key) }) { fields[i] = field } else { fields.append(field) }
        }
        func index(_ key: String) -> UInt64? {
            guard let number = UInt64(key), number < 4_294_967_295, String(number) == key else { return nil }; return number
        }
        let indexed = fields.compactMap { field -> (UInt64, NativeRPCValue.Field)? in index(field.key).map { ($0, field) } }.sorted { $0.0 < $1.0 }.map(\.1)
        return indexed + fields.filter { index($0.key) == nil }
    }
    static func isType(_ type: String, _ value: NativeRPCValue) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("object", .object), ("array", .array), ("string", .string): return true
        case ("number", .number(let n)): return n.isFinite
        case ("integer", .number(let n)): return n.isFinite && n.rounded(.towardZero) == n
        default: return false
        }
    }
    static func numberText(_ n: Double) -> String {
        if n == 0 { return "0" }; if !n.isFinite { return String(n) }
        // Reuse the existing JS-number foundation. JSON Schema diagnostics and
        // Ajv's parseInt also need JS's decimal rendering in [1e-6, 1e21).
        let raw = OrderedJSON.jsNumber(n).lowercased()
        guard let e = raw.firstIndex(of: "e"), let exponent = Int(raw[raw.index(after: e)...]) else { return raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw }
        var mantissa = String(raw[..<e]); let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        if mantissa.hasSuffix(".0") { mantissa = String(mantissa.dropLast(2)) }
        if exponent >= -6 && exponent < 21 {
            let pieces = mantissa.components(separatedBy: "."), digits = pieces.joined(), point = pieces[0].count + exponent
            let value: String
            if point <= 0 { value = "0." + String(repeating: "0", count: -point) + digits }
            else if point >= digits.count { value = digits + String(repeating: "0", count: point - digits.count) }
            else { let split = digits.index(digits.startIndex, offsetBy: point); value = String(digits[..<split]) + "." + String(digits[split...]) }
            return (negative ? "-" : "") + value
        }
        return (negative ? "-" : "") + mantissa + "e" + (exponent < 0 ? "" : "+") + String(exponent)
    }
    static func jsString(_ value: NativeRPCValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return numberText(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .missing: return "undefined"
        case .array(let a): return a.map { $0.isNullish ? "" : jsString($0) }.joined(separator: ",")
        default: return "[object Object]"
        }
    }
    static func equal(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        switch (a, b) {
        case (.null, .null), (.missing, .missing): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return exact(x, y)
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object, .object):
            let left = fields(a), right = fields(b)
            return left.count == right.count && left.allSatisfy { field in right.contains { exact(field.key, $0.key) && equal(field.value, $0.value) } }
        default: return false
        }
    }

    mutating func evaluate(_ id: Int, value: NativeRPCValue, path: String, depth: Int = 0, dynamic: [String: Int] = [:]) throws -> Result {
        steps += 1
        guard depth <= 512, steps <= 200_000 else { throw NativeRPCError(code: "json-schema-limit", message: "JSON Schema evaluation exceeds the supported nesting or work limit.") }
        if steps % 128 == 0 { try Task.checkCancellation() }
        // propertyNames validates a string at its parent's diagnostic path. A
        // local ref may legitimately revisit a schema there with that new type.
        let kind: String
        switch value {
        case .object: kind = "object"
        case .array: kind = "array"
        case .string: kind = "string"
        case .number: kind = "number"
        case .bool: kind = "boolean"
        case .null: kind = "null"
        default: kind = "other"
        }
        let frame = Frame(node: id, path: BackendMcpClientJSONSchemaReferences.key(path), kind: kind)
        guard active.insert(frame).inserted else { throw NativeRPCError(code: "json-schema-recursion", message: "JSON Schema reference cycle does not advance the instance at \(path.isEmpty ? "data" : "data" + path).") }
        defer { active.remove(frame) }
        let node = graph.nodes[id], schema = node.schema
        var result = Result(), scope = dynamic
        if let boolean = schema.bool { if !boolean { result.fail(path, "boolean schema is false") }; return result }
        func kw(_ name: String) -> NativeRPCValue { Self.member(schema, name) }
        if let anchor = kw("$dynamicAnchor").string {
            let key = BackendMcpClientJSONSchemaReferences.key(anchor); if scope[key] == nil { scope[key] = id }
        }
        if kw("$recursiveAnchor").bool == true && scope["$recursive"] == nil { scope["$recursive"] = id }
        var types = kw("type").elements?.compactMap(\.string) ?? kw("type").string.map { [$0] } ?? []
        if kw("nullable").bool == true && !types.contains("null") { types.append("null") }
        let wrongType = !types.isEmpty && !types.contains { Self.isType($0, value) }
        let deferredType = types.count == 1 && hasTypedRules(schema, type: types[0], dialect: node.location.dialect)
        let typeMessage = "must be " + Self.jsString(kw("type"))
        if wrongType && !deferredType { result.fail(path, typeMessage) }
        if let target = node.reference { result.merge(try evaluate(target, value: value, path: path, depth: depth + 1, dynamic: scope)) }
        if let fallback = node.dynamicReference {
            let anchor = Self.member(graph.nodes[fallback].schema, "$dynamicAnchor").string
            let target = anchor.flatMap { scope[BackendMcpClientJSONSchemaReferences.key($0)] } ?? fallback
            result.merge(try evaluate(target, value: value, path: path, depth: depth + 1, dynamic: scope))
        }
        if let fallback = node.recursiveReference { result.merge(try evaluate(scope["$recursive"] ?? fallback, value: value, path: path, depth: depth + 1, dynamic: scope)) }
        if kw("const") != .missing && !Self.equal(value, kw("const")) { result.fail(path, "must be equal to constant") }
        if let allowed = kw("enum").elements, !allowed.contains(where: { Self.equal(value, $0) }) { result.fail(path, "must be equal to one of the allowed values") }
        if let child = node.child("not") {
            if try evaluate(child, value: value, path: path, depth: depth + 1, dynamic: scope).valid { result.fail(path, "must NOT be valid") }
        }
        for keyword in ["anyOf", "oneOf"] {
            if let branches = kw(keyword).elements {
                if keyword == "anyOf", node.location.dialect == .draft07, branches.contains(where: { BackendMcpClientJSONSchemaCompiler.alwaysValid($0, dialect: .draft07) }) { continue }
                var failed: [String] = [], successes: [Result] = []
                for (index, _) in branches.enumerated() {
                    let branch = try evaluate(node.child(keyword, String(index))!, value: value, path: path, depth: depth + 1, dynamic: scope)
                    if branch.valid { successes.append(branch) } else { failed += branch.errors }
                    if keyword == "oneOf" && successes.count == 2 { break }
                }
                if keyword == "anyOf" ? !successes.isEmpty : successes.count == 1 {
                    for branch in successes { result.merge(branch, errors: false) }
                } else {
                    result.errors += failed; result.fail(path, keyword == "anyOf" ? "must match a schema in anyOf" : "must match exactly one schema in oneOf")
                }
            }
        }
        for (index, _) in (kw("allOf").elements ?? []).enumerated() {
            result.merge(try evaluate(node.child("allOf", String(index))!, value: value, path: path, depth: depth + 1, dynamic: scope))
        }
        if let condition = node.child("if"), node.child("then") != nil || node.child("else") != nil {
            let checked = try evaluate(condition, value: value, path: path, depth: depth + 1, dynamic: scope)
            result.merge(checked, errors: false)
            let keyword = checked.valid ? "then" : "else"
            if let branch = node.child(keyword) {
                let branchResult = try evaluate(branch, value: value, path: path, depth: depth + 1, dynamic: scope)
                result.merge(branchResult, annotations: branchResult.valid)
                if !branchResult.valid { result.fail(path, "must match \"\(keyword)\" schema") }
            }
        }
        if let number = value.number {
            for (key, comparison) in [("maximum", "<="), ("minimum", ">="), ("exclusiveMaximum", "<"), ("exclusiveMinimum", ">")] {
                guard let bound = kw(key).number else { continue }
                let valid = key == "maximum" ? number <= bound : key == "minimum" ? number >= bound : key == "exclusiveMaximum" ? number < bound : number > bound
                if !valid { result.fail(path, "must be \(comparison) \(Self.numberText(bound))") }
            }
            if let divisor = kw("multipleOf").number {
                let quotient = number / divisor, text = Self.numberText(quotient)
                var prefix = ""; for ch in text { if ch.isASCII && ch.isNumber || prefix.isEmpty && (ch == "-" || ch == "+") { prefix.append(ch) } else { break } }
                if divisor == 0 || !quotient.isFinite || Double(prefix) != quotient { result.fail(path, "must be multiple of \(Self.numberText(divisor))") }
            }
            try format(schema, value: value, path: path, result: &result)
        } else if wrongType && deferredType && types[0] == "number" { result.fail(path, typeMessage) }
        if let text = value.string {
            let length = Double(text.unicodeScalars.count)
            for (key, word) in [("maxLength", "more"), ("minLength", "fewer")] {
                if let bound = kw(key).number, key == "maxLength" ? length > bound : length < bound { result.fail(path, "must NOT have \(word) than \(Self.numberText(bound)) characters") }
            }
            if let pattern = kw("pattern").string, try !BackendMcpClientJSONSchemaPattern.matches(pattern, value: text) { result.fail(path, "must match pattern \"\(pattern)\"") }
            try format(schema, value: value, path: path, result: &result)
        } else if wrongType && deferredType && types[0] == "string" { result.fail(path, typeMessage) }
        if let items = value.elements { try array(node, items: items, path: path, depth: depth, dynamic: scope, result: &result) }
        else if wrongType && deferredType && types[0] == "array" { result.fail(path, typeMessage) }
        if value.fields != nil { try object(node, value: value, path: path, depth: depth, dynamic: scope, result: &result) }
        else if wrongType && deferredType && types[0] == "object" { result.fail(path, typeMessage) }
        if node.location.dialect == .draft2020 { try unevaluated(node, value: value, path: path, depth: depth, dynamic: scope, result: &result) }
        return result
    }

    private func hasTypedRules(_ schema: NativeRPCValue, type: String, dialect: BackendMcpClientJSONSchemaDialect) -> Bool {
        let keywords: [String]
        switch type {
        case "number": keywords = ["maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum", "multipleOf", "format"]
        case "string": keywords = ["maxLength", "minLength", "pattern", "format"]
        case "array": keywords = ["maxItems", "minItems", "items", "additionalItems", "contains", "uniqueItems"] + (dialect == .draft2020 ? ["prefixItems", "unevaluatedItems"] : [])
        case "object": keywords = ["maxProperties", "minProperties", "required", "propertyNames", "properties", "patternProperties", "additionalProperties", "dependencies"] + (dialect == .draft2020 ? ["dependentRequired", "dependentSchemas", "unevaluatedProperties"] : [])
        default: return false
        }
        return keywords.contains { Self.member(schema, $0) != .missing }
    }
    private func format(_ schema: NativeRPCValue, value: NativeRPCValue, path: String, result: inout Result) throws {
        if let format = Self.member(schema, "format").string, try BackendMcpClientJSONSchemaFormats.check(format, value: value) == false { result.fail(path, "must match format \"\(format)\"") }
    }

    private mutating func array(_ node: BackendMcpClientJSONSchemaGraph.Node, items: [NativeRPCValue], path: String, depth: Int, dynamic: [String: Int], result: inout Result) throws {
        let schema = node.schema, count = Double(items.count)
        for (key, word) in [("maxItems", "more"), ("minItems", "fewer")] {
            if let bound = Self.member(schema, key).number, key == "maxItems" ? count > bound : count < bound { result.fail(path, "must NOT have \(word) than \(Self.numberText(bound)) items") }
        }
        let tupleKey = node.location.dialect == .draft07 ? "items" : "prefixItems", tuple = Self.member(schema, tupleKey).elements
        let restKey = node.location.dialect == .draft07 ? "additionalItems" : "items"
        // Ajv registers additionalItems before tuple items, then contains, all
        // before uniqueItems. 2020 registers prefixItems before its rest items.
        if node.location.dialect == .draft07, let tuple, let rest = node.child(restKey) {
            try restItems(rest, from: tuple.count, items: items, path: path, depth: depth, dynamic: dynamic, result: &result)
        }
        if let tuple {
            for i in 0..<min(tuple.count, items.count) {
                result.items.insert(i)
                let checked = try evaluate(node.child(tupleKey, String(i))!, value: items[i], path: path + "/" + String(i), depth: depth + 1, dynamic: dynamic)
                result.merge(checked, annotations: false)
            }
        }
        if node.location.dialect == .draft2020, let rest = node.child("items") {
            try restItems(rest, from: tuple?.count ?? 0, items: items, path: path, depth: depth, dynamic: dynamic, result: &result)
        } else if node.location.dialect == .draft07, tuple == nil, let item = node.child("items") {
            for (i, value) in items.enumerated() { result.items.insert(i); result.merge(try evaluate(item, value: value, path: path + "/" + String(i), depth: depth + 1, dynamic: dynamic), annotations: false) }
        }
        if let contains = node.child("contains") {
            let minimum = node.location.dialect == .draft2020 ? Self.member(schema, "minContains").number ?? 1 : 1
            let maximum = node.location.dialect == .draft2020 ? Self.member(schema, "maxContains").number : nil
            if minimum != 0 || maximum != nil {
                let always = BackendMcpClientJSONSchemaCompiler.alwaysValid(graph.nodes[contains].schema, dialect: node.location.dialect)
                if always {
                    if count < minimum || maximum.map({ count > $0 }) == true {
                        result.fail(path, maximum.map { "must contain at least \(Self.numberText(minimum)) and no more than \(Self.numberText($0)) valid item(s)" } ?? "must contain at least \(Self.numberText(minimum)) valid item(s)")
                    }
                } else if let maximum, minimum > maximum {
                    result.fail(path, "must contain at least \(Self.numberText(minimum)) and no more than \(Self.numberText(maximum)) valid item(s)")
                } else {
                // Ajv marks the whole array evaluated for nontrivial contains,
                // even in its 2020 vocabulary. Preserve that sourced behavior.
                result.items.formUnion(items.indices)
                var matches = Set<Int>(), failures: [String] = []
                for (i, value) in items.enumerated() {
                    let checked = try evaluate(contains, value: value, path: path + "/" + String(i), depth: depth + 1, dynamic: dynamic)
                    if checked.valid { matches.insert(i) } else { failures += checked.errors }
                    if let maximum, Double(matches.count) > maximum { break }
                    if maximum == nil && Double(matches.count) >= minimum { break }
                }
                if Double(matches.count) >= minimum && maximum.map({ Double(matches.count) <= $0 }) != false { result.items.formUnion(matches) }
                else {
                    result.errors += failures
                    result.fail(path, maximum.map { "must contain at least \(Self.numberText(minimum)) and no more than \(Self.numberText($0)) valid item(s)" } ?? "must contain at least \(Self.numberText(minimum)) valid item(s)")
                }
                }
            }
        }
        if Self.member(schema, "uniqueItems").bool == true, items.count > 1 {
            let itemSchema = Self.member(schema, "items"), types = Self.member(itemSchema, "type").elements?.compactMap(\.string) ?? Self.member(itemSchema, "type").string.map { [$0] } ?? []
            let optimized = !types.isEmpty && !types.contains("object") && !types.contains("array")
            var duplicate: (Int, Int)?
            if optimized {
                var later: [Int] = []
                for i in items.indices.reversed() {
                    if !types.contains(where: { Self.isType($0, items[i]) }) { continue }
                    if let j = later.first(where: { Self.equal(items[i], items[$0]) }) { duplicate = (j, i); break }; later.append(i)
                }
            } else {
                outer: for i in items.indices.reversed() where i > 0 {
                    for j in stride(from: i - 1, through: 0, by: -1) where Self.equal(items[i], items[j]) { duplicate = (j, i); break outer }
                }
            }
            if let duplicate { result.fail(path, "must NOT have duplicate items (items ## \(duplicate.0) and \(duplicate.1) are identical)") }
        }
    }
    private mutating func restItems(_ child: Int, from: Int, items: [NativeRPCValue], path: String, depth: Int, dynamic: [String: Int], result: inout Result) throws {
        if graph.nodes[child].schema.bool == false {
            if items.count > from { result.fail(path, "must NOT have more than \(from) items") }
            result.items.formUnion(items.indices); return
        }
        for i in items.indices where i >= from {
            result.items.insert(i); result.merge(try evaluate(child, value: items[i], path: path + "/" + String(i), depth: depth + 1, dynamic: dynamic), annotations: false)
        }
    }

    private mutating func object(_ node: BackendMcpClientJSONSchemaGraph.Node, value: NativeRPCValue, path: String, depth: Int, dynamic: [String: Int], result: inout Result) throws {
        let schema = node.schema, instance = Self.fields(value), properties = Self.fields(Self.member(schema, "properties")), patterns = Self.fields(Self.member(schema, "patternProperties"))
        for (key, word) in [("maxProperties", "more"), ("minProperties", "fewer")] {
            if let bound = Self.member(schema, key).number, key == "maxProperties" ? Double(instance.count) > bound : Double(instance.count) < bound { result.fail(path, "must NOT have \(word) than \(Self.numberText(bound)) properties") }
        }
        for raw in Self.member(schema, "required").elements ?? [] {
            let key = Self.jsString(raw)
            if Self.member(value, key) == .missing { result.fail(path, "must have required property '\(key)'") }
        }
        if let names = node.child("propertyNames") {
            for field in instance {
                let checked = try evaluate(names, value: .string(field.key), path: path, depth: depth + 1, dynamic: dynamic)
                result.merge(checked, annotations: false)
                if !checked.valid { result.fail(path, "property name must be valid") }
            }
        }
        if let additional = node.child("additionalProperties") {
            for field in instance {
                let declared = properties.contains { Self.exact($0.key, field.key) }
                var matched = false
                for pattern in patterns where try BackendMcpClientJSONSchemaPattern.matches(pattern.key, value: field.key) { matched = true; break }
                if declared || matched { continue }
                result.properties.insert(BackendMcpClientJSONSchemaReferences.key(field.key))
                if graph.nodes[additional].schema.bool == false { result.fail(path, "must NOT have additional properties") }
                else { result.merge(try evaluate(additional, value: field.value, path: BackendMcpClientJSONSchemaReferences.child(path, field.key), depth: depth + 1, dynamic: dynamic), annotations: false) }
            }
        }
        let dependencies = Self.fields(Self.member(schema, "dependencies"))
        try propertyDependencies(dependencies.filter { $0.value.elements != nil }, value: value, path: path, result: &result)
        for dependency in dependencies where dependency.value.elements == nil && Self.member(value, dependency.key) != .missing {
            let checked = try evaluate(node.child("dependencies", dependency.key)!, value: value, path: path, depth: depth + 1, dynamic: dynamic)
            result.merge(checked, annotations: checked.valid)
        }
        if node.location.dialect == .draft2020 {
            try propertyDependencies(Self.fields(Self.member(schema, "dependentRequired")), value: value, path: path, result: &result)
            for field in Self.fields(Self.member(schema, "dependentSchemas")) where Self.member(value, field.key) != .missing {
                let checked = try evaluate(node.child("dependentSchemas", field.key)!, value: value, path: path, depth: depth + 1, dynamic: dynamic)
                result.merge(checked, annotations: checked.valid)
            }
        }
        for property in properties {
            let existing = Self.member(value, property.key); if existing == .missing { continue }
            result.properties.insert(BackendMcpClientJSONSchemaReferences.key(property.key))
            result.merge(try evaluate(node.child("properties", property.key)!, value: existing, path: BackendMcpClientJSONSchemaReferences.child(path, property.key), depth: depth + 1, dynamic: dynamic), annotations: false)
        }
        for pattern in patterns {
            for field in instance where try BackendMcpClientJSONSchemaPattern.matches(pattern.key, value: field.key) {
                result.properties.insert(BackendMcpClientJSONSchemaReferences.key(field.key))
                result.merge(try evaluate(node.child("patternProperties", pattern.key)!, value: field.value, path: BackendMcpClientJSONSchemaReferences.child(path, field.key), depth: depth + 1, dynamic: dynamic), annotations: false)
            }
        }
    }
    private func propertyDependencies(_ dependencies: [NativeRPCValue.Field], value: NativeRPCValue, path: String, result: inout Result) throws {
        for field in dependencies where Self.member(value, field.key) != .missing {
            let dependencies = (field.value.elements ?? []).map(Self.jsString)
            for key in dependencies where Self.member(value, key) == .missing {
                result.fail(path, "must have \(dependencies.count == 1 ? "property" : "properties") \(dependencies.joined(separator: ", ")) when property \(field.key) is present")
            }
        }
    }
    private mutating func unevaluated(_ node: BackendMcpClientJSONSchemaGraph.Node, value: NativeRPCValue, path: String, depth: Int, dynamic: [String: Int], result: inout Result) throws {
        if let child = node.child("unevaluatedProperties"), value.fields != nil {
            for field in Self.fields(value) where !result.properties.contains(BackendMcpClientJSONSchemaReferences.key(field.key)) {
                if graph.nodes[child].schema.bool == false { result.fail(path, "must NOT have unevaluated properties") }
                else { result.merge(try evaluate(child, value: field.value, path: BackendMcpClientJSONSchemaReferences.child(path, field.key), depth: depth + 1, dynamic: dynamic), annotations: false) }
                result.properties.insert(BackendMcpClientJSONSchemaReferences.key(field.key))
            }
        }
        if let child = node.child("unevaluatedItems"), let items = value.elements {
            let remaining = items.indices.filter { !result.items.contains($0) }
            if graph.nodes[child].schema.bool == false, let first = remaining.first { result.fail(path, "must NOT have more than \(first) items") }
            else { for i in remaining { result.merge(try evaluate(child, value: items[i], path: path + "/" + String(i), depth: depth + 1, dynamic: dynamic), annotations: false) } }
            result.items.formUnion(items.indices)
        }
    }
}
