import Foundation

// MARK: Scripts into the page with structured arguments

/// A JSON-like value written as a JavaScript literal. Object keys keep their order,
/// so the script for a given value is always the same text.
public indirect enum PageValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PageValue])
    case object([(String, PageValue)])

    public static func == (lhs: PageValue, rhs: PageValue) -> Bool { lhs.literal == rhs.literal }

    /// The JavaScript literal. Strings use the bridge's own escaping
    /// (`PageCommand.javaScriptString`); a non-finite number is `null`.
    public var literal: String {
        switch self {
        case .string(let text): return PageCommand.javaScriptString(text)
        case .number(let value):
            guard value.isFinite else { return "null" }
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.literal).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { "\(PageCommand.javaScriptString($0.0)):\($0.1.literal)" }.joined(separator: ",") + "}"
        }
    }
}

public enum PageScript {
    /// `window.tdNative && window.tdNative.run('<name>', <argument>)`. The name is one
    /// of ours (a fixed string), so it is written as-is.
    public static func run(_ name: String, _ argument: PageValue? = nil) -> String {
        guard let argument else { return "window.tdNative && window.tdNative.run('\(name)')" }
        return "window.tdNative && window.tdNative.run('\(name)', \(argument.literal))"
    }
}

// MARK: Reading WebKit's message bodies

/// Readers for the Foundation objects WebKit hands over, strict about type: a
/// JavaScript boolean is never a number here, nor a number a boolean.
enum PageBody {
    static func string(_ value: Any?) -> String? { value as? String }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// One line, trimmed, at most `limit` characters.
    static func line(_ raw: String, limit: Int) -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(limit))
    }
}

// MARK: Context menus

/// One row of a page's context menu.
public struct ContextMenuItem: Equatable, Sendable {
    public var id: String
    public var label: String
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    /// Non-nil for a row that opens a submenu.
    public var submenu: [ContextMenuItem]?

    public static func separator() -> ContextMenuItem {
        ContextMenuItem(id: "", label: "", enabled: false, checked: false, isSeparator: true, submenu: nil)
    }

    public init(id: String, label: String, enabled: Bool = true, checked: Bool = false,
                isSeparator: Bool = false, submenu: [ContextMenuItem]? = nil) {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.checked = checked
        self.isSeparator = isSeparator
        self.submenu = submenu
    }
}

/// `{type:'context-menu', id, x, y, items:[{id, label, enabled, checked?, separator?, submenu?}]}`.
/// `x`/`y` are the page's CSS pixels from the web view's top-left.
public struct ContextMenuRequest: Equatable, Sendable {
    public var id: String
    public var x: Double
    public var y: Double
    public var items: [ContextMenuItem]

    public static let messageType = "context-menu"
    public static let resultCommand = "context-menu-result"
    public static let maxItems = 300
    public static let maxDepth = 4
    public static let maxLabel = 200
    public static let maxID = 200

    /// What the page sent: a menu to show, a request that can only be answered
    /// "nothing chosen" (it has an id but nothing showable), or not a menu at all.
    public enum Parsed: Equatable, Sendable {
        case show(ContextMenuRequest)
        case dismissOnly(id: String)
    }

    public static func isContextMenuMessage(_ body: Any) -> Bool {
        (body as? [String: Any])?["type"] as? String == messageType
    }

    /// nil when it is not a context-menu message or has no usable id (nothing to answer).
    public static func parse(_ body: Any) -> Parsed? {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType,
              let id = PageBody.string(dict["id"]), !id.isEmpty, id.count <= maxID
        else { return nil }
        guard let x = PageBody.number(dict["x"]), let y = PageBody.number(dict["y"]),
              let rawItems = dict["items"] as? [Any]
        else { return .dismissOnly(id: id) }
        var budget = maxItems
        let items = tidy(decode(rawItems, depth: 1, budget: &budget))
        guard items.contains(where: { !$0.isSeparator }) else { return .dismissOnly(id: id) }
        return .show(ContextMenuRequest(id: id, x: max(0, x), y: max(0, y), items: items))
    }

    private static func decode(_ raw: [Any], depth: Int, budget: inout Int) -> [ContextMenuItem] {
        var out: [ContextMenuItem] = []
        for entry in raw {
            guard budget > 0 else { break }
            guard let item = entry as? [String: Any] else { continue }
            if PageBody.bool(item["separator"]) == true {
                budget -= 1
                out.append(.separator())
                continue
            }
            guard let rawLabel = PageBody.string(item["label"]) else { continue }
            let label = PageBody.line(rawLabel, limit: maxLabel)
            guard !label.isEmpty else { continue }
            let id = PageBody.string(item["id"]).map { String($0.prefix(maxID)) } ?? ""
            let enabled = PageBody.bool(item["enabled"]) ?? true
            let checked = PageBody.bool(item["checked"]) ?? false
            if let children = item["submenu"] as? [Any] {
                budget -= 1
                // Deeper than the limit: the row stays, disabled, rather than vanish.
                let inner = depth < maxDepth ? tidy(decode(children, depth: depth + 1, budget: &budget)) : []
                let usable = inner.contains { !$0.isSeparator }
                out.append(ContextMenuItem(id: id, label: label, enabled: enabled && usable, checked: checked,
                                           submenu: inner))
                continue
            }
            // A row without an id could never be answered: shown disabled.
            budget -= 1
            out.append(ContextMenuItem(id: id, label: label, enabled: enabled && !id.isEmpty, checked: checked))
        }
        return out
    }

    /// No separator first, last, or twice in a row.
    static func tidy(_ items: [ContextMenuItem]) -> [ContextMenuItem] {
        var out: [ContextMenuItem] = []
        for item in items {
            if item.isSeparator, out.isEmpty || out.last?.isSeparator == true { continue }
            out.append(item)
        }
        while out.last?.isSeparator == true { out.removeLast() }
        return out
    }

    /// `window.tdNative.run('context-menu-result', {id, itemId})` — `itemId` null when dismissed.
    public static func resultScript(id: String, itemId: String?) -> String {
        PageScript.run(resultCommand, .object([("id", .string(id)), ("itemId", itemId.map(PageValue.string) ?? .null)]))
    }
}
