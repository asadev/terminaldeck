import Foundation

// Record: the steps a person takes on a page, written down so an agent can
// repeat them. A port of the web browser's recorder rules
// (`src/main/browser-steps.ts`): what is a step, how repeats fold together,
// that a password is recorded as "the password" and never its value, the
// 200-step limit, and the one line a session receives.

/// One line of text, safe for a terminal and capped (`sanitizeLine` in selector.ts).
public enum BrowserLine {
    public static func sanitize(_ value: String, max: Int) -> String {
        let spaced = String(String.UnicodeScalarView(value.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            let v = scalar.value
            if v <= 0x1f || (0x7f...0x9f).contains(v) || v == 0x2028 || v == 0x2029 { return " " }
            if (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200e || v == 0x200f { return nil }
            return scalar
        }))
        let flat = spaced.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if flat.count <= max { return flat }
        return String(flat.prefix(max)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

public struct BrowserRecordedStep: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case navigate, click, type, select, check, press, submit
    }

    public var kind: Kind
    public var selector = ""
    public var label = ""
    public var tag = ""
    public var value = ""
    /// A password or file field: recorded, its value never.
    public var redacted = false
    public var key = ""
    public var checked = false
    public var url = ""
    /// Milliseconds.
    public var at: Double

    public init(kind: Kind, selector: String = "", label: String = "", tag: String = "", value: String = "",
                redacted: Bool = false, key: String = "", checked: Bool = false, url: String = "", at: Double) {
        self.kind = kind
        self.selector = selector
        self.label = label
        self.tag = tag
        self.value = value
        self.redacted = redacted
        self.key = key
        self.checked = checked
        self.url = url
        self.at = at
    }
}

public enum BrowserFlow {
    public static let maxSteps = 200
    public static let notableKeys = ["Enter", "Escape", "Tab"]
    static let maxValue = 200
    static let maxLabel = 120
    static let maxURL = 400
    static let maxFlowLine = 1200
    static let clickMergeMs: Double = 400

    public static func navigate(_ url: String, at: Double) -> BrowserRecordedStep {
        BrowserRecordedStep(kind: .navigate, url: BrowserLine.sanitize(url, max: maxURL), at: at)
    }

    /// A step the page's recorder posted: `{v:1, kind, target:{selector,label,tag,type}, value?, key?, checked?, secret?}`.
    /// Anything malformed is dropped.
    public static func parse(_ raw: Any, url: String, at: Double) -> BrowserRecordedStep? {
        guard let payload = raw as? [String: Any], (payload["v"] as? NSNumber)?.intValue == 1,
              let kindName = payload["kind"] as? String, let kind = BrowserRecordedStep.Kind(rawValue: kindName),
              kind != .navigate,
              let target = payload["target"] as? [String: Any] else { return nil }
        let selector = BrowserLine.sanitize((target["selector"] as? String) ?? "", max: 400)
        let tag = BrowserLine.sanitize((target["tag"] as? String) ?? "", max: 40).lowercased()
        let type = ((target["type"] as? String) ?? "").lowercased()
        guard !selector.isEmpty || !tag.isEmpty else { return nil }
        var step = BrowserRecordedStep(kind: kind, selector: selector, tag: tag, url: url, at: at)
        let label = BrowserLine.sanitize((target["label"] as? String) ?? "", max: maxLabel)
        step.label = label

        switch kind {
        case .press:
            let key = (payload["key"] as? String) ?? ""
            guard notableKeys.contains(key) else { return nil }
            step.key = key
        case .check:
            step.checked = (payload["checked"] as? Bool) ?? false
        case .type, .select:
            if (payload["secret"] as? Bool) == true || type == "password" || type == "file" {
                step.redacted = true
            } else {
                step.value = BrowserLine.sanitize((payload["value"] as? String) ?? "", max: maxValue)
            }
        default:
            break
        }
        return step
    }

    /// Add a step, folding repeats: typing into the same field keeps only the last
    /// value, the same address twice is one visit, a double click is one click.
    public static func append(_ steps: [BrowserRecordedStep], _ next: BrowserRecordedStep) -> [BrowserRecordedStep] {
        if let last = steps.last {
            let sameTarget = !last.selector.isEmpty && last.selector == next.selector
            if (next.kind == .type || next.kind == .select) && last.kind == next.kind && sameTarget {
                return steps.dropLast() + [next]
            }
            if next.kind == .navigate && last.kind == .navigate && last.url == next.url { return steps }
            if next.kind == .click && last.kind == .click && sameTarget && next.at - last.at < clickMergeMs { return steps }
        }
        if steps.count >= maxSteps { return steps }
        return steps + [next]
    }

    public static func isFull(_ steps: [BrowserRecordedStep]) -> Bool { steps.count >= maxSteps }

    static func target(_ step: BrowserRecordedStep) -> String {
        let named = step.label.isEmpty ? "" : "\"\(step.label)\""
        let place = !step.selector.isEmpty ? "`\(step.selector)`" : !step.tag.isEmpty ? "<\(step.tag)>" : "the page"
        return named.isEmpty ? place : "\(named) (\(place))"
    }

    public static func describe(_ step: BrowserRecordedStep) -> String {
        switch step.kind {
        case .navigate: return "Go to \(step.url)"
        case .click: return "Click \(target(step))"
        case .type: return step.redacted ? "Type the password into \(target(step))" : "Type \"\(step.value)\" into \(target(step))"
        case .select: return step.redacted ? "Choose a value in \(target(step))" : "Choose \"\(step.value)\" in \(target(step))"
        case .check: return "\(step.checked ? "Check" : "Uncheck") \(target(step))"
        case .press: return "Press \(step.key) in \(target(step))"
        case .submit: return "Submit \(target(step))"
        }
    }

    /// The flow as numbered lines — what Copy puts on the clipboard.
    public static func text(_ steps: [BrowserRecordedStep]) -> String {
        guard !steps.isEmpty else { return "" }
        var lines = steps.enumerated().map { "\($0.offset + 1). \(describe($0.element))" }
        if isFull(steps) { lines.append("(stopped at \(maxSteps) steps)") }
        return lines.joined(separator: "\n")
    }

    /// The flow as the one line a session receives.
    public static func line(_ steps: [BrowserRecordedStep]) -> String {
        guard !steps.isEmpty else { return "" }
        let body = steps.enumerated().map { "\($0.offset + 1)) \(describe($0.element))" }.joined(separator: "; ")
        return BrowserLine.sanitize("[browser flow: \(body)]", max: maxFlowLine)
    }

    /// The row's two words in the panel ("Click" · "\"Save\"").
    public static func kindLabel(_ kind: BrowserRecordedStep.Kind) -> String {
        switch kind {
        case .navigate: "Go"
        case .click: "Click"
        case .type: "Type"
        case .select: "Choose"
        case .check: "Check"
        case .press: "Press"
        case .submit: "Submit"
        }
    }

    public static func detail(_ step: BrowserRecordedStep) -> String {
        switch step.kind {
        case .navigate: return step.url
        case .type: return step.redacted ? "the password" : "\"\(step.value)\""
        case .select: return step.redacted ? "a value" : "\"\(step.value)\""
        case .press: return step.key
        case .check: return step.checked ? "on" : "off"
        default: return step.label.isEmpty ? "" : "\"\(step.label)\""
        }
    }

    /// What a session receives for a flow, with what was typed in front.
    public static func compose(instruction: String, steps: [BrowserRecordedStep]) -> String {
        let lead = BrowserText.oneLine(instruction)
        let flow = line(steps)
        return lead.isEmpty ? flow : "\(lead) \(flow)"
    }
}
