import Foundation
import TerminalDeckNativeCore

/// Exact missing dependency from the JS client's Ajv validator. A supplier must
/// implement arbitrary JSON Schema output validation, including references,
/// rather than silently accept a schema it does not understand.
public protocol BackendMcpClientOutputValidating: Sendable {
    /// Nil means valid. Otherwise return the validator's diagnostic to preserve
    /// the SDK's "Structured content does not match ..." error shape.
    func validate(schema: NativeRPCValue, value: NativeRPCValue) async throws -> String?
}

enum BackendMcpClientValidation {
    static func invalid(_ label: String) -> NativeRPCError { BackendMcpClientValue.error("Invalid MCP \(label).") }
    static func optionalString(_ value: NativeRPCValue) -> Bool { value == .missing || value.string != nil }
    static func listing(_ row: NativeRPCValue, section: String) throws {
        guard row.fields != nil, row["name"].string != nil, optionalString(row["title"]), optionalString(row["description"]) else { throw invalid(section + " listing") }
        if section == "tools" {
            try schema(row["inputSchema"])
            if row["outputSchema"] != .missing { try schema(row["outputSchema"]) }
        } else if section == "resources" || section == "resourceTemplates" {
            guard row[section == "resources" ? "uri" : "uriTemplate"].string != nil, optionalString(row["mimeType"]) else { throw invalid(section + " listing") }
        } else if section == "prompts", row["arguments"] != .missing {
            guard let arguments = row["arguments"].elements else { throw invalid("prompts listing") }
            for argument in arguments {
                guard argument.fields != nil, argument["name"].string != nil, optionalString(argument["description"]), argument["required"] == .missing || argument["required"].bool != nil else { throw invalid("prompts listing") }
            }
        }
    }
    private static func schema(_ value: NativeRPCValue) throws {
        guard value.fields != nil, value["type"].string == "object" else { throw invalid("tool schema") }
        if value["required"] != .missing {
            guard let keys = value["required"].elements, keys.allSatisfy({ $0.string != nil }) else { throw invalid("tool schema") }
        }
        if value["properties"] != .missing {
            guard let fields = value["properties"].fields, fields.allSatisfy({ $0.value.fields != nil }) else { throw invalid("tool schema") }
        }
    }
    static func result(_ raw: NativeRPCValue, method: String) throws -> NativeRPCValue {
        guard raw.fields != nil else { throw invalid("result") }
        var result = raw
        if method == "tools/call" {
            if result["content"] == .missing { result = result.setting("content", .array([])) }
            guard let blocks = result["content"].elements, result["isError"] == .missing || result["isError"].bool != nil,
                  result["structuredContent"] == .missing || result["structuredContent"].fields != nil else { throw invalid("tool result") }
            for block in blocks { try content(block) }
        } else if method == "resources/read" {
            guard let contents = result["contents"].elements else { throw invalid("resource result") }
            for entry in contents { try resource(entry) }
        } else if method == "prompts/get" {
            guard let messages = result["messages"].elements, optionalString(result["description"]) else { throw invalid("prompt result") }
            for message in messages {
                guard ["user", "assistant"].contains(message["role"].string ?? "") else { throw invalid("prompt message") }
                try content(message["content"])
            }
        }
        return result
    }
    private static func resource(_ value: NativeRPCValue) throws {
        guard value.fields != nil, value["uri"].string != nil, optionalString(value["mimeType"]), value["text"].string != nil || value["blob"].string != nil else { throw invalid("resource contents") }
    }
    private static func content(_ value: NativeRPCValue) throws {
        guard value.fields != nil, let type = value["type"].string else { throw invalid("content block") }
        switch type {
        case "text": guard value["text"].string != nil else { throw invalid("text content") }
        case "image", "audio": guard value["data"].string != nil, value["mimeType"].string != nil else { throw invalid(type + " content") }
        case "resource": try resource(value["resource"])
        case "resource_link": guard value["uri"].string != nil, value["name"].string != nil, optionalString(value["description"]), optionalString(value["mimeType"]) else { throw invalid("resource link") }
        default: throw invalid("content block")
        }
    }
}
