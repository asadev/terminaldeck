import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeChatMarkdown: View {
    let text: String

    var body: some View {
        NativeChatBlocks(blocks: ChatMarkdown.parse(text))
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
            out[range].link = nil
            out[range].underlineStyle = Text.LineStyle(pattern: .dot, color: .secondary)
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
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attributes[.underlineColor] = NSColor.tertiaryLabelColor
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
        if let rich = NativeChatMarkdown.rich(source, font: nsFont) {
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

/// Code keeps its original lines and scrolls inside its own surface.
private struct NativeChatCode: View {
    @Environment(\.nativeChatFindQuery) private var findQuery
    let label: String
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(open ? "▾" : "▸")
                    Text(label)
                    Spacer(minLength: 0)
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open || !NativeChatFindText.ranges(text, query: findQuery).isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(NativeChatFindText.highlight(AttributedString(text), query: findQuery))
                        .font(.system(size: NativeChatMarkdown.bodyFont.pointSize * 0.92, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, DeckTokens.Spacing.s12)
                }
                .frame(height: min(320, CGFloat(text.components(separatedBy: "\n").count) * NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: NativeChatMarkdown.bodyFont.pointSize * 0.92, weight: .regular)) + DeckTokens.Spacing.s12))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
    }
}

/// Measurement follows the chat column, never the table's intrinsic text width.
struct NativeChatTable: View {
    let header: [String]
    let rows: [[String]]
    @State private var available: CGFloat = 0
    private var count: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    private func cell(_ row: [String], _ index: Int) -> String { index < row.count ? row[index] : "" }
    var body: some View {
        Group {
            if let widths = ChatTableLayout.widths(header: header, rows: rows, available: available) {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                    tableRow(header, widths: widths, bold: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        tableRow(row, widths: widths, bold: false)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                            ForEach(0..<count, id: \.self) { index in
                                let label = cell(header, index).isEmpty ? "Column \(index + 1)" : cell(header, index)
                                inline("**" + label + "**: " + cell(row, index), bold: false)
                            }
                        }
                        .padding(DeckTokens.Spacing.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DeckTokens.taskCard, in: .rect(cornerRadius: DeckTokens.Metrics.cardRadius))
                    }
                    if rows.isEmpty { ForEach(header.indices, id: \.self) { inline(header[$0], bold: true) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
    private func inline(_ text: String, bold: Bool) -> some View {
        NativeChatInline(source: text, font: bold ? NativeChatMarkdown.bodyType.weight(.semibold) : NativeChatMarkdown.bodyType,
                         nsFont: NativeChatMarkdown.calloutFont(bold: bold))
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func tableRow(_ cells: [String], widths: [Double], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: ChatTableLayout.gap) {
            ForEach(0..<count, id: \.self) { index in
                inline(cell(cells, index), bold: bold).frame(width: widths[index], alignment: .leading)
            }
        }
    }
}
