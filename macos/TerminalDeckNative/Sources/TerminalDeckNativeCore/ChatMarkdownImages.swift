import Foundation
import Markdown

public enum ChatMarkdownImages {
    public struct Reference: Sendable {
        public let source: String
        public let alt: String
        public let start: Int
        public let end: Int
    }
    /// Parser ranges exclude code and support inline, nested and reference-style images.
    public static func references(_ text: String) -> [Reference] {
        let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        var starts = [0]
        for line in lines.dropLast() { starts.append(starts.last! + line.count + 1) }
        func offset(_ location: Markdown.SourceLocation) -> Int? {
            guard location.line > 0, location.line <= starts.count, location.column > 0,
                  location.column <= lines[location.line - 1].count + 1 else { return nil }
            return starts[location.line - 1] + location.column - 1
        }
        var result: [Reference] = []
        func walk(_ node: any Markup) {
            if let image = node as? Markdown.Image, let source = image.source, let range = image.range,
               let start = offset(range.lowerBound), let end = offset(range.upperBound), end > start {
                result.append(.init(source: source, alt: image.plainText, start: start, end: end))
            } else { for child in node.children { walk(child) } }
        }
        walk(Document(parsing: text))
        return result
    }
    public static func replacing(_ text: String, references: [Reference], sources: [String: String]) -> String {
        var bytes = Array(text.utf8)
        for reference in references.sorted(by: { $0.start > $1.start }) {
            guard reference.start >= 0, reference.end <= bytes.count,
                  let source = sources[reference.source] else { continue }
            let alt = reference.alt.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            bytes.replaceSubrange(reference.start..<reference.end, with: Array(("![" + alt + "](" + source + ")").utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
