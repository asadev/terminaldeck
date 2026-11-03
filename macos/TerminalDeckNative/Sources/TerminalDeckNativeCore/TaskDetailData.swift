import Foundation

// The task popup's data and rules — the reference CRM's task page, as the
// window copied it (src/shared/crm/*.ts, src/renderer/crm-task/task-collab-draft.ts,
// LocalTaskPopup.tsx). Every value arrives as JSON from `tasks:local-detail`
// and is read field by field.

// MARK: - A JSON value, kept whole (activity payloads, routine rules)

public indirect enum CrmValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([CrmValue])
    case object([String: CrmValue])

    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: self = .array(array.map { CrmValue($0) })
        case let dict as [String: Any]: self = .object(dict.mapValues { CrmValue($0) })
        default: self = .null
        }
    }

    /// Back to Foundation objects, for the wire.
    public var any: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [CrmValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: CrmValue]? { if case .object(let o) = self { o } else { nil } }
    public subscript(key: String) -> CrmValue? { object?[key] }
}
