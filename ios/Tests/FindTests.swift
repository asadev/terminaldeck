/**
 * Finding a line in the scrollback.
 *
 * Two halves, deliberately. The first drives `FindSession` against a **real**
 * `TerminalBridge` with real text fed into it, because the question that matters
 * — does typing `needle` actually land on the newest `needle` in five hundred
 * lines of output — can only be answered by SwiftTerm's own buffer. The second
 * drives it against a recorder, because the rules that are easy to get wrong are
 * about *ordering*: whether the highlight hold is taken when the bar opens and
 * given back when it closes, and whether emptying the field clears the search
 * rather than searching for nothing.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class FindTests: XCTestCase {

    // MARK: - Against a real terminal

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge()
        // A terminal at `.zero` has no columns to put anything in; the size the
        // app gives it comes from SwiftUI layout, which does not happen here.
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        return bridge
    }

    /// Sixty lines with the needle on three of them, well past what fits on one
    /// screen — so the matches are genuinely in the scrollback rather than in
    /// front of the cursor.
    private func filled() -> TerminalBridge {
        let bridge = bridge()
        for line in 1 ... 60 {
            switch line {
            case 4: bridge.feed("the first needle is here\r\n")
            case 30: bridge.feed("a second needle, halfway\r\n")
            case 58: bridge.feed("the last needle, near the end\r\n")
            default: bridge.feed("ordinary line \(line)\r\n")
            }
        }
        return bridge
    }

    func testTypingFindsEveryMatchInTheScrollback() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")

        XCTAssertEqual(find.total, 3)
        XCTAssertTrue(find.hasMatches)
    }

    /**
     * The first match is the **newest** one.
     *
     * The whole reason the search runs backwards from the bottom: on a terminal
     * the interesting occurrence is the one that just happened, and starting at
     * the top means paging forward through a build log to reach it.
     */
    func testTheFirstMatchIsTheMostRecentOne() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")

        XCTAssertEqual(find.index, 3, "typing should land on the last of the three, not the first")
        XCTAssertEqual(find.status, "3 of 3")
    }

    func testEarlierWalksBackAndLaterComesForward() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")
        XCTAssertEqual(find.index, 3)

        find.earlier()
        XCTAssertEqual(find.index, 2)
        find.earlier()
        XCTAssertEqual(find.index, 1)

        find.later()
        XCTAssertEqual(find.index, 2)
    }

    func testSomethingThatIsNotThereSaysSo() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("haystack")

        XCTAssertEqual(find.total, 0)
        XCTAssertFalse(find.hasMatches)
        XCTAssertEqual(find.status, "No matches")
    }

    /// The match is SwiftTerm's selection, which is what makes the system Copy
    /// callout work on a search result. If this stops being true, copying what
    /// you found stops working and nothing else would notice.
    func testAMatchIsSelectedSoItCanBeCopied() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")

        XCTAssertEqual(terminal.selectedText(), "needle")
    }

    /**
     * Output arriving must not wipe the match.
     *
     * SwiftTerm drops the selection on every feed while mouse reporting is
     * allowed, and on a live session that is under a second away. The bar holds
     * it off while it is open; this is the test that says so, and it fails if
     * anybody removes the hold as an optimisation.
     */
    func testAMatchSurvivesTheSessionPrintingMore() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")
        XCTAssertNotNil(terminal.selectedText())

        terminal.feed("the agent keeps working\r\n")

        XCTAssertEqual(terminal.selectedText(), "needle",
                       "the highlight was cleared by output arriving")
    }

    func testClosingGivesMouseReportingBack() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        XCTAssertFalse(terminal.view.allowMouseReporting)

        find.close()

        // A finger has to drive vim again the moment the bar is gone.
        XCTAssertTrue(terminal.view.allowMouseReporting)
    }

    func testClosingDropsTheHighlightAndKeepsTheTerm() {
        let terminal = filled()
        let find = FindSession(terminal: terminal)
        find.open()
        find.type("needle")

        find.close()

        XCTAssertNil(terminal.selectedText(), "a closed bar must not leave a selection behind")
        // Kept, because looking for the same string again is the common case and
        // it is a phone keyboard.
        XCTAssertEqual(find.term, "needle")
        XCTAssertFalse(find.isOpen)
    }

    // MARK: - The rules, against a recorder

    private final class Recorder: TerminalSearching {
        var nexts: [String] = []
        var previouses: [String] = []
        var clears = 0
        var holds: [Bool] = []
        var summary: (index: Int, total: Int) = (0, 0)

        func findNext(_ term: String) -> Bool {
            nexts.append(term)
            return summary.total > 0
        }

        func findPrevious(_ term: String) -> Bool {
            previouses.append(term)
            return summary.total > 0
        }

        func matchSummary(_ term: String) -> (index: Int, total: Int) { summary }
        func clearFind() { clears += 1 }
        func holdHighlight(_ hold: Bool) { holds.append(hold) }
    }

    func testOpeningTakesTheHoldAndClosingReturnsIt() {
        let recorder = Recorder()
        let find = FindSession(terminal: recorder)

        find.open()
        find.close()

        XCTAssertEqual(recorder.holds, [true, false])
    }

    /// Opening twice must not take a second hold, or leave one behind.
    func testOpeningTwiceIsOnceAndClosingTwiceIsOnce() {
        let recorder = Recorder()
        let find = FindSession(terminal: recorder)

        find.open()
        find.open()
        find.close()
        find.close()

        XCTAssertEqual(recorder.holds, [true, false])
    }

    /**
     * Every keystroke restarts from the bottom.
     *
     * Continuing from the last match while a term is being *typed* walks the
     * cursor through the buffer one character at a time, so `error` ends up
     * somewhere in the middle of the scrollback at whichever `e` came first.
     */
    func testEachKeystrokeSearchesAfresh() {
        let recorder = Recorder()
        recorder.summary = (index: 2, total: 4)
        let find = FindSession(terminal: recorder)
        find.open()

        find.type("e")
        find.type("er")
        find.type("err")

        XCTAssertEqual(recorder.previouses, ["e", "er", "err"])
        XCTAssertEqual(recorder.nexts, [], "typing must never step forwards")
        // One clear per keystroke, plus none from anywhere else.
        XCTAssertEqual(recorder.clears, 3)
    }

    func testEmptyingTheFieldClearsRatherThanSearches() {
        let recorder = Recorder()
        recorder.summary = (index: 1, total: 2)
        let find = FindSession(terminal: recorder)
        find.open()
        find.type("needle")

        find.type("")

        XCTAssertEqual(recorder.previouses, ["needle"], "an empty term is not a search")
        XCTAssertEqual(find.total, 0)
        XCTAssertEqual(find.status, "", "an empty field must not accuse anybody of finding nothing")
    }

    func testTheArrowsDoNothingWithNoTerm() {
        let recorder = Recorder()
        let find = FindSession(terminal: recorder)
        find.open()

        find.earlier()
        find.later()

        XCTAssertEqual(recorder.previouses, [])
        XCTAssertEqual(recorder.nexts, [])
    }

    /// A term with more matches than the counter counts says so rather than
    /// reporting the cap as if it were the answer.
    func testAVeryCommonTermSaysMoreThanTheCap() {
        let recorder = Recorder()
        recorder.summary = (index: 7, total: FindSession.countLimit)
        let find = FindSession(terminal: recorder)
        find.open()
        find.type("e")

        XCTAssertEqual(find.status, "7 of 1000+")
    }
}
