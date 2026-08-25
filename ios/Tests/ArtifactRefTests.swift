import XCTest
@testable import TerminalDeck

/**
 * The half of the artifact viewer that has no simulator in it.
 *
 * `ArtifactRef` is the contract between `src/main/remote/panels/artifacts.ts`
 * and the screen: one string carrying what a file is, how big it is, where it is
 * and whether anything is serving it. It is parsed on every row of every draw,
 * and getting it wrong is not a cosmetic failure — a row that mis-parses opens
 * the wrong file, and a row that parses when it should not draws a chevron onto
 * a screen with nothing on it.
 *
 * The grammar is written down in the panel's own header. The cases below are the
 * ones that are easy to get wrong rather than the ones that are easy to write:
 * a filename with a space in it, a host older than this build, a size the
 * machine could not measure.
 */
final class ArtifactRefTests: XCTestCase {

    // MARK: - The grammar

    func testReadsEveryFieldOfARow() {
        let ref = ArtifactRef(id: "demo/index.html page 4096 - /work/deck/demo/index.html")
        XCTAssertEqual(ref?.token, "demo/index.html")
        XCTAssertEqual(ref?.kind, .page)
        XCTAssertEqual(ref?.bytes, 4096)
        XCTAssertNil(ref?.preview)
        XCTAssertEqual(ref?.path, "/work/deck/demo/index.html")
    }

    /// The reason the path is the last field. A filename may contain anything
    /// but `/` and NUL, and a space in one is ordinary rather than exotic.
    func testKeepsASpaceInTheFileName() {
        let ref = ArtifactRef(id: "#abc123 text 12 - /work/deck/design notes/read me.md")
        XCTAssertEqual(ref?.path, "/work/deck/design notes/read me.md")
        XCTAssertEqual(ref?.name, "read me.md")
        XCTAssertEqual(ref?.folder, "/work/deck/design notes")
        XCTAssertEqual(ref?.suffix, "md")
    }

    /// `-1` is the machine saying it could not stat the file, which is a
    /// different fact from a zero-byte file and must not be drawn as one.
    func testTellsAnUnmeasurableFileFromAnEmptyOne() {
        XCTAssertNil(ArtifactRef(id: "x other -1 - /work/x")?.bytes)
        XCTAssertEqual(ArtifactRef(id: "x text 0 - /work/x")?.bytes, 0)
    }

    /**
     * A row this build cannot read is not tappable, rather than tappable and
     * wrong.
     *
     * `PanelView` asks for one of these before it draws a chevron, so every
     * refusal here is a row that stays a list entry — which is what a host older
     * than this build should produce.
     */
    func testRefusesAnythingItCannotReadRatherThanGuessing() {
        XCTAssertNil(ArtifactRef(id: nil))
        XCTAssertNil(ArtifactRef(id: ""))
        // What this panel sent before the grammar existed: a bare relative path.
        XCTAssertNil(ArtifactRef(id: "PLAN.md"))
        XCTAssertNil(ArtifactRef(id: "tok text 10 -"))
        // A word from a newer host that this build has no screen for.
        XCTAssertNil(ArtifactRef(id: "tok spreadsheet 10 - /work/x"))
        XCTAssertNil(ArtifactRef(id: "tok text notanumber - /work/x"))
        XCTAssertNil(ArtifactRef(id: "tok text 10 - "))
    }

    func testSortsAFileIntoTheScreenThatCanShowIt() {
        let kinds: [(String, ArtifactKind)] = [
            ("page", .page), ("image", .image), ("media", .media),
            ("text", .text), ("other", .other), ("gone", .gone),
        ]
        for (word, kind) in kinds {
            XCTAssertEqual(ArtifactRef(id: "t \(word) 1 - /work/x")?.kind, kind, word)
        }
    }

    /// A machine that spells its paths with backslashes is still naming a file.
    func testReadsAWindowsPath() {
        let ref = ArtifactRef(id: #"demo\index.html page 9 - C:\Users\asad\deck\demo\index.html"#)
        XCTAssertEqual(ref?.name, "index.html")
        XCTAssertEqual(ref?.folder, #"C:\Users\asad\deck\demo"#)
    }

    // MARK: - Where it is being served

    func testReadsAPortAndItsSecret() {
        let ref = ArtifactRef(id: "demo/i.html page 9 51423.aB3-_x9 /work/deck/demo/i.html")
        XCTAssertEqual(ref?.preview?.port, 51423)
        XCTAssertEqual(ref?.preview?.secret, "aB3-_x9")
    }

    /// A field that does not parse means *nothing is serving*, never a bad row:
    /// the rest of the row is still a file worth opening.
    func testTreatsAnUnreadablePreviewAsNothingServing() {
        for field in ["-", "notaport.secret", "51423", "0.secret", "99999.secret", "51423."] {
            let ref = ArtifactRef(id: "t page 9 \(field) /work/x")
            XCTAssertNotNil(ref, field)
            XCTAssertNil(ref?.preview, field)
        }
    }

    /**
     * The URL the phone asks for, and why it is a token rather than a path.
     *
     * The host answers `302` to the file's real address, so the page that
     * finally loads is at its own path and every relative URL in it resolves
     * from there. Spelling that path here would mean this phone doing arithmetic
     * with a root and an absolute path it did not produce.
     */
    func testAddressesAFileByItsToken() {
        let ref = ArtifactRef(id: "demo/index.html page 9 51423.sEcReT /work/deck/demo/index.html")
        let address = try? XCTUnwrap(ref?.preview)
        XCTAssertEqual(ref?.previewPath(address!), "/sEcReT/~/demo%2Findex.html")
    }

    func testEscapesATokenWithoutManglingAnOrdinaryName() {
        let ref = ArtifactRef(id: "docs/read-me_v2.md text 9 41000.k /work/x")
        let address = try? XCTUnwrap(ref?.preview)
        // The separator is escaped because a token is **one** URL segment; `-`,
        // `.` and `_` are left alone, because an encoder that took those too
        // would make every ordinary filename unreadable in a log for no gain.
        XCTAssertEqual(ref?.previewPath(address!), "/k/~/docs%2Fread-me_v2.md")
    }

    /**
     * A token with whitespace in it would make the fifth field ambiguous, so the
     * panel never mints one — `tokenFor` digests such a path instead. This is
     * the phone half of that contract: were one to arrive, it is refused rather
     * than mis-split into a row pointing at the wrong file.
     */
    func testRefusesAnIdWhoseTokenWouldSplitTheRow() {
        XCTAssertNil(ArtifactRef(id: "my notes.md text 9 - /work/deck/my notes.md"))
        // What the panel sends for that file instead.
        let hashed = ArtifactRef(id: "#Zm9vYmFy text 9 - /work/deck/my notes.md")
        XCTAssertEqual(hashed?.token, "#Zm9vYmFy")
        XCTAssertEqual(hashed?.path, "/work/deck/my notes.md")
    }
}

/**
 * The markdown reader behind *Read it as prose*.
 *
 * A plan an agent wrote is the most common artifact there is, and it was shown
 * as monospace source with its own hashes in it. This is not a Markdown
 * implementation and is not trying to be — it is the six shapes an agent
 * actually writes, and the case that has to be right before any other is the
 * fence, because a `# heading` inside a code block is a shell comment.
 */
final class MarkdownBlockTests: XCTestCase {

    func testReadsTheSixShapesAnAgentWrites() {
        let blocks = MarkdownBlock.parse("""
        # Plan

        First line
        continued on the next.

        - one
        * two
        1. three

        ---

        ```sh
        npm run build
        ```
        """)

        XCTAssertEqual(blocks, [
            .heading(level: 1, "Plan"),
            // Two source lines, one paragraph — which is what markdown means and
            // what makes it read as prose rather than as a file.
            .paragraph("First line continued on the next."),
            .bullet(marker: "•", "one"),
            .bullet(marker: "•", "two"),
            .bullet(marker: "1.", "three"),
            .rule,
            .code("npm run build"),
        ])
    }

    /// The one rule that has to be applied before every other. A renderer that
    /// drew this heading would be rewriting somebody's script inside their own
    /// document.
    func testDoesNotReadInsideAFence() {
        let blocks = MarkdownBlock.parse("```\n# not a heading\n- not a bullet\n```")
        XCTAssertEqual(blocks, [.code("# not a heading\n- not a bullet")])
    }

    /// What every renderer does, and what the author of a half-written file
    /// means.
    func testRunsAnUnclosedFenceToTheEnd() {
        XCTAssertEqual(MarkdownBlock.parse("intro\n\n```\nstill code"),
                       [.paragraph("intro"), .code("still code")])
    }

    /// Seven hashes is not a heading in any dialect, and a line that is only
    /// hashes is not one either. Both stay what they are rather than becoming
    /// an empty heading.
    func testLeavesSomethingThatIsNotAHeadingAlone() {
        XCTAssertEqual(MarkdownBlock.parse("####### deep"), [.paragraph("####### deep")])
        XCTAssertEqual(MarkdownBlock.parse("###"), [.paragraph("###")])
    }

    func testHasNothingToSayAboutAnEmptyFile() {
        XCTAssertEqual(MarkdownBlock.parse(""), [])
        XCTAssertEqual(MarkdownBlock.parse("\n\n   \n"), [])
    }
}
