import Foundation
import Markdown

public indirect enum ChatBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case list(ordered: Bool, start: Int, items: [[ChatBlock]])
    case task(checked: Bool, blocks: [ChatBlock])
    case quote([ChatBlock])
    case rule
    case table(header: [String], rows: [[String]])
    case image(source: String, alt: String)
    case visual(kind: String, source: String)
    case math(String)
}

// NSCache synchronizes its own access. Values are immutable and safe to share
// between the chat engine, read tools and renderer while a reply streams.
private final class ChatMarkdownCache: @unchecked Sendable {
    final class Entry: NSObject {
        let blocks: [ChatBlock]
        init(_ blocks: [ChatBlock]) { self.blocks = blocks }
    }
    let values = NSCache<NSString, Entry>()
    init() { values.countLimit = 512; values.totalCostLimit = 8 * 1024 * 1024 }
}

/// GFM's structure comes from swift-markdown/cmark-gfm. Only our display extensions
/// (closed visual fences, math and footnote labels) live here.
public enum ChatMarkdown {
    private static let cache = ChatMarkdownCache()
    /// The same words on every app (Windows: ChatRichContent.Instruction). Visuals follow the app's light or dark theme
    /// through the sealed document's variables (Asad's release check, 6 Nov: dark grey chart text on the dark card).
    public static let instruction = "This chat shows GitHub Markdown (tables, lists, math), ```mermaid diagrams and ```visual blocks (HTML/SVG/JS; scripts only from cdnjs/jsdelivr) drawn live. Visuals follow the app's light or dark theme: colour text, labels, axes and lines with var(--text) or currentColor, secondary text with var(--muted), highlights with var(--accent) and fills behind text with var(--background); never fixed dark or light text colours. Canvas charts read them with getComputedStyle(document.documentElement).getPropertyValue('--text')."

    public static func parse(_ text: String, streaming: Bool = false) -> [ChatBlock] {
        if let hit = cache.values.object(forKey: text as NSString) { return hit.blocks }
        let mathTokens = mathTokens(footnotes(text))
        let prepared = mathTokens.source
        func restore(_ value: String) -> String {
            mathTokens.values.reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
        }
        let document = Document(parsing: prepared, options: [.disableSmartOpts])
        let lines = prepared.components(separatedBy: "\n")
        func blocks(_ node: any Markup) -> [ChatBlock] {
            node.children.flatMap { child -> [ChatBlock] in
                switch child {
                case let code as CodeBlock:
                    let language = code.language?.lowercased()
                    let body = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
                    if ["visual", "svg", "mermaid"].contains(language ?? "") {
                        let lastLine = child.range?.upperBound.line ?? lines.count
                        let opening = child.range.map { range in
                            String(decoding: lines[max(0, range.lowerBound.line - 1)].utf8.dropFirst(max(0, range.lowerBound.column - 1)), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                        } ?? ""
                        let marker = opening.first ?? "`"
                        let length = opening.prefix { $0 == marker }.count
                        let closing = lastLine <= lines.count ? lines[max(0, lastLine - 1)].trimmingCharacters(in: .whitespaces) : ""
                        let closed = lastLine > (child.range?.lowerBound.line ?? lastLine) && closing.count >= max(3, length) && closing.allSatisfy { $0 == marker }
                        if !closed { return [.code(language: language, text: body)] }
                        return [.visual(kind: language!, source: body)]
                    }
                    return [.code(language: code.language, text: body)]
                case let heading as Heading: return [.heading(level: heading.level, text: restore(inline(heading)))]
                case let list as OrderedList:
                    return [.list(ordered: true, start: Int(list.startIndex), items: list.children.map { item in taskBlocks(item, blocks: blocks) })]
                case let list as UnorderedList:
                    return [.list(ordered: false, start: 1, items: list.children.map { item in taskBlocks(item, blocks: blocks) })]
                case is BlockQuote: return [.quote(blocks(child))]
                case is ThematicBreak: return [.rule]
                case let table as Markdown.Table:
                    return [.table(header: table.head.children.map { restore(inline($0)) }, rows: table.body.children.map { $0.children.map { restore(inline($0)) } })]
                case let paragraph as Paragraph:
                    let math = restore(inline(paragraph))
                    if math.hasPrefix("$$"), math.hasSuffix("$$"), math.count >= 4 {
                        return [.math(String(math.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines))]
                    }
                    var result: [ChatBlock] = [], buffer = ""
                    for part in child.children {
                        if let image = part as? Markdown.Image, let destination = image.source {
                            if !buffer.isEmpty { result.append(.paragraph(restore(buffer))); buffer = "" }
                            result.append(.image(source: destination, alt: image.plainText))
                        } else { buffer += inlinePart(part) }
                    }
                    if !buffer.isEmpty { result.append(.paragraph(restore(buffer))) }
                    return result
                case let html as HTMLBlock: return [.paragraph(html.rawHTML)]
                default: return blocks(child)
                }
            }
        }
        let result = blocks(document)
        cache.values.setObject(.init(result), forKey: text as NSString, cost: max(1, text.utf8.count * 4))
        return result
    }
    private static func taskBlocks(_ item: any Markup, blocks: (any Markup) -> [ChatBlock]) -> [ChatBlock] {
        let inner = blocks(item)
        guard let check = (item as? ListItem)?.checkbox else { return inner }
        return [.task(checked: check == .checked, blocks: inner)]
    }
    private static func inline(_ node: any Markup) -> String { node.children.map(inlinePart).joined() }
    private static func inlinePart(_ node: any Markup) -> String {
        switch node {
        case is SoftBreak: return " "
        case is LineBreak: return "\n"
        case let text as Markdown.Text:
            return text.string.reduce(into: "") { result, character in
                if "\\*_~`[]".contains(character) { result.append("\\") }
                result.append(character)
            }
        case is Strong: return "**" + inline(node) + "**"
        case is Emphasis: return "*" + inline(node) + "*"
        case is Strikethrough: return "~~" + inline(node) + "~~"
        case let code as InlineCode:
            let run = (code.code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1
            let delimiter = String(repeating: "`", count: run)
            return delimiter + " " + code.code + " " + delimiter
        case let link as Markdown.Link:
            let destination = (link.destination ?? "").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            return "[" + inline(node) + "](" + destination + ")"
        case let image as Markdown.Image: return "![" + image.plainText + "](" + (image.source ?? "") + ")"
        case let html as InlineHTML: return html.rawHTML.replacingOccurrences(of: "<", with: "\\<")
        default: return inline(node)
        }
    }

    // Preserve TeX before Markdown sees underscores, stars or backslashes. Code
    // remains code; the maintained AST identifies the protected source lines.
    private static func mathTokens(_ source: String) -> (source: String, values: [(String, String)]) {
        guard source.contains("$") else { return (source, []) }
        var protected: [Range<Int>] = []
        var lineOffsets = [0]
        for (offset, byte) in source.utf8.enumerated() where byte == 10 { lineOffsets.append(offset + 1) }
        func protect(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode || node is HTMLBlock || node is Markdown.Image {
                if let range = node.range, lineOffsets.indices.contains(range.lowerBound.line - 1), lineOffsets.indices.contains(range.upperBound.line - 1) {
                    let lower = lineOffsets[range.lowerBound.line - 1] + range.lowerBound.column - 1
                    let upper = lineOffsets[range.upperBound.line - 1] + range.upperBound.column - 1
                    if upper > lower { protected.append(lower..<upper) }
                }
            } else { for child in node.children { protect(child) } }
        }
        protect(Document(parsing: source, options: [.disableSmartOpts]))
        let pattern = #"(?s)(?<![\\$])\$\$(.+?)(?<!\\)\$\$|(?<![\\$])\$([^$\n]+?)(?<!\\)\$(?!\$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return (source, []) }
        let prefix = "TDMath" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var prepared = source, values: [(String, String)] = []
        for (index, match) in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).enumerated().reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            let start = source[..<range.lowerBound].utf8.count
            let bytes = start..<(start + source[range].utf8.count)
            guard !protected.contains(where: { $0.overlaps(bytes) }) else { continue }
            let token = prefix + "N" + String(index) + "End"
            values.append((token, String(source[range])))
            prepared.replaceSubrange(range, with: token)
        }
        return (prepared, values)
    }

    public static func linkURLs(_ source: String) -> [URL] {
        var urls: [URL] = []
        func visit(_ node: any Markup) {
            if let link = node as? Markdown.Link, let destination = link.destination, let url = URL(string: destination),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { urls.append(url) }
            for child in node.children { visit(child) }
        }
        visit(Document(parsing: source, options: [.disableSmartOpts]))
        return urls
    }

    public static func mathInlineHTML(_ source: String) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func html(_ node: any Markup) -> String {
            let children = node.children.map(html).joined()
            switch node {
            case let text as Markdown.Text: return escape(text.string)
            case is Strong: return "<strong>" + children + "</strong>"
            case is Emphasis: return "<em>" + children + "</em>"
            case is Strikethrough: return "<del>" + children + "</del>"
            case let code as InlineCode: return "<code>" + escape(code.code) + "</code>"
            case is SoftBreak: return " "
            case is LineBreak: return "<br>"
            case let link as Markdown.Link:
                guard let destination = link.destination, let url = URL(string: destination), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return children }
                return "<a href=\"" + escape(destination) + "\">" + children + "</a>"
            case let raw as InlineHTML: return escape(raw.rawHTML)
            default: return children
            }
        }
        let tokens = mathTokens(source)
        return tokens.values.reduce(html(Document(parsing: tokens.source, options: [.disableSmartOpts]))) {
            $0.replacingOccurrences(of: $1.0, with: escape($1.1))
        }
    }

    public static func inlineSource(_ text: String) -> String { text }
    public static func codeLabel(language: String?, text: String) -> String {
        let count = text.components(separatedBy: "\n").count
        return "\((language?.isEmpty == false ? language : nil) ?? "code") · \(count) \(count == 1 ? "line" : "lines")"
    }
    // Footnotes are a GFM extension outside swift-markdown's current AST. Keep
    // their content native and never interpret definitions inside fenced code.
    private static func footnotes(_ text: String) -> String {
        guard text.contains("[^") else { return text }
        var protected = Set<Int>()
        func protect(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode || node is HTMLBlock {
                if let range = node.range { protected.formUnion(range.lowerBound.line...range.upperBound.line) }
            } else { for child in node.children { protect(child) } }
        }
        protect(Document(parsing: text, options: [.disableSmartOpts]))
        var out: [String] = [], notes: [(String, String)] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if !protected.contains(index + 1), line.prefix(while: { $0 == " " }).count <= 3,
               trimmed.hasPrefix("[^"), let end = trimmed.range(of: "]:") {
                let label = String(trimmed.dropFirst(2).prefix(upTo: end.lowerBound))
                var content = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(""); index += 1
                while index < lines.count, lines[index].hasPrefix("    ") {
                    content += "\n" + lines[index].dropFirst(4)
                    out.append(""); index += 1
                }
                notes.append((label, content))
            } else { out.append(line); index += 1 }
        }
        for i in out.indices where !protected.contains(i + 1) {
            for (index, note) in notes.enumerated() { out[i] = out[i].replacingOccurrences(of: "[^\(note.0)]", with: "[\(index + 1)]") }
        }
        var source = out.joined(separator: "\n")
        if !notes.isEmpty { source += "\n\n---\n\n" + notes.enumerated().map { "[\($0.offset + 1)] \($0.element.1)" }.joined(separator: "\n\n") }
        return source
    }

    private static func markdownSource(_ block: ChatBlock) -> String {
        switch block {
        case .paragraph(let text), .math(let text): return text
        case .heading(let level, let text): return String(repeating: "#", count: level) + " " + text
        case .code(let language, let text): return "```" + (language ?? "") + "\n" + text + "\n```"
        case .visual(let kind, let text): return "```" + kind + "\n" + text + "\n```"
        case .image(let source, let alt): return "![" + alt + "](" + source + ")"
        case .quote(let blocks): return blocks.map(markdownSource).joined(separator: "\n\n").components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
        case .task(let checked, let blocks): return (checked ? "[x] " : "[ ] ") + blocks.map(markdownSource).joined(separator: "\n")
        case .rule: return "---"
        case .table(let header, let rows): return ([header, header.map { _ in "---" }] + rows).map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        case .list(let ordered, let start, let items): return items.enumerated().map { index, blocks in
            let marker = ordered ? "\(start + index). " : "- "
            return marker + blocks.map(markdownSource).joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: marker.count))
        }.joined(separator: "\n")
        }
    }

    public static func renderedBlocks(_ text: String, streaming: Bool = false) -> NativeRPCValue {
        func wire(_ block: ChatBlock) -> NativeRPCValue {
            var fields: [NativeRPCValue.Field] = []
            func field(_ key: String, _ value: String) { fields.append(.init(key, .string(value))) }
            switch block {
            case .paragraph(let source): field("type", "markdown"); field("source", source)
            case .heading(let level, let source): field("type", "markdown"); field("source", String(repeating: "#", count: level) + " " + source)
            case .code(let language, let source): field("type", "code"); field("source", source); field("language", language ?? "")
            case .visual(let kind, let source): field("type", kind); field("source", source)
            case .math(let source): field("type", "math"); field("source", source)
            case .image(let source, let alt): field("type", "image"); field("source", source); field("alt", alt)
            case .rule: field("type", "markdown"); field("source", "---")
            case .quote(let children): field("type", "quote"); fields.append(.init("children", .array(children.map(wire))))
            case .task(let checked, let children): field("type", "task"); fields += [.init("checked", .bool(checked)), .init("children", .array(children.map(wire)))]
            case .list(let ordered, let start, let items): field("type", "list"); fields += [.init("ordered", .bool(ordered)), .init("start", .number(Double(start))), .init("items", .array(items.map { .array($0.map(wire)) }))]
            case .table(let header, let rows): field("type", "table"); fields += [.init("header", .array(header.map(NativeRPCValue.string))), .init("rows", .array(rows.map { .array($0.map(NativeRPCValue.string)) }))]
            }
            if !fields.contains(where: { $0.key == "source" }) { field("source", markdownSource(block)) }
            return .object(fields)
        }
        return .array(parse(text, streaming: streaming).map(wire))
    }
}
