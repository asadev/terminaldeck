import Foundation
import TerminalDeckNativeCore

enum BackendMcpClientJSONSchemaDialect: Equatable, Sendable {
    case draft07, draft2020
    static func selected(_ schema: NativeRPCValue, inherited: Self) -> Self {
        guard let uri = BackendMcpClientJSONSchemaCore.member(schema, "$schema").string else { return inherited }
        return uri.contains("2020-12") || uri.contains("2019-09") ? .draft2020 : .draft07
    }
}

/// Indexes only schema-bearing positions as URI resources/anchors. JSON Pointer
/// lookup can still address any document position, as Ajv's local refs can.
struct BackendMcpClientJSONSchemaReferences {
    struct Location: Sendable {
        let path: String; let baseID: String; let resourceRoot: String; let dialect: BackendMcpClientJSONSchemaDialect
    }
    let document: NativeRPCValue
    private var locations: [String: Location] = [:]
    private var resources: [String: String] = [:]
    private var anchors: [String: String] = [:]
    static func key(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
    static func escape(_ part: String) -> String { part.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    static func child(_ path: String, _ key: String) -> String { path + "/" + escape(key) }
    static func normalize(_ uri: String) -> String { uri.hasSuffix("#") ? String(uri.dropLast()) : uri }
    static func resolveURI(_ ref: String, base: String) -> String {
        if ref.hasPrefix("#") { return String(base.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]) + ref }
        if base.isEmpty { return ref }
        guard let baseURL = URL(string: base), let resolved = URL(string: ref, relativeTo: baseURL) else { return ref }
        return resolved.absoluteURL.absoluteString
    }
    init(_ document: NativeRPCValue) throws {
        self.document = document
        resources[Self.key("")] = ""
        try index(document, path: "", base: "", resource: "", dialect: .draft07, depth: 0)
    }
    private mutating func index(_ schema: NativeRPCValue, path: String, base: String, resource: String, dialect: BackendMcpClientJSONSchemaDialect, depth: Int) throws {
        guard depth <= 512 else { throw NativeRPCError(code: "json-schema-limit", message: "JSON Schema nesting exceeds 512 levels.") }
        var baseID = base, resourceRoot = resource
        if let id = BackendMcpClientJSONSchemaCore.member(schema, "$id").string {
            let resolved = Self.normalize(Self.resolveURI(id, base: base)), parts = resolved.components(separatedBy: "#")
            if parts.count > 1, !parts[1].isEmpty {
                try addAnchor(resolved, path: path)
                baseID = parts[0]
            } else {
                baseID = resolved; resourceRoot = path
                let key = Self.key(resolved)
                if let old = resources[key], old != path, !resolved.isEmpty { throw NativeRPCError(code: "json-schema-compile", message: "reference \"\(resolved)\" resolves to more than one schema") }
                resources[key] = path
            }
        }
        let selected = BackendMcpClientJSONSchemaDialect.selected(schema, inherited: dialect)
        locations[Self.key(path)] = .init(path: path, baseID: baseID, resourceRoot: resourceRoot, dialect: selected)
        for keyword in selected == .draft2020 ? ["$anchor", "$dynamicAnchor"] : [] {
            if let anchor = BackendMcpClientJSONSchemaCore.member(schema, keyword).string { try addAnchor(baseID + "#" + anchor, path: path) }
        }
        for keyword in ["$defs", "definitions", "properties", "patternProperties"] + (selected == .draft2020 ? ["dependentSchemas"] : []) {
            for field in BackendMcpClientJSONSchemaCore.fields(BackendMcpClientJSONSchemaCore.member(schema, keyword)) {
                try index(field.value, path: Self.child(Self.child(path, keyword), field.key), base: baseID, resource: resourceRoot, dialect: selected, depth: depth + 1)
            }
        }
        for field in BackendMcpClientJSONSchemaCore.fields(BackendMcpClientJSONSchemaCore.member(schema, "dependencies")) where field.value.elements == nil {
            try index(field.value, path: Self.child(Self.child(path, "dependencies"), field.key), base: baseID, resource: resourceRoot, dialect: selected, depth: depth + 1)
        }
        for keyword in ["allOf", "anyOf", "oneOf"] + (selected == .draft2020 ? ["prefixItems"] : []) {
            for (i, child) in (BackendMcpClientJSONSchemaCore.member(schema, keyword).elements ?? []).enumerated() {
                try index(child, path: Self.child(Self.child(path, keyword), String(i)), base: baseID, resource: resourceRoot, dialect: selected, depth: depth + 1)
            }
        }
        let conditional = BackendMcpClientJSONSchemaCore.member(schema, "if") != .missing && ["then", "else"].contains { keyword in
            let branch = BackendMcpClientJSONSchemaCore.member(schema, keyword)
            return branch != .missing && !BackendMcpClientJSONSchemaCompiler.alwaysValid(branch, dialect: selected)
        }
        let rest = selected == .draft07 && BackendMcpClientJSONSchemaCore.member(schema, "items").elements != nil ? ["additionalItems"] : []
        for keyword in ["not", "contains", "propertyNames", "additionalProperties", "items"] + (conditional ? ["if", "then", "else"] : []) + (selected == .draft2020 ? ["unevaluatedProperties", "unevaluatedItems"] : rest) {
            let child = BackendMcpClientJSONSchemaCore.member(schema, keyword)
            if child == .missing { continue }
            if keyword == "items", let tuple = child.elements {
                for (i, sub) in tuple.enumerated() { try index(sub, path: Self.child(Self.child(path, keyword), String(i)), base: baseID, resource: resourceRoot, dialect: selected, depth: depth + 1) }
            } else { try index(child, path: Self.child(path, keyword), base: baseID, resource: resourceRoot, dialect: selected, depth: depth + 1) }
        }
    }
    private mutating func addAnchor(_ uri: String, path: String) throws {
        let key = Self.key(uri)
        if let old = anchors[key], old != path { throw NativeRPCError(code: "json-schema-compile", message: "reference \"\(uri)\" resolves to more than one schema") }
        anchors[key] = path
    }
    func location(_ path: String) -> Location {
        if let held = locations[Self.key(path)] { return held }
        var parent = path
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if let found = locations[Self.key(parent)] { return .init(path: path, baseID: found.baseID, resourceRoot: found.resourceRoot, dialect: found.dialect) }
        }
        return .init(path: path, baseID: "", resourceRoot: "", dialect: .draft07)
    }
    func schema(_ path: String) -> NativeRPCValue {
        var value = document
        for token in Self.tokens(path) ?? [] {
            if let array = value.elements, let i = Int(token), i >= 0, i < array.count, String(i) == token { value = array[i] }
            else { value = BackendMcpClientJSONSchemaCore.member(value, token) }
        }
        return value
    }
    func resolve(_ reference: String, from location: Location) throws -> Location {
        let uri = Self.normalize(Self.resolveURI(reference, base: location.baseID))
        if let path = anchors[Self.key(uri)] { return self.location(path) }
        let parts = uri.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false), base = String(parts[0])
        guard let root = resources[Self.key(base)] else { throw missing(reference, location) }
        if parts.count == 1 || parts[1].isEmpty { return self.location(root) }
        guard let fragment = String(parts[1]).removingPercentEncoding, fragment.hasPrefix("/"), Self.tokens(fragment) != nil else { throw missing(reference, location) }
        let path = root + fragment
        let value = schema(path)
        guard value.fields != nil || value.bool != nil else { throw missing(reference, location) }
        return self.location(path)
    }
    private func missing(_ reference: String, _ location: Location) -> NativeRPCError {
        .init(code: "json-schema-reference", message: "can't resolve reference \(reference) from id \(location.baseID)")
    }
    static func tokens(_ pointer: String) -> [String]? {
        if pointer.isEmpty { return [] }; guard pointer.hasPrefix("/") else { return nil }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).reduce(into: Optional<[String]>([])) { result, raw in
            guard result != nil else { return }; let token = String(raw)
            if token.range(of: #"~(?![01])"#, options: .regularExpression) != nil { result = nil; return }
            result?.append(token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~"))
        }
    }
}
