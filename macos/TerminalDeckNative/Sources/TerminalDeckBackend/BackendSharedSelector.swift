import Foundation
import TerminalDeckNativeCore

public struct BackendSharedElementDescriptor: Equatable, Sendable {
    public var tag: String
    public var id: String?
    public var testAttr: String?
    public var testValue: String?
    public var idUnique: Bool
    public var testUnique: Bool
    public var nthOfType: Double?
    public var ofTypeCount: Double?
    public init(tag: String, id: String? = nil, testAttr: String? = nil, testValue: String? = nil, idUnique: Bool = false, testUnique: Bool = false, nthOfType: Double? = nil, ofTypeCount: Double? = nil) {
        self.tag = tag; self.id = id; self.testAttr = testAttr; self.testValue = testValue; self.idUnique = idUnique; self.testUnique = testUnique; self.nthOfType = nthOfType; self.ofTypeCount = ofTypeCount
    }
}

public struct BackendSharedElementCapture: Equatable, Sendable {
    public let selector: String
    public let tag: String
    public let label: String
    public let labelSource: String
    public let url: String
    public let attributes: [String: String]
    public init(selector: String, tag: String, label: String, labelSource: String, url: String, attributes: [String: String]) {
        self.selector = selector; self.tag = tag; self.label = label; self.labelSource = labelSource; self.url = url; self.attributes = attributes
    }
}

/// main/selector.ts. Descriptors are untrusted page facts; the URL is supplied
/// by the browser owner. Output contains no executable terminal control bytes.
public enum BackendSharedSelector {
    public static let testIDAttributes = ["data-testid", "data-test-id", "data-test", "data-qa", "data-cy", "data-automation-id"]
    public static let captureAttributes = ["aria-label", "alt", "placeholder", "title", "role", "type", "name", "href", "value"]
    public static let maxPathDepth = 64
    public static let maxLabelLength = 150
    public static func sanitizeLine(_ value: NativeRPCValue, max: Int) -> String {
        guard let raw = value.string else { return "" }
        let scanLimit = max * 32 + 1024
        let text = BackendSharedText.prefix(raw, scanLimit)
            .replacingOccurrences(of: #"[\x00-\x1f\x7f-\x9f\u2028\u2029]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\u202a-\u202e\u2066-\u2069\u200e\u200f]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let flat = BackendSharedText.trim(text)
        return flat.utf16.count <= max ? flat : BackendSharedText.prefix(flat, max).replacingOccurrences(of: #"[\s\uFEFF]+$"#, with: "", options: .regularExpression) + "…"
    }
    private static func printable(_ text: String) -> Bool { !BackendSharedText.matches(text, #"[\x00-\x1f\x7f-\x9f\u2028\u2029]"#) }
    public static func escapeIdent(_ text: String) -> String {
        // CSS.escape reads UTF-16 units; escaping ASCII and retaining every
        // non-ASCII scalar gives the same output for Swift's valid Unicode.
        var output = "", index = 0
        let first = text.unicodeScalars.first?.value
        for scalar in text.unicodeScalars {
            let code = scalar.value, digit = (0x30...0x39).contains(scalar.value)
            if code == 0 { output += "�" }
            else if (1...0x1f).contains(code) || code == 0x7f || index == 0 && digit || index == 1 && digit && first == 0x2d { output += "\\\(String(code, radix: 16)) " }
            else if index == 0 && code == 0x2d && text.utf16.count == 1 { output += "\\-" }
            else if code >= 0x80 || code == 0x2d || code == 0x5f || digit || (0x41...0x5a).contains(code) || (0x61...0x7a).contains(code) { output.unicodeScalars.append(scalar) }
            else { output += "\\"; output.unicodeScalars.append(scalar) }
            index += code >= 0x10000 ? 2 : 1
        }
        return output
    }
    public static func cssString(_ text: String) -> String? {
        guard printable(text) else { return nil }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func safeTag(_ tag: String) -> String { tag.utf16.count <= 60 && BackendSharedText.matches(tag, #"^[a-zA-Z][a-zA-Z0-9-]*$"#) ? tag : "*" }
    private static func usableID(_ row: BackendSharedElementDescriptor) -> String? {
        let id = BackendSharedText.trim(row.id ?? "")
        return !id.isEmpty && id.utf16.count <= 200 && printable(id) ? id : nil
    }
    private static func usableTest(_ row: BackendSharedElementDescriptor) -> String? {
        guard let attribute = row.testAttr, testIDAttributes.contains(attribute), let value = row.testValue, !value.isEmpty, value.utf16.count <= 200, let literal = cssString(value) else { return nil }
        return "[\(attribute)=\(literal)]"
    }
    private static func segment(_ row: BackendSharedElementDescriptor) -> String {
        let tag = safeTag(row.tag), count = row.ofTypeCount ?? 1, nth = row.nthOfType ?? 1
        return count > 1 && nth.isFinite && nth.rounded() == nth && nth >= 1 ? "\(tag):nth-of-type(\(BackendSharedText.jsNumber(nth)))" : tag
    }
    public static func computeSelector(_ path: [BackendSharedElementDescriptor]) -> String {
        var segments: [String] = []
        for row in path.prefix(maxPathDepth) {
            if let id = usableID(row), row.idUnique { segments.insert("#" + escapeIdent(id), at: 0); return segments.joined(separator: " > ") }
            if let test = usableTest(row), row.testUnique { segments.insert(test, at: 0); return segments.joined(separator: " > ") }
            if row.tag == "html" { break }
            segments.insert(segment(row), at: 0)
            if row.tag == "body" { break }
        }
        return segments.joined(separator: " > ")
    }
    private static func descriptor(_ raw: NativeRPCValue) -> BackendSharedElementDescriptor? {
        guard raw.fields != nil, let tag = raw["tag"].string else { return nil }
        func positiveInteger(_ value: NativeRPCValue) -> Double? { guard let n = value.number, n.rounded() == n, n >= 1 else { return nil }; return n }
        return .init(tag: BackendSharedText.prefix(tag, 60), id: raw["id"].string.map { BackendSharedText.prefix($0, 200) },
                     testAttr: raw["testAttr"].string.map { BackendSharedText.prefix($0, 60) }, testValue: raw["testValue"].string.map { BackendSharedText.prefix($0, 200) },
                     idUnique: raw["idUnique"].bool == true, testUnique: raw["testUnique"].bool == true,
                     nthOfType: positiveInteger(raw["nthOfType"]), ofTypeCount: positiveInteger(raw["ofTypeCount"]))
    }
    public static func parseCapture(_ raw: NativeRPCValue, url: String) -> BackendSharedElementCapture? {
        guard raw.fields != nil, raw["v"] == .number(1), let entries = raw["path"].elements, !entries.isEmpty else { return nil }
        var path: [BackendSharedElementDescriptor] = []
        for raw in entries.prefix(maxPathDepth) { guard let row = descriptor(raw) else { break }; path.append(row) }
        guard let first = path.first else { return nil }
        let selector = computeSelector(path)
        guard !selector.isEmpty else { return nil }
        let attributesRaw = raw["attributes"]
        let isSecret = attributesRaw["type"].string.map { BackendSharedText.trim($0).lowercased() == "password" } ?? false
        var attributes: [String: String] = [:]
        for key in captureAttributes where !(isSecret && key == "value") {
            let value = sanitizeLine(attributesRaw[key], max: 300)
            if !value.isEmpty { attributes[key] = value }
        }
        let text = sanitizeLine(raw["text"], max: maxLabelLength)
        var label = text, source = text.isEmpty ? "none" : "text"
        if text.isEmpty {
            for key in ["value", "aria-label", "alt", "placeholder", "title"] {
                if let value = attributes[key], !value.isEmpty { label = value; source = key; break }
            }
        }
        return .init(selector: selector, tag: safeTag(first.tag) == "*" ? "" : first.tag, label: label, labelSource: source,
                     url: sanitizeLine(.string(url), max: 400), attributes: attributes)
    }
    public static func composeAgentContext(_ capture: BackendSharedElementCapture, instruction: String = "") -> String {
        var parts: [String] = []
        if !capture.url.isEmpty { parts.append("on \(capture.url)") }
        parts.append("element `\(capture.selector)`")
        if !capture.tag.isEmpty { parts.append("<\(capture.tag)>") }
        if !capture.label.isEmpty { parts.append("\(capture.labelSource == "text" ? "text" : capture.labelSource) \"\(capture.label)\"") }
        let context = "[browser: \(parts.joined(separator: ", "))]", lead = sanitizeLine(.string(instruction), max: 600)
        return sanitizeLine(.string(lead.isEmpty ? context : lead + " " + context), max: 1200)
    }
}
