import Foundation

// MARK: - Text rules (task-page.ts, inline-files.ts)

public enum CrmText {
    public static let headingMax = 80
    public static let chipChar: Character = "\u{FFFC}"

    public enum Part: Equatable, Sendable {
        case text(String)
        case file(String)
    }

    /// `[[file:<id>]]` tokens and the text between them.
    public static func splitInlineFiles(_ text: String) -> [Part] {
        var out: [Part] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[[file:") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "]]") else { break }
            let id = String(afterOpen[..<close.lowerBound])
            let valid = !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":") }
                && (id.hasPrefix("draft:") ? id.dropFirst(6).allSatisfy { $0 != ":" } : !id.contains(":"))
            if valid {
                if open.lowerBound > rest.startIndex { out.append(.text(String(rest[..<open.lowerBound]))) }
                out.append(.file(id))
                rest = afterOpen[close.upperBound...]
            } else {
                out.append(.text(String(rest[..<open.upperBound])))
                rest = afterOpen
            }
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        // Merge neighbouring text parts.
        var merged: [Part] = []
        for part in out {
            if case .text(let t) = part, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + t)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    public static func fileToken(_ id: String) -> String { "[[file:\(id)]]" }

    public static func fileTokenIds(_ text: String) -> [String] {
        splitInlineFiles(text).compactMap { if case .file(let id) = $0 { id } else { nil } }
    }

    /// Tokens as one chip character each (the text field's own form).
    public static func toFlat(_ text: String) -> String {
        splitInlineFiles(text).map { part in
            switch part {
            case .text(let t): t
            case .file: String(chipChar)
            }
        }.joined()
    }

    /// The chips back as tokens, in order.
    public static func fromFlat(_ flat: String, ids: [String]) -> String {
        var k = 0
        var out = ""
        for ch in flat {
            if ch == chipChar {
                if k < ids.count { out += fileToken(ids[k]) }
                k += 1
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// The heading (the first line or sentence, at most 80 visible characters) and
    /// the rest. Cut mid-way, the two halves carry an ellipsis.
    public static func split(_ text: String) -> (heading: String, body: String, cut: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each visible character with where it starts in the stored text (UTF-16, as JS slices).
        var storage: [Int] = []
        var chars: [Character?] = []
        var visible: [Int] = []
        var s = 0, v = 0
        for part in splitInlineFiles(trimmed) {
            switch part {
            case .file(let id):
                storage.append(s); visible.append(v); chars.append(nil)
                s += fileToken(id).utf16.count
            case .text(let t):
                for ch in t {
                    storage.append(s); visible.append(v); chars.append(ch)
                    s += String(ch).utf16.count
                    v += 1
                }
            }
        }
        let utf = Array(trimmed.utf16)
        func slice(_ a: Int, _ b: Int? = nil) -> String {
            let end = b ?? utf.count
            return String(decoding: utf[max(0, min(a, utf.count))..<max(0, min(end, utf.count))], as: UTF16.self)
        }
        func at(_ i: Int) -> Int { i < storage.count ? storage[i] : utf.count }
        let ws = CharacterSet.whitespacesAndNewlines
        func t(_ x: String) -> String { x.trimmingCharacters(in: ws) }
        let visibleTotal = v
        let nl = chars.firstIndex { $0 == "\n" } ?? -1
        if nl > 0 && visible[nl] <= headingMax {
            return (t(slice(0, at(nl))), t(slice(at(nl) + 1)), false)
        }
        if chars.count > 1 {
            for i in 0..<(chars.count - 1) {
                if visible[i] >= headingMax { break }
                if let c = chars[i], c == "." || c == "?" || c == "!", chars[i + 1] == " " {
                    let end = at(i + 1)
                    let rest = t(slice(end))
                    if !rest.isEmpty { return (t(slice(0, end)), rest, false) }
                }
            }
        }
        if visibleTotal <= headingMax && nl < 0 { return (trimmed, "", false) }
        if visibleTotal <= headingMax { return (t(slice(0, at(nl))), t(slice(at(nl) + 1)), false) }
        var cut = (0..<chars.count).first { visible[$0] >= headingMax && chars[$0] != nil } ?? 0
        var i = cut
        while i > 0 {
            if chars[i] == " " || chars[i] == "\n" { cut = i; break }
            i -= 1
        }
        let end = at(cut)
        return ("\(t(slice(0, end)))…", "…\(t(slice(end)))", true)
    }

    /// The display heading for a title: the heading without file tokens.
    public static func plainHeading(_ title: String) -> String {
        var out = ""
        for part in splitInlineFiles(split(title).heading) { if case .text(let t) = part { out += t } }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A task link inside the popup (`task:<id>`, or the CRM's `/tasks?task=<id>`), as the id it names.
    public static func linkedTaskId(_ href: String) -> String? {
        if href.hasPrefix("task:") { return String(href.dropFirst(5)).removingPercentEncoding }
        guard href.hasPrefix("/tasks"), let range = href.range(of: "task=") else { return nil }
        let before = href[..<range.lowerBound].last
        guard before == "?" || before == "&" else { return nil }
        let value = href[range.upperBound...].prefix { $0 != "&" && $0 != "#" }
        return value.isEmpty ? nil : String(value).removingPercentEncoding
    }

    /// Labels: trimmed, spaces collapsed, at most 40 characters, case-insensitively once, at most 20.
    public static func normalizeLabels(_ input: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for x in input {
            let t = String(x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(40))
            if t.isEmpty || seen.contains(t.lowercased()) { continue }
            seen.insert(t.lowercased())
            out.append(t)
            if out.count >= 20 { break }
        }
        return out
    }

    /// The status pill's word.
    public static func statusWord(_ status: String) -> String {
        switch status {
        case "To-Do": "TO DO"
        case "Working on it": "WORKING ON IT"
        case "In Progress": "IN PROGRESS"
        case "Done": "DONE"
        case "Stuck": "STUCK"
        default: status.uppercased()
        }
    }

    public static func boardLabel(_ board: String) -> String {
        board.trimmingCharacters(in: .whitespaces).isEmpty ? "No board" : board
    }

    public static let statuses = TaskStatuses.all
    public static let priorities = ["Low", "Medium", "High", "Critical"]

    /// The ▸ beside the status pill: the CRM's flow; Stuck → In Progress.
    public static func nextStatus(_ status: String) -> String? { TaskStatuses.next(status) }
}
