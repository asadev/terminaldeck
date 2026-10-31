import Foundation

/// Declarative text only. No renderer expressions, HTML, URLs or script nodes.
public enum PluginContract {
    public static let newCapabilities: Set<String> = ["ui.contribute", "state.read", "state.write", "jobs.run", "events.receive"]
    public static func json(_ value: NativeRPCValue, bytes: Int = 8192, depth: Int = 8) throws {
        func visit(_ value: NativeRPCValue, _ level: Int) throws {
            guard level <= depth else { throw invalid("JSON is nested too deeply") }
            switch value {
            case .missing, .bytes: throw invalid("Only ordinary JSON values are supported")
            case .number(let n): guard n.isFinite else { throw invalid("Numbers must be finite") }
            case .object(let fields):
                guard Set(fields.map(\.key)).count == fields.count else { throw invalid("Repeated JSON keys") }
                for field in fields { try visit(field.value, level + 1) }
            case .array(let values): for item in values { try visit(item, level + 1) }
            default: break
            }
        }
        try visit(value, 0)
        guard try value.encodedJSON().count <= bytes else { throw invalid("JSON exceeds its size limit") }
    }
    public static func equal(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        if let fields = a.fields { guard let other = b.fields, fields.count == other.count else { return false }; return fields.allSatisfy { field in other.contains { $0.key == field.key && equal($0.value, field.value) } } }
        if let list = a.elements { guard let other = b.elements, list.count == other.count else { return false }; return zip(list, other).allSatisfy { equal($0, $1) } }
        return a == b
    }
    public static func key(_ value: NativeRPCValue, label: String = "id") throws -> String {
        guard let id = value.string, id.range(of: #"^[a-z][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else { throw invalid(label + " must be a short simple identifier") }; return id
    }
    public static func closed(_ value: NativeRPCValue, _ keys: Set<String>, _ label: String) throws {
        guard let fields = value.fields else { throw invalid(label + " must be an object") }
        if let unknown = fields.first(where: { !keys.contains($0.key) }) { throw invalid(label + " has unsupported field " + unknown.key) }
        guard Set(fields.map(\.key)).count == fields.count else { throw invalid(label + " repeats a field") }
    }
    public static func text(_ value: NativeRPCValue, limit: Int) throws -> String {
        guard let text = value.string, !text.isEmpty, text.utf8.count <= limit, !text.contains("\0") else { throw invalid("Text is missing or too long") }; return text
    }
    public static func invalid(_ message: String) -> NativeRPCError { .init(code: "plugin-contract", message: message) }
}
