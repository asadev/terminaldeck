import Foundation

/// The History view's line diff — `diffLines` in the web page, ported as is.
///
/// The transcript stores the exact text an `Edit` replaced and the exact text
/// that replaced it, so both sides are facts and only their alignment is
/// computed: common head and tail are stripped, then a longest common
/// subsequence lines up what is left.
public enum ArtifactsDiff {
    public enum Kind: String, Equatable, Sendable {
        case same, add, del

        /// The mark in the gutter.
        public var mark: String {
            switch self {
            case .same: return " "
            case .add: return "+"
            case .del: return "-"
            }
        }
    }

    public struct Line: Equatable, Sendable {
        public let kind: Kind
        public let text: String
        public init(_ kind: Kind, _ text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Past this many lines on either side, a change is shown as one block removed and one added.
    public static let maxDiffLines = 600
    /// Lines of one change drawn before the rest is folded away.
    public static let maxRenderedLines = 300

    /// A trailing newline ends the last line rather than starting an empty one.
    public static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        // By scalar, as the web splits by code unit: "\r\n" is one Character in
        // Swift and would never match a "\n" separator.
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    public static func diff(before: String, after: String) -> (lines: [Line], truncated: Bool) {
        let a = splitLines(before)
        let b = splitLines(after)

        if a.count > maxDiffLines || b.count > maxDiffLines {
            return (a.prefix(maxDiffLines).map { Line(.del, $0) } + b.prefix(maxDiffLines).map { Line(.add, $0) }, true)
        }

        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }

        let midA = Array(a[head..<(a.count - tail)])
        let midB = Array(b[head..<(b.count - tail)])

        let cols = midB.count + 1
        var table = [Int32](repeating: 0, count: (midA.count + 1) * cols)
        if !midA.isEmpty, !midB.isEmpty {
            for i in stride(from: midA.count - 1, through: 0, by: -1) {
                for j in stride(from: midB.count - 1, through: 0, by: -1) {
                    table[i * cols + j] = midA[i] == midB[j]
                        ? table[(i + 1) * cols + j + 1] + 1
                        : max(table[(i + 1) * cols + j], table[i * cols + j + 1])
                }
            }
        }

        var lines = a[0..<head].map { Line(.same, $0) }
        var i = 0, j = 0
        while i < midA.count, j < midB.count {
            if midA[i] == midB[j] {
                lines.append(Line(.same, midA[i])); i += 1; j += 1
            } else if table[(i + 1) * cols + j] >= table[i * cols + j + 1] {
                lines.append(Line(.del, midA[i])); i += 1
            } else {
                lines.append(Line(.add, midB[j])); j += 1
            }
        }
        while i < midA.count { lines.append(Line(.del, midA[i])); i += 1 }
        while j < midB.count { lines.append(Line(.add, midB[j])); j += 1 }
        lines += a[(a.count - tail)...].map { Line(.same, $0) }
        return (lines, false)
    }

    /// One change as the History view draws it: a write's text (no "before" to
    /// align against), or an edit's diff — capped, with the line under it.
    public enum Body: Equatable, Sendable {
        case write(text: String, more: String?)
        case edit(lines: [Line], more: String?)
    }

    public static func body(for change: ArtifactChange) -> Body {
        if change.action == .write {
            let lines = splitLines(change.after)
            let hidden = lines.count - maxRenderedLines
            return .write(text: lines.prefix(maxRenderedLines).joined(separator: "\n"),
                          more: hidden > 0 ? "\(hidden.formatted()) more line\(hidden == 1 ? "" : "s") not shown." : nil)
        }
        let (lines, truncated) = diff(before: change.before, after: change.after)
        let hidden = lines.count - maxRenderedLines
        let more: String? = truncated
            ? "Too long to line up — shown as one block removed and one added."
            : hidden > 0 ? "\(hidden.formatted()) more lines not shown." : nil
        return .edit(lines: Array(lines.prefix(maxRenderedLines)), more: more)
    }
}
