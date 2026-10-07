import Foundation
import TerminalDeckNativeCore

/// Native, stateless JSON Schema validation for the MCP client's structured
/// output. Draft-07 is the default; a 2020-12 $schema selects its applicators.
/// Unknown extension keywords/formats follow Ajv's strict:false behavior.
/// Nothing is downloaded, executed or fetched to resolve a schema.
public struct BackendMcpClientJSONSchemaValidator: BackendMcpClientOutputValidating, Sendable {
    public init() {}

    /// The SDK compiles output schemas while listing tools. This is the native
    /// preflight hook for the integration owner; invalid schema/ref/regex errors
    /// throw before a tool with that schema can be offered for a call.
    public func prepare(schema: NativeRPCValue) throws {
        _ = try BackendMcpClientJSONSchemaCompiler.compile(schema)
    }

    /// Nil means valid; otherwise Ajv-style errorsText, with every failure in
    /// order and JSON Pointer instance paths. Compile/dependency failures throw.
    public func validate(schema: NativeRPCValue, value: NativeRPCValue) async throws -> String? {
        try Task.checkCancellation()
        try BackendMcpClientJSONSchemaCore.requireJSON(value)
        let graph = try BackendMcpClientJSONSchemaCompiler.compile(schema)
        var evaluation = BackendMcpClientJSONSchemaCore(graph: graph)
        let result = try evaluation.evaluate(graph.root, value: value, path: "")
        return result.errors.isEmpty ? nil : result.errors.joined(separator: ", ")
    }
}
