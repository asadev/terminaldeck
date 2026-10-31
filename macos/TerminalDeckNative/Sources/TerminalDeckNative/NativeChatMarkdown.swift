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
            out[range].font = .system(size: NSFont.systemFontSize * 0.86, design: .monospaced)
            out[range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return out
    }
}

// MARK: - A line with links in it: their addresses as tooltips

extension NativeChatMarkdown {
    static var bodyFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    static var headlineFont: NSFont { NSFont.preferredFont(forTextStyle: .headline) }
    static var subheadlineFont: NSFont {
        NSFontManager.shared.convert(NSFont.preferredFont(forTextStyle: .subheadline), toHaveTrait: .boldFontMask)
    }
    static func calloutFont(bold: Bool) -> NSFont {
        let font = NSFont.preferredFont(forTextStyle: .callout)
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
        }
    }
}

private struct NativeChatBlockView: View {
    let block: ChatBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            NativeChatInline(source: text, font: .body, nsFont: NativeChatMarkdown.bodyFont)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            NativeChatInline(source: text, font: level <= 2 ? .headline : .subheadline.weight(.semibold),
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
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            NativeChatInline(source: cell, font: .callout.weight(.semibold), nsFont: NativeChatMarkdown.calloutFont(bold: true))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                NativeChatInline(source: cell, font: .callout, nsFont: NativeChatMarkdown.calloutFont(bold: false))
                            }
                        }
                        if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .font(.callout)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// `<details class="cv-code">`: shut until opened, at most 320 points tall, wrapped.
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
                ScrollView(.vertical) {
                    Text(NativeChatFindText.highlight(AttributedString(text), query: findQuery))
                        .font(.system(size: NSFont.systemFontSize * 0.92, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
    }
}
