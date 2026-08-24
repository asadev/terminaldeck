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

    /**
     * A store of this test's own, and it is not tidiness.
     *
     * `TerminalBridge` paints from `TerminalThemeStore.shared`, which reads the
     * simulator's own `UserDefaults` — so a scheme pinned by a UI run, or by
     * somebody's finger on the same simulator, would silently decide what colour
     * every assertion below expects. A fresh suite has nothing pinned, which
     * means `follow-app`, which is what a fresh install has.
     */
    private func store() -> TerminalThemeStore {
        let defaults = UserDefaults(suiteName: "bridge.\(UUID().uuidString)")!
        return TerminalThemeStore(defaults: defaults, center: NotificationCenter())
    }

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge(themes: store())
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

    // MARK: - The appearance

    /**
     * A terminal in a window, which is the only place trait changes happen.
     *
     * Worth its own helper and its own paragraph, because the first version of
     * these tests set `overrideUserInterfaceStyle` on the bare view and measured
     * nothing changing — and concluded, wrongly, that the mechanism did not
     * work. On iOS 17 and later a view outside a window hierarchy does not get
     * its trait collection updated at all: `traitCollection.userInterfaceStyle`
     * stayed `.light` through both settings and no change handler ran. Put the
     * same view in a window and the same code is correct.
     *
     * So the window is not scaffolding, it is the fixture: the app's terminal is
     * always in one, and a test that skipped it would be asking a question the
     * product never asks.
     */
    private func hosted() -> (bridge: TerminalBridge, window: UIWindow) {
        let bridge = TerminalBridge(themes: store())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        bridge.view.frame = root.view.bounds
        root.view.addSubview(bridge.view)
        window.layoutIfNeeded()
        return (bridge, window)
    }

    /// Change the appearance the way the window does when the setting moves, and
    /// let UIKit run the update cycle that propagates it.
    private func switchTo(_ style: UIUserInterfaceStyle, _ window: UIWindow) {
        window.overrideUserInterfaceStyle = style
        window.layoutIfNeeded()
    }

    /**
     * The terminal repaints when the appearance changes, and this is the one
     * test in the suite that could not have been written by reasoning about the
     * code.
     *
     * SwiftTerm does not keep a `UIColor`. `nativeForegroundColor`'s setter runs
     * `getTerminalColor()` on the value it is given and stores the result in
     * `terminal.foregroundColor` as a 16-bit RGB struct, and `installColors`
     * does the same to the ANSI set. So handing the emulator a colour built from
     * a `dynamicProvider` — which is exactly what works for every other UIKit
     * view in this app — resolves it once and freezes it. The symptom is a phone
     * switched to Light whose chrome changes and whose terminal does not: no
     * crash, no warning, and correct-looking in whichever appearance the app
     * happened to launch in.
     */
    func testTheTerminalsPaperAndInkFollowTheAppearance() {
        let (bridge, window) = hosted()

        switchTo(.dark, window)
        let darkPaper = bridge.view.getTerminal().backgroundColor
        let darkInk = bridge.view.getTerminal().foregroundColor

        switchTo(.light, window)
        let lightPaper = bridge.view.getTerminal().backgroundColor
        let lightInk = bridge.view.getTerminal().foregroundColor

        XCTAssertNotEqual(darkPaper, lightPaper, "the terminal's paper did not follow the appearance")
        XCTAssertNotEqual(darkInk, lightInk, "the terminal's ink did not follow the appearance")

        // And it is the *right* paper rather than merely a different one: the
        // light value is the desktop's own `--terminal-bg`, so the two products'
        // terminals are one colour.
        XCTAssertEqual(lightPaper.red / 257, 0xe8)
        XCTAssertEqual(lightPaper.green / 257, 0xe8)
        XCTAssertEqual(lightPaper.blue / 257, 0xe8)
        // `#191919` — Deck Dark, out of the shared scheme table. It was
        // `#121212` before this app had schemes; see `Ink.terminalPaper`.
        XCTAssertEqual(darkPaper.red / 257, 0x19)
    }

    /**
     * And so does the ANSI palette — asked of the emulator rather than of this
     * app's own constants.
     *
     * OSC 4 with a `?` is the escape sequence a program uses to ask a terminal
     * what colour *n* currently is, and the answer comes back through the same
     * channel a keystroke does. So this reads the palette the emulator will
     * actually paint with, which is the thing that was frozen: `installColors`
     * flattens sixteen `UIColor`s into sixteen structs, and nothing re-runs it
     * unless something asks.
     *
     * Colour 2 is green because green is the one an agent's diff uses on every
     * line it adds, and because it is one of the nine that had to move for the
     * light theme — the desktop's `#4e9a06` is 2.9:1 on paper.
     */
    func testTheAnsiPaletteFollowsTheAppearance() {
        let (bridge, window) = hosted()
        var replies = ""
        bridge.onInput = { replies += $0 }

        switchTo(.dark, window)
        replies = ""
        bridge.feed("\u{1b}]4;2;?\u{1b}\\")
        let dark = replies

        switchTo(.light, window)
        replies = ""
        bridge.feed("\u{1b}]4;2;?\u{1b}\\")
        let light = replies

        // `formatAsXcolor` writes each channel as four hex digits, and
        // `init(red8:)` widens by 257 — so #4e9a06 comes back as 4e4e/9a9a/0606.
        XCTAssertTrue(dark.contains("4e4e/9a9a/0606"),
                      "dark ANSI green should be the desktop's #4e9a06; the terminal said \(dark.debugDescription)")
        XCTAssertTrue(light.contains("3b3b/7474/0505"),
                      "light ANSI green should be the walked-down #3b7405; the terminal said \(light.debugDescription)")
    }

    // MARK: - The scheme

    /**
     * Choosing a scheme repaints a session that is already open.
     *
     * *"Applies live"* is the requirement and this is the whole of it. Without
     * the notification observer in `TerminalBridge`, the picker still works, the
     * choice still saves, and the next session opens in the new colours — while
     * the terminal the person is looking at keeps yesterday's. Nothing in the
     * SwiftUI graph can fix that: the emulator is a UIKit view SwiftUI does not
     * own, and SwiftTerm resolved and froze every colour it was given.
     *
     * The colour is read back out of the emulator rather than off this app's
     * constants, for the same reason the appearance tests do it.
     */
    func testChoosingASchemeRepaintsAnOpenSession() {
        let center = NotificationCenter()
        let defaults = UserDefaults(suiteName: "bridge.\(UUID().uuidString)")!
        let themes = TerminalThemeStore(defaults: defaults, center: center)
        let bridge = TerminalBridge(themes: themes)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        bridge.view.frame = root.view.bounds
        root.view.addSubview(bridge.view)
        switchTo(.dark, window)

        XCTAssertEqual(bridge.view.getTerminal().backgroundColor.red / 257, 0x19,
                       "a fresh phone follows the app, which in dark is Deck Dark")

        // The store this bridge was built with posts on its own centre, and the
        // bridge listens on `.default` — so this is the real path: the app's
        // singletons both use `.default`, and a test that posted directly would
        // be proving less than it looks.
        themes.select(TerminalScheme.pureBlackID)
        NotificationCenter.default.post(name: .terminalSchemeChanged, object: nil)

        XCTAssertEqual(bridge.view.getTerminal().backgroundColor.red / 257, 0x00)
        XCTAssertEqual(bridge.view.getTerminal().backgroundColor.green / 257, 0x00)
        XCTAssertEqual(bridge.view.getTerminal().backgroundColor.blue / 257, 0x00)
    }

    /**
     * A chosen scheme does not follow the appearance, and this is where that is
     * proved on the emulator rather than in arithmetic.
     *
     * Solarized Light on a phone in Dark stays Solarized Light. The failure this
     * guards is a resolver that helpfully "corrected" a light scheme on a dark
     * phone, which would be the app overruling the one choice the picker exists
     * to offer.
     */
    func testAChosenSchemeSurvivesTheAppearanceChanging() {
        let defaults = UserDefaults(suiteName: "bridge.\(UUID().uuidString)")!
        let themes = TerminalThemeStore(defaults: defaults, center: NotificationCenter())
        themes.select("solarized-light")
        let bridge = TerminalBridge(themes: themes)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        bridge.view.frame = root.view.bounds
        root.view.addSubview(bridge.view)

        for style in [UIUserInterfaceStyle.dark, .light, .dark] {
            switchTo(style, window)
            let paper = bridge.view.getTerminal().backgroundColor
            XCTAssertEqual(paper.red / 257, 0xfd, "style \(style.rawValue)")
            XCTAssertEqual(paper.green / 257, 0xf6, "style \(style.rawValue)")
            XCTAssertEqual(paper.blue / 257, 0xe3, "style \(style.rawValue)")
        }
    }

    /// The sixteen come from the scheme too, asked of the emulator through the
    /// escape sequence a program would use. Dracula's green is `#50fa7b` and is
    /// nothing any other scheme here would produce.
    func testTheSixteenComeFromTheChosenScheme() {
        let defaults = UserDefaults(suiteName: "bridge.\(UUID().uuidString)")!
        let themes = TerminalThemeStore(defaults: defaults, center: NotificationCenter())
        themes.select("dracula")
        let bridge = TerminalBridge(themes: themes)
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()

        var replies = ""
        bridge.onInput = { replies += $0 }
        bridge.feed("\u{1b}]4;2;?\u{1b}\\")
        XCTAssertTrue(replies.contains("5050/fafa/7b7b"),
                      "the terminal said \(replies.debugDescription)")
    }

    /// Going back is not a special case, and a stuck value would only show on
    /// the second change — which is where a cache that was cleared once and not
    /// again would hide.
    func testTheTerminalFollowsTheAppearanceBackAgain() {
        let (bridge, window) = hosted()
        switchTo(.light, window)
        let paper = bridge.view.getTerminal().backgroundColor
        switchTo(.dark, window)
        switchTo(.light, window)
        XCTAssertEqual(bridge.view.getTerminal().backgroundColor, paper)
    }
}
