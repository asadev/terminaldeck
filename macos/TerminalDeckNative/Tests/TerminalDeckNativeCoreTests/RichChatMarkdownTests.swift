import Testing
@testable import TerminalDeckNativeCore

@Suite struct RichChatMarkdownTests {
    @Test func taskListsAndInlineSyntaxUseGFM() {
        let blocks = ChatMarkdown.parse("- [x] **done**\n  1. ~~old~~ and https://example.com\n- [ ] waiting")
        guard case .list(false, _, let items) = blocks.first, case .task(true, let children) = items.first?.first else { Issue.record("Missing task list"); return }
        #expect(children.count == 2)
        guard case .list(true, _, let nested) = children[1], case .paragraph(let inline) = nested[0][0] else { Issue.record("Missing nested ordered list"); return }
        #expect(inline.contains("~~old~~"))
        #expect(inline.contains("https://example.com"))
        #expect(items[1] == [.task(checked: false, blocks: [.paragraph("waiting")])])
    }
    @Test func imagesAndFootnotesKeepTheirContent() {
        #expect(ChatMarkdown.parse("![plot](images/chart.png)") == [.image(source: "images/chart.png", alt: "plot")])
        let blocks = ChatMarkdown.parse("A fact[^source].\n\n[^source]: A **reference**.")
        #expect(blocks.contains(.rule))
        #expect(blocks.last == .paragraph("\\[1\\] A **reference**."))
    }
    @Test func mathAndVisualFencesStayDistinctFromCode() {
        #expect(ChatMarkdown.parse("$$\nx^2 + y^2\n$$") == [.math("x^2 + y^2")])
        for kind in ["visual", "svg", "mermaid"] {
            #expect(ChatMarkdown.parse("```\(kind)\nsource\n```", streaming: true) == [.visual(kind: kind, source: "source")])
            #expect(ChatMarkdown.parse("```\(kind)\nsource", streaming: true) == [.code(language: kind, text: "source")])
        }
        #expect(ChatMarkdown.parse("~~~visual\n<script>ok()</script>\n~~~") == [.visual(kind: "visual", source: "<script>ok()</script>")])
    }
    @Test func texPunctuationSurvivesMarkdownAndHTMLRendering() {
        let formula = #"\frac{x_i * y_j}{a_b} < z"#
        #expect(ChatMarkdown.parse("$$\n" + formula + "\n$$") == [.math(formula)])
        let html = ChatMarkdown.mathInlineHTML("**Result** $" + formula + "$")
        #expect(html.contains("<strong>Result</strong>"))
        #expect(html.contains(formula.replacingOccurrences(of: "<", with: "&lt;")))
        #expect(!html.contains("<em>"))
        let linked = ChatMarkdown.mathInlineHTML("[Equation $a*b*c$](https://example.com)")
        #expect(linked.contains("$a*b*c$"))
        #expect(!linked.contains("<em>"))
    }
    @Test func codeDoesNotBecomeFootnotesOrMath() {
        #expect(ChatMarkdown.parse("```text\n[^a]: dollars $$\n```\n\nkeep") == [.code(language: "text", text: "[^a]: dollars $$"), .paragraph("keep")])
    }
    @Test func wideTablesKeepEscapedCells() {
        #expect(ChatMarkdown.parse("| left | right |\n| --- | --- |\n| a\\|b | `x` |") == [.table(header: ["left", "right"], rows: [["a|b", "` x `"]])])
    }
    @Test func joinedPhoneMessagesContainClosedVisualSource() {
        let records: [HootChatRecord] = [.text(.user, id: "u", "show"), .text(.textDelta, id: "a", "```visual\n<div>"), .text(.textDelta, id: "a", "chart</div>\n```"), .text(.message, id: "a", "```visual\n<div>chart</div>\n```")]
        let events = records.enumerated().map { HootChatEvent(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element).wireValue }
        let messages = ChatRenderedContent.messages(events).elements ?? []
        #expect(messages.count == 2)
        #expect(messages.last?["blocks"].elements?.first?["type"].string == "visual")
        #expect(messages.last?["blocks"].elements?.first?["source"].string == "<div>chart</div>")
    }
}
