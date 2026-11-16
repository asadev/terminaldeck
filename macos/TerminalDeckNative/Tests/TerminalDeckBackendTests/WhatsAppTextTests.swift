import Foundation
import XCTest
@testable import TerminalDeckBackend

final class WhatsAppTextTests: XCTestCase {

    // MARK: - format

    func testHeadingsBecomeOneBoldLineWithoutNestedStars() {
        XCTAssertEqual(WhatsAppText.format("# Build report for **TD**"), "*Build report for TD*")
        XCTAssertEqual(WhatsAppText.format("### Next steps ###"), "*Next steps*")
        XCTAssertEqual(WhatsAppText.format("Setup\n-----\nText"), "*Setup*\nText")
        XCTAssertEqual(WhatsAppText.format("Title\n=====\n"), "*Title*")
        XCTAssertEqual(WhatsAppText.format("# Issue #42"), "*Issue #42*")
    }

    func testBoldItalicStrikeAndInlineCode() {
        XCTAssertEqual(WhatsAppText.format("The build **passed** in *12 minutes*."), "The build *passed* in _12 minutes_.")
        XCTAssertEqual(WhatsAppText.format("__bold__ and _italic_ and ~~gone~~ and ***both***"), "*bold* and _italic_ and ~gone~ and *_both_*")
        XCTAssertEqual(WhatsAppText.format("Run `swift test --filter **x**` now"), "Run `swift test --filter **x**` now")
        XCTAssertEqual(WhatsAppText.format("my_var_name and snake_case_too, 5 * 3 * 2"), "my_var_name and snake_case_too, 5 * 3 * 2")
        XCTAssertEqual(WhatsAppText.format(#"Literal \*stars\* stay"#), "Literal *stars* stay")
    }

    func testCodeBlocksKeepTheirTextExactlyAndLoseTheLanguage() {
        let markdown = "Here:\n\n```swift\nlet x = **not bold** // _keep_\n\n    indented()\n```\nDone."
        XCTAssertEqual(WhatsAppText.format(markdown), "Here:\n\n```\nlet x = **not bold** // _keep_\n\n    indented()\n```\nDone.")
        XCTAssertEqual(WhatsAppText.format("~~~\nraw\n~~~"), "```\nraw\n```")
        XCTAssertEqual(WhatsAppText.format("```\nnever closed"), "```\nnever closed\n```")
    }

    func testListsArePlainLines() {
        let markdown = "- one\n  - nested **b**\n* two\n+ three\n1. first\n2) second\n- [x] done\n- [ ] open"
        XCTAssertEqual(WhatsAppText.format(markdown),
                       "- one\n  - nested *b*\n- two\n- three\n1. first\n2. second\n- ☑ done\n- ☐ open")
    }

    func testATableBecomesOneLinePerRow() {
        let markdown = "| Name | Size | Note |\n|:-----|-----:|:----:|\n| a.txt | 3 KB | **new** |\n| b.txt | 4 \\| 5 KB | |\n\nAfter."
        XCTAssertEqual(WhatsAppText.format(markdown), "*Name* | *Size* | *Note*\na.txt | 3 KB | *new*\nb.txt | 4 | 5 KB | \n\nAfter.")
    }

    func testLinksBecomeTextAndURLOrTheBareURL() {
        XCTAssertEqual(WhatsAppText.format("See [the docs](https://example.com/a_b_c \"title\")."), "See the docs (https://example.com/a_b_c).")
        XCTAssertEqual(WhatsAppText.format("[https://y.com](https://y.com) and [y.com](https://y.com)"), "https://y.com and https://y.com")
        XCTAssertEqual(WhatsAppText.format("Open https://x.com/some_path_here_now, then <https://z.io/a*b*c>."),
                       "Open https://x.com/some_path_here_now, then https://z.io/a*b*c.")
        XCTAssertEqual(WhatsAppText.format("![chart](https://e.com/c.png)"), "chart (https://e.com/c.png)")
    }

    func testNoHTMLIsLeft() {
        XCTAssertEqual(WhatsAppText.format("<b>Bold</b> &amp; <i>it</i><br>next &lt;tag&gt; <span class=\"x\">plain</span>"),
                       "*Bold* & _it_\nnext <tag> plain")
        XCTAssertEqual(WhatsAppText.format("<details><summary>More</summary>Body</details>"), "MoreBody")
        XCTAssertEqual(WhatsAppText.format("if a < b and c > d"), "if a < b and c > d")
    }

    func testQuotesRulesAndBlankLines() {
        XCTAssertEqual(WhatsAppText.format("> quoted *it*\n\n---\n\n\n\nEnd"), "> quoted _it_\n\nEnd")
        XCTAssertEqual(WhatsAppText.format("\n\nStart\n\n\n\nEnd\n\n"), "Start\n\nEnd")
    }

    func testNonEnglishAndEmojiAreUntouched() {
        XCTAssertEqual(WhatsAppText.format("اردو میں **جواب** 😀 中文 *斜体* 👨‍👩‍👧‍👦"), "اردو میں *جواب* 😀 中文 _斜体_ 👨‍👩‍👧‍👦")
    }

    func testARealLookingAnswer() {
        let answer = """
        ## Done

        I fixed the **login** bug. Changes:

        1. `AuthView.swift`: the button waits for the *token*.
        2. Tests in [AuthTests](https://github.com/a/b/blob/main/AuthTests.swift).

        | Check | Result |
        |---|---|
        | unit | ✅ 42 passed |

        ```bash
        swift test --filter AuthTests
        ```
        """
        XCTAssertEqual(WhatsAppText.format(answer), """
        *Done*

        I fixed the *login* bug. Changes:

        1. `AuthView.swift`: the button waits for the _token_.
        2. Tests in AuthTests (https://github.com/a/b/blob/main/AuthTests.swift).

        *Check* | *Result*
        unit | ✅ 42 passed

        ```
        swift test --filter AuthTests
        ```
        """)
    }

    // MARK: - split

    private func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }

    func testShortTextIsOnePartAndBlankIsNone() {
        XCTAssertEqual(WhatsAppText.split("Hello"), ["Hello"])
        XCTAssertEqual(WhatsAppText.split("\n\n  Hello  \n"), ["  Hello"])
        XCTAssertEqual(WhatsAppText.split(""), [])
        XCTAssertEqual(WhatsAppText.split(" \n\n "), [])
        let exact = String(repeating: "a", count: 4096)
        XCTAssertEqual(WhatsAppText.split(exact), [exact])
    }

    func testATwelveThousandCharacterAnswerSplitsAtParagraphEnds() {
        var paragraphs: [String] = []
        for index in 0..<40 {
            paragraphs.append("Paragraph \(index): " + String(repeating: "The build ran again and اردو text 👍🏽 stays whole. ", count: 6)
                .trimmingCharacters(in: .whitespaces))
        }
        let answer = paragraphs.joined(separator: "\n\n")
        XCTAssertGreaterThan(answer.count, 12_000)
        let parts = WhatsAppText.split(answer)
        XCTAssertGreaterThanOrEqual(parts.count, 3)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, 4096)
            XCTAssertTrue(part.hasPrefix("Paragraph "), "each part starts at a paragraph")
            XCTAssertTrue(part.hasSuffix("stays whole."), "each part ends at a paragraph end")
        }
        XCTAssertEqual(parts.joined(separator: "\n\n"), answer)
    }

    func testOneLongParagraphSplitsAtLinesThenSentencesNeverInsideAWord() {
        let lines = (0..<120).map { "Line \($0) has some words in it and ends here" }.joined(separator: "\n")
        let byLine = WhatsAppText.split(lines)
        XCTAssertGreaterThan(byLine.count, 1)
        for part in byLine { XCTAssertTrue(part.hasSuffix("ends here")); XCTAssertLessThanOrEqual(part.utf16.count, 4096) }
        XCTAssertEqual(words(byLine.joined(separator: "\n")), words(lines))

        let sentences = String(repeating: "Another sentence goes here, with commas. ", count: 300)
        let bySentence = WhatsAppText.split(sentences)
        XCTAssertGreaterThan(bySentence.count, 1)
        for part in bySentence { XCTAssertTrue(part.hasSuffix("commas.")); XCTAssertLessThanOrEqual(part.utf16.count, 4096) }
        XCTAssertEqual(words(bySentence.joined(separator: " ")), words(sentences))

        let noStops = String(repeating: "word ", count: 2000)
        let byWord = WhatsAppText.split(noStops)
        for part in byWord { XCTAssertTrue(part.hasSuffix("word")); XCTAssertLessThanOrEqual(part.utf16.count, 4096) }
        XCTAssertEqual(words(byWord.joined(separator: " ")), words(noStops))
    }

    func testEmojiAndSurrogatePairsAreNeverCut() {
        let emoji = String(repeating: "👍🏽", count: 3000)   // 4 UTF-16 units each, no spaces
        let parts = WhatsAppText.split(emoji)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, 4096)
            XCTAssertTrue(part.allSatisfy { $0 == "👍🏽" })
        }
        XCTAssertEqual(parts.joined(), emoji)
        let urdu = String(repeating: "تجربہ ", count: 1500)
        XCTAssertEqual(words(WhatsAppText.split(urdu).joined(separator: " ")), words(urdu))
    }

    func testACodeBlockThatFitsIsNeverCut() {
        let before = String(repeating: "Intro sentence here. ", count: 150)
        let code = "```\n" + (0..<60).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n") + "\n```"
        let parts = WhatsAppText.split(before + "\n\n" + code + "\n\nAfter.")
        XCTAssertTrue(parts.contains { $0.contains(code) }, "the whole block is in one part")
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, 4096)
            XCTAssertEqual(part.components(separatedBy: "```").count % 2, 1, "fences balanced in every part")
        }
    }

    func testALongCodeBlockIsClosedAndReopened() {
        let lines = (0..<400).map { "line \($0) of code here" }
        let text = "Here is the log:\n\n```\n" + lines.joined(separator: "\n") + "\n```\n\nThat is all."
        let parts = WhatsAppText.split(text)
        let codeParts = parts.filter { $0.hasPrefix("```") }
        XCTAssertGreaterThan(codeParts.count, 1)
        for part in codeParts {
            XCTAssertTrue(part.hasSuffix("\n```"))
            XCTAssertLessThanOrEqual(part.utf16.count, 4096)
        }
        let carried = codeParts.flatMap { $0.components(separatedBy: "\n").filter { $0 != "```" } }
        XCTAssertEqual(carried, lines, "every code line once, in order, none cut")
        XCTAssertEqual(parts.first, "Here is the log:")
        XCTAssertEqual(parts.last, "That is all.")
    }

    func testFormatThenSplitKeepsEveryPartWithinTheLimit() {
        var markdown = ""
        for index in 0..<30 {
            markdown += "## Section \(index)\n\n**Bold** text with [a link](https://example.com/\(index)) and `code`.\n\n"
            markdown += "| A | B |\n|---|---|\n| \(index) | ✅ |\n\n- item\n- item two\n\n"
            markdown += "```\n" + String(repeating: "x = 1\n", count: 40) + "```\n\n"
        }
        let parts = WhatsAppText.split(WhatsAppText.format(markdown))
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(part.utf16.count, WhatsAppText.limit)
            XCTAssertFalse(part.isEmpty)
            XCTAssertEqual(part.components(separatedBy: "```").count % 2, 1)
        }
    }
}
