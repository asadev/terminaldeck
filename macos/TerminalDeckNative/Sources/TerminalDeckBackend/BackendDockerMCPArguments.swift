import Foundation
import TerminalDeckNativeCore

/// A small shared validator for the actual Docker/Apps tool schemas. It checks
/// objects recursively, including duplicate keys, before consent or dispatch.
public enum BackendDockerMCPArguments {
    public static func validate(_ arguments: NativeRPCValue, schema: NativeRPCValue) throws {
        try validate(arguments, schema: schema, path: "arguments", depth: 0)
        guard (try arguments.encodedJSON()).count <= 256 * 1024 else {
            throw NativeRPCError.invalidArguments("Server-control arguments are too large.")
        }
    }
    private static func validate(_ value: NativeRPCValue, schema: NativeRPCValue, path: String, depth: Int) throws {
        guard depth <= 16 else { throw NativeRPCError.invalidArguments("Server-control arguments are too deeply nested.") }
        if let choices = schema["enum"].elements, !choices.contains(value) {
            throw NativeRPCError.invalidArguments("\(path) is not one of the supported choices.")
        }
        switch schema["type"].string {
        case "object":
            guard let fields = value.fields else { throw NativeRPCError.invalidArguments("\(path) must be an object.") }
            guard Set(fields.map(\.key)).count == fields.count else { throw NativeRPCError.invalidArguments("\(path) has a repeated argument.") }
            for key in schema["required"].elements?.compactMap(\.string) ?? [] where !value.has(key) {
                throw NativeRPCError.invalidArguments("\(path).\(key) is required.")
            }
            let properties = schema["properties"]
            for field in fields {
                let child = properties[field.key]
                if child != .missing { try validate(field.value, schema: child, path: path + "." + field.key, depth: depth + 1) }
                else if schema["additionalProperties"].bool == false { throw NativeRPCError.invalidArguments("\(path) has an argument it does not accept.") }
                else if schema["additionalProperties"].fields != nil { try validate(field.value, schema: schema["additionalProperties"], path: path + "." + field.key, depth: depth + 1) }
            }
        case "array":
            guard let values = value.elements else { throw NativeRPCError.invalidArguments("\(path) must be an array.") }
            if let minimum = schema["minItems"].number, Double(values.count) < minimum { throw NativeRPCError.invalidArguments("\(path) has too few items.") }
            if let maximum = schema["maxItems"].number, Double(values.count) > maximum { throw NativeRPCError.invalidArguments("\(path) has too many items.") }
            if schema["items"].fields != nil {
                for child in values { try validate(child, schema: schema["items"], path: path + "[]", depth: depth + 1) }
            }
        case "string":
            guard let string = value.string, !string.contains("\0") else { throw NativeRPCError.invalidArguments("\(path) must be a string without null bytes.") }
            if let minimum = schema["minLength"].number, Double(string.count) < minimum { throw NativeRPCError.invalidArguments("\(path) must not be empty.") }
            if let maximum = schema["maxLength"].number, Double(string.count) > maximum { throw NativeRPCError.invalidArguments("\(path) is too long.") }
        case "integer", "number":
            guard let number = value.number, schema["type"].string != "integer" || number.rounded() == number else { throw NativeRPCError.invalidArguments("\(path) must be \(schema["type"].string ?? "a number").") }
            if let minimum = schema["minimum"].number, number < minimum { throw NativeRPCError.invalidArguments("\(path) is below its supported range.") }
            if let maximum = schema["maximum"].number, number > maximum { throw NativeRPCError.invalidArguments("\(path) is above its supported range.") }
        case "boolean":
            guard value.bool != nil else { throw NativeRPCError.invalidArguments("\(path) must be true or false.") }
        default: break
        }
    }
}
