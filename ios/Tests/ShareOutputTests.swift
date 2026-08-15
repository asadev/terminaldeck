/**
 * Sharing a session's output.
 *
 * Two things worth pinning. The first is that what gets shared is the **whole
 * buffer** and not the screen — the reason to send somebody a session is almost
 * always the error that has already scrolled off the top, and a share that
 * stopped at the top of the screen would be the wrong half of the story every
 * time. The second is the file name, which is the one part of this a person
 * reads before opening it, and which has to survive being a folder name with
 * spaces, slashes and an emoji in it.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class ShareOutputTests: XCTestCase {

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge()
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        return bridge
    }

    // MARK: - What is shared

    /// The difference between this and Copy, in one test: a line that has
    /// scrolled off the top is still in what gets shared.
    func testTheScrollbackIsSharedAndNotJustTheScreen() {
        let bridge = bridge()
        bridge.feed("the very first line, long gone\r\n")
        for line in 1 ... 80 { bridge.feed("filler \(line)\r\n") }

        let visible = bridge.visibleText()
        let shared = bridge.scrollbackText()

        XCTAssertFalse(visible.contains("the very first line"),
                       "the fixture is wrong: that line was supposed to have scrolled away")
        XCTAssertTrue(shared.contains("the very first line, long gone"))
        XCTAssertTrue(shared.contains("filler 80"))
    }

    func testAnEmptyTerminalSharesNothing() {
        XCTAssertEqual(bridge().scrollbackText(), "")
    }

    /// A terminal is forty rows whether or not anything is on them. Sharing
    /// thirty-eight blank lines is its own bug report.
    func testTrailingBlankLinesAreNotShared() {
        let bridge = bridge()
        bridge.feed("one\r\ntwo\r\n")

        XCTAssertEqual(bridge.scrollbackText(), "one\ntwo")
    }

    // MARK: - The file name

    private let noon = Date(timeIntervalSince1970: 1_776_000_000)

    func testTheNameIsTheSessionAndTheMoment() {
        let name = ShareOutput.fileName(session: "daftar", at: noon)
        XCTAssertTrue(name.hasPrefix("daftar-"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
    }

    /// A session is named after a folder, and a folder can be called anything.
    /// What comes out has to be safe on every system the file might land on.
    func testAwkwardTitlesBecomeSafeNames() {
        let name = ShareOutput.fileName(session: "My Project: v2/final 🎉", at: noon)

        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains(" "))
        XCTAssertTrue(name.hasPrefix("my-project-v2-final"), name)
    }

    func testATitleWithNothingUsableInItStillMakesAName() {
        let name = ShareOutput.fileName(session: "🎉🎉🎉", at: noon)
        XCTAssertTrue(name.hasPrefix("session-"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
    }

    func testAVeryLongFolderNameIsCutRatherThanCarried() {
        let name = ShareOutput.fileName(session: String(repeating: "a", count: 300), at: noon)
        XCTAssertLessThan(name.count, 70, name)
    }

    // MARK: - Writing it

    func testWhatIsWrittenIsWhatWasShared() throws {
        let name = ShareOutput.fileName(session: "daftar", at: noon)
        let url = try XCTUnwrap(ShareOutput.write("first\nsecond", named: name))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first\nsecond")
        XCTAssertEqual(url.lastPathComponent, name)
    }

    /// One transcript at a time on disk. The system clears the temporary
    /// directory eventually, and "eventually" is not a cleanup story for
    /// something that can be several hundred kilobytes a time.
    func testASecondShareReplacesTheFirstOnDisk() throws {
        let first = try XCTUnwrap(ShareOutput.write("one", named: "one.txt"))
        let second = try XCTUnwrap(ShareOutput.write("two", named: "two.txt"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }
}
