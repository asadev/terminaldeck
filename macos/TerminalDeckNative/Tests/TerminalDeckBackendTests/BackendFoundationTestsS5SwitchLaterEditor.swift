import Foundation
import Testing
@testable import TerminalDeckBackend

// Seam S5-4 landed (lane P1); the build flag guard is gone.

private let ESC = "\u{1b}"
private enum Key {
    static let up = ESC + "[A", down = ESC + "[B", right = ESC + "[C", left = ESC + "[D", ss3Left = ESC + "OD", ss3Right = ESC + "OC"
    static let home = ESC + "[H", end = ESC + "[F", homeNumbered = ESC + "[1~", endNumbered = ESC + "[4~", del = ESC + "[3~"
    static let pageUp = ESC + "[5~", shiftTab = ESC + "[Z", ctrlLeft = ESC + "[1;5D", optionLeft = ESC + "b", f5 = ESC + "[15~"
    static let pasteOn = ESC + "[200~", pasteOff = ESC + "[201~"
    static let backspace = "\u{7f}", ctrlA = "\u{1}", ctrlE = "\u{5}", ctrlK = "\u{b}", ctrlU = "\u{15}", ctrlW = "\u{17}", ctrlC = "\u{3}", tab = "\t"
    static let all = [up, down, right, left, ss3Left, ss3Right, home, end, homeNumbered, endNumbered, del, pageUp, shiftTab, ctrlLeft, optionLeft, f5,
                      pasteOn, pasteOff, backspace, ctrlA, ctrlE, ctrlK, ctrlU, ctrlW, ctrlC, tab]
}
private typealias Editor = BackendSessionSwitchDeferred.Editor
private func compose(_ keys: String, from start: Editor = Editor()) -> Editor { var editor = start; _ = editor.feed(keys); return editor }
private func hasControl(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }

@Suite("S5 switch-later: the line editor (TS compose)")
struct BackendFoundationTestsS5SwitchLaterEditor {
    // TS switch-later.test.ts:101
    @Test func buildsTheLineFromOrdinaryTyping() { let e = compose("fix the bug"); #expect(e.text == "fix the bug"); #expect(e.exact); #expect(e.cursor == 11) }
    // TS switch-later.test.ts:108
    @Test func backspaceInBothSpellings() { #expect(compose("abc\u{7f}").text == "ab"); #expect(compose("abc\u{8}").text == "ab") }
    // TS switch-later.test.ts:113
    @Test func ctrlUClearsAndCtrlWDropsAWord() { #expect(compose("hello there" + Key.ctrlU).text == ""); #expect(compose("hello there" + Key.ctrlW).text == "hello ") }
    // TS switch-later.test.ts:118
    @Test func ctrlCAbandonsTheLineAndIsCertainAgain() {
        var start = Editor(); start.characters = Array("half typed"); start.cursor = 10; start.exact = false
        let e = compose(Key.ctrlC, from: start)
        #expect(e.text == ""); #expect(e.exact); #expect(e.cursor == 0)
    }
    // TS switch-later.test.ts:139
    @Test func noEscapeSequenceEverPutsACharacterInTheLine() {
        let sequences = [Key.up, Key.down, Key.left, Key.right, Key.ss3Left, Key.ss3Right, Key.home, Key.end, Key.homeNumbered, Key.endNumbered, Key.del,
                         Key.pageUp, Key.shiftTab, Key.ctrlLeft, Key.optionLeft, Key.f5, Key.tab, ESC + "]0;a window title\u{7}", ESC + "Pq some device string" + ESC + "\\", ESC]
        for keys in sequences {
            let e = compose("typed" + keys)
            #expect(e.text == "typed", "\(keys.debugDescription) leaked into the line"); #expect(!hasControl(e.text))
        }
    }
    // TS switch-later.test.ts:169
    @Test func cursorMakesArrowKeyEditsExact() { let e = compose("run the tesst" + Key.left + Key.backspace + Key.end); #expect(e.text == "run the test"); #expect(e.exact) }
    // TS switch-later.test.ts:181
    @Test func insertsWhereTheCursorIs() { let e = compose("world" + Key.home + "hello "); #expect(e.text == "hello world"); #expect(e.cursor == 6); #expect(e.exact) }
    // TS switch-later.test.ts:188
    @Test func deleteForwardAndBackspaceBackward() { #expect(compose("abcd" + Key.home + Key.del).text == "bcd"); #expect(compose("abcd" + Key.left + Key.backspace).text == "abd") }
    // TS switch-later.test.ts:193
    @Test func readlineKillsActAtTheCursor() {
        #expect(compose("hello there" + Key.ctrlA + Key.ctrlK).text == "")
        #expect(compose("hello there" + Key.left + Key.left + Key.ctrlK).text == "hello the")
        #expect(compose("hello there" + Key.left + Key.left + Key.ctrlU).text == "re")
        #expect(compose("hello there" + Key.ctrlA + Key.ctrlE + "x").text == "hello therex")
    }
    // TS switch-later.test.ts:200
    @Test func cursorStopsAtBothEnds() {
        #expect(compose("ab" + String(repeating: Key.left, count: 4) + "x").text == "xab")
        #expect(compose("ab" + Key.right + Key.right + "x").text == "abx")
        let e = compose(Key.backspace + "ab"); #expect(e.text == "ab"); #expect(e.exact)
    }
    // TS switch-later.test.ts:217
    @Test func modifiedCursorKeyIsConsumedAndCertaintyGoes() { let e = compose("one two three" + Key.ctrlLeft); #expect(e.text == "one two three"); #expect(!e.exact) }
    // TS switch-later.test.ts:223
    @Test func historyRecallGivesUpCertaintyKeepsWords() { let e = compose("draft" + Key.up); #expect(e.text == "draft"); #expect(!e.exact) }
    // TS switch-later.test.ts:232
    @Test func pastedLineIsTextWithoutItsBrackets() { let e = compose(Key.pasteOn + "pasted text" + Key.pasteOff); #expect(e.text == "pasted text"); #expect(e.exact); #expect(!e.pasting) }
    // TS switch-later.test.ts:239
    @Test func multiLinePasteKeptWholeButNotSendable() {
        let e = compose(Key.pasteOn + "first\rsecond" + Key.pasteOff); #expect(e.text == "first\nsecond"); #expect(!e.exact)
    }
    // TS switch-later.test.ts:251
    @Test func sequenceSplitAcrossChunksSurvives() {
        let keys = "abc" + Key.left + Key.left + "X" + Key.end + "!"
        var byByte = Editor(); for ch in keys { _ = byByte.feed(String(ch)) }
        #expect(byByte.text == "aXbc!"); #expect(byByte.exact); #expect(byByte.escape.isEmpty); #expect(byByte.text == compose(keys).text)
    }
    // TS switch-later.test.ts:260
    @Test func chunkEndingInsideASequenceIsStillMidSequence() {
        let half = compose("abc" + ESC + "["); #expect(half.text == "abc"); #expect(!half.escape.isEmpty)
        let rest = compose("D!", from: half); #expect(rest.text == "ab!c"); #expect(rest.escape.isEmpty)
    }
    // TS switch-later.test.ts:278 — same LCG and seed as the TS test
    @Test func lineHoldsNothingHeDidNotType() {
        let words = ["fix", "the", "bug", "now", "please"]
        let noise = Key.all + [ESC + "[?2004h", ESC + "[6n", ESC + "[999;999R", ESC + "]0;title\u{7}", ESC + "O", ESC + "[", ESC + "[1;", ESC, "\u{7}", "\u{0}"]
        var seed = 20260820
        func next() -> Int { seed = (seed * 1103515245 + 12345) % 2147483648; return seed }
        let allowed = Set("fixthebugnowplase")
        for _ in 0..<2000 {
            var stream = "", typed = ""
            for _ in 0..<12 {
                if next() % 3 == 0 { let word = words[next() % words.count]; stream += word; typed += word } else { stream += noise[next() % noise.count] }
            }
            let e = compose(stream); let text = e.text.replacingOccurrences(of: "\n", with: "")
            #expect(!hasControl(text), "control byte in \(e.text.debugDescription)")
            #expect(text.allSatisfy { allowed.contains($0) }, "foreign text in \(e.text.debugDescription)")
            #expect(text.count <= typed.count)
        }
    }
    // TS switch-later.test.ts:343
    @Test func focusReportKeepsLineExact() { let e = compose(ESC + "[O" + ESC + "[I" + "what is the secret word"); #expect(e.text == "what is the secret word"); #expect(e.exact) }
    // TS switch-later.test.ts:349
    @Test func focusChangeMidSentenceKeepsLineExact() { let e = compose("what is " + ESC + "[I" + "the secret word"); #expect(e.text == "what is the secret word"); #expect(e.exact) }
    // TS switch-later.test.ts:355
    @Test func sgrMouseReportKeepsLineExact() { let e = compose("run " + ESC + "[<0;40;12M" + ESC + "[<0;40;12m" + "the tests"); #expect(e.text == "run the tests"); #expect(e.exact) }
    // TS switch-later.test.ts:364
    @Test func realCursorMoveStillGivesUpCertainty() { #expect(!compose("hello" + ESC + "[A").exact) }
    // TS switch-later.test.ts:373
    @Test func firstEnterFoundAndNothingElse() {
        var a = Editor(); #expect(a.feed("hello").submit == nil)
        var b = Editor(); let rb = b.feed("hello\r"); #expect(rb.submit != nil); #expect(rb.before == "hello")
        var c = Editor(); let rc = c.feed("hello\nworld\r"); #expect(rc.before == "hello"); #expect(rc.after == "world\r")
    }
    // TS switch-later.test.ts:386
    @Test func accumulatesWhileArmedPassingEveryKeystrokeThrough() {
        var e = Editor(); #expect(e.feed("fix ").submit == nil); #expect(e.feed("the bug").submit == nil); #expect(e.text == "fix the bug")
    }
    // TS switch-later.test.ts:394
    @Test func firesOnEnterCarryingTheWholeLineAndBytesBefore() {
        var e = Editor(); _ = e.feed("fix the"); let r = e.feed(" bug\r")
        #expect(r.submit != nil); #expect(e.text == "fix the bug"); #expect(r.before == " bug")
        #expect(e.exact && e.escape.isEmpty && !e.pasting)
    }
    // TS switch-later.test.ts:409
    @Test func notSureItReadTheLineMeansNotSendable() {
        var e = Editor(); _ = e.feed("draft" + ESC + "[A"); let r = e.feed("\r")
        #expect(r.submit != nil); #expect(!(e.exact && e.escape.isEmpty && !e.pasting))
    }
    // TS switch-later.test.ts:431
    @Test func arrowKeyCarriesHisWordsAndNothingElse() {
        var e = Editor(); _ = e.feed("run the tests"); _ = e.feed(Key.up); let r = e.feed("\r")
        #expect(r.submit != nil); #expect(e.text == "run the tests"); #expect(!e.exact)
    }
    // TS switch-later.test.ts:443
    @Test func reproducibleEditingStaysSendable() {
        var e = Editor(); _ = e.feed("run the tesst" + Key.left + Key.backspace + Key.end); let r = e.feed("\r")
        #expect(r.submit != nil); #expect(e.text == "run the test"); #expect(e.exact && e.escape.isEmpty && !e.pasting)
    }
    // TS switch-later.test.ts:456
    @Test func newlineInsidePastedBlockDoesNotFireAndIsNotSendable() {
        var e = Editor(); #expect(e.feed(Key.pasteOn + "first\rsecond" + Key.pasteOff).submit == nil)
        let r = e.feed("\r"); #expect(r.submit != nil); #expect(e.text == "first\nsecond"); #expect(!(e.exact && e.escape.isEmpty && !e.pasting))
    }
    // TS switch-later.test.ts:471
    @Test func lineWhoseLastKeystrokeHasNotArrivedIsNotSendable() {
        var e = Editor(); _ = e.feed("hello" + ESC + "["); let r = e.feed("\r")
        #expect(r.submit != nil); #expect(e.text == "hello"); #expect(!(e.exact && e.escape.isEmpty && !e.pasting))
    }
}
