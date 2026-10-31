import Foundation
import TerminalDeckNativeCore

/// MCP requests are conversation input, never tool permissions or automatic grants.
public enum BackendChatElicitation {
    public static func isRequest(_ request: NativeRPCValue) -> Bool {
        ["mcpServer/elicitation/request", "elicitation"].contains(request["subtype"].string ?? "")
    }
    public static func authURL(_ request: NativeRPCValue) -> URL? {
        guard isRequest(request), request["input"]["mode"].string == "url",
              let text = request["input"]["url"].string, let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public struct Field: Identifiable, Sendable {
        public let id: String
        public let schema: NativeRPCValue
        public let required: Bool
        public var title: String { schema["title"].string ?? id }
        private var titledChoices: [NativeRPCValue] { schema["oneOf"].elements ?? schema["items"]["anyOf"].elements ?? [] }
        public var choices: [NativeRPCValue] {
            schema["enum"].elements ?? schema["items"]["enum"].elements ?? titledChoices.compactMap { $0.has("const") ? $0["const"] : nil }
        }
        public func choiceTitle(_ index: Int) -> String {
            if let title = schema["enumNames"].elements?.dropFirst(index).first?.string { return title }
            if let title = titledChoices.dropFirst(index).first?["title"].string { return title }
            guard index < choices.count else { return "" }
            return choices[index].string ?? choices[index].compact
        }
    }
    public static func fields(_ request: NativeRPCValue) -> [Field] {
        let schema = request["input"]["requestedSchema"]
        let required = Set(schema["required"].elements?.compactMap(\.string) ?? [])
        return (schema["properties"].fields ?? []).map { Field(id: $0.key, schema: $0.value, required: required.contains($0.key)) }
    }
    public static func usesFields(_ request: NativeRPCValue) -> Bool {
        let schema = request["input"]["requestedSchema"]
        return schema["type"].string == "object" && !fields(request).isEmpty && fields(request).allSatisfy {
            ["string", "number", "integer", "boolean"].contains($0.schema["type"].string ?? "") ||
                ($0.schema["type"].string == "array" && !$0.choices.isEmpty && $0.choices.allSatisfy { $0.string != nil })
        }
    }
    public static func defaults(_ request: NativeRPCValue) -> NativeRPCValue {
        .object(fields(request).compactMap { field in
            field.schema.has("default") ? .init(field.id, field.schema["default"]) : nil
        })
    }
    public static func answers(_ request: NativeRPCValue, text: [String: String], selected: NativeRPCValue) throws -> NativeRPCValue {
        var result = NativeRPCValue.object([])
        for field in fields(request) {
            if let raw = text[field.id], !raw.isEmpty || (field.required && field.schema["type"].string == "string") {
                let value: NativeRPCValue
                if ["integer", "number"].contains(field.schema["type"].string ?? "") {
                    guard let number = Double(raw), number.isFinite else { throw NativeRPCError.invalidArguments("Enter a number for " + field.title + ".") }
                    value = .number(number)
                } else { value = .string(raw) }
                result = result.setting(field.id, value)
            } else if selected.has(field.id) { result = result.setting(field.id, selected[field.id]) }
            else if field.required && field.schema["type"].string == "array" { result = result.setting(field.id, .array([])) }
        }
        return result
    }
    public static func validate(_ request: NativeRPCValue, answers: NativeRPCValue) async throws {
        guard isRequest(request) else { return }
        if request["input"]["mode"].string == "url" {
            guard authURL(request) != nil else { throw NativeRPCError.invalidArguments("This tool server sent an invalid authentication link.") }
            return
        }
        guard request["input"]["mode"].isNullish || request["input"]["mode"].string == "form",
              answers.fields != nil else { throw NativeRPCError.invalidArguments("This tool server needs a supported form and structured answers.") }
        if let error = try await BackendMcpClientJSONSchemaValidator().validate(schema: request["input"]["requestedSchema"], value: answers) {
            throw NativeRPCError.invalidArguments("Check the form: " + error)
        }
    }
}
