import Foundation
import TerminalDeckNativeCore

struct BackendMcpClientJSONSchemaGraph: Sendable {
    struct Node: Sendable {
        let schema: NativeRPCValue; let location: BackendMcpClientJSONSchemaReferences.Location
        var children: [String: Int] = [:]
        var reference: Int?, dynamicReference: Int?, recursiveReference: Int?
        func child(_ keyword: String, _ part: String? = nil) -> Int? {
            children[BackendMcpClientJSONSchemaReferences.key(part.map { keyword + "/" + BackendMcpClientJSONSchemaReferences.escape($0) } ?? keyword)]
        }
    }
    let root: Int; let nodes: [Node]
}

/// Compile preflight mirrors keyword value-type checks despite validateSchema:
/// false. It deliberately does not impose meta-schema-only constraints such as
/// nonnegative bounds, unique required names, or additional annotation rules.
enum BackendMcpClientJSONSchemaCompiler {
    static func compile(_ schema: NativeRPCValue) throws -> BackendMcpClientJSONSchemaGraph {
        guard schema.fields != nil || schema.bool != nil else { throw failure("schema must be object or boolean") }
        try BackendMcpClientJSONSchemaCore.requireJSON(schema)
        let references = try BackendMcpClientJSONSchemaReferences(schema)
        var builder = Builder(references: references)
        let root = try builder.add(references.location(""), depth: 0)
        return .init(root: root, nodes: builder.nodes)
    }
    static func failure(_ message: String) -> NativeRPCError { .init(code: "json-schema-compile", message: message) }
    static func alwaysValid(_ schema: NativeRPCValue, dialect: BackendMcpClientJSONSchemaDialect) -> Bool {
        if let boolean = schema.bool { return boolean }
        let known: Set<String> = ["$ref", "type", "nullable", "const", "enum", "not", "anyOf", "oneOf", "allOf", "if", "then", "else", "maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum", "multipleOf", "maxLength", "minLength", "pattern", "format", "maxItems", "minItems", "items", "additionalItems", "contains", "uniqueItems", "maxProperties", "minProperties", "required", "propertyNames", "properties", "patternProperties", "additionalProperties", "dependencies"]
        let modern: Set<String> = ["prefixItems", "dependentRequired", "dependentSchemas", "unevaluatedItems", "unevaluatedProperties", "$dynamicRef", "$recursiveRef"]
        return !BackendMcpClientJSONSchemaCore.fields(schema).contains { known.contains($0.key) || dialect == .draft2020 && modern.contains($0.key) }
    }
    private struct Builder {
        let references: BackendMcpClientJSONSchemaReferences
        var ids: [String: Int] = [:]
        var nodes: [BackendMcpClientJSONSchemaGraph.Node] = []
        private func failure(_ message: String) -> NativeRPCError { BackendMcpClientJSONSchemaCompiler.failure(message) }
        mutating func add(_ location: BackendMcpClientJSONSchemaReferences.Location, depth: Int) throws -> Int {
            let key = BackendMcpClientJSONSchemaReferences.key(location.path)
            if let id = ids[key] { return id }
            guard depth <= 512, nodes.count < 16_384 else { throw NativeRPCError(code: "json-schema-limit", message: "JSON Schema compilation exceeds the supported nesting or node limit.") }
            let schema = references.schema(location.path)
            guard schema.fields != nil || schema.bool != nil else { throw failure("schema must be object or boolean") }
            let id = nodes.count; ids[key] = id; nodes.append(.init(schema: schema, location: location))
            if schema.bool != nil { return id }
            try check(schema, dialect: location.dialect)
            var children: [String: Int] = [:]
            func member(_ key: String) -> NativeRPCValue { BackendMcpClientJSONSchemaCore.member(schema, key) }
            let conditional = member("if") != .missing && ["then", "else"].contains { member($0) != .missing && !BackendMcpClientJSONSchemaCompiler.alwaysValid(member($0), dialect: location.dialect) }
            let rest = location.dialect == .draft07 && member("items").elements != nil ? ["additionalItems"] : []
            for keyword in ["not", "contains", "propertyNames", "additionalProperties"] + (conditional ? ["if", "then", "else"] : []) + (location.dialect == .draft2020 ? ["unevaluatedProperties", "unevaluatedItems"] : rest) {
                if member(keyword) != .missing {
                    let path = BackendMcpClientJSONSchemaReferences.child(location.path, keyword)
                    children[BackendMcpClientJSONSchemaReferences.key(keyword)] = try add(references.location(path), depth: depth + 1)
                }
            }
            for keyword in ["allOf", "anyOf", "oneOf"] + (location.dialect == .draft2020 ? ["prefixItems"] : []) {
                if keyword == "anyOf", location.dialect == .draft07, (member(keyword).elements ?? []).contains(where: { BackendMcpClientJSONSchemaCompiler.alwaysValid($0, dialect: .draft07) }) { continue }
                for (index, _) in (member(keyword).elements ?? []).enumerated() {
                    let part = String(index), path = BackendMcpClientJSONSchemaReferences.child(BackendMcpClientJSONSchemaReferences.child(location.path, keyword), part)
                    children[BackendMcpClientJSONSchemaReferences.key(keyword + "/" + part)] = try add(references.location(path), depth: depth + 1)
                }
            }
            for keyword in ["properties", "patternProperties"] + (location.dialect == .draft2020 ? ["dependentSchemas"] : []) {
                for field in BackendMcpClientJSONSchemaCore.fields(member(keyword)) {
                    let part = BackendMcpClientJSONSchemaReferences.escape(field.key), path = location.path + "/" + keyword + "/" + part
                    children[BackendMcpClientJSONSchemaReferences.key(keyword + "/" + part)] = try add(references.location(path), depth: depth + 1)
                }
            }
            for field in BackendMcpClientJSONSchemaCore.fields(member("dependencies")) where field.value.elements == nil {
                let part = BackendMcpClientJSONSchemaReferences.escape(field.key), path = location.path + "/dependencies/" + part
                children[BackendMcpClientJSONSchemaReferences.key("dependencies/" + part)] = try add(references.location(path), depth: depth + 1)
            }
            if let items = member("items").elements, location.dialect == .draft07 {
                for (index, _) in items.enumerated() {
                    let part = String(index), path = location.path + "/items/" + part
                    children[BackendMcpClientJSONSchemaReferences.key("items/" + part)] = try add(references.location(path), depth: depth + 1)
                }
            } else if member("items") != .missing { children[BackendMcpClientJSONSchemaReferences.key("items")] = try add(references.location(location.path + "/items"), depth: depth + 1) }
            nodes[id].children = children
            for keyword in ["$ref"] + (location.dialect == .draft2020 ? ["$dynamicRef", "$recursiveRef"] : []) {
                if let ref = member(keyword).string {
                    let target = try add(references.resolve(ref, from: location), depth: depth + 1)
                    if keyword == "$ref" { nodes[id].reference = target }
                    if keyword == "$dynamicRef" { nodes[id].dynamicReference = target }
                    if keyword == "$recursiveRef" { nodes[id].recursiveReference = target }
                }
            }
            return id
        }
        private func check(_ schema: NativeRPCValue, dialect: BackendMcpClientJSONSchemaDialect) throws {
            func value(_ key: String) -> NativeRPCValue { BackendMcpClientJSONSchemaCore.member(schema, key) }
            func expect(_ key: String, types: [String]) throws {
                let v = value(key); if v == .missing { return }
                let valid = types.contains { BackendMcpClientJSONSchemaCore.isType($0, v) }
                if !valid { throw failure("\(key) value must be [" + types.map { "\"" + $0 + "\"" }.joined(separator: ",") + "]") }
            }
            let type = value("type")
            let types = type.elements ?? (type == .missing || type == .null || type == .bool(false) || type == .number(0) || type == .string("") ? [] : [type])
            let allowed = Set(["null", "boolean", "object", "array", "number", "integer", "string"])
            if !types.allSatisfy({ $0.string.map { allowed.contains($0) } == true }) {
                throw failure("type must be JSONType or JSONType[]: " + types.map(BackendMcpClientJSONSchemaCore.jsString).joined(separator: ","))
            }
            if type != .missing { try expect("type", types: ["string", "array"]) }
            try expect("nullable", types: ["boolean"])
            if value("nullable") != .missing && types.isEmpty { throw failure("\"nullable\" cannot be used without \"type\"") }
            if types.contains(.string("null")) && value("nullable").bool == false { throw failure("type: null contradicts nullable: false") }
            if value("$id") != .missing && value("$id").string == nil { throw failure("schema $id must be string") }
            for keyword in ["$ref", "$schema"] + (dialect == .draft2020 ? ["$anchor"] : []) { try expect(keyword, types: ["string"]) }
            if value("$async").bool == true { throw failure("Async JSON Schema validation is unavailable.") }
            for keyword in ["maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum", "multipleOf", "maxLength", "minLength", "maxItems", "minItems", "maxProperties", "minProperties"] { try expect(keyword, types: ["number"]) }
            for keyword in ["pattern", "format"] { try expect(keyword, types: ["string"]) }
            if let pattern = value("pattern").string { try BackendMcpClientJSONSchemaPattern.validate(pattern) }
            for keyword in ["required", "enum", "allOf", "anyOf", "oneOf"] { try expect(keyword, types: ["array"]) }
            if value("enum").elements?.isEmpty == true { throw failure("enum must have non-empty array") }
            for keyword in ["properties", "patternProperties", "dependencies"] { try expect(keyword, types: ["object"]) }
            for field in BackendMcpClientJSONSchemaCore.fields(value("patternProperties")) { try BackendMcpClientJSONSchemaPattern.validate(field.key) }
            for keyword in ["uniqueItems"] { try expect(keyword, types: ["boolean"]) }
            for keyword in ["not", "if", "contains", "propertyNames", "additionalProperties"] { try expect(keyword, types: ["object", "boolean"]) }
            if value("if") != .missing { for keyword in ["then", "else"] { try expect(keyword, types: ["object", "boolean"]) } }
            if dialect == .draft07 { try expect("additionalItems", types: ["boolean", "object"]) }
            try expect("items", types: dialect == .draft07 ? ["object", "array", "boolean"] : ["object", "boolean"])
            if dialect == .draft2020 {
                for keyword in ["prefixItems"] { try expect(keyword, types: ["array"]) }
                for keyword in ["minContains", "maxContains"] { try expect(keyword, types: ["number"]) }
                for keyword in ["dependentRequired", "dependentSchemas"] { try expect(keyword, types: ["object"]) }
                for field in BackendMcpClientJSONSchemaCore.fields(value("dependentRequired")) {
                    guard field.value.elements != nil else { throw failure("dependentRequired value must be [\"object\"]") }
                }
                for keyword in ["unevaluatedProperties", "unevaluatedItems"] { try expect(keyword, types: ["boolean", "object"]) }
                for keyword in ["$dynamicRef", "$recursiveRef", "$dynamicAnchor"] { try expect(keyword, types: ["string"]) }
                try expect("$recursiveAnchor", types: ["boolean"])
            }
        }
    }
}
