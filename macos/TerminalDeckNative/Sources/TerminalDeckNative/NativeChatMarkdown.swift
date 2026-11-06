import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeChatMarkdown: View {
    let text: String
    var streaming = false

    var body: some View {
        NativeChatBlocks(blocks: ChatMarkdown.parse(text, streaming: streaming))
            .textSelection(.enabled)
    }

    /// Inline markdown, with links made inert (dotted, not clickable) and code in a tint.
    static func inline(_ source: String) -> AttributedString {
        let prepared = ChatMarkdown.inlineSource(source)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var out = try? AttributedString(markdown: prepared, options: options) else { return AttributedString(source) }
        var links: [Range<AttributedString.Index>] = []
        var codes: [Range<AttributedString.Index>] = []
        for run in out.runs {
            if run.link != nil { links.append(run.range) }
            if run.inlinePresentationIntent?.contains(.code) == true { codes.append(run.range) }
        }
        for range in links {
            if let url = out[range].link, !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { out[range].link = nil }
        }
        for range in codes {
            out[range].font = .system(size: bodyFont.pointSize * 0.86, design: .monospaced)
            out[range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return out
    }
}

// MARK: - A line with links in it: their addresses as tooltips

extension NativeChatMarkdown {
    static var bodyFont: NSFont { .systemFont(ofSize: 14) }
    static var bodyType: Font { .system(size: bodyFont.pointSize) }
    static var headlineFont: NSFont { NSFont.systemFont(ofSize: 15, weight: .semibold) }
    static var subheadlineFont: NSFont {
        NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .boldFontMask)
    }
    static func calloutFont(bold: Bool) -> NSFont {
        let font = bodyFont
        return bold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
    }

    /// The same inline markdown for a text view, when it has a link: the link
    /// inert and dotted, with its address as the run's tooltip (`.cv-link`'s
    /// `title`). Nil when there is no link, and SwiftUI's Text draws it.
    static func rich(_ source: String, font: NSFont) -> NSAttributedString? {
        let prepared = ChatMarkdown.inlineSource(source)
        guard prepared.contains("](") || prepared.contains("<http") else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: prepared, options: options),
              parsed.runs.contains(where: { $0.link != nil }) else { return nil }
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let manager = NSFontManager.shared
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .paragraphStyle: style]
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.86, weight: .regular)
                attributes[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.14)
            }
            if intent.contains(.stronglyEmphasized) { runFont = manager.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = manager.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.toolTip] = link.absoluteString
                if ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") { attributes[.link] = link }
                attributes[.foregroundColor] = NSColor.linkColor
            }
            attributes[.font] = runFont
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

/// Inline markdown: SwiftUI's Text, or — when there is a link — a text view that
/// can show each link's address on hover.
private struct NativeChatInline: View {
    @Environment(\.nativeChatFindQuery) private var findQuery
    let source: String
    let font: Font
    let nsFont: NSFont

    var body: some View {
        if source.contains("$"), source.filter({ $0 == "$" }).count >= 2 {
            NativeChatSealedWeb(source: source, kind: "math-inline")
        } else if let rich = NativeChatMarkdown.rich(source, font: nsFont) {
            NativeChatLinkText(text: NativeChatFindText.highlight(rich, query: findQuery))
        } else {
            Text(NativeChatFindText.highlight(NativeChatMarkdown.inline(source), query: findQuery)).font(font)
        }
    }
}

private struct NativeChatLinkText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width.map { $0.isFinite ? $0 : 10_000 } ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposal.width?.isFinite == true ? width : ceil(used.width), height: ceil(used.height))
    }
}

private struct NativeChatBlocks: View {
    let blocks: [ChatBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                NativeChatBlockView(block: block)
            }
        }.font(NativeChatMarkdown.bodyType)
    }
}

private struct NativeChatBlockView: View {
    let block: ChatBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            NativeChatInline(source: text, font: NativeChatMarkdown.bodyType, nsFont: NativeChatMarkdown.bodyFont)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            NativeChatInline(source: text, font: .system(size: level <= 2 ? 15 : 14, weight: .semibold),
                             nsFont: level <= 2 ? NativeChatMarkdown.headlineFont : NativeChatMarkdown.subheadlineFont)
                .padding(.top, 4)
        case .code(let language, let text):
            NativeChatCode(label: ChatMarkdown.codeLabel(language: language, text: text), text: text)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ordered ? "\(start + index)." : "•")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        NativeChatBlocks(blocks: item)
                    }
                }
            }
            .padding(.leading, 4)
        case .task(let checked, let inner):
            HStack(alignment: .top, spacing: DeckTokens.Spacing.s8) {
                Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                    .accessibilityLabel(checked ? "Completed" : "Not completed")
                NativeChatBlocks(blocks: inner)
            }
        case .image(let source, let alt):
            NativeChatMarkdownImage(source: source, alt: alt)
        case .visual(let kind, let source):
            NativeChatSealedWeb(source: source, kind: kind)
        case .math(let source):
            NativeChatSealedWeb(source: source, kind: "math")
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                NativeChatBlocks(blocks: inner).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            NativeChatTable(header: header, rows: rows)
        }
    }
}

/// Code is immediately readable, with a separate copy action and local scrolling.
private struct NativeChatCode: View {
    @Environment(\.nativeChatFindQuery) private var findQuery
    let label: String
    let text: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
            HStack {
                Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }.buttonStyle(.plain).font(.caption)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(NativeChatFindText.highlight(NativeChatSyntax.color(text), query: findQuery))
                    .font(.system(size: NativeChatMarkdown.bodyFont.pointSize * 0.92, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
            }.frame(height: min(320, CGFloat(text.components(separatedBy: "\n").count) * 18 + DeckTokens.Spacing.s8))
        }
        .padding(DeckTokens.Spacing.s12)
        .background(DeckTokens.taskCard, in: .rect(cornerRadius: DeckTokens.Metrics.cardRadius))
    }
}

/// Columns keep their readable width. Overflow belongs to the table, never the chat.
struct NativeChatTable: View {
    let header: [String]
    let rows: [[String]]
    @State private var available: CGFloat = 360
    private var count: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    private func cell(_ row: [String], _ index: Int) -> String { index < row.count ? row[index] : "" }
    private var widths: [CGFloat] { Self.columnWidths(header: header, rows: rows, available: available) }
    static func columnWidths(header: [String], rows: [[String]], available: CGFloat) -> [CGFloat] {
        let count = max(header.count, rows.map(\.count).max() ?? 0)
        let natural = (0..<count).map { i in
            min(360, max(80, ([header] + rows).map { row in
                ((i < row.count ? row[i] : "") as NSString).size(withAttributes: [.font: NativeChatMarkdown.bodyFont]).width + 24
            }.max() ?? 80))
        }
        let extra = max(0, available - natural.reduce(0, +) - CGFloat(max(0, count - 1)) * DeckTokens.Spacing.s16)
        return natural.map { $0 + extra / CGFloat(max(1, count)) }
    }

    var body: some View {
        let layoutWidths = widths
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                tableRow(header, widths: layoutWidths, bold: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in tableRow(row, widths: layoutWidths, bold: false) }
            }.fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
    private func tableRow(_ cells: [String], widths: [CGFloat], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: DeckTokens.Spacing.s16) {
            ForEach(0..<count, id: \.self) { index in
                NativeChatInline(source: cell(cells, index), font: bold ? NativeChatMarkdown.bodyType.weight(.semibold) : NativeChatMarkdown.bodyType,
                    nsFont: NativeChatMarkdown.calloutFont(bold: bold))
                    .fixedSize(horizontal: false, vertical: true).frame(width: widths[index], alignment: .leading)
            }
        }
    }
}

private enum NativeChatSyntax {
    static func color(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        let patterns: [(String, Color)] = [
            (#"\b(?:let|var|func|class|struct|enum|import|return|if|else|for|while|in|public|private|static|async|await|throw|try|const|function|def|from|true|false|null|nil)\b"#, .purple),
            (#"\b[0-9]+(?:\.[0-9]+)?\b"#, .orange),
            (#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#, .green),
            (#"(?m)//[^\n]*|#[^\n]*"#, .secondary)
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text), let converted = Range(range, in: result) else { continue }
                result[converted].foregroundColor = color
            }
        }
        return result
    }
}
