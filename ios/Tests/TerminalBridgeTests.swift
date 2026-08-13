/**
 * The two directions data moves through the terminal, and the one thing the
 * copy button depends on.
 *
 * `visibleText()` is the fallback behind Copy when nothing is selected, and it
 * reads SwiftTerm's buffer through an API whose row indices are absolute rather
 * than screen-relative. Getting that wrong produces an empty string, which the
 * UI reports as "Nothing to copy" — a button that appears to work and does
 * nothing, which is the failure mode worth a test.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class TerminalBridgeTests: XCTestCase {

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge()
        // A terminal at `.zero` has no columns to put anything in. The size the
        // app gives it comes from SwiftUI layout, which does not happen here.
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        return bridge
    }

    func testWhatIsFedIsWhatIsCopied() {
        let bridge = bridge()
        bridge.feed("hello from the desktop\r\n")
        let text = bridge.visibleText()
        XCTAssertTrue(text.contains("hello from the desktop"), "visibleText was: \(text)")
    }

    func testTrailingBlankRowsAreNotCopied() {
        let bridge = bridge()
        bridge.feed("one\r\ntwo\r\n")
        let text = bridge.visibleText()
        // A terminal is 24 rows whether or not anything is on them; pasting
        // twenty empty lines into a message is its own bug report.
        XCTAssertFalse(text.hasSuffix("\n"), "visibleText was: \(text.debugDescription)")
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testAnEmptyTerminalCopiesNothing() {
        XCTAssertEqual(bridge().visibleText(), "")
    }

    func testNoteIsVisiblyNotProgramOutput() {
        let bridge = bridge()
        bridge.note("connection lost")
        XCTAssertTrue(bridge.visibleText().contains("[connection lost]"))
    }

    func testClearResetsRatherThanScrolls() {
        let bridge = bridge()
        bridge.feed("before the re-attach\r\n")
        bridge.clear()
        // A re-attach replays the whole scrollback; anything left behind would
        // be printed twice.
        XCTAssertFalse(bridge.visibleText().contains("before the re-attach"))
    }

    func testNothingIsSelectedUntilSomethingIs() {
        let bridge = bridge()
        bridge.feed("some output\r\n")
        XCTAssertNil(bridge.selectedText())
    }

    // MARK: - Pasting

    /**
     * The paste rules, tested on the pure half.
     *
     * `pasteable` is deliberately `static` so these can run without driving a
     * socket: every one of the cases below was a real defect in the version that
     * sent the clipboard straight at the wire.
     */

    func testNewlinesBecomeCarriageReturns() {
        // A terminal's Enter is CR. LF into a line editor produces a literal
        // newline in the buffer on some programs and nothing at all on others.
        XCTAssertEqual(TerminalBridge.pasteable("one\ntwo"), "one\rtwo")
    }

    func testCRLFCollapsesToOneCarriageReturn() {
        // Text copied from a web page on a phone is full of these. Two Enters
        // per line runs every other line as an empty command.
        XCTAssertEqual(TerminalBridge.pasteable("one\r\ntwo\r\n"), "one\rtwo\r")
    }

    func testEscapeSequencesAreStrippedFromAPaste() {
        // A clipboard is not a control channel. An escape sequence in one is how
        // a copied page repaints, retitles or re-colours somebody's terminal.
        XCTAssertEqual(TerminalBridge.pasteable("red \u{1b}[31mtext\u{1b}[0m"), "red [31mtext[0m")
    }

    func testAPasteCannotCloseItsOwnBracket() {
        // The attack bracketed paste exists to stop, reintroduced by the code
        // implementing it: an embedded `ESC[201~` ends the bracket early and the
        // rest arrives as keystrokes. Removing ESC is what prevents it.
        let hostile = "safe\u{1b}[201~\rrm -rf /\r"
        let cleaned = TerminalBridge.pasteable(hostile)
        XCTAssertFalse(cleaned.contains("\u{1b}"))
        XCTAssertFalse(cleaned.contains("\u{1b}[201~"))
    }

    func testC1ControlsAreStrippedToo() {
        // U+009B is CSI in eight-bit form — an escape sequence with no ESC in it.
        XCTAssertEqual(TerminalBridge.pasteable("a\u{9b}31mb"), "a31mb")
    }

    func testTabSurvivesAPaste() {
        // People paste tab-separated text on purpose, and the remote line editor
        // is entitled to treat it as completion.
        XCTAssertEqual(TerminalBridge.pasteable("a\tb"), "a\tb")
    }

    func testEmojiAndNonLatinTextSurviveAPaste() {
        XCTAssertEqual(TerminalBridge.pasteable("git commit -m '🎉 حسنا'"), "git commit -m '🎉 حسنا'")
    }

    func testAMultiLinePasteIsBracketedWhenTheProgramAskedForIt() {
        let bridge = bridge()
        var sent = ""
        bridge.onInput = { sent += $0 }

        // DECSET 2004 — what zsh, readline and every coding CLI turn on. Fed as
        // output, because that is how the phone learns the far end's real mode.
        bridge.feed("\u{1b}[?2004h")
        bridge.paste("first line\nsecond line")

        XCTAssertTrue(sent.hasPrefix("\u{1b}[200~"), "sent: \(sent.debugDescription)")
        XCTAssertTrue(sent.hasSuffix("\u{1b}[201~"), "sent: \(sent.debugDescription)")
        // And the payload in between is one paste with a CR in it, not two
        // submissions.
        XCTAssertTrue(sent.contains("first line\rsecond line"), "sent: \(sent.debugDescription)")
    }

    func testAPasteIsNotBracketedWhenTheProgramDidNotAskForIt() {
        let bridge = bridge()
        var sent = ""
        bridge.onInput = { sent += $0 }

        // No DECSET 2004. `cat` and a bare `sh` never set it, and sending the
        // markers anyway would print `[200~` into somebody's file.
        bridge.paste("plain text")

        XCTAssertEqual(sent, "plain text")
    }

    func testBracketedPasteIsForgottenOnAReset() {
        let bridge = bridge()
        var sent = ""
        bridge.onInput = { sent += $0 }

        bridge.feed("\u{1b}[?2004h")
        // A re-attach resets the terminal. The mode the dead connection left
        // behind must not outlive it, or the first paste after reconnecting is
        // bracketed at a shell that never asked.
        bridge.clear()
        bridge.paste("after")

        XCTAssertEqual(sent, "after")
    }
}
